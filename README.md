# DeskLight

Menu bar app for Bluetooth desk lamps that use the **LED LAMP** app (iOS id1449109039 / Android `com.ledlamp`).
Power, brightness, a color wheel / RGB picker, warm/cool white, live color from your wallpaper, screen, or music, slow fades, and schedules.

Tested with `LEDDMX-03-0F2B` (RGB). Also speaks the `LEDBLE-*` command set from the same app.

## Run

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

## Links (Shortcuts, Raycast, Terminal)

```sh
open desklight://on              # off, toggle, wallpaper
open desklight://color/FF8800
open desklight://white/70        # 70% warm
open desklight://brightness/40   # or +10 / -10
open desklight://live/music      # screen, wallpaper, off
open desklight://fadeout/30      # minutes; also sunrise/15
```

## Schedules

Menu bar → **Schedules…**. Each schedule has a time, days, and actions (power, white/color, brightness).
They run only while the Mac is awake. A schedule whose time passes during sleep is skipped. After wake, the app reconnects to the lamp.
Stored in `~/Library/Application Support/DeskLight/schedules.json`.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Protocol details: [docs/PROTOCOL.md](docs/PROTOCOL.md).
