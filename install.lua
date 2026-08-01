---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - prvni instalace

  Spousti se primo z GitHubu, nic nemusi byt predem na pocitaci:

    wget run https://raw.githubusercontent.com/UZIVATEL/REPO/main/install.lua

  Volitelne se da repozitar predat argumenty:

    ... /install.lua uzivatel repo vetev

  Potrebuje zapnute HTTP. Vzdalene pocitace, ktere HTTP nemaji, se
  nainstaluji rucnim zkopirovanim boot.lua + updater.lua; zbytek si
  uz stahnou po rednetu od PC1.
----------------------------------------------------------------------]]

local args = { ... }

-- ZMEN NA SVUJ REPOZITAR (nebo predej argumenty)
local USER   = args[1] or "uzivatel"
local REPO   = args[2] or "sleepmon"
local BRANCH = args[3] or "main"

local function rawUrl(file)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s")
    :format(USER, REPO, BRANCH, file)
end

local function fetch(url)
  if not http then return nil, "HTTP je vypnute v configu CC:Tweaked" end
  local ok, res, err = pcall(http.get, url)
  if not ok then return nil, tostring(res) end
  if not res then return nil, tostring(err or "nedostupne") end
  local code = res.getResponseCode()
  local body = res.readAll()
  res.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  return body
end

local function write(name, content)
  if name:sub(-4) == ".lua" then
    local chunk, err = load(content, "@" .. name)
    if not chunk then return false, "syntakticka chyba: " .. tostring(err) end
  end
  local f = fs.open(name, "w")
  if not f then return false, "nelze zapsat" end
  f.write(content)
  f.close()
  return true
end

--=====================================================================

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("SleepMon - instalace")
print(USER .. "/" .. REPO .. " (" .. BRANCH .. ")")
print("")

local body, err = fetch(rawUrl("manifest.json"))
if not body then
  printError("manifest.json: " .. tostring(err))
  return
end

local ok, m = pcall(textutils.unserialiseJSON, body)
if not ok or type(m) ~= "table" or type(m.files) ~= "table" then
  printError("manifest.json se neda precist")
  return
end

-- nejdriv stahnout vse, teprve pak zapisovat
local staged = {}
for _, name in ipairs(m.files) do
  local c, e = fetch(rawUrl(name))
  if not c then
    printError(name .. ": " .. tostring(e))
    return
  end
  staged[name] = c
  print("stazeno " .. name)
end

for name, c in pairs(staged) do
  local okw, e = write(name, c)
  if not okw then
    printError(name .. ": " .. tostring(e))
    return
  end
end

write("manifest.json", body)

local f = fs.open("/.sleepmon_version", "w")
if f then f.write(tostring(m.version or 1)); f.close() end

-- boot.lua se spousti pri startu
if fs.exists("startup.lua") then fs.delete("startup.lua") end
fs.copy("boot.lua", "startup.lua")

print("")
term.setTextColor(colors.green)
print("Hotovo, verze " .. tostring(m.version))
term.setTextColor(colors.lightGray)
print("Rezim se pozna sam podle toho, jestli je")
print("pripojeny monitor. Vynutit jde souborem")
print("/.sleepmon_role s obsahem main nebo remote.")
term.setTextColor(colors.white)
print("")
print("Restartuji za 3 s...")
sleep(3)
os.reboot()
