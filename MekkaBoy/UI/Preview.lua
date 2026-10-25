-- The team preview: what a trade or battle where you stand asks with (GBA/Trade3.lua), like the screen competitive
-- players see before a match. Both teams side by side, "You" and the other player: each Pokemon's picture, nickname
-- (the species small beside it when the nickname is its own), level, type chips and held item. Nothing more of the
-- build (no moves, stats, abilities or HP). The data is GBA/Team3.lua's; the glass, colorways and pictures are the team
-- card's (UI/Card.lua's Card.Kit, DexIcons.lua).
--
-- Who sees what:
--   asked     "<name> wants to battle right where you stand", their game; both teams; the safety line; Not now and
--             Battle (or Trade). x and Esc are Not now. It answers itself Not now after 60 s, and says so.
--   asking    "Asking <name> to battle right where you stand" and where it has got to (saving, waiting for their
--             MekkaBoy, waiting for their answer, said yes); your team, and theirs once their MekkaBoy sends it
--             ("Waiting for their team..." until then; a plain line if theirs sends none: an older MekkaBoy); Cancel
--             (what /mb battle off does; x and Esc too). If it is called off, why, and Close.
-- An older MekkaBoy on the other side sends no team: the one asked then gets the plain pop-up of before (Trade3).
--
-- P.Show(o)   o = { role = "asked" | "asking", kind = "battle" | "trade", partner, game (their game's name),
--                   mine = team, mineGame, theirs = team or nil, theirsState = "ok" | "waiting" | "none",
--                   status (asking: the line under the title), onYes, onNo, seconds }
-- P.Update(o) the same fields, for the one shown;   P.Finish(why) asking only: called off, and why;   P.Hide()
local _, MB = ...
local Card, Team = MB.Card, MB.Team3
if not (Card and Card.Kit and Team) then return end
local K = Card.Kit
local Icons = MB.DexIcons
local P = {}
MB.Preview = P
local floor, max, min = math.floor, math.max, math.min

local MID, ELL, X = " \194\183 ", "\226\128\166", "\195\151"
local POKEMON = "Pok\195\169mon"
local W, PAD, GAP = 600, 16, 16
local COL = floor((W - PAD * 2 - GAP) / 2)
local ROW_H, ROW_GAP, ICON = 36, 3, 32
local TEXT_X, LV_W = 40, 40
local SPARE = 1.08                       -- (every line fits with 8% to spare: other UI scales and fonts)
local panel, view
local layout, guard                      -- (below)

-- ------------------------------------------------------------- measuring ---
local measure = {}
local function widthOf(font, s)
    local fs = measure[font]
    if not fs then
        fs = UIParent:CreateFontString(nil, "OVERLAY", font)
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        fs:Hide()
        measure[font] = fs
    end
    fs:SetText(s)
    return (fs:GetStringWidth() or 0) * SPARE
end
-- s cut (with ...) to fit w at that font; "" if not even one letter and the dots fit
local function cut(font, s, w)
    s = tostring(s or "")
    if widthOf(font, s) <= w then return s end
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    for n = #chars - 1, 1, -1 do
        local t = table.concat(chars, "", 1, n):gsub("%s+$", "") .. ELL
        if widthOf(font, t) <= w then return t end
    end
    return ""
end
local function place(fs, font, s, w)     -- the text, cut to w; the string's box is the text's own width
    local t = cut(font, s, w)
    fs:SetText(t)
    fs:SetWidth(max(1, math.ceil(widthOf(font, t))))
    return t, (t ~= "" and widthOf(font, t) or 0)
end

-- --------------------------------------------------------------- the words ---
local NAMES = { BPEE = "Emerald", BPRE = "FireRed", BPGE = "LeafGreen" }
local function words()
    local m = MB.Machine and MB.Machine()
    return m and Team.Words(m) or nil
end
local function speciesName(w, n)
    local s = w and w.speciesName(n)
    if not s then
        local d = MB.Dex and MB.Dex.Name and MB.Dex.Name(n)
        s = d and Team.TitleCase(d) or nil
    end
    return s or ("No. %d"):format(n or 0)
end
-- how a Pokemon reads in the list: { name, species (small, or nil), level, item, itemId, types = { i, ... }, egg, unknown }
local function line(w, e)
    if e.egg then return { name = "Egg", egg = true, types = {} } end
    if e.unknown or (e.species or 0) == 0 then return { name = POKEMON .. " not readable", unknown = true, level = e.level, types = {} } end
    local sp = speciesName(w, e.species)
    local nick = e.nick and e.nick:gsub("^%s+", ""):gsub("%s+$", "") or ""
    local out = { level = e.level, itemId = e.item or 0, types = {} }
    if nick == "" or nick:upper() == sp:upper() then out.name = sp else out.name, out.species = nick, sp end
    out.speciesName = sp
    if (e.item or 0) > 0 then out.item = (w and w.itemName(e.item)) or "Unknown item" else out.item = "No item" end
    local a, b = nil, nil
    if w then a, b = w.types(e.species) end
    if a then out.types[1] = a end
    if b then out.types[2] = b end
    return out
end
P.Line = line

-- ----------------------------------------------------------------- build ---
-- the classic type colours, by the game's type number (0 Normal ... 17 Dark; 9 is "???"), each with the darker or
-- white lettering that reads best on it
local TYPE_RGB = {
    [0] = "A8A878", "C03028", "A890F0", "A040A0", "E0C068", "B8A038", "A8B820", "705898", "B8B8D0",
    "68A090", "F08030", "6890F0", "78C850", "F8D030", "F85888", "98D8D8", "7038F8", "705848",
}
local WHITE_INK = { [1] = true, [3] = true, [7] = true, [16] = true, [17] = true }
local function rgb(hex) return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 } end
local TYPE_COL = {}
for i, h in pairs(TYPE_RGB) do TYPE_COL[i] = rgb(h) end
local INK_DARK, INK_WHITE = { 0.10, 0.10, 0.10 }, { 1, 1, 1 }
P.TypeColor = function(i) return TYPE_COL[i], TYPE_COL[i] and (WHITE_INK[i] and INK_WHITE or INK_DARK) end
local function paintChip(c, i)
    local fill, ink = P.TypeColor(i)
    local col = K.colors()
    c.bg.rgb = fill
    K.paintTex(c.bg, col)
    for _, e in ipairs(c.edges or {}) do e.rgb = fill K.paintTex(e, col) end
    c.label.rgb = ink
    K.paintText(c.label, col)
    if c.label.SetShadowColor then
        if ink == INK_WHITE then c.label:SetShadowColor(0, 0, 0, 0.8) else c.label:SetShadowColor(0, 0, 0, 0) end
    end
end
local function chip(p, parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(40, 13)
    c.bg = K.tex(p, c, "chip", "BACKGROUND")
    c.bg:SetAllPoints(c)
    c.edges = K.edges(p, c, "chipEdge")
    c.label = K.text(p, c, "GameFontHighlightSmall", "ink", nil, "CENTER")
    c.label:SetPoint("CENTER", 0, 0)
    c:EnableMouse(true)
    K.tooltip(c, function(self)
        local r = self.row and self.row.line
        if not (r and self.name) then return nil end
        local all = {}
        for _, t in ipairs(r.types) do all[#all + 1] = self.words and self.words.typeName(t) or "?" end
        return self.name, ("One of %s's types (%s)."):format(r.speciesName or r.name, table.concat(all, " / "))
    end)
    return c
end
local function buildRow(p, col, i)
    local r = CreateFrame("Frame", nil, col)
    r:SetSize(COL, ROW_H)
    r:SetPoint("TOPLEFT", 0, -24 - (i - 1) * (ROW_H + ROW_GAP))
    r.bg = K.tex(p, r, "tile", "BACKGROUND")
    r.bg:SetAllPoints(r)
    r.holder = CreateFrame("Frame", nil, r)
    r.holder:SetSize(ICON, ICON)
    r.holder:SetPoint("TOPLEFT", 2, -2)
    r.dash = K.dashes(p, r.holder)
    r.px = {}
    r.nick = K.text(p, r, "GameFontHighlight", "ink")
    r.nick:SetPoint("TOPLEFT", TEXT_X, -4)
    r.species = K.text(p, r, "GameFontHighlightSmall", "soft")
    r.species:SetPoint("BOTTOMLEFT", r.nick, "BOTTOMRIGHT", 5, 1)
    r.level = K.text(p, r, "GameFontHighlight", "ink", LV_W, "RIGHT")
    r.level:SetPoint("TOPRIGHT", -6, -4)
    r.item = K.text(p, r, "GameFontHighlightSmall", "soft")
    r.item:SetPoint("TOPLEFT", TEXT_X, -21)
    r.itemHit = CreateFrame("Frame", nil, r)
    r.itemHit:SetPoint("TOPLEFT", TEXT_X, -19)
    r.itemHit:SetSize(60, 14)
    r.itemHit:EnableMouse(true)
    K.tooltip(r.itemHit, function()
        local l = r.line
        if not l or l.egg or l.unknown then return nil end
        if (l.itemId or 0) == 0 then return "No item", ("%s isn't holding anything."):format(l.name) end
        local w = r.words
        local txt = w and w.itemText(l.itemId)
        if txt then txt = txt:gsub("POK\195\169MON", POKEMON):gsub("POK\195\169", "Pok\195\169") end
        return l.item, txt or ("Held by %s. Your game has no name for item number %d."):format(l.name, l.itemId)
    end)
    r.chips = { chip(p, r), chip(p, r) }
    for _, c in ipairs(r.chips) do c.row = r end
    r.chips[2]:SetPoint("TOPRIGHT", r, "TOPRIGHT", -6, -20)
    r:EnableMouse(true)
    K.tooltip(r, function(self)
        local l = self.line
        if not l then return nil end
        if l.egg then return "Egg", "Still an egg." end
        if l.unknown then return POKEMON .. " not readable", "This one couldn't be read from the game's memory." end
        local w = self.words
        local lines = { ("%s, level %d."):format(l.speciesName, l.level or 0) }
        lines[#lines + 1] = (l.itemId or 0) > 0 and ("Holding " .. l.item .. ".") or "No held item."
        local ts = {}
        for _, t in ipairs(l.types) do ts[#ts + 1] = w and w.typeName(t) or "?" end
        if #ts > 0 then lines[#lines + 1] = table.concat(ts, " / ") .. (#ts == 1 and " type." or " types.") end
        return l.name, table.concat(lines, "\n")
    end)
    return r
end
local function buildColumn(p, side)
    local c = CreateFrame("Frame", nil, p)
    c:SetSize(COL, 24)
    c:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + (side - 1) * (COL + GAP), -62)
    c.who = K.text(p, c, "GameFontHighlight", "ink")
    c.who:SetPoint("TOPLEFT", 0, 0)
    c.sub = K.text(p, c, "GameFontHighlightSmall", "soft")
    c.sub:SetPoint("BOTTOMLEFT", c.who, "BOTTOMRIGHT", 8, 1)
    c.rule = K.tex(p, c, "edge")
    c.rule:SetPoint("TOPLEFT", 0, -17) c.rule:SetSize(COL, 1)
    c.rows = {}
    for i = 1, 6 do c.rows[i] = buildRow(p, c, i) end
    c.msg = K.text(p, c, "GameFontHighlight", "ink", COL - 12, "LEFT", true)
    c.msg:SetPoint("TOPLEFT", 6, -32)
    c.msg2 = K.text(p, c, "GameFontHighlightSmall", "soft", COL - 12, "LEFT", true)
    return c
end
local function answer(yes)
    local p = panel
    if not p then return end
    local f = yes and p.onYes or p.onNo
    p.pending, p.onYes, p.onNo = nil, nil, nil
    p:Hide()
    if f then f() end
end
local function build()
    local p = K.panel("MekkaBoyTeamPreview", W)
    panel = p
    p:SetPoint("TOP", UIParent, "TOP", 0, -110)
    p.cols = { buildColumn(p, 1), buildColumn(p, 2) }
    p.note = K.text(p, p, "GameFontHighlightSmall", "soft", W - PAD * 2, "LEFT", true)
    p.timer = K.text(p, p, "GameFontHighlightSmall", "soft", 200)
    p.yes = K.button(p, p, "Battle", 100, true, function() answer(true) end)
    p.no = K.button(p, p, "Not now", 100, false, function() answer(false) end)
    p.yes.tip = function() local v = view return v and (v.kind == "battle" and "Battle" or "Trade"), v and ("Your game saves, then the " .. (v.kind == "battle" and "battle starts" or "trade screen opens") .. " right here.") end
    p.no.tip = function()
        local v = view
        if not v then return nil end
        if v.role == "asking" and v.done then return "Close", nil end
        if v.role == "asking" then return "Cancel", "Call the " .. v.kind .. " off (the same as /mb " .. v.kind .. " off)." end
        return "Not now", "Say no for now. " .. MB.Link.Short(v.partner or "") .. " is told."
    end
    p.close.tip = function()
        local v = view
        if v and v.role == "asking" and not v.done then return "Cancel", "Calls the " .. v.kind .. " off. Esc does too." end
        if v and v.role == "asked" then return "Not now", "Closing says no for now. Esc does too." end
        return "Close", "Esc closes it too."
    end
    -- x and Esc: the quiet answer (Not now, or Cancel), never a request left hanging
    p:SetScript("OnHide", function(self)
        if self.pending then
            local f = self.onNo
            self.pending, self.onYes, self.onNo = nil, nil, nil
            if f then f() end
        end
        view = nil
    end)
    -- (Esc reaches it before the console, which would otherwise take it for pause: the panel is on top and listens
    -- for that one key only, letting every other through to the game)
    p:EnableKeyboard(true)
    p:SetScript("OnKeyDown", function(self, k)
        if InCombatLockdown and InCombatLockdown() then return end
        if k == "ESCAPE" then
            if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
            self:Hide()
        elseif self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    local acc = 0
    p:SetScript("OnUpdate", function(self, e)
        acc = acc + (e or 0)
        if acc < 0.25 then return end
        acc = 0
        local v = view
        if not v then return end
        if v.role == "asking" and not v.slow and (v.theirsState or "waiting") == "waiting" and GetTime() - (v.shownAt or 0) > 12 then
            v.slow = true
            guard(layout)
        end
        if v.until_ and GetTime() >= v.until_ then
            if v.role == "asked" then answer(false) else P.Hide() end
            return
        end
        if v.until_ and v.role == "asked" then
            local left = math.ceil(v.until_ - GetTime())
            if left ~= v.left then v.left = left p.timer:SetText(("Closes in %d s if not answered"):format(left)) end
        end
    end)
end

-- ---------------------------------------------------------------- layout ---
local function drawRow(r, w, e)
    r:Show()
    r.words = w
    r.bg.faint = not e
    for _, c in ipairs(r.chips) do c:Hide() c.words = w end
    if not e then
        r.line = nil
        r.holder:Hide() K.drawIcon(r, nil)
        r.nick:SetText("") r.species:SetText("") r.level:SetText("") r.item:SetText("")
        r.itemHit:Hide()
        r:EnableMouse(false)
        return
    end
    r:EnableMouse(true)
    local l = line(w, e)
    r.line = l
    r.holder:Show()
    K.drawIcon(r, (not l.unknown) and Icons and Icons.Get(l.egg and 0 or e.species) or nil)
    r.level:SetText((not l.egg and l.level) and ("Lv " .. l.level) or "")
    -- the second line first: the type chips from the right, then the item in what is left
    local right = COL - 6
    for k = #l.types, 1, -1 do
        local c = r.chips[k]
        local name = w and w.typeName(l.types[k]) or "?"
        local tag = (w and w.typeTag and w.typeTag(l.types[k])) or name:upper()
        c.name = name                                   -- (the tooltip keeps the full word)
        c.label:SetText(tag)
        paintChip(c, l.types[k])
        local cw = math.max(math.ceil(widthOf("GameFontHighlightSmall", tag)) + 10, 44)
        c.label:SetWidth(cw - 2)
        c:SetSize(cw, 13)
        c:ClearAllPoints()
        c:SetPoint("TOPRIGHT", r, "TOPLEFT", right, -20)
        right = right - cw - 4
        c:Show()
    end
    if l.egg or l.unknown then
        place(r.item, "GameFontHighlightSmall", l.egg and "Still an egg" or "", right - 4 - TEXT_X)
        r.itemHit:Hide()
    else
        local _, iw = place(r.item, "GameFontHighlightSmall", l.item, right - 4 - TEXT_X)
        r.itemHit:SetSize(max(20, iw), 14)
        r.itemHit:Show()
    end
    -- the first line: the name, and the species small beside it when the nickname is not the species' own
    local room = COL - TEXT_X - 6 - LV_W - 6
    -- (the species gives way first: it is cut, then left out, before the name is)
    local _, nw = place(r.nick, "GameFontHighlight", l.name, room)
    nw = math.ceil(nw)
    local left = room - nw - 5
    if l.species and left >= widthOf("GameFontHighlightSmall", l.species:sub(1, 3) .. ELL) then
        place(r.species, "GameFontHighlightSmall", l.species, left)
    else
        r.species:SetText("")
    end
end
local function sideText(team, game)
    local bits = {}
    if team and team.trainer and team.trainer ~= "" then bits[#bits + 1] = team.trainer end
    if game then bits[#bits + 1] = game end
    return table.concat(bits, MID)
end
layout = function()
    local p, v = panel, view
    if not (p and v and p:IsShown()) then return end
    local w = words()
    local who = MB.Link.Short(v.partner or "")
    local verb = v.kind == "battle" and "battle" or "trade"
    local title
    if v.role == "asked" then title = ("%s wants to %s right where you stand"):format(who, verb)
    elseif v.done then title = ("The %s with %s didn't start"):format(verb, who)
    else title = ("Asking %s to %s right where you stand"):format(who, verb) end
    p.title:SetText(cut("GameFontHighlight", title, W - 72))
    local sub
    if v.role == "asked" then sub = v.game and (POKEMON .. " " .. v.game) or nil
    else sub = v.status end
    p.sub:SetText(cut("GameFontHighlightSmall", sub or "", W - 48))
    -- the two columns: you, them
    local sides = {
        { who = "You", team = v.mine, state = v.mine and "ok" or "unreadable", game = v.mineGame },
        { who = who, team = v.theirs, state = v.theirsState or (v.theirs and "ok" or "waiting"), game = v.game },
    }
    local rows = 1
    for _, s in ipairs(sides) do
        if s.state == "ok" and s.team and #s.team.mons == 0 then s.state = "unreadable" end
        if s.state == "ok" then rows = max(rows, #s.team.mons) end
    end
    local colH = 24
    for i, s in ipairs(sides) do
        local c = p.cols[i]
        local _, ww = place(c.who, "GameFontHighlight", s.who, 150)
        place(c.sub, "GameFontHighlightSmall", sideText(s.state == "ok" and s.team or nil, s.game), COL - ww - 8)
        local msgA, msgB
        if s.state == "ok" then
            for k = 1, 6 do
                if k <= rows then drawRow(c.rows[k], w, s.team.mons[k]) else c.rows[k]:Hide() end
            end
        else
            for k = 1, 6 do c.rows[k]:Hide() end
            if s.state == "waiting" then
                msgA = ("Waiting for %s's team%s"):format(who, ELL)
                msgB = v.slow and ("Nothing from %s's MekkaBoy yet. If it doesn't answer, the request ends by itself and you're told."):format(who)
                    or "Their MekkaBoy sends it as soon as it hears the request."
            elseif s.state == "none" then
                msgA, msgB = ("%s's MekkaBoy didn't send a team."):format(who), ("It may be older than yours: %s answers on the plain pop-up, and the %s works the same."):format(who, verb)
            elseif i == 1 then
                msgA, msgB = "Your team couldn't be read from your game.", "The " .. verb .. " works the same."
            else
                msgA, msgB = ("%s's team couldn't be read from their game."):format(who), "The " .. verb .. " works the same."
            end
        end
        c.msg:SetShown(msgA ~= nil) c.msg2:SetShown(msgB ~= nil)
        c.msg:SetText(msgA or "") c.msg2:SetText(msgB or "")
        if msgA then
            c.msg2:ClearAllPoints()
            c.msg2:SetPoint("TOPLEFT", c.msg, "BOTTOMLEFT", 0, -4)
        end
    end
    local listH = 24 + rows * (ROW_H + ROW_GAP) - ROW_GAP
    for _, c in ipairs(p.cols) do
        if c.msg:IsShown() then
            local h = 32 + (c.msg:GetStringHeight() or 14) + 4 + (c.msg2:GetStringHeight() or 12) + 4
            listH = max(listH, h)
        end
    end
    local y = -62 - listH - 12
    -- the safety line
    if v.kind == "battle" then
        p.note:SetText("Your " .. POKEMON .. " are healed for the battle and come back exactly as they were. Your game saves before the battle and again after it.")
    else
        p.note:SetText("Your game is saved first, then the trade screen opens.")
    end
    p.note:ClearAllPoints()
    p.note:SetPoint("TOPLEFT", PAD, y)
    p.note:SetShown(not v.done)                            -- (called off: what would have happened no longer matters)
    if not v.done then y = y - (p.note:GetStringHeight() or 24) - 12 end
    -- the buttons, from the right
    p.yes:ClearAllPoints() p.no:ClearAllPoints()
    if v.role == "asked" then
        p.yes:Set(v.kind == "battle" and "Battle" or "Trade")
        p.no:Set("Not now")
        p.yes:Show() p.no:Show()
        p.yes:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y)
        p.no:SetPoint("TOPRIGHT", p.yes, "TOPLEFT", -8, 0)
    else
        p.yes:Hide()
        p.no:Set(v.done and "Close" or "Cancel")
        p.no:Show()
        p.no:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y)
    end
    p.timer:ClearAllPoints()
    p.timer:SetPoint("TOPLEFT", PAD, y - 6)
    p.timer:SetShown(v.role == "asked" and v.until_ ~= nil)
    if v.role == "asked" and v.until_ then
        v.left = math.ceil(v.until_ - GetTime())
        p.timer:SetText(("Closes in %d s if not answered"):format(v.left))
    else p.timer:SetText("") end
    y = y - 24
    p:SetHeight(-y + PAD)
    p.h = -y + PAD
    p:Paint()
end

guard = function(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then MB.DB().lastError = { at = date and date("%Y-%m-%d %H:%M:%S") or "?", error = "preview: " .. tostring(err):sub(1, 400) } end
    return ok
end

-- ------------------------------------------------------------------- API ---
function P.Show(o)
    if not panel then build() end
    -- (one panel at a time: the card and the Pokedex make room)
    for _, f in ipairs({ Card.CardPanel and Card.CardPanel(), Card.DexPanel and Card.DexPanel() }) do if f and f:IsShown() then f:Hide() end end
    if panel:IsShown() then panel.pending = nil panel:Hide() end
    view = {}
    for k, val in pairs(o) do view[k] = val end
    view.mineGame = view.mineGame or (view.mine and NAMES[view.mine.code or ""]) or nil
    view.until_ = (o.seconds and o.seconds > 0) and (GetTime() + o.seconds) or nil
    view.shownAt = GetTime()
    panel.onYes, panel.onNo, panel.pending = o.onYes, o.onNo, true
    panel:Show()
    guard(layout)
    if o.role == "asked" and PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then pcall(PlaySound, SOUNDKIT.READY_CHECK) end
    return panel
end
function P.Update(o)
    if not (view and panel and panel:IsShown()) then return end
    for k, val in pairs(o) do view[k] = val end
    if o.onNo then panel.onNo = o.onNo end
    guard(layout)
end
-- asking: it was called off (why), and Close; it goes by itself after a while
function P.Finish(why)
    if not (view and panel and panel:IsShown() and view.role == "asking") then return end
    view.done, view.status = true, why
    view.until_ = GetTime() + 12
    panel.pending, panel.onYes, panel.onNo = nil, nil, nil
    guard(layout)
end
function P.Hide()
    if not panel then return end
    panel.pending, panel.onYes, panel.onNo = nil, nil, nil
    if panel:IsShown() then panel:Hide() end
end
function P.Shown() return panel ~= nil and panel:IsShown() and view ~= nil end
function P.View() return view end
function P.Panel() return panel end
function P.Refresh() if panel and panel:IsShown() then guard(layout) end end
local paintBefore = MB.PaintFriends
MB.PaintFriends = function(...)
    if paintBefore then paintBefore(...) end
    P.Refresh()
end
