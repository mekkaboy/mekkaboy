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
-- cogs first (behind the body); they turn while a game is running
local gears = {}
for i, key in ipairs({ "gear1", "gear2" }) do
    local g = Lay[key]
    local t = win:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(ART .. "gear.tga")
    at(t, g[1] - g[3], g[2] - g[3], g[3] * 2)
    gears[i] = { tex = t, dir = (i == 1) and 1 or -1.75, angle = (i == 1) and 0 or 0.26 }
    t:SetRotation(gears[i].angle)
end

-- the body picture hangs over the frame's edges (pipe, cogs, steam stack)
local body = win:CreateTexture(nil, "ARTWORK")
body:SetTexture(ART .. "body.tga")
body:SetTexCoord(0, 1, 0, Lay.usedH / Lay.canvasH)
at(body, -Lay.bodyX, -Lay.bodyY, Lay.canvasW, Lay.usedH)

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
    lamp:SetShown(powered)
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
    if powered then
        for _, g in ipairs(gears) do
            g.angle = g.angle + elapsed * 0.9 * g.dir
            g.tex:SetRotation(g.angle)
        end
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

-- a clickable patch of the body: x, y = centre
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
    tip(btn, "MekkaBoy", function() return MB.HelpText and MB.HelpText() or "/mb help" end)
    btn:SetScript("OnClick", function() if MB.commands.help then MB.commands.help.run("") end end)
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
        while k > 1 and (Lay.bodyH * k * px / 2 > room * 0.86 or Lay.bodyW * k * px / 2 > across * 0.62) do k = k - 1 end
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
