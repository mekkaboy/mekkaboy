-- The first time: two questions, once per account. The first time the console opens after this release (for players
-- who used MekkaBoy before it, and for everyone new), a small panel asks how you want to play (Open, Friends only, Solo:
-- MB.PlayMode) and how MekkaBoy should look (Minimal or Console: MB.Look, UI/Body.lua), with the choices most players
-- want already picked. Picking a look shows it straight away behind the panel. "Start playing" keeps both and the panel
-- never comes back; both can be changed later in the settings, or with /mb play and /mb look. The Together question
-- about the realm (GBA/Ghosts.lua) is answered here as well, so nobody is asked twice.
local _, MB = ...
local Print = MB.Print

local INK, SOFT, LINE, PICK = { 0.91, 0.93, 0.94 }, { 0.70, 0.75, 0.77 }, { 1, 1, 1, 0.14 }, { 0.56, 0.76, 0.82 }
local W = 440
local panel, choice

function MB.Onboarded() return MB.DB().onboarded ~= nil end

local PLAYS = {
    { id = "open", name = "Open", line = "Anyone who targets you sees you have MekkaBoy and can ask to link." },
    { id = "friends", name = "Friends only", line = "Only your friends list, guild, group and past link partners." },
    { id = "solo", name = "Solo", line = "Nobody is told you have MekkaBoy, and Together is off." },
}
local LOOKS = {
    { id = "glass", name = "Minimal", line = "A see-through window, played on the keyboard." },
    { id = "console", name = "Console", line = "The MekkaBoy handheld, buttons and all." },
}

local function box(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    b.bg = bg
    local edge = {}
    for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = b:CreateTexture(nil, "BORDER")
        t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        edge[i] = t
    end
    b.edge = edge
    local name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("TOPLEFT", 10, -8)
    name:SetJustifyH("LEFT")
    b.name = name
    local line = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
    line:SetWidth(w - 20)
    line:SetJustifyH("LEFT")
    line:SetTextColor(SOFT[1], SOFT[2], SOFT[3])
    b.line = line
    function b:Pick(on)
        self.on = on
        if on then
            bg:SetColorTexture(PICK[1], PICK[2], PICK[3], 0.18)
            for _, t in ipairs(edge) do t:SetColorTexture(PICK[1], PICK[2], PICK[3], 1) end
        else
            bg:SetColorTexture(1, 1, 1, 0.04)
            for _, t in ipairs(edge) do t:SetColorTexture(LINE[1], LINE[2], LINE[3], LINE[4]) end
        end
    end
    return b
end

local function refresh()
    for _, b in ipairs(panel.plays) do b:Pick(b.id == choice.play) end
    for _, b in ipairs(panel.looks) do b:Pick(b.id == choice.look) end
end

local function finish()
    MB.SetPlayMode(choice.play)
    MB.SetLook(choice.look)
    local db = MB.DB()
    -- (Together on the realm, still an experiment: on when playing Open, off otherwise; GBA/Ghosts.lua)
    if db.opt.realm == nil then db.opt.realm = (choice.play == "open") and "on" or "off" end
    db.onboarded = MB.VERSION or true
    panel:Hide()
    Print(("How you play: %s. Look: %s. Change either in the settings, or with /mb play and /mb look."):format(
        MB.PLAY_WORDS[choice.play] or choice.play, MB.LOOK_WORDS[choice.look] or choice.look))
end

local function build()
    panel = CreateFrame("Frame", "MekkaBoyWelcome", UIParent)
    panel:SetFrameStrata("DIALOG")
    panel:SetSize(W, 100)
    panel:SetPoint("TOP", UIParent, "TOP", 0, -90)
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    bg:SetColorTexture(0.06, 0.08, 0.09, 0.92)
    for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = panel:CreateTexture(nil, "BORDER")
        t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        t:SetColorTexture(LINE[1], LINE[2], LINE[3], 0.22)
    end
    local y = -16
    local function text(font, str, gap, color)
        local fs = panel:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", 18, y)
        fs:SetWidth(W - 36)
        fs:SetJustifyH("LEFT")
        fs:SetText(str)
        if color then fs:SetTextColor(color[1], color[2], color[3]) end
        y = y - (gap or 20)
        return fs
    end
    panel.kicker = text("GameFontNormalSmall", "WELCOME TO MEKKABOY", 16, SOFT)
    panel.title = text("GameFontHighlightLarge", "Two quick choices. You can change both later in the settings.", 40, INK)
    panel.q1 = text("GameFontNormal", "How do you want to play?", 22, INK)
    panel.plays = {}
    for _, p in ipairs(PLAYS) do
        local b = box(panel, W - 36, 44)
        b:SetPoint("TOPLEFT", 18, y)
        b.id = p.id
        b.name:SetText(p.name)
        b.line:SetText(p.line)
        b:SetScript("OnClick", function() choice.play = p.id refresh() end)
        panel.plays[#panel.plays + 1] = b
        y = y - 50
    end
    y = y - 8
    panel.q2 = text("GameFontNormal", "How should MekkaBoy look?", 22, INK)
    panel.looks = {}
    local half = (W - 36 - 8) / 2
    for i, l in ipairs(LOOKS) do
        local b = box(panel, half, 54)
        b:SetPoint("TOPLEFT", 18 + (i - 1) * (half + 8), y)
        b.id = l.id
        b.name:SetText(l.name)
        b.line:SetText(l.line)
        b:SetScript("OnClick", function()
            choice.look = l.id
            MB.SetLook(l.id)           -- (shown straight away, behind the panel)
            refresh()
        end)
        panel.looks[#panel.looks + 1] = b
    end
    y = y - 66
    local go = CreateFrame("Button", nil, panel)
    go:SetSize(140, 28)
    go:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, y)
    local gbg = go:CreateTexture(nil, "BACKGROUND")
    gbg:SetAllPoints(go)
    gbg:SetColorTexture(PICK[1], PICK[2], PICK[3], 1)
    local gl = go:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gl:SetPoint("CENTER")
    gl:SetTextColor(0.06, 0.08, 0.09)
    gl:SetText("Start playing")
    go.label = gl
    go:SetScript("OnClick", finish)
    panel.go = go
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("LEFT", panel, "TOPLEFT", 18, y - 14)
    note:SetWidth(W - 36 - 150)
    note:SetJustifyH("LEFT")
    note:SetTextColor(SOFT[1], SOFT[2], SOFT[3])
    note:SetText("Colors: six to pick from in the settings, for either look.")
    y = y - 28 - 16
    panel:SetHeight(-y)
    panel:Hide()
end

function MB.ShowWelcome()
    if not panel then build() end
    choice = { play = MB.PlayMode(), look = "glass" }
    MB.SetLook("glass")
    refresh()
    panel:Show()
end
function MB.WelcomePanel() return panel end      -- (for tests)

-- the console opened: the first time ever (on this account), the two questions come first
MB.window:HookScript("OnShow", function()
    if not MB.Onboarded() then MB.ShowWelcome() end
end)
MB.window:HookScript("OnHide", function() if panel and panel:IsShown() then panel:Hide() end end)

MB.AddCommand("look", "look minimal|console - how MekkaBoy looks: a see-through window, or the handheld console", function(rest)
    local word = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if word ~= "" and not MB.SetLook(word) then Print("/mb look minimal (a see-through window) or /mb look console (the handheld).") return end
    Print("MekkaBoy looks: " .. (MB.LOOK_WORDS[MB.Look()] or MB.Look()) .. ".")
end)
MB.AddCommand("welcome", "welcome - ask the two first-time questions again (how you play, how it looks)", function()
    if not MB.window:IsShown() then MB.Show(false) end
    MB.ShowWelcome()
end)
