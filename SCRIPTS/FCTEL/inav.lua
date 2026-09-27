-- Profile interface: name is the screen tag; decodeFM(s) returns mode, reason,
-- armed (boolean or nil), blocked; msp is the command-id poll list;
-- parseReply(cmd, bytes) returns any of flags, reason, armed, distance, bearing,
-- navMode, navState; navModes is a set of display names; voice maps every
-- reported display name to a lowercase, no-space clip basename.
local floor = math.floor
local ssub = string.sub
local function band(a,b)
  local r,p=0,1
  while a>0 and b>0 do
    if a%2==1 and b%2==1 then r=r+p end
    a,b,p=floor(a/2),floor(b/2),p*2
  end
  return r
end
local function has(v,n) return band(v or 0,2^n)~=0 end
local function u16(b,i) return (b[i] or 0)+256*(b[i+1] or 0) end
local function u32(b,i) return u16(b,i)+65536*u16(b,i+2) end

local modes={ACRO="ACRO",ANGL="ANGLE",HOR="HORIZON",ANGH="ANGLE HOLD",
  MANU="MANUAL",AH="ALT HOLD",CRUZ="CRUISE",CRSH="COURSE HOLD",
  LOTR="LOITER",HOLD="POS HOLD",WP="WAYPOINT",RTH="RTH",WRTH="WP RTH",
  LAND="LANDING",["!FS!"]="FAILSAFE",HRST="HOME RESET"}
local reasons={["!GPS"]="NO GPS FIX",["!SW"]="ARM SWITCH ON",["!THR"]="THROTTLE HIGH",
  ["!STK"]="STICKS OFF CENTRE",["!RC"]="NO RC LINK",["!CAL"]="CALIBRATING",
  ["!ACC"]="ACC NOT CAL",["!MAG"]="MAG NOT CAL",["!LVL"]="NOT LEVEL",
  ["!NAV"]="NAV UNSAFE",["!FS"]="FAILSAFE",["!CLI"]="CLI OPEN",["!MNU"]="MENU OPEN",
  ["!PRE"]="NO PREARM",["!TRM"]="AUTOTRIM",["!GEO"]="GEOZONE",["!LND"]="LANDED",
  ["!DSB"]="DSHOT BEEPER",["!HW"]="HARDWARE",["!SET"]="BAD SETTING",
  ["!PWM"]="PWM ERROR",["!MEM"]="LOW MEMORY",["!OVL"]="CPU OVERLOAD",["!ERR"]="ERROR"}
local flagReasons={{7,"FAILSAFE"},{16,"FAILSAFE"},{18,"NO RC LINK"},{15,"HARDWARE"},
  {26,"BAD SETTING"},{27,"PWM ERROR"},{25,"LOW MEMORY"},{10,"CPU OVERLOAD"},
  {14,"ARM SWITCH ON"},{20,"CLI OPEN"},{21,"MENU OPEN"},{22,"MENU OPEN"},
  {9,"CALIBRATING"},{13,"ACC NOT CAL"},{12,"MAG NOT CAL"},{8,"NOT LEVEL"},
  {11,"NAV UNSAFE"},{6,"GEOZONE"},{19,"THROTTLE HIGH"},{23,"STICKS OFF CENTRE"},
  {24,"AUTOTRIM"},{28,"NO PREARM"},{29,"DSHOT BEEPER"},{30,"LANDED"}}
local navName=nil
local function flagText(flags)
  local out,n,last="",0,nil
  for i=1,#flagReasons do
    if has(flags,flagReasons[i][1]) then
      local t=flagReasons[i][2]
      if t~=last then out=n==0 and t or out..", "..t; n=n+1; last=t end
      if n==3 then break end
    end
  end
  return out
end
local function decodeFM(s)
  if type(s)~="string" or s=="" then return "UNKNOWN","",false,false end
  if reasons[s] then return "BLOCKED",reasons[s],false,true end
  local last=ssub(s,-1)
  if last=="!" and ssub(s,1,1)~="!" then
    local k=ssub(s,1,-2); return modes[k] or k,"ARMING BLOCKED",false,true
  end
  local ready=last=="*"; local k=ready and ssub(s,1,-2) or s; local m=modes[k]
  return navName or m or k,"",not ready and (m~=nil or ssub(k,1,1)~="!"),false
end
local function parseReply(cmd,b)
  if cmd==0x2000 and #b>=13 then
    local f=u32(b,10); return {flags=f,reason=flagText(f),armed=has(f,2)}
  elseif cmd==107 and #b>=4 then return {distance=u16(b,1),bearing=u16(b,3)}
  elseif cmd==121 and #b>=2 then
    local n,s=b[1] or 0,b[2] or 0
    navName=n==2 and "RTH" or n==3 and "WAYPOINT" or n==1 and "POS HOLD" or n==15 and "FAILSAFE" or nil
    return {navMode=n,navState=s}
  end
  return {}
end
return {name="INAV",decodeFM=decodeFM,msp={0x2000,107,121},parseReply=parseReply,
  navModes={["ALT HOLD"]=true,CRUISE=true,["COURSE HOLD"]=true,LOITER=true,
    ["POS HOLD"]=true,WAYPOINT=true,RTH=true,["WP RTH"]=true,LANDING=true},
  voice={ACRO="acro",ANGLE="angle",HORIZON="horizon",["ANGLE HOLD"]="anglehold",
    MANUAL="manual",["ALT HOLD"]="althold",CRUISE="cruise",["COURSE HOLD"]="coursehold",
    LOITER="loiter",["POS HOLD"]="poshold",WAYPOINT="waypoint",RTH="rth",
    ["WP RTH"]="wprth",LANDING="landing",FAILSAFE="failsafe",["HOME RESET"]="homereset"},
  _flagText=flagText}
