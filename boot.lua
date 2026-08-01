---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - zavadec

  Tenhle soubor se na kazdy pocitac uklada jako startup.lua.
  Sam pozna, jestli je hlavni (ma monitor) nebo vzdaleny, stahne
  aktualizace a spusti spravnou aplikaci.

  Pri padu aplikace obnovi zalohu a nabootuje znovu - ale jen jednou,
  aby pocitac neskoncil ve smycce restartu.

  Rezim se da vynutit souborem /.sleepmon_role s obsahem "main"
  nebo "remote".
----------------------------------------------------------------------]]

local RECOVERY = "/.sleepmon_recovery"
local ROLE_FILE = "/.sleepmon_role"
local APP_MAIN, APP_REMOTE = "sleepmon.lua", "sender.lua"

local function openModems()
  local any = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      pcall(rednet.open, name)
      any = true
    end
  end
  return any
end

local function readRole()
  if not fs.exists(ROLE_FILE) then return nil end
  local f = fs.open(ROLE_FILE, "r")
  if not f then return nil end
  local r = (f.readAll() or ""):gsub("%s", "")
  f.close()
  return r ~= "" and r or nil
end

local function say(color, text)
  term.setTextColor(color)
  print(text)
  term.setTextColor(colors.white)
end

--=====================================================================

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
say(colors.white, "SleepMon boot")

local hasModem = openModems()
if not hasModem then
  say(colors.orange, "Zadny modem - bez aktualizaci a logu.")
end

local role = readRole() or (peripheral.find("monitor") and "main" or "remote")
local app = (role == "main") and APP_MAIN or APP_REMOTE
say(colors.lightGray, "Rezim: " .. role .. "  ->  " .. app)

--=====================================================================
-- AKTUALIZACE
--=====================================================================

local upd
if fs.exists("updater.lua") then
  local ok, m = pcall(require, "updater")
  if not ok then
    -- require nemusi byt v ceste, zkusime primo
    local fn = loadfile("updater.lua", nil, _G) or loadfile("updater.lua")
    if fn then ok, m = pcall(fn) end
  end
  if ok and type(m) == "table" then upd = m end
end

if not upd then
  say(colors.orange, "updater.lua chybi - preskakuji update.")
elseif not hasModem and role ~= "main" then
  say(colors.orange, "Bez modemu se update stahnout neda.")
else
  say(colors.lightGray, "Verze: " .. upd.localVersion())
  local ver, err, changed

  if role == "main" then
    if upd.httpAvailable() then
      ver, err, changed = upd.pullGithub()
    else
      err = "HTTP je vypnute v configu CC:Tweaked"
    end
  else
    ver, err, changed = upd.pullRednet(5)
  end

  if err then
    say(colors.red, "Update selhal: " .. tostring(err))
    say(colors.gray, "Pokracuji na stavajici verzi.")
    if hasModem then pcall(upd.log, "warn", "update selhal: " .. tostring(err)) end
  elseif changed then
    say(colors.green, "Nova verze " .. tostring(ver) .. ", restartuji.")
    if hasModem then pcall(upd.log, "info", "aktualizovano na verzi " .. tostring(ver)) end
    sleep(1)
    os.reboot()
  else
    say(colors.lightGray, "Aktualni verze.")
  end
end

--=====================================================================
-- SPUSTENI APLIKACE
--=====================================================================

if not fs.exists(app) then
  say(colors.red, app .. " chybi. Nemam co spustit.")
  return
end

local fn, loadErr = loadfile(app, nil, _G)
if not fn then fn, loadErr = loadfile(app) end

local ok, runErr
if fn then
  ok, runErr = pcall(fn)
else
  ok, runErr = false, loadErr
end

if ok then
  if fs.exists(RECOVERY) then fs.delete(RECOVERY) end
  return
end

--=====================================================================
-- PAD APLIKACE
--=====================================================================

term.setTextColor(colors.red)
print("")
print("Aplikace spadla:")
print(tostring(runErr))
term.setTextColor(colors.white)

if upd then pcall(upd.log, "error", app .. " spadl: " .. tostring(runErr)) end

if fs.exists(RECOVERY) then
  -- uz jsme jednou obnovovali a stejne to spadlo; dal nerestartujeme,
  -- jinak by se pocitac tocil dokola a nesel opravit
  say(colors.orange, "Obnova uz probehla, koncim.")
  say(colors.gray, "Oprav rucne: edit " .. app)
  return
end

local f = fs.open(RECOVERY, "w")
if f then f.write(tostring(os.epoch("utc"))); f.close() end

if upd and upd.restore(app) then
  say(colors.orange, "Obnovena predchozi verze, restartuji.")
  if upd then pcall(upd.log, "warn", "rollback na zalohu " .. app) end
  sleep(2)
  os.reboot()
else
  say(colors.orange, "Zaloha neexistuje, koncim.")
end
