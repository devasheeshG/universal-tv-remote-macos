# TV Remote Dock App — Research Notes (pre-plan)

Decisions so far: macOS **menu bar app**; brands = **all, Fire TV first**; features = core remote + **keyboard text input, app launcher, Mac media-key passthrough**. Build-vs-buy not yet decided.

## Part 1 — Protocol research (per brand)

### Amazon Fire TV (priority) — two routes
- **Route B (recommended): reverse-engineered REST API, no ADB.**
  - HTTPS port **8080**, self-signed cert, hardcoded header `X-Api-Key: 0987654321`.
  - Pairing: `POST /v1/FireTV/pin/display {"friendlyName":"..."}` → 4-digit PIN on TV → `POST /v1/FireTV/pin/verify {"pin":"1234"}` → persistent token (`X-Client-Token`).
  - Keys: `POST /v1/FireTV?action=dpad_up|dpad_down|dpad_left|dpad_right|select|back|home|menu|play|volume_up|volume_down|volume_mute|0-9`
  - Text input: `POST /v1/FireTV/keyboard {"text":"..."}`. App launch: `POST /v1/FireTV/app/<package>`.
  - ~50 ms latency. Reference: github.com/mase1981/uc-intg-firetv (active 2025) + Node-RED flow "FireTV Stick Remote via REST-API" (documents every endpoint).
  - Caveats: private Amazon API; command-only (no state); model coverage unverified on some Fire OS builds; wake via plain HTTP port 8009 is single-sourced — test on hardware.
- **Route A (fallback): ADB over TCP :5555.** What Home Assistant androidtv uses. Needs Developer Options → ADB Debugging on TV + RSA trust dialog. `input keyevent`, `input text`, `am start`. Reliable but clunky UX; reconnect-after-sleep flaky. Native Swift ADB client exists: QuestSyncKit (github.com/ishanperera/questsync) — no need to bundle adb binary.
- Discovery: mDNS `_amzn-wplay._tcp`.

### Samsung (Tizen)
- `wss://<ip>:8002/api/v2/channels/samsung.remote.control?name=<b64>&token=...`; port 8001 = device info REST.
- Pairing: first connect → Allow/Deny popup on TV → token to persist.
- Keys `KEY_VOLUP` etc. via `ms.remote.control`; text via `SendInputString` (base64); apps via `ed.apps.launch` or `POST :8001/api/v2/applications/<id>`.
- Power-on = **Wake-on-LAN** (cache MAC while on). Discovery: SSDP `urn:samsung.com:device:RemoteControlReceiver:1`.
- Reference: github.com/xchwarze/samsung-tv-ws-api (HA uses it).

### LG (webOS)
- WebSocket :3000, modern firmware → **wss :3001** (self-signed). Pairing: `register` w/ permission manifest → TV prompt → `client-key`.
- SSAP JSON commands (`ssap://audio/volumeUp`, `ssap://system.launcher/launch`, `ssap://system/turnOff`); d-pad via second "pointer input socket" (`getPointerInputSocket` → `type:button\nname:UP`).
- Text: `ssap://com.webos.service.ime/insertText`. Power-on: WoL. Discovery: SSDP `urn:lge-com:service:webos-second-screen:1`.
- **Maintained Swift package exists: github.com/jareksedy/WebOSClient** — use directly. Also aiowebostv (HA).

### Android TV / Google TV (Sony, TCL, Hisense GTV, Chromecast, Shield)
- Remote v2: TLS w/ generated client cert; pairing :6467 (6-char code), session :6466; length-prefixed protobuf (public .proto files).
- Keys = Android KEYCODE_*; text via IME messages; app launch via deep links; TV pushes state (volume/current app). No WoL needed.
- Discovery: mDNS `_androidtvremote2._tcp`. Fire TV does NOT speak this protocol.
- References: github.com/tronikos/androidtvremote2 (HA), Swift lib github.com/odyshewroman/AndroidTVRemoteControl (verify macOS build), working macOS menu-bar example: github.com/usrivastava92/gtv-desktop-remote.

### Roku / Roku TV
- Plain HTTP :8060, **no pairing**. `POST /keypress/<Key>` (arrows, Select, Home, Back, Play, VolumeUp/Down, PowerOn/PowerOff, InputHDMI1-4), `/launch/<appId>`, text via `Lit_<char>`, `GET /query/apps|active-app|device-info`.
- Discovery: SSDP ST `roku:ecp`. Caveat: Roku OS 14.1 gates ECP behind Settings → "Control by mobile apps" — onboarding needs error path.
- Deep-standby power-on may need WoL (`supports-wake-on-wlan` in device-info).

### macOS constraints
- Need both Bonjour/mDNS (Fire TV, Android TV) and SSDP/UDP multicast (Samsung, LG, Roku). Multicast entitlement is iOS-only — **not needed on macOS**. Sandbox: `network.client` (+ `network.server` if listening for SSDP NOTIFY).
- macOS Sequoia: Local Network privacy (TCC) prompt; add `NSLocalNetworkUsageDescription`; prompt known flaky → ship help path to System Settings → Privacy → Local Network.
- Self-signed TLS trust-overrides needed for Samsung :8002, LG :3001, Fire TV :8080. Android TV needs generated client cert in Keychain. WoL = simple UDP broadcast.

## Part 2 — Existing apps (build vs buy)

**Nothing combines macOS menu bar + Fire TV + multi-brand.**

Open source:
- gtv-desktop-remote — Electron menu bar, Google TV ONLY. Active, ~10★, no license.
- TellyKeys — native macOS 14+ menu bar, closed-source beta; Android TV protocol only; Fire TV absent.
- demote (github.com/YotaPower04/demote) — **best protocol blueprint**: Samsung+Roku+LG+AndroidTV+Vizio w/ discovery+pairing wizards, but Linux/Qt, GPL-3.0, Fire TV experimental.
- roam (github.com/msdrigg/roam) — beautiful native SwiftUI Roku-only remote (Mac/iOS), MIT — study for UI.
- ZaneH/firetv-remote — Node web app, ADB-based, manual IP, last commit 2023.
- Android-TV-Desktop-Toolkit — Python windowed ADB power-tool (can drive Fire TV via ADB), not menu bar.
- g-tiwari/fireTVRemote — empty repo (README only).

Commercial:
- **Universal TV Remote** (Remote Sunrise, Mac App Store, ~$19.99 lifetime or ~$9.99 sub) — closest match: real Mac app, Fire TV + Samsung + LG + GTV + Roku + Apple TV. Windowed, closed-source.
- **TVRem** (Mac App Store, free + IAP) — Samsung, LG, Roku, Fire TV, GTV. Windowed.
- **Official Amazon Fire TV app** — free, runs on Apple Silicon Macs, full Fire TV control incl. text input. Fire TV only, iPad-style window.
- Adam Foot "TV Remote" — polished native multi-brand, but NO Fire TV, no menu bar.

Bottom line: every protocol is solved somewhere in open source (Swift libs exist for LG + Android TV). The novel thing to build = sleek native menu-bar shell unifying them + Fire TV via the REST route (no desktop app uses it yet).

## Approved design (2026-07-23)

- Native Swift + SwiftUI MenuBarExtra (.window style), macOS 14+, name "Universal TV Remote for Mac".
- All 5 brands in v1: Fire TV (REST route, DIAL wake), Android TV (vendored AndroidTVRemoteControl, MIT), Samsung (Tizen WS + WoL), LG (SSAP WS + pointer socket + WoL), Roku (ECP).
- UI: device picker + power/refresh/settings header, status/pairing section, d-pad, back/home/menu, transport, volume, TV text field, app shortcut row. Keyboard + media-key passthrough while popover open.
- Files: App.swift (UI), TVController.swift (abstraction + WoL/ARP), Discovery.swift (Bonjour+SSDP), one driver file per brand. build-app.sh assembles/ad-hoc-signs the bundle; GitHub Actions releases on every push to main (v1.0.<run>) and on v* tags.
- Known ships-untested: Samsung/LG/Roku drivers (no hardware). Fire TV REST coverage on some old builds unverified; ADB fallback deliberately deferred.
