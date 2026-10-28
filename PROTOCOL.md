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
