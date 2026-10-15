-- The link cable, part one: can two MekkaBoys talk at all, and how fast?
-- Addons can send each other hidden messages through the game server. Before
-- building trades and battles on that, /mb ping measures what the line is
-- like on this realm: how long a message takes there and back, whether every
-- byte value arrives intact, and how much can be sent before the server
-- pushes back. The other player only needs MekkaBoy installed; their console
-- answers by itself. The results are also kept with your saved settings.
local _, MB = ...

local Link = {}
MB.Link = Link

local PREFIX = "MekkaBoy"
local LANES = 4             -- the link's frames are shared out over this many addon names (see GB/Wire.lua)
local Print = MB.Print
local C = C_ChatInfo or {}
local SendAddonMessage = C.SendAddonMessage or SendAddonMessage
local RegisterPrefix = C.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix

local PINGS = 10            -- there-and-back timings, one at a time
local BURST = 12            -- messages sent all at once
local STEADY = 40           -- messages sent four a second
local STEADY_GAP = 0.25
local PAYLOAD = 200         -- bytes of filler in the burst and steady messages
local TIMEOUT = 3
local LANE_ROUNDS = 24      -- messages sent on each lane in the lanes test, four a second

-- what a send returned: true or 0 mean "accepted"; anything else is the server's reason
local REASONS = { [1] = "bad prefix", [2] = "bad message", [3] = "throttled", [4] = "bad channel", [5] = "not in a group",
                  [6] = "no target", [7] = "bad channel", [8] = "channel throttled", [9] = "error",
                  [10] = "not in a guild", [11] = "locked down", [12] = "target offline" }

local diag = { events = 0, ours = 0, returns = {} }     -- what the line has shown us so far, for the record
Link.diag = diag

local function laneName(lane) return (lane and lane > 1) and (PREFIX .. lane) or PREFIX end
local function send(text, channel, target, lane)
    if not SendAddonMessage then return "no messaging" end
    local ok, r = pcall(SendAddonMessage, laneName(lane), text, channel, target)
    local seen = tostring(ok and r or ("error: " .. tostring(r)))
    diag.returns[channel .. ":" .. seen] = (diag.returns[channel .. ":" .. seen] or 0) + 1
    if not ok then return "error" end
    if r == true or r == 0 or r == nil then return nil end
    return REASONS[r] or tostring(r)
end

local function now() return GetTime() * 1000 end   -- milliseconds; messages arrive between frames, so finer is no use
Link.Send = send

-- ------------------------------------------------------------ answering ---
-- Messages: a one-letter kind, then a three-character number, then the rest.
--   P ping -> A answer        B every-byte test -> C what arrived
local answered, answerWindow = 0, 0
local test = nil

local function bytesMessage(first, last)
    local t = {}
    for b = first, last do t[#t + 1] = string.char(b) end
    return table.concat(t)
end

-- Names come in several spellings (with a realm, with a space or a hyphen
-- between a two-part name), so compare them with all of that taken out.
local function plain(name) return (name:lower():gsub("[%s%-']", "")) end
local function isMe(sender)
    if not UnitName then return false end
    local me, second = UnitName("player")
    if type(me) ~= "string" or me == "" then return false end
    local s = plain(sender)
    if type(second) == "string" and second ~= "" then
        -- a two-part name: both parts must match (or the sender is given by first name alone)
        local full = plain(me .. second)
        return s == plain(me) or s:sub(1, #full) == full
    end
    return s:sub(1, #plain(me)) == plain(me)
end

-- every way a player's name might have to be written to whisper them
local function spellings(list, name)
    if type(name) ~= "string" or name == "" then return end
    local seen = {}
    for _, v in ipairs(list) do seen[v:lower()] = true end
    for _, v in ipairs({ name, (name:gsub("%s+", "-")), (name:gsub("%s+", "")), (name:gsub("%-", " ")) }) do
        if not seen[v:lower()] then
            seen[v:lower()] = true
            list[#list + 1] = v
        end
    end
end

local function unitSpellings(unit)
    local list = {}
    local a, b = nil, nil
    if UnitFullName then a, b = UnitFullName(unit) end
    if GetUnitName then spellings(list, GetUnitName(unit, true)) end
    if type(a) == "string" and type(b) == "string" and b ~= "" then spellings(list, a .. "-" .. b) end
    spellings(list, a)
    if UnitName then spellings(list, (UnitName(unit))) end
    return list
end

local function nameFacts()
    local f = {}
    if UnitName then f.unitName = { UnitName("player") } end
    if UnitFullName then f.unitFullName = { UnitFullName("player") } end
    if GetUnitName then f.getUnitName = GetUnitName("player", true) end
    if GetRealmName then f.realm = GetRealmName() end
    if GetNormalizedRealmName then f.normalizedRealm = GetNormalizedRealmName() end
    return f
end

local function onMessage(text, channel, sender, lane)
    local kind, id, rest = text:sub(1, 1), text:sub(2, 4), text:sub(5)
    if kind == "V" then                           -- "this is my version" (Hello.lua)
        if MB.Hello and MB.Hello.Heard then MB.Hello.Heard(rest, channel, sender) end
        return
    end
    if kind == "L" or kind == "W" then            -- the link itself (further down)
        if Link.Heard then Link.Heard(text, channel, sender) end
        return
    end
    -- Testing alone: on a shared route (a chat channel, party, guild) we hear
    -- our own messages come back from the server, and time those instead.
    local loop = test and test.loop and kind == "P" and test.loop[id]
    if loop then
        if not loop.back then
            loop.back, loop.sender = now(), sender
            test.heardLoop = true
        end
        return
    end
    if test and test.echo and (kind == "P" or kind == "B") then
        local sent = test.sent[kind .. id]
        if sent and not sent.back then
            sent.back = now()
            test.heard = true
            if kind == "B" then
                local sum = 0
                for i = 1, #rest do sum = (sum + rest:byte(i) * i) % 65521 end
                sent.reply = ("%d,%d"):format(#rest, sum)
            end
        end
        return
    end
    if kind == "P" or kind == "B" then
        -- In a party everyone hears their own messages too: do not answer yourself.
        -- (A whisper to yourself is different: that is how you test the line alone.)
        if channel ~= "WHISPER" and isMe(sender) then return end
        -- answer, but never be made into a firehose by a stranger
        local t = GetTime()
        if t - answerWindow > 10 then answerWindow, answered = t, 0 end
        answered = answered + 1
        if answered > 200 then return end
        local back = (channel == "WHISPER") and "WHISPER" or channel
        if kind == "P" then
            send("A" .. id, back, sender, lane)
        else
            -- say exactly which bytes arrived: count, and a simple sum
            local sum = 0
            for i = 1, #rest do sum = (sum + rest:byte(i) * i) % 65521 end
            send(("C%s%d,%d"):format(id, #rest, sum), back, sender)
        end
    elseif test and (kind == "A" or kind == "C") then
        local sent = test.sent[kind .. id]
        if sent and not sent.back then
            sent.back = now()
            sent.reply = rest
            test.heard = true
            if sent.spelling and not test.whisper then      -- this spelling of the name reaches them
                test.whisper = sent.spelling
                test.sender = sender
            end
        end
    end
end

Link.Plain, Link.IsMe = plain, isMe

-- ---------------------------------------------------------------- test ---
local function mark(kind, n, payload, channel, target, lane)
    local id = ("%03d"):format(n)
    local entry = { at = now() }
    test.sent[(kind == "P" and "A" or "C") .. id] = entry      -- the other player's answer
    test.sent[kind .. id] = entry                               -- or, alone, our own message coming back
    entry.refused = send(kind .. id .. (payload or ""), channel, target, lane)
    return entry
end

local function stats(list)
    local n, sum, lo, hi = 0, 0, nil, nil
    for _, e in ipairs(list) do
        if e.back then
            local ms = e.back - e.at
            n, sum = n + 1, sum + ms
            lo = (not lo or ms < lo) and ms or lo
            hi = (not hi or ms > hi) and ms or hi
        end
    end
    return n, n > 0 and sum / n or nil, lo, hi
end

local function refusals(list)
    local n, why = 0, nil
    for _, e in ipairs(list) do
        if e.refused then n, why = n + 1, e.refused end
    end
    return n, why
end

local function finish()
    local t = test
    test = nil
    local res = { when = date and date("%Y-%m-%d %H:%M") or "", target = t.target, channel = t.channel,
                  tried = t.candidates, worked = t.whisper, sender = t.sender, names = nameFacts() }
    local n, avg, lo, hi = stats(t.pings)
    res.pings = { sent = #t.pings, back = n, avg = avg, min = lo, max = hi }
    if t.loop or t.loopSeen then
        res.loop = {}
        for id, l in pairs(t.loop or t.loopSeen) do
            res.loop[l.channel .. id] = { refused = l.refused, ms = l.back and (l.back - l.at) or nil, sender = l.sender, target = l.target }
        end
    end
    res.diag = { events = diag.events, ours = diag.ours, returns = diag.returns, registered = diag.registered,
                 isRegistered = diag.isRegistered and diag.isRegistered() or nil, lastTypes = diag.lastTypes,
                 heard = t.heardEvents, watching = diag.watching,
                 lockdown = C.InChatMessagingLockdown and C.InChatMessagingLockdown() or false,
                 level = UnitLevel and UnitLevel("player") or nil }
    res.echo = t.echo and t.channel or nil
    if t.chanName and LeaveChannelByName then pcall(LeaveChannelByName, t.chanName) end
    if n == 0 and t.loop and not t.echo then
        Print("Nothing came back: not a whisper to yourself, and not your own messages on any shared route"
            .. " (a chat channel, or party or guild chat if you are in one). This realm may not let addons talk at all,"
            .. " or only between different players. Try /mb ping target on a friend with MekkaBoy.")
        res.failed = "nothing came back"
    elseif n == 0 then
        local _, why = refusals(t.pings)
        Print(("No answer from %s%s. They need MekkaBoy 0.8 or later, and to be online on this realm.%s")
            :format(t.target, why and (" (the server said: " .. why .. ")") or "",
                    t.candidates and (" Tried the name as: " .. table.concat(t.candidates, ", ") .. ".") or ""))
        res.failed = why or "no answer"
    else
        if t.echo then
            Print(("Link test alone, hearing my own messages come back on %s: to the server and back in %d ms on average (%d to %d), %d of %d heard. (Whispers to yourself are not delivered here.)")
                :format(t.routeName, avg, lo, hi, n, #t.pings))
        else
            Print(("Link test with %s: there and back in %d ms on average (%d to %d), %d of %d answered.")
                :format(t.target, avg, lo, hi, n, #t.pings))
        end
        local good, total = 0, 0
        for _, e in ipairs(t.bytes) do
            total = total + 1
            if e.back and e.reply == e.expect then good = good + 1 end
        end
        res.bytes = { sent = total, intact = good }
        Print(good == total and "Every byte value arrived intact."
            or ("Byte test: %d of %d messages arrived intact."):format(good, total))
        local bn, bavg = stats(t.burst)
        local br, bwhy = refusals(t.burst)
        res.burst = { sent = #t.burst, back = bn, refused = br, why = bwhy, avg = bavg }
        Print(("Burst of %d messages at once: %d arrived%s."):format(#t.burst, bn,
            br > 0 and (", %d refused (%s)"):format(br, bwhy) or ""))
        local sn, savg, _, smax = stats(t.steady)
        local sr, swhy = refusals(t.steady)
        res.steady = { sent = #t.steady, back = sn, refused = sr, why = swhy, avg = savg, max = smax,
                       bytesPerSecond = math.floor(sn * (PAYLOAD + 4) / (STEADY * STEADY_GAP)) }
        Print(("Steady stream, four a second for %d seconds: %d of %d arrived%s - about %d bytes a second.")
            :format(STEADY * STEADY_GAP, sn, #t.steady, sr > 0 and (", %d refused (%s)"):format(sr, swhy) or "",
                    res.steady.bytesPerSecond))
        if t.lanes then
            local per, total, sent = {}, 0, 0
            for lane = 1, LANES do
                local n = stats(t.lanes[lane])
                per[lane] = { sent = #t.lanes[lane], back = n, refused = (refusals(t.lanes[lane])) }
                total, sent = total + n, sent + #t.lanes[lane]
            end
            res.lanes = { per = per, back = total, sent = sent, seconds = LANE_ROUNDS * STEADY_GAP }
            local one = per[1].back
            Print(("Four lanes at once for %d seconds: %d of %d arrived (%d on the first lane). %s")
                :format(LANE_ROUNDS * STEADY_GAP, total, sent, one,
                        total >= one * 2.5 and "The server counts each lane by itself: the link can use all four."
                        or "The server counts the lanes together: the link runs at the speed of one."))
        end
    end
    local db = MB.DB()
    db.linkTests = db.linkTests or {}
    table.insert(db.linkTests, res)
    while #db.linkTests > 20 do table.remove(db.linkTests, 1) end
    Link.last = res
end

local runner = CreateFrame("Frame")
runner:SetScript("OnUpdate", function(_, elapsed)
    local t = test
    if not t then return end
    t.clock = t.clock + elapsed
    if t.phase == "probe" then
        -- one ping to every spelling of the name at once; the first to answer is the one to use
        if not t.probed then
            t.probed, t.stamp = true, t.clock
            for i, name in ipairs(t.candidates) do
                local e = mark("P", 900 + i, nil, t.channel, name)
                e.spelling = name
                t.pings[#t.pings + 1] = e
            end
        elseif t.loop and (t.loopRound or 0) < 3 and t.clock >= ({ 1.5, 3.5, 6 })[(t.loopRound or 0) + 1] then
            -- testing alone: also listen for ourselves on the shared routes
            -- (the test channel takes a moment to join, hence the wait and the repeats)
            t.loopRound = (t.loopRound or 0) + 1
            t.looped, t.stamp = (t.loopRound == 3), t.clock
            local routes = {}
            if t.chanName and GetChannelName then
                local n = GetChannelName(t.chanName)
                if type(n) == "number" and n > 0 then routes[#routes + 1] = { "CHANNEL", n, "a chat channel" } end
            end
            if IsInGroup and IsInGroup() then routes[#routes + 1] = { "PARTY", nil, "party chat" } end
            if IsInGuild and IsInGuild() then routes[#routes + 1] = { "GUILD", nil, "guild chat" } end
            for i, r in ipairs(routes) do
                local id = ("%03d"):format(940 + t.loopRound * 10 + i)
                t.loop[id] = { channel = r[1], target = r[2], name = r[3], round = t.loopRound, at = now(), refused = send("P" .. id, r[1], r[2]) }
            end
            -- and once, the "logged" kind of addon message, in case that is the kind this realm delivers
            if t.loopRound == 1 and C.SendAddonMessageLogged then
                for i, name in ipairs(t.candidates) do
                    if i <= 2 then
                        local ok, r = pcall(C.SendAddonMessageLogged, PREFIX, ("P%03d"):format(980 + i), "WHISPER", name)
                        diag.returns["LOGGED:" .. tostring(ok and r or "error")] = (diag.returns["LOGGED:" .. tostring(ok and r or "error")] or 0) + 1
                        t.loop[("%03d"):format(980 + i)] = { channel = "WHISPER", target = name, name = "a logged whisper", at = now() }
                    end
                end
            end
        elseif t.whisper then
            t.pings, t.loop = {}, nil
            t.phase, t.stamp = "ping", t.clock
        elseif t.clock - t.stamp >= TIMEOUT + 1 and (t.looped or not t.loop) then
            local route
            for _, l in pairs(t.loop or {}) do
                if l.back and (not route or l.channel == "CHANNEL") then route = l end
            end
            if route then
                -- no whisper came back, but we can hear ourselves: run the test that way
                t.echo, t.channel, t.whisper, t.routeName = true, route.channel, route.target, route.name
                t.sender = route.sender
                t.loopSeen = t.loop
                t.pings, t.loop, t.heard = {}, nil, false
                t.phase, t.stamp = "ping", t.clock
            else
                finish()
            end
        end
    elseif t.phase == "ping" then
        local cur = t.pings[#t.pings]
        if cur and not cur.back and not cur.refused and t.clock - t.stamp < TIMEOUT then return end
        if #t.pings >= PINGS or (#t.pings >= 3 and not t.heard) then
            if not t.heard then finish() return end
            t.phase, t.stamp = "bytes", t.clock
            -- every byte value an addon message may carry (0 is not allowed), in two messages
            for i, range in ipairs({ { 1, 128 }, { 129, 255 } }) do
                local payload = bytesMessage(range[1], range[2])
                local e = mark("B", 100 + i, payload, t.channel, t.whisper)
                local sum = 0
                for k = 1, #payload do sum = (sum + payload:byte(k) * k) % 65521 end
                e.expect = ("%d,%d"):format(#payload, sum)
                t.bytes[#t.bytes + 1] = e
            end
            return
        end
        t.stamp = t.clock
        t.pings[#t.pings + 1] = mark("P", #t.pings + 1, nil, t.channel, t.whisper)
    elseif t.phase == "bytes" then
        if t.clock - t.stamp < 1.5 then return end
        t.phase, t.stamp = "burst", t.clock
        local filler = ("x"):rep(PAYLOAD)
        for i = 1, BURST do t.burst[i] = mark("P", 200 + i, filler, t.channel, t.whisper) end
    elseif t.phase == "burst" then
        if t.clock - t.stamp < 12 then return end      -- long enough for any allowance to refill
        t.phase, t.stamp, t.next = "steady", t.clock, t.clock
    elseif t.phase == "steady" then
        if #t.steady < STEADY then
            if t.clock >= t.next then
                t.next = t.next + STEADY_GAP
                t.steady[#t.steady + 1] = mark("P", 300 + #t.steady + 1, ("x"):rep(PAYLOAD), t.channel, t.whisper)
                t.stamp = t.clock
            end
        elseif t.clock - t.stamp >= TIMEOUT then
            t.phase, t.stamp = "rest", t.clock
        end
    elseif t.phase == "rest" then
        if t.clock - t.stamp < 12 then return end      -- let every allowance refill
        t.phase, t.stamp, t.next, t.laneRounds = "lanes", t.clock, t.clock, 0
        t.lanes = {}
        for lane = 1, LANES do t.lanes[lane] = {} end
    elseif t.phase == "lanes" then
        -- the same stream again, on every lane at once: does the server count each lane by itself?
        if t.laneRounds < LANE_ROUNDS then
            if t.clock >= t.next then
                t.next = t.next + STEADY_GAP
                t.laneRounds = t.laneRounds + 1
                for lane = 1, LANES do
                    local list = t.lanes[lane]
                    list[#list + 1] = mark("P", 400 + (lane - 1) * LANE_ROUNDS + t.laneRounds, ("x"):rep(PAYLOAD), t.channel, t.whisper, lane)
                end
                t.stamp = t.clock
            end
        elseif t.clock - t.stamp >= TIMEOUT then
            finish()
        end
    end
end)

function Link.Ping(target)
    if test then Print("A link test is already running.") return end
    if not SendAddonMessage then Print("This game client has no addon messaging.") return end
    test = { target = target, channel = "WHISPER", phase = "probe", clock = 0, stamp = 0,
             sent = {}, pings = {}, bytes = {}, burst = {}, steady = {} }
    local word = target:lower()
    if word == "party" then
        test.channel, test.target, test.phase = "PARTY", "your party", "ping"
    elseif word == "me" or word == "self" then
        test.target, test.candidates, test.loop = "yourself", unitSpellings("player"), {}
        if JoinTemporaryChannel then
            test.chanName = "MekkaTest" .. math.random(1000, 9999)
            pcall(JoinTemporaryChannel, test.chanName)
        end
    elseif word == "target" then
        if not (UnitExists and UnitExists("target") and UnitIsPlayer("target")) then
            test = nil
            Print("Target a player first, then /mb ping target.")
            return
        end
        test.candidates = unitSpellings("target")
        test.target = test.candidates[1] or "your target"
    else
        test.candidates = {}
        spellings(test.candidates, target)
    end
    if test.candidates and #test.candidates == 0 then
        test = nil
        Print("Could not work out that player's name.")
        return
    end
    Print(("Testing the link with %s. This takes about a minute."):format(test.target))
end

local OURS = {}             -- addon name -> lane number
for lane = 1, LANES do OURS[laneName(lane)] = lane end
local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
ev:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
    diag.events = diag.events + 1
    local ours = OURS[prefix]
    if ours then
        diag.ours = diag.ours + 1
        diag.lastTypes = type(text) .. "," .. type(channel) .. "," .. type(sender)
    end
    if ours and type(text) == "string" and type(sender) == "string" then
        pcall(onMessage, text, channel, sender, ours)
    end
end)
if RegisterPrefix then
    local ok, r = pcall(RegisterPrefix, PREFIX)
    diag.registered = tostring(ok and r or ("error: " .. tostring(r)))
    for lane = 2, LANES do pcall(RegisterPrefix, laneName(lane)) end
end
if C.IsAddonMessagePrefixRegistered then
    diag.isRegistered = function() return C.IsAddonMessagePrefixRegistered(PREFIX) end
end

-- ------------------------------------------------------------ the link ---
-- Part two of the cable: /mb link joins your MekkaBoy to the other one in
-- your party, so two games can trade and battle. Each game talks to a
-- stand-in for the other player (GB/Cable.lua); the stand-ins talk to each
-- other over party chat through a wire that makes it dependable
-- (GB/Wire.lua). This part finds the other player and keeps the wire fed.
--
-- Messages (all in party chat, under the addon's hidden prefix):
--   LI <id> <family>   "I want to link" (sent by whoever typed /mb link first: they lead)
--   LA <id> <family>   "yes" (the other player typed /mb link)
--                      (each names its own game's family; the two need not be the same)
--   LX <id>            "I am ending the link"
--   W <frame>          a frame of the wire
local INVITE_EVERY, INVITE_FOR = 3, 90
local GAMES_TEXT = "Pokemon Red, Blue, Yellow, Gold, Silver, Crystal, Ruby, Sapphire, Emerald, FireRed and LeafGreen, and MekkaBoy's own games"
local function fits(a, b) return MB.Cable.Compatible(a, b) end
-- where a game's link desk is
local function desk(fam)
    if fam == "gen3" then return "the attendant on the right, upstairs in a Pokemon Center (both of you pick the same thing)" end
    if fam == "gen2" then return "the trade or the battle receptionist upstairs in a Pokemon Center (both of you pick the same one)" end
    return "the Cable Club attendant in a Pokemon Center"
end

local session        -- { id, host, state = "inviting" | "linked", partner, wire, ghost, epoch, since, lastInvite }
local heard          -- an invitation waiting for an answer: { id, sender, family, at }
local machine        -- the game in the console, when one is running
local ticker = CreateFrame("Frame")
ticker:Hide()

local function clockNow() return GetTime() end
local function raw(text, lane)
    return send(text, "PARTY", nil, lane) == nil
end
-- the stand-ins for this machine: the Game Boy kind or the Advance kind
local function cableFor(m)
    if not m then return nil end
    if m.linkPlug then return MB.AdvanceCable end
    return MB.Cable
end
local function family()
    local cable = cableFor(machine)
    return cable and cable.Family(machine) or nil
end
local function short(name) return (tostring(name):gsub("%-[^%-]*$", "")) end

local NOTES = {
    lead = function(s)
        local where = desk(s.peer)
        if s.peer ~= s.family and s.peer == "gen2" then where = "the Time Capsule receptionist upstairs in a Pokemon Center" end
        if s.peer == "gen2" and s.family == "gen2" then where = "the same receptionist" end
        return ("The link is open. %s can talk to %s now."):format(short(s.partner), where)
    end,
    invited = function(s)
        if s.family == "gen2" and s.peer == "gen1" then
            return ("%s has opened the link. Talk to the Time Capsule receptionist upstairs in a Pokemon Center."):format(short(s.partner))
        end
        if s.family == "gen2" and s.peer == "gen2" then
            return ("%s has opened the link. Talk to the same receptionist they chose (trade or battle), upstairs in a Pokemon Center."):format(short(s.partner))
        end
        return ("%s has opened the link. Talk to %s."):format(short(s.partner), desk(s.family))
    end,
    closed = function(s)
        if s.family == "gen3" then return nil end       -- (these games open and close the link many times in one visit)
        return "Your game closed the link."
    end,
    left = function(s)
        if s.family == "gen2" then
            return ("%s's game left the link. Walk out of the room to end it on your side too."):format(short(s.partner))
        end
        return ("%s's game left the link. If yours is still in the Cable Club, /mb reset takes you out (your game saved on the way in, and after each trade)."):format(short(s.partner))
    end,
    follow = function() return nil end,
    room = function(s)
        if s.host then return "Pick the room. Your choice counts for both of you." end
        return ("%s picks the room: your A and B buttons wait until they have."):format(short(s.partner))
    end,
    -- the Advance games
    there = function(s)
        if s.saidThere or s.saidJoined then return nil end
        s.saidThere = true
        if s.host then return ("%s's game is at the link desk. Yours will ask you to confirm the link."):format(short(s.partner)) end
        return ("%s's game is at the link desk."):format(short(s.partner))
    end,
    away = function() return nil end,
    joined = function(s)
        if s.saidJoined then return nil end
        s.saidJoined = true
        return "The two games are linked. The link is slower than a real cable: give each step a few seconds."
    end,
    capsule = function(s)
        return ("%s's Time Capsule takes you to the Trade Center: your A and B buttons wait until it has."):format(short(s.partner))
    end,
}

-- a short record of each link, kept with your saved settings (it helps when something goes wrong)
local function record(s, what)
    local db = MB.DB()
    db.linkLog = db.linkLog or {}
    local log = db.linkLog
    if not s.log then
        s.log = { when = date and date("%Y-%m-%d %H:%M") or "", partner = s.partner, host = s.host, family = s.family, events = {} }
        log[#log + 1] = s.log
        while #log > 10 do table.remove(log, 1) end
    end
    local e = s.log.events
    if #e < 200 then e[#e + 1] = ("%.1f %s"):format(clockNow() - s.since, what) end
    if s.wire then s.log.frames, s.log.resent, s.log.refused = s.wire.frames, s.wire.resent, s.wire.refused end
end

local function plug()
    local s = session
    if not (s and s.state == "linked") then return end
    if s.ghost then
        s.epoch, s.round = s.ghost.epoch, s.ghost.round
        pcall(s.ghost.detach, s.ghost)
        s.ghost = nil
    end
    if not machine then return end
    if family() ~= s.family then
        Print("This game cannot use the link. It works with " .. GAMES_TEXT .. ".")
        return
    end
    s.ghost = cableFor(machine).Attach(machine, {
        host = s.host, epoch = s.epoch, round = s.round, peer = s.peer,
        send = function(msg) if session == s then s.wire:push(msg) end end,
        note = function(what)
            record(s, what)
            local line = NOTES[what]
            if line then line = line(s) else line = what end
            if line then Print(line) end
        end,
    })
    record(s, s.ghost and "plugged in" or "no stand-in for this game")
end

local function unlink(why, tell)
    local s = session
    if not s then return end
    session = nil
    ticker:Hide()
    if s.ghost then pcall(s.ghost.detach, s.ghost) end
    if s.state == "linked" then record(s, "ended: " .. tostring(why)) end
    if tell then raw("LX" .. string.char(s.id)) end
    if why then Print(why) end
end

local function linked(partner, id, host, fam, peer)
    session = { id = id, host = host, state = "linked", partner = partner, family = fam, peer = peer or fam, epoch = 0, since = clockNow() }
    local s = session
    s.wire = MB.Wire.New({
        id = host and id or (id + 125), peer = host and (id + 125) or id, room = 254, now = clockNow, lanes = LANES,
        send = function(frame, lane) return raw("W" .. frame, lane) end,
        deliver = function(msg) if s.ghost then s.ghost:receive(msg) end end,
        lost = function() if session == s then unlink(("The link with %s went quiet and was closed. /mb link starts again."):format(short(partner))) end end,
    })
    ticker:Show()
    local mixed = (session.peer ~= fam)
    if fam == "native" then
        Print(("Linked with %s. Your games can see each other now%s."):format(short(partner), host and " (you lead)" or ""))
    elseif fam == "gen3" then
        if host then
            Print(("Linked with %s. Each of you: talk to %s. Your game will ask you to confirm once it sees theirs."):format(short(partner), desk(fam)))
        else
            Print(("Linked with %s. Each of you: talk to %s. Their game confirms the link."):format(short(partner), desk(fam)))
        end
    elseif host then
        if mixed and fam == "gen2" then
            Print(("Linked with %s, who is playing an older game. You lead: talk to the Time Capsule receptionist upstairs in a Pokemon Center first."):format(short(partner)))
        else
            Print(("Linked with %s%s. You lead: talk to %s first."):format(short(partner),
                mixed and ", who is playing a newer game (you will meet through its Time Capsule)" or "", desk(fam)))
        end
    else
        Print(("Linked with %s%s. They lead: stand in a Pokemon Center until told their link is open."):format(short(partner),
            mixed and (fam == "gen2" and ", who is playing an older game (use your Time Capsule)" or ", who is playing a newer game (you will meet through its Time Capsule)") or ""))
    end
    plug()
end

ticker:SetScript("OnUpdate", function()
    local s = session
    if not s then ticker:Hide() return end
    if s.state == "linked" then
        s.wire:tick()
    elseif s.state == "inviting" then
        local t = clockNow()
        if t - s.since > INVITE_FOR then
            unlink("Nobody answered. The other player needs MekkaBoy open with a game running, then /mb link.")
        elseif t - s.lastInvite >= INVITE_EVERY then
            s.lastInvite = t
            raw("LI" .. string.char(s.id) .. s.family)
        end
    end
end)

function Link.Heard(text, channel, sender)
    if channel ~= "PARTY" then return end
    local kind = text:sub(1, 2)
    if kind:sub(1, 1) == "W" then
        local s = session
        if s and s.state == "linked" and plain(sender) == plain(s.partner) then s.wire:receive(text:sub(2)) end
        return
    end
    if isMe(sender) then return end
    local id, fam = text:byte(3), text:sub(4)
    if not id then return end
    local s = session
    if (kind == "LI" or kind == "LA") and MB.Hello and MB.Hello.CannotLink(sender) then
        -- two copies whose link messages differ: say so (once in a while) instead of linking and going wrong
        if s and s.state == "inviting" or kind == "LI" then MB.Hello.SayCannotLink(sender) end
        return
    end
    if kind == "LI" then
        if s and s.state == "linked" then
            if not s.host and id == s.id and plain(sender) == plain(s.partner) then raw("LA" .. string.char(id) .. s.family) end
            return
        end
        if s and s.state == "inviting" then
            -- both asked at once: the lower number leads
            if id > s.id or (id == s.id and plain(sender) > plain(UnitName("player") or "")) then return end
            if not fits(fam, s.family) then return end
            local mine = s.family
            session = nil
            raw("LA" .. string.char(id) .. mine)
            linked(sender, id, false, mine, fam)
            return
        end
        if not (heard and heard.id == id) then
            Print(("%s wants to link MekkaBoys. Start your game and type /mb link to join."):format(short(sender)))
        end
        heard = { id = id, sender = sender, family = fam, at = clockNow() }
    elseif kind == "LA" then
        if s and s.state == "inviting" and id == s.id then
            if not fits(fam, s.family) then
                Print(("%s answered, but is playing a game that cannot link with yours."):format(short(sender)))
                return
            end
            local mine = s.family
            session = nil
            linked(sender, id, true, mine, fam)
        end
    elseif kind == "LX" then
        if s and s.state == "linked" and id == s.id and plain(sender) == plain(s.partner) then
            unlink(("%s ended the link."):format(short(sender)))
        end
    end
end

-- The console tells us when a game starts or stops.
function Link.MachineChanged(m)
    local now = m or nil
    if now == machine then return end
    machine = now
    if session and session.state == "linked" then plug() end
end
-- Should the Advance game be held still this frame? (see GBA/Cable.lua)
function Link.Waiting()
    local g = session and session.ghost
    return (g and g.waiting and g:waiting(clockNow())) and true or false
end
function Link.Busy()
    return (session and session.ghost and session.ghost:busy()) and true or false
end
function Link.BlocksKey(button)
    return (session and session.ghost and session.ghost:blocksKey(button)) and true or false
end
function Link.Session() return session end

function Link.Open()
    if not (MB.Cable and MB.Wire and MB.AdvanceCable) then Print("The link is not installed properly: restart the game client.") return end
    if session and session.state == "linked" then
        local s = session
        Print(("Linked with %s (%s). /mb link off ends it."):format(short(s.partner), s.host and "you lead" or "they lead"))
        print(("  messages sent %d (%d of them twice or more, %d turned back by the server); game %s"):format(s.wire.frames, s.wire.resent, s.wire.refused,
            s.ghost and (s.ghost:busy() and ("in a link session, " .. s.ghost.phase) or "not in a link session yet") or "not running or not supported"))
        return
    end
    if session then Print("Still looking for the other MekkaBoy...") return end
    if not (IsInGroup and IsInGroup()) then
        Print("Join a party with the other player first: the link runs through party chat.")
        return
    end
    local fam = family()
    if not fam then
        if machine and not machine.linkPlug and MB.Cable.Changed(machine) then
            Print("This copy of the game is not the one the link knows: it is another version, or it has been modified. The link is switched off for it, so that nothing gets corrupted.")
        else
            Print("Start your game on the MekkaBoy first. The link works with " .. GAMES_TEXT .. ".")
        end
        return
    end
    if heard and clockNow() - heard.at < INVITE_FOR then
        local h = heard
        heard = nil
        if not fits(h.family, fam) then
            Print(("%s is playing a game that cannot link with yours."):format(short(h.sender)))
            return
        end
        raw("LA" .. string.char(h.id) .. fam)
        linked(h.sender, h.id, false, fam, h.family)
        return
    end
    session = { id = math.random(1, 120), host = true, state = "inviting", family = fam, since = clockNow(), lastInvite = -100 }
    ticker:Show()
    Print("Looking for another MekkaBoy in your party. The other player types /mb link too.")
end

function Link.Close()
    if not session then Print("There is no link to end.") return end
    unlink("Link ended.", session.state == "linked")
end

MB.AddCommand("link", "link - join the other MekkaBoy in your party, to trade and battle; link off ends it", function(rest)
    rest = rest:lower()
    if rest == "off" or rest == "end" or rest == "stop" then Link.Close() else Link.Open() end
end)

MB.AddCommand("ping", "ping target|me|party|<player> - test the link to another MekkaBoy (they just need it installed)", function(rest)
    if rest == "" then
        Print("Who with? Target a player and /mb ping target, or /mb ping <name>, or /mb ping party. /mb ping me tests the line to the server and back.")
        return
    end
    Link.Ping(rest)
end)

-- For the record: every chat-side event seen while a test runs, so that a
-- silent line can be told apart from a refusal the server did announce.
do
    local watch = CreateFrame("Frame")
    diag.watching = {}
    for _, name in ipairs({ "CHAT_MSG_ADDON", "CHAT_MSG_ADDON_LOGGED", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
                            "CHAT_MSG_SYSTEM", "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
                            "CHAT_MSG_RESTRICTED", "CHAT_MSG_FILTERED", "CHAT_MSG_IGNORED", "CHANNEL_PASSWORD_REQUEST",
                            "CHAT_SERVER_DISCONNECTED", "CHAT_SERVER_RECONNECTED" }) do
        if pcall(watch.RegisterEvent, watch, name) then diag.watching[#diag.watching + 1] = name end
    end
    local function show(v)
        if issecretvalue and issecretvalue(v) then return "<secret>" end
        local ok, text = pcall(tostring, v)
        text = ok and text or "?"
        if #text > 60 then text = text:sub(1, 60) .. "..." end
        return (text:gsub("[%c|]", "."))
    end
    watch:SetScript("OnEvent", function(_, event, a, b2, c, d, e, f, g, h, i)
        local t = test
        if not t then return end
        t.heardEvents = t.heardEvents or {}
        if #t.heardEvents < 60 then
            t.heardEvents[#t.heardEvents + 1] = ("%.1f %s: %s; %s; %s; %s; .. %s; %s"):format(t.clock, event, show(a), show(b2), show(c), show(d), show(h), show(i))
        end
    end)
end
