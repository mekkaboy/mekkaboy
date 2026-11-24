-- (0.25) The Controls card: every button with its key and its controller button, changed by clicking one and pressing
-- the new key (or controller button); Escape cancels. Two switches on top: play with a controller, and fast-forward
-- as a switch instead of held. Opened from the settings page (Controls), /mb controls, or the key drawer's line.
-- It asked for itself: players found /mb bind only by asking us.
local _, MB = ...
local Print = MB.Print

local W, ROW = 460, 20
local card, rows, waiting = nil, {}, nil       -- waiting = { button, pad (true: a controller button) }
local C = MB.CardColors

local PRETTY = { BACKSPACE = "Backspace", ENTER = "Enter", TAB = "Tab", SPACE = "Space", UP = "Up", DOWN = "Down",
                 LEFT = "Left", RIGHT = "Right", ["`"] = "`",
                 PAD1 = "A", PAD2 = "B", PAD3 = "X", PAD4 = "Y", PAD5 = "Pad 5", PAD6 = "Pad 6",
                 PADDUP = "D-pad up", PADDDOWN = "D-pad down", PADDLEFT = "D-pad left", PADDRIGHT = "D-pad right",
                 PADFORWARD = "Menu", PADBACK = "View", PADLSHOULDER = "LB", PADRSHOULDER = "RB",
                 PADLTRIGGER = "LT", PADRTRIGGER = "RT", PADLSTICK = "Left stick click", PADRSTICK = "Right stick click",
                 PADSOCIAL = "Share", PADSYSTEM = "Guide" }
local function pretty(label)
    if not label then return "-" end
    local t = {}
    for k in label:gmatch("[^ ]+") do if k ~= "or" then t[#t + 1] = PRETTY[k] or k end end
    return #t > 0 and table.concat(t, " or ") or "-"
end
MB.PrettyKey = pretty

local function refresh()
    if not card then return end
    for _, r in ipairs(rows) do
        local kw = waiting and waiting.button == r.button and not waiting.pad
        local pw = waiting and waiting.button == r.button and waiting.pad
        r.key.text:SetText(kw and "Press a key..." or pretty(MB.KeyLabel(r.button)))
        r.pad.text:SetText(pw and "Press a button..." or pretty(MB.PadLabel(r.button)))
        for _, cell in ipairs({ { r.key, kw }, { r.pad, pw } }) do
            local c, on = cell[1], cell[2]
            if on then c.face:SetColorTexture(C.PICK[1], C.PICK[2], C.PICK[3], 0.35) c.text:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
            else c.face:SetColorTexture(1, 1, 1, 0.05) c.text:SetTextColor(C.INK[1], C.INK[2], C.INK[3]) end
        end
        local controller = MB.Opt("controller", false)
        r.pad:SetAlpha(controller and 1 or 0.45)
    end
    card.ctl:SetChecked(MB.Opt("controller", false) and true or false)
    card.ff:SetChecked(MB.Opt("ffToggle", false) and true or false)
    card.hint:SetText(waiting and "Escape cancels." or "Click a key or a button to change it.")
end

local function stopWaiting()
    waiting = nil
    if card then
        card:EnableKeyboard(false)
        if card.EnableGamePadButton then pcall(card.EnableGamePadButton, card, false) end
    end
    refresh()
end
-- a key or controller button arrived while the card waits for one: true when it was taken
local function take(key, fromPad)
    if not waiting then return false end
    if key == "ESCAPE" then stopWaiting() return true end
    if fromPad ~= waiting.pad then
        Print(waiting.pad and "That was a key: press a button on the controller (Escape cancels)." or "That was a controller button: press a key (Escape cancels).")
        return true
    end
    local name, why = MB.BindButton(waiting.button, key)
    if name then Print(("%s is now on %s."):format(name, pretty(key))) elseif why then Print(why) end
    stopWaiting()
    return true
end
MB.CapturingInput = function(key, fromPad) return take(key, fromPad) end

local function startWaiting(button, pad)
    if pad and not MB.Opt("controller", false) then
        Print("Switch on \"Play with a controller\" first, at the top of this card.")
        return
    end
    waiting = { button = button, pad = pad }
    card:EnableKeyboard(true)
    if pad and card.EnableGamePadButton then pcall(card.EnableGamePadButton, card, true) end
    refresh()
end

local function cell(parent, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, ROW - 2)
    local face = b:CreateTexture(nil, "BACKGROUND")
    face:SetAllPoints(b)
    local glow = b:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints(b)
    glow:SetColorTexture(1, 1, 1, 0.08)
    local text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -8, 0)
    text:SetJustifyH("LEFT")
    b.face, b.text = face, text
    return b
end

local function check(parent, label, tip, onClick)
    local b = CreateFrame("CheckButton", nil, parent)
    b:SetSize(24, 24)
    b:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    b:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    local words = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    words:SetPoint("LEFT", b, "RIGHT", 4, 1)
    words:SetText(label)
    words:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
    local small = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    small:SetPoint("TOPLEFT", words, "BOTTOMLEFT", 0, -2)
    small:SetWidth(W - 80)
    small:SetJustifyH("LEFT")
    small:SetText(tip)
    small:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    b:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) refresh() end)
    return b
end

local function build()
    card = MB.CardFrame("MekkaBoyControls", W)
    card:SetPoint("TOP", UIParent, "TOP", 0, -90)
    card:SetScript("OnKeyDown", function(self, key)
        if waiting then self:SetPropagateKeyboardInput(false) take(key, false)
        else self:SetPropagateKeyboardInput(true) end
    end)
    pcall(card.SetScript, card, "OnGamePadButtonDown", function(_, button) take(button, true) end)
    card:SetScript("OnHide", function() if waiting then stopWaiting() end end)
    local y = -16
    local function line(font, str, color, gap)
        local fs = card:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", 20, y)
        fs:SetWidth(W - 40)
        fs:SetJustifyH("LEFT")
        fs:SetText(str)
        fs:SetTextColor(color[1], color[2], color[3])
        y = y - gap
        return fs
    end
    line("GameFontNormalSmall", "CONTROLS", C.SOFT, 18)
    line("GameFontHighlightLarge", "Change the controls", C.INK, 30)
    card.ctl = check(card, "Play with a controller", "Also switches on the game's own controller support. Works while MekkaBoy is open.",
        function(on)
            local turned = MB.SetController(on)
            if on then
                Print(turned and "Controller on. The game's own controller support is switched on too (Options > Controls)."
                    or "Controller on: it plays MekkaBoy while the console is open.")
            else Print("Controller off for MekkaBoy.") end
            if MB.KeyDrawerOpen and MB.KeyDrawerOpen() then MB.RefreshKeyDrawer() end
        end)
    card.ctl:SetPoint("TOPLEFT", 16, y)
    if not (MB.ControllerSupported and MB.ControllerSupported()) then card.ctl:Disable() end
    y = y - 44
    card.ff = check(card, "Toggle fast-forward", "On: press once to speed up, again to go back to normal. Off: hold to fast-forward.",
        function(on) MB.DB().opt.ffToggle = on or nil if MB.KeyDrawerOpen and MB.KeyDrawerOpen() then MB.RefreshKeyDrawer() end end)
    card.ff:SetPoint("TOPLEFT", 16, y)
    y = y - 50
    -- the table: button, key, controller button
    local NAME_W, KEY_W, PAD_W = 150, 124, 124
    local hk = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hk:SetPoint("TOPLEFT", 20 + NAME_W, y) hk:SetText("KEYBOARD") hk:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    local hp = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hp:SetPoint("TOPLEFT", 20 + NAME_W + KEY_W + 8, y) hp:SetText("CONTROLLER") hp:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    y = y - 16
    for _, button in ipairs(MB.BUTTON_ORDER) do
        local name = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOPLEFT", 20, y - 3)
        name:SetWidth(NAME_W - 8)
        name:SetJustifyH("LEFT")
        name:SetText((((MB.BUTTON_NAMES[button] or button):gsub(" %(hold%)", ""))))
        name:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
        local key = cell(card, KEY_W)
        key:SetPoint("TOPLEFT", 20 + NAME_W, y)
        key:SetScript("OnClick", function() startWaiting(button, false) end)
        local pad = cell(card, PAD_W)
        pad:SetPoint("TOPLEFT", 20 + NAME_W + KEY_W + 8, y)
        pad:SetScript("OnClick", function() startWaiting(button, true) end)
        rows[#rows + 1] = { button = button, key = key, pad = pad }
        y = y - ROW
    end
    y = y - 12
    local done = MB.CardButton(card, "Done", 96, true)
    done:SetPoint("TOPLEFT", card, "TOPLEFT", 20, y)
    done:SetScript("OnClick", function() card:Hide() end)
    local reset = MB.CardButton(card, "Reset all", 96, false)
    reset:SetPoint("LEFT", done, "RIGHT", 8, 0)
    reset:SetScript("OnClick", function() MB.ResetBindings() Print("Controls back to defaults.") refresh() end)
    card.hint = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.hint:SetPoint("LEFT", reset, "RIGHT", 12, 0)
    card.hint:SetPoint("RIGHT", card, "RIGHT", -20, 0)
    card.hint:SetJustifyH("LEFT")
    card.hint:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    y = y - 28 - 16
    card:SetHeight(-y)
end

function MB.OpenControls()
    if InCombatLockdown and InCombatLockdown() then Print("The controls stay shut while you are in combat.") return end
    if not card then build() end
    waiting = nil
    card:Show()
    if card.fade then card.fade:Stop() card.fade:Play() end
    refresh()
end
function MB.ControlsCard() return card end      -- (for tests)

MB.AddCommand("controls", "controls - change the keys and controller buttons, play with a controller, fast-forward as a switch", function() MB.OpenControls() end)
