-- Profile interface: name is the screen tag; decodeFM(s) returns mode, reason,
-- armed (boolean or nil), blocked; msp is the command-id poll list;
-- parseReply(cmd, bytes) returns any of flags, reason, armed, distance, bearing,
-- navMode, navState; navModes is a set; voice maps every reported mode to a clip.
local ssub=string.sub
local modes={MANU="MANUAL",CIRC="CIRCLE",STAB="STABILIZE",TRAN="TRAINING",ACRO="ACRO",
  FBWA="FBWA",FBWB="FBWB",CRUS="CRUISE",ATUN="AUTOTUNE",AUTO="AUTO",RTL="RTL",
  LOIT="LOITER",TKOF="TAKEOFF",AVOI="AVOID ADSB",GUID="GUIDED",INIT="INITIALISING",
  QSTB="QSTABILIZE",QHOV="QHOVER",QLOT="QLOITER",QLND="QLAND",QRTL="QRTL",
  QACO="QACRO",QATN="QAUTOTUNE",THML="THERMAL",L2QL="LOITER QLAND",ALND="AUTOLAND",
  ALTH="ALT HOLD",LAND="LAND",DRIF="DRIFT",SPRT="SPORT",FLIP="FLIP",PHLD="POSHOLD",
  BRAK="BRAKE",THRW="THROW",GNGP="GUIDED NOGPS",SRTL="SMART RTL",FHLD="FLOWHOLD",
  FOLL="FOLLOW",ZIGZ="ZIGZAG",SYSI="SYSTEM ID",AROT="AUTOROTATE",TRTL="TURTLE"}
local function trim(s)
  while #s>0 and ssub(s,-1)==" " do s=ssub(s,1,-2) end
  return s
end
local function decodeFM(s)
  if type(s)~="string" or s=="" then return "UNKNOWN","",nil,false end
  local star=ssub(s,-1)=="*"; if star then s=ssub(s,1,-2) end
  local k=trim(s); if star then return modes[k] or k,"",false,false end
  return modes[k] or k,"",nil,false
end
local voice={MANUAL="manual",CIRCLE="circle",STABILIZE="stabilize",TRAINING="training",ACRO="acro",
  FBWA="fbwa",FBWB="fbwb",CRUISE="cruise",AUTOTUNE="autotune",AUTO="auto",RTL="rtl",
  LOITER="loiter",TAKEOFF="takeoff",["AVOID ADSB"]="avoidadsb",GUIDED="guided",
  INITIALISING="initialising",QSTABILIZE="qstabilize",QHOVER="qhover",QLOITER="qloiter",
  QLAND="qland",QRTL="qrtl",QACRO="qacro",QAUTOTUNE="qautotune",THERMAL="thermal",
  ["LOITER QLAND"]="loiterqland",AUTOLAND="autoland",["ALT HOLD"]="althold",LAND="land",
  DRIFT="drift",SPORT="sport",FLIP="flip",POSHOLD="poshold",BRAKE="brake",THROW="throw",
  ["GUIDED NOGPS"]="guidednogps",["SMART RTL"]="smartrtl",FLOWHOLD="flowhold",FOLLOW="follow",
  ZIGZAG="zigzag",["SYSTEM ID"]="systemid",AUTOROTATE="autorotate",TURTLE="turtle"}
return {name="AP",decodeFM=decodeFM,msp={},parseReply=function() return {} end,
  navModes={AUTO=true,RTL=true,LOITER=true,CIRCLE=true,GUIDED=true,CRUISE=true,FBWB=true,
    TAKEOFF=true,AUTOLAND=true,QLOITER=true,QLAND=true,QRTL=true,["SMART RTL"]=true,
    POSHOLD=true,LAND=true},voice=voice}
