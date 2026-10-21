-- The console itself: the brass body, the screen behind its glass, buttons
-- you can click, the flight gauge, the status plate. All art is in Art/
-- (drawn by Tools/gen_art.py, which also writes Art/layout.lua so positions
-- here always match the picture). Sizes are in "design units": the body is
-- 840 x 456 of them and one game pixel is 2 x 2. The screen is as big as a
-- Game Boy Advance picture; Game Boy pictures sit in the middle of it.
local _, MB = ...

local Lay = MB.Layout
local ART = "Interface\\AddOns\\MekkaBoy\\Art\\"
local rad = math.rad

local win = CreateFrame("Frame", "MekkaBoyWindow", UIParent)
win:SetSize(Lay.bodyW, Lay.bodyH)
win:SetPoint("CENTER")
win:SetFrameStrata("MEDIUM")
win:SetMovable(true)
win:SetClampedToScreen(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- remember where it was put (the beta is unreliable about doing this itself)
    local point, _, relPoint, x, y = self:GetPoint(1)
    if point then MB.DB().opt.pos = { point, relPoint, x, y } end
end)
win:Hide()
MB.window = win

-- place a region by body coordinates (x right, y down from the body's top-left)
local function at(region, x, y, w, h)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", win, "TOPLEFT", x, -y)
    if w then region:SetSize(w, h or w) end
end

-- ---------------------------------------------------------------- art ---
-- The body comes in colorways, one picture each (Tools/gen_art.py): /mb color, or the settings page.
MB.Colorways = { "gunmetal", "midnight", "arcane", "verdant", "ivory", "rosegold" }
MB.ColorwayNames = { gunmetal = "Gunmetal", midnight = "Midnight", arcane = "Arcane", verdant = "Verdant", ivory = "Ivory", rosegold = "Rose Gold" }
local function colorway()
    local opt = MB.DB().opt
    if opt.colourway ~= nil then      -- (0.20.0 and earlier kept it under the British spelling)
        if opt.colorway == nil then opt.colorway = opt.colourway end
        opt.colourway = nil
    end
    local c = MB.Opt("colorway", "gunmetal")
    return MB.ColorwayNames[c] and c or "gunmetal"
end

-- the body picture hangs a little over the frame's edges (the shoulder buttons)
local body = win:CreateTexture(nil, "ARTWORK")
body:SetTexture(ART .. "body_gunmetal.tga")
body:SetTexCoord(0, 1, 0, Lay.usedH / Lay.canvasH)
at(body, -Lay.bodyX, -Lay.bodyY, Lay.canvasW, Lay.usedH)

function MB.SetColorway(name)
    name = name and name:lower():gsub("[%s%-]", "")
    if not (name and MB.ColorwayNames[name]) then return false end
    MB.DB().opt.colorway = name
    body:SetTexture(ART .. "body_" .. name .. ".tga")
    if MB.PaintGlass then MB.PaintGlass() end
    return true
end
function MB.Colorway() return colorway() end
MB.onLogin[#MB.onLogin + 1] = function() body:SetTexture(ART .. "body_" .. colorway() .. ".tga") end
-- /mb color <name>: the console's colorway. GB/Console.lua owns the /mb color command, which also takes lcd|raw for
-- the Game Boy Color screen, and hands every other word here.
function MB.ColorwayCommand(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local list = {}
    for _, c in ipairs(MB.Colorways) do list[#list + 1] = MB.ColorwayNames[c] end
    if rest == "" then MB.Print(("The console is %s. /mb color <name>: %s."):format(MB.ColorwayNames[colorway()], table.concat(list, ", "))) return end
    if MB.SetColorway(rest) then MB.Print(("The console is %s now."):format(MB.ColorwayNames[colorway()]))
    else MB.Print(("No color called %s. Pick one of: %s."):format(rest, table.concat(list, ", "))) end
end

-- ------------------------------------------------------------- screen ---
local scr = Lay.screen
local screen = CreateFrame("Frame", nil, win)
at(screen, scr[1], scr[2], scr[3], scr[4])
screen:EnableMouse(true)
MB.screen = screen
screen:SetScript("OnMouseDown", function() if MB.OnScreenClick then MB.OnScreenClick() end end)

-- above the pixels: a dimmer with a message (paused, no game...), then the glass
local veil = CreateFrame("Frame", nil, win)
veil:SetAllPoints(screen)
veil:SetFrameLevel(screen:GetFrameLevel() + 10)
local dim = veil:CreateTexture(nil, "BACKGROUND")
dim:SetAllPoints(veil)
dim:SetColorTexture(0, 0, 0, 0.62)
local message = veil:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
MB.screenText = message
message:SetPoint("CENTER")
message:SetWidth(scr[3] - 40)
local glass = veil:CreateTexture(nil, "OVERLAY")
glass:SetTexture(ART .. "glass.tga")
glass:SetAllPoints(veil)
glass:SetAlpha(0.07)
glass:SetBlendMode("ADD")

function MB.SetScreenMessage(text)
    if text then
        message:SetText(text)
        dim:Show()
        message:Show()
    else
        dim:Hide()
        message:Hide()
    end
end

-- ------------------------------------------------------- status plate ---
local sp = Lay.status
local status = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
at(status, sp[1] + 6, sp[2] + 1, sp[3] - 12, sp[4] - 2)
status:SetJustifyH("CENTER")
status:SetTextColor(1, 0.86, 0.55)
MB.statusText = status
function MB.SetStatus(text) status:SetText(text or "") end

-- ------------------------------------------------------- lamp and glow ---
local function glow(x, y, size, r, g, b, layer)
    local t = win:CreateTexture(nil, layer or "OVERLAY")
    t:SetTexture(ART .. "glow.tga")
    t:SetBlendMode("ADD")
    t:SetVertexColor(r, g, b)
    at(t, x - size / 2, y - size / 2, size)
    t:Hide()
    return t
end

local lamp = glow(Lay.led[1], Lay.led[2], 30, 1, 0.25, 0.2)
local powered = false
function MB.SetPower(on)
    powered = on and true or false
    lamp:SetShown(powered and not (MB.Look and MB.Look() == "glass"))
    if MB.PaintGlass then MB.PaintGlass() end
end

-- ------------------------------------------------------------- gauge ---
local ga = Lay.gauge
local needle = win:CreateTexture(nil, "OVERLAY")
needle:SetTexture(ART .. "needle.tga")
at(needle, ga[1] - ga[3], ga[2] - ga[3], ga[3] * 2)
local flightText = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
MB.flightText = flightText
flightText:SetPoint("CENTER", win, "TOPLEFT", ga[1], -(ga[2] + ga[3] + 12))
flightText:SetTextColor(0.25, 0.16, 0.05)
flightText:SetShadowColor(1, 0.9, 0.6, 0.5)

-- The scale runs from lower left (a full flight ahead) clockwise over the top
-- to the red zone at lower right (landing). fraction = share of the flight
-- still to go, 1 .. 0; nil parks the needle.
local needleAt, needleWant = -120, -120
local function needleDegrees(fraction)
    if not fraction then return -120 end
    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    return -120 + (1 - fraction) * 240
end
needle:SetRotation(-rad(needleAt))

function MB.SetFlight(text, fraction)
    flightText:SetText(text or "")
    needleWant = needleDegrees(fraction)
    if not win:IsVisible() then -- nobody is watching: no need to swing
        needleAt = needleWant
        needle:SetRotation(-rad(needleAt))
    end
end
function MB.NeedleDegrees() return needleAt, needleWant end
win:SetScript("OnHide", function()
    needleAt = needleWant
    needle:SetRotation(-rad(needleAt))
end)

-- ------------------------------------------------------ volume wheel ---
-- The wheel shows the console's own volume (GB/Sound.lua): its mark points
-- lower left when silent, straight up at half, lower right at full.
local vo = Lay.volume
local knob = win:CreateTexture(nil, "OVERLAY")
knob:SetTexture(ART .. "knob.tga")
at(knob, vo[1] - vo[3], vo[2] - vo[3], vo[3] * 2)
function MB.SetVolumeKnob(fraction)
    if type(fraction) ~= "number" then fraction = 0.5 end
    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    knob:SetRotation(-rad(-135 + fraction * 270))
    if MB.glassButtons then MB.glassButtons.volume.label:SetText(("Vol %d%%"):format(math.floor(fraction * 100 + 0.5))) end
end
MB.SetVolumeKnob(0.5)

-- --------------------------------------------------------- animation ---
win:SetScript("OnUpdate", function(_, elapsed)
    if needleAt ~= needleWant then
        -- the needle swings to its mark instead of jumping
        local step = (needleWant - needleAt) * math.min(1, elapsed * 6)
        needleAt = (math.abs(needleWant - needleAt) < 0.3) and needleWant or (needleAt + step)
        needle:SetRotation(-rad(needleAt))
    end
end)

-- ------------------------------------------------------------ buttons ---
local pressGlow = {}
MB.buttons = {}

local function tip(owner, title, lines)
    owner:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(type(title) == "function" and title() or title, 1, 0.82, 0.3)
        local body2 = type(lines) == "function" and lines() or lines
        if body2 then GameTooltip:AddLine(body2, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function keyOf(button)
    local k = MB.KeyLabel and MB.KeyLabel(button)
    return k and ("Key: " .. k) or nil
end

-- a clickable patch of the body: x, y = center
local function hot(name, cx, cy, w, h, glowSize, r, g, b)
    local btn = CreateFrame("Button", nil, win)
    at(btn, cx - w / 2, cy - h / 2, w, h)
    btn:SetFrameLevel(win:GetFrameLevel() + 20)
    btn:RegisterForClicks("AnyUp")
    pressGlow[name] = glow(cx, cy, glowSize, r, g, b)
    MB.buttons[name] = btn
    return btn
end

function MB.SetPressed(name, down)
    if MB.Look and MB.Look() == "glass" then
        local b = MB.glassButtons and MB.glassFace and MB.glassFace(name)
        if b and MB.PaintGlass then
            MB.PaintGlass()
            if down then b.face:SetColorTexture(1, 1, 1, 0.28) end
        end
        return
    end
    local t = pressGlow[name]
    if t then t:SetShown(down and true or false) end
end

-- held buttons: press on mouse down, let go on mouse up (or when the mouse slides off)
local function holdable(btn, name, callbackName)
    local function set(down)
        if btn.down == down then return end
        btn.down = down
        MB.SetPressed(name, down)
        local cb = MB[callbackName]
        if cb then cb(name, down) end
    end
    btn:SetScript("OnMouseDown", function() set(true) end)
    btn:SetScript("OnMouseUp", function() set(false) end)
    btn:HookScript("OnLeave", function() set(false) end)
    btn:SetScript("OnHide", function() set(false) end)
end

local dp = Lay.dpad
local reach, arm = dp[4], dp[3] * 2
local padNames = { up = "Up", down = "Down", left = "Left", right = "Right", a = "A", b = "B", start = "Start", select = "Select", l = "L", r = "R" }
for name, off in pairs({ up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }) do
    local cx, cy = dp[1] + off[1] * (reach - 14), dp[2] + off[2] * (reach - 14)
    local btn = hot(name, cx, cy, arm, arm, 44, 1, 0.8, 0.4)
    tip(btn, padNames[name], function() return keyOf(name) end)
    holdable(btn, name, "OnPad")
end
for _, name in ipairs({ "a", "b" }) do
    local c = Lay[name]
    local btn = hot(name, c[1], c[2], c[3] * 2, c[3] * 2, 84, 1, 0.45, 0.35)
    tip(btn, padNames[name] .. " button", function() return keyOf(name) end)
    holdable(btn, name, "OnPad")
end
for _, name in ipairs({ "l", "r" }) do     -- the shoulder buttons stand up above the body's top edge
    local c = Lay[name]
    local btn = hot(name, c[1], c[2], c[3], c[4], 70, 1, 0.8, 0.4)
    tip(btn, padNames[name] .. " button", function() return "For Game Boy Advance games.\n" .. (keyOf(name) or "") end)
    holdable(btn, name, "OnPad")
end
for _, name in ipairs({ "select", "start" }) do
    local c = Lay[name]
    local btn = hot(name, c[1], c[2], c[3] + 6, c[4] + 14, 56, 1, 0.8, 0.4)
    tip(btn, padNames[name], function() return keyOf(name) end)
    holdable(btn, name, "OnPad")
end
do
    local c = Lay.rew
    local btn = hot("rewind", c[1], c[2], c[3], c[4], 48, 1, 0.8, 0.4)
    tip(btn, "Rewind", function() return "Hold to run the last moments backwards.\n" .. (keyOf("rewind") or "") end)
    holdable(btn, "rewind", "OnAction")
    c = Lay.ff
    btn = hot("ff", c[1], c[2], c[3], c[4], 48, 1, 0.8, 0.4)
    tip(btn, "Fast-forward", function() return "Hold to speed the game up.\n" .. (keyOf("ff") or "") end)
    holdable(btn, "ff", "OnAction")
end
for n, c in ipairs(Lay.mem) do
    local btn = hot("mem" .. n, c[1], c[2], c[3] * 2 + 4, c[3] * 2 + 4, 40, 0.5, 0.8, 1)
    tip(btn, function() return "Memory valve " .. n end, function()
        local when = MB.StateInfo and MB.StateInfo(n)
        return (when and ("Holds a save from " .. when .. ".") or "Empty.") .. "\nLeft-click: load.  Right-click: save."
    end)
    btn:SetScript("OnClick", function(_, mouseButton)
        if MB.OnMemory then MB.OnMemory(n, mouseButton == "RightButton") end
    end)
    btn:SetScript("OnMouseDown", function() MB.SetPressed("mem" .. n, true) end)
    btn:SetScript("OnMouseUp", function() MB.SetPressed("mem" .. n, false) end)
end
do
    local c = Lay.close
    local btn = hot("close", c[1], c[2], c[3] * 2 + 4, c[3] * 2 + 4, 36, 1, 0.5, 0.4)
    tip(btn, "Put it away", "The game pauses and waits for you.")
    btn:SetScript("OnClick", function() MB.Hide() end)
    c = Lay.help
    btn = hot("help", c[1], c[2], c[3] * 2 + 4, c[3] * 2 + 4, 36, 1, 0.9, 0.5)
    tip(btn, "MekkaBoy", function() return (MB.HelpText and MB.HelpText() or "/mb help") .. "\nClick: show or hide the keys." end)
    btn:SetScript("OnClick", function()
        if MB.ToggleKeyDrawer then MB.ToggleKeyDrawer() elseif MB.commands.help then MB.commands.help.run("") end
    end)
end

do
    local btn = CreateFrame("Button", nil, win)
    at(btn, vo[1] - vo[3] - 5, vo[2] - vo[3] - 5, vo[3] * 2 + 10)
    btn:SetFrameLevel(win:GetFrameLevel() + 20)
    btn:RegisterForClicks("AnyUp")
    MB.buttons.volume = btn
    tip(btn, function() return MB.VolumeText and MB.VolumeText() or "Volume" end,
        function() return "Mouse wheel, or left-click louder, right-click quieter.\n" .. "Keys: " .. (MB.KeyLabel and MB.KeyLabel("volup") or "") .. " louder, " .. (MB.KeyLabel and MB.KeyLabel("voldown") or "") .. " quieter.\nThe rest of WoW keeps its own volume." end)
    local function turn(steps)
        if MB.OnVolume then MB.OnVolume(steps) end
        local again = btn:GetScript("OnEnter")      -- (the mouse is on the wheel: its tooltip shows the new level)
        if again then again(btn) end
    end
    btn:SetScript("OnClick", function(_, mouseButton) turn(mouseButton == "RightButton" and -1 or 1) end)
    btn:EnableMouseWheel(true)
    btn:SetScript("OnMouseWheel", function(_, delta) turn(delta > 0 and 1 or -1) end)
end

-- -------------------------------------------------- the minimal look ---
-- Two looks for the same window (/mb look, the settings, the first-open questions in UI/Onboarding.lua):
--   glass    (what a new player starts with) a see-through panel the color of the colorway: the picture, a thin top
--            line (the game, the link, help and close) and a bar under the picture (memory valves, rewind, fast-
--            forward, volume, the flight). The game is played on the keyboard; the bar dims while the mouse is away.
--   console  the MekkaBoy handheld above, every button clickable.
-- Same screen, same size of picture, same everything else: only what is drawn around it changes.
local G_PAD, G_TOP, G_BAR = 10, 28, 30
local glassW, glassH = scr[3] + G_PAD * 2, G_TOP + scr[4] + 8 + G_BAR + 6
-- each colorway as glass: the panel's color, text, quieter text, the accent, the edge
local GLASS = {
    gunmetal = { bg = { 0.10, 0.11, 0.13 }, ink = { 0.91, 0.93, 0.94 }, soft = { 0.66, 0.71, 0.73 }, accent = { 0.56, 0.76, 0.82 }, edge = { 1, 1, 1, 0.16 } },
    midnight = { bg = { 0.07, 0.09, 0.19 }, ink = { 0.90, 0.92, 1.00 }, soft = { 0.65, 0.69, 0.88 }, accent = { 0.56, 0.64, 1.00 }, edge = { 0.67, 0.73, 1, 0.22 } },
    arcane   = { bg = { 0.14, 0.09, 0.23 }, ink = { 0.94, 0.91, 1.00 }, soft = { 0.75, 0.68, 0.90 }, accent = { 0.76, 0.61, 0.96 }, edge = { 0.78, 0.67, 1, 0.22 } },
    verdant  = { bg = { 0.07, 0.16, 0.10 }, ink = { 0.90, 0.96, 0.91 }, soft = { 0.65, 0.79, 0.69 }, accent = { 0.50, 0.82, 0.60 }, edge = { 0.59, 0.90, 0.67, 0.20 } },
    ivory    = { bg = { 0.94, 0.92, 0.88 }, ink = { 0.16, 0.15, 0.13 }, soft = { 0.37, 0.34, 0.29 }, accent = { 0.54, 0.42, 0.20 }, edge = { 0.24, 0.20, 0.12, 0.22 } },
    rosegold = { bg = { 0.23, 0.13, 0.13 }, ink = { 0.98, 0.91, 0.89 }, soft = { 0.88, 0.73, 0.69 }, accent = { 0.92, 0.66, 0.58 }, edge = { 0.94, 0.71, 0.65, 0.24 } },
}
local pane = CreateFrame("Frame", nil, win)
pane:SetAllPoints(win)
pane:SetFrameLevel(win:GetFrameLevel())
pane:Hide()
local paneBg = pane:CreateTexture(nil, "BACKGROUND")
paneBg:SetAllPoints(pane)
local edges = {}
for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = pane:CreateTexture(nil, "BORDER")
    t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
    if e[3] then t:SetHeight(1) else t:SetWidth(1) end
    edges[i] = t
end
local dot = pane:CreateTexture(nil, "ARTWORK")
dot:SetSize(8, 8)
dot:SetPoint("LEFT", pane, "TOPLEFT", G_PAD + 2, -G_TOP / 2)
local bar = CreateFrame("Frame", nil, pane)
bar:SetPoint("TOPLEFT", pane, "TOPLEFT", G_PAD, -(G_TOP + scr[4] + 8))
bar:SetSize(scr[3], G_BAR)
local glassButtons, glassFaces = {}, {}
local function glassButton(parent, label, w, name)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 24)
    b:RegisterForClicks("AnyUp")
    local face = b:CreateTexture(nil, "BACKGROUND")
    face:SetAllPoints(b)
    b.face = face
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER")
    fs:SetText(label)
    b.label = fs
    b:SetScript("OnEnter", nil)
    glassButtons[#glassButtons + 1] = b
    if name then glassFaces[name] = b end
    return b
end
local mems = {}
for n = 1, 4 do
    local b = glassButton(bar, tostring(n), 26, "mem" .. n)
    b:SetPoint("LEFT", bar, "LEFT", (n - 1) * 30, 0)
    tip(b, function() return "Memory valve " .. n end, function()
        local when = MB.StateInfo and MB.StateInfo(n)
        return (when and ("Holds a save from " .. when .. ".") or "Empty.") .. "\nLeft-click: load.  Right-click: save."
    end)
    b:SetScript("OnClick", function(_, mouseButton) if MB.OnMemory then MB.OnMemory(n, mouseButton == "RightButton") end end)
    mems[n] = b
end
local gRew = glassButton(bar, "<<", 34, "rewind")
gRew:SetPoint("LEFT", bar, "LEFT", 4 * 30 + 12, 0)
tip(gRew, "Rewind", function() return "Hold to run the last moments backwards.\n" .. (keyOf("rewind") or "") end)
holdable(gRew, "rewind", "OnAction")
local gFF = glassButton(bar, ">>", 34, "ff")
gFF:SetPoint("LEFT", gRew, "RIGHT", 4, 0)
tip(gFF, "Fast-forward", function() return "Hold to speed the game up.\n" .. (keyOf("ff") or "") end)
holdable(gFF, "ff", "OnAction")
local gVol = glassButton(bar, "Vol", 64, "volume")
gVol:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
tip(gVol, function() return MB.VolumeText and MB.VolumeText() or "Volume" end,
    function() return "Mouse wheel, or left-click louder, right-click quieter.\nThe rest of WoW keeps its own volume." end)
do
    local function turn(steps)
        if MB.OnVolume then MB.OnVolume(steps) end
        local again = gVol:GetScript("OnEnter")
        if again then again(gVol) end
    end
    gVol:SetScript("OnClick", function(_, mouseButton) turn(mouseButton == "RightButton" and -1 or 1) end)
    gVol:EnableMouseWheel(true)
    gVol:SetScript("OnMouseWheel", function(_, delta) turn(delta > 0 and 1 or -1) end)
end
local gClose = glassButton(pane, "\195\151", 22, "close")      -- (×)
gClose:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -6, -3)
tip(gClose, "Put it away", "The game pauses and waits for you.")
gClose:SetScript("OnClick", function() MB.Hide() end)
local gHelp = glassButton(pane, "?", 22, "help")
gHelp:SetPoint("RIGHT", gClose, "LEFT", -4, 0)
tip(gHelp, "MekkaBoy", function() return (MB.HelpText and MB.HelpText() or "/mb help") .. "\nClick: show or hide the keys." end)
gHelp:SetScript("OnClick", function()
    if MB.ToggleKeyDrawer then MB.ToggleKeyDrawer() elseif MB.commands.help then MB.commands.help.run("") end
end)
function MB.glassFace(name) return glassFaces[name] end
MB.glassButtons = { mem = mems, rewind = gRew, ff = gFF, volume = gVol, close = gClose, help = gHelp }

local look = "console"
local sizeW, sizeH = Lay.bodyW, Lay.bodyH
function MB.WindowSize() return sizeW, sizeH end
local function glassColors()
    return GLASS[colorway()] or GLASS.gunmetal
end
local function paintGlass()
    local c = glassColors()
    local a = MB.Opt("glassAlpha", 0.66)
    paneBg:SetColorTexture(c.bg[1], c.bg[2], c.bg[3], a)
    for _, t in ipairs(edges) do t:SetColorTexture(c.edge[1], c.edge[2], c.edge[3], c.edge[4]) end
    for _, b in ipairs(glassButtons) do
        b.face:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], 0.08)
        b.label:SetTextColor(c.ink[1], c.ink[2], c.ink[3])
    end
    if look == "glass" then
        status:SetTextColor(c.ink[1], c.ink[2], c.ink[3])
        flightText:SetTextColor(c.soft[1], c.soft[2], c.soft[3])
        flightText:SetShadowColor(0, 0, 0, 0)
    end
    if powered then dot:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 1) else dot:SetColorTexture(c.soft[1], c.soft[2], c.soft[3], 0.5) end
    if MB.PaintKeyDrawer then MB.PaintKeyDrawer() end
    if MB.PaintFriends then pcall(MB.PaintFriends) end
end
MB.PaintGlass = paintGlass
function MB.GlassColors() return glassColors(), MB.Opt("glassAlpha", 0.66) end    -- (the key drawer wears them too: UI/KeyDrawer.lua)

-- the parts only the console has
local consoleParts = { body, needle, knob }
for _, b in pairs(MB.buttons) do consoleParts[#consoleParts + 1] = b end

function MB.Look() return look end
local function applyLook()
    look = (MB.Opt("look", "glass") == "console") and "console" or "glass"
    local glassy = look == "glass"
    for _, part in ipairs(consoleParts) do part:SetShown(not glassy) end
    for _, t in pairs(pressGlow) do t:Hide() end
    pane:SetShown(glassy)
    if glassy then
        sizeW, sizeH = glassW, glassH
        win:SetSize(glassW, glassH)
        at(screen, G_PAD, G_TOP, scr[3], scr[4])
        status:ClearAllPoints()
        status:SetPoint("LEFT", pane, "TOPLEFT", G_PAD + 16, -G_TOP / 2)
        status:SetWidth(scr[3] - 80)
        status:SetJustifyH("LEFT")
        flightText:ClearAllPoints()
        flightText:SetPoint("RIGHT", gVol, "LEFT", -10, 0)
        lamp:Hide()
        paintGlass()
    else
        sizeW, sizeH = Lay.bodyW, Lay.bodyH
        win:SetSize(Lay.bodyW, Lay.bodyH)
        at(screen, scr[1], scr[2], scr[3], scr[4])
        at(status, sp[1] + 6, sp[2] + 1, sp[3] - 12, sp[4] - 2)
        status:SetJustifyH("CENTER")
        status:SetTextColor(1, 0.86, 0.55)
        flightText:ClearAllPoints()
        flightText:SetPoint("CENTER", win, "TOPLEFT", ga[1], -(ga[2] + ga[3] + 12))
        flightText:SetTextColor(0.25, 0.16, 0.05)
        flightText:SetShadowColor(1, 0.9, 0.6, 0.5)
        lamp:SetShown(powered)
        if MB.PaintKeyDrawer then MB.PaintKeyDrawer() end
    end
    if MB.ApplyScale and MB.DB then pcall(MB.ApplyScale) end
end
MB.ApplyLook = applyLook
function MB.SetLook(v)
    v = (v or ""):lower()
    if v == "minimal" or v == "glass" then v = "glass" elseif v ~= "console" then return false end
    MB.DB().opt.look = v
    applyLook()
    return true
end
MB.LOOK_WORDS = { glass = "Minimal", console = "Console" }
MB.onLogin[#MB.onLogin + 1] = applyLook

-- the bar under the picture dims while the mouse is elsewhere (it is still there, and works, at a glance)
pane:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t < 0.1 then return end
    self.t = 0
    local over = win:IsMouseOver()
    bar:SetAlpha(over and 1 or 0.45)
end)

-- ---------------------------------------------------- scale, position ---
-- One game pixel is 2 design units; the window is scaled so that this is
-- a whole number of real screen pixels (no seams between pixels).
function MB.ApplyScale()
    local px = 1
    if GetPhysicalScreenSize then
        local _, ph = GetPhysicalScreenSize()
        local s = UIParent:GetEffectiveScale()
        if ph and ph > 0 and s and s > 0 then px = 768 / ph / s end
    end
    local k = MB.Opt("scale", nil)
    if not k then
        k = math.floor(2 / px + 0.5)          -- about 2 UI units per pixel ...
        local room, across = UIParent:GetHeight() or 768, UIParent:GetWidth() or 1024
        -- ... unless that is taller than the screen, or takes up most of its width
        local w, h = MB.WindowSize()
        while k > 1 and (h * k * px / 2 > room * 0.86 or w * k * px / 2 > across * 0.62) do k = k - 1 end
    end
    if k < 1 then k = 1 elseif k > 6 then k = 6 end
    win:SetScale(k * px / 2)
    return k
end

function MB.RestorePosition()
    local pos = MB.Opt("pos", nil)
    win:ClearAllPoints()
    if pos and pos[1] then
        win:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        win:SetPoint("CENTER")
    end
end

MB.SetScreenMessage("")
MB.SetFlight(nil, nil)
