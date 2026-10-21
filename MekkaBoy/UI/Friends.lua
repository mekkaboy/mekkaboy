-- The friends list, the invitation pop-up, and the small MekkaBoy mark beside a target's portrait (Friends.lua is the
-- part that talks; this is the part you see). Glass panels in the colorway in use, like the Minimal look and the card.
local _, MB = ...
local F = MB.Friends
if not F then return end

local ROWS = 10
local GOLD = { 0.85, 0.65, 0.25 }            -- (only the WoW tooltip on the mark still uses it)
local X = "\195\151"

-- Glass, like the Minimal look and the team card (UI/Body.lua's colorways): every texture and text here has a role,
-- and paint() colours a panel from the colorway in use each time it is shown.
local DEFAULT = { bg = { 0.10, 0.11, 0.13 }, ink = { 0.91, 0.93, 0.94 }, soft = { 0.66, 0.71, 0.73 }, accent = { 0.56, 0.76, 0.82 }, edge = { 1, 1, 1, 0.16 } }
local function colors() return (MB.GlassColors and MB.GlassColors()) or DEFAULT end
local function light(c) return (c.bg[1] + c.bg[2] + c.bg[3]) > 1.5 end
local function hex(k) return ("|cff%02x%02x%02x"):format(math.floor(k[1] * 255 + 0.5), math.floor(k[2] * 255 + 0.5), math.floor(k[3] * 255 + 0.5)) end
-- text colours for words inside a line: a name or a state (the accent, a shade darker on a light colorway), good news,
-- bad news, and quiet
local function tones(c)
    local lt = light(c)
    local a = c.accent
    local strong = lt and { a[1] * 0.75, a[2] * 0.75, a[3] * 0.75 } or a
    return { name = hex(strong), good = hex(lt and { 0.16, 0.46, 0.22 } or { 0.45, 0.85, 0.55 }),
             bad = hex(lt and { 0.62, 0.20, 0.10 } or { 0.98, 0.55, 0.42 }), quiet = hex(c.soft) }
end
-- the old gold and green codes some messages carry, turned into this colorway's own
local function recolor(text, c)
    local t = tones(c)
    return (tostring(text or ""):gsub("|cffffd100", t.name):gsub("|cff60ff60", t.good):gsub("|cffff8060", t.bad):gsub("|cff909090", t.quiet):gsub("|cffd0d0d0", t.quiet))
end

local function paint(f)
    local c = colors()
    for _, t in ipairs(f.texs) do
        local r = t.role
        if r == "bg" then t:SetColorTexture(c.bg[1], c.bg[2], c.bg[3], 0.96)
        elseif r == "edge" then t:SetColorTexture(c.edge[1], c.edge[2], c.edge[3], math.max(c.edge[4] or 0.2, 0.22))
        elseif r == "accent" then t:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 1)
        elseif r == "face" then t:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], t.hot and 0.16 or 0.08)
        elseif r == "pface" then t:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], t.hot and 0.32 or 0.20)
        elseif r == "row" then t:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], t.odd and 0.06 or 0.03) end
    end
    for _, fs in ipairs(f.texts) do
        local k = fs.role == "soft" and c.soft or c.ink
        fs:SetTextColor(k[1], k[2], k[3])
    end
end
local function tex(f, parent, role, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t.role = role
    f.texs[#f.texs + 1] = t
    return t
end
local function edges(f, frame, role)
    for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = tex(f, frame, role or "edge", "BORDER")
        t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
    end
end
local function panelBase(name, w, h)
    local f = CreateFrame("Frame", name, UIParent)
    f.texs, f.texts = {}, {}
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    tex(f, f, "bg", "BACKGROUND"):SetAllPoints(f)
    edges(f, f)
    f:HookScript("OnShow", function(self) paint(self) end)
    return f
end
local function label(parent, font, x, y, w, role, owner)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    if w then fs:SetWidth(w) end
    fs:SetJustifyH("LEFT")
    fs.role = role or "ink"
    local f = owner or parent
    if f.texts then f.texts[#f.texts + 1] = fs end
    return fs
end
local function makeButton(owner, parent, text, w, primary, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 24)
    b.bg = tex(owner, b, primary and "pface" or "face", "BACKGROUND")
    b.bg:SetAllPoints(b)
    if primary then edges(owner, b, "accent") end
    local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("CENTER")
    t:SetWidth(w - 6)
    t:SetText(text)
    t.role = "ink"
    owner.texts[#owner.texts + 1] = t
    b.label = t
    b.enabled = true
    b:SetScript("OnClick", function(self, ...) if self.enabled ~= false then onClick(self, ...) end end)
    b:SetScript("OnEnter", function(self) self.bg.hot = true paint(owner) end)
    b:SetScript("OnLeave", function(self) self.bg.hot = nil paint(owner) end)
    function b:Set(str, enabled)
        t:SetText(str)
        self.enabled = enabled ~= false
        self:SetAlpha(self.enabled and 1 or 0.45)
    end
    return b
end
-- (the names kept from before: the main answer, and the quiet one)
local function goldButton(owner, parent, text, w, onClick) return makeButton(owner, parent, text, w, true, onClick) end
local function quietButton(owner, parent, text, w, onClick) return makeButton(owner, parent, text, w, false, onClick) end
local function header(f, title, sub)
    local dot = tex(f, f, "accent")
    dot:SetSize(8, 8)
    dot:SetPoint("TOPLEFT", 16, -19)
    f.title = label(f, "GameFontHighlight", 32, -14, f:GetWidth() - 32 - 40, "ink")
    f.title:SetText(title)
    if sub then
        f.sub = label(f, "GameFontHighlightSmall", 32, -32, f:GetWidth() - 32 - 16, "soft")
        f.sub:SetText(sub)
    end
    local rule = tex(f, f, "edge")
    rule:SetPoint("TOPLEFT", 16, -50) rule:SetPoint("TOPRIGHT", -16, -50) rule:SetHeight(1)
    f.close = quietButton(f, f, X, 22, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", -8, -8)
end

-- ---------------------------------------------------------------- the list ---
local win
local function rowsData()
    local out = {}
    for _, p in ipairs(F.List()) do out[#out + 1] = { name = p.name, peer = p } end
    for _, r in ipairs(F.Recent()) do
        local seen = false
        for _, o in ipairs(out) do if MB.Link.NameIs(o.name, r.name) then seen = true o.recent = r end end
        if not seen then out[#out + 1] = { name = r.name, recent = r } end
    end
    local function rank(o)
        local st = F.Status(o.name)
        if st then return 0 end
        local ok = F.Fits(o.peer)
        if o.peer and o.peer.state == "ready" and ok then return 1 end
        if o.peer and ok then return 2 end
        if o.peer then return 3 end
        return 4
    end
    table.sort(out, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return MB.Link.Short(a.name):lower() < MB.Link.Short(b.name):lower()
    end)
    return out
end
local STATE_WORDS = { ready = "playing", paused = "console closed", linked = "linked with someone", off = "no game in" }
local function describe(o, t)
    local p = o.peer
    if not p then
        return ("%sLinked with you before%s. Not heard from just now.|r"):format(t.quiet, o.recent and o.recent.game ~= "" and (" (" .. o.recent.game .. ")") or "")
    end
    local game = p.game ~= "" and p.game or "no game in"
    local ok, why = F.Fits(p)
    local color = ok and t.good or (ok == false and t.bad or t.quiet)
    return ("%s, %s. %s%s|r"):format(game, STATE_WORDS[p.state] or p.state, color, why:sub(1, 1):upper() .. why:sub(2) .. ".")
end
local function refresh()
    if not (win and win:IsShown()) then return end
    local t = tones(colors())
    local data = rowsData()
    for i = 1, ROWS do
        local row, o = win.rows[i], data[i]
        if o then
            row:Show()
            row.who:SetText(MB.Link.Short(o.name))
            row.what:SetText(describe(o, t))
            local st, words = F.Status(o.name)
            local ok = F.Fits(o.peer)
            row.name = o.name
            if st == "linked" then row.go:Set("Linked", false)
            elseif st == "calling" then row.go:Set("Cancel")
            elseif st == "answering" then row.go:Set("Linking...", false)
            elseif st == "invited" then row.go:Set("Answer")
            elseif ok == false then row.go:Set("Can't link", false)
            else row.go:Set(o.peer and "Link" or "Ask again") end
            row.state:SetText(words and (t.name .. words .. "|r") or "")
        else
            row:Hide()
        end
    end
    local mode = MB.PlayMode()
    if #data == 0 then win.empty:Show() else win.empty:Hide() end
    win.empty:SetText(mode == "solo" and "You are playing Solo, so nobody is asked. /mb play open or friends changes it."
        or "Nobody with MekkaBoy heard from yet. Target a player, or ask your group or guild to install it. People in your group, friends list and guild show up here.")
    win.share:SetText(("How you play: %s%s|r (/mb play)"):format(t.name, MB.PLAY_WORDS[mode]))
end
F.Changed = function() refresh() if F.UpdateTargetMark then F.UpdateTargetMark() end end

local W = 420
local function build()
    win = panelBase("MekkaBoyFriendsWindow", W, 64 + ROWS * 34 + 44)
    win:SetPoint("CENTER", 0, 80)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    header(win, "MekkaBoy friends", "Who around you has MekkaBoy, and whether your games can link.")
    win.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, win)
        row:SetSize(W - 32, 32)
        row:SetPoint("TOPLEFT", 16, -60 - (i - 1) * 34)
        local shade = tex(win, row, "row", "BACKGROUND")
        shade:SetAllPoints(row)
        shade.odd = i % 2 == 1
        row.who = label(row, "GameFontHighlight", 8, -3, 180, "ink", win)
        row.state = label(row, "GameFontHighlightSmall", 190, -4, 110, "soft", win)
        row.what = label(row, "GameFontHighlightSmall", 8, -18, W - 32 - 92, "soft", win)
        row.go = goldButton(win, row, "Link", 76, function(self)
            local st = F.Status(row.name)
            if st == "calling" then F.Cancel()
            elseif st == "invited" then F.Accept()
            else F.Call(row.name) end
            refresh()
        end)
        row.go:SetPoint("RIGHT", -6, 0)
        win.rows[i] = row
    end
    win.empty = label(win, "GameFontHighlightSmall", 24, -72, W - 48, "soft")
    win.share = label(win, "GameFontHighlightSmall", 16, -(64 + ROWS * 34) - 6, 200, "soft")
    local again = quietButton(win, win, "Ask again", 80, function() F.AskAll() refresh() end)
    again:SetPoint("BOTTOMRIGHT", -16, 12)
    -- (your Pokedex across every save, opened where this list was: UI/Card.lua)
    win.dex = quietButton(win, win, "My Pok\195\169dex", 96, function() if MB.Card and MB.Card.ShowDex then MB.Card.ShowDex(nil, win) end end)
    win.dex:SetPoint("RIGHT", again, "LEFT", -8, 0)
    if UISpecialFrames then table.insert(UISpecialFrames, "MekkaBoyFriendsWindow") end      -- (Esc closes it)
    local acc, askAcc = 0, 0
    win:SetScript("OnUpdate", function(_, e)
        acc, askAcc = acc + e, askAcc + e
        if askAcc >= 60 then askAcc = 0 F.AskAll() end             -- (an open list stays fresh: once a minute)
        if acc >= 1 then acc = 0 refresh() end
    end)
    win:Hide()
end
function F.Open()
    if not win then build() end
    if win:IsShown() then win:Hide() return end
    if MB.Card and MB.Card.DexPanel and MB.Card.DexPanel() then MB.Card.DexPanel():Hide() end     -- (one panel at a time)
    if MB.Card and MB.Card.CardPanel and MB.Card.CardPanel() then MB.Card.CardPanel():Hide() end
    F.AskAll()
    win:Show()
    refresh()
end
function F.Window() return win end

-- --------------------------------------------------------- the invitation ---
local pop
local function buildPop()
    pop = panelBase("MekkaBoyInvitePopup", 340, 100)
    pop:SetPoint("TOP", 0, -140)
    pop.text = label(pop, "GameFontHighlight", 16, -16, 308)
    pop.yes = goldButton(pop, pop, "Link", 120, function() F.Accept() end)
    pop.yes:SetPoint("BOTTOMLEFT", 40, 12)
    pop.no = quietButton(pop, pop, "Not now", 120, function() F.Decline() end)
    pop.no:SetPoint("BOTTOMRIGHT", -40, 12)
    pop:SetScript("OnUpdate", function(self)
        if self.until_ and GetTime() > self.until_ then F.Decline() end
    end)
    pop:Hide()
end
function F.ShowInvite(inv)
    if not pop then buildPop() end
    local p = F.Peer(inv.sender)
    local game = p and p.game ~= "" and (" (" .. p.game .. ")") or ""
    local ok, why = F.Fits(p or { protocol = MB.PROTOCOL, family = inv.family, game = "", version = MB.VERSION })
    pop.text:SetText(recolor(("|cffffd100%s|r wants to link MekkaBoys with you%s.\n%s"):format(MB.Link.Short(inv.sender), game,
        ok == false and ("|cffff8060Your games can't link: " .. why .. ".|r") or (MB.IsRunning() and "" or "Your game starts when you press Link.")), colors()))
    pop.yes:Set("Link", ok ~= false)
    pop.until_ = GetTime() + 85
    pop:Show()
    if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then pcall(PlaySound, SOUNDKIT.READY_CHECK) end
    refresh()
end
function F.HideInvite() if pop then pop:Hide() end refresh() end

-- a question with two answers (a trade where you stand, undoing a trade: GBA/Trade3.lua). One at a time; seconds = 0
-- keeps it up until answered.
local ask
local function answered(yes)
    if not ask then return end
    local f = (yes == "alt" and ask.onAlt) or (yes and yes ~= "alt" and ask.onYes) or (not yes and ask.onNo) or nil
    ask:Hide()
    ask.id, ask.onYes, ask.onNo, ask.onAlt, ask.until_ = nil, nil, nil, nil, nil
    if f then f() end
end
-- (altText, onAlt: an optional second choice beside the first, e.g. Trade | Battle | Not now)
function F.Ask(id, text, yesText, noText, onYes, onNo, seconds, altText, onAlt)
    if not ask then
        ask = panelBase("MekkaBoyAskPopup", 380, 128)
        ask:SetPoint("TOP", 0, -250)
        ask.text = label(ask, "GameFontHighlight", 16, -16, 348)
        ask.yes = goldButton(ask, ask, "Yes", 140, function() answered(true) end)
        ask.yes:SetPoint("BOTTOMLEFT", 36, 12)
        ask.no = quietButton(ask, ask, "No", 140, function() answered(false) end)
        ask.no:SetPoint("BOTTOMRIGHT", -36, 12)
        ask.alt = goldButton(ask, ask, "", 100, function() answered("alt") end)
        ask.alt:SetPoint("BOTTOM", 0, 12)
        ask:SetScript("OnUpdate", function(self) if self.until_ and GetTime() > self.until_ then answered(false) end end)
        ask:Hide()
    end
    ask.id, ask.onYes, ask.onNo, ask.onAlt = id, onYes, onNo, onAlt
    ask.text:SetText(recolor(text, colors()))
    ask.yes:Set(yesText or "Yes", true)
    local three = altText ~= nil
    ask.yes:SetWidth(three and 100 or 140) ask.no:SetWidth(three and 100 or 140)
    ask.yes:ClearAllPoints() ask.yes:SetPoint("BOTTOMLEFT", three and 16 or 36, 12)
    ask.no:ClearAllPoints() ask.no:SetPoint("BOTTOMRIGHT", three and -16 or -36, 12)
    if three then ask.alt:Set(altText, true) ask.alt:Show() else ask.alt:Hide() end
    if ask.no.label then ask.no.label:SetText(noText or "No") end
    ask.until_ = (seconds and seconds > 0) and (GetTime() + seconds) or nil
    ask:Show()
    if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then pcall(PlaySound, SOUNDKIT.READY_CHECK) end
end
function F.HideAsk(id) if ask and ask:IsShown() and (not id or ask.id == id) then ask:Hide() ask.id = nil end end
function F.AskPopup() return ask end
function F.Popup() return pop end

-- a new colorway while one of these is open
function MB.PaintFriends()
    for _, f in ipairs({ win, pop, ask }) do if f and f:IsShown() then paint(f) end end
    refresh()
end

-- ----------------------------------------------- the mark on your target ---
local mark
local function buildMark()
    mark = CreateFrame("Button", "MekkaBoyTargetMark", UIParent)
    mark:SetSize(20, 20)
    mark:SetFrameStrata("HIGH")
    local icon = mark:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(mark)
    icon:SetTexture("Interface\\AddOns\\MekkaBoy\\Art\\icon")
    mark.icon = icon
    -- a click opens their team card (UI/Card.lua); its Link button does what the click itself did before (F.Call)
    mark:SetScript("OnClick", function()
        local spellings = MB.Link.UnitSpellings and MB.Link.UnitSpellings("target") or {}
        local p
        for _, s in ipairs(spellings) do p = p or F.Peer(s) end
        if not p then return end
        if MB.Card and MB.Card.ShowCard then MB.Card.ShowCard(p.name) else F.Call(p.name) end
    end)
    mark:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        local p = self.peer
        if not p then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("MekkaBoy " .. p.version, GOLD[1], GOLD[2], GOLD[3])
        local ok, why = F.Fits(p)
        GameTooltip:AddLine((p.game ~= "" and p.game or "No game in") .. ": " .. why .. ".", 1, 1, 1, true)
        GameTooltip:AddLine(ok and "Click for their team card, and to link." or "Click for their team card.", 0.6, 1, 0.6)
        GameTooltip:Show()
    end)
    mark:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    mark:Hide()
end
function F.UpdateTargetMark()
    if not mark then buildMark() end
    mark.peer = nil
    if (InCombatLockdown and InCombatLockdown()) or not (UnitExists and UnitExists("target")) then mark:Hide() return end
    local p
    for _, s in ipairs(MB.Link.UnitSpellings and MB.Link.UnitSpellings("target") or {}) do p = p or F.Peer(s) end
    if not p then mark:Hide() return end
    mark.peer = p
    mark:ClearAllPoints()
    if TargetFrame and TargetFrame.IsShown and TargetFrame:IsShown() then
        mark:SetPoint("BOTTOMRIGHT", TargetFrame, "TOPRIGHT", -40, -22)
    else
        mark:SetPoint("TOP", UIParent, "TOP", 120, -60)
    end
    local ok = F.Fits(p)
    mark.icon:SetDesaturated(ok == false)
    mark:Show()
end
F.TargetChanged = F.UpdateTargetMark
function F.TargetMark() return mark end
