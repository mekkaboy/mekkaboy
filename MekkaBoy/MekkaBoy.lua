-- MekkaBoy: a Game Boy Color, as a gnome would build one, for your flight paths.
-- This file: saved settings, chat output and the slash-command table. The
-- window is UI/Body.lua, the flight logic Session.lua, the emulator GB/.
local addonName, MB = ...

-- The version (the same number as in MekkaBoy.toc) and the link's protocol:
-- two MekkaBoys tell each other both when they share a group (Hello.lua).
-- PROTOCOL only changes when the link's messages change in a way an older
-- copy could not follow; that, not the version, is what stops two from linking.
MB.VERSION = "0.21.0-beta"
MB.PROTOCOL = 1
-- "stable" (the Release on CurseForge) or "alpha" (the testers' build, and this source tree): a stable build leaves out
-- what has not been proven with real players yet (dev/make_release.py --channel sets it; see MB.Alpha's callers)
MB.CHANNEL = "alpha"
function MB.Alpha() return MB.CHANNEL ~= "stable" end

-- Saved settings. Always fetched through DB(): the game replaces the global
-- with the saved copy after these files have run, so nothing may hold on to it.
local function DB()
    MekkaBoyDB = MekkaBoyDB or {}
    local db = MekkaBoyDB
    db.gb = db.gb or {}             -- battery saves, per game
    db.states = db.states or {}     -- save states, per game
    db.cheats = db.cheats or {}     -- cheat codes, per game
    db.flights = db.flights or {}   -- learned flight times, "From > To" = seconds
    db.opt = db.opt or {}           -- settings
    return db
end
MB.DB = DB

-- Where games keep their saves: your own (the settings themselves), or, with /mb testsave on, a
-- separate set of practice saves that never touches yours. Returns a table with .gb, .states, .gba.
function MB.Saves()
    local db = DB()
    -- (a build without the practice saves, after a QA kit that had them: back to your own saves, since there is no
    -- /mb testsave here to switch them off)
    if db.testSaves and not MB.TestSaves then db.testSaves = nil end
    if db.testSaves then
        db.test = db.test or {}
        local t = db.test
        t.gb, t.states, t.gba = t.gb or {}, t.states or {}, t.gba or {}
        return t
    end
    db.gba = db.gba or {}
    return db
end

-- Each game's battery save counts how many times it has been kept. A resume point remembers the count it was made at,
-- and is used only while the save is still that one: a save kept later (with resume turned off, say) is newer
-- progress than the resume point, so the save wins. (Resume points from before 0.20.2 carry no count and load as before.)
function MB.BatteryRev(key)
    local s = MB.Saves()
    return s.rev and s.rev[key] or 0
end
function MB.BatteryKept(key)
    local s = MB.Saves()
    s.rev = s.rev or {}
    s.rev[key] = (s.rev[key] or 0) + 1
end

-- ---- our own games: the realm's clock, and one save per character ----
-- MekkaLabs' own cartridges (the ones whose game code starts "MB", games/gba/build_all.py) include games that run on
-- real time. They read the realm's clock as the server keeps it, so moving the computer's clock moves nothing, and
-- they keep one save for each character: a character lives on one realm, while one save played on realms in other
-- time zones would see its clock jump about. A game made from a ROM you own keeps one save for the whole account and
-- reads the computer's clock, as it always has.
local floor = math.floor
function MB.IsOurs(rom)
    local b = rom and rom.system == "gba" and rom.banks and rom.banks[1]
    return type(b) == "string" and b:sub(0xAD, 0xAE) == "MB"
end
-- the same, for a cartridge on the shelf that has not been read yet (its folder's label carries the game code)
local function oursById(id)
    local rom = MB.Carts and MB.Carts.Peek and MB.Carts.Peek(id)
    if rom and rom.banks and rom.banks[1] then return MB.IsOurs(rom) end
    local c = MB.Carts and MB.Carts.Find and MB.Carts.Find(id)
    return c ~= nil and c.system == "gba" and type(c.code) == "string" and c.code:sub(1, 2) == "MB"
end
-- who is playing: the character's lasting id (it survives a rename), worked out once a session
local who
function MB.Who()
    if who then return who end
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) == "string" and guid ~= "" then who = guid return who end
    local name = UnitName and UnitName("player")
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
    local fallback = (name and realm and realm ~= "") and (name .. "-" .. realm) or "nobody"
    if not UnitGUID then who = fallback end            -- (a client without character ids: name and realm, for good)
    return fallback                                    -- (too early for the id: not remembered, asked again next time)
end
-- the character's name, for messages and for a save's label
function MB.WhoName()
    local name = UnitName and UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if not name then return "this character" end
    return (realm and realm ~= "") and (name .. " of " .. realm) or name
end
-- the key a game's saves, memory valves and resume point are kept under: the game itself, or for one of ours the
-- game and the character ("CRITTERCRATE@Player-1234-0A1B2C3D")
function MB.SaveKey(id, rom)
    if not id then return nil end
    local ours
    if rom then ours = MB.IsOurs(rom) else ours = oursById(id) end
    if not ours then return id end
    return id .. "@" .. MB.Who()
end
-- From before saves moved to characters, one of our games may have a save kept for the whole account. The first
-- character to open that game takes it (and its memory valves and resume point, MB.ClaimStates); every other
-- character starts afresh. Returns true when it moved.
function MB.ClaimSave(saves, id, key)
    if key == id or saves.gba[key] ~= nil or not saves.gba[id] then return false end
    saves.gba[key], saves.gba[id] = saves.gba[id], nil
    local db = MB.DB()
    db.claimed = db.claimed or {}
    db.claimed[(db.testSaves and "practice " or "") .. id] = key
    local c = MB.Carts and MB.Carts.Find and MB.Carts.Find(id)
    MB.Print(("%s: the save you had now belongs to %s. Each character keeps a game of its own from now on, on the realm's clock."):format(c and c.name or id, MB.WhoName()))
    return true
end
-- store: where valves are kept; prefix: how that store names practice valves; claimPrefix: which claim record applies
function MB.ClaimStates(store, prefix, key, claimPrefix)
    local id = type(key) == "string" and key:match("^(.-)@")
    local db = MB.DB()
    if not id or not db.claimed or db.claimed[(claimPrefix or prefix) .. id] ~= key then return end
    local mine, old = store[prefix .. key], store[prefix .. id]
    if old ~= nil and (mine == nil or next(mine) == nil) then store[prefix .. key], store[prefix .. id] = old, nil end
end

-- The realm's clock, as a table the way date("*t") gives one: universal time from the server (GetServerTime, which the
-- computer's clock does not move), shifted into the realm's time zone. The server says what time it is on the realm
-- through the calendar, which keeps realm time; that, less universal time, is the realm's offset (to the nearest
-- quarter hour, worked out again once a minute so that summer time comes and goes with the realm's).
local function days(y, m, d)                         -- days from 1970-01-01 to a date
    if m <= 2 then y = y - 1 end
    local era = floor(y / 400)
    local yoe = y - era * 400
    local doy = floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy - 719468
end
local zone, zoneAt, zoneFrom = nil, nil, "none"
local function quarter(off) return floor(off / 900 + 0.5) * 900 end          -- time zones come in quarter hours
local function sane(off) return type(off) == "number" and off <= 14 * 3600 and off >= -12 * 3600 end
local function realmOffset(utc)
    if zone and zoneAt and utc >= zoneAt and utc - zoneAt < 60 then return zone end
    local D = C_DateAndTime
    -- the realm's time of day as the game's own clock gives it: the other sources must agree with it
    local gt
    if GetGameTime then
        local h, m = GetGameTime()
        local u = date("!*t", utc)
        if type(h) == "number" and type(m) == "number" and type(u) == "table" then
            gt = quarter(((h * 60 + m) - (u.hour * 60 + u.min)) * 60)
            if gt > 14 * 3600 then gt = gt - 86400 elseif gt < -12 * 3600 then gt = gt + 86400 end
        end
    end
    local function agrees(o) return gt == nil or (o - gt) % 86400 == 0 end
    local off, from
    local ok, cal = pcall(function() return D and D.GetCurrentCalendarTime and D.GetCurrentCalendarTime() end)
    if ok and type(cal) == "table" and type(cal.year) == "number" and cal.month and cal.monthDay and cal.hour and cal.minute then
        local o = quarter(days(cal.year, cal.month, cal.monthDay) * 86400 + cal.hour * 3600 + cal.minute * 60 - utc)
        if sane(o) and agrees(o) then off, from = o, "the calendar" end
    end
    if not off then
        local ok2, l = pcall(function() return D and D.GetServerTimeLocal and D.GetServerTimeLocal() end)
        if ok2 and type(l) == "number" then
            local o = quarter(l - utc)
            if sane(o) and agrees(o) then off, from = o, "the server's local time" end
        end
    end
    if not off and sane(gt) then off, from = gt, "the game clock" end
    if not off then                                  -- last: your computer's time zone, still on the server's time
        local l, u = date("*t", utc), date("!*t", utc)
        if type(l) == "table" and type(u) == "table" and l.year and u.year then
            local o = quarter((days(l.year, l.month, l.day) - days(u.year, u.month, u.day)) * 86400 + (l.hour - u.hour) * 3600 + (l.min - u.min) * 60)
            if sane(o) then off, from = o, "your computer's time zone" end
        end
    end
    zone, zoneAt, zoneFrom = off or zone or 0, utc, from or zoneFrom
    return zone
end
function MB.RealmClock()
    local utc = GetServerTime and GetServerTime()
    if type(utc) ~= "number" or utc < 1e9 then return date("*t"), false end    -- (no server time in this client: the computer's clock)
    return date("!*t", utc + realmOffset(utc)), true
end

function MB.Opt(name, default)
    local v = DB().opt[name]
    if v == nil then return default end
    return v
end

-- How I play: one setting for everything MekkaBoy tells other players (the friends list, Friends.lua; Together
-- Mode, GBA/Ghosts.lua).
--   open     anyone who targets you (or shares your group or guild) sees that you have MekkaBoy and what you play;
--            Together shares with the friends you add (and, once it ships, with the realm)
--   friends  only people you know: your group, friends list, guild and past link partners; Together with added friends
--   solo     nobody is told and nobody is asked; Together is off
-- (0.20.3 test builds kept this as opt.presence = everyone / known / off: read as open / friends / solo)
local PLAY_FROM_PRESENCE = { everyone = "open", known = "friends", off = "solo" }
function MB.PlayMode()
    local o = MB.DB().opt
    local v = o.play
    if v == "open" or v == "friends" or v == "solo" then return v end
    return PLAY_FROM_PRESENCE[o.presence] or "open"
end
function MB.SetPlayMode(v)
    if v ~= "open" and v ~= "friends" and v ~= "solo" then return false end
    local o = MB.DB().opt
    o.play, o.presence = v, nil
    if MB.Friends and MB.Friends.Changed then pcall(MB.Friends.Changed) end
    if MB.Ghosts and MB.Ghosts.PlayModeChanged then pcall(MB.Ghosts.PlayModeChanged) end
    return true
end
MB.PLAY_WORDS = { open = "Open", friends = "Friends only", solo = "Solo" }
MB.PLAY_LINES = {
    open = "Open: anyone who targets you, and your group and guild, can see that you have MekkaBoy and what you are playing.",
    friends = "Friends only: just your group, friends list, guild and the players you have linked with can see that you have MekkaBoy.",
    solo = "Solo: nobody is told that you have MekkaBoy, nobody is asked, and Together is off.",
}

-- Where the Workshop page lives: the page that turns a game you own into a
-- code to paste (/mb setup shows this address). "" = point at the copy of
-- the page that ships in this folder, Workshop.html.
MB.WORKSHOP_URL = ""

local PREFIX = "|cffe6b450MekkaBoy:|r "
function MB.Print(msg) print(PREFIX .. msg) end

-- MB.AddCommand(name, help line, function(rest of the command) ... end)
MB.commands = {}
MB.commandOrder = {}
function MB.AddCommand(name, help, run)
    MB.commands[name] = { run = run, help = help }
    if help ~= "" then MB.commandOrder[#MB.commandOrder + 1] = name end
end

-- /mb clock: the time our own games go by, beside the computer's (for anyone wondering why a pet is asleep)
MB.AddCommand("clock", "clock - the realm time our own games run on (from the server), beside your computer's", function()
    local r, server = MB.RealmClock()
    local pc = date("*t")
    if not server then
        MB.Print(("This game client gives no server time, so our games use your computer's clock: %02d:%02d."):format(pc.hour, pc.min))
        return
    end
    local off = (zone or 0) / 3600
    MB.Print(("Our games: %04d-%02d-%02d %02d:%02d, the realm's time (universal time %+g h, from %s). Your computer: %02d:%02d."):format(
        r.year, r.month, r.day, r.hour, r.min, off, zoneFrom, pc.hour, pc.min))
end)

-- Things to do once saved settings have arrived (PLAYER_LOGIN).
MB.onLogin = {}
