
## Task 8 — v1.2026.10.6 (2026-10-28): persistence + auto-resume + skeuomorphic shell + auth/restore

**Install failure forensics (10.5 INSTALL_FAILED on device):**
- Release asset downloaded byte-identical (23,986,311 B) → verify_apk_v2: DIGEST MATCH, self-consistent, cert fp = keystore fp (80:31:65:AA:…:B4:C4)
- Manifest diff 10.4 vs 10.5 (pyaxmlparser): only +FOREGROUND_SERVICE_SPECIAL_USE +BridgeService(specialUse, exported=false, PROPERTY_SPECIAL_USE_FGS_SUBTYPE) — versionCode up, packaging identical (extractNativeLibs=true preserved)
- Verdict: build is installable; device installer transient. Advice: reboot → retry; 10.6 is the fresh target. RECEIVE_BOOT_COMPLETED already in manifest (boot receiver deferred: without a running Dart engine it would only fake a notification)

**Sandbox reset caught red-handed:** local repo rolled back to 18fb030 (10.4), remote gone, but link/ state survived → re-cloned via PAT remote, reset --hard origin/main (8d15bfa). Proves the config-bank design; formalizing it (API repo sandbox-state + restore_sandbox.sh)

**10.6 changes:**
- Chat persistence hardened to DUAL stores: chat_history.jsonl + SharedPreferences mirror (chatMirrorJson, last 150), union-dedup merge on load (OEM cache cleaners suspected of eating the workspace file on 10.4)
- Auto-resume: store.wasOnline persisted via Link.onOnlineChanged; cold start auto-connects (engine hello re-announces, FGS restarts) — "withstand app closes"
- Link.autoEvents buffer: pre-screen engine events seeded into Bridge activity log
- clearChats(): wipes file + mirror + memory (three-dot menu)
- Authentication screen: (a) operator chat endpoint (chat.z.ai/c/<id>) saved as credential; (b) RESTORE identity from pasted ORUBUS-LINK1 line — reinstalls skip 30-min pairing entirely
- Pairing screen: token ops + advanced manual channel edit; Settings: mode + auto-launch switch + update check (kAppVersion const — fixes stale 1.2026.10.1 hardcode)
- UI overhaul per user refs: neumorphic light theme (#E4E9F2 bg, #6BCEEC accent, #00CFCC focus, r=20, dual soft shadows), shell = hamburger drawer (Chat/Bridge/Pairing/Authentication/Settings/Device Access) + three-dot popup (online toggle, copy token, clear chat); bubbles: user=accent, operator=surface
- Gate: local Dart SDK 3.13.7 `dart format --output=none` — 0 parse errors (caught 3 real syntax bugs pre-CI)
- gradle: 1.2026.10.6 / 120261006

**10.6 verification (CI round 2, run #7): SUCCESS** — admin/consumer/windows assets published; admin6.apk (24,080,519 B) independently verified: DIGEST MATCH, self-consistent, cert fp = keystore fp. Manifest: app.orubus.harness.admin @ 1.2026.10.6 (120261006), services = NotifListener + CaptureService + BridgeService ✓
[2026-10-28T16:13:34+0000] re-paired to 3rd identity (topic e705f47...) from discord msg 1565035238483165337; 2nd rotation in ~15min => app regenerates identity on restart, persistence fix targeted in 10.6; confirmation sent via vercel relay
[poller] re-paired to new device identity (topic e705f4…) from discord msg 1565035238483165337; bridge ack sent via vercel; 2nd identity rotation in 15min -> app persistence bug confirmed, queued for v1.2026.10.6
[main] msg 1565039253728002209: user confirms ntfy DEAD on phone (DNS errno=7, screenshots image1/image2.png); directive accepted: relay-first (vercel only), 6-digit code pairing, scrap token flow, light skeuomorph UI from reference imgs (upload/*.jpg @14:52), +icon attachments, model picker, webview cookie auth, round-trip acceptance test; ack sent on discord
[build] 10.7 app pushed (bffbedd): relay_engine + 6-digit pairing screen + attach + model chips + warm reskin; relay deployed (device-token auth, sys/pair bus, b64 attach); wire test ALL PASS; CI android-apk run 40734085521 in flight
[build] relay: attach endpoint LIVE (GitHub asset store, GH_TOKEN sourcing fixed); app: model picker pushed (ad4d39a) on top of their c9ce314 syntax fix; awaiting CI
