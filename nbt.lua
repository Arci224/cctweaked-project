---@diagnostic disable: undefined-global
--[[--------------------------------------------------------------------
  SleepMon - vypis NBT bloku pres Block Reader

  Zapojeni:
    Block Reader (Advanced Peripherals) musi CELIT zkoumanemu bloku
    (quarry). Cti: predni strana readeru se dotyka quarry.
    Reader pak bud primo prilehá k pocitaci, nebo je na spolecne
    kabelove siti pres wired modem.

  Vypis se zaroven ulozi do /nbt.txt, aby se dal v klidu precist:
    edit /nbt.txt
----------------------------------------------------------------------]]

local OUT = "/nbt.txt"
local MAX_DEPTH = 8

local BR_TYPES = { block_reader = true, blockReader = true }

local function findReader()
  for _, name in ipairs(peripheral.getNames()) do
    if BR_TYPES[peripheral.getType(name)] then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
end

local reader, readerName = findReader()
if not reader then
  printError("Block Reader nenalezen.")
  print("")
  print("Musi byt pripojeny k pocitaci (primo nebo")
  print("pres wired modem) a CELIT zkoumanemu bloku.")
  return
end

local function call(m)
  if not reader[m] then return nil end
  local ok, v = pcall(reader[m])
  if ok then return v end
  return nil
end

--=====================================================================

local lines = {}

local function add(s) lines[#lines + 1] = s end

local function dump(v, indent, key)
  local pad = string.rep(" ", indent)
  local label = key ~= nil and (tostring(key) .. ": ") or ""

  if type(v) ~= "table" then
    add(pad .. label .. tostring(v) .. "  (" .. type(v) .. ")")
    return
  end

  if indent >= MAX_DEPTH * 2 then
    add(pad .. label .. "{...}")
    return
  end

  -- prazdna tabulka
  if next(v) == nil then
    add(pad .. label .. "{}")
    return
  end

  add(pad .. label .. "{")

  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, k in ipairs(keys) do
    dump(v[k], indent + 2, k)
  end
  add(pad .. "}")
end

--=====================================================================

add("Block Reader: " .. tostring(readerName))
add("")

add("getBlockName()    = " .. tostring(call("getBlockName")))
add("isTileEntity()    = " .. tostring(call("isTileEntity")))
add("")

local states = call("getBlockStates")
if states then
  add("getBlockStates():")
  dump(states, 2)
  add("")
end

local data = call("getBlockData")
if data == nil then
  add("getBlockData() = nil")
  add("(blok neni tile entity, nebo reader neceli spravnym smerem)")
else
  add("getBlockData():")
  dump(data, 2)
end

--=====================================================================
-- ulozit
local f = fs.open(OUT, "w")
if f then
  for _, l in ipairs(lines) do f.writeLine(l) end
  f.close()
end

-- vypsat po strankach
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.white)

for _, l in ipairs(lines) do
  textutils.pagedPrint(l)
end

print("")
term.setTextColor(colors.lightGray)
print("Ulozeno do " .. OUT .. " (" .. #lines .. " radku)")
print("Precist: edit " .. OUT)
term.setTextColor(colors.white)
