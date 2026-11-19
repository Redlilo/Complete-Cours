#!/usr/bin/python3
# Faux programme « claude » pour les tests de ClaudeCodeEngine : aucun réseau, aucun jeton, aucun quota.
#
# Il REFUSE de tourner (code 97) si une variable ANTHROPIC_* / CLAUDE_CODE_* / CLAUDECODE est présente, et (code 96) si
# une option exigée manque : -p, --safe-mode, --tools "", --json-schema, --output-format stream-json, --verbose,
# --input-format stream-json, --no-session-persistence, --disable-slash-commands, --permission-prompts none, --system-prompt.
# Il vérifie aussi que son dossier de travail est vide et qu'il reçoit une ligne JSON {"type":"user",…} sur stdin.
# Le scénario joué est écrit par le test dans $HOME/fake-claude-state/scenario (un nom par appel ou pour toute une série).
# État et journal des appels : $HOME/fake-claude-state/ (calls.log, scenario, logged_in, status_mode, login_mode, started.json).
import json, os, re, signal, subprocess, sys, time

STATE = os.path.join(os.environ.get("HOME", "."), "fake-claude-state")
os.makedirs(STATE, exist_ok=True)


def die(code, message):
    sys.stderr.write(message + "\n")
    sys.stderr.flush()
    sys.exit(code)


def state_text(name, default=""):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


bad = sorted(k for k in os.environ
             if k.startswith("ANTHROPIC_") or k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" or k.startswith("CLAUDE_AGENT_"))
if bad:
    die(97, "variable interdite présente : " + ",".join(bad))

args = sys.argv[1:]

if args == ["--version"]:
    print("2.1.999 (Claude Code)")
    sys.exit(0)

if args[:2] == ["auth", "status"]:
    mode = state_text("status_mode", "normal")
    if mode == "hang":
        time.sleep(60)
    if mode == "garbage":
        print("¯\\_(ツ)_/¯ rien de lisible")
        sys.exit(0)
    if mode == "apikey":
        print(json.dumps({"loggedIn": True, "authMethod": "api_key", "apiProvider": "firstParty"}))
        sys.exit(0)
    if os.path.exists(os.path.join(STATE, "logged_in")):
        print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
                          "email": "eleve@example.com", "subscriptionType": "pro"}, indent=2))
        sys.exit(0)
    print(json.dumps({"loggedIn": False, "authMethod": "none", "apiProvider": "firstParty"}, indent=2))
    sys.exit(1)

if args[:2] == ["auth", "login"]:
    if args != ["auth", "login", "--claudeai"]:
        die(96, "arguments de connexion inattendus : %r" % (args,))
    print("Ouverture du navigateur… SECRET-A-NE-JAMAIS-AFFICHER-12345")
    sys.stdin.read()
    mode = state_text("login_mode", "ok")
    if mode == "ok":
        open(os.path.join(STATE, "logged_in"), "w").close()
        sys.exit(0)
    if mode == "noeffect":
        sys.exit(0)
    if mode == "hang":
        time.sleep(60)
    sys.exit(1)


# ---- Appel « claude -p » -------------------------------------------------------------------------------------------
def option(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def need(cond, what):
    if not cond:
        die(96, "argument attendu absent ou faux : " + what)


need("-p" in args or "--print" in args, "-p")
need("--safe-mode" in args, "--safe-mode")
need("--tools" in args and option("--tools") == "", '--tools ""')
need(option("--output-format") == "stream-json", "--output-format stream-json")
need(option("--input-format") == "stream-json", "--input-format stream-json")
need("--verbose" in args, "--verbose")
need("--no-session-persistence" in args, "--no-session-persistence")
need("--disable-slash-commands" in args, "--disable-slash-commands")
need(option("--permission-prompts") == "none", "--permission-prompts none")
need(bool(option("--system-prompt")), "--system-prompt")
need("--bare" not in args, "pas de --bare")
try:
    schema = json.loads(option("--json-schema") or "")
except ValueError:
    schema = None
need(isinstance(schema, dict) and schema.get("type") == "object", "--json-schema (objet JSON valide)")
need(os.listdir(".") == [], "dossier de travail vide")
need("CompleteCours-ClaudeCode-" in os.getcwd(), "dossier de travail créé par l'app")


def log(**kw):
    with open(os.path.join(STATE, "calls.log"), "a", encoding="utf-8") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")


def count_starts(scn):
    n = 0
    try:
        with open(os.path.join(STATE, "calls.log"), encoding="utf-8") as f:
            for line in f:
                o = json.loads(line)
                if o.get("ev") == "start" and o.get("scn") == scn:
                    n += 1
    except OSError:
        pass
    return n


def init_line():
    emit({"type": "system", "subtype": "init", "session_id": "fake", "tools": ["StructuredOutput"], "model": "fake-model",
          "apiKeySource": "none", "claude_code_version": "2.1.999"})


def result(**kw):
    base = {"type": "result", "subtype": "success", "is_error": False, "result": "", "session_id": "fake",
            "total_cost_usd": 0, "duration_ms": 5, "num_turns": 1, "usage": {}, "stop_reason": "end_turn"}
    base.update(kw)
    emit(base)


def structured_for(text):
    if "Zones à remplir" in text:
        nums = [int(n) for n in re.findall(r"^⟦(\d+)⟧ — ", text, flags=re.M)]
        kinds = ["mot", "definition", "question", "ignorer"]
        zones = []
        for n in nums:
            k = kinds[(n - 1) % 4]
            zones.append({"numero": n, "type": k, "texte": "" if k == "ignorer" else "réponse %d" % n})
        return {"zones": zones}
    a, b = text.find("["), text.rfind("]")
    items = json.loads(text[a:b + 1])
    return {"reponses": [{"id": it["id"], "texte": "Retouché : " + it["reponse"]} for it in items]}


def success(text, via="structured"):
    data = structured_for(text)
    init_line()
    emit({"type": "stream_event", "event": {"type": "ping"}})
    sys.stdout.write("\n")
    emit({"type": "rate_limit_event", "info": {"status": "allowed"}})
    emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "StructuredOutput", "input": data}]}})
    if via == "structured":
        result(structured_output=data)
    elif via == "fence":
        result(result="```json\n" + json.dumps(data, ensure_ascii=False) + "\n```")
    elif via == "prose":
        result(result="Voici la réponse : " + json.dumps(data, ensure_ascii=False) + " — voilà.")
    sys.exit(0)


scn = state_text("scenario", "ok")
log(ev="start", scn=scn, pid=os.getpid(), model=option("--model"), effort=option("--effort"), t=time.time())

# Comme le vrai programme quand on n'est pas connecté : il répond tout de suite, sans lire stdin.
if scn == "notlogged":
    init_line()
    emit({"type": "assistant", "error": "authentication_failed", "is_api_error_message": True,
          "message": {"role": "assistant", "content": [{"type": "text", "text": "Not logged in · Please run /login"}]}})
    result(is_error=True, result="Not logged in · Please run /login", terminal_reason="api_error", stop_reason="stop_sequence")
    sys.exit(1)

# Beaucoup de sortie AVANT de lire stdin : sans lecture continue de stdout et stderr, l'app serait bloquée.
if scn == "bigout":
    sys.stderr.write("e" * (3 * 1024 * 1024) + "\n")
    sys.stderr.flush()
    sys.stdout.write("junk " * (600 * 1024) + "\n")
    sys.stdout.flush()

raw = sys.stdin.buffer.read()
first_line = raw.decode("utf-8", "replace").split("\n")[0]
try:
    msg = json.loads(first_line)
except ValueError:
    die(96, "stdin : la première ligne n'est pas du JSON")
need(msg.get("type") == "user" and msg.get("message", {}).get("role") == "user", "message utilisateur")
blocks = msg["message"]["content"]
text = "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")
log(ev="message", scn=scn, blocks=[b.get("type") for b in blocks], bytes=len(raw), newlines=raw.decode("utf-8", "replace").count("\n"))

if scn in ("ok", "bigout"):
    success(text)
if scn == "fence":
    success(text, via="fence")
if scn == "prose":
    success(text, via="prose")
if scn == "badjson":
    init_line()
    result(result="ceci n'est pas du JSON du tout")
    sys.exit(0)
if scn == "badshape":
    init_line()
    result(structured_output={"autre": 1})
    sys.exit(0)
if scn == "limit":
    init_line()
    result(is_error=True, result="5-hour limit reached ∙ resets 3pm (Europe/Paris)", terminal_reason="api_error")
    sys.exit(1)
if scn == "limit_epoch":
    init_line()
    result(is_error=True, result="Claude AI usage limit reached|%d" % (int(time.time()) + 7200))
    sys.exit(1)
if scn == "limit_plain":
    init_line()
    result(is_error=True, result="You've hit your limit")
    sys.exit(1)
if scn == "overloaded":
    init_line()
    result(is_error=True, result="API Error: 529 Overloaded", api_error_status=529)
    sys.exit(1)
if scn == "structfail":
    init_line()
    result(subtype="error_max_structured_output_retries", is_error=True, result="")
    sys.exit(1)
if scn == "refusal":
    init_line()
    result(stop_reason="refusal", result="")
    sys.exit(0)
if scn == "toolong":
    init_line()
    result(is_error=True, result="Prompt is too long")
    sys.exit(1)
if scn == "weird":
    init_line()
    result(is_error=True, result="Quelque chose d'inattendu s'est produit (sk-ant-abcdef0123456789abcdef) dans /Users/quelquun/x")
    sys.exit(1)
if scn == "oldcli":
    die(1, "error: unknown option '--safe-mode'")
if scn == "exit127":
    die(127, "env: node: No such file or directory")
if scn == "crash":
    init_line()
    die(2, "boum")
if scn == "crash_signal":
    init_line()
    os.kill(os.getpid(), signal.SIGKILL)
if scn == "empty":
    sys.exit(0)
if scn == "truncated":
    sys.stdout.write('{"type":"result","subtype":"succ')
    sys.stdout.flush()
    sys.exit(0)
if scn == "flaky":
    if count_starts("flaky") < 2:
        init_line()
        die(2, "panne passagère")
    success(text)
if scn == "slow":
    time.sleep(1.0)
    log(ev="end", scn=scn, pid=os.getpid(), t=time.time())
    success(text)
if scn == "orphan":
    # Réponse normale, mais un sous-processus reste vivant en gardant stdout et stderr ouverts.
    child = subprocess.Popen(["/bin/sleep", "120"])
    with open(os.path.join(STATE, "started.json"), "w") as f:
        json.dump({"pid": os.getpid(), "child": child.pid}, f)
    time.sleep(0.8)
    success(text)
if scn in ("hang", "hang_child", "ignore_term"):
    if scn == "ignore_term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen(["/bin/sleep", "120"]) if scn != "hang" else None
    with open(os.path.join(STATE, "started.json"), "w") as f:
        json.dump({"pid": os.getpid(), "child": child.pid if child else None}, f)
    time.sleep(120)
    sys.exit(0)
die(96, "scénario inconnu : " + scn)
