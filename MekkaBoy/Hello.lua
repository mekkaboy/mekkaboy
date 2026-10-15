-- Two MekkaBoys in the same group tell each other which version they are.
-- Whoever is behind gets one line saying so; nobody else hears a thing. The
-- link itself is only refused when the two speak different link protocols
-- (MB.PROTOCOL), which is rarer than a version change.
--
-- The message rides on the link's own hidden line (GB/Link.lua), kind "V":
--   V000<version>;<protocol>;q     "this is me; who are you?"
--   V000<version>;<protocol>;a     "this is me" (an answer: nobody answers an answer)
-- Copies from before this file existed ignore it, and are taken to speak protocol 1.
local _, MB = ...

local Hello = {}
MB.Hello = Hello
local Print = MB.Print

local peers = {}            -- plain name -> { name =, version =, protocol =, at = }
local toldNewer = {}        -- versions we have already been told about this session
local toldCannot = {}       -- plain name -> when we last said "cannot link"
local lastAsk, lastAnswer, lastCount = -100, -100, 0

local function plain(name) return MB.Link.Plain(name) end
local function short(name) return (tostring(name):gsub("%-[^%-]*$", "")) end

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

local function channel()
    if not (IsInGroup and IsInGroup()) then return nil end
    if IsInRaid and IsInRaid() then return "RAID" end
    return "PARTY"
end

local function say(kind)
    local ch = channel()
    if not (ch and MB.Link and MB.Link.Send) then return end
    MB.Link.Send(("V000%s;%d;%s"):format(MB.VERSION, MB.PROTOCOL, kind), ch)
end

function Hello.Heard(rest, _, sender)
    if MB.Link.IsMe(sender) then return end
    local version, protocol, kind = rest:match("^([%w%.%-]+);(%d+);([qa])$")
    if not version or #version > 24 then return end
    peers[plain(sender)] = { name = sender, version = version, protocol = tonumber(protocol), at = GetTime() }
    if kind == "q" and GetTime() - lastAnswer > 5 then      -- (several people asking at once get one answer between them)
        lastAnswer = GetTime()
        say("a")
    end
    if Hello.Newer(version, MB.VERSION) and not toldNewer[version] then
        toldNewer[version] = true
        Print(("%s has a newer MekkaBoy (%s; yours is %s). Update yours so the two match."):format(short(sender), version, MB.VERSION))
    end
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
    Print(("%s's MekkaBoy (%s) and yours (%s) cannot link with each other: %s the newer version."):format(short(name), p.version, MB.VERSION, who))
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
    if C_Timer and C_Timer.After then C_Timer.After(2, ask) else ask() end
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GROUP_ROSTER_UPDATE")
pcall(ev.RegisterEvent, ev, "PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", soon)

MB.AddCommand("version", "version - your MekkaBoy's version, and those of the MekkaBoys in your group", function()
    Print(("version %s (link protocol %d)."):format(MB.VERSION, MB.PROTOCOL))
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
