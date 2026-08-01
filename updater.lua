---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - knihovna pro aktualizace a vzdaleny log

  Tok aktualizaci:
      GitHub  --HTTP-->  PC1 (hlavni)  --rednet-->  ostatni pocitace

  Vzdalene pocitace nepotrebuji HTTP, staci jim ender modem. PC1 si
  stahne novou verzi z GitHubu a ostatni si ji vyzadaji od nej.

  Bezpecnost (dulezite u pocitace v jine dimenzi):
    - .lua soubor se zapise, jen kdyz projde load() - odchyti syntaxi
    - puvodni verze zustava jako <soubor>.bak
    - boot.lua po padu aplikace zalohu obnovi a nabootuje znovu
----------------------------------------------------------------------]]

local M = {}

M.PROTO      = "sleepmon_update"
M.LOG_PROTO  = "sleepmon_log"
M.VER_FILE   = "/.sleepmon_version"
M.MANIFEST   = "manifest.json"
M.CHUNK      = 4096          -- rednet posilame po kouscich, ne najednou

-- ZMEN NA SVUJ REPOZITAR
M.repo = { user = "uzivatel", name = "sleepmon", branch = "main" }

local function rawUrl(file)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s")
    :format(M.repo.user, M.repo.name, M.repo.branch, file)
end

--=====================================================================
-- ZAKLADY
--=====================================================================

function M.httpAvailable()
  return http ~= nil
end

function M.fetch(url)
  if not http then return nil, "HTTP je vypnute v configu CC" end
  local ok, res, err = pcall(http.get, url)
  if not ok then return nil, "chyba: " .. tostring(res) end
  if not res then return nil, tostring(err or "nedostupne") end

  local code = res.getResponseCode()
  local body = res.readAll()
  res.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  return body
end

function M.localVersion()
  if not fs.exists(M.VER_FILE) then return 0 end
  local f = fs.open(M.VER_FILE, "r")
  if not f then return 0 end
  local v = tonumber(f.readAll()) or 0
  f.close()
  return v
end

function M.setLocalVersion(v)
  local f = fs.open(M.VER_FILE, "w")
  if f then f.write(tostring(v)); f.close() end
end

-- Zapise soubor jen kdyz je prelozitelny. Puvodni necha jako .bak.
function M.safeWrite(name, content)
  if name:sub(-4) == ".lua" then
    local chunk, err = load(content, "@" .. name)
    if not chunk then return false, "syntakticka chyba: " .. tostring(err) end
  end

  if fs.exists(name) then
    if fs.exists(name .. ".bak") then fs.delete(name .. ".bak") end
    fs.copy(name, name .. ".bak")
  end

  local f = fs.open(name, "w")
  if not f then return false, "nelze zapsat" end
  f.write(content)
  f.close()
  return true
end

function M.restore(name)
  if not fs.exists(name .. ".bak") then return false end
  if fs.exists(name) then fs.delete(name) end
  fs.copy(name .. ".bak", name)
  return true
end

local function readFile(name)
  if not fs.exists(name) then return nil end
  local f = fs.open(name, "r")
  if not f then return nil end
  local c = f.readAll()
  f.close()
  return c
end
M.readFile = readFile

-- seznam souboru z lokalne ulozeneho manifestu
function M.fileList()
  local body = readFile(M.MANIFEST)
  if not body then return {} end
  local ok, m = pcall(textutils.unserialiseJSON, body)
  if not ok or type(m) ~= "table" or type(m.files) ~= "table" then return {} end
  return m.files
end

--=====================================================================
-- LOG NA PC1
--=====================================================================

M.logLocal = nil   -- volitelna funkce pro vypis i u sebe

function M.log(level, text)
  local line = { level = level or "info", text = tostring(text),
                 from = os.getComputerLabel() or ("PC" .. os.getComputerID()),
                 id = os.getComputerID() }
  pcall(rednet.broadcast, line, M.LOG_PROTO)
  if M.logLocal then pcall(M.logLocal, line) end
end

--=====================================================================
-- PC1: STAHOVANI Z GITHUBU
--=====================================================================

-- vraci: verze, chyba, doslo_ke_zmene
function M.pullGithub(force)
  local body, err = M.fetch(rawUrl(M.MANIFEST))
  if not body then return nil, err end

  local ok, m = pcall(textutils.unserialiseJSON, body)
  if not ok or type(m) ~= "table" or not tonumber(m.version) then
    return nil, "manifest.json se neda precist"
  end

  local newVer = tonumber(m.version)
  if not force and newVer <= M.localVersion() then
    return newVer, nil, false
  end

  -- nejdriv stahnout vse, teprve pak zapisovat; pri vypadku v pulce
  -- by jinak zustala smes stare a nove verze
  local staged = {}
  for _, name in ipairs(m.files or {}) do
    local c, e = M.fetch(rawUrl(name))
    if not c then return nil, name .. ": " .. tostring(e) end
    staged[name] = c
  end

  for name, c in pairs(staged) do
    local okw, e = M.safeWrite(name, c)
    if not okw then return nil, name .. ": " .. tostring(e) end
  end

  M.safeWrite(M.MANIFEST, body)
  M.setLocalVersion(newVer)
  return newVer, nil, true
end

--=====================================================================
-- PC1: OBSLUHA POZADAVKU OD OSTATNICH
--=====================================================================

-- Vola se z event smycky aplikace pri rednet_message.
-- Vraci true, kdyz zpravu zpracovala.
function M.serve(id, msg, proto)
  if proto ~= M.PROTO or type(msg) ~= "table" then return false end

  if msg.cmd == "manifest" then
    local files = {}
    for _, n in ipairs(M.fileList()) do
      if fs.exists(n) then files[#files + 1] = n end
    end
    rednet.send(id, { version = M.localVersion(), files = files }, M.PROTO)
    return true
  end

  if msg.cmd == "get" and type(msg.file) == "string" then
    -- pouzivame jen jmena z manifestu, aby sla po siti stahnout
    -- jen ta, co k projektu patri
    local allowed = false
    for _, n in ipairs(M.fileList()) do
      if n == msg.file then allowed = true break end
    end
    local content = allowed and readFile(msg.file) or nil

    if not content then
      rednet.send(id, { file = msg.file, err = "neni k dispozici" }, M.PROTO)
      return true
    end

    local total = math.max(1, math.ceil(#content / M.CHUNK))
    for i = 1, total do
      rednet.send(id, {
        file = msg.file, part = i, total = total,
        data = content:sub((i - 1) * M.CHUNK + 1, i * M.CHUNK),
      }, M.PROTO)
    end
    return true
  end

  return false
end

--=====================================================================
-- OSTATNI: STAZENI OD PC1
--=====================================================================

local function receiveFile(name, timeout)
  local parts, total, have = {}, nil, 0
  while true do
    local _, r = rednet.receive(M.PROTO, timeout or 10)
    if type(r) ~= "table" or r.file ~= name then
      return nil, "prenos se rozpadl"
    end
    if r.err then return nil, r.err end
    if r.part and not parts[r.part] then
      parts[r.part] = r.data
      have = have + 1
    end
    total = r.total
    if total and have >= total then break end
  end
  return table.concat(parts)
end

-- vraci: verze, chyba, doslo_ke_zmene
function M.pullRednet(timeout)
  rednet.broadcast({ cmd = "manifest" }, M.PROTO)

  local id, msg = rednet.receive(M.PROTO, timeout or 5)
  if not id or type(msg) ~= "table" or not tonumber(msg.version) then
    return nil, "PC1 neodpovida"
  end

  local newVer = tonumber(msg.version)
  if newVer <= M.localVersion() then return newVer, nil, false end

  local staged = {}
  for _, name in ipairs(msg.files or {}) do
    rednet.send(id, { cmd = "get", file = name }, M.PROTO)
    local c, e = receiveFile(name)
    if not c then return nil, name .. ": " .. tostring(e) end
    staged[name] = c
  end

  for name, c in pairs(staged) do
    local okw, e = M.safeWrite(name, c)
    if not okw then return nil, name .. ": " .. tostring(e) end
  end

  M.setLocalVersion(newVer)
  return newVer, nil, true
end

return M
