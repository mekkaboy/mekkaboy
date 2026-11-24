-- (0.25) Small cards: one job each, in the look of the Together cards (dark glass, a teal rule down the left edge, a
-- small kicker, a title, a few lines of body text, then the buttons: one primary, the rest quiet). Built once per card
-- id, shown at the top middle of the screen, never in combat, closed by Escape. MB.ShowCard(id, spec) builds and shows
-- one; spec = { kicker, title, body, step (a line in white under the body), buttons = { { label, fn, primary, width } },
-- note (small text beside the buttons) }. A button's fn runs after the card has closed.
local _, MB = ...

local INK, SOFT, LINE, PICK = { 0.91, 0.93, 0.94 }, { 0.70, 0.75, 0.77 }, { 1, 1, 1, 0.22 }, { 0.56, 0.76, 0.82 }
local W = 360
local cards = {}
MB.CardColors = { INK = INK, SOFT = SOFT, LINE = LINE, PICK = PICK }

-- a flat button: primary is filled teal with dark text, quiet is a faint fill with soft text; pressed moves the label
function MB.CardButton(parent, label, w, primary)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 28)
    local face = b:CreateTexture(nil, "BACKGROUND")
    face:SetAllPoints(b)
    local glow = b:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints(b)
    glow:SetColorTexture(1, 1, 1, primary and 0.18 or 0.08)
    local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetText(label)
    if primary then
        face:SetColorTexture(PICK[1], PICK[2], PICK[3], 1)
        text:SetTextColor(0.06, 0.08, 0.09)
    else
        face:SetColorTexture(1, 1, 1, 0.06)
        text:SetTextColor(SOFT[1], SOFT[2], SOFT[3])
    end
    b:SetScript("OnMouseDown", function() text:SetPoint("CENTER", 0, -1) end)
    b:SetScript("OnMouseUp", function() text:SetPoint("CENTER", 0, 0) end)
    b.text, b.face = text, face
    return b
end

-- the dark glass panel with its edges and the teal rule; returns the frame
function MB.CardFrame(name, w)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(w or W, 100)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0.06, 0.08, 0.09, 0.94)
    for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        t:SetColorTexture(LINE[1], LINE[2], LINE[3], LINE[4])
    end
    local accent = f:CreateTexture(nil, "BORDER")
    accent:SetPoint("TOPLEFT", 0, 0) accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetWidth(3)
    accent:SetColorTexture(PICK[1], PICK[2], PICK[3], 1)
    if name and UISpecialFrames then table.insert(UISpecialFrames, name) end     -- (Escape closes it)
    local ag = f.CreateAnimationGroup and f:CreateAnimationGroup()
    if ag then
        local a = ag:CreateAnimation("Alpha")
        if a.SetFromAlpha then a:SetFromAlpha(0) a:SetToAlpha(1) else a:SetChange(1) end
        a:SetDuration(0.14)
        if a.SetSmoothing then a:SetSmoothing("OUT") end
        if ag.SetToFinalAlpha then ag:SetToFinalAlpha(true) end
        f.fade = ag
    end
    f:Hide()
    return f
end

local function build(id, spec)
    local w = spec.width or W
    local card = MB.CardFrame("MekkaBoyCard_" .. id, w)
    local y = -16
    local function text(font, str, gap, color)
        local fs = card:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", 20, y)
        fs:SetWidth(w - 40)
        fs:SetJustifyH("LEFT")
        fs:SetText(str)
        fs:SetTextColor(color[1], color[2], color[3])
        y = y - (gap or 20)
        return fs
    end
    if spec.kicker then text("GameFontNormalSmall", spec.kicker, 18, SOFT) end
    local title = text("GameFontHighlightLarge", spec.title or "", 0, INK)
    y = y - math.max(22, (title:GetStringHeight() or 22)) - 6
    if spec.body then
        local body = text("GameFontHighlight", spec.body, 0, SOFT)
        y = y - math.max(18, (body:GetStringHeight() or 18)) - 12
    end
    if spec.step then
        local step = text("GameFontHighlight", spec.step, 0, INK)
        y = y - math.max(18, (step:GetStringHeight() or 18)) - 14
    end
    local x = 20
    local last
    for _, b in ipairs(spec.buttons or { { "Got it", nil, true } }) do
        local bw = b[4] or 96
        local btn = MB.CardButton(card, b[1], bw, b[3])
        btn:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        btn:SetScript("OnClick", function()
            card:Hide()
            if b[2] then pcall(b[2]) end
        end)
        x = x + bw + 8
        last = btn
    end
    if spec.note and last then
        local note = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        note:SetPoint("LEFT", last, "RIGHT", 12, 0)
        note:SetPoint("RIGHT", card, "RIGHT", -20, 0)
        note:SetJustifyH("LEFT")
        note:SetTextColor(SOFT[1], SOFT[2], SOFT[3])
        note:SetText(spec.note)
    end
    y = y - 28 - 16
    card:SetHeight(-y)
    return card
end

function MB.ShowCard(id, spec)
    if InCombatLockdown and InCombatLockdown() then return false end
    local card = cards[id]
    if not card then card = build(id, spec) cards[id] = card end
    for other, c in pairs(cards) do if other ~= id and c:IsShown() then c:Hide() end end     -- (one card at a time)
    if not card:IsShown() then
        card:Show()
        if card.fade then card.fade:Stop() card.fade:Play() end
    end
    return true
end
function MB.HideCard(id) if cards[id] then cards[id]:Hide() end end
function MB.CardShown(id) return cards[id] and cards[id]:IsShown() or false end
function MB.Cards() return cards end      -- (for tests)
