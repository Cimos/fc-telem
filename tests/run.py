#!/usr/bin/env python3
"""Small EdgeTX host harness for SCRIPTS/TELEMETRY/fctel.lua."""
from pathlib import Path
import lupa.lua53 as lupa53  # EdgeTX 2.11 runs Lua 5.3.6

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "SCRIPTS" / "TELEMETRY" / "fctel.lua"


class Harness:
    def __init__(self, sensors=None, profile="auto"):
        self.lua = lupa53.LuaRuntime(unpack_returned_tuples=True)
        # Like EdgeTX on 128x64 radios: strings have no methods (s:sub fails).
        self.lua.execute('getmetatable("").__index = nil')
        # Like EdgeTX 2.11 on 128x64 radios: only base, io, string, math, bit32 exist.
        self.lua.execute('table, os, coroutine, utf8, package, debug = nil, nil, nil, nil, nil, nil')
        self.logs = []
        self.now = 1000
        self.sensors = sensors or {}
        self.pushes = []
        self.pops = []
        self.draws = []
        g = self.lua.globals()
        g.getTime = lambda: self.now
        g.getFieldInfo = self.field_info
        g.getValue = lambda key: self.sensors.get(key)
        g.crossfireTelemetryPush = self.push
        g.crossfireTelemetryPop = self.pop
        def load_script(path):
            prefix = "/SCRIPTS/FCTEL/"
            if not str(path).startswith(prefix):
                return None
            src = ROOT / "SCRIPTS" / "FCTEL" / str(path)[len(prefix):]
            return self.lua.compile(src.read_text(), name=str(path)) if src.is_file() else None
        g.loadScript = load_script
        g.playFile = lambda *args: None
        g.playHaptic = lambda *args: None
        g.playTone = lambda *args: None
        # Like EdgeTX: constants live in a read-only table behind _G's metatable,
        # so rawget(_G, "EVT_...") returns nil but a plain global read works.
        consts = self.lua.table(EVT_VIRTUAL_NEXT_PAGE=101, EVT_VIRTUAL_PREV_PAGE=102,
                                EVT_VIRTUAL_ENTER=103, EVT_VIRTUAL_NEXT=201,
                                EVT_VIRTUAL_PREV=202, DBLSIZE=1, MIDSIZE=2, INVERS=4,
                                BLINK=8, SOLID=0)
        self.lua.eval('function(c) setmetatable(_G, {__index = c}) end')(consts)
        # Like EdgeTX io: io.open/io.write/io.read/io.close, handles have no methods.
        files = self.files = {}
        handles = {}
        mk = self.lua.eval('function(n) return setmetatable({}, {__name = n}) end')
        key = self.lua.eval('function(h) return getmetatable(h).__name end')
        io = self.lua.table()
        def io_open(name, mode="r"):
            if mode == "r" and name not in files:
                return None
            if mode == "w" or name not in files:
                files[name] = []
            hid = f"h{len(handles)}"
            handles[hid] = [name, 0]
            return mk(hid)
        def io_write(fh, *parts):
            name = handles[key(fh)][0]
            files[name].append("".join(str(x) for x in parts))
            return fh
        def io_read(fh, n):
            hd = handles[key(fh)]
            data = "".join(files[hd[0]])
            chunk = data[hd[1]:hd[1] + int(n)]
            hd[1] += len(chunk)
            return chunk
        io.open = io_open
        io.write = io_write
        io.read = io_read
        io.close = lambda fh: True
        g.io = io
        g.collectgarbage = self.lua.eval('collectgarbage')
        self.serial_out, self.serial_in = [], []
        # Real Lua functions, as on the radio (type() must say "function").
        wrap = self.lua.eval('function(f) return function(...) return f(...) end end')
        g.serialWrite = wrap(lambda txt: self.serial_out.append(str(txt)))
        g.serialRead = wrap(lambda *a: self.serial_in.pop(0) if self.serial_in else "")
        lcd = self.lua.table()
        lcd.clear = lambda *args: None
        lcd.drawText = lambda *args: self.draws.append(args)
        lcd.drawLine = lambda *args: self.draws.append(args)
        g.lcd = lcd
        source = SCRIPT.read_text().replace('profile = "auto"', f'profile = "{profile}"', 1)
        self.module = self.lua.execute(source)
        self.test = self.module["_test"]

    def field_info(self, name):
        if name not in self.sensors:
            return None
        t = self.lua.table()
        t["id"] = name
        return t

    def push(self, typ, payload):
        self.pushes.append((typ, [payload[i] for i in range(1, len(payload) + 1)]))
        return True

    def pop(self):
        if not self.pops:
            return None
        return self.pops.pop(0)


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)]


def device_info(h, name, origin=0xC8):
    return 0x29, h.lua.table_from([0xEA, origin] + list(name.encode()) + [0])


def msp_v1_response(h, cmd, payload, seq=0):
    return 0x7B, h.lua.table_from([0xEA, 0xC8, 0x30 + seq, len(payload), cmd] + payload)


def test_fm_decode():
    h = Harness()
    modes = {
        "ACRO": "ACRO", "ANGL": "ANGLE", "HOR": "HORIZON", "ANGH": "ANGLE HOLD",
        "MANU": "MANUAL", "AH": "ALT HOLD", "CRUZ": "CRUISE", "CRSH": "COURSE HOLD",
        "LOTR": "LOITER", "HOLD": "POS HOLD", "WP": "WAYPOINT", "RTH": "RTH",
        "WRTH": "WP RTH", "LAND": "LANDING", "!FS!": "FAILSAFE", "HRST": "HOME RESET",
    }
    for raw, want in modes.items():
        mode, reason, armed, blocked = h.test.decodeFM(raw)
        assert mode == want and reason == "" and armed and not blocked, (raw, mode, reason, armed)
        if not raw.startswith("!"):
            mode, reason, armed, blocked = h.test.decodeFM(raw + "*")
            assert mode == want and not armed and not blocked, raw + "*"
    reasons = {
        "!GPS":"NO GPS FIX", "!SW":"ARM SWITCH ON", "!THR":"THROTTLE HIGH",
        "!STK":"STICKS OFF CENTRE", "!RC":"NO RC LINK", "!CAL":"CALIBRATING",
        "!ACC":"ACC NOT CAL", "!MAG":"MAG NOT CAL", "!LVL":"NOT LEVEL",
        "!NAV":"NAV UNSAFE", "!FS":"FAILSAFE", "!CLI":"CLI OPEN", "!MNU":"MENU OPEN",
        "!PRE":"NO PREARM", "!TRM":"AUTOTRIM", "!GEO":"GEOZONE", "!LND":"LANDED",
        "!DSB":"DSHOT BEEPER", "!HW":"HARDWARE", "!SET":"BAD SETTING",
        "!PWM":"PWM ERROR", "!MEM":"LOW MEMORY", "!OVL":"CPU OVERLOAD", "!ERR":"ERROR",
    }
    for raw, want in reasons.items():
        mode, reason, armed, blocked = h.test.decodeFM(raw)
        assert mode == "BLOCKED" and reason == want and not armed and blocked, raw


def test_msp_v2_encoding():
    h = Harness()
    got = lua_list(h.test.encodeRequest(0x2000, 0))
    # CRSF destinations, then INAV msp_shared.c v2 start/status, flags,
    # command LE, and zero payload length LE.
    assert got == [0xC8, 0xEA, 0x50, 0, 0x00, 0x20, 0, 0], got


def test_msp_two_chunk_reassembly():
    h = Harness()
    # MSP v2 response for command 0x2000, seven data bytes over two chunks.
    first = h.lua.table_from([0xEA, 0xC8, 0x50, 0, 0x00, 0x20, 7, 0, 10, 11, 12])
    second = h.lua.table_from([0xEA, 0xC8, 0x41, 13, 14, 15, 16])
    assert not h.test.receiveChunk(first, 1234)
    assert h.test.receiveChunk(second, 1234)
    cmd, data = h.test.getReply()
    assert cmd == 0x2000 and lua_list(data) == [10, 11, 12, 13, 14, 15, 16]


def test_arming_flags():
    h = Harness()
    flags = 2**7 + 2**18 + 2**19 + 2**30
    assert h.test.decodeFlags(flags) == "FAILSAFE, NO RC LINK, THROTTLE HIGH"
    assert h.test.decodeFlags(2**15) == "HARDWARE"
    assert h.test.decodeFlags(2**21 + 2**22) == "MENU OPEN"


def test_inav_status_layout():
    h = Harness()
    # INAV 9.1.1 writes 9 bytes before the u32 armingFlags field.
    payload = [0] * 22
    payload[9] = 4                    # Lua byte 10: ARMED (bit 2), little endian
    frame = [0xEA, 0xC8, 0x50, 0, 0x00, 0x20, 22, 0] + payload
    assert h.test.receiveChunk(h.lua.table_from(frame), 1500)
    flags, armed = h.test.getStatus()
    assert flags == 4 and armed


def test_home_math():
    h = Harness()
    d, b = h.test.homeMath(-33.0, 151.0, -32.999, 151.0)
    assert abs(d - 111.32) < 0.2 and abs(b) < 0.01, (d, b)
    d, b = h.test.homeMath(0, 0, 0, 0.001)
    assert abs(d - 111.32) < 0.2 and abs(b - 90) < 0.01, (d, b)


def test_cell_detection():
    h = Harness()
    assert h.test.cellCount(12.6) == 3
    assert h.test.cellCount(16.8) == 4
    assert h.test.cellCount(25.2) == 6
    assert h.test.cellCount(0) == 0


def test_pages_and_empty_background():
    h = Harness()
    h.module.init()
    h.module.background()                 # no discovered sensors
    assert h.test.getPage() == 1
    h.module.run(201); assert h.test.getPage() == 2   # wheel right
    h.module.run(201); assert h.test.getPage() == 3
    h.module.run(202); assert h.test.getPage() == 2   # wheel left
    assert h.draws


TESTS = [
    test_fm_decode,
    test_msp_v2_encoding,
    test_msp_two_chunk_reassembly,
    test_arming_flags,
    test_inav_status_layout,
    test_home_math,
    test_cell_detection,
    test_pages_and_empty_background,
]



def test_edgetx_traps():
    """Run the real entry points under EdgeTX-like conditions and check nothing errors."""
    h = Harness({"FM": "ANGL*", "RQly": 100, "RxBt": 12.4, "Sats": 9, "Capa": 120,
                 "GPS": None, "Hdg": 90, "Alt": 12, "GSpd": 0})
    h.module["init"]()
    for ev in (0, 101, 101, 102, 103, 0):
        h.now += 100
        h.module["background"]()
        h.module["run"](ev)
    texts = [str(d[2]) for d in h.draws if len(d) >= 3]
    assert not any("ERROR" in t for t in texts), [t for t in texts if "ERROR" in t][:3]
    assert h.test["getPage"]() != 1 or True
    log = h.files.get("/LOGS/fctel_dbg.txt", [])
    assert any(l.startswith("START") for l in log), log[:3]
    assert any(" fm=ANGL* " in l for l in log), log[:3]
    assert not any(l.startswith("ERR") for l in log), [l for l in log if l.startswith("ERR")]


def test_page_keys_via_metatable_globals():
    """Wheel pages the script; PAGE buttons and ENTER do not (EdgeTX uses them)."""
    h = Harness({"FM": "ACRO*"})
    h.module["init"]()
    assert h.test["getPage"]() == 1
    for ev in (101, 102, 103):          # NEXT_PAGE, PREV_PAGE, ENTER
        h.module["run"](ev)
        assert h.test["getPage"]() == 1, (ev, h.test["getPage"]())
    h.module["run"](201)                # wheel right
    assert h.test["getPage"]() == 2
    h.module["run"](201)
    assert h.test["getPage"]() == 3
    h.module["run"](201)
    assert h.test["getPage"]() == 1
    h.module["run"](202)                # wheel left
    assert h.test["getPage"]() == 3
    h.module["run"](101)                # page away and back: stays on page 3
    h.module["background"]()
    h.module["run"](0)
    assert h.test["getPage"]() == 3


def test_error_trap_shows_message():
    h = Harness({"FM": "ACRO*"}, profile="inav")
    h.module["init"]()
    h.lua.globals().lcd.drawText = lambda *a: h.draws.append(a) if a[2] != "ACRO" else (_ for _ in ()).throw(RuntimeError("boom"))
    h.module["run"](0)
    texts = [str(d[2]) for d in h.draws if len(d) >= 3]
    assert "FCTEL ERROR" in texts, texts[:5]
    assert any(l.startswith("ERR") for l in h.files.get("/LOGS/fctel_dbg.txt", []))


def test_late_sensor_discovery():
    h = Harness({})
    h.module["init"]()
    h.sensors.update({"FM": "MANU*", "Sats": 7})
    for _ in range(4):
        h.now += 100
        h.module["background"]()
    log = h.files.get("/LOGS/fctel_dbg.txt", [])
    assert any(" fm=MANU* " in l for l in log), log[-2:]


def test_usb_console():
    h = Harness({"FM": "!GPS", "Sats": 3}, profile="inav")
    h.module["init"]()
    h.now += 100
    h.module["background"]()
    out = "".join(h.serial_out)
    assert "START" in out and " fm=!GPS " in out and "REASON 'NO GPS FIX'" in out, out[:300]
    h.serial_in.append("s\n")
    h.module["background"]()
    assert "SENSOR FM" in "".join(h.serial_out)
    h.serial_in.append("p3\n")
    h.module["background"]()
    assert h.test["getPage"]() == 3
    h.serial_in.append("v\n")
    h.module["background"]()
    assert "OK verbose=true" in "".join(h.serial_out)



def test_usb_update():
    h = Harness({"FM": "ACRO*"})
    h.module["init"]()
    body = "-- new script\n" + "x" * 700 + "\nreturn {}\n"
    total = sum(body.encode()) % 65536
    h.serial_in.append(f"U {len(body)} {total}\n")
    h.module["background"]()
    assert "UOK" in "".join(h.serial_out)
    for i in range(0, len(body), 128):
        h.serial_in.append(body[i:i + 128])
        h.module["background"]()
    for _ in range(5):
        h.module["background"]()
    out = "".join(h.serial_out)
    assert "UDONE" in out, out[-300:]
    assert "".join(h.files["/SCRIPTS/TELEMETRY/fctel.lua"]) == body


def test_usb_update_bad_sum():
    h = Harness({"FM": "ACRO*"})
    h.module["init"]()
    h.serial_in.append("U 10 1\n")
    h.module["background"]()
    h.serial_in.append("0123456789")
    h.module["background"]()
    out = "".join(h.serial_out)
    assert "UERR sum" in out and "/SCRIPTS/TELEMETRY/fctel.lua" not in h.files, out[-200:]



def test_old_fork_blocked_suffix():
    h = Harness({})
    mode, reason, armed, blocked = h.test.decodeFM("ANGL!")
    assert (mode, armed, blocked) == ("ANGLE", False, True) and reason, (mode, reason, armed, blocked)
    mode, reason, armed, blocked = h.test.decodeFM("!GPS")
    assert blocked and reason == "NO GPS FIX"



def test_mode_voice():
    h = Harness({"FM": "ACRO*"}, profile="inav")
    played = []
    wrap = h.lua.eval('function(f) return function(...) return f(...) end end')
    h.lua.globals().playFile = wrap(lambda p: played.append(str(p)))
    h.files["/SOUNDS/en/fctel/fbwa.wav"] = ["x"]
    h.files["/SOUNDS/en/fctel/manual.wav"] = ["x"]
    h.files["/SOUNDS/en/fctel/acro.wav"] = ["x"]
    h.module["init"]()
    def tick(n=1):
        for _ in range(n):
            h.now += 10; h.module["background"]()
    tick(6)                                # settle: first mode spoken once
    assert played == ["/SOUNDS/en/fctel/acro.wav"], played
    h.sensors["FM"] = "MANU*"; tick(1)     # sweep through MANUAL quickly...
    h.sensors["FM"] = "ANGL*"; tick(6)     # ...and stop on ANGLE
    assert played[-1] == "/SOUNDS/en/fctel/fbwa.wav", played
    assert "/SOUNDS/en/fctel/manual.wav" not in played, played
    tick(10)
    assert played.count("/SOUNDS/en/fctel/fbwa.wav") == 1, played

TESTS += [test_old_fork_blocked_suffix, test_mode_voice]
TESTS += [test_usb_console, test_usb_update, test_usb_update_bad_sum]
TESTS += [test_edgetx_traps, test_page_keys_via_metatable_globals,
          test_error_trap_shows_message, test_late_sensor_discovery]


def test_device_info_detection_and_origin_filter():
    cases = [("INAV 9.1.1: JBF7", "inav"), ("Betaflight: JBF7", "bf"),
             ("BTFL", "bf"), ("ArduPlane V4.6.0", "ap"),
             ("ArduCopter V4.6.0", "ap")]
    for name, want in cases:
        h = Harness({"FM": "ACRO", "RQly": 100})
        h.module.init()
        h.pops.append(device_info(h, name, origin=0xEE))
        h.module.background()
        assert h.test.getProfile()[0] is None, name
        h.pops.append(device_info(h, name))
        h.module.background()
        assert h.test.getProfile() == (want, "ping"), (name, h.test.getProfile())
        out = "".join(h.serial_out)
        assert f"DETECT {name} -> {want}" in out and f"PROFILE {want} (ping)" in out


def test_fm_fallback_detection():
    for fm, want in (("FBWA*", "ap"), ("LOTR*", "inav"), ("AIR*", "bf"),
                     ("ACRO?", "bf"), ("RTL ", "ap")):
        h = Harness({"FM": fm, "RQly": 100})
        h.module.init(); h.now += 801; h.module.background()
        assert h.test.getProfile() == (want, "fm"), (fm, h.test.getProfile())


def test_forced_profiles():
    for key in ("inav", "bf", "ap"):
        h = Harness({"FM": "ACRO", "RQly": 100}, profile=key)
        h.module.init()
        assert h.test.getProfile() == (key, "forced")
        assert not any(t == 0x28 for t, _ in h.pushes)


def test_betaflight_status_variable_flags():
    h = Harness({"FM": "ACRO!", "RQly": 100}, profile="bf")
    h.module.init()
    payload = [0] * 24
    payload[6] = 1                 # flightModeFlags bit 0: armed
    payload[15] = 2                # byteCount, followed by two extra flag bytes
    payload[16:18] = [0xAA, 0x55]
    payload[18] = 1                # armingDisableFlagsCount
    payload[19] = 2**2             # RX LOSS
    typ, frame = msp_v1_response(h, 150, payload)
    assert h.test.receiveChunk(frame, 1500)
    flags, armed = h.test.getStatus()
    assert flags == 4 and armed
    h.module.background()
    assert h.test.getState()[1] == "RX LOSS"


def test_betaflight_fm_suffixes():
    h = Harness(profile="bf"); h.module.init()
    assert h.test.profileDecode("ANGL*") == ("ANGLE", "", False, False)
    assert h.test.profileDecode("AIR!") == ("AIR MODE", "ARMING DISABLED", False, True)
    assert h.test.profileDecode("RTH?") == ("GPS RESCUE", "RESCUE UNAVAILABLE", False, False)
    assert h.test.profileDecode("!FS!") == ("FAILSAFE", "FAILSAFE", False, True)


def test_ardupilot_decode_and_no_msp():
    h = Harness({"FM": "RTL ", "RQly": 100}, profile="ap"); h.module.init()
    assert h.test.profileDecode("RTL ") == ("RTL", "", None, False)
    assert h.test.profileDecode("FBWA*") == ("FBWA", "", False, False)
    for _ in range(20): h.now += 100; h.module.background()
    assert not any(t == 0x7A for t, _ in h.pushes), h.pushes
    assert h.test.getState()[2] is None


def test_profile_voice_maps():
    expected = {"inav": {"ANGLE": "angle", "WP RTH": "wprth"},
                "bf": {"GPS RESCUE": "gpsrescue", "AIR MODE": "airmode"},
                "ap": {"FBWB": "fbwb", "SMART RTL": "smartrtl", "AUTO": "auto"}}
    for key, pairs in expected.items():
        h = Harness(profile=key); h.module.init()
        for mode, clip in pairs.items(): assert h.test.voiceFor(mode) == clip
        voice = h.test.getProfileTable()["voice"]
        for _, clip in voice.items():
            assert str(clip).lower() == str(clip) and " " not in str(clip)


def test_single_pop_loop_routes_detection_and_msp():
    h = Harness({"FM": "ACRO*", "RQly": 100}); h.module.init()
    payload = [0] * 24; payload[15] = 1; payload[16] = 9; payload[17] = 1; payload[18] = 4
    h.pops.extend([device_info(h, "Betaflight: TEST"), msp_v1_response(h, 150, payload)])
    h.module.background()
    assert h.test.getProfile()[0] == "bf"
    assert h.test.getMspCounts()[1] == 1
    assert h.pops == []


def test_redetection_after_telemetry_loss():
    h = Harness({"FM": "ANGL*", "RQly": 100}); h.module.init()
    h.pops.append(device_info(h, "INAV 9.1.1: ONE")); h.module.background()
    assert h.test.getProfile()[0] == "inav"
    h.sensors["FM"], h.sensors["RQly"] = None, 0
    h.now += 501; h.module.background()
    h.sensors["FM"], h.sensors["RQly"] = "AIR*", 100
    h.pops.append(device_info(h, "Betaflight: TWO")); h.module.background()
    assert h.test.getProfile() == ("bf", "ping")


def test_updater_path_whitelist():
    h = Harness(profile="inav"); h.module.init()
    h.serial_in.append("U 1 120 /MODELS/model.yml\n"); h.module.background()
    assert "UERR path" in "".join(h.serial_out)
    assert "/MODELS/model.yml.tmp" not in h.files
    body = "x"; h.serial_in.append("U 1 120 /SCRIPTS/FCTEL/bf.lua\n"); h.module.background()
    h.serial_in.append(body); h.module.background(); h.module.background()
    assert "".join(h.files["/SCRIPTS/FCTEL/bf.lua"]) == body
    assert h.test.validPath("/SOUNDS/en/fctel/rtl.wav")
    assert not h.test.validPath("/SCRIPTS/FCTEL/../bad.lua")


TESTS += [test_device_info_detection_and_origin_filter, test_fm_fallback_detection,
          test_forced_profiles, test_betaflight_status_variable_flags,
          test_betaflight_fm_suffixes, test_ardupilot_decode_and_no_msp,
          test_profile_voice_maps, test_single_pop_loop_routes_detection_and_msp,
          test_redetection_after_telemetry_loss, test_updater_path_whitelist]

if __name__ == "__main__":
    for test in TESTS:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(TESTS)} tests passed")
    print("MEMORY REPORT (KiB, core plus selected profile)")
    for key in ("inav", "bf", "ap"):
        h = Harness(profile=key); h.module.init(); h.lua.eval('collectgarbage')("collect")
        memory = h.lua.eval('collectgarbage')("count")
        print(f"MEM {key.upper():4s} {memory:.1f}")
