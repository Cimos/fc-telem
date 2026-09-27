#!/usr/bin/env python3
"""Generate the flight-mode voice clips for inav.lua.

Microsoft neural TTS (edge-tts) -> MP3 -> 32 kHz 16-bit mono PCM WAV, the format
EdgeTX voice packs use. Silence is trimmed and each clip is normalised to the same
peak, so they all sound alike on the radio.

Usage: .venv/bin/python tools/make_voices.py [--voice en-AU-NatashaNeural]
Writes SOUNDS/en/inav/<name>.wav; copy that folder to the radio's SD card.
"""
import argparse, array, asyncio, io, wave
from pathlib import Path
import edge_tts, miniaudio

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "SOUNDS" / "en" / "inav"
RATE = 32000

# file name (matches wavName in inav.lua) -> spoken phrase
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
}


async def tts(text, voice):
    buf = bytearray()
    async for chunk in edge_tts.Communicate(text, voice, rate="+5%").stream():
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
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in CLIPS.items():
        pcm = to_pcm(await tts(text, a.voice))
        write_wav(OUT / f"{name}.wav", pcm)
        print(f"{name:11s} {len(pcm)/RATE:4.2f}s  '{text}'")

asyncio.run(main())
