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
