---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - vysilac dat ze vzdalenych senzoru
  Bezi na POCITACI U SLEDOVANYCH BLOKU, ne na tom s monitorem.

  Jeden program pro vsechny vzdalene stanoviste. Sam si zjisti, co ma
  u sebe pripojeno, a posila jen to. Dava se na kazdy vzdaleny pocitac
  stejny - lisi se jen tim, co k nemu postavis.

  Zapojeni:
    - Energy Detector (Advanced Peripherals) primo vedle pocitace,
      nebo pripojeny wired modemem + Networking Cable
    - volitelne baterie (Mekanism Energy Cube, Powah, Thermal, ...)
      taky vedle pocitace nebo na stejne kabelove siti
    - volitelne Block Reader, ktery CELI bloku quarry (QuarryPlus)
    - Ender Modem (doporuceno) nebo Wireless Modem kdekoli na pocitaci

  Staci jedno z toho - vysila se to, co najde. Program muze bezet na
  vice pocitacich zaroven; kazdy se hlasi svym ID a na hlavnim PC
  vystupuji jako samostatne zdroje.

  V JINE DIMENZI NEZ HLAVNI PC MUSI BYT ENDER MODEM - obycejny
  wireless modem hranici dimenzi neprekroci.

  Na tomto pocitaci uloz jako "startup.lua", aby se spoustel sam.
  POZOR: chunk s timto pocitacem musi byt nacteny, jinak vysilani stoji.
----------------------------------------------------------------------]]

local RN_PROTO = "sleepmon_energy"      -- vysilani hodnot
local RN_CMD   = "sleepmon_energy_cmd"  -- prijem prikazu z hlavniho PC
local INTERVAL = 0.5                    -- perioda vysilani (s)
local RESCAN   = 10                     -- jak casto (s) hledat chybejici bloky

-- Necha se auto-detekovat baterie s nejvetsi kapacitou. Kdyby to sahlo
-- po spatnem bloku, napis sem presny nazev periferie, treba:
--   local STORAGE_NAME = "mekanism:energy_cube_0"
local STORAGE_NAME = nil

local ED_TYPES = { energy_detector = true, energyDetector = true }

local function findDetector()
  for _, name in ipairs(peripheral.getNames()) do
    if ED_TYPES[peripheral.getType(name)] then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
end

-- baterie poznavame podle schopnosti, ne podle modu:
--   getEnergy + getEnergyCapacity  = CC generic peripheral (FE)
--   getEnergy + getMaxEnergy       = nativni integrace modu (Mekanism)
local function hasStorage(dev)
  return dev and dev.getEnergy and (dev.getEnergyCapacity or dev.getMaxEnergy)
end

local function num(dev, method)
  if not (dev and dev[method]) then return nil end
  local ok, v = pcall(dev[method])
  if ok then return tonumber(v) end
  return nil
end

local function capacityOf(dev)
  return num(dev, "getEnergyCapacity") or num(dev, "getMaxEnergy") or 0
end

-- Block Reader (Advanced Peripherals) pro cteni NBT quarry
local BR_TYPES = { block_reader = true, blockReader = true }

local function findReader()
  for _, name in ipairs(peripheral.getNames()) do
    if BR_TYPES[peripheral.getType(name)] then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
end

-- Z NBT vytahne jen podstatne hodnoty. Cele NBT vcetne inventaru by
-- se po rednetu posilalo zbytecne a 2x za sekundu by to bylo drahe.
local function parseQuarry(data, states)
  if type(data) ~= "table" then return nil end
  local a, h = data.area, data.head
  if type(a) ~= "table" or type(h) ~= "table" then return nil end

  local dm, digMinY = data.digMinY, nil
  if type(dm) == "table" then
    local set = dm.isSet
    if set == true or (tonumber(set) or 0) ~= 0 then digMinY = tonumber(dm.minY) end
  end

  return {
    minX = tonumber(a.minX), maxX = tonumber(a.maxX),
    minY = tonumber(a.minY), maxY = tonumber(a.maxY),
    minZ = tonumber(a.minZ), maxZ = tonumber(a.maxZ),
    hx = tonumber(h[1]), hy = tonumber(h[2]), hz = tonumber(h[3]),
    state     = tostring(data.state or "?"),
    working   = states and states.working or nil,
    energy    = tonumber(data.energy),
    maxEnergy = tonumber(data.maxEnergy),
    digMinY   = digMinY,
  }
end

-- Pozor: energii hlasi i Energy Detector a kazdy stroj s vnitrnim bufferem.
-- Detektor proto vyradime uplne a z ostatnich bereme ten s nejvetsi
-- kapacitou - Energy Cube ma radove vic nez buffer stroje.
local function findStorage()
  if STORAGE_NAME and peripheral.isPresent(STORAGE_NAME) then
    local ok, dev = pcall(peripheral.wrap, STORAGE_NAME)
    if ok and hasStorage(dev) then return dev, STORAGE_NAME end
  end

  local best, bestName, bestCap = nil, nil, 0
  for _, name in ipairs(peripheral.getNames()) do
    if not ED_TYPES[peripheral.getType(name)] then
      local ok, dev = pcall(peripheral.wrap, name)
      if ok and hasStorage(dev) then
        local cap = capacityOf(dev)
        if cap > bestCap then best, bestName, bestCap = dev, name, cap end
      end
    end
  end
  return best, bestName
end

local function openModems()
  local anyModem, wireless = false, false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      pcall(rednet.open, name)
      anyModem = true
      local m = peripheral.wrap(name)
      if m and m.isWireless and m.isWireless() then wireless = true end
    end
  end
  return anyModem, wireless
end

local function call(dev, method, ...)
  if not (dev and dev[method]) then return nil end
  local ok, res = pcall(dev[method], ...)
  if ok then return res end
  return nil
end

--=====================================================================

local anyModem, wireless = openModems()
if not anyModem then
  error("Neni pripojeny zadny modem. Pridej Ender/Wireless Modem.", 0)
end

-- Pojistka proti zamene programu: vysilac patri k detektoru, ne
-- k pocitaci s monitorem. Kdyz na hlavnim PC bezi tenhle program,
-- SleepMon tam nebezi a monitor jen drzi posledni vykresleny obraz.
if peripheral.find("monitor") then
  term.setTextColor(colors.red)
  print("POZOR: k tomuto pocitaci je pripojeny monitor.")
  print("Tohle je program pro pocitac U DETEKTORU.")
  print("Hlavni PC ma spoustet SleepMon (startup.lua).")
  term.setTextColor(colors.white)
  print("")
  print("N ukonci, jinak se pokracuje za 10 s.")

  -- s timeoutem, aby to po reloadu chunku nezustalo viset na vstupu
  local t = os.startTimer(10)
  while true do
    local ev, p = os.pullEvent()
    if ev == "char" then
      if p == "n" or p == "N" then print("Ukonceno."); return end
      break
    elseif ev == "timer" and p == t then
      break
    end
  end
end

local label = os.getComputerLabel() or ("PC" .. os.getComputerID())
local det, detName = findDetector()
local sto, stoName = findStorage()
local rdr, rdrName = findReader()

-- Volitelny log na PC1. Bez updater.lua vysilac bezi dal, jen mlci.
local upd
do
  if fs.exists("updater.lua") then
    local fn = loadfile("updater.lua", nil, _G) or loadfile("updater.lua")
    if fn then
      local ok, m = pcall(fn)
      if ok and type(m) == "table" then upd = m end
    end
  end
end

local function log(level, text)
  if upd then pcall(upd.log, level, text) end
end

--=====================================================================
-- ALIAS STANOVISTE
--=====================================================================
-- Jmeno se nastavuje primo tady klavesou A a putuje s kazdou zpravou.
-- PC1 ho pouzije misto strohého QRY3 / BAT3 u vseho, co tenhle
-- pocitac hlasi.

local ALIAS_FILE = "/.sleepmon_alias"
local ALIAS_MAX  = 16

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readAlias()
  if not fs.exists(ALIAS_FILE) then return nil end
  local f = fs.open(ALIAS_FILE, "r")
  if not f then return nil end
  local a = trim(f.readAll())
  f.close()
  return a ~= "" and a:sub(1, ALIAS_MAX) or nil
end

local function writeAlias(a)
  if not a or a == "" then
    if fs.exists(ALIAS_FILE) then fs.delete(ALIAS_FILE) end
    return
  end
  local f = fs.open(ALIAS_FILE, "w")
  if f then f.write(a); f.close() end
end

local alias = readAlias()
-- v logu na PC1 pak vystupujeme pod aliasem, ne pod nazvem pocitace
if upd then upd.logName = alias end

-- hlasime jen zmeny stavu, ne kazdy tik - jinak by log zaplavilo
local function watch(name, present, was)
  if present == was then return present end
  log(present and "ok" or "warn",
    name .. (present and " pripojen" or " ZMIZEL"))
  return present
end

local hadDet, hadSto, hadRdr = det ~= nil, sto ~= nil, rdr ~= nil
local sent, lastRate, lastPct = 0, 0, nil
local sinceScan = 0   -- tiky od posledniho hledani chybejicich bloku
local qTick, lastQuarry = 0, nil

local function readStorage()
  if not sto then return nil end
  local stored = tonumber(call(sto, "getEnergy"))
  if not stored then return nil end

  -- jednotku urcuje az ta metoda, ktera kapacitu opravdu dala:
  -- getEnergyCapacity = CC generic, vzdy FE
  -- getMaxEnergy      = nativni metoda modu, jednotka muze byt jina
  local cap, unit
  local c = tonumber(call(sto, "getEnergyCapacity"))
  if c and c > 0 then cap, unit = c, "FE" end
  if not cap then
    c = tonumber(call(sto, "getMaxEnergy"))
    if c and c > 0 then cap, unit = c, "E" end
  end
  if not cap then return nil end

  return { stored = stored, cap = cap, unit = unit or "?" }
end

local function status()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("SleepMon vysilac energie")
  print("")
  term.setTextColor(colors.lightGray)
  if alias then
    term.setTextColor(colors.white)
    print("Alias:    " .. alias)
    term.setTextColor(colors.lightGray)
  end
  print("Nazev:    " .. label .. "  (ID " .. os.getComputerID() .. ")")
  print("Verze:    " .. (upd and upd.localVersion() or "bez updateru"))
  print("Modem:    " .. (wireless and "bezdratovy OK" or "jen wired (!)"))

  if det then
    term.setTextColor(colors.green)
    print("Detektor: " .. tostring(detName) .. "  " .. lastRate .. " FE/t")
  else
    term.setTextColor(colors.red)
    print("Detektor: NENALEZEN")
  end

  if sto then
    term.setTextColor(colors.green)
    print("Baterie:  " .. tostring(stoName) ..
      (lastPct and string.format("  %.1f%%", lastPct) or ""))
  else
    term.setTextColor(colors.gray)
    print("Baterie:  neni")
  end

  if rdr then
    term.setTextColor(lastQuarry and colors.green or colors.orange)
    print("Quarry:   " .. tostring(rdrName) ..
      (lastQuarry and ("  " .. lastQuarry.state) or "  ceka na data"))
  else
    term.setTextColor(colors.gray)
    print("Quarry:   neni")
  end

  term.setTextColor(colors.gray)
  print("Odeslano: " .. sent .. " zprav")
  print("")
  print("A = alias stanoviste,  Q = konec")
end

status()
log("info", ("sender v%s bezi"):format(upd and upd.localVersion() or "?") ..
  (det and " +det" or "") .. (sto and " +bat" or "") ..
  (rdr and " +qry" or ""))

local timer = os.startTimer(INTERVAL)
local uiTimer = os.startTimer(2)
local running = true

while running do
  local ev = { os.pullEvent() }

  if ev[1] == "timer" and ev[2] == timer then
    -- co chybi, zkusime obcas najit znovu; hledani prochazi vsechny
    -- periferie a vola na ne metody, takze ne pri kazdem tiku
    sinceScan = sinceScan + 1
    if (not det or not sto or not rdr) and sinceScan * INTERVAL >= RESCAN then
      sinceScan = 0
      if not det then det, detName = findDetector() end
      if not sto then sto, stoName = findStorage() end
      if not rdr then rdr, rdrName = findReader() end
    end

    local payload = {
      label = label, alias = alias,
      ver = upd and upd.localVersion() or nil,
      -- uptime rozlisi "restartoval se" od "jen vypadlo spojeni"
      up = math.floor(os.clock()),
    }
    local any = false

    if det then
      local rate = call(det, "getTransferRate")
      if type(rate) == "number" then
        lastRate = rate
        payload.rate  = rate
        payload.limit = call(det, "getTransferRateLimit")
        any = true
      else
        det = nil   -- detektor zmizel, pri dalsim tiku ho hledame znovu
      end
    end

    local st = readStorage()
    if st then
      payload.storage = st
      lastPct = (st.cap and st.cap > 0) and (st.stored / st.cap * 100) or nil
      any = true
    elseif sto then
      sto = nil
    end

    -- NBT quarry je velke, cist ho 2x za sekundu je zbytecne
    qTick = qTick + INTERVAL
    if rdr and qTick >= 2 then
      qTick = 0
      local okD, data = pcall(rdr.getBlockData)
      local okS, states = pcall(rdr.getBlockStates)
      local q = okD and parseQuarry(data, okS and states or nil) or nil
      lastQuarry = q
      if not q then rdr = nil end   -- neceli quarry nebo zmizel
    end
    if lastQuarry then
      payload.quarry = lastQuarry
      any = true
    end

    hadDet = watch("detektor", det ~= nil, hadDet)
    hadSto = watch("baterie", sto ~= nil, hadSto)
    hadRdr = watch("block reader", rdr ~= nil, hadRdr)

    if any then
      rednet.broadcast(payload, RN_PROTO)
      sent = sent + 1
    end
    timer = os.startTimer(INTERVAL)

  elseif ev[1] == "timer" and ev[2] == uiTimer then
    status()
    uiTimer = os.startTimer(2)

  elseif ev[1] == "rednet_message" then
    local _, msg, proto = ev[2], ev[3], ev[4]

    if proto == RN_CMD and type(msg) == "table" and msg.cmd == "setLimit" then
      local v = tonumber(msg.value)
      if v and det then call(det, "setTransferRateLimit", math.floor(v)) end

    elseif upd and proto == upd.PROTO and type(msg) == "table"
           and msg.cmd == "update" then
      -- PC1 hlasi novou verzi; stahujeme si ji sami, at si to muze
      -- kazdy pocitac odbavit vlastnim tempem
      local want = tonumber(msg.version) or 0
      if want > upd.localVersion() then
        log("info", "vyzva v" .. want .. ", stahuji")

        -- stejne rozlozeni jako pri bootu, at deset stroju
        -- nezavali PC1 naraz
        local wait = os.getComputerID() % 12
        if wait > 0 then sleep(wait) end

        local ver, err, changed = upd.pullRednet(10)
        if err then
          log("error", "update selhal: " .. tostring(err))
        elseif changed then
          log("ok", "v" .. tostring(ver) .. ", restart")
          sleep(1)
          os.reboot()
        end

        -- sleep a rednet.receive spolykaly nase timery
        timer = os.startTimer(INTERVAL)
        uiTimer = os.startTimer(2)
        status()
      end
    end

  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    openModems()
    det, detName = findDetector()
    sto, stoName = findStorage()
    rdr, rdrName = findReader()
    status()

  elseif ev[1] == "key" and ev[2] == keys.a then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    print("Alias tohoto stanoviste")
    term.setTextColor(colors.lightGray)
    print("Zobrazi se na PC1 misto QRY/BAT + ID.")
    print("Prazdny vstup alias zrusi. Max " .. ALIAS_MAX .. " znaku.")
    print("")
    term.setTextColor(colors.white)
    write("> ")

    local a = trim(read(nil, nil, nil, alias or ""))
    alias = (a ~= "") and a:sub(1, ALIAS_MAX) or nil
    writeAlias(alias)
    if upd then upd.logName = alias end
    log("info", "alias: " .. tostring(alias or "(zadny)"))
    status()

    -- read() spolykal i nase timery, musime je nasadit znovu
    timer = os.startTimer(INTERVAL)
    uiTimer = os.startTimer(2)

  elseif ev[1] == "key" and ev[2] == keys.q then
    running = false
  end
end

term.setTextColor(colors.white)
print("Vysilac ukoncen.")
