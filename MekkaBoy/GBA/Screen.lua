-- Game Boy Advance games on the console. The console itself (GB/Console.lua)
-- is the same for every kind of cartridge; this file is the part that is
-- particular to the Advance: how its machine is started, where its save and
-- its memory valves go, how its colours are read. EXPERIMENTAL: no rewind yet.
--
-- The game's own saving works: the save is kept with the addon's settings,
-- which WoW writes to disk at logout or /reload. Memory valves (and the
-- point to resume from) are much bigger than a Game Boy's, so they live in a
-- small addon of their own, MekkaBoy_States, read only when an Advance game
-- is played; without that folder they are kept with the settings instead.
local _, MB = ...

local floor = math.floor
local clock = debugprofilestop or function() return GetTime() * 1000 end
local function Print(msg) MB.Print(msg) end

local Sys = {
    kind = "gba",
    W = 240, H = 160, fps = 59.7275,
    budget = 30,              -- most time to spend on frames nobody sees, before the one that is drawn, ms
    budgetFF = 30,
    mostOwed = 5,             -- game frames one screen frame may make up for
    pictureMax = 4,           -- show at least every 4th picture
    pictureMs = 13,
    pictureOpt = "gbaPicture",
    states = true,            -- memory valves and "resume where I left off"
    rewind = false,           -- (a state takes too long to make five times a second)
    pad = { up = true, down = true, left = true, right = true, a = true, b = true, start = true, select = true, l = true, r = true },
}
MB.AdvanceSystem = Sys

-- colours arrive as 15 bits, sometimes with a layer number above them (see the screen painter)
function Sys.colour(c, RC, GC, BC)
    local v = c % 32768
    local r5 = v % 32
    local g5 = floor(v / 32) % 32
    local b5 = floor(v / 1024)
    RC[c], GC[c], BC[c] = r5 / 31, g5 / 31, b5 / 31
    return RC[c]
end

function Sys.release(m)
    for button in pairs(Sys.pad) do m.setKey(button, false) end
end

local lastWrites, savedOnce = -1, false
local quietOnce = false       -- the next save to be kept came out of a memory valve: no need to announce it

-- ---- memory valves ----
local STATES = "MekkaBoy_States"
local A = C_AddOns or {}
local LoadAddOn, EnableAddOn = A.LoadAddOn or LoadAddOn, A.EnableAddOn or EnableAddOn
local triedStates, haveStates = false, false
local function openStates()
    if triedStates then return haveStates end
    triedStates = true
    if not LoadAddOn then return false end
    local ok, reason = LoadAddOn(STATES)
    if not ok and reason == "DISABLED" and EnableAddOn then
        EnableAddOn(STATES)
        ok = LoadAddOn(STATES)
    end
    haveStates = ok and true or false
    return haveStates
end
function Sys.statesFor(key)
    if openStates() then
        MekkaBoyStates = MekkaBoyStates or {}
        local name = (MB.DB().testSaves and "practice " or "") .. key      -- (practice saves keep valves of their own)
        MekkaBoyStates[name] = MekkaBoyStates[name] or {}
        return MekkaBoyStates[name]
    end
    local states = MB.Saves().states
    states[key] = states[key] or {}
    return states[key]
end
-- (the machine's own states are already something a settings file can hold)
function Sys.pack(st) return st end
function Sys.unpack(st) return st end
-- a state has just been put into the machine: the save chip came with it, and is kept without a word
function Sys.loaded(m)
    lastWrites, quietOnce = m.flashWrites, true
end
local startedAt, loadMs, firstFrameMs = 0, 0, 0
local slowest

function Sys.new(rom)
    local t0 = clock()
    local saves = MB.Saves()
    if MB.DB().testSaves and saves.gba[rom.id] == nil and MB.TestSaves then
        -- practice saves are on and this game has not been played with them yet: put the ready-made one in
        saves.gba[rom.id] = MB.TestSaves.For("gba", rom.banks[1]:sub(0xAD, 0xB0)) or false
    end
    local kept = saves.gba[rom.id] or nil
    local m = MB.GBA.new({ bank = function(n) return rom.banks[n + 1] end, size = rom.size or rom.numBanks * 16384, save = kept, chip = rom.chip,
                           clock = function() return date("*t") end })
    pcall(m.runFrame, true)
    firstFrameMs = clock() - t0
    if MB.Tested and MB.Tested.Notice then pcall(MB.Tested.Notice, rom) end      -- (what to expect of this game, said once)
    lastWrites, slowest, startedAt, quietOnce = -1, nil, GetTime(), false
    return m, kept and ("Save from " .. tostring(kept.at or "earlier") .. " is in") or nil
end

-- The game's own save. A game writes its save over a few seconds; once the writing has gone quiet
-- the whole save is copied into the settings, where it stays until the next one.
function Sys.keep(m, id, quiet, say)
    if not m.flashDirty then return end
    local t = m.getSave()
    t.at = date and date("%Y-%m-%d %H:%M") or "?"
    MB.Saves().gba[id] = t
    if quiet or quietOnce then quietOnce = false return end
    if say then say("Save kept") end
    if not savedOnce then
        savedOnce = true
        Print("Save kept. WoW writes it to disk when you log out or /reload, so do one of those before closing the game client.")
    end
end
-- (the console is put away: whatever the game has written so far is kept)
function Sys.away(m, id) Sys.keep(m, id, true) end

-- once a second while the game runs: keep a finished save, and note how the machine is doing
function Sys.second(m, id, now, say)
    if m.flashDirty then
        if m.flashWrites == lastWrites then Sys.keep(m, id, false, say) else lastWrites = m.flashWrites end
    end
    local db = MB.DB()
    local t = { game = id, at = date and date("%Y-%m-%d %H:%M:%S") or "?", speed = now.speed, pictures = now.pictures,
                every = now.every, msDrawn = now.game, msBlind = now.blind, msScreen = now.paint,
                stretches = m.stretches(), firstFrameMs = firstFrameMs, frames = m.frameNo,
                wowFps = GetFramerate and GetFramerate() or 0, memoryKB = collectgarbage("count"),
                idleShare = m.idle / math.max(1, m.cyc), uptime = GetTime() - startedAt }
    -- the slowest second of this sitting is kept too, since that is the one worth looking at afterwards
    if t.uptime > 5 and (not slowest or t.speed < slowest.speed) then
        slowest = {}
        for k, v in pairs(t) do slowest[k] = v end
    end
    t.slowest = slowest
    db.gbaTrial = t
end

-- ----------------------------------------------------------------------------
-- /mb gba: a short way to put an Advance cartridge in. (It used to open a
-- separate trial window; the games now run on the console like any other.)
local Adv = {}
MB.Advance = Adv

local function onConsole()
    local m = MB.Machine and MB.Machine()
    return (m and m.linkPlug) and m or nil       -- (only the Advance machine has that port)
end
function Adv.Machine() return onConsole() end
function Adv.IsOpen() return onConsole() ~= nil and MB.IsRunning() end
function Adv.Close() MB.Hide() end
function Adv.Forget() if onConsole() then MB.EjectGame() end end
function Adv.Open(id)
    if not MB.GBA then Print("The Game Boy Advance part is not loaded: restart the game client.") return end
    local list = MB.Carts.ListAdvance()
    if #list == 0 then Print("No Game Boy Advance cartridges are installed.") return end
    local pick
    for _, c in ipairs(list) do
        if id and id ~= "" and c.id:lower() == id:lower() then pick = c end
    end
    if not pick and (not id or id == "") then
        local m = onConsole()
        if m then MB.Show(false) if MB.OnScreenClick then MB.OnScreenClick() end return end
        if #list == 1 then pick = list[1] end
    end
    if not pick then
        local names = {}
        for _, c in ipairs(list) do names[#names + 1] = c.id:lower() end
        Print(((id and id ~= "") and "No such cartridge. " or "") .. "/mb gba <name> puts one in. You have: " .. table.concat(names, ", "))
        return
    end
    MB.PlayCart(pick.id)
end

MB.AddCommand("gba", "gba <name> - put a Game Boy Advance cartridge in (EXPERIMENTAL; or choose it on the console like any other)", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "off" then Adv.Close() return end
    local every = rest:match("^picture%s+(%d)$")
    if every then MB.DB().opt.gbaPicture = tonumber(every) Print("Picture rate: " .. (every == "0" and "automatic" or ("1 in " .. every))) return end
    Adv.Open(rest)
end)
