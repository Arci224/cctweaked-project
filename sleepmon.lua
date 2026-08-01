---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - menu + hodiny se signalizaci spanku
  CC:Tweaked / Advanced Computer

  Zapojeni:
    - Advanced Monitor 5x3  -> vpravo  ("right")
    - Speaker               -> nahore  ("top")
    - Energy Detector (Advanced Peripherals), volitelne:
        a) wired modem + Networking Cable az sem  -> nacte se sam
        b) druhy pocitac u detektoru se sender.lua
           + ender modem na obou -> data chodi pres rednet

  Ovladani: dotykem na monitoru. Na pocitaci Q = konec.

  POZN.: font CC:Tweaked neumi ceskou diakritiku, texty jsou proto
         zamerne bez hacku a carek.
----------------------------------------------------------------------]]

local VERSION = "1.0"
local CFG_PATH = "/sleepmon.cfg"

--=====================================================================
-- KONFIGURACE (da se menit i za behu na strance Nastaveni)
--=====================================================================

local cfg = {
  monitorSide   = "right",
  speakerSide   = "top",
  textScale     = 1,          -- 0.5 / 1 / 1.5 / 2
  alarmEnabled  = true,
  alarmInterval = 60,         -- realne sekundy mezi zvuky
  soundName     = "minecraft:block.note_block.bell",
  volume        = 1.0,
  pitch         = 1.0,
  -- herni tiky, kdy vanilla dovoli spat (0 = 6:00 rano)
  sleepStart    = 12542,
  sleepEnd      = 23459,
  refresh       = 0.5,        -- perioda hlavni smycky (s)
  graphWindow   = 300,        -- kolik realnych sekund ukazuje graf
  lowEnergyAlarm = true,      -- pipat pri nizkem stavu baterie
  lowEnergyPct  = 20,         -- prah v procentech
  lowInterval   = 30,         -- realne sekundy mezi varovnymi pipnutimi
  -- Kam az quarry kope, kdyz nema nastaveny digMinY. Vychozi je dno
  -- sveta v 1.21; da se prepnout primo na strance Quarry.
  quarryBottomY = -64,
  -- evidence zarizeni, ktera uz nekdy byla videna; diky ni poznáme
  -- rozdil mezi "nikdy tu nebylo" a "vypadlo" (prezije restart)
  expected      = {},         -- [key] = {kind=, label=, name=, id=}
}

local SOUNDS = {
  { name = "minecraft:block.note_block.bell",  label = "Bell"   },
  { name = "minecraft:block.note_block.pling", label = "Pling"  },
  { name = "minecraft:block.note_block.chime", label = "Chime"  },
  { name = "minecraft:block.note_block.harp",  label = "Harp"   },
  { name = "minecraft:entity.experience_orb.pickup", label = "Orb" },
  { name = "minecraft:block.bell.use",         label = "Zvon"   },
}

local function loadConfig()
  if not fs.exists(CFG_PATH) then return end
  local f = fs.open(CFG_PATH, "r")
  if not f then return end
  local data = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(data) == "table" then
    for k, v in pairs(data) do
      if cfg[k] ~= nil then cfg[k] = v end
    end
  end
end

local function saveConfig()
  local f = fs.open(CFG_PATH, "w")
  if not f then return false end
  f.write(textutils.serialize(cfg))
  f.close()
  return true
end

--=====================================================================
-- PERIFERIE
--=====================================================================

-- Volitelna knihovna aktualizaci. Kdyz chybi, aplikace bezi dal,
-- jen bez update sluzby a bez sberu logu od ostatnich pocitacu.
local updater
do
  if fs.exists("updater.lua") then
    local fn = loadfile("updater.lua", nil, _G) or loadfile("updater.lua")
    if fn then
      local ok, m = pcall(fn)
      if ok and type(m) == "table" then updater = m end
    end
  end
end

local function findPeripheral(side, ptype)
  if side and peripheral.isPresent(side) and peripheral.getType(side) == ptype then
    return peripheral.wrap(side), side
  end
  local p = peripheral.find(ptype)
  if p then return p, peripheral.getName(p) end
  return nil, nil
end

loadConfig()

local mon, monName = findPeripheral(cfg.monitorSide, "monitor")
if not mon then
  error("Monitor nenalezen. Zkontroluj, ze je pripojeny (ocekavano vpravo).", 0)
end
cfg.monitorSide = monName

local speaker, spkName = findPeripheral(cfg.speakerSide, "speaker")
if speaker then cfg.speakerSide = spkName end

mon.setTextScale(cfg.textScale)

--=====================================================================
-- HERNI CAS
--=====================================================================

-- os.time() vraci herni hodiny 0..24, kde 6 = tik 0 (vychod slunce)
local function mcTicks()
  return (os.time() * 1000 + 18000) % 24000
end

local function fmtClock(t)
  local h = math.floor(t) % 24
  local m = math.floor((t % 1) * 60)
  return string.format("%02d:%02d", h, m)
end

local function canSleep()
  local tk = mcTicks()
  return tk >= cfg.sleepStart and tk <= cfg.sleepEnd
end

-- kolik realnych sekund zbyva do daneho herniho tiku
local function realSecondsUntil(targetTick)
  local d = (targetTick - mcTicks()) % 24000
  return d / 20
end

local function fmtDuration(sec)
  sec = math.max(0, math.floor(sec))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function tickToClock(tk)
  return fmtClock(((tk / 1000) + 6) % 24)
end

--=====================================================================
-- KRESLICI POMOCNIKY
--=====================================================================

local W, H = mon.getSize()
local clickables = {}

local function clearClickables()
  clickables = {}
end

local function hit(x, y)
  for i = #clickables, 1, -1 do
    local b = clickables[i]
    if x >= b.x and x <= b.x + b.w - 1 and y >= b.y and y <= b.y + b.h - 1 then
      return b
    end
  end
  return nil
end

local function fill(x, y, w, h, bg)
  mon.setBackgroundColor(bg)
  local line = string.rep(" ", math.max(0, w))
  for r = 0, h - 1 do
    mon.setCursorPos(x, y + r)
    mon.write(line)
  end
end

local function text(x, y, s, fg, bg)
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or colors.white)
  if bg then mon.setBackgroundColor(bg) end
  mon.write(s)
end

local function textCenter(x, w, y, s, fg, bg)
  local len = #s
  if len > w then s = s:sub(1, w); len = w end
  text(x + math.floor((w - len) / 2), y, s, fg, bg)
end

local function textRight(x, w, y, s, fg, bg)
  local len = math.min(#s, w)
  text(x + w - len, y, s:sub(1, len), fg, bg)
end

-- tlacitko: registruje se do clickables a hned se vykresli
local function button(x, y, w, h, label, bg, fg, action)
  fill(x, y, w, h, bg)
  textCenter(x, w, y + math.floor((h - 1) / 2), label, fg, bg)
  clickables[#clickables + 1] = { x = x, y = y, w = w, h = h, action = action }
end

-- velke cislice 3x5 pro hlavni hodiny
local BIG = {
  ["0"] = { "###", "# #", "# #", "# #", "###" },
  ["1"] = { "  #", "  #", "  #", "  #", "  #" },
  ["2"] = { "###", "  #", "###", "#  ", "###" },
  ["3"] = { "###", "  #", "###", "  #", "###" },
  ["4"] = { "# #", "# #", "###", "  #", "  #" },
  ["5"] = { "###", "#  ", "###", "  #", "###" },
  ["6"] = { "###", "#  ", "###", "# #", "###" },
  ["7"] = { "###", "  #", "  #", "  #", "  #" },
  ["8"] = { "###", "# #", "###", "# #", "###" },
  ["9"] = { "###", "# #", "###", "  #", "###" },
  [":"] = { "   ", " # ", "   ", " # ", "   " },
}

-- vodorovny ukazatel naplneni (0..1)
local function drawBar(x, y, w, pct, color)
  local filled = math.max(0, math.min(w, math.floor(w * (pct or 0) + 0.5)))
  fill(x, y, w, 1, colors.gray)
  if filled > 0 then fill(x, y, filled, 1, color) end
end

local function bigWidth(s) return #s * 4 - 1 end

local function drawBig(x, y, s, color, bgColor)
  for i = 1, #s do
    local pat = BIG[s:sub(i, i)]
    if pat then
      for r = 1, 5 do
        for c = 1, 3 do
          local on = pat[r]:sub(c, c) == "#"
          mon.setCursorPos(x + (i - 1) * 4 + (c - 1), y + r - 1)
          mon.setBackgroundColor(on and color or bgColor)
          mon.write(" ")
        end
      end
    end
  end
end

--=====================================================================
-- STAV APLIKACE
--=====================================================================

local state = {
  page       = "dash",
  lastAlarm  = 0,      -- os.epoch ms posledniho pipnuti
  wasSleep   = false,
  alarmCount = 0,
  running    = true,
  toast      = nil,    -- {text=..., until=epoch}
}

local function toast(msg)
  state.toast = { text = msg, until_ = os.epoch("utc") + 2500 }
end

--=====================================================================
-- LOG ZE VZDALENYCH POCITACU
--=====================================================================

local logs = { lines = {}, max = 200, unseen = 0, errors = 0 }

local function addLog(entry)
  if type(entry) ~= "table" then return end
  local level = tostring(entry.level or "info")
  logs.lines[#logs.lines + 1] = {
    clock = fmtClock(os.time()),
    level = level,
    text  = tostring(entry.text or ""),
    from  = tostring(entry.from or "?"),
  }
  while #logs.lines > logs.max do table.remove(logs.lines, 1) end
  if state.page ~= "log" then
    logs.unseen = logs.unseen + 1
    if level == "error" then logs.errors = logs.errors + 1 end
  end
end

if updater then updater.logLocal = addLog end

local function playAlarm()
  if not speaker then return false end
  speaker.playSound(cfg.soundName, cfg.volume, cfg.pitch)
  return true
end

local function checkAlarm()
  local sleepable = canSleep()

  -- vstup do okna spanku -> vynulovat, aby prvni pipnuti prislo hned
  if sleepable and not state.wasSleep then
    state.lastAlarm = 0
    state.alarmCount = 0
  end
  state.wasSleep = sleepable

  if not (sleepable and cfg.alarmEnabled and speaker) then return end

  local now = os.epoch("utc")
  if now - state.lastAlarm >= cfg.alarmInterval * 1000 then
    state.lastAlarm = now
    state.alarmCount = state.alarmCount + 1
    playAlarm()
  end
end

local function secondsToNextAlarm()
  if not (cfg.alarmEnabled and speaker and canSleep()) then return nil end
  local left = cfg.alarmInterval - (os.epoch("utc") - state.lastAlarm) / 1000
  return math.max(0, left)
end

--=====================================================================
-- ENERGY DETECTOR (Advanced Peripherals)
--=====================================================================
-- Zdroj dat muze byt dvoji:
--   LOKALNI  - detektor je na wired modem siti tohoto pocitace
--              (peripheral.find, plna kontrola vcetne setTransferRateLimit)
--   VZDALENY - u detektoru stoji druhy pocitac se sender.lua
--              a posila hodnoty pres rednet (wireless / ender modem)
--
-- Typ periferie se lisi podle verze modu:
--   MC < 1.21.1  -> "energyDetector"
--   MC >= 1.21.1 -> "energy_detector"   (nas pripad: NeoForge 21.1.x)
local ED_TYPES = { energy_detector = true, energyDetector = true }

local RN_PROTO = "sleepmon_energy"      -- vysilani hodnot
local RN_CMD   = "sleepmon_energy_cmd"  -- prikazy smerem k vysilaci
local REMOTE_TIMEOUT = 6000             -- ms bez zpravy = zdroj je mrtvy

--=====================================================================
-- EVIDENCE ZARIZENI
--=====================================================================
-- cfg.expected drzi trvale zaznamy o vsech zarizenich, ktera uz nekdy
-- byla pripojena. devices.lastSeen je runtime cast (kdy naposledy
-- odpovedelo). Rozdil obojiho = "melo by tu byt, ale neni".

local devices = { lastSeen = {} }

local function registerDevice(key, info)
  local e = cfg.expected[key]
  if not e then
    cfg.expected[key] = info
    saveConfig()
  elseif e.label ~= info.label then
    e.label = info.label
    saveConfig()
  end
  devices.lastSeen[key] = os.epoch("utc")
end

local function markSeen(key)
  devices.lastSeen[key] = os.epoch("utc")
end

-- vraci: text stavu, barva, stari v sekundach (nebo nil)
local function deviceStatus(key)
  local ts = devices.lastSeen[key]
  if not ts then return "CHYBI", colors.red, nil end
  local age = (os.epoch("utc") - ts) / 1000
  if age <= REMOTE_TIMEOUT / 1000 then return "OK", colors.green, age end
  return "VYPADLO", colors.red, age
end

-- kolik evidovanych zarizeni prave nefunguje
local function problemCount()
  local n = 0
  for key in pairs(cfg.expected) do
    local st = deviceStatus(key)
    if st ~= "OK" then n = n + 1 end
  end
  return n
end

local function forgetOffline()
  local removed = 0
  for key in pairs(cfg.expected) do
    if deviceStatus(key) ~= "OK" then
      cfg.expected[key] = nil
      devices.lastSeen[key] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then saveConfig() end
  return removed
end

--=====================================================================

local energy = {
  sources = {},   -- sjednoceny seznam zdroju pro UI
  remotes = {},   -- [computerId] = {rate=, limit=, label=, lastSeen=}
  index   = 1,
  history = {},   -- posledni vzorky FE/t vybraneho zdroje
  maxKeep = 1800, -- 15 minut pri refresh 0.5 s
  total   = 0,    -- odhad preneseneho mnozstvi od startu (FE)
  peak    = 0,
  limit   = nil,
  pending = nil,  -- navrzeny novy limit, ceka na potvrzeni
}

local function shortName(name)
  local n = tostring(name):match("(%d+)$")
  if n then return "ED#" .. n end
  return tostring(name):sub(1, 6)
end

-- prebuduje seznam zdroju; drzi vyber na stejnem klici, pokud existuje
local function rebuildSources()
  local keep = energy.sources[energy.index] and energy.sources[energy.index].key
  local list = {}

  for _, name in ipairs(peripheral.getNames()) do
    if ED_TYPES[peripheral.getType(name)] then
      local key = "L:" .. name
      registerDevice(key, { kind = "local", label = shortName(name), name = name })
      list[#list + 1] = {
        kind = "local", key = key,
        label = shortName(name), name = name,
        dev = peripheral.wrap(name),
      }
    end
  end

  local ids = {}
  for id in pairs(energy.remotes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local r = energy.remotes[id]
    list[#list + 1] = {
      kind = "remote", key = "R:" .. id,
      label = r.label or ("PC" .. id), id = id,
    }
  end

  energy.sources = list
  energy.index = 1
  for i, s in ipairs(list) do
    if s.key == keep then energy.index = i end
  end
end

local function source()
  return energy.sources[energy.index]
end

-- volani lokalni periferie vzdy pres pcall - odpojeny blok jinak hodi chybu
local function edCall(src, method, ...)
  if not (src and src.kind == "local" and src.dev and src.dev[method]) then return nil end
  local ok, res = pcall(src.dev[method], ...)
  if ok then return res end
  return nil
end

-- vraci: rate, limit, online
local function readSource(src)
  if not src then return nil, nil, false end
  if src.kind == "local" then
    local rate = edCall(src, "getTransferRate")
    if type(rate) ~= "number" then return nil, nil, false end
    return rate, edCall(src, "getTransferRateLimit"), true
  else
    local r = energy.remotes[src.id]
    if not r then return nil, nil, false end
    if os.epoch("utc") - r.lastSeen > REMOTE_TIMEOUT then
      return r.rate, r.limit, false
    end
    return r.rate, r.limit, true
  end
end

local function resetEnergyStats()
  energy.history = {}
  energy.total = 0
  energy.peak = 0
end

local function sampleEnergy()
  local src = source()
  local rate, limit, online = readSource(src)
  energy.limit = limit
  energy.online = online
  if type(rate) ~= "number" or not online then return end

  energy.history[#energy.history + 1] = rate
  while #energy.history > energy.maxKeep do table.remove(energy.history, 1) end
  energy.total = energy.total + rate * 20 * cfg.refresh  -- FE/t * 20 tiku/s * s
  if rate > energy.peak then energy.peak = rate end
end

-- lokalni detektory potvrzujeme kazdy tik, vzdalene resi prijem rednetu
local function refreshPresence()
  for _, s in ipairs(energy.sources) do
    if s.kind == "local" and peripheral.isPresent(s.name) then
      markSeen(s.key)
    end
  end
end

-- nastaveni limitu funguje lokalne primo, vzdalene pres rednet prikaz
local function applyLimit(v)
  local src = source()
  if not src then return false end
  if src.kind == "local" then
    edCall(src, "setTransferRateLimit", math.floor(v))
    return true
  else
    rednet.send(src.id, { cmd = "setLimit", value = v }, RN_CMD)
    return true
  end
end

local function fmtFE(v)
  if type(v) ~= "number" then return "?" end
  local a = math.abs(v)
  if a >= 1e9 then return string.format("%.2fG", v / 1e9) end
  if a >= 1e6 then return string.format("%.2fM", v / 1e6) end
  if a >= 1e3 then return string.format("%.2fk", v / 1e3) end
  return string.format("%d", math.floor(v + 0.5))
end

-- presna hodnota s mezerami po tisicich; u obrich kapacit se zkraceny
-- zapis ani procenta viditelne nehnou, tohle ano
local function fmtExact(v)
  if type(v) ~= "number" then return "?" end
  local s = string.format("%.0f", math.abs(v))
  while true do
    local k
    s, k = s:gsub("^(%d+)(%d%d%d)", "%1 %2")
    if k == 0 then break end
  end
  return (v < 0 and "-" or "") .. s
end

-- otevre rednet na vsech modemech (wireless i wired)
local function openModems()
  local found = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      pcall(rednet.open, name)
      found = true
    end
  end
  return found
end

--=====================================================================
-- ZASOBNIK ENERGIE (Energy Cube / Induction Matrix / jakakoli baterie)
--=====================================================================
-- Nehledame konkretni mod, ale schopnosti bloku:
--   getEnergy() + getEnergyCapacity()  -> CC:Tweaked generic peripheral,
--                                         hodnoty jsou garantovane v FE
--   getEnergy() + getMaxEnergy()       -> nativni integrace modu
--                                         (Mekanism), jednotka dle modu
-- Diky tomu to funguje na Mekanism Energy Cube, Powah, Thermal i dalsi
-- bez jedine radky specificke pro konkretni mod.

local battery = {
  list    = {},   -- nalezene zasobniky (lokalni i vzdalene)
  remotes = {},   -- [computerId] = {stored=, cap=, unit=, label=, lastSeen=}
  index   = 1,
  rx      = 0,    -- pocet prijatych zprav se zasobou (diagnostika)
  samples = {},   -- {t=epoch ms, e=stav} pro vypocet cisteho toku
  shortWin = 15000,  -- ms - okamzity tok
  longWin  = 300000, -- ms - klidny prumer (5 minut)
  stored  = nil,
  cap     = nil,
  unit    = "FE",
}

local function hasStorage(dev)
  return dev and dev.getEnergy and (dev.getEnergyCapacity or dev.getMaxEnergy)
end

local function batLabel(name)
  local n = tostring(name):match("(%d+)$")
  return "BAT" .. (n and ("#" .. n) or "")
end

local function capacityOf(dev)
  local function num(m)
    if not dev[m] then return nil end
    local ok, v = pcall(dev[m])
    if ok then return tonumber(v) end
    return nil
  end
  return num("getEnergyCapacity") or num("getMaxEnergy") or 0
end

-- seznam = lokalni bloky na kabelu + baterie hlasene pres rednet
local function rebuildBatteries()
  local keep = battery.list[battery.index] and battery.list[battery.index].key
  local list = {}

  -- Energii hlasi i Energy Detector a kazdy stroj s vnitrnim bufferem.
  -- Detektor vyradime a zbytek radime podle kapacity sestupne, takze
  -- skutecna baterie je prvni a buffer stroje az za ni.
  local locals = {}
  for _, name in ipairs(peripheral.getNames()) do
    if not ED_TYPES[peripheral.getType(name)] then
      local ok, dev = pcall(peripheral.wrap, name)
      if ok and hasStorage(dev) then
        local cap = capacityOf(dev)
        if cap > 0 then
          locals[#locals + 1] = {
            kind = "local", name = name, dev = dev,
            key = "B:" .. name, label = batLabel(name), cap = cap,
          }
        end
      end
    end
  end
  table.sort(locals, function(a, b) return a.cap > b.cap end)

  for _, e in ipairs(locals) do
    registerDevice(e.key, { kind = "battery", label = e.label, name = e.name })
    list[#list + 1] = e
  end

  local ids = {}
  for id in pairs(battery.remotes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local r = battery.remotes[id]
    list[#list + 1] = {
      kind = "remote", id = id, key = "B:R" .. id,
      label = r.label or ("BAT" .. id),
    }
  end

  battery.list = list
  battery.index = 1
  for i, b in ipairs(list) do
    if b.key == keep then battery.index = i end
  end
end

local function bat()
  return battery.list[battery.index]
end

-- vraci: stav, kapacita, jednotka  (nil pri chybe nebo mrtvem spoji)
local function readStorage(b)
  if not b then return nil end

  if b.kind == "remote" then
    local r = battery.remotes[b.id]
    if not r or os.epoch("utc") - r.lastSeen > REMOTE_TIMEOUT then return nil end
    return r.stored, r.cap, r.unit or "FE"
  end

  local ok, stored = pcall(b.dev.getEnergy)
  stored = ok and tonumber(stored) or nil
  if not stored then return nil end

  -- jednotku hlasime podle toho, ktera metoda kapacitu opravdu dala:
  -- getEnergyCapacity je CC generic a je vzdy ve FE, getMaxEnergy je
  -- nativni metoda modu a jednotka muze byt jina (Mekanism: jouly)
  local cap, unit
  local ok2, c2 = pcall(b.dev.getEnergyCapacity or function() end)
  c2 = ok2 and tonumber(c2) or nil
  if c2 and c2 > 0 then cap, unit = c2, "FE" end

  if not cap and b.dev.getMaxEnergy then
    local ok3, c3 = pcall(b.dev.getMaxEnergy)
    c3 = ok3 and tonumber(c3) or nil
    if c3 and c3 > 0 then cap, unit = c3, "E" end
  end
  return stored, cap, unit or "?"
end

local function sampleStorage()
  local b = bat()
  if not b then
    battery.stored, battery.cap = nil, nil
    return
  end
  local stored, cap, unit = readStorage(b)
  battery.stored, battery.cap, battery.unit = stored, cap, unit or "FE"
  if not stored then return end

  local now = os.epoch("utc")
  battery.samples[#battery.samples + 1] = { t = now, e = stored }
  while #battery.samples > 1 and now - battery.samples[1].t > battery.longWin do
    table.remove(battery.samples, 1)
  end
  markSeen(b.key)
end

-- Cisty tok do/z zasobniku v jednotkach za sekundu.
-- (posledni - prvni) / cas je presne prumerna rychlost zmeny za dane
-- okno, zadna aproximace. Kratke okno = aktualni stav, dlouhe = prumer.
local function netRate(windowMs)
  local s = battery.samples
  local n = #s
  if n < 2 then return nil end

  local cutoff = s[n].t - (windowMs or battery.shortWin)
  local first = n
  for i = n, 1, -1 do
    if s[i].t < cutoff then break end
    first = i
  end
  if first >= n then return nil end

  local dt = (s[n].t - s[first].t) / 1000
  if dt < 2 then return nil end   -- prilis kratky usek = samy sum
  return (s[n].e - s[first].e) / dt, dt
end

local function batteryPct()
  if not (battery.stored and battery.cap and battery.cap > 0) then return nil end
  return battery.stored / battery.cap
end

local function pctColor(p)
  if p == nil then return colors.gray end
  if p <= 0.10 then return colors.red end
  if p <= 0.25 then return colors.orange end
  if p <= 0.50 then return colors.yellow end
  return colors.green
end

-- delsi useky casu: 2h 05m / 12m 30s / 45s
local function fmtLong(sec)
  if not sec or sec ~= sec or sec == math.huge then return "?" end
  sec = math.floor(sec)
  if sec >= 3600 then
    return string.format("%dh %02dm", math.floor(sec / 3600), math.floor(sec % 3600 / 60))
  elseif sec >= 60 then
    return string.format("%dm %02ds", math.floor(sec / 60), sec % 60)
  end
  return sec .. "s"
end

-- text typu "Vydrzi 2h 05m" / "Plno za 12m" / "Stabilni"
local function batteryEta()
  -- pro odhad radsi klidny prumer, jinak vydrz poskakuje
  local net = netRate(battery.longWin) or netRate(battery.shortWin)
  local p = batteryPct()
  if not (net and p) then return "?", colors.gray end
  if net < -0.5 then
    return "Vydrzi " .. fmtLong(battery.stored / -net), colors.orange
  elseif net > 0.5 and battery.cap then
    return "Plno za " .. fmtLong((battery.cap - battery.stored) / net), colors.green
  end
  return "Stabilni", colors.lightGray
end

-- varovne pipnuti pri nizkem stavu; nizsi ton nez budik na spanek,
-- aby se to nedalo zamenit
local function checkLowEnergy()
  local p = batteryPct()
  if not (cfg.lowEnergyAlarm and speaker and p) or p * 100 >= cfg.lowEnergyPct then
    state.lowLast = nil
    return
  end
  local now = os.epoch("utc")
  if not state.lowLast or now - state.lowLast >= cfg.lowInterval * 1000 then
    state.lowLast = now
    pcall(speaker.playSound, cfg.soundName, cfg.volume, 0.6)
  end
end

--=====================================================================

--=====================================================================
-- QUARRY (QuarryPlus pres Block Reader)
--=====================================================================
-- QuarryPlus zadne CC API nema, ale Block Reader z Advanced Peripherals
-- umi precist NBT tile entity. Z nej bereme:
--   area.min/max{X,Y,Z} - hranice tezby
--   head[1..3]          - kde je hlava prave ted
--   state               - MAKE_FRAME / tezi / hotovo
--   digMinY             - spodni hranice, kdyz ji hrac nastavil
--   energy / maxEnergy  - vlastni buffer stroje

local BR_TYPES = { block_reader = true, blockReader = true }

local quarry = {
  list     = {},
  remotes  = {},
  index    = 1,
  samples  = {},      -- {t=epoch ms, done=vytezeno bloku}
  shortWin = 30000,
  longWin  = 300000,
  cur      = nil,     -- posledni rozparsovana data
  tick     = 0,
}

-- Vytahne z NBT jen to podstatne. Stejna funkce je i ve vysilaci,
-- aby se po rednetu neposilalo cele NBT vcetne inventaru.
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

-- vraci: hotovo, celkem, sirka, hloubka, poc.vrstev, spodni Y
local function quarryProgress(q)
  if not q then return nil end
  -- sx/sz zamerne nejsou W/D, aby to neprekrylo rozmery monitoru
  local sx = (q.maxX or 0) - (q.minX or 0) + 1
  local sz = (q.maxZ or 0) - (q.minZ or 0) + 1
  local top = q.maxY
  local bot = q.digMinY or cfg.quarryBottomY
  if not (top and bot) or sx <= 0 or sz <= 0 or top < bot then return nil end

  local layers = top - bot + 1
  local total  = sx * sz * layers

  -- hotove vrstvy + pozice hlavy uvnitr rozdelane vrstvy
  local done = (top - (q.hy or top)) * sx * sz
  local ix = math.min(math.max((q.hx or q.minX) - q.minX, 0), sx - 1)
  local iz = math.min(math.max((q.hz or q.minZ) - q.minZ, 0), sz - 1)
  done = math.min(math.max(done + ix * sz + iz, 0), total)

  return done, total, sx, sz, layers, bot
end

local function qsrc()
  return quarry.list[quarry.index]
end

local function rebuildQuarries()
  local keep = quarry.list[quarry.index] and quarry.list[quarry.index].key
  local list = {}

  for _, name in ipairs(peripheral.getNames()) do
    if BR_TYPES[peripheral.getType(name)] then
      local ok, dev = pcall(peripheral.wrap, name)
      if ok then
        local key = "Q:" .. name
        local n = tostring(name):match("(%d+)$")
        local label = "QRY" .. (n and ("#" .. n) or "")
        registerDevice(key, { kind = "quarry", label = label, name = name })
        list[#list + 1] = { kind = "local", key = key, label = label,
                            name = name, dev = dev }
      end
    end
  end

  local ids = {}
  for id in pairs(quarry.remotes) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    list[#list + 1] = { kind = "remote", id = id, key = "Q:R" .. id,
                        label = "QRY" .. id }
  end

  quarry.list = list
  quarry.index = 1
  for i, e in ipairs(list) do
    if e.key == keep then quarry.index = i end
  end
end

local function readQuarry(src)
  if not src then return nil end
  if src.kind == "remote" then
    local r = quarry.remotes[src.id]
    if not r or os.epoch("utc") - r.lastSeen > REMOTE_TIMEOUT then return nil end
    return r.q
  end
  local okD, data = pcall(src.dev.getBlockData)
  if not okD then return nil end
  local okS, st = pcall(src.dev.getBlockStates)
  return parseQuarry(data, okS and st or nil)
end

local function sampleQuarry()
  -- cteni celeho NBT je drahe, staci po dvou sekundach
  quarry.tick = quarry.tick + cfg.refresh
  if quarry.tick < 2 then return end
  quarry.tick = 0

  local src = qsrc()
  local q = readQuarry(src)
  quarry.cur = q
  if not q then return end
  markSeen(src.key)

  local done = quarryProgress(q)
  if not done then return end

  local now = os.epoch("utc")
  quarry.samples[#quarry.samples + 1] = { t = now, done = done }
  while #quarry.samples > 1 and now - quarry.samples[1].t > quarry.longWin do
    table.remove(quarry.samples, 1)
  end
end

-- vytezenych bloku za sekundu
local function quarryRate(windowMs)
  local s = quarry.samples
  local n = #s
  if n < 2 then return nil end

  local cutoff = s[n].t - (windowMs or quarry.shortWin)
  local first = n
  for i = n, 1, -1 do
    if s[i].t < cutoff then break end
    first = i
  end
  if first >= n then return nil end

  local dt = (s[n].t - s[first].t) / 1000
  if dt < 5 then return nil end
  return (s[n].done - s[first].done) / dt, dt
end

local function quarryEta()
  local done, total = quarryProgress(quarry.cur)
  if not done then return nil end
  local r = quarryRate(quarry.longWin) or quarryRate(quarry.shortWin)
  if not r or r <= 0 then return nil end
  return (total - done) / r
end

--=====================================================================

-- jedna zprava muze nest tok, zasobu, quarry, nebo vse - resime nezavisle
local function onRednet(id, msg, proto)
  if proto ~= RN_PROTO or type(msg) ~= "table" then return false end
  local now = os.epoch("utc")
  local name = msg.label or ("PC" .. id)

  if msg.rate ~= nil then
    local known = energy.remotes[id] ~= nil
    registerDevice("R:" .. id, { kind = "remote", label = name, id = id })
    energy.remotes[id] = {
      rate = tonumber(msg.rate), limit = tonumber(msg.limit),
      label = name, lastSeen = now,
    }
    if not known then rebuildSources() end
  end

  if type(msg.storage) == "table" then
    local known = battery.remotes[id] ~= nil
    local key = "B:R" .. id
    battery.rx = battery.rx + 1
    registerDevice(key, { kind = "battery", label = name .. " bat", id = id })
    battery.remotes[id] = {
      stored = tonumber(msg.storage.stored),
      cap    = tonumber(msg.storage.cap),
      unit   = msg.storage.unit or "FE",
      label  = "BAT" .. id,
      lastSeen = now,
    }
    if not known then rebuildBatteries() end
  end

  if type(msg.quarry) == "table" then
    local known = quarry.remotes[id] ~= nil
    local key = "Q:R" .. id
    registerDevice(key, { kind = "quarry", label = name .. " qry", id = id })
    quarry.remotes[id] = { q = msg.quarry, lastSeen = now }
    if not known then rebuildQuarries() end
  end

  return true
end

--=====================================================================
-- STRANKY
--=====================================================================

local PAGES = {
  { id = "dash",   label = "Prehled"   },
  { id = "energy", label = "Energie"   },
  { id = "bat",    label = "Baterie"   },
  { id = "quarry", label = "Quarry"    },
  { id = "dev",    label = "Zarizeni"  },
  { id = "log",    label = "Log"       },
  { id = "alarm",  label = "Alarm"     },
  { id = "conf",   label = "Nastaveni" },
  { id = "info",   label = "Info"      },
}

local SIDEBAR = math.min(13, math.max(9, math.floor(W * 0.28)))
local CX = SIDEBAR + 2            -- levy okraj obsahu
local CW = W - CX + 1             -- sirka obsahu
local CY = 3                      -- horni okraj obsahu
local CH = H - CY + 1

-- dopredna deklarace: stranky si potrebuji vynutit prekresleni driv,
-- nez je draw() nize definovano
local draw

local BG      = colors.black
local PANEL   = colors.gray
local HEADER  = colors.blue
local OK      = colors.green
local BAD     = colors.red
local MUTED   = colors.lightGray

-- pruh celeho herniho dne s vyznacenym oknem spanku
local function drawDayBar(x, y, w)
  for i = 0, w - 1 do
    local tk = (i / w) * 24000
    local c
    if tk >= cfg.sleepStart and tk <= cfg.sleepEnd then
      c = colors.green
    elseif tk >= 12000 or tk <= 100 then
      c = colors.cyan
    else
      c = colors.lightBlue
    end
    mon.setCursorPos(x + i, y)
    mon.setBackgroundColor(c)
    mon.write(" ")
  end
  -- ukazatel aktualni pozice
  local pos = math.floor((mcTicks() / 24000) * w)
  pos = math.min(w - 1, math.max(0, pos))
  fill(x, y + 1, w, 1, BG)
  text(x + pos, y + 1, "^", colors.white, BG)
end

local function pageDash()
  local sleepable = canSleep()
  local statusColor = sleepable and OK or BAD
  local clock = fmtClock(os.time())

  -- velke hodiny
  local bw = bigWidth(clock)
  local bx = CX + math.floor((CW - bw) / 2)
  drawBig(bx, CY + 1, clock, statusColor, BG)

  -- stav
  local label = sleepable and " LZE SPAT " or " NELZE SPAT "
  fill(CX, CY + 7, CW, 1, BG)
  textCenter(CX, CW, CY + 7, label, colors.black, statusColor)

  -- odpocet
  local line
  if sleepable then
    line = "Konec noci za " .. fmtDuration(realSecondsUntil(cfg.sleepEnd + 1))
  else
    line = "Spat lze za " .. fmtDuration(realSecondsUntil(cfg.sleepStart))
  end
  fill(CX, CY + 9, CW, 1, BG)
  textCenter(CX, CW, CY + 9, line, MUTED, BG)

  -- pruh dne
  if CH >= 13 then
    drawDayBar(CX, CY + 11, CW)
  end

  -- tok energie a stav baterie - to, na co se kouka z dalky
  local src = source()
  local p = batteryPct()
  if (src or p) and H >= 18 then
    fill(CX, H - 2, CW, 1, BG)
    if src then
      local rate, _, online = readSource(src)
      text(CX, H - 2, online and (fmtFE(rate) .. " FE/t") or "tok offline",
        online and colors.green or colors.red, BG)
    end
    if p then
      textRight(CX, CW, H - 2,
        string.format("BAT %d%%  %s", math.floor(p * 100), (batteryEta())),
        pctColor(p), BG)
      drawBar(CX, H - 1, CW, p, pctColor(p))
    end
  end

  -- patka
  local nxt = secondsToNextAlarm()
  local foot
  if not speaker then
    foot = "Bez speakeru"
  elseif not cfg.alarmEnabled then
    foot = "Alarm vypnut"
  elseif nxt then
    foot = "Dalsi zvuk za " .. fmtDuration(nxt)
  else
    foot = "Alarm ceka na noc"
  end
  fill(CX, H, CW, 1, BG)
  text(CX, H, "Den " .. os.day(), MUTED, BG)
  textRight(CX, CW, H, foot, MUTED, BG)
end

local function pageAlarm()
  local y = CY + 1
  text(CX, y, "Zvukova signalizace", colors.white, BG); y = y + 2

  local st = cfg.alarmEnabled and "ZAPNUT" or "VYPNUT"
  text(CX, y, "Stav:     ", MUTED, BG)
  text(CX + 10, y, st, cfg.alarmEnabled and OK or BAD, BG); y = y + 1
  text(CX, y, "Interval: " .. cfg.alarmInterval .. " s", MUTED, BG); y = y + 1
  text(CX, y, "Zvuk:     " .. cfg.soundName:match("[^.]+$"), MUTED, BG); y = y + 1
  text(CX, y, "Pipnuti:  " .. state.alarmCount .. " (tuto noc)", MUTED, BG); y = y + 2

  button(CX, y, 14, 1, cfg.alarmEnabled and "Vypnout" or "Zapnout",
    cfg.alarmEnabled and colors.red or colors.green, colors.white, function()
      cfg.alarmEnabled = not cfg.alarmEnabled
      saveConfig()
      toast(cfg.alarmEnabled and "Alarm zapnut" or "Alarm vypnut")
    end)
  button(CX + 16, y, 14, 1, "Test zvuku", colors.blue, colors.white, function()
    if playAlarm() then toast("Prehrano") else toast("Speaker chybi!") end
  end)
  y = y + 2

  text(CX, y, "Interval:", MUTED, BG); y = y + 1
  local opts = { 15, 30, 60, 120 }
  local bx = CX
  for _, v in ipairs(opts) do
    local sel = (cfg.alarmInterval == v)
    button(bx, y, 7, 1, v .. "s", sel and colors.green or PANEL,
      sel and colors.black or colors.white, function()
        cfg.alarmInterval = v
        state.lastAlarm = 0
        saveConfig()
      end)
    bx = bx + 8
  end
  y = y + 2

  text(CX, y, "Okno spanku: " .. tickToClock(cfg.sleepStart) ..
    " - " .. tickToClock(cfg.sleepEnd), MUTED, BG)
end

local function pageConf()
  local y = CY + 1
  text(CX, y, "Nastaveni", colors.white, BG); y = y + 2

  text(CX, y, "Velikost textu: " .. cfg.textScale, MUTED, BG); y = y + 1
  local bx = CX
  for _, v in ipairs({ 0.5, 1, 1.5, 2 }) do
    local sel = (cfg.textScale == v)
    button(bx, y, 6, 1, tostring(v), sel and colors.green or PANEL,
      sel and colors.black or colors.white, function()
        cfg.textScale = v
        saveConfig()
        mon.setTextScale(v)
        os.queueEvent("sleepmon_resize")
      end)
    bx = bx + 7
  end
  y = y + 2

  text(CX, y, "Hlasitost: " .. string.format("%.1f", cfg.volume), MUTED, BG); y = y + 1
  button(CX, y, 5, 1, "-", PANEL, colors.white, function()
    cfg.volume = math.max(0.1, cfg.volume - 0.2); saveConfig()
  end)
  button(CX + 6, y, 5, 1, "+", PANEL, colors.white, function()
    cfg.volume = math.min(3.0, cfg.volume + 0.2); saveConfig()
  end)
  y = y + 2

  text(CX, y, "Zvuk:", MUTED, BG); y = y + 1
  bx = CX
  local row = y
  for _, s in ipairs(SOUNDS) do
    if bx + 8 > CX + CW then bx = CX; row = row + 1 end
    local sel = (cfg.soundName == s.name)
    button(bx, row, 8, 1, s.label, sel and colors.green or PANEL,
      sel and colors.black or colors.white, function()
        cfg.soundName = s.name; saveConfig(); playAlarm()
      end)
    bx = bx + 9
  end
end

--=====================================================================
-- GRAF TOKU
--=====================================================================

local NO_LIMIT = 2000000000   -- setTransferRateLimit(MAX) = prakticky bez limitu
local GUTTER   = 6            -- sirka sloupce s popisky osy Y

local GRAPH_WINDOWS = {
  { label = "1m",  sec = 60   },
  { label = "5m",  sec = 300  },
  { label = "15m", sec = 900  },
}

-- zaokrouhli maximum osy nahoru na "hezke" cislo, aby mel graf hlavu
local function niceMax(v)
  if not v or v <= 0 then return 1 end
  local exp = math.floor(math.log(v) / math.log(10))
  local base = 10 ^ exp
  local m = v / base
  for _, s in ipairs({ 1, 1.5, 2, 3, 4, 5, 6, 8, 10 }) do
    if m <= s then return s * base end
  end
  return 10 * base
end

-- kompaktni popisek osy: 10k, 2.5k, 500
local function fmtAxis(v)
  if v >= 1e9 then return string.format("%.4gG", v / 1e9) end
  if v >= 1e6 then return string.format("%.4gM", v / 1e6) end
  if v >= 1e3 then return string.format("%.4gk", v / 1e3) end
  return string.format("%.4g", v)
end

-- slouci vzorky do w sloupcu tak, aby graf pokryl pozadovane casove okno
local function graphColumns(w, windowSec)
  local perCol = math.max(1, math.floor((windowSec / cfg.refresh) / w))
  local n = #energy.history
  local cols = {}
  for c = 1, w do
    local hi = n - (w - c) * perCol
    local lo = hi - perCol + 1
    local sum, cnt, mx = 0, 0, 0
    for i = math.max(1, lo), hi do
      local v = energy.history[i]
      if v then
        sum = sum + v; cnt = cnt + 1
        if v > mx then mx = v end
      end
    end
    if cnt > 0 then cols[c] = { avg = sum / cnt, max = mx } end
  end
  return cols
end

-- sloupcovy graf s osou Y, nulovou linkou a hladinou limitu
local function drawGraph(x, y, w, h)
  fill(x, y, w, h, colors.black)
  local gx, gw = x + GUTTER, w - GUTTER
  if gw < 4 or h < 3 then return nil end

  local cols = graphColumns(gw, cfg.graphWindow)
  local peak = 0
  for _, c in pairs(cols) do
    if c.max > peak then peak = c.max end
  end
  local axis = niceMax(peak)
  local mid = y + math.floor((h - 1) / 2)

  -- popisky osy Y
  textRight(x, GUTTER - 1, y, fmtAxis(axis), MUTED, BG)
  textRight(x, GUTTER - 1, mid, fmtAxis(axis / 2), colors.gray, BG)
  textRight(x, GUTTER - 1, y + h - 1, "0", MUTED, BG)

  -- vodici linka v polovine skaly
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.gray)
  mon.setCursorPos(gx, mid)
  mon.write(string.rep("-", gw))

  -- hladina nastaveneho limitu (jen kdyz je realny a vejde se do skaly)
  local limit = energy.limit
  local showLimit = limit and limit > 0 and limit < NO_LIMIT and limit <= axis
  if showLimit then
    local lr = y + h - 1 - math.floor((limit / axis) * (h - 1) + 0.5)
    mon.setCursorPos(gx, lr)
    mon.setTextColor(colors.orange)
    mon.write(string.rep("-", gw))
  end

  -- sloupce (kreslime pres linky, takze prekryv nevadi)
  for c = 1, gw do
    local col = cols[c]
    if col then
      local bh = math.floor((col.avg / axis) * h + 0.5)
      if col.avg > 0 and bh < 1 then bh = 1 end
      local hot = limit and limit > 0 and limit < NO_LIMIT and col.max >= limit * 0.98
      for r = 0, bh - 1 do
        mon.setCursorPos(gx + c - 1, y + h - 1 - r)
        mon.setBackgroundColor(hot and colors.red or colors.green)
        mon.write(" ")
      end
    end
  end

  mon.setBackgroundColor(BG)
  return axis
end

local function pageEnergy()
  local src = source()

  if not src then
    local y = CY + 1
    text(CX, y, "Zadny Energy Detector", colors.white, BG); y = y + 2
    text(CX, y, "Pripoj ho jednim ze zpusobu:", MUTED, BG); y = y + 2
    text(CX, y, "1) Wired modem + Networking", MUTED, BG); y = y + 1
    text(CX, y, "   Cable az k pocitaci, pak", MUTED, BG); y = y + 1
    text(CX, y, "   modem zapnout pravym kl.", MUTED, BG); y = y + 2
    text(CX, y, "2) Druhy pocitac u detektoru", MUTED, BG); y = y + 1
    text(CX, y, "   + ender modem na obou,", MUTED, BG); y = y + 1
    text(CX, y, "   program sender", MUTED, BG); y = y + 2
    button(CX, math.min(y, H), 16, 1, "Hledat znovu", colors.blue, colors.white, function()
      rebuildSources(); openModems(); toast("Hledam...")
    end)
    return
  end

  local rate, limit, online = readSource(src)
  local y = CY

  -- prepinac zdroju (jen kdyz je jich vic)
  if #energy.sources > 1 then
    local bx = CX
    for i, s in ipairs(energy.sources) do
      local sel = (i == energy.index)
      local w = math.min(8, math.floor(CW / #energy.sources) - 1)
      if bx + w - 1 <= CX + CW - 1 then
        button(bx, y, w, 1, s.label, sel and colors.lightBlue or PANEL,
          sel and colors.black or colors.white, function()
            energy.index = i
            resetEnergyStats()
            energy.pending = nil
          end)
      end
      bx = bx + w + 1
    end
    y = y + 2
  else
    y = y + 1
  end

  -- hlavni cisla
  local capped = limit and limit > 0 and limit < NO_LIMIT
  local overLimit = capped and rate and rate >= limit * 0.95
  local rateColor = colors.red
  if online then rateColor = overLimit and colors.orange or colors.green end

  text(CX, y, "Tok:", MUTED, BG)
  text(CX + 7, y, (online and fmtFE(rate) or "--") .. " FE/t", rateColor, BG)
  if src.kind == "remote" then
    textRight(CX, CW, y, online and "rednet ok" or "OFFLINE",
      online and colors.gray or colors.red, BG)
  end
  y = y + 1

  local limStr
  if not limit or limit <= 0 then
    limStr = "neznamy"
  elseif limit >= NO_LIMIT then
    limStr = "bez limitu"          -- MAX se tvari jako 2.15G, coz mate
  else
    limStr = fmtFE(limit) .. " FE/t"
  end
  text(CX, y, "Limit:", MUTED, BG)
  text(CX + 7, y, limStr, colors.white, BG)
  if capped and online and rate then
    textRight(CX, CW, y, math.floor(rate / limit * 100) .. "% limitu", MUTED, BG)
  end
  y = y + 1

  text(CX, y, "Max:", MUTED, BG)
  text(CX + 7, y, fmtFE(energy.peak) .. " FE/t", MUTED, BG)
  textRight(CX, CW, y, "celkem " .. fmtFE(energy.total) .. " FE", MUTED, BG)
  y = y + 2

  -- graf s osou
  local gy = y
  local gh = math.max(4, (H - 3) - gy + 1)
  drawGraph(CX, gy, CW, gh)

  -- casova osa + volba delky okna
  local wy = H - 2
  fill(CX, wy, CW, 1, BG)
  local span = (cfg.graphWindow >= 60)
    and (math.floor(cfg.graphWindow / 60) .. " min zpet")
    or (cfg.graphWindow .. " s zpet")
  text(CX, wy, "<- " .. span, MUTED, BG)

  local bw = 5
  local bx = CX + CW - (#GRAPH_WINDOWS * (bw + 1)) + 1
  for i, gwin in ipairs(GRAPH_WINDOWS) do
    local sel = (cfg.graphWindow == gwin.sec)
    button(bx + (i - 1) * (bw + 1), wy, bw, 1, gwin.label,
      sel and colors.lightBlue or PANEL, sel and colors.black or colors.white,
      function() cfg.graphWindow = gwin.sec; saveConfig() end)
  end

  -- ovladani limitu (dvoukrokove - meni skutecnou sit!)
  if energy.pending then
    local v = energy.pending
    fill(CX, H - 1, CW, 1, BG)
    text(CX, H - 1, "Nastavit limit " .. fmtFE(v) .. " FE/t?", colors.yellow, BG)
    button(CX, H, 8, 1, "ANO", colors.green, colors.black, function()
      applyLimit(v)
      energy.pending = nil
      toast("Limit nastaven")
    end)
    button(CX + 9, H, 8, 1, "NE", colors.red, colors.white, function()
      energy.pending = nil
    end)
  else
    local presets = { 1000, 4000, 16000, 64000, 2147483647 }
    local labels  = { "1k", "4k", "16k", "64k", "MAX" }
    local bw = math.max(4, math.floor(CW / #presets) - 1)
    for i, v in ipairs(presets) do
      local bx = CX + (i - 1) * (bw + 1)
      if bx + bw - 1 <= CX + CW - 1 then
        button(bx, H - 1, bw, 1, labels[i], PANEL, colors.white, function()
          energy.pending = v
        end)
      end
    end
    fill(CX, H, CW, 1, BG)
    button(CX, H, 16, 1, "Reset statistik", colors.gray, colors.white, function()
      resetEnergyStats(); toast("Vynulovano")
    end)
  end
end

local function pageBattery()
  local b = bat()
  local y = CY

  if not b then
    y = CY + 1
    text(CX, y, "Zadna baterie nenalezena", colors.white, BG); y = y + 2
    text(CX, y, "Hledaji se bloky umejici", MUTED, BG); y = y + 1
    text(CX, y, "getEnergy + getEnergyCapacity", MUTED, BG); y = y + 1
    text(CX, y, "nebo getMaxEnergy (Mekanism).", MUTED, BG); y = y + 2
    text(CX, y, "Energy Cube pripoj wired", MUTED, BG); y = y + 1
    text(CX, y, "modemem + Networking Cable", MUTED, BG); y = y + 1
    text(CX, y, "a modem zapni pravym kl.", MUTED, BG); y = y + 2
    button(CX, math.min(y, H), 16, 1, "Hledat znovu", colors.blue, colors.white, function()
      rebuildBatteries(); toast("Hledam...")
    end)
    return
  end

  -- prepinac baterii, kdyz je jich vic
  if #battery.list > 1 then
    local bx = CX
    for i, e in ipairs(battery.list) do
      local sel = (i == battery.index)
      local w = math.min(8, math.floor(CW / #battery.list) - 1)
      if bx + w - 1 <= CX + CW - 1 then
        button(bx, y, w, 1, e.label, sel and colors.lightBlue or PANEL,
          sel and colors.black or colors.white, function()
            battery.index = i
            battery.samples = {}
          end)
      end
      bx = bx + w + 1
    end
    y = y + 2
  else
    text(CX, y, "Zasoba energie", colors.white, BG)
    textRight(CX, CW, y, b.label, MUTED, BG)
    y = y + 2
  end

  local p = batteryPct()
  local col = pctColor(p)

  if not p then
    text(CX, y, b.kind == "remote" and "Spojeni vypadlo" or "Blok neodpovida", BAD, BG)
    y = y + 1
    if b.kind == "remote" then
      text(CX, y, "vysilac PC" .. tostring(b.id) .. " mlci", MUTED, BG)
      y = y + 1
      text(CX, y, "(nenacteny chunk?)", MUTED, BG)
    end
    return
  end

  -- procenta + absolutni hodnoty
  text(CX, y, string.format("%.2f %%", p * 100), col, BG)
  textRight(CX, CW, y,
    fmtFE(battery.stored) .. " / " .. fmtFE(battery.cap) .. " " .. battery.unit,
    MUTED, BG)
  y = y + 1

  -- presna hodnota + diagnostika prijmu:
  -- #pocet zprav a stari te posledni. Kdyz pocet roste a hodnota
  -- vpravo stoji, chyba je na strane vysilace, ne v prenosu.
  if b.kind == "remote" then
    local r = battery.remotes[b.id]
    local age = r and (os.epoch("utc") - r.lastSeen) / 1000 or nil
    text(CX, y, string.format("#%d  %.1fs", battery.rx, age or -1), colors.gray, BG)
  end
  textRight(CX, CW, y, fmtExact(battery.stored), colors.gray, BG)
  y = y + 1

  drawBar(CX, y, CW, p, col)
  drawBar(CX, y + 1, CW, p, col)
  y = y + 3

  -- okamzity tok a dlouhodoby prumer
  local function flowLine(label, v, dt)
    if not v then
      text(CX, y, label .. " meri se...", MUTED, BG)
    else
      local sign = v >= 0 and "+" or "-"
      text(CX, y, label, MUTED, BG)
      text(CX + 9, y, sign .. fmtFE(math.abs(v)) .. " " .. battery.unit .. "/s",
        v >= 0 and colors.green or colors.orange, BG)
      textRight(CX, CW, y,
        dt and ("za " .. fmtLong(dt)) or (sign .. fmtFE(math.abs(v) / 20) .. "/t"),
        colors.gray, BG)
    end
    y = y + 1
  end

  local avg, avgDt = netRate(battery.longWin)
  flowLine("Tok:", netRate(battery.shortWin), nil)
  flowLine("Prumer:", avg, avgDt)

  local etaTxt, etaCol = batteryEta()
  text(CX, y, etaTxt, etaCol, BG)
  y = y + 2

  -- varovani pri nizkem stavu
  if y <= H - 1 then
    text(CX, y, "Varovani pod " .. cfg.lowEnergyPct .. " %", MUTED, BG)
    y = y + 1
    button(CX, y, 8, 1, cfg.lowEnergyAlarm and "ZAP" or "VYP",
      cfg.lowEnergyAlarm and colors.green or colors.red,
      cfg.lowEnergyAlarm and colors.black or colors.white, function()
        cfg.lowEnergyAlarm = not cfg.lowEnergyAlarm
        saveConfig()
      end)
    button(CX + 9, y, 5, 1, "-", PANEL, colors.white, function()
      cfg.lowEnergyPct = math.max(5, cfg.lowEnergyPct - 5); saveConfig()
    end)
    button(CX + 15, y, 5, 1, "+", PANEL, colors.white, function()
      cfg.lowEnergyPct = math.min(90, cfg.lowEnergyPct + 5); saveConfig()
    end)
  end
end

local function pageQuarry()
  local src = qsrc()
  local y = CY

  if not src then
    y = CY + 1
    text(CX, y, "Zadna quarry", colors.white, BG); y = y + 2
    text(CX, y, "Potreba Block Reader z Advanced", MUTED, BG); y = y + 1
    text(CX, y, "Peripherals, ktery CELI bloku", MUTED, BG); y = y + 1
    text(CX, y, "quarry (predni strana na nej).", MUTED, BG); y = y + 2
    text(CX, y, "QuarryPlus vlastni CC API nema,", MUTED, BG); y = y + 1
    text(CX, y, "cteme NBT tile entity.", MUTED, BG); y = y + 2
    button(CX, math.min(y, H), 16, 1, "Hledat znovu", colors.blue, colors.white, function()
      rebuildQuarries(); toast("Hledam...")
    end)
    return
  end

  if #quarry.list > 1 then
    local bx = CX
    for i, s in ipairs(quarry.list) do
      local sel = (i == quarry.index)
      local w = math.min(8, math.floor(CW / #quarry.list) - 1)
      if bx + w - 1 <= CX + CW - 1 then
        button(bx, y, w, 1, s.label, sel and colors.lightBlue or PANEL,
          sel and colors.black or colors.white, function()
            quarry.index = i
            quarry.samples = {}
            quarry.cur = nil
          end)
      end
      bx = bx + w + 1
    end
    y = y + 2
  end

  local q = quarry.cur
  if not q then
    text(CX, y, src.kind == "remote" and "Spojeni vypadlo" or "Blok neodpovida", BAD, BG)
    y = y + 1
    text(CX, y, "celi reader opravdu quarry?", MUTED, BG)
    return
  end

  text(CX, y, "Quarry", colors.white, BG)
  local stCol = colors.lightGray
  if q.working == false then stCol = colors.orange end
  textRight(CX, CW, y, q.state, stCol, BG)
  y = y + 1

  local done, total, sx, sz, layers, bot = quarryProgress(q)
  if not done then
    text(CX, y, "Neznama oblast tezby", BAD, BG)
    return
  end

  text(CX, y, sx .. "x" .. sz .. "  Y " .. q.maxY .. ".." .. bot, MUTED, BG)
  textRight(CX, CW, y, layers .. " vrstev", MUTED, BG)
  y = y + 1

  text(CX, y, "Hlava: " .. tostring(q.hx) .. " " .. tostring(q.hy) ..
    " " .. tostring(q.hz), MUTED, BG)
  y = y + 2

  -- postup
  local p = done / total
  local col = (p >= 1) and colors.green or colors.lightBlue
  text(CX, y, string.format("%.2f %%", p * 100), col, BG)
  textRight(CX, CW, y, fmtFE(done) .. " / " .. fmtFE(total) .. " bl", MUTED, BG)
  y = y + 1
  drawBar(CX, y, CW, p, col)
  drawBar(CX, y + 1, CW, p, col)
  y = y + 3

  -- tempo tezby
  local function rateLine(label, v, dt)
    if not v then
      text(CX, y, label .. " meri se...", MUTED, BG)
    else
      text(CX, y, label, MUTED, BG)
      text(CX + 9, y, string.format("%+.1f bl/s", v),
        v > 0 and colors.green or colors.gray, BG)
      if dt then textRight(CX, CW, y, "za " .. fmtLong(dt), colors.gray, BG) end
    end
    y = y + 1
  end

  local avg, avgDt = quarryRate(quarry.longWin)
  rateLine("Tempo:", quarryRate(quarry.shortWin), nil)
  rateLine("Prumer:", avg, avgDt)

  local eta = quarryEta()
  if p >= 1 then
    text(CX, y, "Hotovo", colors.green, BG)
  elseif eta then
    text(CX, y, "Hotovo za " .. fmtLong(eta), colors.white, BG)
  else
    text(CX, y, "Odhad se pocita...", MUTED, BG)
  end
  y = y + 2

  -- vlastni energeticky buffer stroje
  if q.energy and q.maxEnergy and q.maxEnergy > 0 and y <= H then
    local bp = q.energy / q.maxEnergy
    text(CX, y, "Buffer:", MUTED, BG)
    text(CX + 9, y, string.format("%.1f %%", bp * 100), pctColor(bp), BG)
    y = y + 2
  end

  -- dno je odhad, dokud ho quarry nema nastaveny sama
  if y <= H and not q.digMinY then
    text(CX, y, "Dno (odhad): " .. cfg.quarryBottomY, MUTED, BG)
    button(CX + 20, y, 5, 1, "-16", PANEL, colors.white, function()
      cfg.quarryBottomY = math.max(-64, cfg.quarryBottomY - 16)
      saveConfig(); quarry.samples = {}
    end)
    button(CX + 26, y, 5, 1, "+16", PANEL, colors.white, function()
      cfg.quarryBottomY = math.min((q.maxY or 320) - 1, cfg.quarryBottomY + 16)
      saveConfig(); quarry.samples = {}
    end)
  end
end

local function pageLog()
  local y = CY

  text(CX, y, "Log", colors.white, BG)
  textRight(CX, CW, y,
    updater and ("verze " .. updater.localVersion()) or "bez updateru",
    MUTED, BG)
  y = y + 1

  logs.unseen = 0
  logs.errors = 0

  local rows = math.max(1, (H - 2) - y + 1)
  local first = math.max(1, #logs.lines - rows + 1)

  if #logs.lines == 0 then
    text(CX, y, "zatim nic", colors.gray, BG)
  end

  for i = first, #logs.lines do
    local l = logs.lines[i]
    local col = colors.lightGray
    if l.level == "error" then col = colors.red
    elseif l.level == "warn" then col = colors.orange
    elseif l.level == "ok" then col = colors.green end
    text(CX, y, (l.clock .. " " .. l.from .. ": " .. l.text):sub(1, CW), col, BG)
    y = y + 1
  end

  local bw = math.floor((CW - 1) / 2)
  button(CX, H, bw, 1, "Aktualizovat", colors.blue, colors.white, function()
    if not updater then toast("updater chybi"); return end
    if not updater.httpAvailable() then toast("HTTP je vypnute"); return end

    toast("stahuji...")
    draw()
    local ver, err, changed = updater.pullGithub(true)
    if err then
      addLog({ level = "error", from = "PC1", text = "update: " .. tostring(err) })
      toast("chyba, viz log")
    elseif changed then
      addLog({ level = "ok", from = "PC1", text = "verze " .. tostring(ver) })
      toast("verze " .. tostring(ver) .. ", restart")
      draw()
      sleep(1)
      os.reboot()
    else
      toast("uz je aktualni")
    end
  end)
  button(CX + bw + 1, H, bw, 1, "Smazat log", colors.gray, colors.white, function()
    logs.lines = {}
  end)
end

local function pageDevices()
  local y = CY

  text(CX, y, "Zarizeni", colors.white, BG)
  local probs = problemCount()
  textRight(CX, CW, y, probs == 0 and "vse OK" or (probs .. "x problem"),
    probs == 0 and OK or BAD, BG)
  y = y + 2

  -- jeden radek tabulky: nazev | detail | stav vpravo
  local function row(name, detail, stat, col)
    if y > H - 2 then return false end
    text(CX, y, name:sub(1, 9), MUTED, BG)
    text(CX + 10, y, detail:sub(1, math.max(1, CW - 19)), colors.white, BG)
    textRight(CX, CW, y, stat, col, BG)
    y = y + 1
    return true
  end

  -- zakladni periferie hlavniho pocitace
  row("Monitor", tostring(cfg.monitorSide) .. " " .. W .. "x" .. H, "OK", OK)
  row("Speaker", speaker and tostring(cfg.speakerSide) or "nenalezen",
    speaker and "OK" or "CHYBI", speaker and OK or BAD)

  local nModem = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      nModem = nModem + 1
      local m = peripheral.wrap(name)
      local wl = m and m.isWireless and m.isWireless()
      row("Modem", name .. (wl and " bezdrat" or " kabel"), "OK", OK)
    end
  end
  if nModem == 0 then
    row("Modem", "zadny - rednet nejede", "CHYBI", colors.orange)
  end

  -- evidovane detektory (i ty, ktere prave nehlasi)
  y = y + 1
  if y <= H - 2 then
    text(CX, y, "Detektory a baterie:", MUTED, BG); y = y + 1
  end

  local keys = {}
  for k in pairs(cfg.expected) do keys[#keys + 1] = k end
  table.sort(keys)

  if #keys == 0 then
    if y <= H - 2 then text(CX, y, "zatim zadny nebyl viden", colors.gray, BG) end
  else
    local shown = 0
    for _, k in ipairs(keys) do
      local e = cfg.expected[k]
      local st, col, age = deviceStatus(k)
      local detail
      if e.kind == "quarry" then
        detail = e.name and "quarry kabel" or ("quarry PC" .. tostring(e.id))
      elseif e.kind == "battery" then
        detail = e.name and ("baterie kabel") or ("baterie PC" .. tostring(e.id))
      elseif e.kind == "local" then
        detail = "kabel"
      else
        detail = "rednet PC" .. tostring(e.id)
      end
      if st ~= "OK" and age then detail = detail .. " " .. fmtDuration(age) end
      if row(tostring(e.label), detail, st, col) then shown = shown + 1 else break end
    end
    if #keys > shown and y <= H - 1 then
      text(CX, y, "+" .. (#keys - shown) .. " dalsich", colors.gray, BG)
    end
  end

  -- tlacitka
  local bw = math.floor((CW - 1) / 2)
  button(CX, H, bw, 1, "Hledat znovu", colors.blue, colors.white, function()
    openModems(); rebuildSources(); rebuildBatteries(); rebuildQuarries()
    refreshPresence(); toast("Prohledano")
  end)
  button(CX + bw + 1, H, bw, 1, "Zapomenout", colors.gray, colors.white, function()
    local n = forgetOffline()
    toast(n > 0 and ("Odebrano " .. n) or "Nic k odebrani")
  end)
end

local function pageInfo()
  local y = CY + 1
  text(CX, y, "SleepMon " .. VERSION, colors.white, BG); y = y + 2
  text(CX, y, "Herni tik: " .. math.floor(mcTicks()), MUTED, BG); y = y + 1
  text(CX, y, "Herni den: " .. os.day(), MUTED, BG); y = y + 1
  text(CX, y, "ID pocitace: " .. os.getComputerID(), MUTED, BG); y = y + 1
  text(CX, y, "Uptime: " .. fmtDuration(os.clock()), MUTED, BG); y = y + 2
  text(CX, y, "Stav periferii: zalozka Zarizeni", MUTED, BG); y = y + 2
  text(CX, y, "Ukonceni: klavesa Q na pocitaci.", MUTED, BG); y = y + 1
  text(CX, y, "Konfigurace: " .. CFG_PATH, MUTED, BG)
end

local PAGE_FN = {
  dash = pageDash, energy = pageEnergy, bat = pageBattery,
  quarry = pageQuarry, dev = pageDevices, log = pageLog,
  alarm = pageAlarm, conf = pageConf, info = pageInfo,
}

--=====================================================================
-- VYKRESLENI CELE OBRAZOVKY
--=====================================================================

function draw()
  clearClickables()
  fill(1, 1, W, H, BG)

  -- horni lista
  fill(1, 1, W, 1, HEADER)
  text(2, 1, "SleepMon", colors.white, HEADER)

  -- varovny indikator, aby byl vypadek videt i bez otevreni zalozky
  local probs = problemCount()
  if probs > 0 then
    text(11, 1, " ! " .. probs .. " ", colors.white, colors.red)
  end

  -- hodiny vpravo nahore
  local sleepable = canSleep()
  local clockBg = sleepable and OK or BAD
  local clockStr = " " .. fmtClock(os.time()) .. " "
  fill(W - #clockStr + 1, 1, #clockStr, 1, clockBg)
  text(W - #clockStr + 1, 1, clockStr, colors.black, clockBg)

  -- tep: strida se pri kazdem prekresleni. Kdyz prestane blikat,
  -- program nebezi a monitor uz jen drzi posledni obraz.
  state.beat = not state.beat
  text(W - #clockStr - 1, 1, state.beat and "." or " ", colors.white, HEADER)

  -- postranni menu
  fill(1, 2, SIDEBAR, H - 1, BG)
  local by = 3
  -- na nizkem monitoru zhustime menu na kazdy radek
  local step = (3 + (#PAGES - 1) * 2 <= H - 2) and 2 or 1
  for _, p in ipairs(PAGES) do
    local sel = (state.page == p.id)
    local bg = sel and colors.lightBlue or PANEL
    if p.id == "dev" and probs > 0 and not sel then bg = colors.red end
    if p.id == "log" and not sel and logs.unseen > 0 then
      bg = (logs.errors > 0) and colors.red or colors.brown
    end
    button(1, by, SIDEBAR, 1, p.label, bg,
      sel and colors.black or colors.white, function() state.page = p.id end)
    by = by + step
  end

  -- rychly prepinac alarmu na spodku menu
  button(1, H, SIDEBAR, 1, cfg.alarmEnabled and "Zvuk: ZAP" or "Zvuk: VYP",
    cfg.alarmEnabled and colors.green or colors.red, colors.black, function()
      cfg.alarmEnabled = not cfg.alarmEnabled
      saveConfig()
    end)

  -- svisly oddelovac
  fill(SIDEBAR + 1, 2, 1, H - 1, colors.gray)

  -- obsah
  local fn = PAGE_FN[state.page]
  if fn then fn() end

  -- toast
  if state.toast then
    if os.epoch("utc") > state.toast.until_ then
      state.toast = nil
    else
      local s = " " .. state.toast.text .. " "
      textCenter(CX, CW, CY, s, colors.black, colors.yellow)
    end
  end

  mon.setBackgroundColor(BG)
end

local function drawLocal()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("SleepMon " .. VERSION .. " bezi")
  print("")
  term.setTextColor(colors.lightGray)
  print("Monitor: " .. tostring(cfg.monitorSide))
  print("Speaker: " .. (speaker and cfg.speakerSide or "NENALEZEN"))
  print("")
  term.setTextColor(canSleep() and colors.green or colors.red)
  print(canSleep() and "LZE SPAT  " .. fmtClock(os.time())
                    or "NELZE SPAT  " .. fmtClock(os.time()))
  term.setTextColor(colors.gray)
  print("")
  print("Stisknuti Q ukonci program.")
end

--=====================================================================
-- HLAVNI SMYCKA
--=====================================================================

local function recalcLayout()
  W, H = mon.getSize()
  SIDEBAR = math.min(13, math.max(9, math.floor(W * 0.28)))
  CX = SIDEBAR + 2
  CW = W - CX + 1
  CH = H - CY + 1
end

local function main()
  openModems()
  rebuildSources()
  rebuildBatteries()
  rebuildQuarries()
  recalcLayout()
  draw()
  drawLocal()

  local timer = os.startTimer(cfg.refresh)
  local localTimer = os.startTimer(5)

  while state.running do
    local ev = { os.pullEvent() }
    local e = ev[1]

    if e == "timer" then
      if ev[2] == timer then
        checkAlarm()
        refreshPresence()
        sampleEnergy()
        sampleStorage()
        sampleQuarry()
        checkLowEnergy()
        draw()
        timer = os.startTimer(cfg.refresh)
      elseif ev[2] == localTimer then
        drawLocal()
        localTimer = os.startTimer(5)
      end

    elseif e == "monitor_touch" then
      local b = hit(ev[3], ev[4])
      if b and b.action then
        b.action()
        recalcLayout()
        draw()
      end

    elseif e == "monitor_resize" or e == "sleepmon_resize" then
      recalcLayout()
      draw()

    elseif e == "key" then
      if ev[2] == keys.q then
        state.running = false
      elseif ev[2] == keys.r then
        recalcLayout(); draw(); drawLocal()
      end

    elseif e == "rednet_message" then
      local rid, rmsg, rproto = ev[2], ev[3], ev[4]
      if updater and rproto == updater.PROTO then
        -- vzdaleny pocitac si rika o aktualizaci
        pcall(updater.serve, rid, rmsg, rproto)
      elseif updater and rproto == updater.LOG_PROTO then
        addLog(rmsg)
      else
        onRednet(rid, rmsg, rproto)
      end

    elseif e == "peripheral" or e == "peripheral_detach" then
      -- znovu najit periferie (napr. po prepojeni nebo pripojeni kabelu)
      local m = findPeripheral(cfg.monitorSide, "monitor")
      if m then mon = m; mon.setTextScale(cfg.textScale); recalcLayout() end
      speaker = (findPeripheral(cfg.speakerSide, "speaker"))
      openModems()
      rebuildSources()
      rebuildBatteries()
      rebuildQuarries()
      draw()
      drawLocal()
    end
  end
end

local ok, err = pcall(main)

-- uklid
mon.setBackgroundColor(colors.black)
mon.setTextColor(colors.white)
mon.clear()
mon.setCursorPos(1, 1)
mon.write("SleepMon ukoncen")

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then
  printError("Chyba: " .. tostring(err))
else
  print("SleepMon ukoncen.")
end
