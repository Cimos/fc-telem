-- FCTEL multi-firmware telemetry for 128x64 EdgeTX radios.
-- Values are in the units delivered by the named EdgeTX sensors.
local CFG = {
  profile = "auto",      -- auto | inav | bf | ap
  capacity = 1000,       -- usable pack capacity, mAh (MAD_CAPPY battery profile)
  lqWarn = 70,           -- link-quality warning, percent
  lqRepeat = 1000,       -- 10 ms ticks (10 seconds)
  cellWarn = 3.50,       -- low-cell warning, volts
  cellReady = 3.70,      -- minimum pre-flight cell voltage
  batteryRepeat = 1000,  -- 10 ms ticks
  reservePercent = 20,   -- capacity warning threshold
  reserveRepeat = 2000,  -- 20 seconds
  useWav = true,         -- false uses tones; missing WAVs also use tones
  sayModes = true,       -- speak every flight-mode change, armed or not
  angleAsFbwa = true,    -- say "F-B-W-A" for ANGLE (ArduPilot name); false says "angle"
  modeSettle = 40,       -- 10 ms ticks a mode must hold before it is spoken (skips switch sweeps)
  debugLog = true,       -- write /LOGS/fctel_dbg.txt once a second (for bench debugging)
  usbConsole = true,     -- stream the same lines over USB when the VCP port is set to LUA
  mspTimeout = 300,      -- 10 ms ticks to wait for an MSP reply (replies share the telemetry downlink)
  mspGap = 100,          -- 10 ms ticks between MSP requests; backs off to 5 s after 6 misses in a row
}

local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
local sin, cos, pi = math.sin, math.cos, math.pi
-- EdgeTX on 128x64 radios has no string metatable: s:sub() fails, use ssub(s, ...).
local ssub = string.sub
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local function band(a, b)
  local r, p = 0, 1
  while a > 0 and b > 0 do
    local aa, bb = a % 2, b % 2
    if aa == 1 and bb == 1 then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end
local function bxor(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    if a % 2 ~= b % 2 then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end
local function u16(b, i) return (b[i] or 0) + 256 * (b[i + 1] or 0) end

local sensorNames = {"FM", "RxBt", "Curr", "Capa", "Bat%", "GPS", "GSpd",
  "Hdg", "Alt", "Sats", "RQly", "1RSS", "RSNR", "TPWR", "VSpd"}
local sid, val = {}, {}

-- Only the selected firmware profile is retained. Until then raw FM is displayed.
local profile, profileKey, profileSource = nil, nil, nil
local function rawDecode(s)
  if type(s)~="string" or s=="" then return "UNKNOWN","",nil,false end
  return s,"",nil,false
end

local function homeMath(lat1, lon1, lat2, lon2)
  if not lat1 or not lon1 or not lat2 or not lon2 then return nil, nil end
  local r = pi / 180
  local y = (lat2 - lat1) * 111320
  local x = (lon2 - lon1) * 111320 * cos((lat1 + lat2) * .5 * r)
  local d = sqrt(x*x + y*y)
  local brg = atan2(x, y) / r
  if brg < 0 then brg = brg + 360 end
  return d, brg
end

local function cellCount(v)
  if type(v) ~= "number" or v < 3 then return 0 end
  local n = ceil(v / 4.35)
  if n < 1 then n = 1 elseif n > 12 then n = 12 end
  if v / n < 3.0 then return 0 end
  return n
end

-- MSP-over-CRSF -------------------------------------------------------------
local MSP_REQ, MSP_RESP = 0x7A, 0x7B
local FC, RADIO = 0xC8, 0xEA
local txSeq, reqAt, reqIndex, waiting, lastReply = 0, 0, 0, nil, -100000
local rx, rxSize, rxCmd, rxSeq, rxStarted = {}, 0, 0, 0, false
local statusFlags, statusSeen, mspArmed, navMode, navState = 0, false, false, 0, 0
local mspDistance, mspBearing, mspReason
local mspTx, mspRx, mspTimeouts, mspMiss = 0, 0, 0, 0
local verbose, ev = false, nil  -- ev(line) set below
local detectStart, lastPing, lastTelem, wasLost = 0, -100000, 0, false

local function loadProfile(key, source, detectedName)
  if key==profileKey and profile then return true end
  profile,profileKey,profileSource=nil,nil,nil; collectgarbage()
  local loader=loadScript("/SCRIPTS/FCTEL/"..key..".lua")
  if type(loader)~="function" then if ev then ev("PROFILE LOAD ERROR "..key) end return false end
  local ok,p=pcall(loader)
  if not ok or type(p)~="table" then if ev then ev("PROFILE LOAD ERROR "..key) end return false end
  profile=p; profileKey=key; profileSource=source
  reqIndex,waiting,rxStarted,statusSeen,mspDistance,mspBearing=0,nil,false,false,nil,nil
  mspReason=nil
  if detectedName and ev then ev("DETECT "..detectedName.." -> "..key) end
  if ev then ev("PROFILE "..key.." ("..source..")") end
  return true
end
local function pingProfile(name)
  if type(name)~="string" then return nil end
  if ssub(name,1,4)=="INAV" then return "inav" end
  if ssub(name,1,10)=="Betaflight" or ssub(name,1,4)=="BTFL" then return "bf" end
  if ssub(name,1,4)=="Ardu" or ssub(name,1,5)=="Rover" or string.find(name,"Plane",1,true) or string.find(name,"Copter",1,true) then return "ap" end
end
local apFM={FBWA=true,FBWB=true,CIRC=true,STAB=true,TRAN=true,CRUS=true,ATUN=true,AUTO=true,
  RTL=true,LOIT=true,TKOF=true,AVOI=true,GUID=true,INIT=true,QSTB=true,QHOV=true,QLOT=true,QLND=true,
  QRTL=true,QACO=true,QATN=true,THML=true,L2QL=true,ALND=true,LAND=true,DRIF=true,SPRT=true,
  FLIP=true,PHLD=true,BRAK=true,THRW=true,GNGP=true,SRTL=true,FHLD=true,FOLL=true,ZIGZ=true,
  SYSI=true,AROT=true,TRTL=true}
local inavFM={LOTR=true,CRUZ=true,CRSH=true,WRTH=true,AH=true,ANGH=true,HRST=true}
local bfFM={AIR=true,PASS=true,POSH=true,PHFL=true,CHIR=true}
local function guessFM(s)
  if type(s)~="string" then return nil end
  local last=ssub(s,-1); if last=="*" or last=="!" or last=="?" then s=ssub(s,1,-2) end
  while #s>0 and ssub(s,-1)==" " do s=ssub(s,1,-2) end
  if apFM[s] then return "ap" end
  if inavFM[s] or (ssub(s,1,1)=="!" and #s>=3 and #s<=4) then return "inav" end
  if bfFM[s] or last=="?" then return "bf" end
end
local function deviceInfo(p)
  if type(p)~="table" or p[2]~=FC then return end
  local name=""; local i=3
  while p[i] and p[i]~=0 do name=name..string.char(p[i]); i=i+1 end
  local key=pingProfile(name); if key then loadProfile(key,"ping",name) end
end

local function encodeRequest(cmd, seq)
  local p = {FC, RADIO}
  if cmd >= 0x1000 then
    p[3] = 0x50 + seq -- start + MSP v2
    p[4], p[5], p[6], p[7], p[8] = 0, cmd % 256, floor(cmd/256), 0, 0
  else
    p[3], p[4], p[5] = 0x30 + seq, 0, cmd -- start + MSP v1
    p[6] = bxor(0, cmd)
  end
  return p
end

local function sendRequest(cmd)
  local p = encodeRequest(cmd, txSeq)
  if crossfireTelemetryPush(MSP_REQ, p) then
    txSeq = (txSeq + 1) % 16; waiting = cmd; reqAt = getTime(); mspTx = mspTx + 1
    if verbose and ev then ev("MSP TX " .. cmd .. " seq " .. txSeq) end
    rxStarted = false
  end
end

local function parseReply(cmd, b)
  -- MSP_FC_VARIANT (2): four letters, "INAV" or "BTFL". Used to identify INAV,
  -- which never answers the CRSF device ping. Handled before a profile exists.
  if cmd == 2 then
    if #b >= 4 then
      local v = string.char(b[1], b[2], b[3], b[4])
      if ev then ev("FC VARIANT " .. v) end
      if not profile and CFG.profile == "auto" then
        if v == "INAV" then loadProfile("inav", "msp", "INAV")
        elseif v == "BTFL" then loadProfile("bf", "msp", "Betaflight") end
      end
    end
    return
  end
  if not profile then return end
  local r=profile.parseReply(cmd,b) or {}
  if r.flags~=nil then statusFlags=r.flags; statusSeen=true end
  if r.armed~=nil then mspArmed=r.armed; statusSeen=true end
  if r.distance~=nil then mspDistance=r.distance end
  if r.bearing~=nil then mspBearing=r.bearing end
  if r.navMode~=nil then navMode=r.navMode end
  if r.navState~=nil then navState=r.navState end
  if r.reason~=nil then mspReason=r.reason end
end

local function receiveChunk(p, now)
  if type(p) ~= "table" or p[1] ~= RADIO or p[2] ~= FC or not p[3] then return false end
  local st, i = p[3], 4
  local seq, ver = band(st,15), floor(band(st,0x60)/32)
  if band(st,0x10) ~= 0 then
    rx, rxStarted, rxSeq = {}, true, seq
    if ver == 1 then
      rxSize, rxCmd, i = p[4] or 0, p[5] or 0, 6
    elseif ver == 2 then
      rxCmd, rxSize, i = u16(p,5), u16(p,7), 9
    else rxStarted = false; return false end
  elseif not rxStarted or seq ~= (rxSeq + 1) % 16 then
    rxStarted = false; return false
  else rxSeq = seq end
  while i <= #p and #rx < rxSize do rx[#rx+1] = p[i]; i = i + 1 end
  if #rx >= rxSize then
    rxStarted = false; lastReply = now or getTime(); waiting = nil; mspRx = mspRx + 1; mspMiss = 0
    if verbose and ev then ev("MSP RX " .. rxCmd .. " len " .. #rx) end
    parseReply(rxCmd, rx); return true
  end
  return false
end

local function pollTelemetry(now)
  while true do
    local typ, p = crossfireTelemetryPop()
    if not typ then break end
    if typ == MSP_RESP then receiveChunk(p, now) end
    if typ == 0x29 then deviceInfo(p) end
  end
  if waiting and now - reqAt > CFG.mspTimeout then
    if ev then ev("MSP TIMEOUT " .. waiting) end
    waiting = nil; rxStarted = false; mspTimeouts = mspTimeouts + 1; mspMiss = mspMiss + 1
  end
  local gap = (mspMiss >= 6) and 500 or CFG.mspGap
  local commands=profile and profile.msp
  if commands and #commands>0 and not waiting and now - reqAt >= gap then
    reqIndex = reqIndex % #commands + 1; sendRequest(commands[reqIndex])
  end
end

-- State and alerts ----------------------------------------------------------
local page, cells, armed, prevArmed = 1, 0, nil, nil
local mode, reason, blocked = "UNKNOWN", "", false
local homeLat, homeLon, homeSet, distance, bearing = nil, nil, false, nil, nil
local armedTicks, armTick, lastBg = 0, 0, 0
local lastMode, lastReason = "", ""
local pendingMode, pendingAt, spokenMode = nil, 0, nil
local lastLq, lastBat, lastReserve, lastRefused = -100000, -100000, -100000, -100000
local startCapa, efficiency, flownKm = nil, nil, 0
local lastLat, lastLon

local function tone(kind)
  if kind == "urgent" then playTone(1200,180,40); playHaptic(180,60)
  elseif kind == "warn" then playTone(850,140,30)
  else playTone(1800,100,20) end
end
local function sayMode(m, urgent)
  local f = profile and profile.voice[m]
  if profileKey=="inav" and m == "ANGLE" and CFG.angleAsFbwa then f = "fbwa" end
  if ev then ev("SAY " .. tostring(f or m)) end
  local played = false
  if CFG.useWav and f and io and io.open then
    local h = io.open("/SOUNDS/en/fctel/" .. f .. ".wav", "r")
    if h then io.close(h); playFile("/SOUNDS/en/fctel/" .. f .. ".wav"); played = true end
  end
  if not played then tone(urgent and "urgent" or "mode")
  elseif urgent then playHaptic(180,60) end
end

local function readSensors()
  for i=1,#sensorNames do
    local id = sid[i]
    if id then
      local v = getValue(id)
      if v ~= nil then val[i] = v end
    end
  end
end
local function V(name)
  for i=1,#sensorNames do if sensorNames[i] == name then return val[i] end end
end

local function updateState(now)
  local decoder=profile and profile.decodeFM or rawDecode
  local fmMode, fmReason, fmArmed, fmBlocked = decoder(V("FM"))
  local fresh = statusSeen and now - lastReply < 500
  mode, reason, blocked = fmMode, fmReason, fmBlocked
  armed = fresh and mspArmed or fmArmed
  if fresh then
    reason = mspReason or reason; blocked = not armed and reason ~= ""
  end
  local gps = V("GPS")
  if armed==true and prevArmed~=true then
    armTick = now; startCapa = V("Capa") or 0; flownKm = 0
    if type(gps)=="table" and gps.lat and gps.lon then
      homeLat, homeLon, homeSet = gps.lat, gps.lon, true
      lastLat, lastLon = gps.lat, gps.lon
    end
  elseif armed~=true and prevArmed==true then
    armedTicks = armedTicks + now - armTick; lastLat, lastLon = nil, nil
  elseif armed==true and type(gps)=="table" and gps.lat and gps.lon then
    if lastLat then
      local step = homeMath(lastLat,lastLon,gps.lat,gps.lon)
      if step and step < 1000 then flownKm = flownKm + step/1000 end
    end
    lastLat, lastLon = gps.lat, gps.lon
  end
  prevArmed = armed
  if not homeSet and armed==nil and (V("Sats") or 0)>=6 and type(gps)=="table" and gps.lat and gps.lon then
    homeLat,homeLon,homeSet=gps.lat,gps.lon,true
  end
  if armed then -- current flight time is accumulated only at display time
  end
  if fresh and mspDistance then distance, bearing, homeSet = mspDistance, mspBearing, true
  elseif homeSet and type(gps)=="table" then distance, bearing = homeMath(gps.lat,gps.lon,homeLat,homeLon) end
  local vb = V("RxBt")
  if cells == 0 then cells = cellCount(vb) end
  local capa = V("Capa") or 0
  if flownKm > .1 and startCapa then
    local used = capa - startCapa
    if used > 20 then efficiency = used / flownKm end
  end
end

local function doAlerts(now)
  -- Speak a mode once it has held for CFG.modeSettle, so a quick sweep across the
  -- switch only announces where it stops. Armed or disarmed, when CFG.sayModes is on;
  -- otherwise only while armed (the old behaviour).
  if mode ~= lastMode then pendingMode, pendingAt = mode, now end
  if pendingMode and now - pendingAt >= CFG.modeSettle then
    local m = pendingMode; pendingMode = nil
    if m ~= spokenMode and m ~= "UNKNOWN" and m ~= "BLOCKED" and (CFG.sayModes or armed) then
      sayMode(m, armed and (m == "RTH" or m == "FAILSAFE")); spokenMode = m
    end
  end
  if not armed and blocked and reason ~= lastReason and now-lastRefused >= 500 then
    tone("urgent"); lastRefused = now
  end
  local lq = V("RQly")
  if armed and type(lq)=="number" and lq < CFG.lqWarn and now-lastLq >= CFG.lqRepeat then tone("warn"); lastLq=now end
  local vb = V("RxBt")
  if armed and cells>0 and type(vb)=="number" and vb/cells < CFG.cellWarn and now-lastBat >= CFG.batteryRepeat then tone("warn"); lastBat=now end
  local remain = CFG.capacity-(V("Capa") or 0)
  if armed and remain < CFG.capacity*CFG.reservePercent/100 and now-lastReserve >= CFG.reserveRepeat then tone("warn"); lastReserve=now end
  lastMode, lastReason = mode, reason
end

local function init()
  for i=1,#sensorNames do
    local f = getFieldInfo(sensorNames[i])
    sid[i] = f and f.id or nil
  end
  lastBg = getTime(); reqAt = lastBg - 50; detectStart=lastBg; lastTelem=lastBg
  if CFG.profile~="auto" then loadProfile(CFG.profile,"forced")
  else crossfireTelemetryPush(0x28,{0x00,RADIO}); lastPing=lastBg end
end

local lastResolve, lastDump, dumpLines, lastErr = 0, 0, 0, nil
local function resolveSensors()
  for i=1,#sensorNames do
    if not sid[i] then
      local f = getFieldInfo(sensorNames[i])
      sid[i] = f and f.id or nil
    end
  end
end
local usb = CFG.usbConsole and type(serialWrite) == "function"
local function ulog(line) if usb then pcall(serialWrite, line .. "\r\n") end end
local function dlog(line)
  ulog(line)
  if not CFG.debugLog or not io then return end
  local f = io.open("/LOGS/fctel_dbg.txt", dumpLines > 900 and "w" or "a")
  if dumpLines > 900 then dumpLines = 0 end
  if f then io.write(f, line, "\n"); io.close(f); dumpLines = dumpLines + 1 end
end
local function S(v) if v == nil then return "-" end return tostring(v) end
local function dump(now)
  local g = V("GPS")
  local gs = type(g) == "table" and (S(g.lat) .. "," .. S(g.lon)) or S(g)
  dlog(S(now) .. " fm=" .. S(V("FM")) .. " mode=" .. S(mode) .. " arm=" .. S(armed) ..
    " blk=" .. S(blocked) .. " why=" .. S(reason) .. " sat=" .. S(V("Sats")) ..
    " lq=" .. S(V("RQly")) .. " rxbt=" .. S(V("RxBt")) .. " capa=" .. S(V("Capa")) ..
    " gps=" .. gs .. " home=" .. S(homeSet) .. " dist=" .. S(distance) ..
    " msp=" .. S(mspTx) .. "/" .. S(mspRx) .. "/" .. S(mspTimeouts) ..
    " flags=" .. S(statusFlags) .. " nav=" .. S(navMode) .. "/" .. S(navState) ..
    " page=" .. S(page) .. " mem=" .. S(math.floor(collectgarbage("count"))))
end
ev = function(line) dlog("EV " .. S(getTime()) .. " " .. line) end
local prevMode, prevReason = nil, nil
local function sensorList()
  for i=1,#sensorNames do ulog("SENSOR " .. sensorNames[i] .. " id=" .. S(sid[i]) .. " val=" .. S(val[i])) end
end
-- Over-USB update. Host sends "U <size> <sum> [path]\n", then raw bytes in chunks of at most
-- 128 (the Lua serial FIFO is 256). Each read is acked with "UACK <bytes so far>".
-- The file lands at path.tmp, is checked, then copied over path a block at a time.
local up = nil
local function validPath(path)
  return path=="/SCRIPTS/TELEMETRY/fctel.lua"
    or string.match(path,"^/SCRIPTS/FCTEL/[A-Za-z0-9_%-]+%.lua$")~=nil
    or string.match(path,"^/SOUNDS/en/fctel/[A-Za-z0-9_%-]+%.wav$")~=nil
end
local function upStart(size, sum, path)
  path=path or "/SCRIPTS/TELEMETRY/fctel.lua"
  if not validPath(path) then ulog("UERR path"); return end
  local tmp=path..".tmp"; local fh = io.open(tmp, "w")
  if not fh then ulog("UERR open"); return end
  up = {size=size,sum=sum,got=0,acc=0,fh=fh,phase=1,tmp=tmp,dstPath=path,last=getTime()}
  ulog("UOK " .. size)
end
local function upStep()
  if up.phase == 1 then
    local ok, c = pcall(serialRead, 128)
    if not ok or type(c) ~= "string" or #c == 0 then
      -- Abandon a transfer that stalls for 5 s, so the script is never left
      -- swallowing serial input as file data. The target file is untouched.
      if getTime() - up.last > 500 then
        io.close(up.fh); ulog("UERR timeout at " .. up.got); up = nil
      end
      return
    end
    up.last = getTime()
    local need = up.size - up.got
    if #c > need then c = ssub(c, 1, need) end
    io.write(up.fh, c)
    local acc, byte = up.acc, string.byte
    for i = 1, #c do acc = (acc + byte(c, i)) % 65536 end
    up.acc, up.got = acc, up.got + #c
    ulog("UACK " .. up.got)
    if up.got >= up.size then
      io.close(up.fh)
      if up.acc ~= up.sum then ulog("UERR sum " .. up.acc .. " want " .. up.sum); up = nil; return end
      up.src, up.dst, up.copied, up.phase = io.open(up.tmp, "r"), io.open(up.dstPath, "w"), 0, 2
      if not up.src or not up.dst then ulog("UERR copy"); up = nil end
    end
  else
    local d = io.read(up.src, 512)
    if d and #d > 0 then io.write(up.dst, d); up.copied = up.copied + #d end
    if not d or #d < 512 then
      io.close(up.src); io.close(up.dst)
      ulog("UDONE " .. up.copied .. " (power-cycle the radio to run it)"); up = nil
    end
  end
end
local function command(c)
  local size, sum, path = string.match(c, "^U (%d+) (%d+)%s*(.-)%s*$")
  if size then upStart(tonumber(size), tonumber(sum),path~="" and path or nil); return end
  c = string.gsub(c, "[%s]+", "")
  if c == "" then return end
  if c == "d" then dump(getTime())
  elseif c == "v" then verbose = not verbose; ulog("OK verbose=" .. S(verbose))
  elseif c == "s" then sensorList()
  elseif c == "p1" or c == "p2" or c == "p3" then page = tonumber(ssub(c, 2)); ulog("OK page=" .. S(page))
  elseif c == "e" then ulog("LASTERR " .. S(lastErr))
  else ulog("CMDS d=dump v=verbose s=sensors p1..p3=page e=last error") end
end
local function background()
  local now = getTime()
  if now - lastResolve >= 200 then resolveSensors(); lastResolve = now end
  readSensors()
  local fm,lq=V("FM"),V("RQly"); local live=type(fm)=="string" and fm~="" and lq~=0
  if live then
    if wasLost and CFG.profile=="auto" then
      profile,profileKey,profileSource=nil,nil,nil; collectgarbage(); detectStart=now; lastPing=-100000
      waiting=nil; statusSeen=false; mspReason=nil
    end
    lastTelem=now; wasLost=false
  elseif now-lastTelem>=500 then wasLost=true end
  if CFG.profile=="auto" and not profile then
    -- 1. CRSF device ping: Betaflight and ArduPilot answer with their name.
    if now-lastPing>=200 then crossfireTelemetryPush(0x28,{0x00,RADIO}); lastPing=now end
    -- 2. After 3 s, MSP_FC_VARIANT: INAV (and Betaflight) answer "INAV"/"BTFL".
    --    ArduPilot has no MSP over CRSF, so this just times out there.
    if live and now-detectStart>=300 and not waiting and now-reqAt>=150 then sendRequest(2) end
    -- 3. After 10 s, guess from the flight-mode string.
    if now-detectStart>=1000 then local g=guessFM(fm); if g then loadProfile(g,"fm") end end
  end
  pollTelemetry(now); updateState(now); doAlerts(now); lastBg = now
  if mode ~= prevMode then ev("MODE " .. S(prevMode) .. " -> " .. S(mode)); prevMode = mode end
  if reason ~= prevReason then ev("REASON '" .. S(reason) .. "'"); prevReason = reason end
  if up then upStep()
  elseif usb and type(serialRead) == "function" then
    local ok, c = pcall(serialRead)
    if ok and type(c) == "string" and #c > 0 then command(c) end
  end
  if (CFG.debugLog or usb) and now - lastDump >= 100 then dump(now); lastDump = now end
end

-- Display -------------------------------------------------------------------
local Z, DBL, MID, INVBL = 0, DBLSIZE or 0, MIDSIZE or 0, (INVERS or 0)+(BLINK or 0)
local function txt(x,y,s,f) lcd.drawText(x,y,tostring(s or "--"),f or Z) end
local function num(v, decimals)
  if type(v)~="number" then return "--" end
  if decimals then return string.format("%.1f",v) end
  return tostring(floor(v+.5))
end
local function arrow(x,y,a)
  local r=(a or 0)*pi/180; local sx,sy=sin(r),-cos(r)
  local px,py=-sy,sx
  lcd.drawLine(x+floor(sx*6),y+floor(sy*6),x+floor(-sx*4+px*3),y+floor(-sy*4+py*3),SOLID or 0,Z)
  lcd.drawLine(x+floor(sx*6),y+floor(sy*6),x+floor(-sx*4-px*3),y+floor(-sy*4-py*3),SOLID or 0,Z)
  lcd.drawLine(x+floor(-sx*4+px*3),y+floor(-sy*4+py*3),x+floor(-sx*4-px*3),y+floor(-sy*4-py*3),SOLID or 0,Z)
end
local function flightSeconds(now)
  return floor((armedTicks + (armed==true and now-armTick or 0))/100)
end
local function timerText(s)
  local m=floor(s/60); return string.format("%02d:%02d",m,s-m*60)
end
local function activeWarning()
  local lq, vb = V("RQly"), V("RxBt")
  if mode=="FAILSAFE" then return "FAILSAFE" end
  if type(lq)=="number" and lq<CFG.lqWarn then return "LOW LINK" end
  if cells>0 and type(vb)=="number" and vb/cells<CFG.cellWarn then return "LOW BATTERY" end
  return nil
end

local function drawMain(now)
  local mf = (#mode > 10) and MID or DBL
  txt(0,0,mode,mf); txt(78,0,num(V("RxBt"),true).."V"); txt(112,0,profile and profile.name or "--")
  txt(96,7,num(V("Curr"),true).."A")
  txt(0,16,armed==true and "ARMED" or (blocked and "BLOCKED" or (armed==nil and "--" or "READY")),armed==true and INVERS or Z)
  txt(48,16,"SAT "..num(V("Sats"))..((V("Sats") or 0)>=6 and "+" or "-")); txt(96,16,"LQ"..num(V("RQly")))
  txt(0,25,"ALT "..num(V("Alt")).."m"); txt(65,25,"SPD "..num(V("GSpd")))
  txt(0,34,"HOME "..num(distance).."m")
  local hdg=V("Hdg") or 0; arrow(115,37,((bearing or hdg)-hdg)%360)
  local used=V("Capa") or 0; txt(0,43,"USED "..num(used).."mAh"); txt(75,43,"LEFT "..num(math.max(0,CFG.capacity-used)))
  txt(0,55,timerText(flightSeconds(now)),INVERS)
  local w = armed and activeWarning() or (blocked and reason or nil)
  if w then txt(39,55,w,INVBL) else txt(74,55,"MAD_CAPPY") end
end

local function drawLink()
  local vb, used = V("RxBt"), V("Capa") or 0
  local pc = cells>0 and vb/cells or nil
  txt(0,0,"LINK + BATTERY",INVERS)
  txt(0,9,"RSSI "..num(V("1RSS")).." dBm"); txt(68,9,"SNR "..num(V("RSNR")))
  txt(0,18,"LQ "..num(V("RQly")).."%"); txt(68,18,"PWR "..num(V("TPWR")).."mW")
  txt(0,27,"PACK "..num(vb,true).."V"); txt(68,27,(cells>0 and (cells.."S ") or "")..num(pc,true).."V")
  txt(0,36,"USED "..num(used)); txt(68,36,"LEFT "..num(math.max(0,CFG.capacity-used)))
  local range = efficiency and math.max(0,CFG.capacity-used)/efficiency or nil
  txt(0,45,"EFF "..num(efficiency).."mAh/km"); txt(0,54,"RANGE "..num(range,true).."km")
  txt(85,54,"VS "..num(V("VSpd"),true))
end

local function checklistRow(y,label,ok,fail)
  txt(0,y,label); txt(91,y,ok and "OK" or fail,ok and INVERS or Z)
end
local function isNavMode(m)
  return profile and profile.navModes[m] or false
end
local function drawChecklist()
  local sats=V("Sats") or 0; local vb=V("RxBt"); local lq=V("RQly") or 0
  local gps=sats>=6; local bat=cells>0 and type(vb)=="number" and vb/cells>=CFG.cellReady
  local link=lq>=90; local modeok=not isNavMode(mode); local armok=armed~=nil and not blocked
  local all=gps and homeSet and bat and link and modeok and armok
  txt(0,0,all and "READY TO FLY" or "PRE-FLIGHT",INVERS)
  checklistRow(9,"GPS FIX",gps,"NO FIX"); checklistRow(18,"HOME",homeSet,"NOT SET")
  checklistRow(27,"BATTERY",bat,"LOW"); checklistRow(36,"LINK",link,"WEAK")
  checklistRow(45,"MODE",modeok,"NAV ON"); checklistRow(54,"ARMING",armok,armed==nil and "--" or (reason~="" and reason or "BLOCKED"))
end

local function run(event)
  background()
  -- Scroll wheel changes the script's page. PAGE buttons are left to EdgeTX so they
  -- move between telemetry screens; the page number is kept, so coming back to this
  -- screen shows the page you left. The script always starts on the main page.
  local nxt, prv = EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV
  if event and nxt and event == nxt then page = page % 3 + 1
  elseif event and prv and event == prv then page = (page + 1) % 3 + 1 end
  lcd.clear()
  if page==1 then drawMain(getTime()) elseif page==2 then drawLink() else drawChecklist() end
  return 0
end

local function trap(fn, arg)
  local ok, e = pcall(fn, arg)
  if not ok and e ~= lastErr then lastErr = e; dlog("ERR " .. tostring(e)) end
  return ok
end
local function safeRun(event)
  if not trap(run, event) then
    lcd.clear(); lcd.drawText(0, 0, "FCTEL ERROR", INVERS or 0)
    local m = tostring(lastErr or "?")
    for i = 0, 5 do lcd.drawText(0, 9 + i * 9, ssub(m, i * 21 + 1, i * 21 + 21), 0) end
  end
  return 0
end
local function safeBg() trap(background) end
local function safeInit() trap(init); dlog("START " .. tostring(getTime())) end

local function testDecode(s) if not profile then loadProfile("inav","test") end return profile.decodeFM(s) end
local function testFlags(f) if not profile then loadProfile("inav","test") end return profile._flagText and profile._flagText(f) or "" end
local function testReceive(p,n) if not profile then loadProfile("inav","test") end return receiveChunk(p,n) end
return {init=safeInit,run=safeRun,background=safeBg,
  _test={decodeFM=testDecode,encodeRequest=encodeRequest,receiveChunk=testReceive,
    decodeFlags=testFlags,homeMath=homeMath,cellCount=cellCount,getPage=function() return page end,
    getReply=function() return rxCmd,rx end,
    getStatus=function() return statusFlags,mspArmed end,
    getState=function() return mode,reason,armed,blocked end,
    getMspCounts=function() return mspTx,mspRx,mspTimeouts end,
    profileDecode=function(s) if profile then return profile.decodeFM(s) end end,
    voiceFor=function(m) return profile and profile.voice[m] end,
    getProfileTable=function() return profile end,
    getProfile=function() return profileKey,profileSource end,
    forceProfile=loadProfile,guessFM=guessFM,validPath=validPath}}
