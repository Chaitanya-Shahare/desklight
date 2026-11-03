# LED LAMP (com.ledlamp) BLE protocol

Recovered from the Android APK (`com.ledlamp`, SHA-256 `246eb5d9…9dea59`, from APKPure), decompiled with jadx.
Source: `com.home.net.NetConnectBle`, `com.home.constant.CommonConstant`, `com.home.fragment.service.ServicesFragment`.

## Transport

| Item | Value |
|---|---|
| Service | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| Characteristic (write + notify) | `0000FFE1-0000-1000-8000-00805F9B34FB` |
| Frame size | 9 bytes, no checksum |
| Device names | start with `LED` (`LEDBLE-0x-…`, `LED-…`, `LEDDMX-…`, `LEDCAR-…`, `LEDSMART`, …) |
| Pacing | app throttles writes to 30–100 ms |

## Connect handshake

~300 ms after connect the app writes:

```
2A 02 A1 23 45 67 DH MM AF
```

- `A1 23 45 67`: default password (user can change it in the app).
- `DH` = `(weekday << 5) | hour`, weekday Mon=1 … Sun=7. `MM` = minute. This also sets the lamp clock.
- Lamp notifies `2A 05 SS`: `SS=1` wrong password, `2` invalid password, `3` OK (app re-sends `2A 05 FF… AF`).

## Commands — LEDBLE-00/01/02, LED-, LED_ ("classic")

| Action | Bytes |
|---|---|
| On | `7E FF 04 01 00 FF FF 00 EF` |
| Off | `7E FF 04 00 00 FF FF 00 EF` |
| Brightness 0–100 | `7E FF 01 BB 00 FF FF FF EF` |
| RGB | `7E FF 05 03 RR GG BB FF EF` |
| White temp | `7E FF 05 02 WW CC FF FF EF` (warm% + cool% = 100) |
| Dim 0–100 | `7E FF 05 01 VV FF FF FF EF` |
| Effect | `7E FF 03 MM 03 FF FF FF EF` |
| Speed 0–100 | `7E FF 02 SS 00 FF FF FF EF` |

## Commands — LEDBLE-03/04/05 ("compact")

Power and RGB are identical to classic. Others drop the `FF` after `7E`:

| Action | Bytes |
|---|---|
| Brightness | `7E 01 BB CH FF FF FF FF EF` (CH: 0 RGB, 1 dim, 2 white) |
| White temp | `7E 06 CC FF FF FF FF FF EF` (cool %) |
| Dim (04/05) | `7E 07 VV FF FF FF FF FF EF` |
| Effect | `7E 03 MM 00 FF FF FF FF EF` |
| Speed | `7E 02 SS 00 FF FF FF FF EF` |

## Commands — LEDDMX-03 (RGB only, verified on `LEDDMX-03-0F2B`)

| Action | Bytes |
|---|---|
| On / Off | `7B 04 04 01 FF FF FF FF BF` / `7B 04 04 00 FF FF FF FF BF` |
| RGB | `7B FF 07 RR GG BB 00 FF BF` (from `setDmxRgb`; byte 6 must be `00`) |
| Brightness 0–100 | `7B FF 01 (B×32/100) BB 00 FF FF BF` |
| Effect | `7B FF 03 MM FF FF FF FF BF` |
| Speed | `7B FF 02 SS FF 00 FF FF BF` |

No white channel: DeskLight mixes warm/cool white from RGB.

## Not implemented

- Other LEDDMX models / LEDCAR / LEDSMART / LEDSUN / LEDLIKE / LEDPHO families use other headers (`7B`, `7D`, `7A`, `70`) — see `NetConnectBle.java`.
- On-device timers (`8E …`, `7E FF 11 …`): format only partially understood; DeskLight schedules from the Mac instead.
- Custom passwords: change the bytes passed to `LampProtocol.handshake(password:)`.
