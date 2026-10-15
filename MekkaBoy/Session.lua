-- Opening and closing the console, the flight-path trigger and countdown,
-- combat and ready-check manners, and the slash commands.
local _, MB = ...

local win = MB.window
local DB, Print = MB.DB, MB.Print

-- ---------- show / hide ----------
local shownByTaxi = false

function MB.Show(auto)
    -- The open console keeps the whole keyboard, so it stays shut in combat.
    if InCombatLockdown() then
        if not auto then Print("stays shut while you are in combat.") end
        return
    end
    shownByTaxi = auto and true or false
    win:Show()
end

function MB.Hide()
    win:Hide()
end

function MB.Toggle()
    if win:IsShown() then MB.Hide() else MB.Show(false) end
end

win:HookScript("OnHide", function() shownByTaxi = false end)

-- for the Key Bindings menu (Bindings.xml) and the addon menu by the minimap
function MekkaBoy_Toggle() MB.Toggle() end
function MekkaBoy_Options() if MB.OpenOptions then MB.OpenOptions() end end
function MekkaBoy_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then MekkaBoy_Options() else MB.Toggle() end
end
BINDING_HEADER_MEKKABOY = "MekkaBoy"
BINDING_NAME_MEKKABOY_TOGGLE = "Open or close the console"
BINDING_NAME_MEKKABOY_OPTIONS = "Open MekkaBoy's settings"

-- ---------- things that need you ----------
-- While you play, the world goes on: a ready check, a dungeon group forming,
-- a summon. Each of these stops the game and says why on its screen, so the
-- console is never the reason you missed one. Each can be switched off
-- (settings, or /mb pause). A whisper only leaves a note on the status plate.
local TRIGGERS = { "ready", "queue", "summon", "resurrect", "invite", "duel", "trade", "landing" }
MB.PAUSE_TRIGGERS = TRIGGERS
function MB.PausesOn(key)
    local t = DB().opt.pauseOn
    return not (t and t[key] == false)
end
function MB.SetPauseOn(key, on)
    local db = DB()
    db.opt.pauseOn = db.opt.pauseOn or {}
    db.opt.pauseOn[key] = on and true or false
end
MB.attentionSeen = {}       -- which manners fired this session, for /mb bug
function MB.Attention(key, reason)
    if not win:IsShown() or not MB.PausesOn(key) then return false end
    MB.attentionSeen[key] = (MB.attentionSeen[key] or 0) + 1
    if not (MB.PauseFor and MB.PauseFor(reason)) then
        if MB.Note then MB.Note(reason) end         -- already paused: the plate says it
    end
    return true
end

-- ESC closes the console (when it isn't holding the keyboard).
if UISpecialFrames then
    table.insert(UISpecialFrames, "MekkaBoyWindow")
end

-- ---------- flight paths: auto-open and countdown ----------
-- The game does not tell addons how long a flight takes, so each route is
-- timed the first time you fly it and counted down from then on.
local flight = nil      -- the flight in progress
local pending = nil     -- the route just picked at a flight master

local function clockText(sec)
    if sec < 0 then sec = 0 end
    sec = math.floor(sec + 0.5)
    return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

if hooksecurefunc and TakeTaxiNode and TaxiNodeName and NumTaxiNodes and TaxiNodeGetType then
    hooksecurefunc("TakeTaxiNode", function(slot)
        local ok, dst = pcall(TaxiNodeName, slot)
        if not ok or type(dst) ~= "string" then return end
        local src
        for i = 1, NumTaxiNodes() do
            if TaxiNodeGetType(i) == "CURRENT" then src = TaxiNodeName(i) break end
        end
        if type(src) == "string" and src ~= dst then
            pending = { key = src .. " > " .. dst, rev = dst .. " > " .. src, dst = dst, at = GetTime() }
        end
    end)
end

local function updateGauge()
    if not flight then
        MB.SetFlight(nil, nil)
        return
    end
    local elapsed = GetTime() - flight.start
    local total = flight.known or flight.guess
    if not total then
        -- first time on this route: no countdown yet, so show time in the air
        MB.SetFlight(clockText(elapsed) .. (flight.key and " (timing)" or ""), nil)
        return
    end
    local left = total - elapsed
    local text
    if left <= 0 then
        text = "|cffb01818landing|r"
    else
        text = (flight.known and "" or "~") .. clockText(left)
        if left <= 15 then text = "|cffb01818" .. text .. "|r" end
    end
    MB.SetFlight(text, left / total)
end

-- seconds left in the current flight (nil when not flying or not yet timed)
function MB.FlightRemaining()
    if not flight then return nil end
    local total = flight.known or flight.guess
    return total and (total - (GetTime() - flight.start)) or nil
end

local poll = CreateFrame("Frame")
local acc = 0
local wasOnTaxi = false
poll:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.25 then return end
    acc = 0
    local onTaxi = UnitOnTaxi("player") and true or false
    if onTaxi ~= wasOnTaxi then
        wasOnTaxi = onTaxi
        local now = GetTime()
        if onTaxi then
            flight = { start = now }
            if pending and now - pending.at < 15 then
                local db = DB()
                flight.key = pending.key
                flight.known = db.flights[pending.key]
                flight.guess = db.flights[pending.rev]
            end
            pending = nil
            -- no chat messages: the console appearing says it all
            if MB.Opt("auto", true) and not win:IsShown() then MB.Show(true) end
        else
            if flight and flight.key then
                local took = now - flight.start
                if took > 5 then DB().flights[flight.key] = math.floor(took * 10 + 0.5) / 10 end
            end
            flight = nil
            updateGauge()
            if win:IsShown() and shownByTaxi then MB.Hide()
            elseif win:IsShown() then MB.Attention("landing", "You have landed") end
        end
    end
    if flight then updateGauge() end
end)

-- ---------- slash commands ----------
MB.AddCommand("auto", "auto on|off - open by itself on flight paths", function(rest)
    local db = DB()
    if rest == "on" then db.opt.auto = true elseif rest == "off" then db.opt.auto = false
    else db.opt.auto = not MB.Opt("auto", true) end
    Print("Opening on flight paths is " .. (db.opt.auto and "on." or "off."))
end)

MB.AddCommand("flights", "flights - list the flight times learned so far", function()
    local names = {}
    for k in pairs(DB().flights) do names[#names + 1] = k end
    table.sort(names)
    if #names == 0 then
        Print("No flight times learned yet. Each route is timed the first time you fly it.")
        return
    end
    Print(#names .. " route(s) timed:")
    for _, k in ipairs(names) do print(("  %s  %s"):format(clockText(DB().flights[k]), k)) end
end)

MB.AddCommand("center", "center - bring the console back to the middle of the screen", function()
    DB().opt.pos = nil
    MB.RestorePosition()
    Print("Back in the middle.")
end)

MB.AddCommand("help", "help - this list", function()
    Print("/mb opens or closes the console. Commands:")
    for _, name in ipairs(MB.commandOrder) do print("  /mb " .. MB.commands[name].help) end
end)

SLASH_MEKKABOY1 = "/mb"
SLASH_MEKKABOY2 = "/mekkaboy"
SLASH_MEKKABOY3 = "/gbc"
SlashCmdList["MEKKABOY"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    if msg == "" then
        MB.Toggle()
        return
    end
    local name, rest = msg:match("^(%S+)%s*(.-)$")
    local cmd = MB.commands[name:lower()]
    if cmd then
        cmd.run(rest)
    else
        Print("Unknown command. /mb help lists them.")
    end
end

MB.AddCommand("pause", "pause <ready|queue|summon|resurrect|invite|duel|trade|landing|whisper> on|off - what stops the game for you (all on to begin with)", function(rest)
    local key, v = rest:lower():match("^(%a+)%s*(%a*)$")
    local known = key == "whisper"
    for _, k in ipairs(TRIGGERS) do known = known or k == key end
    if not known then
        local parts = {}
        for _, k in ipairs(TRIGGERS) do parts[#parts + 1] = k .. (MB.PausesOn(k) and " on" or " off") end
        Print("The game pauses for: " .. table.concat(parts, ", ") .. ". A note for whispers: " .. (MB.Opt("whisperNote", true) and "on" or "off") .. ".")
        print("  /mb pause <one of those, or whisper> on|off changes it.")
        return
    end
    if key == "whisper" then
        local on = (v == "on") or (v ~= "off" and not MB.Opt("whisperNote", true))
        DB().opt.whisperNote = on
        Print("A note on the console when someone whispers you: " .. (on and "on." or "off."))
        return
    end
    local on = (v == "on") or (v ~= "off" and not MB.PausesOn(key))
    MB.SetPauseOn(key, on)
    Print(("Pausing for %s: %s"):format(key, on and "on." or "off."))
end)

-- ---------- events ----------
local events = CreateFrame("Frame")
-- (a game client that does not know one of these events must not stop the others from being heard)
for _, name in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_DISABLED", "READY_CHECK", "LFG_PROPOSAL_SHOW", "LFG_ROLE_CHECK_SHOW",
                        "UPDATE_BATTLEFIELD_STATUS", "CONFIRM_SUMMON", "PARTY_INVITE_REQUEST", "RESURRECT_REQUEST", "DUEL_REQUESTED",
                        "TRADE_SHOW", "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER" }) do
    pcall(events.RegisterEvent, events, name)
end
local battlefieldTold = {}
local function shortName(name)
    if type(name) ~= "string" then return nil end
    return (name:gsub("%-[^%-]*$", ""))
end
events:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_LOGIN" then
        local db = DB()
        db.migrated = nil -- left over from the move out of the old addon
        for _, fn in ipairs(MB.onLogin) do fn() end
        MB.ApplyScale()
        MB.RestorePosition()
        -- Say hello once, then stay out of the chat window for good.
        if not db.introShown then
            db.introShown = true
            Print("installed. Type /mb to play; it also opens by itself on flight paths.")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Combat: put the console away without a word (the game pauses and is
        -- kept). It stays away until you ask for it again with /mb, or take
        -- your next flight: one fight ending does not mean you are ready to play.
        if win:IsShown() then MB.Hide() end
    elseif event == "READY_CHECK" then
        MB.Attention("ready", "Ready check")
    elseif event == "LFG_PROPOSAL_SHOW" then
        MB.Attention("queue", "Your group is ready")
    elseif event == "LFG_ROLE_CHECK_SHOW" then
        MB.Attention("queue", "Role check")
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        if not GetBattlefieldStatus then return end
        for i = 1, (GetMaxBattlefieldID and GetMaxBattlefieldID() or 3) do
            local ok, status = pcall(GetBattlefieldStatus, i)
            local confirm = ok and status == "confirm"
            if confirm and not battlefieldTold[i] then MB.Attention("queue", "Your battleground is ready") end
            battlefieldTold[i] = confirm or nil
        end
    elseif event == "CONFIRM_SUMMON" then
        MB.Attention("summon", "You are being summoned")
    elseif event == "PARTY_INVITE_REQUEST" then
        local who = shortName(a1)
        MB.Attention("invite", who and ("Group invite from " .. who) or "Group invite")
    elseif event == "RESURRECT_REQUEST" then
        local who = shortName(a1)
        MB.Attention("resurrect", who and (who .. " offers to resurrect you") or "A resurrection is offered")
    elseif event == "DUEL_REQUESTED" then
        local who = shortName(a1)
        MB.Attention("duel", who and (who .. " challenges you to a duel") or "A duel challenge")
    elseif event == "TRADE_SHOW" then
        MB.Attention("trade", "A trade window has opened")
    else    -- a whisper: a note on the plate, the game carries on
        if win:IsShown() and MB.Opt("whisperNote", true) and MB.Note then
            local ok, who = pcall(shortName, a2)
            if event ~= "CHAT_MSG_WHISPER" then who = nil end     -- (a Battle.net sender is not a name we can show)
            MB.Note((ok and who) and ("Whisper from " .. who) or "Someone whispered you")
        end
    end
end)
