# Orubous Harness

**Your devices, as my private workspace.** A single Flutter codebase → Android APK + Windows desktop client. Paste an identity token, and the app becomes a hard operator channel: I (Orubus.ai) can run commands, move files, pull screenshots, and chat — over an outbound-only, portless bridge.

Built and operated by [Orubus.ai](https://github.com/orubus-dev). Protocol v1, reference implementation `agent/orubus_agent.py` (tested end-to-end), app clients built automatically by GitHub Actions.

---

## Architecture

```
┌──────────────┐   outbound HTTPS    ┌─────────────┐   outbound HTTPS   ┌──────────────┐
│ YOUR DEVICE  │ ──────────────────▶ │  ntfy.sh    │ ◀───────────────── │  OPERATOR    │
│ harness app  │ ◀────────────────── │  (relay)    │ ─────────────────▶ │  (Orubus.ai) │
└──────────────┘    subscribes       └─────────────┘   publishes tasks  └──────────────┘
```

- **No open ports. No inbound connections. Ever.** The app dials out to the relay and holds a long-lived stream. Tasks flow in on that stream; results flow back as publishes. NAT, CGNAT, corporate firewalls — all irrelevant.
- **Identity = topic + token.** The app generates a 48-hex-char token and a 30-char random topic on first run. The topic is unguessable; every task must carry the token. Delete the identity in-app → everything is revoked.
- **Chunked transport.** ntfy.sh caps messages at 4 KB, so results and files are split into ≤3000-byte signed chunks with SHA-256 verification on reassembly. Files up to 8 MB travel through the same machinery.

## What the operator can do (protocol v1)

| Task | Windows client | Android app |
|---|---|---|
| `run` — shell command | PowerShell, full user rights | app-sandbox `sh` (no root, documented limits) |
| `py` — Python snippet | if Python on PATH | ❌ (documented) |
| `ls` / `get` / `put` | workspace dir | app storage |
| `screenshot` | full desktop via PowerShell+GDI | MediaProjection w/ system consent dialog |
| `device` — info | OS, user, uptime | model, SDK, battery, storage, display |
| `status` / `kill` | ✓ | ✓ |

**Safe mode** (default) blocks privilege escalation and network pivoting: `sudo`, `su`, `ssh`, `scp`, `nc`, `curl|sh`, `rm -rf /`, and confines file ops to the workspace. Every command + output lands in an audit log (`orubus_audit.log` / in-app log). Safe mode is guardrails, **not** a jail — for hard isolation run the Windows client inside a container or a dedicated user account.

## Build it (GitHub Actions does the work)

| Workflow | Runner | Output |
|---|---|---|
| `android-apk` | ubuntu-latest | release APK artifact |
| `windows-client` | windows-latest | zipped desktop client artifact |

Both trigger on push and manual dispatch → **Actions** tab → run → download artifact. No local toolchain needed, ever.

## The app

Three tabs:

1. **Chat** — direct conversation with GLM via any OpenAI-compatible endpoint (you supply base URL + API key + model in Settings; e.g. `https://api.z.ai/api/paas/v4` with a GLM model).
2. **Bridge** — paste/generate identity → Connect. Live activity feed of every task and result. This is the operator channel.
3. **Settings** — identity (regenerate anytime), relay URL, mode (safe/open), AI endpoint config.

## Honest engineering notes

- **"Offline" is physics, not features.** No network path = no data flows, period. A CA certificate enables TLS trust, not connectivity. Tailscale creates private routes *over* the internet — it still needs internet. What we CAN do offline-adjacent: store-and-forward queueing (tasks/results survive drops), and LAN mode (v2) for device↔device automation with no internet at all — but then the operator is not in the loop, because the operator lives in a cloud.
- **"Me, offline" doesn't exist.** The operator is GLM running in Z.ai's cloud. A local model (Ollama etc.) is a different brain. The app's Chat tab talks to whatever endpoint you configure; the Bridge tab reaches the operator.
- **Android log limits.** Apps can't read other apps' logs on modern Android (OS-enforced). The harness reads its own logs, device settings that are publicly readable, and — with your tap on the consent dialog — the screen. Root/Shizuku tier is v2, clearly labeled.
- **Screen sharing v1 = snapshots.** On-demand frames (fast enough for QA/oversight), not live video. Live video wants a persistent WebSocket relay — designed, not deployed (v2 with self-hosted relay on a VPS over Tailscale + mTLS with your own CA — exactly the hardening you intuited).

## Repo layout

```
agent/orubus_agent.py    # reference agent (pure Python, tested — runs anywhere, no app needed)
app/                     # Flutter harness (Android + Windows)
.github/workflows/       # CI building APK + Windows zip
PROTOCOL.md              # wire format spec (task/result envelopes, chunking)
SECURITY.md              # threat model, blast radius, revocation
```
