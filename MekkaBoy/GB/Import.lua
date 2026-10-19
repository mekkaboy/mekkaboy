-- Pasted cartridges. A game can be brought in without touching any folder:
-- a tool outside the game (Tools/rom2code.py) packs a ROM you own into one
-- long line of text, and /mb import takes it from the clipboard. The game is
-- then kept with your saved settings, in one of a few small "slot" addons
-- (MekkaBoy_Slot1..) that are only read when that game is put in the console.
--
-- A code is:  MEKKA1:<id>:<name>:<banks>:<color>:<size>:<sum>:<sum>:<data>:END
-- where <data> is the ROM, zlib-compressed and base64-encoded.
local _, MB = ...

local Import = {}
MB.Import = Import

local SLOTS = 4
local BANK = 16384
local Print = MB.Print
local floor = math.floor
local clock = debugprofilestop or function() return GetTime() * 1000 end

-- ------------------------------------------------------------ checksums ---
local function adler32(s)
    local a, b = 1, 0
    local n = #s
    local i = 1
    while i <= n do
        local j = i + 3999
        if j > n then j = n end
        -- 4000 bytes at a time keeps the sums small enough to take the remainder once
        for k = i, j, 16 do
            local c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16 = s:byte(k, k + 15 > j and j or k + 15)
            a = a + c1 b = b + a
            if c2 then a = a + c2 b = b + a end
            if c3 then a = a + c3 b = b + a end
            if c4 then a = a + c4 b = b + a end
            if c5 then a = a + c5 b = b + a end
            if c6 then a = a + c6 b = b + a end
            if c7 then a = a + c7 b = b + a end
            if c8 then a = a + c8 b = b + a end
            if c9 then a = a + c9 b = b + a end
            if c10 then a = a + c10 b = b + a end
            if c11 then a = a + c11 b = b + a end
            if c12 then a = a + c12 b = b + a end
            if c13 then a = a + c13 b = b + a end
            if c14 then a = a + c14 b = b + a end
            if c15 then a = a + c15 b = b + a end
            if c16 then a = a + c16 b = b + a end
        end
        a, b = a % 65521, b % 65521
        i = j + 1
    end
    return b * 65536 + a
end
Import.adler32 = adler32

-- ---------------------------------------------------- unpacking in Lua ---
-- Used when the game client has no decoder of its own.
local B64 = {}
do
    local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[abc:byte(i)] = i - 1 end
end

-- base64 text -> a function that hands out the decoded bytes one at a time
local function byteReader(text)
    local pos, n = 1, #text
    local q, qn, qi = {}, 0, 1
    return function()
        if qi > qn then
            if pos > n then return nil end
            qn, qi = 0, 1
            local stop = pos + 399
            if stop > n then stop = n end
            for k = pos, stop, 4 do
                local c1, c2, c3, c4 = text:byte(k, k + 3)
                local v1, v2, v3, v4 = B64[c1], B64[c2], B64[c3], B64[c4]
                if not v1 or not v2 then return nil end
                local x = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
                q[qn + 1] = floor(x / 65536)
                qn = qn + 1
                if v3 then q[qn + 1] = floor(x / 256) % 256 qn = qn + 1 end
                if v4 then q[qn + 1] = x % 256 qn = qn + 1 end
            end
            pos = stop + 1
            if qn == 0 then return nil end
        end
        local v = q[qi]
        qi = qi + 1
        return v
    end
end

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- a Huffman table from a list of code lengths (index 0..n-1)
local function huffman(lengths, n)
    local count, symbol, offs = {}, {}, {}
    for i = 0, 15 do count[i] = 0 end
    for s = 0, n - 1 do count[lengths[s]] = count[lengths[s]] + 1 end
    offs[1] = 0
    for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
    for s = 0, n - 1 do
        local l = lengths[s]
        if l ~= 0 then
            symbol[offs[l]] = s
            offs[l] = offs[l] + 1
        end
    end
    return { count = count, symbol = symbol }
end

-- zlib data (as base64 text) -> list of 16 KB strings, or nil and why not
local function inflateToBanks(text, expect)
    local nextByte = byteReader(text)
    local bitbuf, bitcnt = 0, 0
    local function bits(n)
        while bitcnt < n do
            local c = nextByte()
            if not c then error("the code ends too soon") end
            bitbuf = bitbuf + c * 2 ^ bitcnt
            bitcnt = bitcnt + 8
        end
        local v = bitbuf % 2 ^ n
        bitbuf = (bitbuf - v) / 2 ^ n
        bitcnt = bitcnt - n
        return v
    end
    local function decode(h)
        local code, first, index = 0, 0, 0
        local count, symbol = h.count, h.symbol
        for len = 1, 15 do
            if bitcnt == 0 then
                local c = nextByte()
                if not c then error("the code ends too soon") end
                bitbuf, bitcnt = c, 8
            end
            local bit = bitbuf % 2
            bitbuf = (bitbuf - bit) / 2
            bitcnt = bitcnt - 1
            code = code + bit
            local c = count[len]
            if code - c < first then return symbol[index + (code - first)] end
            index = index + c
            first = (first + c) * 2
            code = code * 2
        end
        error("the code is damaged")
    end

    local win, wpos = {}, 0            -- the last 32768 bytes written
    local cur, cn = {}, 0              -- the bank being filled
    local banks, total = {}, 0
    local char, concat = string.char, table.concat
    local function flush()
        local parts = {}
        for i = 1, cn, 64 do
            local j = i + 63
            if j > cn then j = cn end
            parts[#parts + 1] = char(unpack(cur, i, j))
        end
        banks[#banks + 1] = concat(parts)
        cn = 0
    end
    local function put(v)
        win[wpos] = v
        wpos = (wpos + 1) % 32768
        cn = cn + 1
        cur[cn] = v
        total = total + 1
        if cn == BANK then flush() end
    end

    local fixedLit, fixedDist
    if bits(8) % 16 ~= 8 then error("not a MekkaBoy code") end
    bits(8)
    local last
    repeat
        last = bits(1)
        local kind = bits(2)
        if kind == 0 then
            bits(bitcnt % 8)
            local len = bits(16)
            bits(16)
            for _ = 1, len do put(bits(8)) end
        elseif kind == 1 or kind == 2 then
            local lit, dist
            if kind == 1 then
                if not fixedLit then
                    local l = {}
                    for i = 0, 143 do l[i] = 8 end
                    for i = 144, 255 do l[i] = 9 end
                    for i = 256, 279 do l[i] = 7 end
                    for i = 280, 287 do l[i] = 8 end
                    fixedLit = huffman(l, 288)
                    local d = {}
                    for i = 0, 29 do d[i] = 5 end
                    fixedDist = huffman(d, 30)
                end
                lit, dist = fixedLit, fixedDist
            else
                local nlen = bits(5) + 257
                local ndist = bits(5) + 1
                local ncode = bits(4) + 4
                local l = {}
                for i = 0, 18 do l[i] = 0 end
                for i = 1, ncode do l[ORDER[i]] = bits(3) end
                local lencode = huffman(l, 19)
                local all, idx = {}, 0
                while idx < nlen + ndist do
                    local sym = decode(lencode)
                    if sym < 16 then
                        all[idx] = sym
                        idx = idx + 1
                    else
                        local prev, rep = 0, 0
                        if sym == 16 then
                            prev = all[idx - 1]
                            rep = 3 + bits(2)
                        elseif sym == 17 then
                            rep = 3 + bits(3)
                        else
                            rep = 11 + bits(7)
                        end
                        for _ = 1, rep do
                            all[idx] = prev
                            idx = idx + 1
                        end
                    end
                end
                local ll, dl = {}, {}
                for i = 0, nlen - 1 do ll[i] = all[i] end
                for i = 0, ndist - 1 do dl[i] = all[nlen + i] end
                lit, dist = huffman(ll, nlen), huffman(dl, ndist)
            end
            while true do
                local sym = decode(lit)
                if sym < 256 then
                    put(sym)
                elseif sym == 256 then
                    break
                else
                    sym = sym - 256
                    local len = LEN_BASE[sym]
                    if LEN_EXTRA[sym] > 0 then len = len + bits(LEN_EXTRA[sym]) end
                    local ds = decode(dist) + 1
                    local d = DIST_BASE[ds]
                    if DIST_EXTRA[ds] > 0 then d = d + bits(DIST_EXTRA[ds]) end
                    local from = (wpos - d) % 32768
                    for _ = 1, len do
                        put(win[from])
                        from = (from + 1) % 32768
                    end
                end
            end
        else
            error("the code is damaged")
        end
    until last == 1
    if cn > 0 then flush() end
    if total ~= expect then error("the game came out the wrong size") end
    return banks
end

-- ---------------------------------------------------------------- codes ---
-- the label on a code, without unpacking it
function Import.Read(code)
    if type(code) ~= "string" then return nil, "That is not a MekkaBoy code." end
    code = code:gsub("%s+", "")
    local id, name64, banks, cgb, size, romSum, textSum, at = code:match("^MEKKA1:([%w_]+):([%w+/=]*):(%d+):([01]):(%d+):(%d+):(%d+):()")
    if not id then
        if code:sub(1, 5) == "MEKKA" then return nil, "This code is for a newer MekkaBoy. Update the addon and try again." end
        return nil, "That is not a MekkaBoy code. Copy the whole code, from MEKKA1 to END."
    end
    if code:sub(-4) ~= ":END" then
        return nil, ("Only part of the code arrived (%d KB). Copy the whole of it, from MEKKA1 to END."):format(floor(#code / 1024))
    end
    local info = { id = id, numBanks = tonumber(banks), cgb = (cgb == "1"), size = tonumber(size),
                   romSum = tonumber(romSum), textSum = tonumber(textSum), code = code,
                   first = at, last = #code - 4 }
    if info.size ~= info.numBanks * BANK or info.numBanks < 2 then return nil, "The code's label makes no sense." end
    -- the name is base64 too; unpack it the slow way (it is short)
    local next8, t = byteReader(name64), {}
    for _ = 1, 64 do
        local c = next8()
        if not c then break end
        t[#t + 1] = string.char(c)
    end
    info.name = (#t > 0) and table.concat(t) or id
    return info
end

-- Unpack a code into its ROM. Returns info, banks (a list of 16 KB strings),
-- or nil and why not. info.how says which decoder did the work, info.ms how long.
function Import.Unpack(code)
    local info, why = Import.Read(code)
    if not info then return nil, why end
    local t0 = clock()
    local payload = info.code:sub(info.first, info.last)
    if adler32(payload) ~= info.textSum then
        return nil, "The code was damaged on the way in (a few characters are wrong). Copy it again."
    end
    info.checkMs = clock() - t0
    t0 = clock()
    local banks
    local E = C_EncodingUtil
    if E and E.DecodeBase64 and E.DecompressString and not Import.forceLua then
        local ok, rom = pcall(function()
            local bin = E.DecodeBase64(payload)
            local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib or 1
            return E.DecompressString(bin, method)
        end)
        if ok and type(rom) == "string" and #rom == info.size then
            banks = {}
            for i = 1, info.numBanks do banks[i] = rom:sub((i - 1) * BANK + 1, i * BANK) end
            info.how = "client"
        else
            info.clientError = tostring(rom)
        end
    end
    if not banks then
        local ok, res = pcall(inflateToBanks, payload, info.size)
        if not ok then return nil, "The code could not be unpacked: " .. tostring(res):gsub("^.-:%d+: ", "") end
        banks = res
        info.how = "lua"
    end
    info.ms = clock() - t0
    if #banks ~= info.numBanks then return nil, "The game came out the wrong size." end
    return info, banks
end

-- ---------------------------------------------------------------- slots ---
local A = C_AddOns or {}
local LoadAddOn = A.LoadAddOn or LoadAddOn
local EnableAddOn = A.EnableAddOn or EnableAddOn

local function imports()
    local db = MB.DB()
    db.imports = db.imports or {}
    return db.imports
end

local function openSlot(n)
    local name = "MekkaBoy_Slot" .. n
    if not LoadAddOn then return false, "no addon loader" end
    local ok, reason = LoadAddOn(name)
    if not ok and reason == "DISABLED" and EnableAddOn then
        EnableAddOn(name)
        ok, reason = LoadAddOn(name)
    end
    return ok and true or false, reason
end

-- the pasted games on the shelf: id -> { slot =, name =, numBanks =, cgb = }
function Import.List() return imports() end

-- read a pasted game back out of its slot: banks, or nil and why not
function Import.Load(id)
    local e = imports()[id]
    if not e then return nil, "There is no such cartridge." end
    local ok, reason = openSlot(e.slot)
    local held = _G["MekkaBoySlot" .. e.slot]
    if type(held) ~= "table" or held.id ~= id or type(held.code) ~= "string" then
        return nil, ok and "This pasted cartridge has gone missing. Paste its code again with /mb import."
            or ("The cartridge's slot would not open (%s). Check that MekkaBoy_Slot%d is enabled in the AddOns list."):format(tostring(reason), e.slot)
    end
    local info, banks = Import.Unpack(held.code)
    if not info then return nil, banks end
    return banks, info
end

-- keep a code: returns info and banks, or nil and why not
function Import.Keep(code)
    local info, banks = Import.Unpack(code)
    if not info then return nil, banks end
    local list = imports()
    -- Already here as a cartridge folder (which can have sound)? Then there
    -- is nothing to keep: the folder is the copy that gets played.
    local have = MB.Carts.Find(info.id)
    if have and have.addon and not list[info.id] then
        info.folder, info.name = true, have.name
        return info, banks
    end
    local slot = list[info.id] and list[info.id].slot
    if not slot then
        local used = {}
        for _, e in pairs(list) do used[e.slot] = true end
        for n = 1, SLOTS do
            if not used[n] then slot = n break end
        end
    end
    if not slot then
        return nil, ("All %d places for pasted cartridges are taken. /mb import remove <name> frees one."):format(SLOTS)
    end
    local ok, reason = openSlot(slot)
    info.kept = ok
    info.slotError = (not ok) and tostring(reason) or nil
    _G["MekkaBoySlot" .. slot] = { id = info.id, code = info.code }
    list[info.id] = { slot = slot, name = info.name, numBanks = info.numBanks, cgb = info.cgb }
    MB.Carts.Adopt(info.id, info.name, info.numBanks, info.cgb, banks)
    return info, banks
end

function Import.Remove(id)
    local list = imports()
    local e = list[id]
    if not e then return false end
    if openSlot(e.slot) then _G["MekkaBoySlot" .. e.slot] = nil end
    list[id] = nil
    MB.Carts.Forget(id)
    return true
end

-- ------------------------------------------------------------ the window ---
local win
local function record(entry)
    local db = MB.DB()
    db.pasteTests = db.pasteTests or {}
    table.insert(db.pasteTests, entry)
    while #db.pasteTests > 30 do table.remove(db.pasteTests, 1) end
end

local function received(text, pasteMs)
    local entry = { when = date and date("%Y-%m-%d %H:%M") or "", chars = #text, pasteMs = floor(pasteMs),
                    client = (C_EncodingUtil and C_EncodingUtil.DecompressString) and true or false }
    local t0 = clock()
    local info, why = Import.Keep(text)
    entry.totalMs = floor(clock() - t0)
    if not info then
        entry.error = why
        win.ready = nil
        win.play:Hide()
        win.status:SetText("|cffff6060" .. why .. "|r")
    else
        entry.id, entry.how, entry.unpackMs, entry.checkMs = info.id, info.how, floor(info.ms), floor(info.checkMs)
        entry.kept, entry.slotError, entry.clientError = info.kept, info.slotError, info.clientError
        local kept = info.folder and "You already have this game as a cartridge folder, so that copy is the one that plays and nothing more was stored."
            or info.kept and "It is on the shelf, and will be kept when you log out or /reload."
            or "It is on the shelf for now, but could not be kept (the slot addon is missing: restart the game client)."
        win.status:SetText(("|cff60ff60%s %s|r %s"):format(info.name, info.folder and "is on your shelf." or "is in.", kept))
        win.ready = info.id
        win.play:Show()
    end
    record(entry)
    Import.last = entry
end
Import.Received = received

local function build()
    win = CreateFrame("Frame", "MekkaBoyImportWindow", UIParent)
    win:SetSize(460, 322)
    win:SetPoint("CENTER", 0, 120)
    win:SetFrameStrata("DIALOG")
    win:EnableMouse(true)
    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(win)
    bg:SetColorTexture(0.07, 0.06, 0.05, 0.96)
    local edge = win:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 0, 0)
    edge:SetPoint("TOPRIGHT", 0, 0)
    edge:SetHeight(3)
    edge:SetColorTexture(0.85, 0.65, 0.25, 1)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("MekkaBoy - add a game you own")
    local function line(y, text)
        local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 16, y)
        fs:SetWidth(428)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    local function field(y)
        local e = CreateFrame("EditBox", nil, win)
        e:SetPoint("TOPLEFT", 16, y)
        e:SetSize(428, 22)
        e:SetFontObject(ChatFontNormal)
        e:SetAutoFocus(false)
        local t = e:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints(e)
        t:SetColorTexture(0, 0, 0, 0.6)
        e:SetScript("OnEscapePressed", function() win:Hide() end)
        return e
    end
    local url = MB.WORKSHOP_URL or ""
    if url ~= "" then
        line(-40, "|cffffd100Step 1.|r Open the MekkaBoy Workshop in your web browser. Click the address below, press Ctrl+C, then paste it into your browser.")
        -- the address can be copied but not changed
        local link = field(-70)
        link:SetText(url)
        link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        link:SetScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
        link:SetScript("OnTextChanged", function(self, typed)
            if typed then self:SetText(url) self:HighlightText() end
        end)
        win.link = link
    else
        line(-40, "|cffffd100Step 1.|r Open the file Workshop.html in your web browser. It is in the MekkaBoy folder, inside the game's Interface\\AddOns folder.")
    end
    line(-102, "|cffffd100Step 2.|r Drop your game on that page and press Copy the code.")
    line(-122, "|cffffd100Step 3.|r Click the box below and press Ctrl+V. A big game can freeze the screen for a second or two while it arrives.")
    win.advance = line(-156, "|cffa0a0a0A Game Boy Advance game is too big to paste: the same page makes a cartridge folder for it and tells you where it goes.|r")
    local box = field(-188)
    box:SetMaxBytes(256)                 -- the box only shows the start; the rest is caught as it is typed in
    win.box = box
    local status = line(-220, "Waiting for a code.")
    win.status = status
    local play = CreateFrame("Button", nil, win)
    play:SetSize(150, 26)
    play:SetPoint("BOTTOM", 0, 14)
    local playBg = play:CreateTexture(nil, "BACKGROUND")
    playBg:SetAllPoints(play)
    playBg:SetColorTexture(0.85, 0.65, 0.25, 1)
    local playText = play:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playText:SetPoint("CENTER")
    playText:SetTextColor(0.1, 0.07, 0.02)
    playText:SetText("Play it now")
    play:SetScript("OnClick", function()
        local id = win.ready
        if not id then return end
        win:Hide()
        if MB.PlayCart then MB.PlayCart(id) end
    end)
    play:Hide()
    win.play = play
    local close = CreateFrame("Button", nil, win)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -6, -6)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    x:SetText("x")
    close:SetScript("OnClick", function() win:Hide() end)

    -- A paste arrives as one "typed" character after another, all within a
    -- moment. Collect them, and act once they stop coming.
    local buf, n, started, quiet = {}, 0, 0, 0
    box:SetScript("OnChar", function(_, c)
        if n == 0 then started = clock() end
        n = n + 1
        buf[n] = c
        quiet = 0
    end)
    box:SetScript("OnUpdate", function()
        if n == 0 then return end
        quiet = quiet + 1
        if quiet < 2 then return end       -- wait one whole frame with nothing new
        local text = table.concat(buf, "", 1, n)
        local ms = clock() - started
        buf, n = {}, 0
        box:SetText("")
        box:ClearFocus()
        if #text < 20 then
            status:SetText("That was only " .. #text .. " characters. Copy the whole code and paste it here.")
            return
        end
        received(text, ms)
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "MekkaBoyImportWindow") end
    win:Hide()
end

function Import.Open()
    if InCombatLockdown() then Print("Not in combat.") return end
    if not win then build() end
    if MB.window:IsShown() then MB.Hide() end   -- the console keeps the keyboard to itself while open
    win.status:SetText("Waiting for a code.")
    win.ready = nil
    win.play:Hide()
    win:Show()
    win.box:SetFocus()
end

MB.AddCommand("setup", "setup - add a game you own (three steps, no folders)", function() Import.Open() end)

MB.AddCommand("import", "import - the same window; also import list | check | remove <name>", function(rest)
    local verb, arg = rest:match("^(%S*)%s*(.-)$")
    verb = verb:lower()
    if verb == "" then
        Import.Open()
    elseif verb == "list" or verb == "check" then
        local any = false
        for id, e in pairs(imports()) do
            any = true
            if verb == "list" then
                print(("  %s (%s), place %d"):format(e.name, id, e.slot))
            else
                local banks, info = Import.Load(id)
                if banks then
                    print(("  %s: fine. Unpacked by the %s in %.2f s."):format(e.name, info.how == "client" and "game client" or "addon", (info.ms + info.checkMs) / 1000))
                    record({ when = date and date("%Y-%m-%d %H:%M") or "", check = id, how = info.how, unpackMs = floor(info.ms), checkMs = floor(info.checkMs) })
                else
                    print(("  %s: %s"):format(e.name, tostring(info)))
                    record({ when = date and date("%Y-%m-%d %H:%M") or "", check = id, error = tostring(info) })
                end
            end
        end
        if not any then Print("No pasted cartridges. /mb import takes one.") end
    elseif verb == "remove" then
        local found
        for id, e in pairs(imports()) do
            if id:lower() == arg:lower() or (arg ~= "" and e.name:lower():find(arg:lower(), 1, true)) then found = id end
        end
        if found then
            local name = imports()[found].name
            Import.Remove(found)
            Print(name .. " removed. Its saves are kept in case you paste it again.")
        else
            Print("No pasted cartridge matches that. /mb import list shows them.")
        end
    else
        Print("/mb import opens the paste window. Also: import list, import check, import remove <name>.")
    end
end)
