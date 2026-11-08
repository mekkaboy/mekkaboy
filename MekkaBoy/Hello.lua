-- MekkaBoys tell each other which version they are, so nobody stays on an old copy without knowing.
-- Whoever is behind gets one line saying so, in their own chat window, with where to get the update; nobody else
-- hears a thing. The link itself is only refused when the two speak different link protocols (MB.PROTOCOL), which is
-- rarer than a version change.
--
-- Where (0.22.2): a party or raid, as before (both sides say who they are, whenever the group grows); and, once a
-- session each, the guild and Together's hidden realm channel ("MekkaBoyTogether", GBA/Ghosts.lua). Friends.lua's
-- "who has MekkaBoy" answers carry a version too, and are checked the same way (Hello.Seen). Solo (How I play) says
-- nothing in the guild or on the channel.
--
-- The message rides on the link's own hidden line (GB/Link.lua), kind "V":
--   V000<version>;<protocol>;q     "this is me; who are you?"   (in a group only)
--   V000<version>;<protocol>;a     "this is me" (an answer: nobody answers an answer)
-- In the guild and on the channel only "a" goes out. Copies from before 0.22.2 hear it, say they are behind when they
-- are, and stay quiet. A 0.22.2 copy that hears an older one there answers with its own "a" a few seconds later, unless
-- someone at least as new has spoken there in the meantime: the older copy hears about the update from one player,
-- not from the whole guild.
-- Copies from before this file existed ignore it, and are taken to speak protocol 1.
local _, MB = ...

local Hello = {}
MB.Hello = Hello
local Print = MB.Print

Hello.WHERE = "mekkaboy.com"       -- where to get MekkaBoy: said with every "newer version" line
local REALM_CHANNEL = "MekkaBoyTogether"   -- Together's hidden channel (GBA/Ghosts.lua)
local LANE = 5                     -- the guild and the channel go out on the extra addon name (GB/Link.lua)
local ANNOUNCE_AFTER, ANNOUNCE_SPREAD = 20, 20   -- the guild hears from us 20 to 40 s after logging in
local CHANNEL_LOOK = 60            -- seconds between looks for Together's channel, until we have spoken on it
local REPLY_MIN, REPLY_SPREAD = 3, 12            -- an answer to an older copy waits 3 to 15 s ...
local REPLY_GAP = 300              -- ... and goes out at most once in five minutes in each place

local peers = {}            -- plain name -> { name =, version =, protocol =, at = }   (group and whispers)
local toldNewer = {}        -- versions we have already been told about this session
local toldCannot = {}       -- plain name -> when we last said "cannot link"
local lastAsk, lastAnswer, lastCount = -100, -100, 0
local announced = {}        -- "GUILD" / "CHANNEL" -> true once we have said who we are there this session
local replyAt = {}          -- place -> when we last answered an older copy there
local waiting = {}          -- place -> true while an answer waits to go out
local coveredAt = {}        -- place -> when someone at least as new as us last spoke there

local function plain(name) return MB.Link.Plain(name) end
local function short(name) return (tostring(name):gsub("%-[^%-]*$", "")) end
local function after(seconds, f)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, f) else f() end
end

-- "0.14.2-dev" -> { 0, 14, 2 }
local function numbers(version)
    local t = {}
    for n in tostring(version):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
-- is version a newer than version b?
function Hello.Newer(a, b)
    local x, y = numbers(a), numbers(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- someone has this version: one line if it is newer than ours (once a version, a session)
function Hello.Seen(version, sender)
    if type(version) ~= "string" or #version > 24 or not version:match("^[%w%.%-]+$") then return end
    if Hello.Newer(version, MB.VERSION) and not toldNewer[version] then
        toldNewer[version] = true
        Print(("%s has a newer MekkaBoy (%s; yours is %s). Get the update at %s."):format(short(sender), version, MB.VERSION, Hello.WHERE))
    end
end

local function channel()
    if not (IsInGroup and IsInGroup()) then return nil end
    if IsInRaid and IsInRaid() then return "RAID" end
    return "PARTY"
end

local function line(kind) return ("V000%s;%d;%s"):format(MB.VERSION, MB.PROTOCOL, kind) end
local function say(kind)
    local ch = channel()
    if not (ch and MB.Link and MB.Link.Send) then return end
    MB.Link.Send(line(kind), ch)
end

-- the guild and Together's channel: whether we may speak there, and how to reach it
local function quiet() return MB.PlayMode and MB.PlayMode() == "solo" end
local function reach(where)
    if quiet() or not (MB.Link and MB.Link.Send) then return nil end
    if where == "GUILD" then
        if IsInGuild and IsInGuild() then return "GUILD" end
    elseif where == "CHANNEL" and GetChannelName then
        local n = GetChannelName(REALM_CHANNEL)
        if type(n) == "number" and n > 0 then return "CHANNEL", n end
    end
    return nil
end
local function announce(where)
    if announced[where] then return true end
    local ch, target = reach(where)
    if not ch then return false end
    announced[where] = true
    MB.Link.Send(line("a"), ch, target, LANE)
    return true
end
-- an older copy spoke there: answer once, a little later, unless someone at least as new answers first
local function answerOlder(where)
    if waiting[where] then return end
    local heard = GetTime()
    if heard - (replyAt[where] or -1000) < REPLY_GAP then return end
    waiting[where] = true
    after(REPLY_MIN + math.random() * REPLY_SPREAD, function()
        waiting[where] = false
        if (coveredAt[where] or -1000) >= heard then return end
        local ch, target = reach(where)
        if not ch then return end
        replyAt[where] = GetTime()
        MB.Link.Send(line("a"), ch, target, LANE)
    end)
end

function Hello.Heard(rest, channelName, sender)
    if MB.Link.IsMe(sender) then return end
    local version, protocol, kind = rest:match("^([%w%.%-]+);(%d+);([qa])$")
    if not version or #version > 24 then return end
    if channelName == "GUILD" or channelName == "CHANNEL" then
        if Hello.Newer(MB.VERSION, version) then answerOlder(channelName)
        else coveredAt[channelName] = GetTime() end
        Hello.Seen(version, sender)
        return
    end
    peers[plain(sender)] = { name = sender, version = version, protocol = tonumber(protocol), at = GetTime() }
    if kind == "q" and GetTime() - lastAnswer > 5 then      -- (several people asking at once get one answer between them)
        lastAnswer = GetTime()
        say("a")
    end
    Hello.Seen(version, sender)
end

-- what we know of a group member's MekkaBoy (nil: never heard from it)
function Hello.Peer(name) return peers[plain(name)] end

function Hello.CannotLink(name)
    local p = peers[plain(name)]
    return (p and p.protocol ~= MB.PROTOCOL) and true or false
end
function Hello.SayCannotLink(name)
    local p = peers[plain(name)]
    if not p then return end
    local t = GetTime()
    if toldCannot[plain(name)] and t - toldCannot[plain(name)] < 60 then return end
    toldCannot[plain(name)] = t
    local who = Hello.Newer(p.version, MB.VERSION) and "you need" or (short(name) .. " needs")
    Print(("%s's MekkaBoy (%s) and yours (%s) cannot link with each other: %s the newer version (%s)."):format(short(name), p.version, MB.VERSION, who, Hello.WHERE))
end

-- ask when the group changes (someone new may have MekkaBoy), but never chatter
local pending = false
local function ask()
    pending = false
    if not channel() then lastCount = 0 return end
    local count = GetNumGroupMembers and GetNumGroupMembers() or 2
    local grew = count > lastCount
    lastCount = count
    if not grew and GetTime() - lastAsk < 300 then return end
    if GetTime() - lastAsk < 10 then return end
    lastAsk = GetTime()
    say("q")
end
local function soon()
    if pending then return end
    pending = true
    after(2, ask)
end

-- once a session: the guild a little after logging in; Together's channel whenever we turn out to be on it
local started = false
local function lookForChannel()
    if announce("CHANNEL") then return end
    after(CHANNEL_LOOK, lookForChannel)
end
local function start()
    if started then return end
    started = true
    after(ANNOUNCE_AFTER + math.random() * ANNOUNCE_SPREAD, function() announce("GUILD") end)
    after(CHANNEL_LOOK, lookForChannel)
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GROUP_ROSTER_UPDATE")
pcall(ev.RegisterEvent, ev, "PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event)
    soon()
    if event == "PLAYER_ENTERING_WORLD" then start() end
end)

MB.AddCommand("version", "version - your MekkaBoy's version, and those of the MekkaBoys in your group", function()
    Print(("version %s (link protocol %d). Updates: %s"):format(MB.VERSION, MB.PROTOCOL, Hello.WHERE))
    local any = false
    for _, p in pairs(peers) do
        any = true
        local note = ""
        if p.protocol ~= MB.PROTOCOL then note = " - cannot link with yours"
        elseif Hello.Newer(p.version, MB.VERSION) then note = " - newer than yours"
        elseif Hello.Newer(MB.VERSION, p.version) then note = " - older than yours" end
        print(("  %s: %s%s"):format(short(p.name), p.version, note))
    end
    if not any then print("  No other MekkaBoy has said hello yet. They do when you share a group.") end
    if channel() then lastAsk = GetTime() say("q") end
end)
