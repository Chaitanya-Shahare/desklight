# DeskLight

Menu bar app for Bluetooth desk lamps that use the **LED LAMP** app (iOS id1449109039 / Android `com.ledlamp`).
Power, brightness, a color wheel / RGB picker, warm/cool white, live color from your wallpaper, screen, or music, slow fades, and schedules.

Tested with `LEDDMX-03-0F2B` (RGB). Also speaks the `LEDBLE-*` command set from the same app.

## Install

```sh
brew install --cask chaitanya-shahare/tap/desklight
```

Universal build (Apple Silicon + Intel), macOS 14+. It's self-signed, not notarized; the cask clears the
download quarantine flag so it opens without the "unidentified developer" block.

## Build from source

```sh
scripts/setup-signing.sh        # once: stable local signature, so Bluetooth permission survives rebuilds
scripts/build-app.sh            # builds build/DeskLight.app
open build/DeskLight.app        # or: scripts/build-app.sh --install
```

1. Allow Bluetooth when macOS asks.
2. Close the LED LAMP app on your phone (the lamp accepts one connection at a time).
3. Click the 💡 in the menu bar → **Scan for lamps** → pick your lamp.

## Color

**Color** tab: drag on the wheel, use the R/G/B sliders, type a hex code, or click a swatch.
**White** tab: cool ↔ warm slider (mixed from RGB on RGB-only lamps).

## Live

**Live** tab picks what drives the color:

| Mode | What it does | Permission |
|---|---|---|
| Wallpaper | Brightest vivid color of your desktop picture; updates when it or the Space changes | none |
| Screen | Follows what's on the main display ~12×/s (videos, games); dark scenes dim the lamp | Screen & System Audio Recording |
| Music | Brightness follows bass, hue steps on each beat; sensitivity slider | Screen & System Audio Recording |

Picking a color manually turns Live off.

## Focus timer (Pomodoro)

**Focus** tab: 25 min focus / 5 min break / 15 min long break every 4 (all adjustable).

- The lamp is the progress bar: focus glides **green → yellow → orange → red** as time runs out; breaks are a calm, dimmer blue (purple for long breaks).
- Three white pulses + a sound mark the end of each phase.
- The menu bar shows the countdown; the popup shows a progress bar in the same colors.
- **Stop** restores the lamp's previous color. ⌃⌥⌘P starts/pauses.

The lamp is a single-color controller (no per-LED addressing), so progress is shown by color, not a lit bar.

## Fades

- **Fade out**: dims to off over 5–60 minutes.
- **Sunrise**: from off, rises to warm white at 100% over 5–30 minutes.
- Schedules have a **Transition** setting to fade to their target instead of switching instantly.

## Automations

- **Off when Mac locks or sleeps**: lamp turns off on lock/sleep and back on at unlock (only if it was on).
- **On-Air light**: lamp turns red while the camera (and optionally the microphone) is in use by any app,
  then restores the previous color. No camera/mic permission needed; it only reads whether the device is busy.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌃⌥⌘L | Toggle on/off |
| ⌃⌥⌘↑ / ↓ | Brightness ±10% |
| ⌃⌥⌘W | Wallpaper color |
| ⌃⌥⌘P | Start/pause focus timer |

## Links (Shortcuts, Raycast, Terminal)

```sh
open desklight://on              # off, toggle, wallpaper
open desklight://color/FF8800
open desklight://white/70        # 70% warm
open desklight://brightness/40   # or +10 / -10
open desklight://live/music      # screen, wallpaper, off
open desklight://fadeout/30      # minutes; also sunrise/15
open desklight://pomodoro/start  # pause, toggle, skip, stop
```

## Schedules

Menu bar → **Schedules…**. Each schedule has a time, days, and actions (power, white/color, brightness).
They run only while the Mac is awake. A schedule whose time passes during sleep is skipped. After wake, the app reconnects to the lamp.
Stored in `~/Library/Application Support/DeskLight/schedules.json`.

## Releasing

```sh
scripts/release.sh 0.2.0                      # dist/DeskLight-0.2.0.zip + SHA-256
gh release create v0.2.0 dist/DeskLight-0.2.0.zip
# then bump version + sha256 in Chaitanya-Shahare/homebrew-tap Casks/desklight.rb
```

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Protocol details: [docs/PROTOCOL.md](docs/PROTOCOL.md).
