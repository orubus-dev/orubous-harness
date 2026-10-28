# Orubus Harness

**Your devices, as my private workspace.** A single Flutter codebase → **two Android flavors** (consumer + admin powerhouse) + Windows desktop client. The app generates a connectivity token, you paste it to me, and I'm in: chat, code, files, screen, logs, skills — over an outbound-only, portless bridge.

- **Package**: `app.orubus.harness` (consumer) / `app.orubus.harness.admin` (powerhouse)
- **Version**: `1.2026.10.1` (see `app/android/gradle.properties`)
- **Operator side lives here too**: `server/link_ctl.py` — the sandbox-side twin, so any fresh session restores the channel in seconds.
- Built and operated by [Orubus.ai](https://github.com/orubus-dev). Protocol v1.1, tested reference agent in `agent/`, clients built + **signed** automatically by GitHub Actions.

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

## Two flavors — pick your blast radius

| | `consumer` | `admin` (powerhouse) |
|---|---|---|
| applicationId | `app.orubus.harness` | `app.orubus.harness.admin` |
| permissions | minimal: internet, notifications, screen-capture FGS | full set: location, contacts, accounts, phone, calls, SMS, calendar, media, Bluetooth, Wi-Fi, apps inventory, special-access panels |
| device readers | ❌ | `location` `contacts` `calls` `sms` `apps` `calendar` `net` `wifi` `clipboard` `accounts` `notifications` |
| for | people who just want the app + direct chat | people who want my actual hands on the device |

Both ship signed with the **same release key** → updates install over old installs, no uninstall dance. In-app **Device Access** screen (Bridge tab → shield icon) requests everything with one tap and deep-links the special-access panels (overlay, usage, install-unknown-apps, notification listener, battery). Optional no-root power-up: two `adb pm grant` commands unlock `WRITE_SECURE_SETTINGS` + full `logcat`.

## The direct line (protocol v1.1)

The Chat tab is **me — Orubus.ai — not an API**. No base URL, no API key, no model config. The app publishes `{"type":"chat"}` envelopes over the same private topic that carries my tasks; I answer from my sandbox with the same envelopes. The 30-minute pairing window means an operator must connect within 30 minutes of token generation — after that, regenerate (old channel dies instantly).

## Skills

I can install Claude-style skill packs straight onto a device: `skill_install` tasks upload `SKILL.md` + scripts into `<workspace>/skills/<name>/` (SHA-256 verified chunks). `skills` lists what's installed. The operator side (`server/link_ctl.py skill <dir> <name>`) pushes a whole folder in one command.

## What the operator can do (protocol v1.1)

| Task | Windows client | Android app |
|---|---|---|
| `run` — shell command | PowerShell, full user rights | app-sandbox `sh` (no root, documented limits) |
| `py` — Python snippet | if Python on PATH | ❌ (documented) |
| `ls` / `get` / `put` | workspace dir | app storage |
| `screenshot` | full desktop via PowerShell+GDI | MediaProjection w/ system consent dialog |
| `device` — info | OS, user, uptime | model, SDK, battery, storage, display |
| `status` / `kill` | ✓ | ✓ |
| `grant` / `special` | ❌ | runtime permission dialogs / system panels |
| `skills` / `skill_install` | ✓ | ✓ |
| `openurl` | ✓ | ✓ |
| `location` … `notifications` | ❌ | admin flavor + your grants |
| **`chat` — the direct line** | ✓ | ✓ (Chat tab, both directions) |

**Safe mode** (default) blocks privilege escalation and network pivoting: `sudo`, `su`, `ssh`, `scp`, `nc`, `curl|sh`, `rm -rf /`, and confines file ops to the workspace. Every command + output lands in an audit log (`orubus_audit.log` / in-app log). Safe mode is guardrails, **not** a jail — for hard isolation run the Windows client inside a container or a dedicated user account.

## Build it (GitHub Actions does the work)

| Workflow | Runner | Output |
|---|---|---|
| `android-apk` | ubuntu-latest | signed APKs, both flavors (`OrubusHarness-<ver>-consumer.apk`, `-admin.apk`) |
| `windows-client` | windows-latest | zipped desktop client artifact |
| `release` | tag `v*` | signed APKs + Windows zip attached to a GitHub Release |

Both build workflows trigger on push and manual dispatch → **Actions** tab → run → download artifact. No local toolchain needed, ever. Signing keys live in repo **Actions secrets** (`ANDROID_KEYSTORE_B64/PASS/ALIAS/PASS`) — never in the repo.

## The app

Three tabs, one channel:

1. **Chat** — the direct line to Orubus.ai. Type; it lands in my sandbox inbox; my replies appear here. History persists in the workspace.
2. **Bridge** — Generate Connectivity Token (30-min pairing window) → Go Online. Live activity feed of every task, result, and chat. Shield icon → Device Access grant screen.
3. **Settings** — identity/token (regenerate anytime), relay URL, mode (safe/open), update check against GitHub Releases.

## Honest engineering notes

- **"Offline" is physics, not features.** No network path = no data flows, period. A CA certificate enables TLS trust, not connectivity. Tailscale creates private routes *over* the internet — it still needs internet. What we CAN do offline-adjacent: store-and-forward queueing (tasks/results survive drops), and LAN mode (v2) for device↔device automation with no internet at all — but then the operator is not in the loop, because the operator lives in a cloud.
- **"Me, offline" doesn't exist.** The operator is GLM running in Z.ai's cloud. A local model (Ollama etc.) is a different brain. The direct line is direct *to me* — but my sandbox must be awake for replies to flow. When it is, latency is seconds; messages sent while I'm away are queued on the relay and delivered the moment I reconnect (`?since=` replay windows on both ends).
- **Android log limits, mapped honestly.** The admin flavor declares every permission a sideloaded app can lawfully hold; each one feeds a real reader — nothing decorative. What remains impossible without root: other apps' private logs (`READ_LOGS` via adb grant helps but is not root-equivalent), privileged phone state, user management. Special accesses (overlay, usage stats, install packages, notification listener, write settings) are user-flipped switches, not silent grants.
- **Screen sharing v1 = snapshots.** On-demand frames (fast enough for QA/oversight), not live video. Live video wants a persistent WebSocket relay — designed, not deployed (v2 with self-hosted relay on a VPS over Tailscale + mTLS with your own CA — exactly the hardening you intuited).

## Repo layout

```
agent/orubus_agent.py    # reference agent (pure Python, tested — runs anywhere, no app needed)
app/                     # Flutter harness (Android consumer/admin flavors + Windows)
server/link_ctl.py       # OPERATOR side — run this in the AI sandbox to pair + drive devices
.github/workflows/       # CI: signed APKs (both flavors) + Windows zip + tag → Release
PROTOCOL.md              # wire format spec v1.1 (task/result/chat envelopes, chunking)
SECURITY.md              # threat model, blast radius, revocation
```
