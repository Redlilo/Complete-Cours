#!/usr/bin/env python3
"""Faux serveur « API Messages » pour SchemaEngine. Usage : mock.py PORT DOSSIER
POST /<scenario>/v1/messages : enregistre le corps reçu dans DOSSIER/<scenario>.json (sans la clé ; la clé est notée dans
DOSSIER/<scenario>.headers seulement sous forme d'indicateur) et répond selon le scénario."""
import json, sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]
GOOD = {"largeurGrille": 99, "hauteurGrille": 99, "remarque": "ok",
        "symboles": [{"id": "Q1", "type": "disjoncteur", "x": 3, "y": 4, "rotation": 0, "label": "Q1"},
                     {"id": "H1", "type": "lampe", "x": 3, "y": 8, "rotation": 0, "label": "H1"}],
        "fils": [{"de": "Q1.b", "vers": "H1.a", "via": []}], "textes": [{"texte": "L1", "x": 1, "y": 1}]}

def ok(text, stop="end_turn"):
    return 200, {"id": "msg_x", "type": "message", "role": "assistant", "stop_reason": stop,
                 "content": [{"type": "text", "text": text}]}, {}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); raw = self.rfile.read(n)
        scenario = self.path.strip("/").split("/")[0]
        body = json.loads(raw)
        with open(os.path.join(OUT, scenario + ".json"), "w") as f: json.dump(body, f)
        with open(os.path.join(OUT, scenario + ".count"), "a") as f: f.write("x")
        with open(os.path.join(OUT, scenario + ".headers"), "w") as f:
            json.dump({"version": self.headers.get("anthropic-version"), "has_key": bool(self.headers.get("x-api-key")),
                       "beta": self.headers.get("anthropic-beta")}, f)
        j = json.dumps(GOOD)
        table = {
            "ok": ok(j), "fenced": ok("```json\n" + j + "\n```"), "noisy": ok("Voici le schéma :\n" + j + "\nBonne chance !"),
            "truncated": ok(j[:60]),
            "unknown": ok(json.dumps(dict(GOOD, symboles=GOOD["symboles"] + [{"id": "Z9", "type": "fusee", "x": 5, "y": 5, "rotation": 0, "label": ""}],
                                          fils=GOOD["fils"] + [{"de": "Z9.a", "vers": "Q1.a", "via": []}]))),
            "hors": ok(json.dumps(dict(GOOD, symboles=[{"id": "Q1", "type": "disjoncteur", "x": 70, "y": 4, "rotation": 0, "label": "Q1"}], fils=[{"de": "Q1.zzz", "vers": "4,4", "via": []}]))),
            "refusal": ok("", "refusal"),
            "auth401": (401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key sk-ant-SECRETSECRET"}}, {}),
            "rate429": (429, {"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}, {"retry-after": "0"}),
        }
        status, obj, headers = table.get(scenario, (404, {"error": {"message": "?"}}, {}))
        data = json.dumps(obj).encode()
        self.send_response(status); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in headers.items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
