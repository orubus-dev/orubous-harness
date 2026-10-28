# Orubous Bridge Protocol — v1

Transport: [ntfy.sh](https://ntfy.sh) pub/sub over HTTPS. All messages are JSON strings published to a private topic. Both sides are outbound-only clients.

## Identity

- `topic`: `orubus-` + 24 random hex chars. Channel name is the first factor.
- `token`: 48–56 random hex chars. Must be present in every envelope. Second factor.

## Message envelope — operator → device (task)

```json
{"type": "task", "token": "<token>", "task_id": "op-<epoch>", "kind": "<kind>", ...}
```

| kind | extra fields | semantics |
|---|---|---|
| `run` | `cmd`, optional `timeout` (s, ≤600) | shell command, `cwd` = workspace |
| `py` | `code`, optional `timeout` | `python -c <code>` |
| `ls` | `path` (workspace-relative) | directory listing, ≤200 entries |
| `get` | `path` | file → result with base64 `b64`, `sha256`, `size` (≤8 MB) |
| `put` | `name`, `data` (b64), `part`, `of`, `sha256` | chunked upload, sha256-verified on final part |
| `status` | — | agent info |
| `screenshot` | — | capture screen → PNG via `get`-style result (path in `out`) |
| `device` | — | platform info (model, battery, storage…) |
| `kill` | — | agent exits after acking |

## Message envelope — device → operator (result)

Results are JSON-serialized to a string, split into ≤3000-byte chunks (ntfy free tier caps messages at 4096 bytes), and published as:

```json
{"type": "result", "token": "<token>", "task_id": "<id>", "part": 1, "of": 3, "data": "<chunk>"}
```

Reassembly: concatenate `data` for `part` 1..`of` in order → `json.loads` → payload:

```json
{"ok": true|false, "rc": 0, "out": "stdout+stderr (≤200KB, truncated if larger)", ...}
```

`get`/`screenshot` results add: `b64`, `sha256`, `size`, `name`.

## Rules of engagement

1. **Devices only process `type == "task"`.** Everything else (their own result echoes, hello) is ignored — prevents self-echo feedback loops. This rule was learned the hard way: without it, the agent answers its own results forever.
2. **Operators match results on `task_id` + `type == "result"` + token.** Discard everything else.
3. Chunk publishes are spaced ≥650 ms (ntfy free-tier rate limiting). On HTTP 429: exponential backoff, max 5 tries.
4. Subscribe stream: `GET {base}/{topic}/json?since=10m` — reconnect with dedupe by ntfy message `id` (persisted seen-set).
5. Publishes that fail 5× are dropped and logged in the audit trail — the operator sees a timeout, not a lie.

## Reference implementations

- `agent/orubus_agent.py` — Python (Windows/macOS/Linux), stdlib + requests
- `app/lib/bridge/engine.dart` — Dart (Flutter), Android + Windows clients
- Operator side: `laptop_ctl.py` in the operator sandbox (status/run/py/ls/put/get)

Wire compatibility across all three is a test requirement, not an aspiration.

---

# v1.1 — the direct line + skills + device access

## Pairing (30-minute window)

The device generates `topic` + `token` locally and shows the paste-string:

```
ORUBUS-LINK1 topic=<topic> token=<token>
```

The user pastes it to the operator (Discord/web chat). The operator registers it
(`server/link_ctl.py pair`) and connects. If the operator does not connect within
**30 minutes** of generation, the device UI flags the window as closed and the
user regenerates. Once the operator answers on the channel, pairing is complete
and the identity stays valid until revoked.

## Operator → device: chat

```json
{"type": "chat", "token": "<token>", "from": "orubus", "text": "..."}
```

Renders in the app's Chat tab. No API, no key — the operator IS the endpoint.

## Device → operator: chat

```json
{"type": "chat", "token": "<token>", "from": "device", "text": "..."}
```

## New task kinds (operator → device)

| kind | extra fields | semantics |
|---|---|---|
| `skills` | — | list installed skill packs |
| `skill_install` | `skill`, `name`, `data` (b64), `part`, `of`, `sha256` | chunked upload into `<workspace>/skills/<skill>/<name>` |
| `grant` | `perms: [android.permission.…]` | fire runtime permission dialogs; result = granted map |
| `special` | `which: overlay\|write_settings\|usage\|install\|notifications\|accessibility\|battery\|app_details` | deep-link the matching system panel |
| `openurl` | `url` | open in browser (updates, releases) |
| `location` / `contacts` / `calls` / `sms` / `apps` / `calendar` / `net` / `wifi` / `clipboard` / `accounts` / `notifications` | — | permission-gated readers (admin flavor); Windows: `net`, `clipboard`, `apps` fallbacks |
| `send_sms` | `to`, `body` | send an SMS (SEND_SMS granted) |

Every reader answers `{"ok": false, "out": "PERMISSION REQUIRED: …"}` when its
permission is missing — honest refusal, never a crash, never a silent empty set.
