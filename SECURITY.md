# SECURITY.md — Orubous Harness threat model

## What this system is

A deliberate, revocable channel that lets a remote AI operator execute commands on devices you own. That is the product. Treat the identity (topic + token) like a house key: whoever holds it, holds the device — within the mode you selected.

## Blast radius by mode

| | safe mode (default) | open mode |
|---|---|---|
| shell | blocked: `sudo`, `su`, `doas`, `ssh`, `scp`, `nc`, `passwd`, `crontab`, `dd if=`, `mkfs`, `rm -rf /`, `curl\|sh`, `wget\|sh`, pipe-to-shell | full user shell |
| file ops | workspace-dir confined (path traversal rejected) | anywhere the user can write |
| timeout | 60 s default / 600 s hard cap | same |
| output | 200 KB cap per result | same |
| files over bridge | 8 MB cap + SHA-256 verify | same |

Safe mode is **guardrails, not a jail**. A determined operator prompt-injected into mischief can still do user-level things shell can do. If that scares you, it should — run the Windows client under a dedicated OS user account or container, and keep Android in safe mode.

## Secrets handling

- Token is generated on-device (crypto-secure RNG), stored in app-private storage / local config file. Never transmitted except inside task/result envelopes to your configured relay.
- Relay (ntfy.sh) sees topics, tokens and payloads in TLS transit. For sensitive fleets, self-host ntfy (Docker one-liner) and point the app at it — config field exists for exactly this.
- Revocation: delete identity in-app (or `config.json` for the Python agent) and restart. Old topic becomes orphaned; nothing can reconnect. Generate a fresh identity in 2 taps.

## Channel hygiene (learned from a real incident)

Pasting a live credential into any chat — even a private one — creates an immutable copy in message history. If a token ever lands in chat: revoke first, apologize later. The harness identity is designed for cheap rotation precisely because credentials in chat are a "when", not an "if".

## Audit

- Python agent: `orubus_audit.log` next to the script — every task, every output head, every kill.
- App: in-UI activity feed + rotating on-device audit file.
- The operator keeps its own transcript. Three independent records; discrepancies are a feature.

## Known limits (not hidden, not fixed by wishful thinking)

- Android: other apps' logs are OS-protected (READ_LOGS is signature-level). Screen capture always shows the system consent dialog — by design, every time.
- ntfy.sh free tier: rate limits + 4 KB messages + transient cache. Not a secrets store, not a message archive.
- No E2E encryption yet: payloads are TLS-protected in transit but plaintext to the relay. mTLS/pinned-CA transport is the v2 relay milestone.
