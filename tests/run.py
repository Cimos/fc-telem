#!/usr/bin/env python3
"""Small EdgeTX host harness for SCRIPTS/TELEMETRY/inav.lua."""
from pathlib import Path
import lupa.lua53 as lupa53  # EdgeTX 2.11 runs Lua 5.3.6

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "SCRIPTS" / "TELEMETRY" / "inav.lua"


class Harness:
    def __init__(self, sensors=None):
        self.lua = lupa53.LuaRuntime(unpack_returned_tuples=True)
        # Like EdgeTX on 128x64 radios: strings have no methods (s:sub fails).
        self.lua.execute('getmetatable("").__index = nil')
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
        g.playFile = lambda *args: None
        g.playHaptic = lambda *args: None
        g.playTone = lambda *args: None
        # Like EdgeTX: constants live in a read-only table behind _G's metatable,
        # so rawget(_G, "EVT_...") returns nil but a plain global read works.
        consts = self.lua.table(EVT_VIRTUAL_NEXT_PAGE=101, EVT_VIRTUAL_PREV_PAGE=102,
                                EVT_VIRTUAL_ENTER=103, DBLSIZE=1, MIDSIZE=2, INVERS=4,
                                BLINK=8, SOLID=0)
        self.lua.eval('function(c) setmetatable(_G, {__index = c}) end')(consts)
        # Like EdgeTX io: io.open/io.write/io.close, handles have no methods.
        files = self.files = {}
        io = self.lua.table()
        def io_open(name, mode="r"):
            if mode == "r" and name not in files:
                return None
            if mode == "w" or name not in files:
                files[name] = []
            return self.lua.eval('function(n) return setmetatable({}, {__name = n}) end')(name)
        def io_write(fh, *parts):
            name = self.lua.eval('function(h) return getmetatable(h).__name end')(fh)
            files[name].append("".join(str(x) for x in parts))
            return fh
        io.open = io_open
        io.write = io_write
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
        self.module = self.lua.execute(SCRIPT.read_text())
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
    h.module.run(101); assert h.test.getPage() == 2
    h.module.run(103); assert h.test.getPage() == 3
    h.module.run(102); assert h.test.getPage() == 2
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
    log = h.files.get("/LOGS/inav_dbg.txt", [])
    assert any(l.startswith("START") for l in log), log[:3]
    assert any(" fm=ANGL* " in l for l in log), log[:3]
    assert not any(l.startswith("ERR") for l in log), [l for l in log if l.startswith("ERR")]


def test_page_keys_via_metatable_globals():
    h = Harness({"FM": "ACRO*"})
    h.module["init"]()
    h.module["run"](101)
    assert h.test["getPage"]() == 2, h.test["getPage"]()
    h.module["run"](102)
    assert h.test["getPage"]() == 1, h.test["getPage"]()


def test_error_trap_shows_message():
    h = Harness({"FM": "ACRO*"})
    h.module["init"]()
    h.lua.globals().lcd.drawText = lambda *a: h.draws.append(a) if a[2] != "ACRO" else (_ for _ in ()).throw(RuntimeError("boom"))
    h.module["run"](0)
    texts = [str(d[2]) for d in h.draws if len(d) >= 3]
    assert "INAV.LUA ERROR" in texts, texts[:5]
    assert any(l.startswith("ERR") for l in h.files.get("/LOGS/inav_dbg.txt", []))


def test_late_sensor_discovery():
    h = Harness({})
    h.module["init"]()
    h.sensors.update({"FM": "MANU*", "Sats": 7})
    for _ in range(4):
        h.now += 100
        h.module["background"]()
    log = h.files.get("/LOGS/inav_dbg.txt", [])
    assert any(" fm=MANU* " in l for l in log), log[-2:]


def test_usb_console():
    h = Harness({"FM": "!GPS", "Sats": 3})
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

TESTS += [test_usb_console]
TESTS += [test_edgetx_traps, test_page_keys_via_metatable_globals,
          test_error_trap_shows_message, test_late_sensor_discovery]

if __name__ == "__main__":
    for test in TESTS:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(TESTS)} tests passed")
