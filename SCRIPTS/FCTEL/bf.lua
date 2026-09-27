-- Profile interface: name is the screen tag; decodeFM(s) returns mode, reason,
-- armed (boolean or nil), blocked; msp is the command-id poll list;
-- parseReply(cmd, bytes) returns any of flags, reason, armed, distance, bearing,
-- navMode, navState; navModes is a set; voice maps every reported mode to a clip.
local floor=math.floor
local ssub=string.sub
local function band(a,b) local r,p=0,1 while a>0 and b>0 do if a%2==1 and b%2==1 then r=r+p end a,b,p=floor(a/2),floor(b/2),p*2 end return r end
local function has(v,n) return band(v or 0,2^n)~=0 end
local function u16(b,i) return (b[i] or 0)+256*(b[i+1] or 0) end
local function u32(b,i) return u16(b,i)+65536*u16(b,i+2) end
local modes={["!FS!"]="FAILSAFE",RTH="GPS RESCUE",PASS="PASSTHRU",POSH="POS HOLD",
  PHFL="POS HOLD FAIL",ALTH="ALT HOLD",ANGL="ANGLE",HOR="HORIZON",CHIR="CHIRP",AIR="AIR MODE"}
local names={{1,"FAILSAFE"},{2,"RX LOSS"},{0,"NO GYRO"},{4,"FAILSAFE SWITCH"},
  {6,"CRASH DETECTED"},{5,"RUNAWAY"},{7,"THROTTLE HIGH"},{8,"NOT LEVEL"},
  {9,"BOOT GRACE"},{10,"NO PREARM"},{11,"CPU LOAD"},{12,"CALIBRATING"},
  {13,"CLI OPEN"},{14,"MENU OPEN"},{15,"BST"},{16,"MSP"},{17,"PARALYZE"},
  {18,"NO GPS FIX"},{19,"RESCUE SWITCH"},{20,"DSHOT TELEMETRY"},{21,"REBOOT REQUIRED"},
  {22,"DSHOT BITBANG"},{23,"ACC NOT CAL"},{24,"MOTOR PROTOCOL"},{25,"CRASHFLIP"},
  {26,"ALT HOLD SWITCH"},{27,"POS HOLD SWITCH"},{28,"AUTOPILOT"},{3,"NOT DISARMED"},{29,"ARM SWITCH"}}
local function flagText(flags)
  local out,n="",0
  for i=1,#names do if has(flags,names[i][1]) then out=n==0 and names[i][2] or out..", "..names[i][2]; n=n+1; if n==3 then break end end end
  return out
end
local function decodeFM(s)
  if type(s)~="string" or s=="" then return "UNKNOWN","",false,false end
  if s=="!FS!" then return "FAILSAFE","FAILSAFE",false,true end
  local last=ssub(s,-1); local suffix=last=="*" or last=="!" or last=="?"
  local k=suffix and ssub(s,1,-2) or s; local m=modes[k] or (k=="ACRO" and "ACRO") or k
  if last=="!" then return m,"ARMING DISABLED",false,true end
  if last=="?" then return m,"RESCUE UNAVAILABLE",false,false end
  if last=="*" then return m,"",false,false end
  return m,"",true,false
end
local function parseReply(cmd,b)
  if cmd==150 and #b>=17 then
    local armed=has(u32(b,7),0); local count=b[16] or 0; local i=17+count
    local flags=(b[i] or 0)>0 and u32(b,i+1) or 0
    return {flags=flags,reason=flagText(flags),armed=armed}
  elseif cmd==107 and #b>=4 then return {distance=u16(b,1),bearing=u16(b,3)} end
  return {}
end
return {name="BF",decodeFM=decodeFM,msp={150,107},parseReply=parseReply,
  navModes={["GPS RESCUE"]=true,["POS HOLD"]=true,["ALT HOLD"]=true},
  voice={FAILSAFE="failsafe",["GPS RESCUE"]="gpsrescue",PASSTHRU="passthru",
    ["POS HOLD"]="poshold",["POS HOLD FAIL"]="posholdfail",["ALT HOLD"]="althold",
    ANGLE="angle",HORIZON="horizon",CHIRP="chirp",["AIR MODE"]="airmode",ACRO="acro"},
  _flagText=flagText}
