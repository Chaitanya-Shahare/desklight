# DeskLight

Menu bar app for Bluetooth desk lamps that use the **LED LAMP** app (iOS id1449109039 / Android `com.ledlamp`).
Power, brightness, warm/cool white, RGB, wallpaper-matched color, and time-based schedules.

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

## Wallpaper color

Menu bar → **Wallpaper color** sends the most vivid dominant color of your desktop picture.
Turn on **Follow** to update the lamp whenever the wallpaper or active Space changes.
Static images only (JPEG/PNG/HEIC/WebP); dynamic and aerial wallpapers aren't readable.

## Effects

The popup lists the lamp's 210 built-in animations (from the LED LAMP app's `dmx03_model` table) with a speed slider.
Schedules can start an effect too.

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
open desklight://effect/12       # speed/80
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
