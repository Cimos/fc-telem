#!/usr/bin/env python3
"""Generate the flight-mode voice clips for fctel.lua.

Microsoft neural TTS (edge-tts) -> MP3 -> 32 kHz 16-bit mono PCM WAV, the format
EdgeTX voice packs use. Silence is trimmed and each clip is normalised to the same
peak, so they all sound alike on the radio.

Usage: .venv/bin/python tools/make_voices.py [--voice en-AU-NatashaNeural] [--pitch -15Hz] [--rate +5%]
Writes SOUNDS/en/fctel/<name>.wav; copy that folder to the radio's SD card.
"""
import argparse, array, asyncio, io, wave
from pathlib import Path
import edge_tts, miniaudio

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "SOUNDS" / "en" / "fctel"
RATE = 32000

# file name (matches wavName in fctel.lua) -> spoken phrase
CLIPS = {
    "fbwa": "F-B-W-A",
    "angle": "Angle",
    "acro": "Acro",
    "horizon": "Horizon",
    "anglehold": "Angle hold",
    "manual": "Manual",
    "althold": "Altitude hold",
    "cruise": "Cruise",
    "coursehold": "Course hold",
    "loiter": "Loiter",
    "poshold": "Position hold",
    "waypoint": "Waypoint",
    "rth": "Return to home",
    "wprth": "Mission return to home",
    "landing": "Landing",
    "failsafe": "Failsafe",
    "homereset": "Home reset",
    "gpsrescue": "GPS rescue",
    "passthru": "Passthrough",
    "posholdfail": "Position hold fail",
    "chirp": "Chirp",
    "airmode": "Air mode",
    "circle": "Circle",
    "stabilize": "Stabilize",
    "training": "Training",
    "fbwb": "F-B-W-B",
    "autotune": "Autotune",
    "auto": "Auto",
    "rtl": "R-T-L",
    "takeoff": "Takeoff",
    "avoidadsb": "Avoid A-D-S-B",
    "guided": "Guided",
    "initialising": "Initialising",
    "qstabilize": "Q stabilize",
    "qhover": "Q hover",
    "qloiter": "Q loiter",
    "qland": "Q land",
    "qrtl": "Q R-T-L",
    "qacro": "Q acro",
    "qautotune": "Q autotune",
    "thermal": "Thermal",
    "loiterqland": "Loiter Q land",
    "autoland": "Autoland",
    "land": "Land",
    "drift": "Drift",
    "sport": "Sport",
    "flip": "Flip",
    "brake": "Brake",
    "throw": "Throw",
    "guidednogps": "Guided no GPS",
    "smartrtl": "Smart R-T-L",
    "flowhold": "Flow hold",
    "follow": "Follow",
    "zigzag": "Zigzag",
    "systemid": "System I-D",
    "autorotate": "Autorotate",
    "turtle": "Turtle",
}


async def tts(text, voice, pitch="+0Hz", rate="+5%"):
    buf = bytearray()
    async for chunk in edge_tts.Communicate(text, voice, rate=rate, pitch=pitch).stream():
        if chunk["type"] == "audio":
            buf += chunk["data"]
    return bytes(buf)


def to_pcm(mp3):
    d = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16,
                         nchannels=1, sample_rate=RATE)
    s = array.array("h", d.samples)
    thr = 300
    start = next((i for i, v in enumerate(s) if abs(v) > thr), 0)
    end = len(s) - next((i for i, v in enumerate(reversed(s)) if abs(v) > thr), 0)
    pad = int(RATE * 0.03)
    s = s[max(0, start - pad):min(len(s), end + pad)]
    peak = max((abs(v) for v in s), default=1) or 1
    gain = (0.89 * 32767) / peak          # about -1 dBFS peak
    return array.array("h", (max(-32768, min(32767, int(v * gain))) for v in s))


def write_wav(path, pcm):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="en-AU-NatashaNeural")
    ap.add_argument("--pitch", default="+0Hz", help="e.g. -15Hz for a deeper voice")
    ap.add_argument("--rate", default="+5%", help="speaking speed, e.g. -5%%")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in CLIPS.items():
        pcm = to_pcm(await tts(text, a.voice, a.pitch, a.rate))
        write_wav(OUT / f"{name}.wav", pcm)
        print(f"{name:11s} {len(pcm)/RATE:4.2f}s  '{text}'")

asyncio.run(main())
