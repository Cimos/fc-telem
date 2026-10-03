# FCTEL multi-firmware telemetry

FCTEL is a three-page EdgeTX telemetry screen for a RadioMaster Boxer (128x64)
using CRSF/ELRS. It supports INAV, Betaflight, and ArduPilot Plane/Copter while
keeping only one small firmware profile in Lua memory.

The main page shows mode, detected firmware, arm state, GPS/link, altitude,
speed, home direction/distance, battery use, and flight time. Page two shows
link and battery detail; page three is a pre-flight checklist. Use the scroll
wheel for the three script pages. EdgeTX PAGE keys remain available for moving
between telemetry screens. Alerts continue from `background()`.

## Files and installation

Copy these paths to the same locations on the radio SD card:

- `SCRIPTS/TELEMETRY/fctel.lua` — shared UI, sensors, detection, MSP transport,
  logging, console, and updater.
- `SCRIPTS/FCTEL/inav.lua` — INAV modes, arming reasons, and MSP decoding.
- `SCRIPTS/FCTEL/bf.lua` — Betaflight modes, arming reasons, and MSP decoding.
- `SCRIPTS/FCTEL/ap.lua` — ArduPilot Plane/Copter modes (no MSP polling).
- `SOUNDS/en/fctel/*.wav` — optional mode announcements.

Discover the standard CRSF sensors (`FM`, `RxBt`, `Curr`, `Capa`, `Bat%`,
`GPS`, `GSpd`, `Hdg`, `Alt`, `Sats`, `RQly`, `1RSS`, `RSNR`, `TPWR`, `VSpd`),
then add `fctel` as a Script telemetry screen. Missing sensors are tolerated.
An ELRS telemetry ratio of 1:2 or 1:4 gives responsive MSP updates.

`tools/sync.sh` copies the core, every profile, and voice files through USB
Storage. It also retrieves `/LOGS/fctel_dbg.txt`. Use `--no-push` to retrieve
without copying.

## Detection and overrides

In the default `CFG.profile = "auto"` mode the script broadcasts a CRSF device
ping at startup and every two seconds until it receives flight-controller
device info. Replies from other origins (including the ELRS TX/RX) are ignored.
Names beginning with INAV, Betaflight/BTFL, or Ardu/Rover (and names containing
Plane/Copter) select the corresponding on-demand profile.

If device info is absent for eight seconds, distinctive `FM` strings provide a
fallback guess. Ambiguous modes such as `MANU` and `ALTH` do not decide a
profile. After five seconds without an FM value or with RQly zero, detection is
restarted when telemetry returns; this handles model or aircraft changes.

Set `CFG.profile` to `"inav"`, `"bf"`, or `"ap"` to bypass detection. The
console logs `DETECT <name> -> <profile>` and `PROFILE <profile> (ping|fm|forced)`.

## Firmware behavior and limits

- INAV polls MSP2 INAV status, MSP_COMP_GPS, and navigation status. Compact
  `!GPS`-style FM refusal strings are decoded when supplied by the firmware;
  standard MSP status still supplies broad arming reasons.
- Betaflight polls MSP_STATUS_EX and MSP_COMP_GPS. Its variable-length status
  payload and 32-bit arming-disable flags are decoded, with up to three reasons
  shown. FM suffix `?` means ready with GPS Rescue unavailable.
- ArduPilot uses its four-character CRSF mode names and sends no MSP requests.
  Arming is only known when the optional disarmed `*` suffix is enabled, so the
  screen otherwise shows `--`. Home is captured at the first GPS fix of six or
  more satellites when arm state is unknown. No ArduPilot arming-refusal reason
  is available through this telemetry data.

Home distance from MSP is preferred where supported; otherwise it is calculated
from the GPS sensor. Cell count is inferred once from the first usable pack
voltage. Estimated range appears only after enough flight data exists.

## Configuration and voice

The `CFG` table controls capacity, battery/link thresholds and repeat times,
WAV use, mode announcements, settle time, logging, console use, MSP timing, and
the profile override. `angleAsFbwa` only changes the spoken clip for INAV ANGLE.

Each profile maps every known display mode to a lowercase clip basename. Missing
clips fall back to a tone. `tools/make_voices.py` contains all INAV, Betaflight,
and ArduPilot phrases; it requires network access and is intentionally not run
as part of installation or tests.

## Debug console and updating

Set EdgeTX **SYS > Hardware > Serial ports > USB-VCP = LUA**, choose USB Serial
when connecting, then run `tools/console.sh`. Status is also written once per
second to `/LOGS/fctel_dbg.txt` when `CFG.debugLog` is enabled. Commands written
one per line to `debug/cmd.txt` are: `d`, `v`, `s`, `p1`/`p2`/`p3`, and `e`.

With the console running:

- `tools/push.sh [local-file] [radio-path]` queues one file. With no arguments it
  pushes the core script.
- `tools/push_all.sh` queues the core and all `SCRIPTS/FCTEL/*.lua` profiles in
  order.
- The raw console form is `!push <windows-file> [<radio-path>]`.

Updater destinations are restricted to the core path, a simple filename below
`/SCRIPTS/FCTEL/`, or a simple WAV filename below `/SOUNDS/en/fctel/`. Data is
written to `<destination>.tmp`, checksum-checked, then copied into place. Power-cycle the radio after replacing Lua files; re-selecting the active model does not reload them.

## Tests and memory

Run `./.venv/bin/python tests/run.py`. The Lua 5.3 harness models EdgeTX 2.11 on
128x64 radios: no string metatable, no `table`/`os`/`coroutine`/`utf8`/`package`/
`debug` libraries, plain-global constants, and methodless file handles. It also
prints desktop-runtime memory for the core plus each selected profile; those
numbers are comparative and are not a hardware RAM measurement.

## Licence

GPL-3.0. See `LICENSE`.
