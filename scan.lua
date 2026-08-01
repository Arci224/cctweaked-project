---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - diagnostika periferii

  Spust na pocitaci, ke kteremu pripojujes bloky (typicky sender).
  Vypise vsechno, co pocitac vidi, a u kazdeho pozna, jestli to umi
  hlasit tok energie nebo zasobu.

  Nazev vypsany tucne je presne to, co patri do STORAGE_NAME
  v sender.lua, kdyby automaticky vyber sahl po spatnem bloku.
----------------------------------------------------------------------]]

local function num(dev, m)
  if not (dev and dev[m]) then return nil end
  local ok, v = pcall(dev[m])
  if ok then return tonumber(v) end
  return nil
end

local function callv(dev, m)
  if not (dev and dev[m]) then return nil end
  local ok, v = pcall(dev[m])
  if ok then return v end
  return nil
end

local function fmt(v)
  if not v then return "?" end
  local a = math.abs(v)
  if a >= 1e9 then return string.format("%.2fG", v / 1e9) end
  if a >= 1e6 then return string.format("%.2fM", v / 1e6) end
  if a >= 1e3 then return string.format("%.2fk", v / 1e3) end
  return tostring(math.floor(v))
end

-- presna hodnota s mezerami po tisicich, aby byl videt i maly pohyb
local function exact(v)
  if not v then return "?" end
  local s = string.format("%.0f", math.abs(v))
  while true do
    local k
    s, k = s:gsub("^(%d+)(%d%d%d)", "%1 %2")
    if k == 0 then break end
  end
  return (v < 0 and "-" or "") .. s
end

local names = peripheral.getNames()

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.white)
print("Nalezeno periferii: " .. #names)
print("")

if #names == 0 then
  term.setTextColor(colors.red)
  print("Nic. Bloky musi bud primo prilehat")
  print("k pocitaci, nebo byt na spolecne siti")
  print("pres wired modem + Networking Cable")
  print("(a modem musi byt zapnuty pravym kl.)")
  return
end

local energyFound, storageFound = 0, 0
local watchDev, watchName, watchCap = nil, nil, 0

for _, name in ipairs(names) do
  local ptype = peripheral.getType(name)
  local ok, dev = pcall(peripheral.wrap, name)
  if not ok then dev = nil end

  term.setTextColor(colors.white)
  textutils.pagedPrint(name)

  term.setTextColor(colors.gray)
  textutils.pagedPrint("  typ: " .. tostring(ptype))

  -- u modemu je nejdulezitejsi, co vidi na kabelove siti
  if ptype == "modem" then
    if callv(dev, "isWireless") then
      term.setTextColor(colors.cyan)
      textutils.pagedPrint("  bezdratovy - pro rednet")
    else
      local remotes = callv(dev, "getNamesRemote")
      if type(remotes) ~= "table" then
        term.setTextColor(colors.gray)
        textutils.pagedPrint("  kabelovy, bez site")
      elseif #remotes == 0 then
        term.setTextColor(colors.red)
        textutils.pagedPrint("  kabelovy: SIT JE PRAZDNA")
        textutils.pagedPrint("  -> druhy modem neni zapnuty")
        textutils.pagedPrint("     nebo nic nechytil")
      else
        term.setTextColor(colors.green)
        textutils.pagedPrint("  kabelovy: " .. #remotes .. " na siti")
        for _, rn in ipairs(remotes) do
          textutils.pagedPrint("    - " .. rn ..
            "  (" .. tostring(peripheral.getType(rn)) .. ")")
        end
      end
    end
  end

  local rate   = num(dev, "getTransferRate")
  local stored = num(dev, "getEnergy")
  local cap    = num(dev, "getEnergyCapacity")   -- CC generic -> FE
  local maxE   = num(dev, "getMaxEnergy")        -- nativni integrace modu

  if rate then
    energyFound = energyFound + 1
    term.setTextColor(colors.yellow)
    textutils.pagedPrint("  TOK: " .. fmt(rate) .. " FE/t")
  end

  if stored then
    storageFound = storageFound + 1
    term.setTextColor(colors.green)
    textutils.pagedPrint("  ZASOBA: " .. fmt(stored) .. " / " ..
      fmt(cap or maxE) .. (cap and " FE" or " (jednotka dle modu)"))
    term.setTextColor(colors.gray)
    textutils.pagedPrint("  presne: " .. exact(stored))

    -- syrove navratove hodnoty vcetne typu - odhali, kdyby mod
    -- vracel retezec nebo neco jineho nez cislo
    for _, m in ipairs({ "getEnergy", "getEnergyCapacity",
                         "getMaxEnergy", "getEnergyFilledPercentage" }) do
      local raw = callv(dev, m)
      if raw ~= nil then
        textutils.pagedPrint("   " .. m .. " = " ..
          tostring(raw) .. " (" .. type(raw) .. ")")
      end
    end

    local c = cap or maxE or 0
    if c > watchCap then watchDev, watchName, watchCap = dev, name, c end
  end
end

print("")
term.setTextColor(colors.lightGray)
print("Detektoru toku: " .. energyFound ..
      "   zasobniku: " .. storageFound)
term.setTextColor(colors.gray)
print("Zasobnik s nejvetsi kapacitou vyhraje")
print("automaticky vyber v sender.lua.")

-- Rozhodujici test: hybe se ta hodnota vubec?
if watchDev then
  print("")
  term.setTextColor(colors.white)
  print("Merim zmenu na " .. tostring(watchName) .. " (5 s)...")
  local a = num(watchDev, "getEnergy")
  sleep(5)
  local b = num(watchDev, "getEnergy")

  if not (a and b) then
    term.setTextColor(colors.red)
    print("Nepodarilo se precist hodnotu.")
  else
    local d = b - a
    term.setTextColor(colors.lightGray)
    print("pred:  " .. exact(a))
    print("po:    " .. exact(b))
    if d == 0 then
      term.setTextColor(colors.red)
      print("zmena: ZADNA -> hodnota stoji")
    else
      term.setTextColor(colors.green)
      print("zmena: " .. exact(d) .. " za 5 s")
      term.setTextColor(colors.gray)
      print(string.format("to je %.6f %% kapacity", math.abs(d) / watchCap * 100))
    end
  end
end

term.setTextColor(colors.white)
