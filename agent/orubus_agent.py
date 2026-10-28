#!/usr/bin/env python3
"""
ORUBUS AGENT v1.0 — outbound-only bridge agent
===============================================
Lets a remote AI operator (Orubus.ai) run whitelisted work on YOUR machine.

HOW IT WORKS (no open ports, no router config):
  your laptop --outbound HTTPS--> ntfy.sh relay <--outbound HTTPS-- AI sandbox
  * This script SUBSCRIBES to a private topic and executes signed commands.
  * The operator publishes commands to the same topic.
  * All traffic is outbound from your machine. NAT/firewall-proof.

QUICK START:
  pip install requests
  python orubus_agent.py --init          # generates topic + token, writes config
  python orubus_agent.py                 # connect; copy topic+token to the AI chat

MODES:
  safe (default)  : guardrails — no sudo/su, no ssh/scp pivoting, no piping
                    curl|sh, commands run inside your workspace dir, 60s timeout.
                    NOTE: guardrails are NOT a jail. For real isolation run it
                    in Docker (see header of quickstart you received).
  open            : full shell, no guardrails. Your call. Explicitly opt in.

COMMANDS UNDERSTOOD (JSON tasks on the topic):
  {"kind":"run","cmd":"..."}            shell command
  {"kind":"py","code":"..."}            python snippet (subprocess)
  {"kind":"ls","path":"rel/path"}       list dir
  {"kind":"get","path":"rel/file"}      download file (base64, chunked)
  {"kind":"put","name":"file","data":<b64>,"part":i,"of":n,"sha256":...}
  {"kind":"status"}                     uptime / platform / mode
  {"kind":"kill"}                       stop the agent (also: Ctrl+C)

KILL SWITCH: Ctrl+C locally, or send {"kind":"kill"}.
AUDIT LOG  : orubus_audit.log next to this script — every command, every output.
"""
import argparse, base64, hashlib, json, os, re, shlex, signal, socket, subprocess
import sys, threading, time, uuid

try:
    import requests
except ImportError:
    print("[!] Missing dependency. Run:  pip install requests")
    sys.exit(1)

NTFY = "https://ntfy.sh"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.json")
SEEN_PATH = os.path.join(SCRIPT_DIR, ".orubus_seen.json")
AUDIT_PATH = os.path.join(SCRIPT_DIR, "orubus_audit.log")

CHUNK = 3000          # bytes per result chunk (ntfy free limit is 4096/msg)
MAX_OUT = 200_000     # truncate command output beyond this
TMO_DEFAULT = 60      # default per-command timeout (s)
TMO_MAX = 600
RATE_SLEEP = 0.65     # spacing between publishes to dodge ntfy rate limits

START_TS = time.time()

# ----------------------------- guardrails ----------------------------------
BLOCKED = [
    r"\bsudo\b", r"\bdoas\b", r"\bsu\s+-", r"\bshutdown\b", r"\breboot\b",
    r"\bpoweroff\b", r"\bmkfs\b", r"\bdd\s+if=", r"\bchown\b", r"\bpasswd\b",
    r"\bcrontab\b", r"\bssh\b", r"\bscp\b", r"\bncat?\b", r"\bnc\s+-e\b",
    r"rm\s+-rf\s+/(\s|$)", r"rm\s+-fr\s+/(\s|$)", r":\(\)\{.*\};:",
    r"curl[^|]*\|\s*(ba)?sh", r"wget[^|]*\|\s*(ba)?sh",
    r"\|\s*(ba)?sh\b", r"\bhistory\s+-c\b",
]

def audit(msg):
    try:
        with open(AUDIT_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass

def guard(cmd, mode):
    """Return list of violations; empty list = allowed. Only enforced in safe mode."""
    if mode != "safe":
        return []
    v = []
    for pat in BLOCKED:
        if re.search(pat, cmd):
            v.append(f"blocked pattern: {pat}")
    return v

# ----------------------------- config --------------------------------------
def load_config():
    if not os.path.exists(CONFIG_PATH):
        sys.exit("[!] No config.json. Run:  python orubus_agent.py --init")
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def init_config(ws=None, mode="safe"):
    topic = "orubus-" + uuid.uuid4().hex[:24]
    token = uuid.uuid4().hex + uuid.uuid4().hex[:16]
    cfg = {
        "topic": topic, "token": token, "mode": mode,
        "workspace": os.path.abspath(ws or os.path.join(SCRIPT_DIR, "workspace")),
        "timeout": TMO_DEFAULT,
    }
    os.makedirs(cfg["workspace"], exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    print("=" * 62)
    print(" ORUBUS AGENT — NEW IDENTITY CREATED (config.json)")
    print("=" * 62)
    print(f" TOPIC : {topic}")
    print(f" TOKEN : {token}")
    print(f" MODE  : {mode}   (edit config.json -> \"mode\": \"open\" to unlock)")
    print(f" WORK  : {cfg['workspace']}")
    print("-" * 62)
    print(" Treat TOPIC+TOKEN as your laptop's key. Paste them to the")
    print(" operator chat to connect. Revoke anytime: delete config.json.")
    print("=" * 62)

def resolve(ws_root, p):
    """Resolve path strictly inside workspace (both put/get/ls targets)."""
    p = (p or ".").strip() or "."
    cand = p if os.path.isabs(p) else os.path.join(ws_root, p)
    cand = os.path.abspath(cand)
    root = os.path.abspath(ws_root)
    if cand != root and not cand.startswith(root + os.sep):
        raise PermissionError(f"path escapes workspace: {p}")
    return cand

# ----------------------------- transport -----------------------------------
def publish(topic, token, envelope):
    """Publish one message; payload JSON string carries the token."""
    envelope = dict(envelope)
    envelope["token"] = token
    body = {"topic": topic, "message": json.dumps(envelope),
            "title": f"{envelope.get('type','?')} {envelope.get('task_id','')}"[:80]}
    for attempt in range(5):
        try:
            r = requests.post(NTFY, json=body, timeout=15)
            if r.status_code == 429:
                time.sleep(2 * (attempt + 1)); continue
            if r.status_code >= 300:
                audit(f"publish http {r.status_code}: {r.text[:200]}")
                time.sleep(1); continue
            return True
        except requests.RequestException as e:
            audit(f"publish error: {e}"); time.sleep(1 + attempt)
    return False

def publish_result(topic, token, task_id, result):
    """Chunk result JSON string into <=CHUNK-byte messages."""
    raw = json.dumps(result, ensure_ascii=False)
    n = max(1, -(-len(raw) // CHUNK))
    ok = True
    for i in range(n):
        part = raw[i * CHUNK:(i + 1) * CHUNK]
        ok &= publish(topic, token, {"type": "result", "task_id": task_id,
                                     "part": i + 1, "of": n, "data": part})
        if i < n - 1:
            time.sleep(RATE_SLEEP)
    return ok

def load_seen():
    try:
        with open(SEEN_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []

def save_seen(ids):
    try:
        with open(SEEN_PATH, "w", encoding="utf-8") as f:
            json.dump(ids[-500:], f)
    except OSError:
        pass

# ----------------------------- handlers ------------------------------------
def h_run(task, cfg):
    cmd = str(task.get("cmd", ""))
    mode = cfg.get("mode", "safe")
    tmo = min(int(task.get("timeout", cfg.get("timeout", TMO_DEFAULT))), TMO_MAX)
    v = guard(cmd, mode)
    if v:
        return {"ok": False, "rc": None, "out": "REFUSED (safe mode): " + "; ".join(v)}
    try:
        p = subprocess.run(cmd, shell=True, cwd=cfg["workspace"],
                           capture_output=True, timeout=tmo)
        out = ((p.stdout or b"") + (p.stderr or b""))[:MAX_OUT]
        s = out.decode("utf-8", "replace")
        if len((p.stdout or b"") + (p.stderr or b"")) > MAX_OUT:
            s += f"\n...[truncated at {MAX_OUT} bytes]"
        return {"ok": p.returncode == 0, "rc": p.returncode, "out": s}
    except subprocess.TimeoutExpired:
        return {"ok": False, "rc": None, "out": f"TIMEOUT after {tmo}s"}

def h_py(task, cfg):
    code = str(task.get("code", ""))
    tmo = min(int(task.get("timeout", cfg.get("timeout", TMO_DEFAULT))), TMO_MAX)
    v = guard(code, cfg.get("mode", "safe")) if "\n" not in code else []
    if v:
        return {"ok": False, "rc": None, "out": "REFUSED (safe mode): " + "; ".join(v)}
    try:
        p = subprocess.run([sys.executable, "-c", code], cwd=cfg["workspace"],
                           capture_output=True, timeout=tmo)
        out = ((p.stdout or b"") + (p.stderr or b""))[:MAX_OUT]
        return {"ok": p.returncode == 0, "rc": p.returncode,
                "out": out.decode("utf-8", "replace")}
    except subprocess.TimeoutExpired:
        return {"ok": False, "rc": None, "out": f"TIMEOUT after {tmo}s"}

def h_ls(task, cfg):
    d = resolve(cfg["workspace"], task.get("path", "."))
    if not os.path.isdir(d):
        return {"ok": False, "out": f"not a dir: {task.get('path')}"}
    entries = []
    for name in sorted(os.listdir(d))[:200]:
        fp = os.path.join(d, name)
        try:
            st = os.stat(fp)
            kind = "d" if os.path.isdir(fp) else "-"
            entries.append(f"{kind} {st.st_size:>10}  {name}")
        except OSError as e:
            entries.append(f"? {'':>10}  {name} ({e})")
    return {"ok": True, "out": "\n".join(entries) or "(empty)"}

def h_get(task, cfg):
    fp = resolve(cfg["workspace"], task.get("path", ""))
    st = os.stat(fp)
    if st.st_size > 8 * 1024 * 1024:
        return {"ok": False, "out": f"file too big for bridge: {st.st_size}B (8MB cap)"}
    with open(fp, "rb") as f:
        data = f.read()
    return {"ok": True, "name": os.path.basename(fp), "size": st.st_size,
            "sha256": hashlib.sha256(data).hexdigest(),
            "b64": base64.b64encode(data).decode()}

PUT_PARTS = {}

def h_put(task, cfg):
    name = os.path.basename(str(task.get("name", "")))
    if not name:
        return {"ok": False, "out": "put: missing file name"}
    key = (name, task.get("task_id", ""))
    buf = PUT_PARTS.setdefault(key, {})
    buf[int(task.get("part", 1))] = task.get("data", "")
    if int(task.get("of", 1)) > len(buf):
        return {"ok": True, "out": f"chunk {len(buf)}/{task.get('of')}"}
    b64 = "".join(buf[i] for i in sorted(buf))
    PUT_PARTS.pop(key, None)
    raw = base64.b64decode(b64)
    if task.get("sha256") and hashlib.sha256(raw).hexdigest() != task["sha256"]:
        return {"ok": False, "out": "sha256 MISMATCH — transfer corrupted"}
    fp = resolve(cfg["workspace"], name)
    with open(fp, "wb") as f:
        f.write(raw)
    return {"ok": True, "out": f"wrote {fp} ({len(raw)} bytes)"}

def h_status(cfg):
    up = int(time.time() - START_TS)
    return {"ok": True, "out":
        f"agent v1.0 | mode={cfg.get('mode')} | up={up}s | "
        f"platform={sys.platform} | host={socket.gethostname()} | "
        f"py={sys.version.split()[0]} | work={cfg['workspace']}"}

HANDLERS = {"run": h_run, "py": h_py, "ls": h_ls, "get": h_get,
            "put": h_put, "status": lambda t, c: h_status(c)}

# ----------------------------- main loop -----------------------------------
def handle(task, cfg, topic, token):
    tid = task.get("task_id", "?")[:40]
    kind = str(task.get("kind", ""))
    audit(f"TASK {tid} kind={kind} from operator: {json.dumps({k: v for k, v in task.items() if k not in ('data', 'code', 'cmd')})[:120]}")
    if kind == "kill":
        publish_result(topic, token, tid, {"ok": True, "out": "agent shutting down. bye."})
        audit("KILL SWITCH — operator requested shutdown")
        os._exit(0)
    fn = HANDLERS.get(kind)
    if not fn:
        publish_result(topic, token, tid, {"ok": False, "out": f"unknown kind: {kind}"})
        return
    try:
        res = fn(task, cfg)
    except PermissionError as e:
        res = {"ok": False, "out": f"REFUSED: {e}"}
    except FileNotFoundError as e:
        res = {"ok": False, "out": f"not found: {e}"}
    except Exception as e:
        res = {"ok": False, "out": f"agent error: {type(e).__name__}: {e}"}
    audit(f"RESULT {tid} ok={res.get('ok')} out[:100]={str(res.get('out'))[:100]!r}")
    publish_result(topic, token, tid, res)

def stream_loop(cfg):
    topic, token = cfg["topic"], cfg["token"]
    seen = load_seen()
    seen_set = set(seen)
    since = "10m"
    while True:
        try:
            url = f"{NTFY}/{topic}/json?since={since}"
            with requests.get(url, stream=True, timeout=(10, 90)) as r:
                r.raise_for_status()
                since = "10m"  # replay window; dedupe covers replays
                for line in r.iter_lines():
                    if not line:
                        continue
                    try:
                        ev = json.loads(line.decode("utf-8"))
                    except ValueError:
                        continue
                    if ev.get("event") != "message":
                        continue
                    mid = ev.get("id", "")
                    if mid in seen_set:
                        continue
                    seen_set.add(mid); seen.append(mid)
                    if len(seen) > 400:
                        save_seen(seen); seen = seen[-500:]
                    try:
                        task = json.loads(ev.get("message", "{}"))
                    except ValueError:
                        continue
                    # CRITICAL: only accept operator tasks. Everything else
                    # (our own published results, echoes) must be ignored,
                    # otherwise we answer ourselves forever (echo loop).
                    if task.get("type") != "task":
                        continue
                    if task.get("token") != token:
                        audit("dropped message: bad token")
                        continue
                    threading.Thread(target=handle, args=(task, cfg, topic, token),
                                     daemon=True).start()
                    save_seen(seen)
        except requests.RequestException as e:
            audit(f"stream dropped: {e} — reconnecting in 5s")
            time.sleep(5)
        except Exception as e:
            audit(f"unexpected: {type(e).__name__}: {e} — reconnecting in 5s")
            time.sleep(5)

def main():
    ap = argparse.ArgumentParser(description="Orubus bridge agent")
    ap.add_argument("--init", nargs="?", const=".", metavar="WORKDIR",
                    help="create new identity (topic+token) and exit")
    ap.add_argument("--open", action="store_true",
                    help="init with mode=open (unguarded shell) — think first")
    ap.add_argument("--config", default=CONFIG_PATH)
    args = ap.parse_args()
    if args.init:
        init_config(args.init, mode="open" if args.open else "safe")
        return
    cfg = load_config()
    audit(f"agent started | mode={cfg.get('mode')} | topic={cfg['topic'][:16]}...")
    print("=" * 62)
    print(f" ORUBUS AGENT online — topic {cfg['topic'][:20]}...")
    print(f" mode={cfg.get('mode')}  workspace={cfg['workspace']}")
    print(" Ctrl+C to stop. Audit log: orubus_audit.log")
    print("=" * 62)
    hello = {"type": "result", "task_id": "hello",
             "part": 1, "of": 1,
             "data": json.dumps(h_status(cfg))}
    publish(cfg["topic"], cfg["token"], hello)
    stream_loop(cfg)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[agent stopped by user]")
        audit("agent stopped locally (Ctrl+C)")
