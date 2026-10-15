-- The cartridge shelf. MekkaBoy ships with no games. Each game is its own
-- small addon, a "cartridge" (a folder named MekkaBoy_Cart_<id>), written by
-- Tools/rom2lua.py from a ROM you own. A cartridge is only read into memory
-- when you put it in the console, so games you are not playing cost nothing.
local _, MB = ...

local Carts = {}
MB.Carts = Carts

local roms = {}        -- id -> { id, name, numBanks, cgb, banks }, once a cartridge has been read
local shelf = nil      -- sorted list of { id, name, addon }

-- What cartridge addons call. (They are separate addons, so they reach
-- MekkaBoy through this one global.)
MekkaBoy = {}

-- A cartridge's first file announces it and gets back the table its other
-- files put the game's data into.
function MekkaBoy.NewCartridge(info)
    if type(info) ~= "table" or type(info.id) ~= "string" or type(info.numBanks) ~= "number" then return nil end
    local rom = { id = info.id, name = info.name or info.id, numBanks = info.numBanks, cgb = info.cgb, banks = {},
                  system = info.system, size = info.size, chip = info.chip }
    roms[info.id] = rom
    shelf = nil
    return rom.banks
end

-- A native cartridge: a game or tool written in Lua that the console hosts in its shell instead of emulating
-- (see GB/Native.lua for what the module may do). The module's start/stop/key/tick are called by the console.
function MekkaBoy.NativeCartridge(id, module)
    if type(id) ~= "string" or type(module) ~= "table" or type(module.start) ~= "function" then return nil end
    roms[id] = { id = id, name = module.name or id, numBanks = 0, banks = {}, system = "native", module = module }
    shelf = nil
    return true
end

-- A cartridge's soundtrack pack (see GB/Sound.lua).
function MekkaBoy.SoundPack(id, pack)
    MB.SoundPacks = MB.SoundPacks or {}
    if type(id) == "string" and type(pack) == "table" then MB.SoundPacks[id] = pack end
end

local A = C_AddOns or {}
local GetNumAddOns = A.GetNumAddOns or GetNumAddOns
local GetAddOnInfo = A.GetAddOnInfo or GetAddOnInfo
local GetAddOnMetadata = A.GetAddOnMetadata or GetAddOnMetadata
local LoadAddOn = A.LoadAddOn or LoadAddOn
local EnableAddOn = A.EnableAddOn or EnableAddOn

local function complete(rom)
    if not rom then return false end
    for i = 1, rom.numBanks do
        if type(rom.banks[i]) ~= "string" then return false end
    end
    return true
end

-- every cartridge installed, in name order: { { id =, name =, addon =, system = }, ... }
-- (system is "gba" for a Game Boy Advance cartridge, "native" for a Lua one, and nil for the Game Boy ones)
function Carts.List()
    if shelf then return shelf end
    local list, seen = {}, {}
    if GetNumAddOns and GetAddOnInfo and GetAddOnMetadata then
        for i = 1, GetNumAddOns() do
            local ok, id = pcall(GetAddOnMetadata, i, "X-MekkaBoy-Cart")
            if ok and type(id) == "string" and id ~= "" and not seen[id] then
                seen[id] = true
                local _, name = pcall(GetAddOnMetadata, i, "X-MekkaBoy-Name")
                local _, system = pcall(GetAddOnMetadata, i, "X-MekkaBoy-System")
                local _, code = pcall(GetAddOnMetadata, i, "X-MekkaBoy-Code")    -- (which game it is, for the list of tried games)
                list[#list + 1] = { id = id, addon = (GetAddOnInfo(i)), system = (system == "gba" or system == "native") and system or nil,
                                    name = (type(name) == "string" and name ~= "") and name or id,
                                    code = (type(code) == "string" and code ~= "") and code or nil }
            end
        end
    end
    if MB.Import then                -- games pasted in with /mb import (a cartridge folder for the same game wins: it can have sound)
        for id, e in pairs(MB.Import.List()) do
            if not seen[id] then
                seen[id] = true
                list[#list + 1] = { id = id, name = e.name, pasted = true }
            end
        end
    end
    for id, rom in pairs(roms) do   -- anything already in memory that the list above did not name
        if not seen[id] then list[#list + 1] = { id = id, name = rom.name, system = rom.system } end
    end
    table.sort(list, function(a, b)
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    shelf = list
    return list
end

-- a game already in memory, or nil (nothing is read from disk for this)
function Carts.Peek(id) return roms[id] end

function Carts.Find(id)
    for _, c in ipairs(Carts.List()) do
        if c.id == id then return c end
    end
    return nil
end
function Carts.ListAdvance()
    local t = {}
    for _, c in ipairs(Carts.List()) do
        if c.system == "gba" then t[#t + 1] = c end
    end
    return t
end

-- Read a cartridge into memory. Returns its ROM, or nil and why not.
local opened = {}      -- cartridge folders already read this session

function Carts.Load(id)
    local c = Carts.Find(id)
    if not c then
        if complete(roms[id]) then return roms[id] end
        return nil, "There is no such cartridge."
    end
    -- A cartridge folder is always read, even when the same game is already
    -- in memory from a paste: the folder is what carries the sound.
    if c.addon and LoadAddOn and not opened[c.addon] then
        local ok, reason = LoadAddOn(c.addon)
        if not ok and reason == "DISABLED" and EnableAddOn then
            EnableAddOn(c.addon)
            ok, reason = LoadAddOn(c.addon)
        end
        if ok then
            opened[c.addon] = true
        elseif not roms[id] then
            return nil, ("The cartridge would not load (%s). Check that %s is enabled in the AddOns list."):format(tostring(reason), c.addon)
        end
    end
    if complete(roms[id]) then return roms[id] end
    if c.pasted then
        local banks, why = MB.Import.Load(id)
        if not banks then return nil, why end
        local e = MB.Import.List()[id]
        Carts.Adopt(id, e.name, e.numBanks, e.cgb, banks)
        return roms[id]
    end
    return nil, "The cartridge is damaged: some of its files are missing. Run Tools/rom2lua.py on the game again."
end

-- Saved settings (which list the pasted games) arrive after this file has run.
MB.onLogin[#MB.onLogin + 1] = function() shelf = nil end

-- a game that arrived some other way than a cartridge folder (see GB/Import.lua)
function Carts.Adopt(id, name, numBanks, cgb, banks)
    if complete(roms[id]) then return end        -- already here, and the same game by definition
    roms[id] = { id = id, name = name, numBanks = numBanks, cgb = cgb, banks = banks }
    shelf = nil
end

function Carts.Forget(id)
    local c = Carts.Find(id)
    if c and c.addon then return end             -- a cartridge folder's game stays
    roms[id] = nil
    shelf = nil
end
