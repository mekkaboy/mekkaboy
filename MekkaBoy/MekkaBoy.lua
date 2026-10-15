-- MekkaBoy: a Game Boy Color, as a gnome would build one, for your flight paths.
-- This file: saved settings, chat output and the slash-command table. The
-- window is UI/Body.lua, the flight logic Session.lua, the emulator GB/.
local addonName, MB = ...

-- The version (the same number as in MekkaBoy.toc) and the link's protocol:
-- two MekkaBoys tell each other both when they share a group (Hello.lua).
-- PROTOCOL only changes when the link's messages change in a way an older
-- copy could not follow; that, not the version, is what stops two from linking.
MB.VERSION = "0.16.0"
MB.PROTOCOL = 1

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
    if db.testSaves then
        db.test = db.test or {}
        local t = db.test
        t.gb, t.states, t.gba = t.gb or {}, t.states or {}, t.gba or {}
        return t
    end
    db.gba = db.gba or {}
    return db
end

function MB.Opt(name, default)
    local v = DB().opt[name]
    if v == nil then return default end
    return v
end

-- Where the Workshop page lives: the page that turns a game you own into a
-- code to paste (/mb setup shows this address). "" = point at the copy of
-- the page that ships in this folder, Workshop.html.
MB.WORKSHOP_URL = "https://workshop.mekkaboy.com"

local PREFIX = "|cffe6b450MekkaBoy:|r "
function MB.Print(msg) print(PREFIX .. msg) end

-- MB.AddCommand(name, help line, function(rest of the command) ... end)
MB.commands = {}
MB.commandOrder = {}
function MB.AddCommand(name, help, run)
    MB.commands[name] = { run = run, help = help }
    if help ~= "" then MB.commandOrder[#MB.commandOrder + 1] = name end
end

-- Things to do once saved settings have arrived (PLAYER_LOGIN).
MB.onLogin = {}
