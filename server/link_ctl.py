#!/usr/bin/env python3
"""
Orubous Harness — operator side (runs in the AI sandbox, like Blender did).

The mirror twin of the app: the app generates a token, the user pastes the
pairing string into the chat, and the operator plugs it in here. Same wire,
same protocol (see PROTOCOL.md v1.1):

    device  ->  ntfy topic  <-  operator

Usage:
  export ORUBUS_PAIR='ORUBUS-LINK1 topic=orubous-xxxx token=yyyy'
  python3 link_ctl.py pair                      # parse + store the pairing
  python3 link_ctl.py chat "hello from my sandbox"
  python3 link_ctl.py poll [--since 30m]        # device chat + task results
  python3 link_ctl.py run "getprop ro.build.version.release"
  python3 link_ctl.py py  "print(1+1)"
  python3 link_ctl.py ls  skills/
  python3 link_ctl.py put <local> <name>
  python3 link_ctl.py get <name> [dest]
  python3 link_ctl.py shot                      # screenshot -> file
  python3 link_ctl.py skill <dir> <name>        # push a SKILL.md pack
  python3 link_ctl.py grant <PERM> [PERM...]    # runtime permission dialogs
  python3 link_ctl.py special <panel>           # open a special-access panel
  python3 link_ctl.py read <what>               # location|contacts|calls|sms|
                                                # apps|calendar|net|wifi|
                                                # clipboard|accounts|notifications
  python3 link_ctl.py status

State: /home/z/my-project/link/pairing.json (+ cursor). Nothing else required.
"""
import base64, hashlib, json, os, sys, time, urllib.request, urllib.error

STATE_DIR = os.environ.get("ORUBUS_STATE", "/home/z/my-project/link")
PAIRING = os.path.join(STATE_DIR, "pairing.json")
CURSOR = os.path.join(STATE_DIR, "cursor.txt")
NTFY = "https://ntfy.sh"
CHUNK = 2400          # publish size for base64 chunks (ntfy free cap 4096)
RATE = 0.65           # spacing between publishes

def _pair():
    if not os.path.exists(PAIRING):
        sys.exit("not paired — run: link_ctl.py pair  (after pasting ORUBUS-LINK1 …)")
    p = json.load(open(PAIRING))
    return p["ntfy"], p["topic"], p["token"]

def _http(url, method="POST", body=None, headers=None, timeout=20):
    req = urllib.request.Request(url, method=method,
                                 data=body.encode() if isinstance(body, str) else body,
                                 headers=headers or {"User-Agent": "orubus-linkd"})
    return urllib.request.urlopen(req, timeout=timeout)

def publish(ntfy, topic, env):
    """Publish one envelope with 429 backoff. Returns True on success."""
    for attempt in range(5):
        try:
            _http(ntfy, body=json.dumps({"topic": topic, "message": json.dumps(env),
                                         "title": f"{env.get('type','?')} {env.get('task_id','')}"[:80]},
                                        ).encode(),
                  headers={"Content-Type": "application/json"})
            return True
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(2 * (attempt + 1)); continue
            print(f"publish HTTP {e.code}", file=sys.stderr); time.sleep(1)
        except Exception as e:
            print(f"publish err: {e}", file=sys.stderr); time.sleep(1 + attempt)
    return False

def send_task(kind, ntfy, topic, token, **fields):
    tid = f"t{int(time.time()*1000)%10**10}"
    env = {"type": "task", "task_id": tid, "kind": kind, "token": token, **fields}
    ok = publish(ntfy, topic, env)
    return tid if ok else None

def wait_result(tid, ntfy, topic, token, timeout=180):
    """Poll JSON stream for result chunks of tid; reassemble + verify."""
    seen, parts = set(), {}
    url = f"{ntfy}/{topic}/json?poll=1&since=10m"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with _http(url, method="GET", timeout=25) as r:
                for line in r.read().decode().splitlines():
                    if not line.strip(): continue
                    try: ev = json.loads(line)
                    except Exception: continue
                    if ev.get("event") != "message": continue
                    mid = ev.get("id")
                    if mid in seen: continue
                    seen.add(mid)
                    try: env = json.loads(ev.get("message", "{}"))
                    except Exception: continue
                    if env.get("type") != "result" or env.get("token") != token: continue
                    if env.get("task_id") != tid: continue
                    parts[int(env.get("part", 1))] = env.get("data", "")
                    if int(env.get("of", 1)) <= len(parts):
                        raw = "".join(parts[i] for i in sorted(parts))
                        try: return json.loads(raw)
                        except Exception: return {"ok": True, "out": raw}
        except Exception:
            pass
        time.sleep(2)
    return {"ok": False, "out": f"TIMEOUT waiting for result {tid}"}

def result_for(kind, ntfy, topic, token, timeout, **fields):
    tid = send_task(kind, ntfy, topic, token, **fields)
    if tid is None:
        return {"ok": False, "out": "publish failed"}
    return wait_result(tid, ntfy, topic, token, timeout)

def read_out(r):
    if r.get("ok"):
        print(r.get("out", "(empty)"))
    else:
        print(f"FAILED: {r.get('out')}", file=sys.stderr)
        sys.exit(1)

def put_file(ntfy, topic, token, local, name, kind="put", skill=None):
    raw = open(local, "rb").read()
    b64 = base64.b64encode(raw).decode()
    sha = hashlib.sha256(raw).hexdigest()
    n = (len(b64) + CHUNK - 1) // CHUNK
    tid = f"t{int(time.time()*1000)%10**10}"
    for i in range(n):
        env = {"type": "task", "task_id": tid, "kind": kind, "name": name,
               "sha256": sha, "part": i + 1, "of": n, "data": b64[i*CHUNK:(i+1)*CHUNK],
               "token": token}
        if skill: env["skill"] = skill
        if not publish(ntfy, topic, env):
            return {"ok": False, "out": f"publish failed on chunk {i+1}/{n}"}
        time.sleep(RATE)
    return wait_result(tid, ntfy, topic, token, 120)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"

    if cmd == "pair":
        os.makedirs(STATE_DIR, exist_ok=True)
        blob = sys.argv[2] if len(sys.argv) > 2 else input("paste ORUBUS-LINK1 string: ").strip()
        blob = blob.replace("`", "").strip()
        kv = dict(kv.split("=", 1) for kv in blob.replace("ORUBUS-LINK1", "").split() if "=" in kv)
        p = {"ntfy": NTFY, "topic": kv["topic"], "token": kv["token"],
             "paired_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
        json.dump(p, open(PAIRING, "w"), indent=1)
        print(f"paired -> topic={p['topic']}  (state: {PAIRING})")
        return

    ntfy, topic, token = _pair()

    if cmd == "chat":
        text = " ".join(sys.argv[2:]) or "(empty)"
        ok = publish(ntfy, topic, {"type": "chat", "from": "orubus", "text": text, "token": token})
        print("sent" if ok else "publish FAILED", file=sys.stderr); return

    if cmd == "poll":
        since = "10m"
        if "--since" in sys.argv:
            since = sys.argv[sys.argv.index("--since") + 1]
        cursor = open(CURSOR).read().strip() if os.path.exists(CURSOR) else since
        url = f"{ntfy}/{topic}/json?poll=1&since={cursor}"
        seen_ids, cursor_new = set(), None
        with _http(url, method="GET", timeout=30) as r:
            for line in r.read().decode().splitlines():
                if not line.strip(): continue
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get("event") != "message": continue
                mid = ev.get("id")
                if mid in seen_ids: continue
                seen_ids.add(mid)
                cursor_new = mid
                try: env = json.loads(ev.get("message", "{}"))
                except Exception: continue
                if env.get("token") != token: continue
                t = env.get("type")
                if t == "chat":
                    frm = env.get("from", "device")
                    print(f"[{ev.get('time')}] CHAT {frm}: {env.get('text','')}")
                elif t == "result":
                    data = env.get("data", "")
                    print(f"[{ev.get('time')}] RESULT {env.get('task_id')}: {data[:2000]}")
                elif t == "task":
                    print(f"[{ev.get('time')}] (our own task echo — ignored)")
        if cursor_new:
            open(CURSOR, "w").write(cursor_new)
        return

    if cmd == "run":
        read_out(result_for("run", ntfy, topic, token, 300, cmd=" ".join(sys.argv[2:])))
    elif cmd == "py":
        read_out(result_for("py", ntfy, topic, token, 300, code=sys.argv[2]))
    elif cmd == "ls":
        read_out(result_for("ls", ntfy, topic, token, 60, path=sys.argv[2] if len(sys.argv) > 2 else "."))
    elif cmd == "skills":
        read_out(result_for("skills", ntfy, topic, token, 60))
    elif cmd == "skill":
        d, skill = sys.argv[2], sys.argv[3]
        for root, _, files in os.walk(d):
            for f in files:
                fp = os.path.join(root, f)
                rel = os.path.relpath(fp, d).replace("\\", "/")
                r = put_file(ntfy, topic, token, fp, rel, kind="skill_install", skill=skill)
                read_out(r)
    elif cmd == "put":
        read_out(put_file(ntfy, topic, token, sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else os.path.basename(sys.argv[2])))
    elif cmd == "get":
        r = result_for("get", ntfy, topic, token, 180, path=sys.argv[2])
        if not r.get("ok"): read_out(r)
        raw = base64.b64decode(r["b64"])
        if r.get("sha256") != hashlib.sha256(raw).hexdigest():
            sys.exit("sha256 MISMATCH on get")
        dest = sys.argv[3] if len(sys.argv) > 3 else r.get("name", "fetched.bin")
        open(dest, "wb").write(raw)
        print(f"saved {dest} ({len(raw)} bytes, sha verified)")
    elif cmd == "shot":
        r = result_for("screenshot", ntfy, topic, token, 180)
        if not r.get("ok"): read_out(r)
        raw = base64.b64decode(r["b64"])
        dest = sys.argv[2] if len(sys.argv) > 2 else f"shot_{int(time.time())}.png"
        open(dest, "wb").write(raw)
        print(f"saved {dest} ({len(raw)} bytes)")
    elif cmd == "grant":
        read_out(result_for("grant", ntfy, topic, token, 120, perms=sys.argv[2:]))
    elif cmd == "special":
        read_out(result_for("special", ntfy, topic, token, 30, which=sys.argv[2]))
    elif cmd == "read":
        read_out(result_for(sys.argv[2], ntfy, topic, token, 60,
                            **({"to": sys.argv[3], "body": sys.argv[4]}
                               if sys.argv[2] == "send_sms" else {})))
    elif cmd == "status":
        tid = send_task("status", ntfy, topic, token)
        if tid is None: sys.exit("publish failed")
        read_out(wait_result(tid, ntfy, topic, token, 45))
    else:
        print(__doc__); sys.exit(2)

if __name__ == "__main__":
    main()
