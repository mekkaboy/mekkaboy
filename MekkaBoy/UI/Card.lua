-- The team card and the Pokedex windows (the talking is Card.lua; the data is Dex.lua). Both are small glass panels in
-- the player's colorway, like the Minimal look (UI/Body.lua's GLASS colors: flat textures, 1 px edges, ink / soft /
-- accent). One shows at a time, in the same place: "Their Pokedex" on a card opens the Pokedex where the card was,
-- and "Team card" on the Pokedex goes back. x and Esc close them.
--
-- Card: the trainer and the game (playing now, or when it was last played), the party (3 x 2: picture, species, level;
-- eggs say Egg), badges / caught (the whole National Pokedex) / link battles (not for Gen 1, which keeps no record),
-- who it is shared with, and buttons: their Pokedex, and Link (what clicking their MekkaBoy mark did before: the same
-- call, the same states as the friends list). States: asking, no Pokemon save yet, private, didn't answer, Solo.
-- Pokedex: caught and living out of 386 with bars, Kanto / Johto / Hoenn, one row per save, the Gen 1 and 2 note,
-- saves still waiting to be opened; someone else's says when it is from, and their last one is shown when they are
-- offline. Pictures: the Gen 3 games' own menu icons from your own cartridge (DexIcons.lua), else a dashed square.
local _, MB = ...
local Card, F, Dex = MB.Card, MB.Friends, MB.Dex
if not (Card and F and Dex) then return end
local Icons = MB.DexIcons
local floor, max, min = math.floor, math.max, math.min

local MID, ELL, DASH, X = " \194\183 ", "\226\128\166", "\226\128\147", "\195\151"
local POKEDEX, POKEMON = "Pok\195\169dex", "Pok\195\169mon"
local ALPHA = 0.96
local DEFAULT = { bg = { 0.10, 0.11, 0.13 }, ink = { 0.91, 0.93, 0.94 }, soft = { 0.66, 0.71, 0.73 }, accent = { 0.56, 0.76, 0.82 }, edge = { 1, 1, 1, 0.16 } }
local function colors() return (MB.GlassColors and MB.GlassColors()) or DEFAULT end
Card.ALPHA = ALPHA

local GAME_DOT = { red = { 0.86, 0.25, 0.22 }, blue = { 0.27, 0.45, 0.85 }, yellow = { 0.95, 0.80, 0.25 }, gold = { 0.82, 0.66, 0.25 },
                   silver = { 0.66, 0.69, 0.74 }, crystal = { 0.45, 0.78, 0.88 }, ruby = { 0.80, 0.15, 0.30 }, sapphire = { 0.20, 0.35, 0.80 },
                   emerald = { 0.20, 0.70, 0.40 }, firered = { 0.92, 0.40, 0.18 }, leafgreen = { 0.45, 0.75, 0.25 } }

-- ----------------------------------------------------------------- words ---
local function gameName(g)
    local n = g and g.name
    if not n then return (g and g.gen) and ("a Gen %d %s game"):format(g.gen, POKEMON) or (POKEMON .. " game") end
    return (n:gsub("^Pokemon", POKEMON))
end
local function titleCase(s) return (s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)) end
local function species(n)
    local name = n and n > 0 and (Dex.Name(n) or (Icons and Icons.Name and Icons.Name(n)))
    if name then return titleCase(name), true end
    return ("No. %d"):format(n or 0), false
end
local function plural(n, one, many) return ("%d %s"):format(n, n == 1 and one or many) end
local function ago(sec)
    sec = max(0, sec or 0)
    if sec < 90 then return "just now" end
    if sec < 3600 then return plural(floor(sec / 60 + 0.5), "minute", "minutes") .. " ago" end
    if sec < 86400 then local h = floor(sec / 3600 + 0.5) return h == 1 and "an hour ago" or (h .. " hours ago") end
    if sec < 2 * 86400 then return "yesterday" end
    if sec < 14 * 86400 then return floor(sec / 86400) .. " days ago" end
    if sec < 60 * 86400 then return floor(sec / (7 * 86400)) .. " weeks ago" end
    if sec < 365 * 86400 then return floor(sec / (30 * 86400)) .. " months ago" end
    return "over a year ago"
end
Card.Ago = ago
local function wall() return (time and time()) or 0 end
local function when(at)
    if not at then return "earlier" end
    local d = wall() - at
    if d < 90 then return "just now" end
    if d < 20 * 3600 and date and date("%Y%m%d", at) == date("%Y%m%d") then return date("%H:%M", at) end     -- (today)
    return ago(d)
end
local function short(name) return MB.Link.Short(name or "") end

-- -------------------------------------------------------- building blocks ---
local function paintTex(t, c)
    local r = t.role
    if r == "bg" then t:SetColorTexture(c.bg[1], c.bg[2], c.bg[3], ALPHA)
    elseif r == "edge" then t:SetColorTexture(c.edge[1], c.edge[2], c.edge[3], max(c.edge[4] or 0.2, 0.22))
    elseif r == "accent" then t:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 1)
    elseif r == "face" then t:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], t.hot and 0.16 or 0.08)
    elseif r == "pface" then t:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], t.hot and 0.32 or 0.20)
    elseif r == "tile" then t:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], t.faint and 0.025 or 0.05)
    elseif r == "track" then t:SetColorTexture(c.ink[1], c.ink[2], c.ink[3], 0.12)
    elseif r == "fill2" then t:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 0.6)
    elseif r == "dash" then t:SetColorTexture(c.soft[1], c.soft[2], c.soft[3], 0.6)
    elseif r == "game" then local g = t.rgb or c.soft t:SetColorTexture(g[1], g[2], g[3], 1) end
end
local function paintText(fs, c)
    local k = fs.role == "soft" and c.soft or (fs.role == "accent" and c.accent) or c.ink
    fs:SetTextColor(k[1], k[2], k[3])
end
local function tex(p, parent, role, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t.role = role
    p.texs[#p.texs + 1] = t
    return t
end
local function text(p, parent, font, role, w, justify, wrap)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    if w then fs:SetWidth(w) end
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(wrap and true or false) end
    fs.role = role
    p.texts[#p.texts + 1] = fs
    return fs
end
local function edges(p, frame, role)
    local list = {}
    for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = tex(p, frame, role or "edge", "BORDER")
        t:SetPoint(e[1], 0, 0) t:SetPoint(e[2], 0, 0)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        list[i] = t
    end
    return list
end
local function tooltip(frame, fn)
    frame:SetScript("OnEnter", function(self)
        if self.hover then self.hover.hot = true paintTex(self.hover, colors()) end
        if not GameTooltip then return end
        local title, body = fn(self)
        if not title then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0.3)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self)
        if self.hover then self.hover.hot = nil paintTex(self.hover, colors()) end
        if GameTooltip then GameTooltip:Hide() end
    end)
end
-- a glass button; primary ones are tinted with the accent and edged with it (the label stays ink: readable in Ivory too)
local function button(p, parent, label, w, primary, onClick, font)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 24)
    b.w = w
    b.face = tex(p, b, primary and "pface" or "face", "BACKGROUND")
    b.face:SetAllPoints(b)
    b.hover = b.face
    if primary then edges(p, b, "accent") end
    b.label = text(p, b, font or "GameFontHighlightSmall", "ink", w - 8, "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText(label)
    b.enabled = true
    b:SetScript("OnClick", function(self, ...) if self.enabled then onClick(self, ...) end end)
    function b:Set(str, enabled)
        self.label:SetText(str)
        self.enabled = enabled ~= false
        self:SetAlpha(self.enabled and 1 or 0.45)
    end
    tooltip(b, function(self) if self.tip then return self.tip() end end)
    return b
end
local function panel(name, w)
    local p = CreateFrame("Frame", name, UIParent)
    p.texs, p.texts, p.w = {}, {}, w
    p:SetSize(w, 120)
    p:SetFrameStrata("DIALOG")
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetMovable(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    local bg = tex(p, p, "bg", "BACKGROUND")
    bg:SetAllPoints(p)
    edges(p, p)
    p.dot = tex(p, p, "accent")
    p.dot:SetSize(8, 8)
    p.dot:SetPoint("TOPLEFT", 16, -19)
    p.title = text(p, p, "GameFontHighlight", "ink", w - 32 - 40)
    p.title:SetPoint("TOPLEFT", 32, -14)
    p.sub = text(p, p, "GameFontHighlightSmall", "soft", w - 32 - 16)
    p.sub:SetPoint("TOPLEFT", 32, -32)
    local rule = tex(p, p, "edge")
    rule:SetPoint("TOPLEFT", 16, -50) rule:SetPoint("TOPRIGHT", -16, -50) rule:SetHeight(1)
    p.close = button(p, p, X, 22, false, function() p:Hide() end, "GameFontHighlight")
    p.close:SetPoint("TOPRIGHT", -8, -8)
    p.close.tip = function() return "Close", "Esc closes it too." end
    if UISpecialFrames then table.insert(UISpecialFrames, name) end
    function p:Paint()
        local c = colors()
        for _, t in ipairs(self.texs) do paintTex(t, c) end
        for _, fs in ipairs(self.texts) do paintText(fs, c) end
    end
    p:SetScript("OnShow", function(self) self:Paint() end)
    p:Hide()
    return p
end
-- a message block (the states without a party or a Pokedex)
local function messages(p, w)
    p.msg = text(p, p, "GameFontHighlight", "ink", w, "LEFT", true)
    p.msg2 = text(p, p, "GameFontHighlightSmall", "soft", w, "LEFT", true)
end
local function height(fs, line, lines)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    if type(h) == "number" and h > 0 then return h end
    return line * (lines or 1)
end
local function placeMessages(p, y, a, b)
    p.msg:ClearAllPoints() p.msg2:ClearAllPoints()
    p.msg:SetText(a or "") p.msg2:SetText(b or "")
    p.msg:SetShown(a ~= nil) p.msg2:SetShown(b ~= nil)
    if a then p.msg:SetPoint("TOPLEFT", 16, y) y = y - height(p.msg, 14, 2) - 6 end
    if b then p.msg2:SetPoint("TOPLEFT", 16, y) y = y - height(p.msg2, 12, 2) - 4 end
    return y
end

-- ================================================================== the card ===
local W, PAD = 340, 16
local INNER = W - PAD * 2
local CELL_W, CELL_H, CELL_GAP = 98, 68, 7
local ICON = 32
local card, cardView, dexPanel, dexView
local textures = { made = 0 }                -- (how many picture textures exist, for the report and the tests)

-- a dashed square where there is no picture
local function dashes(p, holder)
    local list = {}
    for _, side in ipairs({ "top", "bottom", "left", "right" }) do
        for i = 0, 4 do
            local t = tex(p, holder, "dash")
            local at = i * 7
            if side == "top" then t:SetPoint("TOPLEFT", at, 0) t:SetSize(4, 1)
            elseif side == "bottom" then t:SetPoint("TOPLEFT", at, -(ICON - 1)) t:SetSize(4, 1)
            elseif side == "left" then t:SetPoint("TOPLEFT", 0, -at) t:SetSize(1, 4)
            else t:SetPoint("TOPLEFT", ICON - 1, -at) t:SetSize(1, 4) end
            list[#list + 1] = t
        end
    end
    return list
end
local function setShown(list, on) for _, t in ipairs(list) do t:SetShown(on) end end
local function drawIcon(cell, icon)
    if cell.icon == icon and cell.drawn then return end          -- (the same picture: nothing to do)
    cell.icon = icon
    local px = cell.px
    local n = icon and #icon.rects or 0
    for i = 1, n do
        local r = icon.rects[i]
        local t = px[i]
        if not t then
            t = cell.holder:CreateTexture(nil, "ARTWORK")
            px[i] = t
            textures.made = textures.made + 1
        end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", cell.holder, "TOPLEFT", r[1], -r[2])
        t:SetSize(r[3], r[4])
        t:SetColorTexture(r[5], r[6], r[7], 1)
        t:Show()
    end
    for i = n + 1, #px do px[i]:Hide() end
    setShown(cell.dash, n == 0)
    cell.drawn = n
end

local function buildCard()
    card = panel("MekkaBoyTeamCard", W)
    card:SetPoint("TOP", UIParent, "TOP", 0, -120)
    card.cells = {}
    for i = 1, 6 do
        local col, row = (i - 1) % 3, floor((i - 1) / 3)
        local cell = CreateFrame("Frame", nil, card)
        cell:SetSize(CELL_W, CELL_H)
        cell.x, cell.y = PAD + col * (CELL_W + CELL_GAP), row * (CELL_H + CELL_GAP)
        cell.bg = tex(card, cell, "tile", "BACKGROUND")
        cell.bg:SetAllPoints(cell)
        cell.holder = CreateFrame("Frame", nil, cell)
        cell.holder:SetSize(ICON, ICON)
        cell.holder:SetPoint("TOP", 0, -6)
        cell.dash = dashes(card, cell.holder)
        cell.px = {}
        cell.name = text(card, cell, "GameFontHighlightSmall", "ink", CELL_W - 8, "CENTER")
        cell.name:SetPoint("TOP", 0, -42)
        cell.level = text(card, cell, "GameFontHighlightSmall", "soft", CELL_W - 8, "CENTER")
        cell.level:SetPoint("TOP", 0, -55)
        cell:EnableMouse(true)
        tooltip(cell, function(self)
            local m = self.mon
            if not m then return nil end
            if m.egg then return "Egg", "Still an egg in " .. (cardView and cardView.mine and "your" or "their") .. " game." end
            if (m.species or 0) == 0 then
                return "Not known yet", ("Level %d. Which %s it is shows once %s has been opened on MekkaBoy since this update."):format(m.level or 0, POKEMON,
                    cardView and cardView.mine and "this game" or "their game")
            end
            local name, known = species(m.species)
            local lines = {}
            if m.nick and m.nick ~= "" and m.nick:upper() ~= name:upper() then lines[#lines + 1] = "Nickname: " .. m.nick end
            lines[#lines + 1] = ("National %s #%03d, level %d."):format(POKEDEX, m.species or 0, m.level or 0)
            if not known then lines[#lines + 1] = "Names come from your own " .. POKEMON .. " games: open one on MekkaBoy once and they show here." end
            if (self.drawn or 0) == 0 then lines[#lines + 1] = "Pictures come from your own Ruby, Sapphire, Emerald, FireRed or LeafGreen, once you have opened it this session." end
            return name, table.concat(lines, "\n")
        end)
        card.cells[i] = cell
    end
    card.stats = {}
    for i = 1, 3 do
        local s = CreateFrame("Frame", nil, card)
        s.bg = tex(card, s, "tile", "BACKGROUND")
        s.bg:SetAllPoints(s)
        s.value = text(card, s, "GameFontHighlightLarge", "ink", 90, "CENTER")
        s.value:SetPoint("TOP", 0, -7)
        s.label = text(card, s, "GameFontHighlightSmall", "soft", 90, "CENTER")
        s.label:SetPoint("TOP", 0, -29)
        s:EnableMouse(true)
        tooltip(s, function(self) if self.tip then return self.tip() end end)
        card.stats[i] = s
    end
    messages(card, INNER)
    card.share = text(card, card, "GameFontHighlightSmall", "soft", INNER)
    card.dexButton = button(card, card, "Their " .. POKEDEX, 116, false, function()
        local v = cardView
        if v then Card.ShowDex(not v.mine and v.name or nil, card) end
    end)
    card.dexButton.tip = function() return "Their " .. POKEDEX, "Every " .. POKEMON .. " caught across their saves on MekkaBoy." end
    card.linkButton = button(card, card, "Link", 84, true, function(self)
        local v = cardView
        if not v or v.mine then return end
        local st = F.Status(v.name)
        if st == "calling" then F.Cancel()
        elseif st == "invited" then F.Accept()
        else F.Call(v.name) end                      -- (what clicking their mark always did)
        Card.Refresh()
    end)
    card.linkButton.tip = function()
        local v = cardView
        local p = v and F.Peer(v.name)
        local _, why = F.Fits(p)
        return "Link", "Ask " .. short(v and v.name) .. " to link MekkaBoys (trade and battle in your games)." .. (why and ("\nTheir game: " .. why .. ".") or "")
    end
    card.again = button(card, card, "Try again", 96, false, function()
        local v = cardView
        if v and not v.mine then Card.Ask(v.name, "card") Card.Refresh() end
    end)
    local acc = 0
    card:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc >= 1 then acc = 0 Card.Refresh() end         -- (playing now / last played, a call's state)
    end)
end

-- what the card shows: { mine, name, who, status, data }
local function cardData()
    local v = cardView
    if not v then return nil end
    if v.mine then return "ok", Card.Mine() end
    local e = Card.State(v.name, "card")
    if not e then return "asking", nil end
    return e.status, e.data, e
end

local function layoutCard()
    if not (card and card:IsShown() and cardView) then return end
    local v = cardView
    local status, data = cardData()
    local who = v.mine and ((UnitName and UnitName("player")) or "You") or short(v.name)
    local c = data and data.card
    local peer = not v.mine and F.Peer(v.name) or nil
    local y = -62
    for _, cell in ipairs(card.cells) do cell:Hide() end
    for _, s in ipairs(card.stats) do s:Hide() end
    card.share:Hide()
    local msgA, msgB
    if status == "ok" and c then
        card.title:SetText(c.trainer ~= "" and c.trainer or who)
        card.sub:SetText(gameName(c) .. MID .. (data.live and "playing now" or ("last played " .. ago(data.played and (wall() - data.played) or nil))))
        for i, cell in ipairs(card.cells) do
            local m = c.party[i]
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", card, "TOPLEFT", cell.x, y - cell.y)
            cell:Show()
            cell.mon = m
            cell.bg.faint = not m
            if m then
                cell.holder:Show()
                local unknown = not m.egg and (m.species or 0) == 0     -- (a Gen 1 or 3 save read before its game was opened)
                drawIcon(cell, not unknown and Icons and Icons.Get(m.egg and 0 or m.species) or nil)
                cell.name:SetText(m.egg and "Egg" or (unknown and "Not known yet") or (species(m.species)))
                cell.level:SetText(m.egg and "" or ("Lv " .. (m.level or 0)))
            else
                cell.holder:Hide()
                drawIcon(cell, nil)
                cell.name:SetText("") cell.level:SetText("")
            end
        end
        y = y - (CELL_H * 2 + CELL_GAP) - 10
        local stats = {
            { value = ("%d / %d"):format(c.badges or 0, c.badgeTotal or 8), label = "Badges",
              tip = function() return "Badges", ("Gym badges in %s%s."):format(gameName(c), (c.badgeTotal == 16) and " (Johto and Kanto)" or "") end },
            { value = tostring(c.caught or 0), label = "Caught",
              tip = function() return "Caught", ("%s marked caught in the %s of any of %s saves on MekkaBoy: the National %s, out of 386."):format(
                  POKEMON, POKEDEX, v.mine and "your" or (who .. "'s"), POKEDEX) end },
        }
        if c.gen ~= 1 and c.record then
            local r = c.record
            stats[3] = { value = ("%d%s%d"):format(r.wins or 0, DASH, r.losses or 0), label = "Link battles",
                         tip = function() return "Link battles", ("Wins %s losses in %s, from the game's own record%s."):format(DASH, gameName(c),
                             (r.draws or 0) > 0 and (", and " .. plural(r.draws, "draw", "draws")) or "") end }
        end
        local n = #stats
        local sw = floor((INNER - (n - 1) * 8) / n)
        for i, st in ipairs(stats) do
            local s = card.stats[i]
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + (i - 1) * (sw + 8), y)
            s:SetSize(sw, 46)
            s.value:SetWidth(sw - 8) s.label:SetWidth(sw - 8)
            s.value:SetText(st.value) s.label:SetText(st.label)
            s.tip = st.tip
            s.w = sw
            s:Show()
        end
        y = y - 46 - 12
    else
        card.title:SetText(who)
        if status == "asking" then
            card.sub:SetText("Asking" .. ELL)
            msgA = ("Asking %s for their team card%s"):format(who, ELL)
        elseif status == "private" then
            card.sub:SetText("Team card")
            msgA, msgB = who .. " keeps their team private.", "Only people they know in WoW can see it."
        elseif status == "timeout" then
            card.sub:SetText("Team card")
            msgA, msgB = who .. " didn't answer.", "They may be offline, or on an older MekkaBoy."
        elseif status == "solo" then
            card.sub:SetText("Team card")
            msgA, msgB = "You are playing Solo, so nobody is asked.", "/mb play friends or /mb play open changes that."
        else                                                  -- answered: no Pokemon save yet
            local playing = data and data.playing
            card.sub:SetText(playing and (playing .. MID .. (data.live and "playing now" or "in the console")) or "Team card")
            if v.mine then
                msgA = "You aren't on a " .. POKEMON .. " game yet."
                msgB = "Play Red, Gold, Ruby or another " .. POKEMON .. " game on MekkaBoy and your team shows here."
            else
                msgA = who .. " isn't on a " .. POKEMON .. " game yet."
                msgB = "Their team shows here once they play a " .. POKEMON .. " game on MekkaBoy."
            end
        end
        y = placeMessages(card, y, msgA, msgB) - 6
    end
    if not (status == "ok" and c) then card.msg:SetShown(msgA ~= nil) else card.msg:Hide() card.msg2:Hide() end
    -- who sees it
    if status == "ok" then
        local mode = data.share
        local line
        if v.mine then
            line = (mode == "solo") and "Solo: you don't share this with anyone." or ("You share this with " .. (mode == "friends" and "friends" or "everyone") .. ".")
        else
            line = who .. " shares this with " .. (mode == "friends" and "friends" or "everyone") .. "."
        end
        card.share:ClearAllPoints()
        card.share:SetPoint("TOPLEFT", PAD, y)
        card.share:SetText(line)
        card.share:Show()
        y = y - 12 - 10
    end
    -- buttons, from the right
    local right = -PAD
    local function place(b, show)
        b:SetShown(show)
        if not show then return end
        b:ClearAllPoints()
        b:SetPoint("TOPRIGHT", card, "TOPRIGHT", right, y)
        right = right - b.w - 8
    end
    local linked = MB.Link.Session and MB.Link.Session()
    linked = linked and linked.state == "linked"
    local showLink = not v.mine and peer ~= nil and not linked
    if showLink then
        local st = F.Status(v.name)
        local ok = F.Fits(peer)
        if st == "calling" then card.linkButton:Set("Cancel")
        elseif st == "answering" then card.linkButton:Set("Linking" .. ELL, false)
        elseif st == "invited" then card.linkButton:Set("Answer")
        elseif ok == false then card.linkButton:Set("Can't link", false)
        else card.linkButton:Set("Link") end
    end
    place(card.linkButton, showLink)
    local seen = not v.mine and Card.Seen(v.name)
    local showDex = (status == "ok" and c ~= nil) or (seen ~= nil and status ~= "asking")
    card.dexButton.label:SetText(v.mine and ("My " .. POKEDEX) or ("Their " .. POKEDEX))
    place(card.dexButton, showDex)
    place(card.again, not v.mine and status == "timeout")
    if card.linkButton:IsShown() or card.dexButton:IsShown() or card.again:IsShown() then y = y - 24 end
    card.h = -y + PAD - 4
    card:SetHeight(card.h)
    card:Paint()
end

-- ============================================================== the Pokedex ===
local DW = 440
local DINNER = DW - PAD * 2
local ROWS = 12
local function bar(p, parent, y)
    local track = tex(p, parent, "track")
    track:SetPoint("TOPLEFT", PAD, y)
    track:SetSize(DINNER, 8)
    local fill = tex(p, parent, "accent")
    fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    fill:SetSize(1, 8)
    return { track = track, fill = fill }
end
local function setBar(b, n, total, w)
    b.fill:SetWidth(max(1, (w or DINNER) * min(1, (n or 0) / total)))
    b.fill:SetShown((n or 0) > 0)
    b.frac = (n or 0) / total
end
local function buildDex()
    local p = panel("MekkaBoyPokedex", DW)
    dexPanel = p
    p:SetPoint("TOP", UIParent, "TOP", 0, -120)
    p.body = CreateFrame("Frame", nil, p)
    p.body:SetPoint("TOPLEFT", 0, -56)
    p.body:SetSize(DW, 10)
    local b = p.body
    local y = -6
    p.natLabel = text(p, b, "GameFontHighlight", "ink", 260)
    p.natLabel:SetPoint("TOPLEFT", PAD, y)
    p.natLabel:SetText("National " .. POKEDEX)
    p.natCount = text(p, b, "GameFontHighlight", "ink", 120, "RIGHT")
    p.natCount:SetPoint("TOPRIGHT", -PAD, y)
    p.natHit = CreateFrame("Frame", nil, b)
    p.natHit:SetPoint("TOPLEFT", PAD, y + 2) p.natHit:SetSize(DINNER, 32)
    p.natHit:EnableMouse(true)
    tooltip(p.natHit, function() return "National " .. POKEDEX, "Every " .. POKEMON .. " marked caught in the " .. POKEDEX .. " of any save on MekkaBoy, out of the 386 in Red to Emerald." end)
    y = y - 18
    p.natBar = bar(p, b, y)
    y = y - 8 - 14
    p.livLabel = text(p, b, "GameFontHighlight", "ink", 120)
    p.livLabel:SetPoint("TOPLEFT", PAD, y)
    p.livLabel:SetText("Living " .. POKEDEX)
    p.livNote = text(p, b, "GameFontHighlightSmall", "soft", 210)
    p.livNote:SetPoint("TOPLEFT", PAD + 118, y - 2)
    p.livNote:SetText("(in a party or PC box right now)")
    p.livCount = text(p, b, "GameFontHighlight", "ink", 70, "RIGHT")
    p.livCount:SetPoint("TOPRIGHT", -PAD, y)
    p.livHit = CreateFrame("Frame", nil, b)
    p.livHit:SetPoint("TOPLEFT", PAD, y + 2) p.livHit:SetSize(DINNER, 32)
    p.livHit:EnableMouse(true)
    tooltip(p.livHit, function() return "Living " .. POKEDEX, "Different " .. POKEMON .. " in a party or a PC box of any save right now, out of 386. Trading one away takes it off; catching it again puts it back." end)
    y = y - 18
    p.livBar = bar(p, b, y) p.livBar.fill.role = "fill2"
    y = y - 8 - 16
    p.tiles = {}
    local tw = floor((DINNER - 2 * 9) / 3)
    for i, r in ipairs(Dex.REGIONS) do
        local t = CreateFrame("Frame", nil, b)
        t:SetSize(tw, 54)
        t:SetPoint("TOPLEFT", PAD + (i - 1) * (tw + 9), y)
        t.bg = tex(p, t, "tile", "BACKGROUND") t.bg:SetAllPoints(t)
        t.name = text(p, t, "GameFontHighlight", "ink", 70) t.name:SetPoint("TOPLEFT", 10, -9) t.name:SetText(r.name)
        t.range = text(p, t, "GameFontHighlightSmall", "soft", 70) t.range:SetPoint("TOPLEFT", 10, -27)
        t.range:SetText(("#%d%s%d"):format(r.from, DASH, r.to))
        t.count = text(p, t, "GameFontHighlightLarge", "ink", 50, "RIGHT") t.count:SetPoint("TOPRIGHT", -10, -8)
        t.of = text(p, t, "GameFontHighlightSmall", "soft", 50, "RIGHT") t.of:SetPoint("TOPRIGHT", -10, -28)
        t.of:SetText("of " .. (r.to - r.from + 1))
        t.track = tex(p, t, "track") t.track:SetPoint("BOTTOMLEFT", 10, 7) t.track:SetSize(tw - 20, 3)
        t.fill = tex(p, t, "accent") t.fill:SetPoint("BOTTOMLEFT", 10, 7) t.fill:SetSize(1, 3)
        t.region, t.w = r, tw
        t:EnableMouse(true)
        tooltip(t, function(self)
            local d = self.data
            if not d then return nil end
            return ("%s, #%d%s%d"):format(self.region.name, self.region.from, DASH, self.region.to),
                ("%d caught, %d living, of %d."):format(d.caught or 0, d.living or 0, self.region.to - self.region.from + 1)
        end)
        p.tiles[i] = t
    end
    y = y - 54 - 16
    p.head = {}
    for _, h in ipairs({ { "Game", 30, 160, "LEFT" }, { "Trainer", 196, 90, "LEFT" }, { "Badges", 288, 60, "RIGHT" }, { "Caught", 352, 56, "RIGHT" } }) do
        local fs = text(p, b, "GameFontHighlightSmall", "soft", h[3], h[4])
        fs:SetPoint("TOPLEFT", h[2], y)
        fs:SetText(h[1])
        p.head[#p.head + 1] = fs
    end
    p.rowsY = y - 16
    p.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, b)
        r:SetSize(DINNER, 20)
        r:SetPoint("TOPLEFT", PAD, p.rowsY - (i - 1) * 20)
        r.bg = tex(p, r, "tile", "BACKGROUND") r.bg:SetAllPoints(r) r.bg.faint = i % 2 == 0
        r.dot = tex(p, r, "game") r.dot:SetSize(8, 8) r.dot:SetPoint("LEFT", 2, 0)
        r.game = text(p, r, "GameFontHighlightSmall", "ink", 160) r.game:SetPoint("LEFT", 14, 0)
        r.trainer = text(p, r, "GameFontHighlightSmall", "ink", 88) r.trainer:SetPoint("LEFT", 180, 0)
        r.badges = text(p, r, "GameFontHighlightSmall", "ink", 60, "RIGHT") r.badges:SetPoint("LEFT", 272, 0)
        r.caught = text(p, r, "GameFontHighlightSmall", "ink", 56, "RIGHT") r.caught:SetPoint("LEFT", 336, 0)
        r:EnableMouse(true)
        tooltip(r, function(self)
            local s = self.save
            if not s then return nil end
            local lines = { ("Trainer %s, %d of %d badges, %d caught in its own %s."):format(s.trainer ~= "" and s.trainer or "(no name)", s.badges or 0, s.badgeTotal or 8, s.caught or 0, POKEDEX) }
            if s.living then lines[#lines + 1] = ("%d different %s in its party and PC boxes."):format(s.living, POKEMON) end
            if s.pending then lines[#lines + 1] = "Its party and boxes count toward the Living " .. POKEDEX .. " once you open this game." end
            return gameName(s), table.concat(lines, "\n")
        end)
        p.rows[i] = r
    end
    p.more = text(p, b, "GameFontHighlightSmall", "soft", DINNER)
    p.foot = text(p, b, "GameFontHighlightSmall", "soft", DINNER, "LEFT", true)
    p.pend = text(p, b, "GameFontHighlightSmall", "ink", DINNER, "LEFT", true)
    p.note = text(p, b, "GameFontHighlightSmall", "ink", DINNER, "LEFT", true)
    messages(p, DINNER)
    p.cardButton = button(p, p, "Team card", 96, false, function()
        local v = dexView
        if v then Card.ShowCard(not v.mine and v.name or nil, p) end
    end)
    p.cardButton.tip = function() return "Team card", "The party, badges and link battles from the game played last." end
    p.again = button(p, p, "Try again", 96, false, function()
        local v = dexView
        if v and not v.mine then Card.Ask(v.name, "dex") Card.Refresh() end
    end)
    local acc = 0
    p:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc >= 1 then acc = 0 Card.Refresh() end
    end)
end

local function layoutDex()
    local p = dexPanel
    if not (p and p:IsShown() and dexView) then return end
    local v = dexView
    local who = v.mine and ((UnitName and UnitName("player")) or "You") or short(v.name)
    local status, data, at, e = "ok", nil, nil, nil
    if v.mine then data = Card.MyDex() at = data.at
    else
        e = Card.State(v.name, "dex")
        status = e and e.status or "asking"
        if e and e.status == "ok" then data, at = e.data, e.got
        else
            local seen = Card.Seen(v.name)
            if seen then data, at = seen.data, seen.at end
        end
    end
    p.title:SetText(who)
    local dex = data and data.dex
    local saves = dex and #dex.saves or 0
    local sub = (dex and plural(saves, "save", "saves") .. " on MekkaBoy") or POKEDEX
    if not v.mine and dex then sub = sub .. MID .. "as of " .. when(at) end
    if not v.mine and status == "asking" then sub = sub .. MID .. (dex and "asking for a newer one" or "asking") .. ELL end
    p.sub:SetText(sub)
    local y = -62
    local msgA, msgB
    if dex and saves > 0 then
        p.body:Show()
        p.msg:Hide() p.msg2:Hide()
        p.natCount:SetText(("%d / 386"):format(dex.caughtCount or 0))
        p.livCount:SetText(("%d / 386"):format(dex.livingCount or 0))
        setBar(p.natBar, dex.caughtCount, 386)
        setBar(p.livBar, dex.livingCount, 386)
        for i, t in ipairs(p.tiles) do
            local r = dex.regions[i] or {}
            t.data = r
            t.count:SetText(tostring(r.caught or 0))
            t.fill:SetWidth(max(1, (t.w - 20) * min(1, (r.caught or 0) / (t.region.to - t.region.from + 1))))
            t.fill:SetShown((r.caught or 0) > 0)
        end
        for i, r in ipairs(p.rows) do
            local s = dex.saves[i]
            r.save = s
            r:SetShown(s ~= nil)
            if s then
                r.dot.rgb = GAME_DOT[s.game or ""]
                r.game:SetText(gameName(s))
                r.trainer:SetText(s.trainer ~= "" and s.trainer or "-")
                r.badges:SetText(("%d / %d"):format(s.badges or 0, s.badgeTotal or 8))
                r.caught:SetText(tostring(s.caught or 0) .. (s.pending and " *" or ""))
            end
        end
        local shown = min(saves, ROWS)
        local ly = p.rowsY - shown * 20 - 8
        p.more:SetShown(saves > ROWS)
        if saves > ROWS then p.more:ClearAllPoints() p.more:SetPoint("TOPLEFT", PAD, ly) p.more:SetText(("and %d more"):format(saves - ROWS)) ly = ly - 16 end
        p.foot:ClearAllPoints() p.foot:SetPoint("TOPLEFT", PAD, ly)
        p.foot:SetText("Gen 1 and 2 saves count toward #1" .. DASH .. "251.")
        p.foot:Show()
        ly = ly - 14
        local pending = data.pending or 0
        p.pend:SetShown(pending > 0)
        if pending > 0 then
            p.pend:ClearAllPoints() p.pend:SetPoint("TOPLEFT", PAD, ly)
            p.pend:SetText(v.mine and ("* " .. plural(pending, "save", "saves") .. " will count once you open them.")
                or (plural(pending, "of their saves", "of their saves") .. " will count once they open them."))
            ly = ly - height(p.pend, 12, 1) - 2
        end
        local note
        if not v.mine and status == "timeout" then note = who .. " didn't answer just now: this is the copy from " .. when(at) .. "."
        elseif not v.mine and status == "private" then note = who .. " keeps their " .. POKEDEX .. " private now: this is the copy from " .. when(at) .. "." end
        p.note:SetShown(note ~= nil)
        if note then p.note:ClearAllPoints() p.note:SetPoint("TOPLEFT", PAD, ly) p.note:SetText(note) ly = ly - height(p.note, 12, 2) - 2 end
        y = -56 + ly - 10
    else
        p.body:Hide()
        if dex then
            msgA = v.mine and ("No " .. POKEMON .. " saves on MekkaBoy yet.") or (who .. " has no " .. POKEMON .. " saves on MekkaBoy yet.")
            msgB = v.mine and ("Play any " .. POKEMON .. " game from Red to Emerald and every save counts here.") or nil
        elseif status == "asking" then msgA = ("Asking %s for their %s%s"):format(who, POKEDEX, ELL)
        elseif status == "private" then msgA, msgB = who .. " keeps their " .. POKEDEX .. " private.", "Only people they know in WoW can see it."
        elseif status == "timeout" then msgA, msgB = who .. " didn't answer.", "They may be offline, or on an older MekkaBoy."
        elseif status == "solo" then msgA, msgB = "You are playing Solo, so nobody is asked.", "/mb play friends or /mb play open changes that." end
        y = placeMessages(p, y, msgA, msgB) - 6
    end
    local right = -PAD
    local function place(b, show)
        b:SetShown(show)
        if not show then return end
        b:ClearAllPoints()
        b:SetPoint("TOPRIGHT", p, "TOPRIGHT", right, y)
        right = right - b.w - 8
    end
    place(p.cardButton, true)
    place(p.again, not v.mine and (status == "timeout" or status == "private"))
    y = y - 24
    p:SetHeight(-y + PAD - 4)
    p.h = -y + PAD - 4
    p:Paint()
end

-- (a drawing error is kept, like a game's, for /mb bug and the tests; the windows themselves carry on)
local function guard(fn)
    local ok, err = pcall(fn)
    if not ok then MB.DB().lastError = { at = date and date("%Y-%m-%d %H:%M:%S") or "?", error = "card: " .. tostring(err):sub(1, 400) } end
end
function Card.Refresh()
    guard(layoutCard)
    guard(layoutDex)
end
Card.Changed = Card.Refresh
local changedBefore = F.Changed
F.Changed = function(...)
    if changedBefore then changedBefore(...) end
    Card.Refresh()
end

-- open one where the other was (from = the panel it was opened from)
local function swap(show, from)
    if from and from:IsShown() then
        -- (placed where the other one is on the screen, not anchored to it: the two would end up anchored to each
        -- other, which WoW refuses, and neither would open again)
        local x, top = from:GetCenter(), from:GetTop()
        show:ClearAllPoints()
        if x and top then
            local k = (from:GetEffectiveScale() or 1) / ((show:GetEffectiveScale() or 1))
            show:SetPoint("TOP", UIParent, "BOTTOMLEFT", x * k, top * k)
        else
            show:SetPoint("TOP", UIParent, "TOP", 0, -120)
        end
        from:Hide()
    else
        local other = (show == card) and dexPanel or card
        if other and other:IsShown() then other:Hide() end
    end
end
-- Card.ShowCard()           your own card
-- Card.ShowCard(name)       ask that player for theirs (a click on their mark, /mb card <name>)
function Card.ShowCard(name, from)
    if not card then buildCard() end
    if name and MB.Link.IsMe(name) then name = nil end
    if name then
        cardView = { name = name }
        local e = Card.State(name, "card")
        if not (e and e.status == "ok" and from) then Card.Ask(name, "card") end      -- (back from their Pokedex: no need to ask again)
    else
        cardView = { mine = true }
    end
    swap(card, from)
    card:Show()
    guard(layoutCard)
    return card
end
function Card.ShowDex(name, from)
    if not dexPanel then buildDex() end
    if name and MB.Link.IsMe(name) then name = nil end
    if name then
        dexView = { name = name }
        Card.Ask(name, "dex")
    else
        dexView = { mine = true }
    end
    swap(dexPanel, from)
    dexPanel:Show()
    guard(layoutDex)
    return dexPanel
end
function Card.CardPanel() return card end            -- (for tests)
function Card.DexPanel() return dexPanel end
function Card.Textures() return textures.made end
