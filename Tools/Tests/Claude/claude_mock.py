#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Faux serveur « API Messages d'Anthropic » pour tester ClaudeEngine sans aucun appel réseau réel.

Usage :  python3 claude_mock.py PORT [--out DOSSIER] [--images DOSSIER] [--dump DOSSIER]

Chaque requête reçue est VALIDÉE (en-têtes, version, JSON, image JPEG, schéma, champs interdits,
fallbacks seulement pour Opus/Sonnet…). Les écarts sont notés dans le rapport de l'instance et la
requête reçoit un 400 « MOCK » : le test Swift échoue alors, et affiche la liste des écarts.

Le scénario et l'instance sont portés par l'adresse de base du moteur :
    http://127.0.0.1:PORT/<scenario>/<instance>   ->   POST .../v1/messages
(un POST direct sur http://127.0.0.1:PORT/v1/messages prend le scénario de l'en-tête x-mock-scenario, « ok » par défaut,
et l'instance « default », ou x-mock-instance.)

Scénarios (premier segment du chemin) :
    ok, ok_noisy, ok_delay, split_text, fallback_block, fenced_json      réponses 200 valides (ou presque)
    auth401, forbidden403, billing402, credit400, notfound404, toolarge413, bad400, redirect302    erreurs 4xx
    rate_limit_ok, rate_limit_noheader_ok, rate_limit_always, rate_limit_cap_ok                       429
    overloaded_ok, overloaded_always, overloaded_retry_after_ok, server500_ok, status408_ok,
    bad_gateway_html_ok, drop_ok, truncated_body_ok, stale_ok                                         529, 5xx, coupures
    seq_<étape>_<étape>…                enchaînement d'une réponse par requête : 429, 529, 400fb, trunc, refuse, ok
    fallbacks400_a, fallbacks400_b      400 tant que `fallbacks` / l'en-tête bêta sont envoyés
    refusal, refusal_partial, max_tokens_ok, max_tokens_always, ping_max_tokens, context_window,
    invalid_json, bad_shape, no_zones, empty_content, html200                                         réponses 200 inexploitables
    slow, slow_timeout                  réponse après 25 s (annulation, délai dépassé)

Points d'entrée de contrôle :
    GET  /_ping                 prêt ?
    GET  /_report/<instance>    rapport JSON (requêtes reçues, écarts de validation, concurrence)
    POST /_quit                 arrêt propre

Rien de secret n'est conservé : la clé reçue n'est ni journalisée ni stockée. Le journal (--out) ne contient
ni clé ni image. Les images JPEG reçues (pages des cours de l'élève) ne sont écrites sur le disque que si --images
est demandé : le rapport donne sinon seulement leur empreinte SHA-256 et leurs dimensions.
--dump DOSSIER écrit le corps JSON de chaque requête (image et clé exclues) pour le relire à la main.
Bibliothèque standard seulement ; compatible Python 3.9 et plus récent.
"""
import base64
import binascii
import hashlib
import json
import os
import random
import re
import signal
import string
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

EXPECTED_VERSION = "2026-10-21"
EXPECTED_BETA = "server-side-fallback-2026-07-01"
FALLBACK_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5")
KNOWN_MODELS = FALLBACK_MODELS + ("claude-haiku-5-5",)
ALLOWED_TOP_KEYS = {"model", "max_tokens", "system", "messages", "output_config", "fallbacks"}
FORBIDDEN_KEYS = ("temperature", "top_p", "top_k", "thinking", "tool_choice", "tools", "stream",
                  "stop_sequences", "metadata", "output_format", "betas", "cache_control", "speed")
SYSTEM_START = {"complete": "Tu aides un élève de Seconde professionnelle",
               "humanize": "Tu retouches uniquement des réponses à des questions ouvertes"}
ROUTE = re.compile(r"/([a-z0-9_]+)/([A-Za-z0-9_-]+)/v1/messages")
ZONE_LINE = re.compile(r"^⟦(\d+)⟧ — (.+?) — capacité ≈ (\d+) caractères — type probable : (\w+)\s*$", re.M)

OUT_DIR = None
IMAGES_DIR = None
DUMP_DIR = None
LOG_FILE = None
LOG_LOCK = threading.Lock()
INSTANCES = {}
INSTANCES_LOCK = threading.Lock()
SERVER = None


# --------------------------------------------------------------------------------------------------
# État et journal
# --------------------------------------------------------------------------------------------------

class Instance(object):
    def __init__(self, name, scenario):
        self.name = name
        self.scenario = scenario
        self.lock = threading.Lock()
        self.t0 = time.monotonic()
        self.count = 0
        self.inflight = 0
        self.max_inflight = 0
        self.errors = []
        self.calls = []


def get_instance(name, scenario):
    with INSTANCES_LOCK:
        inst = INSTANCES.get(name)
        if inst is None:
            inst = INSTANCES[name] = Instance(name, scenario)
        return inst


def log(line):
    """Journal du mock : jamais de clé, jamais d'image."""
    if not LOG_FILE:
        return
    stamp = time.strftime("%H:%M:%S") + ".%03d" % (int(time.time() * 1000) % 1000)
    with LOG_LOCK:
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(stamp + " " + line + "\n")
        except OSError:
            pass


def dump_request(path, headers, body):
    """Corps de la requête sans l'image (remplacée par sa taille) ; la valeur de x-api-key n'est jamais écrite."""
    def light(x):
        if isinstance(x, dict):
            return {k: ("<%d caractères base64>" % len(v) if k == "data" and isinstance(v, str) else light(v)) for k, v in x.items()}
        if isinstance(x, list):
            return [light(v) for v in x]
        return x
    doc = {"en-têtes": {k: ("<masquée>" if k == "x-api-key" else v) for k, v in sorted(headers.items())}, "corps": light(body)}
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
    except OSError:
        pass


def rand_id(prefix, n=22):
    return prefix + "".join(random.choice(string.ascii_letters + string.digits) for _ in range(n))


# --------------------------------------------------------------------------------------------------
# Validation d'une requête
# --------------------------------------------------------------------------------------------------

def jpeg_size(data):
    """Largeur et hauteur d'un JPEG, ou ValueError s'il est invalide."""
    if len(data) < 4 or data[0:2] != b"\xff\xd8":
        raise ValueError("début de fichier (SOI) absent")
    if data[-2:] != b"\xff\xd9":
        raise ValueError("fin de fichier (EOI) absente")
    i = 2
    sof = (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF)
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            raise ValueError("marqueur attendu à l'octet %d" % i)
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker == 0x01 or 0xD0 <= marker <= 0xD8:
            i += 2
            continue
        seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in sof:
            _precision, h, w = struct.unpack(">BHH", data[i + 4:i + 9])
            return w, h
        if marker == 0xDA:
            break
        i += 2 + seglen
    raise ValueError("cadre de l'image (SOF) introuvable")


def check_schema(kind, s, errs):
    def need(cond, msg):
        if not cond:
            errs.append("schéma : " + msg)

    if not isinstance(s, dict):
        errs.append("schéma : doit être un objet")
        return
    need(s.get("type") == "object", "la racine doit être de type object")
    need(s.get("additionalProperties") is False, "additionalProperties doit valoir false (racine)")
    root = "zones" if kind == "complete" else "reponses"
    need(s.get("required") == [root], "required doit valoir [%r]" % root)
    props = s.get("properties")
    arr = props.get(root) if isinstance(props, dict) else None
    need(isinstance(arr, dict) and arr.get("type") == "array", "%s doit être un tableau" % root)
    item = arr.get("items") if isinstance(arr, dict) else None
    if not isinstance(item, dict):
        errs.append("schéma : items manquant")
        return
    need(item.get("type") == "object", "items doit être de type object")
    need(item.get("additionalProperties") is False, "additionalProperties doit valoir false (items)")
    if kind == "complete":
        expected = {"numero": "integer", "type": "string", "texte": "string"}
    else:
        expected = {"id": "integer", "texte": "string"}
    iprops = item.get("properties") if isinstance(item.get("properties"), dict) else {}
    need(sorted(iprops) == sorted(expected), "propriétés d'items %s au lieu de %s" % (sorted(iprops), sorted(expected)))
    for k, t in expected.items():
        need(isinstance(iprops.get(k), dict) and iprops[k].get("type") == t, "%s doit être de type %s" % (k, t))
    need(sorted(item.get("required") or []) == sorted(expected), "required d'items incorrect")
    if kind == "complete" and isinstance(iprops.get("type"), dict):
        need(iprops["type"].get("enum") == ["mot", "definition", "question", "ignorer"], "enum de type incorrect")


UNSUPPORTED_SCHEMA_KEYS = ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength",
                            "maxLength", "maxItems", "uniqueItems", "minContains", "maxContains")


def check_generic_schema(s, errs, path="racine", is_schema=True):
    """Restrictions des sorties structurées (doc : tool-use-concepts.md, « JSON Schema Limitations »)."""
    if not isinstance(s, dict):
        errs.append("schéma %s : doit être un objet" % path)
        return
    if path == "racine" and s.get("type") != "object":
        errs.append("schéma : la racine doit être de type object")
    for k in UNSUPPORTED_SCHEMA_KEYS:
        if k in s:
            errs.append("schéma %s : « %s » n'est pas pris en charge par les sorties structurées" % (path, k))
    if isinstance(s.get("minItems"), int) and s["minItems"] > 1:
        errs.append("schéma %s : minItems > 1 n'est pas pris en charge" % path)
    if s.get("type") == "object" or "properties" in s:
        if s.get("additionalProperties") is not False:
            errs.append("schéma %s : additionalProperties doit valoir false" % path)
        props = s.get("properties") or {}
        if sorted(s.get("required") or []) != sorted(props):
            errs.append("schéma %s : required doit lister toutes les propriétés" % path)
        for name, sub in props.items():
            check_generic_schema(sub, errs, path + "." + name)
    if "items" in s:
        check_generic_schema(s["items"], errs, path + "[]")
    for k in ("anyOf", "allOf"):
        for i, sub in enumerate(s.get(k) or []):
            check_generic_schema(sub, errs, "%s.%s%d" % (path, k, i))
    for k in ("$defs", "definitions"):
        for name, sub in (s.get(k) or {}).items():
            check_generic_schema(sub, errs, "%s.%s.%s" % (path, k, name))


def value_for(schema, name="x"):
    """Valeur minimale conforme au schéma."""
    if "enum" in schema:
        return schema["enum"][0]
    t = schema.get("type")
    if t == "object":
        return {k: value_for(v, k) for k, v in (schema.get("properties") or {}).items()}
    if t == "array":
        return [value_for(schema.get("items") or {"type": "string"}, name)]
    if t == "integer":
        return 7
    if t == "number":
        return 1.5
    if t == "boolean":
        return True
    return "valeur de %s" % name


def validate_image(block, errs, info):
    if set(block) != {"type", "source"}:
        errs.append("image : champs inattendus %s" % sorted(block))
    src = block.get("source")
    if not isinstance(src, dict):
        errs.append("image : source manquante")
        return
    if set(src) != {"type", "media_type", "data"}:
        errs.append("image : champs de source inattendus %s" % sorted(src))
    if src.get("type") != "base64":
        errs.append("image : source.type doit être base64")
    if src.get("media_type") != "image/jpeg":
        errs.append("image : media_type doit être image/jpeg (reçu %r)" % src.get("media_type"))
    try:
        raw = base64.b64decode(src.get("data") or "", validate=True)
    except (binascii.Error, ValueError, TypeError) as e:
        errs.append("image : base64 invalide (%s)" % e)
        return
    try:
        w, h = jpeg_size(raw)
    except ValueError as e:
        errs.append("image : JPEG invalide (%s)" % e)
        return
    if len(raw) > 5 * 1024 * 1024:
        errs.append("image : %d octets, plus que la limite de 5 Mo de l'API" % len(raw))
    if max(w, h) > 2576:
        errs.append("image : %dx%d dépasse la limite de l'API (2576 px)" % (w, h))
    if max(w, h) < 600:
        errs.append("image : %dx%d trop petite pour être lisible" % (w, h))
    info["has_image"] = True
    info["image"] = {"bytes": len(raw), "w": w, "h": h, "sha256": hashlib.sha256(raw).hexdigest()}
    if IMAGES_DIR:
        info["image_bytes"] = raw


def validate(headers, raw, scenario, n):
    """Renvoie (liste d'écarts, corps décodé ou None, informations)."""
    errs = []
    info = {"kind": "unknown", "model": None, "max_tokens": None, "has_image": False, "image": None,
            "fallbacks": False, "system": "", "user_text": "", "schema": None}

    ct = headers.get("content-type", "")
    if ct.split(";")[0].strip().lower() != "application/json":
        errs.append("content-type doit être application/json (reçu %r)" % ct)
    key = headers.get("x-api-key", "")
    if not key or not re.fullmatch(r"[\x21-\x7e]+", key):
        errs.append("x-api-key absent ou contenant des caractères interdits")
    if headers.get("anthropic-version") != EXPECTED_VERSION:
        errs.append("anthropic-version attendu %s, reçu %r" % (EXPECTED_VERSION, headers.get("anthropic-version")))

    try:
        body = json.loads(raw.decode("utf-8"))
        if not isinstance(body, dict):
            raise ValueError("le corps n'est pas un objet JSON")
    except Exception as e:  # noqa: BLE001
        errs.append("corps non JSON : %s" % e)
        return errs, None, info

    for k in sorted(set(body) - ALLOWED_TOP_KEYS):
        errs.append("champ non documenté ou interdit : %s" % k)
    for k in FORBIDDEN_KEYS:
        if k in body:
            errs.append("champ interdit présent : %s" % k)

    model = body.get("model")
    info["model"] = model
    if model not in KNOWN_MODELS:
        errs.append("model inconnu : %r" % (model,))
    mt = body.get("max_tokens")
    info["max_tokens"] = mt
    if not isinstance(mt, int) or isinstance(mt, bool) or mt < 1:
        errs.append("max_tokens doit être un entier positif")

    system = body.get("system")
    oc = body.get("output_config")
    if oc is None and mt == 16:
        kind = "ping"
    elif isinstance(system, str) and system.startswith(SYSTEM_START["complete"]):
        kind = "complete"
    elif isinstance(system, str) and system.startswith(SYSTEM_START["humanize"]):
        kind = "humanize"
    elif isinstance(system, str) and system.strip() and oc is not None:
        kind = "generic"      # mode Révision : système et schéma libres, mais les mêmes règles de l'API
    else:
        kind = "unknown"
        errs.append("requête non reconnue (system inattendu)")
    info["kind"] = kind
    if isinstance(system, str):
        info["system"] = system

    messages = body.get("messages")
    if not (isinstance(messages, list) and len(messages) == 1 and isinstance(messages[0], dict)):
        errs.append("messages doit contenir exactement un message")
        messages = None
    elif messages[0].get("role") != "user" or set(messages[0]) != {"role", "content"}:
        errs.append("le message doit être {role: user, content}")

    if kind == "ping":
        if set(body) != {"model", "max_tokens", "messages"}:
            errs.append("vérification de clé : champs %s au lieu de model/max_tokens/messages" % sorted(body))
        if mt != 16:
            errs.append("vérification de clé : max_tokens doit valoir 16")
    elif kind in ("complete", "humanize", "generic"):
        first_mt = 12000 if kind == "generic" else 8000
        expected_mt = 16000 if (scenario.startswith("max_tokens") and n >= 2) else first_mt
        if mt != expected_mt and not scenario.startswith("seq_"):
            errs.append("max_tokens attendu %d, reçu %r" % (expected_mt, mt))
        if isinstance(mt, int) and mt > 16000:
            errs.append("max_tokens %d : au-delà de ~16 000 la documentation impose le streaming" % mt)
        if scenario.startswith("seq_") and mt not in (8000, 16000):
            errs.append("max_tokens attendu 8000 ou 16000, reçu %r" % (mt,))
        if not (isinstance(oc, dict) and set(oc) == {"effort", "format"}):
            errs.append("output_config doit contenir exactement effort et format")
        else:
            if oc.get("effort") != "medium":
                errs.append("output_config.effort attendu 'medium', reçu %r" % (oc.get("effort"),))
            fmt = oc.get("format")
            if not (isinstance(fmt, dict) and set(fmt) == {"type", "schema"} and fmt.get("type") == "json_schema"):
                errs.append("output_config.format doit être {type: json_schema, schema}")
            else:
                info["schema"] = fmt.get("schema")
                if kind == "generic":
                    check_generic_schema(fmt.get("schema"), errs)
                else:
                    check_schema(kind, fmt.get("schema"), errs)

        if messages is not None:
            content = messages[0].get("content")
            if not isinstance(content, list) or not content:
                errs.append("content doit être une liste de blocs")
            else:
                texts = [b for b in content if isinstance(b, dict) and b.get("type") == "text"]
                images = [b for b in content if isinstance(b, dict) and b.get("type") == "image"]
                if len(texts) != 1 or content[-1].get("type") != "text" or set(content[-1]) != {"type", "text"}:
                    errs.append("le dernier bloc doit être l'unique bloc texte {type, text}")
                if len(texts) + len(images) != len(content):
                    errs.append("blocs de types inattendus")
                if kind == "humanize" and images:
                    errs.append("l'humanisation n'envoie pas d'image")
                if len(images) > 1 and kind != "generic":
                    errs.append("une seule image attendue")
                if images:
                    if any(b.get("type") != "image" for b in content[:len(images)]):
                        errs.append("les images doivent précéder le texte")
                    for im in images:
                        validate_image(im, errs, info)
                    info["image_count"] = len(images)
                if texts and isinstance(texts[0].get("text"), str):
                    info["user_text"] = texts[0]["text"]
                    if not info["user_text"].strip():
                        errs.append("texte utilisateur vide")
    # fallbacks / bêta
    has_fb = "fallbacks" in body
    info["fallbacks"] = has_fb
    beta = headers.get("anthropic-beta")
    if has_fb:
        if body.get("fallbacks") != "default":
            errs.append("fallbacks doit valoir \"default\"")
        if model not in FALLBACK_MODELS:
            errs.append("fallbacks interdit pour %s" % model)
        if beta != EXPECTED_BETA:
            errs.append("fallbacks sans l'en-tête anthropic-beta attendu (reçu %r)" % (beta,))
        if kind == "ping":
            errs.append("la vérification de clé n'envoie pas fallbacks")
    else:
        if beta is not None:
            errs.append("anthropic-beta présent alors qu'il n'y a pas de fallbacks")
        if kind in ("complete", "humanize", "generic") and model in FALLBACK_MODELS and not scenario.startswith(("fallbacks400", "seq_")):
            errs.append("fallbacks absent pour %s" % model)
    return errs, body, info


# --------------------------------------------------------------------------------------------------
# Réponses réalistes
# --------------------------------------------------------------------------------------------------

MOTS = ["énergie", "résistance", "tension", "courant", "12 V", "puissance", "X", "isolant", "circuit"]


class RawBody(object):
    """Corps de réponse qui n'est pas du JSON (page HTML d'un proxy, par exemple)."""

    def __init__(self, content_type, data):
        self.content_type = content_type
        self.data = data


def api_message(model, text, stop_reason="end_turn", stop_details=None, with_thinking=True, out_tokens=None,
                texts=None, before=None):
    """Réponse 200. `texts` : plusieurs blocs texte à la suite ; `before` : blocs placés en tête (bloc fallback)."""
    content = list(before or [])
    if with_thinking:  # affichage « omitted » par défaut : bloc thinking vide + signature
        content.append({"type": "thinking", "thinking": "", "signature": rand_id("Eu", 120)})
    for part in (texts if texts is not None else ([text] if text is not None else [])):
        content.append({"type": "text", "text": part})
    msg = {
        "id": rand_id("msg_01"),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 1800 + random.randint(0, 400), "cache_creation_input_tokens": 0,
                  "cache_read_input_tokens": 0, "output_tokens": out_tokens or 320, "service_tier": "standard"},
    }
    if stop_details is not None:
        msg["stop_details"] = stop_details
    return msg


def api_error(kind, message):
    return {"type": "error", "error": {"type": kind, "message": message}, "request_id": rand_id("req_011C")}


def user_text_of(body):
    content = body["messages"][0]["content"]
    if isinstance(content, str):
        return content
    return content[-1].get("text", "")


def completion_json(body, noisy=False, truncated=False):
    text = user_text_of(body)
    zones = []
    for m in ZONE_LINE.finditer(text):
        num, _nature, cap, probable = int(m.group(1)), m.group(2), int(m.group(3)), m.group(4)
        kind = probable if probable in ("mot", "definition", "question", "ignorer") else "question"
        if kind == "mot":
            answer = MOTS[num % len(MOTS)]
        elif kind == "definition":
            answer = "Définition de la zone %d : une courte phrase qui explique la notion simplement." % num
        elif kind == "question":
            answer = "Réponse à la question %d : on explique l'idée en une phrase claire, avec un exemple." % num
        else:
            answer = ""
        zones.append({"numero": num, "type": kind, "texte": answer[:max(cap, 4)]})
    if noisy and zones:
        zones.append({"numero": 999, "type": "mot", "texte": "intrus"})                # numéro absent de la requête
        zones.append({"numero": zones[0]["numero"], "type": "mot", "texte": "DOUBLON"})  # doublon : le premier gagne
        zones[-3]["type"] = "inconnu"                                                    # type inconnu -> question
    out = json.dumps({"zones": zones}, ensure_ascii=False)
    if truncated:
        out = out[:max(10, int(len(out) * 0.6))]
    return out


def humanize_json(body):
    text = user_text_of(body)
    try:
        rows = json.loads(text.split("\n\n", 1)[1])
    except Exception:  # noqa: BLE001
        rows = []
    out = []
    for r in rows:
        ans = r.get("reponse", "")
        out.append({"id": r["id"], "texte": (ans[:1].swapcase() + ans[1:]) if ans else ans})
    out.append({"id": 424242, "texte": "id inconnu à ignorer"})
    return json.dumps({"reponses": out}, ensure_ascii=False)


def generic_json(body):
    schema = body["output_config"]["format"]["schema"]
    return json.dumps(value_for(schema), ensure_ascii=False)


def reply_json(kind, body):
    if kind == "generic":
        return generic_json(body)
    return completion_json(body) if kind == "complete" else humanize_json(body)


def success(kind, model, body, noisy=False, truncated=False):
    if kind == "ping":
        return api_message(model, "ok", out_tokens=2)
    if kind == "generic":
        out = generic_json(body)
        if truncated:
            out = out[:max(10, int(len(out) * 0.6))]
        return api_message(model, out, stop_reason="max_tokens" if truncated else "end_turn",
                           out_tokens=12000 if truncated else 900)
    if kind == "humanize":
        out = humanize_json(body)
        if truncated:
            out = out[:max(10, int(len(out) * 0.6))]
        return api_message(model, out, stop_reason="max_tokens" if truncated else "end_turn",
                           out_tokens=8000 if truncated else 400)
    return api_message(model, completion_json(body, noisy=noisy, truncated=truncated),
                       stop_reason="max_tokens" if truncated else "end_turn", out_tokens=8000 if truncated else 600)


def plan(scenario, n, kind, model, body):
    """Décide de la réponse : (statut, objet JSON, en-têtes, délai en secondes, couper la connexion)."""
    def ok(**kw):
        return 200, success(kind, model, body, **kw), {}, 0.0, False

    def err(status, etype, message, headers=None):
        return status, api_error(etype, message), headers or {}, 0.0, False

    has_fb = "fallbacks" in body
    if scenario.startswith("seq_"):
        # Enchaînement de réponses, une par requête (la dernière se répète) : 429, 529, 400fb (400 tant que
        # `fallbacks` est envoyé, sinon succès), trunc (réponse coupée), refuse, ok.
        steps = scenario[4:].split("_")
        step = steps[min(n, len(steps)) - 1]
        if step == "429":
            return err(429, "rate_limit_error", "rate limited", {"retry-after": "1"})
        if step == "529":
            return err(529, "overloaded_error", "Overloaded")
        if step == "400fb":
            if has_fb:
                return err(400, "invalid_request_error", "fallbacks: Extra inputs are not permitted")
            return ok()
        if step == "trunc":
            return ok(truncated=True)
        if step == "refuse":
            return 200, api_message(model, None, stop_reason="refusal", with_thinking=False), {}, 0.0, False
        return ok()
    if scenario == "ok":
        return ok()
    if scenario == "ok_noisy":
        return ok(noisy=True)
    if scenario == "ok_delay":
        status, payload, h, _d, c = ok()
        return status, payload, h, 0.5, c
    if scenario == "auth401":
        return err(401, "authentication_error", "invalid x-api-key")
    if scenario == "forbidden403":
        return err(403, "permission_error", "Your credential is not allowed to use this model.")
    if scenario == "billing402":
        return err(402, "billing_error", "Your credit balance is too low to access the Anthropic API.")
    if scenario == "notfound404":
        return err(404, "not_found_error", "model: %s" % model)
    if scenario == "toolarge413":
        return err(413, "request_too_large", "Request exceeds the maximum allowed number of bytes.")
    if scenario == "bad400":
        return err(400, "invalid_request_error", "messages.0.content.1.text: text content blocks must be non-empty")
    if scenario == "redirect302":
        return 302, {"moved": True}, {"Location": "http://127.0.0.1:1/elsewhere"}, 0.0, False
    if scenario == "rate_limit_ok":
        if n == 1:
            return err(429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit.",
                       {"retry-after": "1"})
        return ok()
    if scenario == "rate_limit_noheader_ok":
        if n == 1:
            return err(429, "rate_limit_error", "rate limited")
        return ok()
    if scenario == "rate_limit_always":
        return err(429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit.",
                   {"retry-after": "1"})
    if scenario == "overloaded_ok":
        if n == 1:
            return err(529, "overloaded_error", "Overloaded")
        return ok()
    if scenario == "overloaded_always":
        return err(529, "overloaded_error", "Overloaded")
    if scenario == "server500_ok":
        if n == 1:
            return err(500, "api_error", "Internal server error")
        return ok()
    if scenario == "status408_ok":
        if n == 1:
            return err(408, "request_timeout", "Request timeout")
        return ok()
    if scenario == "fallbacks400_a":   # le serveur ne connaît pas le champ
        if has_fb:
            return err(400, "invalid_request_error", "fallbacks: Extra inputs are not permitted")
        return ok()
    if scenario == "fallbacks400_b":   # le serveur refuse l'en-tête bêta
        if has_fb:
            return err(400, "invalid_request_error",
                       "Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header.")
        return ok()
    if scenario == "credit400":        # compte sans crédit : l'API répond parfois 400 plutôt que 402
        return err(400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API. "
                   "Please go to Plans & Billing to upgrade or purchase credits.")
    if scenario == "rate_limit_cap_ok":  # retry-after énorme : l'attente est plafonnée (réglée à 1 s par le test)
        if n == 1:
            return err(429, "rate_limit_error", "rate limited", {"retry-after": "120"})
        return ok()
    if scenario == "overloaded_retry_after_ok":
        if n == 1:
            return err(529, "overloaded_error", "Overloaded", {"retry-after": "2"})
        return ok()
    if scenario == "bad_gateway_html_ok":   # 502 d'un proxy : corps HTML, pas du JSON
        if n == 1:
            return 502, RawBody("text/html", b"<html><body><h1>502 Bad Gateway</h1></body></html>"), {}, 0.0, False
        return ok()
    if scenario == "html200":          # portail Wi-Fi : 200 avec une page HTML
        return 200, RawBody("text/html", "<html><body>Connexion au Wi-Fi requise</body></html>".encode("utf-8")), {}, 0.0, False
    if scenario == "empty_content":
        return 200, api_message(model, None, with_thinking=False), {}, 0.0, False
    if scenario == "context_window":
        return 200, api_message(model, None, stop_reason="model_context_window_exceeded", with_thinking=False), {}, 0.0, False
    if scenario == "split_text":       # le JSON arrive en plusieurs blocs texte (coupés n'importe où)
        text = reply_json(kind, body)
        cut = max(1, len(text) // 3)
        return 200, api_message(model, None, texts=[text[:cut], text[cut:2 * cut], text[2 * cut:]]), {}, 0.0, False
    if scenario == "fallback_block":   # reprise côté serveur après un refus : bloc « fallback » avant le texte
        text = reply_json(kind, body)
        marker = {"type": "fallback", "from": {"model": model}, "to": {"model": "claude-opus-4-8"}}
        msg = api_message("claude-opus-4-8", text, before=[marker])
        msg["usage"]["iterations"] = [{"type": "message", "input_tokens": 1800, "output_tokens": 0},
                                      {"type": "fallback_message", "input_tokens": 1800, "output_tokens": 320}]
        return 200, msg, {}, 0.0, False
    if scenario == "refusal":
        return 200, api_message(model, None, stop_reason="refusal", with_thinking=False,
                                stop_details={"type": "refusal", "category": "cyber", "explanation": None}), {}, 0.0, False
    if scenario == "refusal_partial":
        return 200, api_message(model, '{"zones":[{"numero":1,"type":"mot","te', stop_reason="refusal",
                                stop_details={"type": "refusal", "category": None, "explanation": None}), {}, 0.0, False
    if scenario == "max_tokens_ok":
        if n == 1:
            return ok(truncated=True)
        return ok()
    if scenario == "max_tokens_always":
        return ok(truncated=True)
    if scenario == "ping_max_tokens":
        return 200, api_message(model, None, stop_reason="max_tokens", out_tokens=16), {}, 0.0, False
    if scenario == "invalid_json":
        return 200, api_message(model, "Voici mes réponses : zone 1 = mot, zone 2 = autre mot."), {}, 0.0, False
    if scenario == "bad_shape":
        return 200, api_message(model, json.dumps({"zones": "oops"})), {}, 0.0, False
    if scenario == "no_zones":
        return 200, api_message(model, json.dumps({"zones": [{"numero": 777, "type": "mot", "texte": "x"}]})), {}, 0.0, False
    if scenario == "fenced_json":
        text = "```json\n" + completion_json(body) + "\n```" if kind == "complete" else humanize_json(body)
        return 200, api_message(model, text), {}, 0.0, False
    if scenario in ("slow", "slow_timeout"):
        status, payload, h, _d, c = ok()
        return status, payload, h, 25.0, c
    if scenario == "drop_ok":
        if n == 1:
            return 0, None, {}, 0.0, True
        return ok()
    if scenario == "stale_ok":        # répond normalement, puis ferme la connexion sans prévenir (connexion périmée)
        return 200, success(kind, model, body), {}, 0.0, "after"
    if scenario == "truncated_body_ok":   # la connexion tombe au milieu de la réponse
        if n == 1:
            return 200, success(kind, model, body), {}, 0.0, "body"
        return ok()
    return err(400, "invalid_request_error", "MOCK : scénario inconnu %r" % scenario)


# --------------------------------------------------------------------------------------------------
# Serveur HTTP
# --------------------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Anthropic-Mock/1.0"

    def log_message(self, fmt, *args):  # silencieux : le journal est tenu à la main
        pass

    def send_json(self, status, obj, headers=None):
        content_type = "application/json"
        if isinstance(obj, RawBody):
            data, content_type = obj.data, obj.content_type
        else:
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("request-id", rand_id("req_011C"))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/_ping":
            return self.send_json(200, {"ok": True})
        m = re.fullmatch(r"/_report/([A-Za-z0-9_-]+)", path)
        if m:
            with INSTANCES_LOCK:
                inst = INSTANCES.get(m.group(1))
            if inst is None:
                return self.send_json(404, {"error": "instance inconnue"})
            with inst.lock:
                return self.send_json(200, {"requests": inst.count, "max_inflight": inst.max_inflight,
                                            "errors": list(inst.errors), "calls": list(inst.calls)})
        return self.send_json(404, api_error("not_found_error", "Not found"))

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/_quit":
            self.send_json(200, {"bye": True})
            threading.Thread(target=SERVER.shutdown, daemon=True).start()
            return
        m = ROUTE.fullmatch(path)
        if m:
            scenario, name = m.group(1), m.group(2)
        elif path == "/v1/messages":
            scenario = re.sub(r"[^a-z0-9_]", "", (self.headers.get("x-mock-scenario") or "ok").lower()) or "ok"
            name = re.sub(r"[^A-Za-z0-9_-]", "", self.headers.get("x-mock-instance") or "default") or "default"
        else:
            return self.send_json(404, api_error("not_found_error", "Unknown endpoint %s" % path))
        inst = get_instance(name, scenario)
        try:
            length = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            length = -1
        if length < 0:
            return self.send_json(411, api_error("invalid_request_error", "Content-Length requis"))
        raw = self.rfile.read(length)
        headers = {k.lower(): v for k, v in self.headers.items()}

        with inst.lock:
            inst.count += 1
            n = inst.count
            inst.inflight += 1
            inst.max_inflight = max(inst.max_inflight, inst.inflight)
            t = time.monotonic() - inst.t0
        try:
            errs, body, info = validate(headers, raw, scenario, n)
            kind, model = info["kind"], info["model"] or "claude-opus-5-5"
            if errs or body is None:
                status, payload, extra, delay, drop = (
                    400, api_error("invalid_request_error", "MOCK : requête non conforme (voir le rapport du mock)"), {}, 0.0, False)
            else:
                status, payload, extra, delay, drop = plan(scenario, n, kind, model, body)
            image_file = None
            if info.get("image_bytes") is not None and IMAGES_DIR:
                image_file = os.path.join(IMAGES_DIR, "%s-%d.jpg" % (name, n))
                try:
                    with open(image_file, "wb") as f:
                        f.write(info["image_bytes"])
                except OSError:
                    image_file = None
            # Empreinte de la clé reçue, seulement pour la fausse clé du test (« CANARI ») : le test vérifie ainsi
            # que la clé part intacte, sans que le mock ne garde jamais une vraie clé ni même son empreinte.
            key = headers.get("x-api-key", "")
            key_fp = hashlib.sha256(key.encode("utf-8")).hexdigest()[:8] if key.startswith("sk-ant-api03-CANARI") else "?"
            if DUMP_DIR and body is not None:
                dump_request(os.path.join(DUMP_DIR, "%s-%d.json" % (name, n)), headers, body)
            record = {
                "n": n, "t": round(t, 3), "status": status if not drop else 0, "kind": kind, "model": info["model"],
                "max_tokens": info["max_tokens"], "has_image": info["has_image"], "image_count": info.get("image_count", 0), "fallbacks": info["fallbacks"],
                "image": info["image"], "image_file": image_file, "system": info["system"],
                "user_text": info["user_text"], "schema": info["schema"], "errors": errs, "key_fp": key_fp,
                "anthropic_beta": headers.get("anthropic-beta"), "body_bytes": len(raw),
                "body_sha": hashlib.sha256(raw).hexdigest()[:16], "peer": self.client_address[1],
            }
            with inst.lock:
                inst.calls.append(record)
                for e in errs:
                    inst.errors.append("requête %d : %s" % (n, e))
            log("inst=%s scenario=%s n=%d kind=%s model=%s status=%s ecarts=%d" % (
                name, scenario, n, kind, info["model"], record["status"], len(errs)))

            if delay > 0:
                time.sleep(delay)
            if drop == "after":  # réponse normale, puis fermeture silencieuse de la connexion
                self.send_json(status, payload, extra)
                self.close_connection = True
                return
            if drop == "body":  # annonce un long corps, n'en envoie que le début, puis coupe
                data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data) + 4000))
                    self.end_headers()
                    self.wfile.write(data[:len(data) // 2])
                    self.wfile.flush()
                except OSError:
                    pass
                self.close_connection = True
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                return
            if drop:  # coupe la connexion sans répondre
                self.close_connection = True
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                return
            self.send_json(status, payload, extra)
        finally:
            with inst.lock:
                inst.inflight -= 1


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64
    allow_reuse_address = True


def watch_parent():
    """Se termine si le programme de test disparaît (pas de serveur orphelin)."""
    parent = os.getppid()
    while True:
        time.sleep(1.0)
        if os.getppid() != parent:
            os._exit(0)


def main():
    global OUT_DIR, IMAGES_DIR, DUMP_DIR, LOG_FILE, SERVER
    args = sys.argv[1:]
    if not args or not args[0].isdigit():
        sys.stderr.write("usage : claude_mock.py PORT [--out DOSSIER] [--images DOSSIER] [--dump DOSSIER]\n")
        return 2
    port = int(args[0])
    if "--out" in args:
        OUT_DIR = args[args.index("--out") + 1]
        os.makedirs(OUT_DIR, exist_ok=True)
        LOG_FILE = os.path.join(OUT_DIR, "mock.log")
        open(LOG_FILE, "w").close()
    if "--images" in args:
        IMAGES_DIR = args[args.index("--images") + 1]
        os.makedirs(IMAGES_DIR, exist_ok=True)
    if "--dump" in args:
        DUMP_DIR = args[args.index("--dump") + 1]
        os.makedirs(DUMP_DIR, exist_ok=True)
    SERVER = Server(("127.0.0.1", port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=SERVER.shutdown, daemon=True).start())
    threading.Thread(target=watch_parent, daemon=True).start()
    try:
        SERVER.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        SERVER.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
