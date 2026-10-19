-- Native cartridges: a game or tool written in Lua, hosted in the console's shell instead of emulated. The console
-- (GB/Console.lua) is the same for every kind of cartridge; this file is the part particular to a native one: how it
-- is started, what it is lent, how its keys arrive. No dots are drawn for it: the cartridge draws on the screen frame
-- itself with ordinary frames and textures.
--
-- A native cartridge is a folder like any other (MekkaBoy_Cart_<ID>, X-MekkaBoy-System: native) whose Pack.lua says
--
--     MekkaBoy.NativeCartridge("FIELD", { name = "Field",
--         start = function(host) ... end,            -- switched on: build your frames inside host.frame
--         stop  = function() ... end,                -- switched off, ejected, or the console closed
--         key   = function(button, down) ... end,    -- up down left right a b start select l r
--         tick  = function(dt) ... end,              -- once a screen frame while running (optional)
--         save  = function() ... end,                -- hand anything durable to host.db (optional)
--     })
--
-- host: frame (a Frame the size of the screen area, shown while the cartridge runs), db (a table kept in the saved
-- settings under native[id]), print(msg), flash(text) (the status plate), and say(text) (a line on the screen plate
-- while nothing of yours is showing). Nothing a native cartridge does can be a protected action: it sees the same
-- game API as any addon, no more.
local _, MB = ...

local Sys = {
    kind = "native",
    W = 240, H = 160, fps = 60,
    budget = 30, budgetFF = 30, mostOwed = 1,
    pictureMax = 1, pictureMs = 99, pictureOpt = "gbaPicture",
    states = false,           -- no memory valves, no resume point, no rewind: the cartridge keeps its own state
    rewind = false,
    pad = { up = true, down = true, left = true, right = true, a = true, b = true, start = true, select = true, l = true, r = true },
}
MB.NativeSystem = Sys

local function store(id)
    local db = MB.DB()
    db.native = db.native or {}
    db.native[id] = db.native[id] or {}
    return db.native[id]
end

function Sys.new(rom)
    local module = rom.module
    local holder = CreateFrame("Frame", nil, MB.screen)
    holder:SetAllPoints(MB.screen)
    holder:SetFrameLevel(MB.screen:GetFrameLevel() + 5)
    local host = {
        frame = holder,
        db = store(rom.id),
        print = MB.Print,
        flash = function(text) if MB.SetStatus then MB.SetStatus(tostring(text)) end end,
        say = function(text) MB.SetScreenMessage(text) end,
        id = rom.id,
    }
    local m = { native = true, module = module, holder = holder, host = host, changed = false, hasBattery = false }
    function m.setKey(button, down) if module.key then local ok, err = pcall(module.key, button, down and true or false); if not ok then MB.Print("Native cartridge: " .. tostring(err)) end end end
    function m.runFrame() return true end
    function m.releaseAllKeys() if module.key then for b in pairs(Sys.pad) do pcall(module.key, b, false) end end end
    function m.tick(dt) if module.tick then module.tick(dt) end end
    function m.poke() end
    local ok, err = pcall(module.start, host)
    if not ok then holder:Hide(); error("the cartridge would not start: " .. tostring(err)) end
    holder:Show()
    return m
end

function Sys.release(m) m.releaseAllKeys() end
function Sys.keep(m, id, quiet) if m.module.save then pcall(m.module.save) end end
function Sys.away(m, id) Sys.keep(m, id, true) end
function Sys.stop(m)
    if m.module.stop then pcall(m.module.stop) end
    m.holder:Hide()
    m.holder:SetParent(nil)
end
function Sys.color(c) return 0, 0, 0 end
function Sys.pack(st) return st end
function Sys.unpack(st) return st end
function Sys.statesFor() return {} end
