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
local EXTRA_LANE = 5        -- an addon name of its own for ghosts and the lobby (lanes 1-4 are the link's wire)
local whispered, unreachable = {}, {}       -- spelling (lower case) -> when we last whispered it / when the server said nobody
local function send(text, channel, target, lane)
    if not SendAddonMessage then return "no messaging" end
    if channel == "WHISPER" and type(target) == "string" then whispered[target:lower()] = GetTime() end
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
    -- (a trailing -Realm stays a realm: only the name's own hyphen may become a space)
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
    local body, tail = name, ""
    if type(realm) == "string" and realm ~= "" and #name > #realm + 1 and name:sub(-#realm - 1):lower() == ("-" .. realm):lower() then
        body, tail = name:sub(1, -#realm - 2), name:sub(-#realm - 1)
    end
    for _, v in ipairs({ name, (body:gsub("%s+", "-")) .. tail, (body:gsub("%s+", "")) .. tail, (body:gsub("%-", " ")) .. tail }) do
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

local nameIs          -- (below: the same player, with or without the realm in the name)
local function onMessage(text, channel, sender, lane)
    local kind, id, rest = text:sub(1, 1), text:sub(2, 4), text:sub(5)
    if kind == "V" then                           -- "this is my version" (Hello.lua)
        if MB.Hello and MB.Hello.Heard then MB.Hello.Heard(rest, channel, sender) end
        return
    end
    if kind == "Q" then                           -- the realm lobby (GB/Lobby.lua)
        if MB.Lobby and MB.Lobby.Heard then MB.Lobby.Heard(text, channel, sender) end
        return
    end
    if kind == "L" or kind == "W" then            -- the link itself (further down)
        if Link.Heard then Link.Heard(text, channel, sender) end
        return
    end
    if kind == "F" then                           -- who has MekkaBoy and what they are playing (Friends.lua)
        if MB.Friends and MB.Friends.Heard then MB.Friends.Heard(text, channel, sender) end
        return
    end
    if kind == "J" then                           -- did both games keep a trade? (GBA/Trade3.lua)
        if MB.Trade3 and MB.Trade3.Heard then pcall(MB.Trade3.Heard, text, channel, sender) end
        return
    end
    if kind == "G" then                           -- other trainers walking in your game (GBA/Ghosts.lua)
        if MB.Ghosts and MB.Ghosts.Heard then MB.Ghosts.Heard(text, channel, sender) end
        return
    end
    -- which spelling of a name reaches that player (Link.Resolve): their MekkaBoy answers our ping
    if kind == "A" and channel == "WHISPER" and Link.resolving then
        local r = Link.resolving[tonumber(id) or -1]
        if r then
            if nameIs(sender, r.name) then
                Link.resolving[tonumber(id)] = nil
                if not r.call.done and GetTime() - r.call.at < 15 then
                    r.call.done = true
                    pcall(r.call.cb, r.name, sender)
                end
            elseif GetTime() - r.call.at > 15 then
                Link.resolving[tonumber(id)] = nil
            end
            return
        end
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
        if kind == "P" and back == "WHISPER" and (tonumber(id) or 0) >= 800 and (tonumber(id) or 0) < 900 then
            -- someone finding which spelling of our name reaches us (Link.Resolve): answer every spelling of theirs
            local list = { sender }                     -- (the name the server gave first; it is the surest)
            spellings(list, sender)
            for i, name in ipairs(list) do if i <= 4 and not Link.Unreachable(name) then send("A" .. id, "WHISPER", name, lane) end end
        elseif kind == "P" then
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
-- the same player? (one name may carry the realm, "Name-Realm", and the other not)
local function realmPlain()
    local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
    return type(r) == "string" and r ~= "" and plain(r) or nil
end
function nameIs(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local pa, pb = plain(a), plain(b)
    if pa == pb then return true end
    local r = realmPlain()
    return r ~= nil and (pa == pb .. r or pb == pa .. r)
end
Link.NameIs = nameIs
-- did the server just say nobody of that name is online? (then that spelling is not tried again for a minute)
function Link.Unreachable(name)
    local t = type(name) == "string" and unreachable[name:lower()]
    return t and GetTime() - t < 60 or false
end

-- Find which spelling of a player's name a whisper reaches: one ping to each (numbers 800-899), and their
-- MekkaBoy answers by itself (this version and later: the pings go out on the extra addon name, which older versions
-- do not listen on). cb(spelling, theirSenderName) once, on the first answer.
local resolveNext = 800
function Link.Resolve(name, cb, unit)
    local cands = {}
    if unit then cands = unitSpellings(unit) else spellings(cands, name) end
    Link.resolving = Link.resolving or {}
    local call = { cb = cb, at = GetTime() }
    for i, c in ipairs(cands) do
        if i > 4 then break end
        local id = resolveNext
        resolveNext = resolveNext >= 899 and 800 or resolveNext + 1
        Link.resolving[id] = { name = c, call = call }
        send(("P%03d"):format(id), "WHISPER", c, EXTRA_LANE)
    end
    return cands
end
Link.Spellings = function(name) local t = {} spellings(t, name) return t end
Link.UnitSpellings = function(unit) return unitSpellings(unit) end
Link.EXTRA_LANE = EXTRA_LANE

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
OURS[laneName(EXTRA_LANE)] = EXTRA_LANE
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
    pcall(RegisterPrefix, laneName(EXTRA_LANE))
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
-- Without a party (/mb link <name>), the same link runs over whispers to that one player. A name can be spelled
-- several ways (Forever's two-part names), and only some reach the player, so the first messages find the spelling:
--   LV <id> <k> <protocol> <family>        "I want to link" (whispered to spelling k of their name)
--   LB <id> <k> <j> <protocol> <family>    "yes" (whispered to spelling j of the caller's name; k: the spelling that reached me)
--   LC <id> <j>                            "linked" (j: the spelling of your name that reached me)
--   then W frames and LX, as in a party, whispered to the spelling that works
-- A table for more than two (only MekkaBoy's own games, when the cartridge asks for one: GBA/Cable.lua Seats).
-- The host links with each guest on a wire of its own; guests talk only to the host.
--   LT <id> <seats> <code> <family>   "my table has room" (the host, every few seconds while a seat is free;
--                                     code: the 4-letter game code, which the guest's game must share)
--   LA <id> <family>                  "may I sit down?" (the guest, every few seconds until seated)
--   LS <id> <seat> <name>             "<name>: seat <seat> is yours" (255 = the table is full; never 0: chat takes no zero bytes)
--   LX <id>                           a guest leaving frees its seat; the host leaving closes the table
local INVITE_EVERY, INVITE_FOR = 3, 90
local TABLE_INVITE_EVERY, ASK_EVERY, ASK_FOR = 4, 3, 30
-- the wire marks for seat k's pair of wires at table id (seat 1 gets the two-player pair: id and id + 125);
-- always 1..120 and 126..245, so never "|" (124) nor zero
local function wireIds(id, k) local h = ((id - 1 + 40 * (k - 1)) % 120) + 1 return h, h + 125 end
local GAMES_TEXT = "Pokemon Red, Blue, Yellow, Gold, Silver, Crystal, Ruby, Sapphire, Emerald, FireRed and LeafGreen, and MekkaBoy's own games"
local function fits(a, b) return MB.Cable.Compatible(a, b) end
-- MekkaBoy's own games all share the "native" link, but each only talks to itself: the family sent for one of them names
-- the game too ("native:MBCC"), so Overload never links with Gearworks. A MekkaBoy from before 0.20.2 sends a bare
-- "native", which matches nothing: the two cannot tell whether their games agree.
local function isNative(f) return type(f) == "string" and f:sub(1, 6) == "native" end
local function whyNot(theirs, mine)
    if isNative(theirs) and isNative(mine) then
        if theirs == "native" or mine == "native" then return "is using another version of MekkaBoy (both of you need 0.20.2 or later)" end
        return "is playing a different MekkaBoy game (start the same one)"
    end
    return "is playing a game that cannot link with yours"
end
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
-- While linked, each MekkaBoy says "my game is running" every second (a bare "K" on the wire), and only while it is:
-- a partner whose game has stopped (paused, closed, a loading screen, gone) falls silent. The Advance game here is then
-- held still, so it cannot finish a trade, and save it, on its own; after AWAY_CLOSE the link is closed.
-- (a beat goes only when nothing else has for BEAT_EVERY: anything we send says the same, and a trade or battle in
-- full flow needs every frame the server allows; a frame lost on the way is sent again after 3 s, hence the margins)
local BEAT_EVERY, AWAY_HOLD, AWAY_TELL, AWAY_CLOSE = 2.5, 4, 9, 60
-- at a table (the host's star) a seat whose console has fallen silent this long is freed: the game decides what
-- happens to it (Deadmines Hold'em empties it, and a crew member sits down a little later). The beats there go
-- whether or not the game is running: a paused guest is the game's to deal with (it sits out), a gone one is ours.
local TABLE_AWAY = 15

local function clockNow() return GetTime() end
-- one wire's beat: "K" when nothing else has gone for BEAT_EVERY; returns how long the other end has been silent
-- (nil until it has been heard to beat at all: an older MekkaBoy never does, and is never timed out this way)
local function beat(o, wire, t, running)
    if running and t - math.max(o.beatAt or 0, wire.pushedAt or 0) >= BEAT_EVERY then
        o.beatAt = t
        wire:push("K", true)
    end
    if o.tickAt and t - o.tickAt > 3 then o.heardAt = t end          -- (our own loading screen)
    o.tickAt = t
    if o.beats then return t - (o.heardAt or t) end
end
local function heardFrom(o, msg) o.heardAt = clockNow() if msg == "K" then o.beats = true return true end end
local function raw(text, lane, route)
    if route == nil then route = session and session.route end
    if route then return send(text, "WHISPER", route.target, lane) == nil end
    return send(text, "PARTY", nil, lane) == nil
end
-- the stand-ins for this machine: the Game Boy kind or the Advance kind
local function cableFor(m)
    if not m then return nil end
    if m.linkPlug then return MB.AdvanceCable end
    return MB.Cable
end
local gameCode
local function family()
    local cable = cableFor(machine)
    local f = cable and cable.Family(machine) or nil
    if f == "native" then return "native:" .. gameCode() end
    return f
end
local function short(name) return (tostring(name):gsub("%-[^%-]*$", "")) end
Link.Short = short
function Link.Family() return family() end            -- (what the game in the console links as: Friends.lua says it to others)
local function friendsSay(what, ...) if MB.Friends and MB.Friends[what] then pcall(MB.Friends[what], ...) end end
-- the seats the running game's table wants (0: an ordinary two-player link)
local function tableSeats()
    local m = machine
    if m and m.linkPlug and MB.AdvanceCable and MB.AdvanceCable.Seats then return MB.AdvanceCable.Seats(m) end
    return 0
end
function gameCode()
    local m = machine
    if m and m.linkPlug and MB.AdvanceCable and MB.AdvanceCable.Code then return MB.AdvanceCable.Code(m) end
    return ""
end
-- exactly this player (a seat is given by name, so a prefix match is not enough)
local function sameAsMe(name)
    if not (UnitName and type(name) == "string") then return false end
    local me, realm = UnitName("player")
    if type(me) ~= "string" or me == "" then return false end
    local n = plain(name)
    if n == plain(me) then return true end
    realm = (type(realm) == "string" and realm ~= "" and realm) or (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
    return type(realm) == "string" and n == plain(me .. realm)
end
-- the whisper paths: this player in any spelling (a two-part name, with or without the realm), and my full name
local function myFull()
    local me, second = UnitName and UnitName("player")
    if type(me) ~= "string" then return "" end
    return plain(me .. ((type(second) == "string") and second or ""))
end
local function isMyself(name)
    if sameAsMe(name) then return true end
    local me, second = UnitName and UnitName("player")
    if type(me) ~= "string" or me == "" then return false end
    return nameIs(name, me) or (type(second) == "string" and second ~= "" and nameIs(name, me .. second)) or false
end
local function fullOf(name)                       -- a sender's name without the realm, for the tie-break
    local n, r = plain(name), realmPlain and realmPlain()
    if r and #n > #r and n:sub(-#r) == r then n = n:sub(1, -#r - 1) end
    return n
end
local function memberMask(s)
    if not s.host then return 1 + 2 ^ (s.seat or 1) end
    local mask = 1
    for k in pairs(s.members) do mask = mask + 2 ^ k end
    return mask
end
local function memberBy(s, sender)
    for k, mb in pairs(s.members) do if plain(mb.name) == plain(sender) then return k, mb end end
end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

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
    if s.wire then
        s.log.frames, s.log.resent, s.log.refused = s.wire.frames, s.wire.resent, s.wire.refused
        local w = s.wire
        s.log.rttMs = w.rtt and math.floor(w.rtt * 1000 + 0.5) or nil              -- (answer times: average, and best)
        s.log.rttBestMs = w.rttLow and math.floor(w.rttLow * 1000 + 0.5) or nil
        s.log.waitedS = w.starved and math.floor(w.starved * 10 + 0.5) / 10 or nil   -- (seconds held back by the server's limit)
    end
    -- the game's speed while linked (100 = full speed): a slow console makes a slow link, whatever the line does
    local m = MB.Machine and MB.Machine()
    local f = m and (m.frameNo or (m.clock and math.floor(m.clock() / 70224)))
    if f then
        local t = clockNow()
        if not s.speedAt then s.speedAt, s.speedFrames = t, f
        elseif t - s.speedAt > 5 then
            local pct = math.floor((f - s.speedFrames) / ((t - s.speedAt) * 59.73) * 100 + 0.5)
            s.log.speed = pct
            s.log.slowest = math.min(s.log.slowest or pct, pct)
            s.speedAt, s.speedFrames = t, f
        end
    end
    if s.table then s.log.seats, s.log.seat = s.seats, s.seat end
end

local unlink
local function plug()
    local s = session
    if not (s and s.state == "linked") then return end
    if s.table then
        if s.ghost then pcall(s.ghost.detach, s.ghost) s.ghost = nil end
        if not machine then return end
        if family() ~= s.family or gameCode() ~= s.code then
            unlink(s.host and "The cartridge changed, so your table was closed." or "The cartridge changed, so you left the table.", true)
            return
        end
        local send
        if s.host then
            send = function(msg, to)
                if session ~= s then return end
                if to then
                    local mb = s.members[to]
                    if mb then mb.wire:push(msg) end
                else
                    for _, mb in pairs(s.members) do mb.wire:push(msg) end
                end
            end
        else
            send = function(msg) if session == s and s.wire then s.wire:push(msg) end end
        end
        s.ghost = MB.AdvanceCable.Attach(machine, {
            host = s.host, seats = s.seats, seat = s.seat, members = memberMask(s), send = send,
            note = function(what) record(s, what) end,
        })
        record(s, s.ghost and "plugged in" or "no stand-in for this game")
        return
    end
    if s.ghost then
        s.epoch, s.round = s.ghost.epoch, s.ghost.round
        pcall(s.ghost.detach, s.ghost)
        s.ghost = nil
    end
    if not machine then return end
    if family() ~= s.family then
        -- (another cartridge while linked: the other player's game is still the one it linked with, so the link goes)
        unlink(family() and ("The cartridge changed, so the link with %s was closed."):format(short(s.partner))
            or "This game cannot use the link. It works with " .. GAMES_TEXT .. ".", true)
        return
    end
    s.ghost = cableFor(machine).Attach(machine, {
        host = s.host, epoch = s.epoch, round = s.round, peer = s.peer,
        send = function(msg) if session == s then s.wire:push(msg) end end,
        hurry = MB.Alpha() and function() if session == s then s.wire:hurry() end end or nil,
        note = function(what)
            record(s, what)
            local line = NOTES[what]
            if line then line = line(s) else line = what end
            if line then Print(line) end
        end,
    })
    record(s, s.ghost and "plugged in" or "no stand-in for this game")
end

-- "the link is over" must reach the other end: when the server pushes back (the allowance is spent, as it can be when
-- all the addon's names are counted together), try again for a few seconds rather than leave them linked to nobody
local byeFrame
local function sayBye(text, route)
    if raw(text, nil, route) then return end
    byeFrame = byeFrame or CreateFrame("Frame")
    local untilT, nextT = GetTime() + 5, GetTime() + 0.3
    byeFrame:SetScript("OnUpdate", function(f)
        local t = GetTime()
        if t < nextT then return end
        nextT = t + 0.3
        if raw(text, nil, route) or t > untilT then f:SetScript("OnUpdate", nil) end
    end)
    byeFrame:Show()
end
function unlink(why, tell)
    local s = session
    if not s then return end
    session = nil
    ticker:Hide()
    if s.ghost then pcall(s.ghost.detach, s.ghost) end
    if s.state == "linked" then record(s, "ended: " .. tostring(why)) end
    if tell then sayBye("LX" .. string.char(s.id), s.route or false) end
    if why then Print(why) end
    if MB.Trade3 and MB.Trade3.LinkEnded then pcall(MB.Trade3.LinkEnded) end
end

local function linked(partner, id, host, fam, peer, route)
    session = { id = id, host = host, state = "linked", partner = partner, family = fam, peer = peer or fam, epoch = 0, since = clockNow(), route = route }
    friendsSay("Linked", partner, fam, peer or fam)
    if MB.Trade3 and MB.Trade3.Linked then pcall(MB.Trade3.Linked, partner) end
    local s = session
    s.wire = MB.Wire.New({
        id = host and id or (id + 125), peer = host and (id + 125) or id, room = 254, now = clockNow, lanes = LANES,
        send = function(frame, lane) return raw("W" .. frame, lane, s.route or false) end,
        deliver = function(msg)
            s.heardAt = clockNow()
            if msg == "K" then s.beats = true return end        -- (their game is running: nothing else to it)
            if s.ghost then s.ghost:receive(msg) end
        end,
        lost = function() if session == s then unlink(("The link with %s went quiet and was closed. /mb link starts again."):format(short(partner))) end end,
    })
    s.heardAt, s.beatAt = clockNow(), 0
    ticker:Show()
    local mixed = (session.peer ~= fam)
    if route then record(s, "over whispers to " .. tostring(route.target)) end
    if isNative(fam) then
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
    if not isNative(fam) and MB.Alpha() then
        -- (the trade animation and a battle's moves are the games' own, and long: fast-forward is safe while linked)
        Print(("If a trade or battle feels slow, hold %s to fast-forward. The two games stay in step; the other player can do the same."):format(MB.KeyLabel and MB.KeyLabel("ff") or "Tab"))
    end
    plug()
end

-- ---- a table for more than two ----
local function dropMember(s, k, why)
    local mb = s.members[k]
    if not mb then return end
    s.members[k] = nil
    record(s, ("seat %d left: %s"):format(k, why))
    if s.ghost and s.ghost.setMembers then s.ghost:setMembers(memberMask(s)) end
    Print(why == "left" and ("%s left your table."):format(short(mb.name))
        or ("%s's link went quiet; their seat is free again."):format(short(mb.name)))
end
local function seatMember(s, sender, fam)
    local k = memberBy(s, sender)
    if k then raw("LS" .. string.char(s.id, k) .. sender) return end     -- (asked again: the answer was lost)
    if not fits(fam, s.family) then return end
    for seat = 1, s.seats - 1 do if not s.members[seat] then k = seat break end end
    if not k then raw("LS" .. string.char(s.id, 255) .. sender) return end
    local mine, peer = wireIds(s.id, k)
    local mb = { name = sender }
    mb.wire = MB.Wire.New({
        id = mine, peer = peer, room = 254, now = clockNow, lanes = LANES, share = s.lanes,
        send = function(frame, lane) return raw("W" .. frame, lane) end,
        deliver = function(msg) if heardFrom(mb, msg) then return end if s.ghost then s.ghost:receive(msg, k) end end,
        lost = function() if session == s and s.members[k] == mb then dropMember(s, k, "quiet") end end,
    })
    s.members[k] = mb
    record(s, ("seat %d: %s"):format(k, sender))
    if s.ghost and s.ghost.setMembers then s.ghost:setMembers(memberMask(s)) end
    raw("LS" .. string.char(s.id, k) .. sender)
    Print(("%s sat down at your table (%d of %d seats taken)."):format(short(sender), count(s.members) + 1, s.seats))
end
local function openTable(seats)
    session = { id = math.random(1, 120), host = true, state = "linked", table = true, seats = seats, seat = 0, members = {},
                family = family(), code = gameCode(), epoch = 0, since = clockNow(), lastInvite = -100, lanes = MB.Wire.Lanes(LANES, clockNow) }
    ticker:Show()
    plug()
    Print(("Your table is open, with room for %d more. The others in your party start the same game and type /mb link to sit down. /mb link off closes it."):format(seats - 1))
end
local function askForSeat(h, fam)
    session = { id = h.id, host = false, state = "seating", table = true, seats = h.seats, partner = h.sender, family = fam, code = h.code,
                epoch = 0, since = clockNow(), lastAsk = clockNow() }
    ticker:Show()
    raw("LA" .. string.char(h.id) .. fam)
    Print(("Asking %s for a seat at their table..."):format(short(h.sender)))
end
local function seated(s, k)
    s.state, s.seat = "linked", k
    local mine, peer = wireIds(s.id, k)
    mine, peer = peer, mine                                              -- (the guest's mark is the second of the pair)
    s.wire = MB.Wire.New({
        id = mine, peer = peer, room = 254, now = clockNow, lanes = LANES,
        send = function(frame, lane) return raw("W" .. frame, lane) end,
        deliver = function(msg) if heardFrom(s, msg) then return end if s.ghost then s.ghost:receive(msg, 0) end end,
        lost = function() if session == s then unlink(("The link with %s's table went quiet and was closed. /mb link starts again."):format(short(s.partner))) end end,
    })
    record(s, ("seated: %d"):format(k))
    Print(("You sit down at %s's table. Your games can see each other now."):format(short(s.partner)))
    plug()
end

ticker:SetScript("OnUpdate", function()
    local s = session
    if not s then ticker:Hide() return end
    if s.state == "linked" and s.members then
        for _, mb in pairs(s.members) do mb.wire:tick() end
        if session ~= s then return end
        local t = clockNow()
        for k, mb in pairs(s.members) do
            local away = beat(mb, mb.wire, t, true)
            if away and away > TABLE_AWAY then dropMember(s, k, "quiet") end
        end
        if count(s.members) < s.seats - 1 and t - s.lastInvite >= TABLE_INVITE_EVERY then
            s.lastInvite = t
            raw("LT" .. string.char(s.id, s.seats) .. s.code .. s.family)
        end
    elseif s.state == "linked" then
        s.wire:tick()
        if session ~= s then return end
        if s.table then                                                 -- (a seat at someone's table)
            local away = beat(s, s.wire, clockNow(), true)
            if away and away > TABLE_AWAY then
                unlink(("%s's table went quiet (they may have gone offline), so you have left it. /mb link finds a table again."):format(short(s.partner)), true)
            end
            return
        end
        local t = clockNow()
        -- (our own client froze a while, a loading screen: what the other end said meanwhile is still on its way)
        if s.tickAt and t - s.tickAt > 3 then s.heardAt = t end
        s.tickAt = t
        if MB.IsRunning and MB.IsRunning() and t - math.max(s.beatAt, s.wire.pushedAt or 0) >= BEAT_EVERY then
            s.beatAt = t
            s.wire:push("K", true)
        end
        if s.beats then
            local away = t - (s.heardAt or t)
            if s.ghost then s.ghost.partnerAway = away > AWAY_HOLD end
            if away > AWAY_TELL and not s.toldAway then
                s.toldAway = true
                Print(("%s's game has stopped (paused, a loading screen, or gone offline). Yours waits for it, so that nothing happens on one side only."):format(short(s.partner)))
            elseif away <= AWAY_HOLD and s.toldAway then
                s.toldAway = false
                Print(("%s's game is back; both carry on."):format(short(s.partner)))
            end
            if away > AWAY_CLOSE then
                unlink(("%s's game has not come back for a minute, so the link is closed. If your game shows a communication error, type /mb reset to restart it from your save: a trade only counts once both games have saved it."):format(short(s.partner)), true)
                return
            end
        end
    elseif s.state == "seating" then
        local t = clockNow()
        if t - s.since > ASK_FOR then
            unlink(("%s's table did not answer. /mb link tries again."):format(short(s.partner)))
        elseif t - s.lastAsk >= ASK_EVERY then
            s.lastAsk = t
            raw("LA" .. string.char(s.id) .. s.family)
        end
    elseif s.state == "inviting" then
        local t = clockNow()
        if t - s.since > INVITE_FOR then
            unlink("Nobody answered. The other player needs MekkaBoy open with a game running, then /mb link.")
        elseif t - s.lastInvite >= INVITE_EVERY then
            s.lastInvite = t
            raw("LI" .. string.char(s.id) .. s.family)
        end
    elseif s.state == "calling" then                 -- (no party: whispering every spelling of their name)
        local t = clockNow()
        if t - s.since > INVITE_FOR then
            unlink(("%s did not answer. They need MekkaBoy open with a game running, to be online, and (probably) your faction; then they type /mb link."):format(short(s.partner)))
        elseif t - s.lastInvite >= INVITE_EVERY then
            s.lastInvite = t
            for k, name in ipairs(s.candidates) do if not Link.Unreachable(name) then send("LV" .. string.char(s.id, k, MB.PROTOCOL) .. s.family, "WHISPER", name) end end
        end
    elseif s.state == "answering" then
        local t = clockNow()
        if t - s.since > ASK_FOR then
            unlink(("%s's MekkaBoy did not hear the answer. /mb link %s tries from your side."):format(short(s.partner), short(s.partner)))
        elseif t - s.lastAsk >= ASK_EVERY then
            s.lastAsk = t
            for j, name in ipairs(s.cands) do if not Link.Unreachable(name) then send("LB" .. string.char(s.id, s.echo, j, MB.PROTOCOL) .. s.family, "WHISPER", name) end end
        end
    end
end)

-- ---- the link without a party: whispers to one player ----
local heardW = {}    -- whispered invitations waiting for an answer: plain name -> { id, k, sender, family, at }
local toldInvite = {} -- plain name -> when we last said they want to link (kept when the invitation goes)
local function okId(id) return id and id >= 1 and id <= 120 end
local function latestInvite()
    local best
    for key, h in pairs(heardW) do
        if clockNow() - h.at > INVITE_FOR then heardW[key] = nil
        elseif not best or h.at > best.at then best = h end
    end
    return best
end
local toldProtocol = {}
local function sayProtocol(sender)
    local t = clockNow()
    if toldProtocol[plain(sender)] and t - toldProtocol[plain(sender)] < 60 then return end
    toldProtocol[plain(sender)] = t
    Print(("%s's MekkaBoy speaks another link protocol: one of you needs the newer version."):format(short(sender)))
end
local function answer(h, fam)
    local cands = {}
    spellings(cands, h.sender)
    session = { id = h.id, host = false, state = "answering", family = fam, peer = h.family, cands = cands, echo = h.k,
                partner = h.sender, since = clockNow(), lastAsk = -100 }
    ticker:Show()
    Print(("Answering %s..."):format(short(h.sender)))
end
local function calls(s, sender)
    for _, name in ipairs(s.candidates) do if nameIs(name, sender) then return true end end
    return nameIs(s.partner, sender)
end
local function heardWhisper(text, sender)
    if isMyself(sender) then return end
    local s = session
    local kind = text:sub(1, 2)
    if kind:sub(1, 1) == "W" then
        if s and s.state == "linked" and s.route and s.wire and nameIs(sender, s.partner) then s.wire:receive(text:sub(2)) end
        return
    end
    local id = text:byte(3)
    if not okId(id) then return end
    if kind == "LV" then
        local k, proto, fam = text:byte(4), text:byte(5), text:sub(6)
        if not (k and proto) or k < 1 or k > 8 or fam == "" or #fam > 12 then return end
        if proto ~= MB.PROTOCOL then sayProtocol(sender) return end
        if s and s.state == "calling" and calls(s, sender) then
            -- both called each other at once: the lower number leads, the other answers
            if id > s.id or (id == s.id and fullOf(sender) > myFull()) then return end
            if not fits(fam, s.family) then return end
            local mine = s.family
            session = nil
            answer({ id = id, k = k, sender = sender, family = fam }, mine)
            return
        end
        local key = plain(sender)
        if s then
            -- busy with another link: say so (once in a while), and tell them not now
            if clockNow() - (toldInvite[key] or -100) > 30 then
                toldInvite[key] = clockNow()
                Print(("%s wants to link MekkaBoys with you, but you are %s. /mb link off first, then /mb link %s."):format(short(sender),
                    s.state == "linked" and "linked already" or "busy with another link", short(sender)))
            end
            send("LX" .. string.char(id), "WHISPER", sender)
            return
        end
        latestInvite()                                                   -- (old invitations go)
        local n = 0
        for _ in pairs(heardW) do n = n + 1 end
        if not heardW[key] and n >= 20 then return end                   -- (no more than 20 callers at once)
        local tell = clockNow() - (toldInvite[key] or -100) > 30          -- (one notice per caller every 30 s at most)
        heardW[key] = { id = id, k = k, sender = sender, family = fam, at = clockNow() }
        friendsSay("Invited", sender, fam, "whisper", id)
        if tell then
            toldInvite[key] = clockNow()
            Print(("%s wants to link MekkaBoys with you (no party needed). Start your game and type /mb link %s to answer."):format(short(sender), short(sender)))
        end
    elseif kind == "LB" then
        local k, j, proto, fam = text:byte(4), text:byte(5), text:byte(6), text:sub(7)
        if not (k and j and proto) or j < 1 or j > 8 then return end
        if s and s.state == "calling" and id == s.id and calls(s, sender) then
            if proto ~= MB.PROTOCOL then sayProtocol(sender) return end
            local target = s.candidates[k]
            if not target then return end
            if not fits(fam, s.family) then
                Print(("%s answered, but %s."):format(short(sender), whyNot(fam, s.family)))
                return
            end
            local mine = s.family
            session = nil
            linked(sender, id, true, mine, fam, { target = target })
            raw("LC" .. string.char(id, j))
        elseif s and s.state == "linked" and s.host and s.route and id == s.id and nameIs(sender, s.partner) then
            raw("LC" .. string.char(id, j))                  -- (they did not hear it the first time)
        end
    elseif kind == "LC" then
        local j = text:byte(4)
        if s and s.state == "answering" and id == s.id and j and s.cands[j] and nameIs(sender, s.partner) then
            local fam, peer = s.family, s.peer
            session = nil
            linked(sender, id, false, fam, peer, { target = s.cands[j] })
        end
    elseif kind == "LX" then
        if s and (s.route or s.state == "answering") and id == s.id and nameIs(sender, s.partner) then
            unlink(("%s ended the link."):format(short(sender)))
        elseif s and s.state == "calling" and id == s.id and calls(s, sender) then
            unlink(("%s said no for now."):format(short(sender)))
        else
            local key = plain(sender)
            if heardW[key] and heardW[key].id == id then heardW[key] = nil end      -- (they stopped calling)
        end
    end
end

function Link.Heard(text, channel, sender)
    if channel == "WHISPER" then heardWhisper(text, sender) return end
    if channel ~= "PARTY" then return end
    local kind = text:sub(1, 2)
    if kind:sub(1, 1) == "W" then
        local s = session
        if s and s.state == "linked" then
            if s.members then
                local _, mb = memberBy(s, sender)
                if mb then mb.wire:receive(text:sub(2)) end
            elseif s.wire and not s.route and plain(sender) == plain(s.partner) then
                s.wire:receive(text:sub(2))
            end
        end
        return
    end
    if isMyself(sender) then return end
    local id, fam = text:byte(3), text:sub(4)
    if not id or id < 1 or id > 120 then return end
    local s = session
    if (kind == "LI" or kind == "LA" or kind == "LT") and MB.Hello and MB.Hello.CannotLink(sender) then
        -- two copies whose link messages differ: say so (once in a while) instead of linking and going wrong
        if s and s.state == "inviting" or kind == "LI" or kind == "LT" then MB.Hello.SayCannotLink(sender) end
        return
    end
    -- the table messages
    if kind == "LT" then
        local seats, code, tfam = text:byte(4), text:sub(5, 8), text:sub(9)
        if not seats or seats < 3 or seats > 5 or #code < 4 then return end
        local h = { id = id, sender = sender, family = tfam, at = clockNow(), table = true, seats = seats, code = code }
        if s and s.members and count(s.members) == 0 and s.code == code
            and (id < s.id or (id == s.id and plain(sender) < plain(UnitName("player") or ""))) then
            -- two tables opened at once, and nobody has sat at ours yet: the lower number keeps its table
            local fam = s.family
            unlink(nil, false)
            Print(("%s opened a table at the same time; you join theirs instead."):format(short(sender)))
            askForSeat(h, fam)
            return
        end
        if s or not MB.Alpha() then return end        -- (a stable build has no party tables yet)
        if not (heard and heard.id == id and heard.table) then
            Print(("%s has a table with a free seat. Start the same game and type /mb link to sit down."):format(short(sender)))
        end
        heard = h
        return
    elseif kind == "LA" and s and s.members then
        if id == s.id then seatMember(s, sender, fam) end
        return
    elseif kind == "LS" then
        local k, name = text:byte(4), text:sub(5)
        if not (s and s.table and not s.host and id == s.id and plain(sender) == plain(s.partner) and sameAsMe(name)) then return end
        if s.state == "seating" then
            if not k or k < 1 or k > 4 then unlink(("%s's table is full."):format(short(sender))) return end
            seated(s, k)
        end
        return
    elseif kind == "LX" and s and s.members then
        if id == s.id then
            local k = memberBy(s, sender)
            if k then dropMember(s, k, "left") end
        end
        return
    elseif kind == "LX" and s and s.table and not s.host then
        if id == s.id and plain(sender) == plain(s.partner) then unlink(("%s closed the table."):format(short(sender))) end
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
        friendsSay("Invited", sender, fam, "party", id)
    elseif kind == "LA" then
        if s and s.state == "inviting" and id == s.id then
            if not fits(fam, s.family) then
                Print(("%s answered, but %s."):format(short(sender), whyNot(fam, s.family)))
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

local function needGame()
    local fam = family()
    if fam then return fam end
    if machine and not machine.linkPlug and MB.Cable.Changed(machine) then
        Print("This copy of the game is not the one the link knows: it is another version, or it has been modified. The link is switched off for it, so that nothing gets corrupted.")
    else
        Print("Start your game on the MekkaBoy first. The link works with " .. GAMES_TEXT .. ".")
    end
end
-- /mb link <name> or /mb link target: no party, whispers to that one player
local function callByName(who)
    local cands = {}
    if who:lower() == "target" then
        if not (UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target")) then Print("Target a player first, then /mb link target.") return end
        cands = unitSpellings("target")
    else
        spellings(cands, who)
    end
    if #cands == 0 then Print("Could not work out that player's name.") return end
    for _, name in ipairs(cands) do if isMyself(name) then Print("That is you.") return end end
    local fam = needGame()
    if not fam then return end
    if tableSeats() >= 3 then Print("This game seats a table: tables still need a party for now.") return end
    session = { id = math.random(1, 120), host = true, state = "calling", family = fam, candidates = cands, partner = cands[1],
                since = clockNow(), lastInvite = -100 }
    ticker:Show()
    Print(("Calling %s (no party needed). They type /mb link to answer: they need MekkaBoy open with a game running."):format(short(cands[1])))
end

function Link.Open(who)
    who = who or ""
    if not (MB.Cable and MB.Wire and MB.AdvanceCable) then Print("The link is not installed properly: restart the game client.") return end
    if session and session.state == "calling" then Print(("Still calling %s... /mb link off stops."):format(short(session.partner))) return end
    if session and session.state == "answering" then Print(("Still answering %s..."):format(short(session.partner))) return end
    if session and session.members then
        local s, names = session, {}
        for k = 1, s.seats - 1 do if s.members[k] then names[#names + 1] = short(s.members[k].name) end end
        Print(("Your table: %d of %d seats taken%s. /mb link off closes it."):format(#names + 1, s.seats,
            #names > 0 and (" (" .. table.concat(names, ", ") .. ")") or ""))
        return
    end
    if session and session.state == "seating" then Print(("Still asking %s for a seat..."):format(short(session.partner))) return end
    if session and session.state == "linked" then
        local s = session
        if s.table then Print(("At %s's table, seat %d. /mb link off leaves it."):format(short(s.partner), s.seat)) return end
        Print(("Linked with %s (%s%s). /mb link off ends it."):format(short(s.partner), s.host and "you lead" or "they lead", s.route and ", over whispers" or ""))
        print(("  messages sent %d (%d of them twice or more, %d turned back by the server); game %s"):format(s.wire.frames, s.wire.resent, s.wire.refused,
            s.ghost and (s.ghost:busy() and ("in a link session, " .. s.ghost.phase) or "not in a link session yet") or "not running or not supported"))
        return
    end
    if session then Print("Still looking for the other MekkaBoy...") return end
    local KEYWORD = { party = true, yes = true, on = true, accept = true, answer = true, join = true }
    if KEYWORD[who:lower()] then who = "" end
    -- /mb link <name> when that player has just invited you: answer them rather than calling back
    local h
    if who ~= "" then
        latestInvite()
        for _, inv in pairs(heardW) do if nameIs(inv.sender, who) then h = inv end end
        if not h then callByName(who) return end
    elseif not (IsInGroup and IsInGroup()) then
        h = latestInvite()                       -- (in a party, /mb link is the party link, exactly as before)
    end
    if h then
        local fam = needGame()
        if not fam then return end
        heardW[plain(h.sender)] = nil
        if not fits(h.family, fam) then
            Print(("%s %s."):format(short(h.sender), whyNot(h.family, fam)))
            return
        end
        answer(h, fam)
        return
    end
    if not (IsInGroup and IsInGroup()) then
        Print("Join a party with the other player, or link without one: /mb link <their name> (or target them and /mb link target).")
        return
    end
    local fam = needGame()
    if not fam then return end
    local seats = tableSeats()
    if seats >= 3 and not MB.Alpha() then
        Print("This game's party table is still being tested and comes in a later version. Play it on your own for now.")
        return
    end
    if seats >= 3 then
        -- this game seats more than two: sit at the table someone has open, or open one
        if heard and heard.table and clockNow() - heard.at < INVITE_FOR then
            local h = heard
            heard = nil
            if h.code ~= gameCode() then
                Print(("%s's table is for another game. Start the same game to sit down."):format(short(h.sender)))
                return
            end
            askForSeat(h, fam)
            return
        end
        openTable(seats)
        return
    end
    if heard and heard.table then
        if clockNow() - heard.at < INVITE_FOR then
            Print(("%s's table is for another game. Start the same game to sit down."):format(short(heard.sender)))
            return
        end
        heard = nil
    end
    if heard and clockNow() - heard.at < INVITE_FOR then
        local h = heard
        heard = nil
        if not fits(h.family, fam) then
            Print(("%s %s."):format(short(h.sender), whyNot(h.family, fam)))
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
    local s = session
    if s.state == "calling" or s.state == "answering" then
        for _, name in ipairs(s.candidates or s.cands or {}) do send("LX" .. string.char(s.id), "WHISPER", name) end
        session = nil
        ticker:Hide()
        Print("Stopped.")
        return
    end
    unlink(session.members and "Your table is closed." or "Link ended.", session.state == "linked" or session.table)
end

MB.AddCommand("link", "link - join the other MekkaBoy in your party, to trade and battle; link <name>|target links without a party; link off ends it", function(rest)
    local word = rest:lower()
    if word == "off" or word == "end" or word == "stop" then Link.Close() else Link.Open(rest) end
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

-- A whisper to a spelling of a name nobody has (or to a friend who is offline) makes the server say "No player
-- named ... is currently playing." MekkaBoy whispers several spellings on purpose, so those lines are kept out of
-- the chat window when the name is one it whispered in the last ten seconds, and the spelling is noted as unreachable.
do
    local fmt = type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
    local pattern = "^" .. fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
    -- The line names one spelling. Only that one is unreachable: "Ana-Lyse" not being found says nothing about
    -- "Ana Lyse" (nameIs would call them the same player, and the spelling that works would be shut off too).
    local function sameSpelling(w, name)
        local a, b = w:lower(), name:lower()
        if a == b then return true end
        local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
        if type(r) ~= "string" or r == "" then return false end
        r = "-" .. r:lower()
        return a == b .. r or b == a .. r
    end
    Link.SameSpelling = sameSpelling
    local function ours(msg)
        if type(msg) ~= "string" then return false end
        local name = msg:match(pattern)
        if not name then return false end
        local hit = false
        for w, t in pairs(whispered) do
            if GetTime() - t > 10 then whispered[w] = nil
            elseif sameSpelling(w, name) then unreachable[w] = GetTime() hit = true end
        end
        return hit
    end
    Link.NotFoundLine = ours
    local seen = CreateFrame("Frame")                -- (noted even when no chat window shows system lines)
    seen:RegisterEvent("CHAT_MSG_SYSTEM")
    seen:SetScript("OnEvent", function(_, _, msg) pcall(ours, msg) end)
    if ChatFrame_AddMessageEventFilter then          -- (and kept out of the chat windows)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
            if type(msg) ~= "string" or not msg:match(pattern) then return false end
            local name = msg:match(pattern)
            for w in pairs(unreachable) do if GetTime() - unreachable[w] < 10 and nameIs(w, name) then return true end end
            return ours(msg)
        end)
    end
end
