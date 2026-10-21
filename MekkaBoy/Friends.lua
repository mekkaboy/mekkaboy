-- Friends: who around you has MekkaBoy, what they are playing, and linking with one of them in one step.
--
-- Nothing here links by itself: the link is still GB/Link.lua's (a party link, or one over whispers to a named
-- player). This part finds the people, says whether your two games can link, and turns an invitation into a button.
--
-- Messages, on the extra addon name (lane 5, apart from a link's own traffic), kind "F":
--   F?00                                               "do you have MekkaBoy? what are you playing?"
--   F!00<version>;<protocol>;<family>;<state>;<game>   "this is me" (always whispered back to whoever asked)
--     state: ready (a game running), paused (a game in, console closed), linked, off (no game)
--   Fc / Fd / FC / FD / FN  the team card and the Pokedex: asked, answered, kept private (Card.lua wraps Heard for them)
-- Who gets an answer is the player's choice, How I play (/mb play, and the settings): Open (the default) answers anyone
-- who targets you, or shares your group or guild; Friends only keeps it to the people you already know in WoW (your
-- group, your friends list, your guild, and players you have linked with); Solo answers nobody and asks nobody. Asking is never done in a loop:
-- once when you target a player, when your group or guild changes, and when you open the list.
local _, MB = ...

local Friends = {}
MB.Friends = Friends
local Print = MB.Print
local LANE = 5
local PEER_TTL = 900                 -- what someone told us is kept this long (seconds)
local ASK_TARGET_EVERY = 60          -- the same target is asked at most once a minute
local ASK_GROUP_EVERY, ASK_GUILD_EVERY, ASK_FRIEND_EVERY = 300, 120, 300
local ANSWER_EVERY = 10              -- one answer per asker every 10 s at most
local INVITE_SHOWN = 85              -- an invitation's pop-up stays this long (the link waits 90 s)

local peers = {}                     -- plain name -> { name, version, protocol, family, state, game, at, via }
local askedAt, answeredAt = {}, {}   -- plain name -> when
local lastGroupAsk, lastGuildAsk, lastFriendsAsk, lastGroupCount = -1000, -1000, -1000, 0
local queue = {}                     -- whispers waiting their turn (friends list asks are spaced out)
local guildNames = {}                -- plain name -> true
local calling                        -- { name, at }: the player we just asked to link
local outcome                        -- { name, text, at }: how that went, shown for a while

local function now() return GetTime() end
local function plain(name) return MB.Link.Plain(name) end
local function short(name) return MB.Link.Short(name) end
local function db() return MB.DB() end
local SHARE_OF = { open = "everyone", friends = "known", solo = "off" }
local function share() return SHARE_OF[MB.PlayMode()] or "everyone" end      -- (MB.PlayMode: How I play, MekkaBoy.lua)
local function send(text, channel, target) return MB.Link.Send(text, channel, target, LANE) end

-- ---- what this MekkaBoy says about itself ----
local function myState()
    local s = MB.Link.Session and MB.Link.Session()
    if s and s.state == "linked" then return "linked" end
    local id, _, running = MB.CurrentCart()
    if not id then return "off" end
    if running and MB.window and MB.window:IsShown() then return "ready" end
    return "paused"
end
local function myGame()
    local id = MB.CurrentCart()
    local c = id and MB.Carts and MB.Carts.Find and MB.Carts.Find(id)
    return c and c.name or ""
end
local function myFamily() return (MB.Link.Family and MB.Link.Family()) or "" end
local function clean(t) return (tostring(t or ""):gsub("[;%c]", " "):sub(1, 40)) end
local function me()
    return ("F!00%s;%d;%s;%s;%s"):format(clean(MB.VERSION), MB.PROTOCOL, clean(myFamily()), myState(), clean(myGame()))
end
Friends.Me = me

-- ---- who counts as someone you know ----
local function inGroup(name)
    if not (IsInGroup and IsInGroup()) then return false end
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local kind = (IsInRaid and IsInRaid()) and "raid" or "party"
    for i = 1, (kind == "raid" and n or n - 1) do
        local u = kind .. i
        local who, realm = UnitName and UnitName(u)
        if who and MB.Link.NameIs(name, (realm and realm ~= "") and (who .. "-" .. realm) or who) then return true end
    end
    return false
end
local function isFriend(name)
    if not (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex) then return false end
    for i = 1, C_FriendList.GetNumFriends() or 0 do
        local f = C_FriendList.GetFriendInfoByIndex(i)
        if f and f.name and MB.Link.NameIs(name, f.name) then return true end
    end
    return false
end
local function linkedBefore(name)
    for _, r in ipairs(db().friendsRecent or {}) do if MB.Link.NameIs(name, r.name) then return true end end
    return false
end
local function known(name, channel)
    if channel == "GUILD" or channel == "PARTY" or channel == "RAID" then return true end
    return guildNames[plain(name)] or inGroup(name) or isFriend(name) or linkedBefore(name) or false
end
Friends.Known = known

-- ---- asking ----
local function askName(name, why)
    if share() == "off" or not name or MB.Link.IsMe(name) then return end
    local key = plain(name)
    local every = (why == "target" and ASK_TARGET_EVERY) or (why == "refresh" and 10) or ASK_FRIEND_EVERY   -- (refresh: you asked)
    if askedAt[key] and now() - askedAt[key] < every then return end
    askedAt[key] = now()
    for i, spelling in ipairs(MB.Link.Spellings(name)) do
        if i > 3 then break end
        if not MB.Link.Unreachable(spelling) then queue[#queue + 1] = spelling end
    end
end
local function askTarget()
    if share() == "off" or not (UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target")) then return end
    if UnitIsUnit and UnitIsUnit("target", "player") then return end
    local spellings = MB.Link.UnitSpellings("target")
    if #spellings == 0 then return end
    local key = plain(spellings[1])
    if askedAt[key] and now() - askedAt[key] < ASK_TARGET_EVERY then return end
    askedAt[key] = now()
    for i, s in ipairs(spellings) do if i <= 3 and not MB.Link.Unreachable(s) then queue[#queue + 1] = s end end
end
local function askGroup(force)
    if share() == "off" or not (IsInGroup and IsInGroup()) then lastGroupCount = 0 return end
    local count = GetNumGroupMembers and GetNumGroupMembers() or 2
    local grew = count > lastGroupCount
    lastGroupCount = count
    if not force and not grew and now() - lastGroupAsk < ASK_GROUP_EVERY then return end
    if now() - lastGroupAsk < 10 then return end
    lastGroupAsk = now()
    send("F?00", (IsInRaid and IsInRaid()) and "RAID" or "PARTY")
end
local function askGuild(force)
    if share() == "off" or not (IsInGuild and IsInGuild()) then return end
    if now() - lastGuildAsk < (force and 30 or ASK_GUILD_EVERY) then return end
    lastGuildAsk = now()
    send("F?00", "GUILD")
end
local function askFriends()
    if share() == "off" or not (C_FriendList and C_FriendList.GetNumFriends) then return end
    if now() - lastFriendsAsk < 30 then return end
    lastFriendsAsk = now()
    local n = 0
    for i = 1, C_FriendList.GetNumFriends() or 0 do
        local f = C_FriendList.GetFriendInfoByIndex(i)
        if f and f.connected and f.name and n < 50 then n = n + 1 askName(f.name, "friend") end
    end
end
-- everyone we know of, asked again (the list was opened)
local function askAll()
    askGroup(true) askGuild(true) askFriends()
    for _, p in pairs(peers) do askName(p.name, "refresh") end
    for _, r in ipairs(db().friendsRecent or {}) do askName(r.name, "refresh") end
end
Friends.AskAll = askAll

-- ---- hearing ----
function Friends.Heard(text, channel, sender)
    if MB.Link.IsMe(sender) then return end
    local what = text:sub(2, 2)
    if what == "?" then
        if share() == "off" then return end
        if share() ~= "everyone" and not known(sender, channel) then return end
        local key = plain(sender)
        if answeredAt[key] and now() - answeredAt[key] < ANSWER_EVERY then return end
        answeredAt[key] = now()
        send(me(), "WHISPER", sender)                  -- (always back to the one who asked, never to the whole guild)
    elseif what == "!" then
        local version, protocol, family, state, game = text:sub(5):match("^([^;]*);(%d+);([^;]*);(%a+);(.*)$")
        if not version then return end
        peers[plain(sender)] = { name = sender, version = version, protocol = tonumber(protocol), family = family ~= "" and family or nil,
                                 state = state, game = game, at = now(), via = channel }
        local inv = Friends.invite
        if inv and MB.Link.NameIs(inv.sender, sender) and Friends.ShowInvite then Friends.ShowInvite(inv) end
        if MB.Trade3 and MB.Trade3.Seen then pcall(MB.Trade3.Seen, sender) end
        if Friends.Changed then Friends.Changed() end
    end
end

function Friends.Peer(name)
    local p = name and peers[plain(name)]
    if p and now() - p.at > PEER_TTL then peers[plain(name)] = nil return nil end
    return p
end
function Friends.List()
    local out = {}
    for key, p in pairs(peers) do
        if now() - p.at > PEER_TTL then peers[key] = nil else out[#out + 1] = p end
    end
    return out
end

-- ---- can our two games link? ----
-- returns ok (true / false / nil = not known yet), and a few words
function Friends.Fits(p)
    if not p then return nil, "not heard from" end
    if p.protocol ~= MB.PROTOCOL then
        return false, MB.Hello and MB.Hello.Newer(p.version, MB.VERSION) and "has a newer MekkaBoy: update yours" or "has an older MekkaBoy"
    end
    local mine = myFamily()
    if not p.family then return nil, "no game in yet" end
    if mine == "" then return nil, "start a game to link" end
    if not MB.Cable.Compatible(p.family, mine) then
        if p.family:sub(1, 6) == "native" and mine:sub(1, 6) == "native" then return false, "a different MekkaBoy game" end
        return false, "a game that can't link with yours"
    end
    if p.family ~= mine then return true, "can trade through the Time Capsule" end
    return true, "can link with you"
end

-- ---- linking ----
local function startGameThen(fn)
    if MB.IsRunning() then fn() return end
    local id = MB.CurrentCart()
    if not id then Print("Put a game in first (one that can link), then try again.") return end
    MB.PlayCart(id)
    Friends.after = { at = now() + 0.5, fn = fn }
end
-- ask that player to link (they get a pop-up)
function Friends.Call(name)
    if not name then return end
    local s = MB.Link.Session and MB.Link.Session()
    if s then
        if s.state == "linked" then Print(("You are linked with %s. /mb link off first."):format(short(s.partner))) return end
        if s.state == "calling" and MB.Link.NameIs(s.partner, name) then return end   -- (already asking them)
    end
    startGameThen(function()
        calling, outcome = { name = name, at = now() }, nil
        local inv = Friends.invite
        if inv and MB.Link.NameIs(inv.sender, name) then Friends.Accept() return end     -- (they asked us first: answer)
        if share() ~= "off" then send(me(), "WHISPER", name) end                      -- (so their pop-up can say what we play)
        MB.Link.Open(name)
        if Friends.Changed then Friends.Changed() end
    end)
end
function Friends.Cancel()
    local s = MB.Link.Session and MB.Link.Session()
    if s and (s.state == "calling" or s.state == "answering") then MB.Link.Close() end
    calling = nil
    if Friends.Changed then Friends.Changed() end
end

-- an invitation arrived (GB/Link.lua): offer it as a button
function Friends.Invited(sender, family, via, id)
    local inv = Friends.invite
    if inv and inv.id == id and MB.Link.NameIs(inv.sender, sender) and now() - inv.at < INVITE_SHOWN then return end
    if calling and MB.Link.NameIs(calling.name, sender) then return end       -- (we asked them too: Link sorts out who leads)
    Friends.invite = { sender = sender, family = family, via = via, id = id, at = now() }
    if Friends.ShowInvite then Friends.ShowInvite(Friends.invite) end
end
function Friends.Accept()
    local inv = Friends.invite
    if not inv then return end
    Friends.invite = nil
    if Friends.HideInvite then Friends.HideInvite() end
    startGameThen(function()
        if inv.via == "party" then MB.Link.Open("") else MB.Link.Open(inv.sender) end
    end)
end
function Friends.Decline()
    Friends.invite = nil
    if Friends.HideInvite then Friends.HideInvite() end
end

-- a link is up (GB/Link.lua): remember the partner
function Friends.Linked(partner)
    local list = db().friendsRecent or {}
    for i = #list, 1, -1 do if MB.Link.NameIs(list[i].name, partner) then table.remove(list, i) end end
    table.insert(list, 1, { name = partner, game = myGame(), at = time and time() or 0 })
    while #list > 8 do table.remove(list) end
    db().friendsRecent = list
    calling, outcome = nil, { name = partner, text = "linked", at = now() }
    Friends.invite = nil
    if Friends.HideInvite then Friends.HideInvite() end
    if Friends.Changed then Friends.Changed() end
end
function Friends.Recent() return db().friendsRecent or {} end

-- what is going on with that player just now, in a few words (for the list)
function Friends.Status(name)
    local s = MB.Link.Session and MB.Link.Session()
    if s and s.partner and MB.Link.NameIs(s.partner, name) then
        if s.state == "linked" then return "linked", "Linked with you" end
        if s.state == "calling" then return "calling", "Asking them to link..." end
        if s.state == "answering" then return "answering", "Linking..." end
    end
    local inv = Friends.invite
    if inv and MB.Link.NameIs(inv.sender, name) and now() - inv.at < INVITE_SHOWN then return "invited", "Wants to link with you" end
    if outcome and MB.Link.NameIs(outcome.name, name) and now() - outcome.at < 30 then return "outcome", outcome.text end
    return nil
end

-- ---- the clock: queued asks, a call that ended without a link ----
local tick = CreateFrame("Frame")
local nextSend = 0
tick:SetScript("OnUpdate", function()
    local t = now()
    if #queue > 0 and t >= nextSend then
        nextSend = t + 0.35
        send("F?00", "WHISPER", table.remove(queue, 1))
    end
    if Friends.after and t >= Friends.after.at then
        local a = Friends.after
        Friends.after = nil
        if MB.IsRunning() then a.fn() else Print("The game did not start, so the link was not tried.") end
    end
    if calling then
        local s = MB.Link.Session and MB.Link.Session()
        if not s and t - calling.at > 2 then
            outcome = { name = calling.name, text = "didn't answer", at = t }
            calling = nil
            if Friends.Changed then Friends.Changed() end
        end
    end
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE", "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local loginAt
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        askTarget()
        if Friends.TargetChanged then Friends.TargetChanged() end
    elseif event == "GROUP_ROSTER_UPDATE" then
        askGroup(false)
    elseif event == "PLAYER_LOGIN" then
        loginAt = now()
    elseif event == "GUILD_ROSTER_UPDATE" then
        guildNames = {}
        if GetNumGuildMembers and GetGuildRosterInfo then
            for i = 1, GetNumGuildMembers() or 0 do
                local name = GetGuildRosterInfo(i)
                if name then guildNames[plain(name)] = true end
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if Friends.TargetChanged then Friends.TargetChanged() end
    end
end)
-- the guild is asked once, a little after logging in (when the roster has arrived)
local guildLater = CreateFrame("Frame")
guildLater:SetScript("OnUpdate", function(f)
    if loginAt and now() - loginAt > 15 then
        f:SetScript("OnUpdate", nil)
        askGuild(false)
        if GuildRoster then pcall(GuildRoster) elseif C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
    end
end)

-- ---- commands ----
local OLD_SHARE = { everyone = "open", known = "friends", off = "solo" }
local function playCommand(arg)
    arg = (arg or ""):lower()
    arg = OLD_SHARE[arg] or (arg == "friends only" and "friends") or arg
    if arg ~= "" and not MB.SetPlayMode(arg) then
        Print("/mb play open (anyone who targets you), friends (only people you know), or solo (nobody, and Together off).")
        return
    end
    Print("How you play: " .. MB.PLAY_LINES[MB.PlayMode()])
end
MB.AddCommand("play", "play open|friends|solo - how you play: open to anyone who targets you, friends only, or solo", playCommand)
MB.AddCommand("friends", "friends - who around you has MekkaBoy, and link with one in a click (/mb play sets who can see you)", function(rest)
    local word, arg = (rest or ""):match("^(%S*)%s*(.*)$")
    word = (word or ""):lower()
    if word == "share" then playCommand(arg) return end            -- (the 0.20.3 test builds' name for it)
    if word ~= "" then Friends.Call(rest) return end
    if Friends.Open then Friends.Open() end
end)
