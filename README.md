# MAD_CAPPY INAV telemetry

`inav.lua` is a three-page EdgeTX telemetry screen for a RadioMaster Boxer with a 128x64 display. It combines normal CRSF sensors with non-blocking MSP-over-CRSF requests to INAV.

The main page shows flight mode, arm state or refusal reason, GPS and link state, altitude, speed, home distance and direction, battery use, remaining capacity, and an armed-only flight timer. The second page concentrates on link and battery data, including estimated range. The third page is a pre-flight checklist. Alerts continue in `background()` while another radio screen is open.

## Install

1. Copy `SCRIPTS/TELEMETRY/inav.lua` to the same path on the radio SD card.
2. In the model setup, discover the CRSF telemetry sensors. Keep their standard names (`FM`, `RxBt`, `Curr`, `Capa`, `Bat%`, `GPS`, `GSpd`, `Hdg`, `Alt`, `Sats`, `RQly`, `1RSS`, `RSNR`, `TPWR`, and `VSpd`). Missing sensors are allowed.
3. Open the model's **Telemetry screens** page, add a **Script** screen, and select `inav`.
4. Set the ExpressLRS telemetry ratio to 1:2 or 1:4. A slower ratio makes MSP updates less responsive.
5. Use Page Next/Page Previous to change pages. Enter also advances a page on the Boxer.

The custom fork firmware is required for the compact arming-reason values carried in `FM`. MSP status and arming reasons work with any INAV 9.x build that supports MSP over CRSF, so the script still provides useful detail without the fork.

## Configuration

Edit the `CFG` table at the top of `inav.lua` before copying it to the SD card:

- `capacity`: usable battery capacity in mAh.
- `lqWarn`: low link-quality threshold.
- `cellWarn`: in-flight per-cell voltage warning.
- `cellReady`: minimum per-cell voltage for the checklist.
- `reservePercent`: remaining-capacity warning threshold.
- `lqRepeat`, `batteryRepeat`, and `reserveRepeat`: alert repeat times in 10 ms EdgeTX ticks.
- `useWav`: use mode WAV files when they are installed; otherwise use tones.

Cell count is detected once from the first valid `RxBt` value. Range is an estimate based on consumed mAh and straight-line distance from home; it is deliberately omitted until enough data exists.

## Optional sounds

Put these files in `/SOUNDS/en/inav/`:

`acro.wav`, `angle.wav`, `horizon.wav`, `anglehold.wav`, `manual.wav`, `althold.wav`, `cruise.wav`, `coursehold.wav`, `loiter.wav`, `poshold.wav`, `waypoint.wav`, `rth.wav`, `wprth.wav`, `landing.wav`, `failsafe.wav`, and `homereset.wav`.

Missing files are harmless and fall back to a tone. RTH and failsafe also use haptic feedback.

## Boxer memory

The script keeps one sensor table, one small MSP receive buffer, and fixed lookup tables. It avoids per-frame table construction in the normal update path. Do not add large bitmaps or debug logging on the Boxer; both consume scarce Lua RAM.

## Bench debugging

`CFG.debugLog = true` makes the script append one status line per second to
`/LOGS/inav_dbg.txt` on the radio's SD card: raw FM string, decoded mode and arming
reason, sats, LQ, RxBt, capacity, GPS, home, MSP requests/replies/timeouts, arming
flags, nav state, page and Lua memory. Any Lua error is caught, shown on screen with
its message, and written to the log as an `ERR` line instead of killing the script.
The log restarts after about 15 minutes of lines.

Loop: fly or bench with the radio, plug the radio into the PC, choose USB Storage,
then run `tools/sync.sh`. It pulls the log into `debug/` (not committed), pushes the
current script, clears the log, and prints any errors plus the last lines.

The host tests run under Lua 5.3 like EdgeTX 2.11 and mimic its quirks on 128x64
radios: no string methods (`s:sub()` fails), constants only reachable as plain
globals, and file handles without methods.

## Live USB console (bench testing)

The script can stream its status over the radio's USB port while you test, with the
radio running normally.

One-time radio setup (EdgeTX 2.11): **SYS > Hardware > Serial ports > USB-VCP = LUA**.

Each session: plug the radio into the PC and choose **USB Serial (VCP)** on the
popup, then on the PC run `tools/console.sh`. It finds the radio's COM port, prints
every line with a timestamp and saves it to `debug/console-<time>.log`
(`debug/console-latest.log` points at the newest).

Lines: `START`, a status line once a second (same fields as the SD log), `EV` events
(mode change, arming reason change, MSP timeouts, and with verbose on every MSP
request and reply), `ERR` Lua errors.

Commands (write one per line to `debug/cmd.txt` while the console runs):
`d` dump now, `v` toggle verbose MSP events, `s` list sensors with their ids and
values, `p1`/`p2`/`p3` jump to a page, `e` show the last Lua error.

INAV flight controllers use the same USB id (0483:5740). With both plugged in, the
console picks the port that is sending script lines.

### Updating the script over the same cable

With the console running, `tools/push.sh` sends the current `inav.lua` to the radio
through the script's own updater: 128-byte chunks, each acknowledged, a checksum at
the end, then a copy over `SCRIPTS/TELEMETRY/inav.lua`. The console prints `PUSHOK`
or `PUSHFAIL`. A bad checksum leaves the old file in place. Select the model again
on the radio (or power-cycle) to run the new version. The updater only exists from
this version on, so the first install still goes over USB Storage.
