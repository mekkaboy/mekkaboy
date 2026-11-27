-- (0.26) Three small cards for saves, in the look of the other cards (UI/Cards.lua):
--   Copy a save   one game's save as a code, selected, ready for Ctrl+C
--   Paste a save  a box to paste a code into; it says whose save it is before anything happens, and asks first
--   Backups       the copies MekkaBoy kept of one game's save (SaveCodes.lua), newest first, each with Put back
-- Opened from the settings page (Your saves) or /mb save. A card that needs the keyboard puts the console away first,
-- since the open console keeps the keyboard. Nothing is replaced without a question, and what is replaced is kept.
local _, MB = ...

local Print = MB.Print
local C = MB.CardColors
local SC = MB.SaveCode
local W = 440
local mine = {}             -- (these cards, one shown at a time)
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "2026-11-24 18:20" -> "Nov 24, 18:20" (anything else as it is)
local function pretty(at)
    local y, m, d, hm = tostring(at or ""):match("^(%d+)-(%d+)-(%d+)%s+(%d+:%d+)")
    if not y then return (at and at ~= "") and tostring(at) or "an earlier day" end
    return ("%s %d, %s"):format(MONTHS[tonumber(m)] or m, tonumber(d), hm)
end
MB.PrettyWhen = pretty

local function busy()
    if InCombatLockdown and InCombatLockdown() then Print("Not in combat.") return true end
    return false
end

-- the card's parts: a title block, a dark well holding a one-line box, a status line, buttons
local function frame(name, kicker)
    local f = MB.CardFrame(name, W)
    mine[#mine + 1] = f
    f.kicker = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.kicker:SetPoint("TOPLEFT", 20, -16)
    f.kicker:SetText(kicker)
    f.kicker:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", 20, -34)
    f.title:SetWidth(W - 40)
    f.title:SetJustifyH("LEFT")
    f.title:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -8)
    f.body:SetWidth(W - 40)
    f.body:SetJustifyH("LEFT")
    f.body:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
    return f
end
local function box(f)
    local well = CreateFrame("Frame", nil, f)
    well:SetSize(W - 40, 30)
    well:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -12)
    local bg = well:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(well)
    bg:SetColorTexture(0, 0, 0, 0.55)
    local line = well:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT") line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(C.PICK[1], C.PICK[2], C.PICK[3], 0.6)
    local e = CreateFrame("EditBox", nil, well)
    e:SetPoint("TOPLEFT", 8, 0) e:SetPoint("BOTTOMRIGHT", -8, 0)
    e:SetFontObject(GameFontHighlightSmall)
    e:SetAutoFocus(false)
    e:SetMultiLine(false)
    if e.SetMaxLetters then e:SetMaxLetters(0) end
    if e.SetMaxBytes then e:SetMaxBytes(0) end
    e:SetScript("OnEscapePressed", function() f:Hide() end)
    f.well, f.edit = well, e
    return e
end
local function status(f)
    local s = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s:SetPoint("TOPLEFT", f.well, "BOTTOMLEFT", 0, -8)
    s:SetWidth(W - 40)
    s:SetJustifyH("LEFT")
    f.status = s
    return s
end
local function say(f, str, good)
    f.status:SetText(str or "")
    if good == false then f.status:SetTextColor(1, 0.55, 0.45) elseif good then f.status:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
    else f.status:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3]) end
end
local function enable(b, on)
    b:SetEnabled(on)
    b:SetAlpha(on and 1 or 0.4)
end
-- the card's height, from what's in it (string heights are known as soon as the text is set)
local function h(fs, min) return math.max(min or 14, fs and fs:GetStringHeight() or 0) end
local function fit(f, middle)
    f:SetHeight(34 + h(f.title, 22) + 8 + h(f.body, 18) + 12 + middle + 14 + 28 + 16)
end
local function show(f)
    if MB.Hide then pcall(MB.Hide) end           -- (the console keeps the keyboard while it's open)
    for _, c in pairs(MB.Cards and MB.Cards() or {}) do if c:IsShown() then c:Hide() end end
    for _, c in ipairs(mine) do if c ~= f and c:IsShown() then c:Hide() end end
    f:Show()
    if f.fade then f.fade:Stop() f.fade:Play() end
end

-- ------------------------------------------------------- Copy a save ---
local copy
function MB.CopySave(id)
    if busy() then return end
    local save, c = MB.SaveOf(id)
    if not c then Print("Pick a game that has a save.") return end
    if not save then Print(c.name .. " has no save yet. Play until the game saves, then copy it.") return end
    local code, why = SC.Make(MB.CartKind(c), c, save)
    if why == "blank" then
        Print(("%s hasn't been saved in the game yet, so there's nothing to copy. Save in the game's own menu first. Where you left off and memory valves aren't part of a copied save."):format(c.name))
        return
    end
    if not code then Print(why) return end
    if not copy then
        copy = frame("MekkaBoySaveCopy", "COPY A SAVE")
        copy.body:SetText("Press Ctrl+C to copy this code, then keep it somewhere safe. Pasting it into MekkaBoy puts this save back, on any computer or character.")
        local e = box(copy)
        e:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        e:SetScript("OnTextChanged", function(self, user) if user then self:SetText(copy.code or "") self:HighlightText() end end)
        e:SetScript("OnMouseUp", function(self) self:HighlightText() end)
        status(copy)
        copy.done = MB.CardButton(copy, "Done", 96, true)
        copy.done:SetPoint("TOPLEFT", copy.status, "BOTTOMLEFT", 0, -14)
        copy.done:SetScript("OnClick", function() copy:Hide() end)
    end
    copy.code = code
    copy.title:SetText(c.name)
    copy.edit:SetText(code)
    say(copy, ("The game's own save, from the last time it was saved in the game (kept %s). Where you left off and memory valves stay here."):format(pretty(save.at)))
    show(copy)
    copy.edit:SetFocus()
    copy.edit:HighlightText()
    fit(copy, 30 + 8 + h(copy.status))
end

-- ------------------------------------------------------ Paste a save ---
local paste
-- which game on the shelf a code is for: the same id, else the same game code
local function target(info)
    local c = MB.Carts.Find(info.id)
    if c and MB.CartHasSaves(c) and MB.CartKind(c) == info.kind then return c end
    if info.code then
        for _, x in ipairs(MB.Carts.List()) do
            if x.code == info.code and MB.CartHasSaves(x) and MB.CartKind(x) == info.kind then return x end
        end
    end
    return nil
end
local function check()
    local text = paste.edit:GetText() or ""
    paste.ready = nil
    enable(paste.go, false)
    if text:gsub("%s", "") == "" then say(paste, "Click the box above, then Ctrl+V.") return end
    local info, why = SC.Read(text)
    if not info then say(paste, why, false) return end
    local c = target(info)
    if not c then say(paste, ("That's a save of %s. Add the game to MekkaBoy first, then paste the save again."):format(info.name ~= "" and info.name or info.id), false) return end
    paste.ready = { text = text, info = info, cart = c }
    say(paste, ("%s, saved %s. Ready to put in."):format(c.name, pretty(info.when)), true)
    enable(paste.go, true)
end
local function putIn()
    local r = paste and paste.ready
    if not r then return end
    local save, why = SC.Open(r.text)
    if not save then say(paste, why, false) enable(paste.go, false) return end
    local c = r.cart
    paste:Hide()
    local has = MB.SaveOf(c.id)
    local ask = has and ("Replace your %s save with the pasted one?\nThe save you have now is kept in Backups."):format(c.name)
        or ("Put the pasted save in %s?"):format(c.name)
    MB.Friends.Ask("savepaste", ask, has and "Replace" or "Put it in", "Cancel", function()
        local ok, err = MB.PutSave(c.id, save, "paste")
        if ok then Print(("%s has the pasted save (from %s). Your old one is in Backups."):format(c.name, pretty(save.at)))
        else Print(err) end
    end, nil, 0)
end
function MB.PasteSave()
    if busy() then return end
    if not paste then
        paste = frame("MekkaBoySavePaste", "PASTE A SAVE")
        paste.title:SetText("Put a save back")
        paste.body:SetText("Copy a save code, click the box below and press Ctrl+V. MekkaBoy says whose save it is before anything changes.")
        local e = box(paste)
        e:SetScript("OnTextChanged", function() check() end)
        e:SetScript("OnEnterPressed", function() if paste.ready then putIn() end end)
        status(paste)
        paste.go = MB.CardButton(paste, "Put it in", 110, true)
        paste.go:SetPoint("TOPLEFT", paste.status, "BOTTOMLEFT", 0, -14)
        paste.go:SetScript("OnClick", putIn)
        local cancel = MB.CardButton(paste, "Cancel", 96, false)
        cancel:SetPoint("LEFT", paste.go, "RIGHT", 8, 0)
        cancel:SetScript("OnClick", function() paste:Hide() end)
    end
    paste.edit:SetText("")
    check()
    show(paste)
    paste.edit:SetFocus()
    fit(paste, 30 + 8 + h(paste.status))
end

-- ----------------------------------------------------------- Backups ---
local backups
local ROWS = 5
function MB.ShowBackups(id)
    if busy() then return end
    local c = id and MB.Carts.Find(id)
    if not (c and MB.CartHasSaves(c)) then Print("Pick a game that has a save.") return end
    local _, _, key = MB.SaveOf(id)
    local list = SC.Backups(key)
    if not backups then
        backups = frame("MekkaBoySaveBackups", "BACKUPS")
        backups.rows = {}
        local anchor = backups.body
        for i = 1, ROWS do
            local r = CreateFrame("Frame", nil, backups)
            r:SetSize(W - 40, 34)
            r:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -12 or -4)
            local bg = r:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(r)
            bg:SetColorTexture(1, 1, 1, 0.04)
            r.when = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.when:SetPoint("TOPLEFT", 10, -4)
            r.when:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
            r.why = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.why:SetPoint("TOPLEFT", r.when, "BOTTOMLEFT", 0, -2)
            r.why:SetTextColor(C.SOFT[1], C.SOFT[2], C.SOFT[3])
            r.put = MB.CardButton(r, "Put back", 90, false)
            r.put:SetHeight(24)
            r.put:SetPoint("RIGHT", -6, 0)
            backups.rows[i] = r
            anchor = r
        end
        backups.empty = backups:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        backups.empty:SetPoint("TOPLEFT", backups.body, "BOTTOMLEFT", 0, -12)
        backups.empty:SetWidth(W - 40)
        backups.empty:SetJustifyH("LEFT")
        backups.empty:SetTextColor(C.INK[1], C.INK[2], C.INK[3])
        backups.empty:SetText("No backups yet. One is kept the first time you play the game each day, and another before its save is replaced.")
        backups.done = MB.CardButton(backups, "Done", 96, true)
        backups.done:SetScript("OnClick", function() backups:Hide() end)
    end
    backups.title:SetText(c.name)
    backups.body:SetText("MekkaBoy keeps the last 5 copies of this game's save. Putting one back keeps the save you have now as a backup too.")
    local shown = 0
    for i, r in ipairs(backups.rows) do
        local b = list[i]
        if b then
            shown = i
            r.when:SetText(pretty(b.at))
            r.why:SetText(b.words)
            r.put:SetScript("OnClick", function()
                backups:Hide()
                MB.Friends.Ask("saverestore", ("Put back the %s backup from %s?\nThe save you have now is kept as a backup too."):format(c.name, pretty(b.at)),
                    "Put it back", "Cancel", function()
                        local save, why = SC.Open(b.code)
                        if not save then Print("That backup couldn't be read: " .. tostring(why)) return end
                        local ok, err = MB.PutSave(c.id, save, "restore")
                        if ok then Print(("%s is back to the backup from %s."):format(c.name, pretty(b.at))) else Print(err) end
                    end, nil, 0)
            end)
            r:Show()
        else
            r:Hide()
        end
    end
    backups.empty:SetShown(shown == 0)
    backups.done:ClearAllPoints()
    backups.done:SetPoint("TOPLEFT", shown > 0 and backups.rows[shown] or backups.empty, "BOTTOMLEFT", 0, -16)
    show(backups)
    fit(backups, shown > 0 and (shown * 38 - 4 + 2) or h(backups.empty, 18) + 2)
end

-- ------------------------------------------------------------ /mb save ---
-- the game a command means: the one named, else the one in the console
local function pickGame(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest ~= "" then
        for _, c in ipairs(MB.Carts.List()) do
            if MB.CartHasSaves(c) and (c.name:lower():find(rest:lower(), 1, true) or c.id:lower() == rest:lower()) then return c.id end
        end
        Print("No game matches \"" .. rest .. "\".")
        return nil
    end
    local id = MB.InConsole and MB.InConsole()
    if not id then Print("Put the game in the console first, or name it: /mb save copy emerald.") end
    return id
end
MB.AddCommand("save", "save copy [game] | save paste | save backups [game] - copy a save out as a code, put one back, or see the backups", function(rest)
    local verb, more = (rest or ""):match("^%s*(%S*)%s*(.*)$")
    verb = (verb or ""):lower()
    if verb == "copy" or verb == "export" then local id = pickGame(more) if id then MB.CopySave(id) end
    elseif verb == "paste" or verb == "import" then MB.PasteSave()
    elseif verb == "backups" or verb == "backup" then local id = pickGame(more) if id then MB.ShowBackups(id) end
    else Print("/mb save copy [game] copies a save out as a code. /mb save paste puts one back. /mb save backups [game] shows the copies MekkaBoy kept.") end
end)
