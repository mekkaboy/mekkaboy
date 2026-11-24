-- MekkaBoy's page in the game's own settings (Options > AddOns > MekkaBoy;
-- /mb options, or right-click the minimap button). Everything on it can also
-- be done with a /mb command; this is the same switches where people look
-- for them. The page is only put together the first time it is shown, and
-- uses no templates of the game's, so a change to those cannot break it.
local _, MB = ...

local Print = MB.Print
local panel = CreateFrame("Frame", "MekkaBoyOptionsPanel")
panel.name = "MekkaBoy"
panel:Hide()
local category
local built = false
local refreshers = {}

local function text(parent, font, str)
    local f = parent:CreateFontString(nil, "ARTWORK", font)
    f:SetJustifyH("LEFT")
    f:SetText(str)
    return f
end

local function tooltip(owner, tip)
    if not tip then return end
    owner:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tip, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

-- a tick box with its words beside it
local function check(parent, label, tip, get, set)
    local b = CreateFrame("CheckButton", nil, parent)
    b:SetSize(26, 26)
    b:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    b:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    local words = text(b, "GameFontHighlight", label)
    words:SetPoint("LEFT", b, "RIGHT", 4, 1)
    b.words = words
    b:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) panel.Refresh() end)
    tooltip(b, tip)
    refreshers[#refreshers + 1] = function() b:SetChecked(get() and true or false) end
    return b
end

-- a slider with its name above it and its value beside it
local function slider(parent, label, lo, hi, step, tip, get, set, show)
    local s = CreateFrame("Slider", nil, parent)
    s:SetSize(220, 17)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0, 0, 0, 0.5)
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(6)
    local name = text(s, "GameFontNormalSmall", label)
    name:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
    local value = text(s, "GameFontHighlightSmall", "")
    value:SetPoint("LEFT", s, "RIGHT", 10, 0)
    s.value = value
    local setting = false
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        value:SetText(show(v))
        if not setting then set(v) end
    end)
    tooltip(s, tip)
    refreshers[#refreshers + 1] = function()
        setting = true
        s:SetValue(get())
        setting = false
        value:SetText(show(get()))
    end
    return s
end

local function button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 24)
    local back = b:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(b)
    back:SetColorTexture(0.35, 0.24, 0.1, 0.9)
    local glow = b:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints(b)
    glow:SetColorTexture(1, 0.82, 0.3, 0.25)
    local words = text(b, "GameFontNormal", label)
    words:SetPoint("CENTER")
    b:SetScript("OnClick", onClick)
    return b
end

local PAUSES = {
    { "ready", "A ready check starts" },
    { "queue", "My dungeon or battleground is ready" },
    { "summon", "Someone summons me" },
    { "resurrect", "Someone offers to resurrect me" },
    { "invite", "Someone invites me to a group" },
    { "duel", "Someone challenges me to a duel" },
    { "trade", "A trade window opens" },
    { "landing", "My flight lands" },
}

-- (0.24) "Start a game over": pick one of your games that has a save, then Start over (it asks first). A list of our
-- own, not the game's dropdown template; it closes on a pick, on Escape with the page, or when the page hides.
local function gamePicker(x, top)
    local W = 170
    local title = text(panel, "GameFontNormal", "Start a game over")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", x, top)
    local note = text(panel, "GameFontDisableSmall", "Erases one game's save. It asks first.")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", x, top - 16)
    local chosen
    local pick = CreateFrame("Button", nil, panel)
    pick:SetSize(W, 24)
    pick:SetPoint("TOPLEFT", panel, "TOPLEFT", x, top - 34)
    local back = pick:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(pick)
    back:SetColorTexture(0.08, 0.07, 0.06, 0.95)
    local edge = pick:CreateTexture(nil, "BORDER")
    edge:SetPoint("BOTTOMLEFT", pick, "BOTTOMLEFT") edge:SetPoint("BOTTOMRIGHT", pick, "BOTTOMRIGHT")
    edge:SetHeight(1)
    edge:SetColorTexture(0.6, 0.45, 0.2, 0.9)
    local glow = pick:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints(pick)
    glow:SetColorTexture(1, 0.82, 0.3, 0.12)
    local label = text(pick, "GameFontHighlight", "Choose a game")
    label:SetPoint("LEFT", pick, "LEFT", 8, 0)
    label:SetPoint("RIGHT", pick, "RIGHT", -22, 0)
    label:SetWordWrap(false)
    local arrow = text(pick, "GameFontNormal", "v")
    arrow:SetPoint("RIGHT", pick, "RIGHT", -8, 0)

    local go = button(panel, "Start over", 86, function()
        if not chosen then return end
        local id = chosen.id
        MB.CloseOptions()
        if MB.StartOver then MB.StartOver(id) end
    end)
    go:SetPoint("LEFT", pick, "RIGHT", 8, 0)
    local function setGo()
        local on = chosen ~= nil
        go:SetEnabled(on)
        go:SetAlpha(on and 1 or 0.45)
    end

    local list = CreateFrame("Frame", nil, panel)
    list:SetFrameStrata("DIALOG")
    list:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -2)
    list:SetWidth(W)
    local lb = list:CreateTexture(nil, "BACKGROUND")
    lb:SetAllPoints(list)
    lb:SetColorTexture(0.05, 0.04, 0.03, 0.97)
    list:Hide()
    local rows = {}
    local function row(i)
        local r = rows[i]
        if r then return r end
        r = CreateFrame("Button", nil, list)
        r:SetSize(W - 4, 20)
        r:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (i - 1) * 20)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(r)
        hl:SetColorTexture(1, 0.82, 0.3, 0.2)
        r.words = text(r, "GameFontHighlightSmall", "")
        r.words:SetPoint("LEFT", r, "LEFT", 6, 0)
        r.words:SetPoint("RIGHT", r, "RIGHT", -4, 0)
        r.words:SetWordWrap(false)
        rows[i] = r
        return r
    end
    local function openList()
        local games = MB.SavedGames and MB.SavedGames() or {}
        for _, r in ipairs(rows) do r:Hide() end
        if #games == 0 then
            local r = row(1)
            r.words:SetText("No saved games yet")
            r.words:SetTextColor(0.5, 0.5, 0.5)
            r:SetScript("OnClick", nil)
            r:Show()
        end
        for i, c in ipairs(games) do
            local r = row(i)
            r.words:SetText(c.name)
            r.words:SetTextColor(1, 1, 1)
            r:SetScript("OnClick", function()
                chosen = c
                label:SetText(c.name)
                list:Hide()
                setGo()
            end)
            r:Show()
        end
        list:SetHeight(4 + math.max(1, #games) * 20)
        list:Show()
    end
    pick:SetScript("OnClick", function() if list:IsShown() then list:Hide() else openList() end end)
    tooltip(pick, "Your games that have a save. The one you pick starts from the beginning; /mb newgame undo puts its save back until you log out.")
    panel:HookScript("OnHide", function() list:Hide() end)
    refreshers[#refreshers + 1] = function()
        -- (a game whose save is gone since, or that was removed, is no longer a choice)
        if chosen then
            local still = false
            for _, c in ipairs(MB.SavedGames and MB.SavedGames() or {}) do if c.id == chosen.id then still = true end end
            if not still then chosen = nil label:SetText("Choose a game") end
        end
        setGo()
    end
end

local function build()
    if built then return end
    built = true
    local db = MB.DB
    local y = -12
    local function place(region, x, gap)
        region:SetPoint("TOPLEFT", panel, "TOPLEFT", x or 16, y)
        y = y - (gap or 26)
    end
    local function heading(str)
        y = y - 8
        place(text(panel, "GameFontNormal", str), 16, 20)
    end

    place(text(panel, "GameFontNormalLarge", "MekkaBoy"), 16, 22)
    place(text(panel, "GameFontHighlightSmall", ("Version %s.  /mb opens the console; /mb help lists every command."):format(MB.VERSION)), 16, 18)

    heading("The console")
    -- (0.24: beside the first row, so the page stays the height of the game's settings window)
    check(panel, "Keep restore points", "Every two minutes, a copy of your game is kept in memory, so an error costs a few minutes at most. Never on your memory valves, and not during a link or trade.",
        function() return MB.Opt("restorePoints", true) end, function(v) db().opt.restorePoints = v end):SetPoint("TOPLEFT", panel, "TOPLEFT", 300, y)
    place(check(panel, "Open by itself on flight paths", nil,
        function() return MB.Opt("auto", true) end, function(v) db().opt.auto = v end), 16, 24)
    place(check(panel, "Pick up exactly where I left off after logging out", "The game is exactly as you left it, mid-step. Off: a game starts from its own save.",
        function() return MB.Opt("resume", true) end, function(v) db().opt.resume = v end), 16, 24)
    place(check(panel, "Show the button on the minimap", nil,
        function() return MB.Opt("minimap", true) end, function(v) db().opt.minimap = v if MB.ApplyMinimapButton then MB.ApplyMinimapButton() end end), 16, 40)
    gamePicker(300, y + 4)
    place(slider(panel, "Size", 0, 6, 1, "How many screen pixels each game pixel takes. Automatic picks the largest that fits your screen comfortably.",
        function() return MB.Opt("scale", nil) or 0 end,
        function(v) db().opt.scale = (v >= 1) and v or nil MB.ApplyScale() end,
        function(v) return v >= 1 and ("%d"):format(v) or "Automatic" end), 20, 26)
    place(slider(panel, "Look", 1, 2, 1, "Minimal: a see-through window, played on the keyboard. Console: the MekkaBoy handheld, every button clickable. Also: /mb look minimal|console.",
        function() return (MB.Look and MB.Look() == "console") and 2 or 1 end,
        function(v) MB.SetLook(v == 2 and "console" or "glass") end,
        function(v) return v == 2 and "Console" or "Minimal" end), 20, 26)
    place(slider(panel, "Color", 1, #MB.Colorways, 1, "The color, for either look. Also: /mb color <name>.",
        function() for i, c in ipairs(MB.Colorways) do if c == MB.Colorway() then return i end end return 1 end,
        function(v) MB.SetColorway(MB.Colorways[v] or "gunmetal") end,
        function(v) return MB.ColorwayNames[MB.Colorways[v] or "gunmetal"] end), 20, 26)

    heading("Sound")
    place(check(panel, "Play the game's music and sounds", "A game needs a soundtrack pack made from your own copy; a pasted game is silent. See the README.",
        function() return MB.Opt("sound", true) end, function(v) MB.Sound.SetEnabled(v) end), 16, 24)
    place(check(panel, "Keep the sound going while another window is in front", "On: while the console is open, WoW's \"Sound in Background\" setting is switched on (for all of WoW's sound), and put back when the console closes. Off: WoW goes silent when you switch to another window, as it normally does, and the game's song starts over when you come back.",
        function() return MB.Opt("soundBackground", true) end, function(v) MB.Sound.SetBackground(v) end), 16, 24)
    place(check(panel, "Give the console a volume of its own", "Off: the console is as loud as your Sound Effects slider. On: the wheel on the console (and the slider below) set it, apart from the rest of WoW.",
        function() return MB.Opt("volume", nil) ~= nil end,
        function(v) MB.Sound.SetVolume(v and (MB.Sound.Level() or 0.5) or nil) MB.SetVolumeKnob(MB.Sound.Level()) end), 16, 38)
    place(slider(panel, "Console volume", 0, 100, 10, nil,
        function() return math.floor((MB.Sound.Level() or 0.5) * 100 + 0.5) end,
        function(v) MB.Sound.SetVolume(v / 100) MB.SetVolumeKnob(MB.Sound.Level()) end,
        function(v) return ("%d%%"):format(v) end), 20, 26)

    heading("Pause the game when")
    -- (two columns, so the page fits the game's settings window)
    for i, p in ipairs(PAUSES) do
        local key = p[1]
        local right = i > #PAUSES / 2
        if i == #PAUSES / 2 + 1 then y = y + 22 * (#PAUSES / 2) end
        place(check(panel, p[2], nil, function() return MB.PausesOn(key) end, function(v) MB.SetPauseOn(key, v) end), right and 300 or 16, 22)
    end
    y = y - 4
    place(check(panel, "Leave a note on the console when someone whispers me", "The game carries on; the status plate says who it was.",
        function() return MB.Opt("whisperNote", true) end, function(v) db().opt.whisperNote = v end), 16, 26)

    heading("Playing with others")
    y = y - 12                  -- (the slider's name sits above it)
    local MODES = { "solo", "friends", "open" }
    place(slider(panel, "How I play", 1, 3, 1, "Open (the default): anyone who targets you, and your group and guild, can see that you have MekkaBoy and what you are playing. Friends only: just your group, friends list, guild and the players you have linked with. Solo: nobody is told, nobody is asked, and Together is off. Also: /mb play.",
        function() for i, k in ipairs(MODES) do if k == MB.PlayMode() then return i end end return 3 end,
        function(v) MB.SetPlayMode(MODES[v] or "open") end,
        function(v) return MB.PLAY_WORDS[MODES[v] or "open"] end), 20, 30)

    local x = 16
    for _, b in ipairs({
        { "Add a game", 110, function() MB.CloseOptions() if MB.Import then MB.Import.Open() end end },
        { "Controls", 100, function() if MB.OpenControls then MB.OpenControls() end end },
        { "Friends", 90, function() MB.CloseOptions() if MB.Friends and MB.Friends.Open then MB.Friends.Open() end end },
        { "Back to the middle", 140, function() if MB.commands.center then MB.commands.center.run("") end end },
    }) do
        local btn = button(panel, b[1], b[2], b[3])
        btn:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
        x = x + b[2] + 8
    end
end

function panel.Refresh()
    if not built then return end
    for _, fn in ipairs(refreshers) do fn() end
end
panel:SetScript("OnShow", function()
    local ok, err = pcall(build)
    if not ok then Print("The settings page could not be drawn (" .. tostring(err) .. "). Every setting also has a /mb command: /mb help.") return end
    panel.Refresh()
end)

-- tell the game about the page (the newer way, then the older one)
local function register()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, "MekkaBoy")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end
MB.onLogin[#MB.onLogin + 1] = function() pcall(register) end

function MB.CloseOptions()
    if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() and HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
    if panel.standalone then panel:Hide() end
end

function MB.OpenOptions()
    if InCombatLockdown() then Print("The settings stay shut while you are in combat.") return end
    MB.Hide()       -- (the open console keeps the keyboard; the settings need it)
    if category and Settings and Settings.OpenToCategory then
        local id = (category.GetID and category:GetID()) or category.ID
        if pcall(Settings.OpenToCategory, id) then return end
    end
    if InterfaceOptionsFrame_OpenToCategory then
        if pcall(InterfaceOptionsFrame_OpenToCategory, panel) then return end
    end
    -- no settings window to live in: stand on its own in the middle of the screen
    if not panel.standalone then
        panel.standalone = true
        panel:SetParent(UIParent)
        panel:SetSize(600, 600)
        panel:SetPoint("CENTER")
        panel:SetFrameStrata("DIALOG")
        panel:EnableMouse(true)
        local back = panel:CreateTexture(nil, "BACKGROUND")
        back:SetAllPoints(panel)
        back:SetColorTexture(0.05, 0.04, 0.03, 0.94)
        local close = button(panel, "Close", 70, function() panel:Hide() end)
        close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
        if UISpecialFrames then table.insert(UISpecialFrames, "MekkaBoyOptionsPanel") end
    end
    panel:Show()
end

MB.AddCommand("options", "options - open the settings page", function() MB.OpenOptions() end)
MB.AddCommand("settings", "", function() MB.OpenOptions() end)
