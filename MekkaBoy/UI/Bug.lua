-- /mb bug: a short, paste-ready description of this MekkaBoy for a bug report.
-- It says what was running and how, and nothing about who: no character, realm,
-- guild or party names, and no chat. Paste it into mekkaboy.com/feedback or a
-- GitHub issue.
local _, MB = ...
local Print = MB.Print

local SYSTEMS = { gb = "Game Boy / Color", gba = "Game Boy Advance", native = "included game" }

local function text()
    local lines = { "MekkaBoy bug report" }
    local function add(fmt, ...) lines[#lines + 1] = fmt:format(...) end

    add("version %s (link protocol %s)", tostring(MB.VERSION), tostring(MB.PROTOCOL or "?"))

    local ok, v, build, _, toc = pcall(GetBuildInfo)
    if ok and v then add("client %s build %s (interface %s), %s", tostring(v), tostring(build), tostring(toc), (GetLocale and GetLocale()) or "?") end

    local id, kind, running
    if MB.CurrentCart then id, kind, running = MB.CurrentCart() end
    if id then
        add("game: %s (%s), %s", tostring(id), SYSTEMS[kind] or tostring(kind), running and "playing" or "paused")
    else
        add("game: none in the slot")
    end

    local linked = "no"
    if MB.Link and MB.Link.Session then
        local s = MB.Link.Session()
        if s then linked = tostring(s.state or "open") end
    end
    add("link: %s", linked)

    local fired = {}
    for _, key in ipairs(MB.PAUSE_TRIGGERS or {}) do
        local n = MB.attentionSeen and MB.attentionSeen[key]
        if n then fired[#fired + 1] = ("%s x%d"):format(key, n) end
    end
    add("paused this session for: %s", #fired > 0 and table.concat(fired, ", ") or "nothing")

    if MB.Perf then
        local okp, p = pcall(MB.Perf)
        if okp and type(p) == "table" and p.game then add("frame cost: %.1f ms game, %.1f ms picture", tonumber(p.game) or 0, tonumber(p.paint) or 0) end
    end
    if MB.ClientNotes then
        local okn, n = pcall(MB.ClientNotes)
        if okn and type(n) == "table" then
            add("client warnings naming MekkaBoy: %d, longest turn %d ms", tonumber(n.warned) or 0, math.floor(tonumber(n.longestTurnMs) or 0))
        end
    end
    if GetFramerate then add("fps: %d", math.floor(GetFramerate() + 0.5)) end
    return table.concat(lines, "\n")
end
MB.BugText = text

-- a small window holding the text, selected, so Ctrl+C takes it
local win
local function build()
    win = CreateFrame("Frame", "MekkaBoyBugWindow", UIParent)
    win:SetSize(460, 260)
    win:SetPoint("CENTER", 0, 120)
    win:SetFrameStrata("DIALOG")
    win:EnableMouse(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(win)
    bg:SetColorTexture(0.07, 0.06, 0.05, 0.96)
    local edge = win:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 0, 0)
    edge:SetPoint("TOPRIGHT", 0, 0)
    edge:SetHeight(3)
    edge:SetColorTexture(0.85, 0.65, 0.25, 1)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("MekkaBoy - report a bug")
    local say = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    say:SetPoint("TOPLEFT", 16, -38)
    say:SetWidth(428)
    say:SetJustifyH("LEFT")
    say:SetText("Press Ctrl+C to copy this, then paste it into the form at |cffffd100mekkaboy.com/feedback|r along with what happened. It holds no character or party names.")
    local box = CreateFrame("EditBox", nil, win)
    box:SetMultiLine(true)
    box:SetPoint("TOPLEFT", 16, -72)
    box:SetSize(428, 150)
    box:SetFontObject(ChatFontNormal)
    box:SetAutoFocus(false)
    local t = box:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPLEFT", -4, 4)
    t:SetPoint("BOTTOMRIGHT", 4, -4)
    t:SetColorTexture(0, 0, 0, 0.6)
    box:SetScript("OnEscapePressed", function() win:Hide() end)
    box:SetScript("OnTextChanged", function(self, typed)     -- read-only: typing puts the report back
        if typed then self:SetText(win.report or "") self:HighlightText() end
    end)
    box:SetScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
    win.box = box
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    if UISpecialFrames then table.insert(UISpecialFrames, "MekkaBoyBugWindow") end
end

MB.AddCommand("bug", "bug - a short report of this MekkaBoy to paste into mekkaboy.com/feedback (no names in it)", function()
    local report = text()
    if not win then build() end
    win.report = report
    win.box:SetText(report)
    win:Show()
    win.box:SetFocus()
    win.box:HighlightText()
    Print("bug report ready: press Ctrl+C in the window, then paste it at mekkaboy.com/feedback.")
end)
