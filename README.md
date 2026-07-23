# Universal TV Remote for Mac

A sleek, minimal **menu-bar remote** for every smart TV on your network.
Click the TV icon in your Mac's menu bar and control **Fire TV, Android TV /
Google TV, Samsung, LG, and Roku** — auto-discovered, no configuration files,
no cloud.

## Features

- **Auto-discovery** — TVs appear in the picker automatically (Bonjour + SSDP)
- **Full remote** — power, d-pad + OK, back/home/menu, play/pause, seek, volume
- **Keyboard text input** — type into TV search boxes from your Mac keyboard
- **App shortcuts** — one click to Netflix, YouTube, Prime Video & friends
- **Media-key passthrough** — while the remote is open, your Mac's arrow keys,
  Space, Esc, and media/volume keys drive the TV
- **One-time pairing** — PIN on screen (Fire TV / Android TV) or an Allow
  dialog on the TV (Samsung / LG); Roku needs nothing. Tokens are remembered.
- Native Swift/SwiftUI. No Electron. ~1 MB binary.

## Install

Grab the latest `Universal.TV.Remote.for.Mac.zip` from
[Releases](../../releases), unzip, drag **Universal TV Remote.app** to
`/Applications`, and **right-click → Open** the first time (the app is ad-hoc
signed, not notarized).

On first launch macOS asks to allow **local network** access — this is
required for discovery. If you dismissed it, re-enable it under
*System Settings → Privacy & Security → Local Network*.

## Per-brand notes

| Brand | Protocol | Pairing | Power-on |
|---|---|---|---|
| Fire TV | Private REST API (`:8080`) | 4-digit PIN on TV | DIAL wake (`:8009`) |
| Android TV / Google TV | Google Remote v2 (TLS + protobuf, `:6466/6467`) | 6-char code on TV | protocol key |
| Samsung (Tizen) | WebSocket (`:8002`) | Allow dialog on TV | Wake-on-LAN |
| LG (webOS) | SSAP WebSocket (`:3001`) | Allow dialog on TV | Wake-on-LAN |
| Roku | ECP REST (`:8060`) | none | ECP / fast-start |

- **Roku OS 14.1+**: enable *Settings → System → Advanced system settings →
  Control by mobile apps*.
- **Fire TV**: uses the same local API as the official mobile app — no ADB,
  no developer options. A few very old Fire OS builds lack this API.
- **Samsung / LG / Roku** drivers are written faithfully from the reference
  implementations (Home Assistant's backends) but are untested on real
  hardware — issue reports welcome.
- Android TV text input types character-by-character (the full IME protocol
  isn't implemented); uppercase and exotic symbols are skipped.

## Build from source

```bash
git clone <this repo>
cd "TV Remote Dock App"
bash scripts/build-app.sh          # → build/Universal TV Remote.app
```

Requires Xcode command-line tools (Swift 5.9+). The only dependency is a
vendored copy of [AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl)
(MIT) with a 2-line manifest patch for macOS support.

## CI/CD

Every push to `main` builds on a macOS runner and publishes a GitHub Release
(`v1.0.<run>`), with the zipped app attached. Push a `v*` tag to cut an
explicitly-versioned release. See `.github/workflows/release.yml`.

## Architecture

```
Sources/UniversalTVRemote/
├── App.swift          entry point + all menu-bar UI
├── TVController.swift TVDriver protocol, RemoteSession, shared key enum, WoL
├── Discovery.swift    Bonjour (NWBrowser) + SSDP (BSD socket) scanning
├── FireTV.swift       one self-contained driver per brand …
├── AndroidTV.swift
├── Samsung.swift
├── LG.swift
└── Roku.swift
```

Every driver implements the same five-method `TVDriver` protocol; adding a
brand is one new file plus one `switch` case.

## License

MIT (vendored AndroidTVRemoteControl library is MIT, © Roman Odyshew).
