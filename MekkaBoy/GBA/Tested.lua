-- Which Game Boy Advance games have been tried, and what to expect of one. The list itself is GBA/TestedList.lua
-- (written by our own test tools); this file reads it for the console: /mb tested, the note in /mb carts, and
-- MB.Tested.For() for anything else that wants to tell the player about a game before it is played.
local _, MB = ...
local T = {}
MB.Tested = T
local Print = MB.Print

-- A game is known by the four-letter code and the version number it carries ("BZME-0"). Returns the list's entry
-- and true when it is for exactly this version; the entry of another version of the same game and false; or nil.
function T.For(key)
    local list = MB.TestedList or {}
    if type(key) ~= "string" then return nil end
    if list[key] then return list[key], true end
    local code = key:match("^(....)%-")
    if code then
        for k, e in pairs(list) do
            if k:sub(1, 4) == code then return e, false end
        end
    end
    return nil
end

-- the same, read out of a game that is in memory (its first 192 bytes hold the code and the version)
function T.KeyOf(rom)
    local head = rom and rom.banks and rom.banks[1]
    if type(head) ~= "string" or #head < 0xBD then return nil end
    return ("%s-%d"):format(head:sub(0xAD, 0xB0), head:byte(0xBD))
end

local STATUS = { played = "played at length", starts = "starts and plays in our tests, not yet played at length", stops = "does not run yet" }
local SHORT = { played = "played at length", starts = "starts in our tests", stops = "does not run yet" }
-- How heavy a game is for the console: 1 (lightest) to 10 (heaviest). From SLOW up we know it runs slow or with
-- few pictures a second, and say so; below that nothing needs saying.
T.SLOW = 6
function T.Weight(e)
    if e.weight then return e.weight end
    local w = math.floor(1 + ((e.cost or 1) - 1) * 3 + 0.5)
    return (w < 1 and 1) or (w > 10 and 10) or w
end
function T.Slow(e) return e.status ~= "stops" and T.Weight(e) >= T.SLOW end
function T.Sound(e)
    if e.sound == "native" then return "music and sounds of its own" end
    if e.sound == "own" then return "silent (it has a music program of its own)" end
    return "sound can be recorded from your own game (Tools/soundpack_gba.py)"
end
-- a few words for a list
function T.Short(key)
    local e, exact = T.For(key)
    if not e then return "not tried by us yet" end
    return SHORT[e.status] .. (T.Slow(e) and ", runs slow" or "") .. (exact and "" or " (another version)")
end
-- everything worth saying, as lines
function T.Lines(key)
    local e, exact = T.For(key)
    if not e then
        return { "This game is not one we have tried. It may play, play with faults, or stop." }
    end
    local lines = { ("%s: %s%s."):format(e.name, STATUS[e.status], exact and "" or " (we tried another version of it)") }
    if e.status ~= "stops" then
        lines[#lines + 1] = ("Weight %d of 10%s. Sound: %s."):format(T.Weight(e), T.Slow(e) and ": a heavy game, expect it to run slow" or "", T.Sound(e))
    elseif e.note then
        lines[#lines + 1] = e.note
    end
    return lines
end

-- The first time a game is switched on (and again if what we know of it has changed since): say what to expect.
-- Nothing for a game that has been played at length and is not a heavy one; that would be noise.
function T.Notice(rom)
    local key = T.KeyOf(rom)
    if not key then return end
    local e, exact = T.For(key)
    local state = e and (e.status .. (exact and "" or "?") .. (T.Slow(e) and "+" or "")) or "untried"
    local db = MB.DB()
    db.told = db.told or {}
    if db.told[key] == state then return end
    db.told[key] = state
    if e and e.status == "played" and exact and not T.Slow(e) then return end
    if not e then
        Print("This is not a game we have tried: it may play, play with faults, or stop. /mb tested lists the ones we have.")
        return
    end
    Print(("%s: %s%s."):format(e.name, STATUS[e.status], exact and "" or " (we tried another version of it)"))
    if e.status == "stops" then
        if e.note then Print(e.note) end
        return
    end
    if T.Slow(e) then Print(("A heavy game (%d of 10): expect it to run slow."):format(T.Weight(e))) end
    if e.sound == "native" then return end
    if e.sound == "own" then Print("No sound: it has a music program of its own.")
    elseif not (MB.SoundPacks and MB.SoundPacks[rom.id]) then Print("Silent until a soundtrack pack is made for it (see the README).") end
end

MB.AddCommand("tested", "tested - the Game Boy Advance games tried so far, and what to expect of them", function()
    local keys = {}
    for k in pairs(MB.TestedList or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return MB.TestedList[a].name < MB.TestedList[b].name end)
    Print(#keys .. " Game Boy Advance games tried so far (any other may play, play with faults, or stop). Weight: how heavy a game is for the console, 1 to 10.")
    for _, k in ipairs(keys) do
        local e = MB.TestedList[k]
        local rest = e.status == "stops" and "" or ((" Weight %d%s. %s"):format(T.Weight(e), T.Slow(e) and ", |cffff8040runs slow|r" or "", e.sound == "native" and "MekkaBoy's own." or e.sound == "own" and "Silent." or "Sound can be recorded."))
        print(("  %s - %s.%s"):format(e.name, SHORT[e.status], rest))
    end
end)
