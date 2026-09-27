#!/usr/bin/env python3
"""Small EdgeTX host harness for SCRIPTS/TELEMETRY/inav.lua."""
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "SCRIPTS" / "TELEMETRY" / "inav.lua"


class Harness:
    def __init__(self, sensors=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
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
        g.EVT_VIRTUAL_NEXT_PAGE = 101
        g.EVT_VIRTUAL_PREV_PAGE = 102
        g.EVT_VIRTUAL_ENTER = 103
        g.DBLSIZE, g.MIDSIZE, g.INVERS, g.BLINK, g.SOLID = 1, 2, 4, 8, 0
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


if __name__ == "__main__":
    for test in TESTS:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(TESTS)} tests passed")
