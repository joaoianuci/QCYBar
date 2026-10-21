# QCYBar

A free, tiny macOS menu-bar app to control **QCY earbuds** without the phone app. Built and tested with the
**QCY MeloBuds A30**; other QCY models that use the same protocol may work.

- **Noise control** — noise cancelling (adaptive, indoor, commuting, noisy, wind, with strength), ambient
  sound (voice focus or level 1–6) and normal; AI scene noise cancelling.
- **Equalizer** — the A30's 8 presets plus a 10-band custom curve.
- **Left/right balance.**
- **Features** — game mode (low latency), wind noise reduction, eco mode, dynamic EQ, sleep mode,
  multipoint, LDAC.
- **Touch controls** — the action of every gesture on each earbud.
- **Power** — turn the earbuds off from the Mac, sleep timer, auto power-off when disconnected, prompt volume.
- **Advanced** — fit test, rename, restore defaults, clear pairings, factory reset, BLE traffic log.
- Battery of each earbud and the case, right in the menu bar.
- English, Português (Brasil) and Español, following your macOS language.

No accounts, no telemetry, no updater frameworks, no network access.

| Idle, measured on an Apple Silicon MacBook Air | QCYBar |
|---|---|
| CPU | ~0.0 % |
| App size | ~0.8 MB |

## Requirements

- macOS 14 or later.
- QCY earbuds paired with the Mac as usual (audio). QCYBar opens its own Bluetooth LE control link next to it.
- Xcode 16+ / Swift 5.10+ toolchain to build.

## Download

Grab the latest `QCYBar-vX.Y.Z.zip` from the [Releases page](https://github.com/joaoianuci/QCYBar/releases/latest),
unzip it and drag `QCYBar.app` to `/Applications`. On first launch macOS asks for Bluetooth access.

> **The build is ad-hoc signed and not notarized.** There is no paid Apple Developer ID behind it yet, so
> Gatekeeper will say the app "can't be opened" the first time. You only need to get past it once:
>
> - **Right-click** (or Control-click) `QCYBar.app` → **Open** → **Open**; or
> - on recent macOS, try to open it once, then go to **System Settings → Privacy & Security** and click
>   **Open Anyway**; or
> - remove the quarantine flag from Terminal:
>   ```bash
>   xattr -dr com.apple.quarantine /Applications/QCYBar.app
>   ```
>
> You can verify the download against the `.sha256` file attached to the release, or build it yourself (below).

## Build & install

```bash
git clone https://github.com/joaoianuci/QCYBar.git
cd QCYBar
INSTALL=1 scripts/build-app.sh   # builds build/QCYBar.app, copies it to ~/Applications and opens it
```

Without `INSTALL=1` it only builds `build/QCYBar.app`. Run the tests with `swift test`.

## Troubleshooting

- **Stuck on "Looking for the earbuds…"** — take them out of the case. If the QCY phone app is open, close
  it: the earbuds accept only one control link at a time.
- **Turning the earbuds on** cannot be done over Bluetooth (they have no radio while off). Put them in the
  case and take them out.
- **Advanced → Diagnostics** shows the raw BLE traffic; the same log is written to `~/Library/Logs/QCYBar.log`.

## How it works

QCY earbuds expose a vendor GATT service next to the audio link. The protocol was reverse-engineered by the
community; QCYBar reimplements it in Swift with CoreBluetooth:

- **QCY chips** (WuQi, Realtek, generic): service `0xA001`, frames `FF len {id n payload}…`.
- **JieLi chips** (the A30 sold today): service `0xA002`, JieLi RCSP frames with QCY settings inside the
  custom opcode `0xFF`.

Both carry the same setting ids (`0x17` noise control, `0x22` equalizer, `0x2B` touch keys, …), so the app
builds one set of commands and the transport wraps them. Firmware update (OTA) commands are never sent.

## Project layout

```
Sources/QCYBar/Protocol.swift  Framing (QCY + JieLi RCSP), settings, EQ encoding
Sources/QCYBar/Earbuds.swift   CoreBluetooth link, state, commands
Sources/QCYBar/App.swift       SwiftUI menu-bar UI
Resources/                     Info.plist and translations (en, pt-BR, es)
Tests/QCYBarTests/             Protocol vectors and a translation coverage check
```

## Credits

The protocol knowledge comes from these open-source projects; please star them:

- [BrunoAssis/qcyx](https://github.com/BrunoAssis/qcyx) (MIT) — wire-verified frame format and ANC scenes.
- [hm-aktaruzzaman-mukdho/Orphion](https://github.com/hm-aktaruzzaman-mukdho/Orphion) (Apache-2.0) — JieLi
  RCSP, per-model control panels, and the EQ master-gain algorithm ported in `EqPreset.autoMasterGain`.
- [hui1601/Quicky](https://github.com/hui1601/Quicky) — command reference.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with QCY. "QCY" and "MeloBuds" are trademarks of their owners.
