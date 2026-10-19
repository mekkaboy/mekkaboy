-- Finding other MekkaBoys on the realm without a party. For now a test of the line itself:
-- /mb lobby test joins a quiet chat channel for a minute and notes who it hears there, and how.
-- Run it at the same time as a friend (not in your party). It answers the question a realm-wide
-- lobby depends on: do hidden addon messages on a custom chat channel reach other players here?
-- /mb lobby say (typed, so it counts as your own key press) also sends one plain text line, the
-- fallback if the hidden kind does not arrive; MekkaBoy hides those lines from your chat window.
local _, MB = ...
local Lobby = {}
MB.Lobby = Lobby
local Print = MB.Print
local CHANNEL = "MekkaBoyLobby"
local MARK = "~MB~"                 -- the start of a plain text line meant for MekkaBoys, never shown
local LENGTH, EVERY = 60, 5         -- seconds the test runs, seconds between hidden messages

local run                           -- the test running now
local function now() return GetTime() end
local function chanNumber()
    if not GetChannelName then return 0 end
    local n = GetChannelName(CHANNEL)
    return type(n) == "number" and n or 0
end
local function game()
    local key, _, running = MB.CurrentCart()
    if running and key then return (tostring(key):gsub("[;|]", "")) end
    return "-"
end
local function note(how, sender, text)
    if not run then return end
    local key = MB.Link.Plain(sender)
    local h = run.heard[key]
    if not h then
        h = { name = sender, hidden = 0, text = 0 }
        run.heard[key] = h
        if not MB.Link.IsMe(sender) then
            Print(("Heard %s on the lobby channel (%s)."):format(sender, how == "hidden" and "a hidden message" or "a plain line"))
            -- (someone new: keep the test going a little longer, so that a late starter is counted too)
            run.started = math.max(run.started, now() - (LENGTH - 20))
        end
    end
    h[how] = h[how] + 1
    h.last = text
    if MB.Link.IsMe(sender) then run.echo = run.echo or how end
end

-- the hidden kind: "Q000<version>;<game>;<count>" (arrives through GB/Link.lua)
function Lobby.Heard(text, channel, sender)
    if channel ~= "CHANNEL" then return end
    note("hidden", sender, text:sub(5))
end

local function finish()
    local r = run
    run = nil
    if LeaveChannelByName and not r.wasIn then pcall(LeaveChannelByName, CHANNEL) end      -- (not if you were in it before)
    MB.DB().lobbyJoined = nil
    local others, lines = 0, {}
    for _, h in pairs(r.heard) do
        if not MB.Link.IsMe(h.name) then
            others = others + 1
            lines[#lines + 1] = ("  %s: %d hidden, %d plain"):format(h.name, h.hidden, h.text)
        end
    end
    Print(("Lobby test over: %d hidden messages sent (%d turned back by the server)%s. Heard from %d other MekkaBoy%s."):format(
        r.sent, r.refused, r.echo and (", my own came back (" .. r.echo .. ")") or ", my own never came back", others, others == 1 and "" or "s"))
    for _, l in ipairs(lines) do print(l) end
    if others == 0 then Print("Nobody heard. If a friend ran it at the same time, the hidden channel route does not work here between players.") end
    local db = MB.DB()
    db.lobbyTests = db.lobbyTests or {}
    local rec = { when = date and date("%Y-%m-%d %H:%M") or "", sent = r.sent, refused = r.refused, echo = r.echo, joined = r.joined,
                  said = r.said, heard = {}, faction = UnitFactionGroup and UnitFactionGroup("player") or nil, returns = r.returns }
    for _, h in pairs(r.heard) do rec.heard[#rec.heard + 1] = { name = h.name, hidden = h.hidden, text = h.text } end
    table.insert(db.lobbyTests, rec)
    while #db.lobbyTests > 10 do table.remove(db.lobbyTests, 1) end
    Lobby.last = rec
end

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local r = run
    if not r then ticker:Hide() return end
    local t = now()
    local n = chanNumber()
    if n > 0 and not r.joined then
        r.joined = t - r.started
        if ChatFrame_RemoveChannel and DEFAULT_CHAT_FRAME then pcall(ChatFrame_RemoveChannel, DEFAULT_CHAT_FRAME, CHANNEL) end
        Print("Joined the lobby channel. Type /mb lobby say once too (one plain line, hidden from chat windows).")
    end
    if n > 0 and t >= r.next then
        r.next = t + EVERY
        r.sent = r.sent + 1
        local why = MB.Link.Send(("Q000%s;%s;%d"):format(MB.VERSION, game(), r.sent), "CHANNEL", n, 5)
        r.returns[tostring(why or "ok")] = (r.returns[tostring(why or "ok")] or 0) + 1
        if why then r.refused = r.refused + 1 end
    end
    if t - r.started >= LENGTH then finish() end
end)

function Lobby.Test()
    if run then Print(("The lobby test is running: %d s left."):format(math.max(0, math.floor(LENGTH - (now() - run.started))))) return end
    if not JoinTemporaryChannel then Print("This game client cannot join chat channels.") return end
    run = { started = now(), next = now() + 2, sent = 0, refused = 0, heard = {}, returns = {}, wasIn = chanNumber() > 0 and not MB.DB().lobbyJoined }
    MB.DB().lobbyJoined = true
    pcall(JoinTemporaryChannel, CHANNEL)
    ticker:Show()
    Print(("Lobby test: joining the %s channel for a minute. Ask a friend (not in your party) to type /mb lobby test now too."):format(CHANNEL))
end

function Lobby.Say()
    if not run then Print("Start the test first: /mb lobby test.") return end
    local n = chanNumber()
    if n == 0 then Print("Not in the lobby channel yet: wait a second and try again.") return end
    if not SendChatMessage then return end
    local ok = pcall(SendChatMessage, ("%sQ%s;%s"):format(MARK, MB.VERSION, game()), "CHANNEL", nil, n)
    run.said = ok and "sent" or "refused"
    -- (a blocked send does not raise an error here: whether it went shows only in who heard it)
    Print(ok and "One plain line sent to the lobby channel (if the game allowed it: the result shows who heard it)." or "The game would not send the line.")
end

-- plain lines: count ours, and keep them out of every chat window
do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHAT_MSG_CHANNEL")
    local function lobbyLine(text, chanName, chanString)
        if type(text) ~= "string" or text:sub(1, #MARK) ~= MARK then return false end
        local where = (type(chanName) == "string" and chanName ~= "" and chanName) or (type(chanString) == "string" and chanString) or ""
        return where:lower():find(CHANNEL:lower(), 1, true) ~= nil       -- (only in our own channel)
    end
    ev:SetScript("OnEvent", function(_, _, text, sender, _, chanString, _, _, _, _, chanName)
        if lobbyLine(text, chanName, chanString) and type(sender) == "string" then note("text", sender, text:sub(#MARK + 1)) end
    end)
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, text, _, _, chanString, _, _, _, _, chanName)
            return lobbyLine(text, chanName, chanString)
        end)
    end
end

MB.onLogin[#MB.onLogin + 1] = function()
    -- (a test cut short by a reload leaves you in the channel: out of it)
    if MB.DB().lobbyJoined and LeaveChannelByName then pcall(LeaveChannelByName, CHANNEL) MB.DB().lobbyJoined = nil end
end

MB.AddCommand("lobby", "lobby test - a minute on a quiet realm channel, to see which other MekkaBoys it reaches; lobby say sends one plain line", function(rest)
    local word = (rest or ""):lower()
    if word == "say" then Lobby.Say() elseif word == "test" or word == "" then Lobby.Test() else Print("/mb lobby test, then /mb lobby say.") end
end)
