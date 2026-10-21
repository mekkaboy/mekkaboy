-- Pictures for the team card: the Gen 3 games' own party-menu icons (the small Pokemon of the party screen), read from
-- the player's own ROM while a Ruby, Sapphire, Emerald, FireRed or LeafGreen cartridge is in memory. Nothing is
-- shipped, and no cartridge is ever loaded for a picture: with no Gen 3 cartridge in memory (and nothing kept, below)
-- the card draws a dashed square instead.
--
-- Where they are: the icons' palette list (six entries, each a ROM address and the tag 56000 + i) is found by its tags;
-- right before it are the 440 palette numbers (one byte each, 0-5) and right before those the 440 picture addresses,
-- in the game's own species order (412 = the egg). The same layout in every Gen 3 game tried (Ruby, Sapphire, Emerald,
-- FireRed, LeafGreen); everything is checked before it is used (the tags, every number and address in range).
-- A picture is 32 x 32 dots, 4 bits each, in 8 x 8 tiles (the first of its two frames); colour 0 is see-through.
--
-- Icons.Name(n) that species' name in the same cartridge (when Dex has none yet)
-- Icons.Get(n)  National Dex n (0 = an egg) -> { rects = { { x, y, w, h, r, g, b }, ... } } or nil. The dots are drawn
--               as rectangles: runs of one colour along a row, merged with the same run in the rows below (about 120
--               per picture, at most about 220).
-- Kept (MekkaBoyDB.dex.icons): the last KEEP pictures asked for, as their dots, and the palettes, so the card keeps
-- its pictures after a reload, before a Gen 3 cartridge is in memory again.
local _, MB = ...
local Icons = {}
MB.DexIcons = Icons
local R = MB.DexRead
local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat

local COUNT, KEEP = 440, 64
local EGG = 412

local function romBytes(rom, at, n)
    local out, got = {}, 0
    while got < n do
        local b = rom.banks[floor((at + got) / 16384) + 1]
        if type(b) ~= "string" then return nil end
        local off = (at + got) % 16384
        local piece = b:sub(off + 1, off + (n - got))
        if piece == "" then return nil end
        out[#out + 1] = piece
        got = got + #piece
    end
    return concat(out)
end
local function u32(s, o) local a, b, c, d = byte(s, o + 1, o + 4) return a + b * 256 + c * 65536 + d * 16777216 end
local function u16(s, o) local a, b = byte(s, o + 1, o + 2) return a + b * 256 end

-- the icon tables of a ROM in memory: { tab, idx, pals = { [0..5] = { [0..15] = colour } }, size } or false
local found = setmetatable({}, { __mode = "k" })
local function locate(rom)
    local size = (rom.numBanks or #rom.banks) * 16384
    local tag = "\192\218\0\0"
    local pt
    for i = 1, rom.numBanks or #rom.banks do
        local b = rom.banks[i]
        if type(b) ~= "string" then return false end
        local p = b:find(tag, 1, true)
        while p do
            if (p - 1) % 4 == 0 and p > 4 then
                local at = (i - 1) * 16384 + p - 5
                local list = romBytes(rom, at, 48)
                local good = list ~= nil
                for e = 0, 5 do
                    if not good then break end
                    local ptr = u32(list, e * 8) - 0x08000000
                    good = u16(list, e * 8 + 4) == 0xDAC0 + e and ptr >= 0 and ptr + 32 <= size
                end
                if good then
                    if pt then return false end                    -- (twice: not sure which, so neither)
                    pt = at
                end
            end
            p = b:find(tag, p + 1, true)
        end
    end
    if not pt then return false end
    local idx, tab = pt - COUNT, pt - COUNT - COUNT * 4
    local ib, tb = romBytes(rom, idx, COUNT), romBytes(rom, tab, COUNT * 4)
    if not (ib and tb) then return false end
    for i = 1, COUNT do if byte(ib, i) > 5 then return false end end
    for i = 0, COUNT - 1 do
        local ptr = u32(tb, i * 4) - 0x08000000
        if ptr < 0 or ptr + 512 > size then return false end
    end
    local pals, list = {}, romBytes(rom, pt, 48)
    for e = 0, 5 do
        local d = romBytes(rom, u32(list, e * 8) - 0x08000000, 32)
        if not d then return false end
        local c = {}
        for k = 0, 15 do c[k] = u16(d, k * 2) % 32768 end
        pals[e] = c
    end
    return { tab = tb, idx = ib, pals = pals }
end
Icons.Locate = function(rom)
    if found[rom] == nil then local ok, t = pcall(locate, rom) found[rom] = ok and t or false end
    return found[rom] or nil
end

-- a Gen 3 cartridge already in memory (nothing is read from disk), with its tables
local function source()
    if not (MB.Carts and MB.Carts.List and MB.Carts.Peek) then return nil end
    for _, c in ipairs(MB.Carts.List()) do
        local rom = c.system == "gba" and MB.Carts.Peek(c.id)
        if rom and rom.system == "gba" and rom.banks and rom.numBanks then
            local complete = true
            for i = 1, rom.numBanks do if type(rom.banks[i]) ~= "string" then complete = false break end end
            local code = complete and R.RomCode(rom)
            if code and R.FAMILY3[code] then
                local loc, t = Icons.Locate(rom), R.Tables(rom)
                if loc and t and t.nat then return rom, loc, t.nat end
            end
        end
    end
    return nil
end

local HEX = {}
for i = 0, 255 do HEX[i] = ("%02x"):format(i) end
local UNHEX = {}
for i = 0, 255 do UNHEX[("%02x"):format(i)] = char(i) end

local function kept()
    local d = MB.Dex and MB.Dex.Store and MB.Dex.Store()
    if not d then return nil end
    if type(d.icons) ~= "table" or type(d.icons.mons) ~= "table" then d.icons = { mons = {}, n = 0 } end
    return d.icons
end
local function keep(n, raw, pal, pals)
    local k = kept()
    if not k then return end
    if not k.pals then
        local t = {}
        for e = 0, 5 do for c = 0, 15 do t[#t + 1] = ("%04x"):format(pals[e][c]) end end
        k.pals = concat(t)
    end
    k.n = (k.n or 0) + 1
    local hex = {}
    for i = 1, #raw do hex[i] = HEX[byte(raw, i)] end
    k.mons[n] = { d = concat(hex), p = pal, u = k.n }
    local count, oldest, oldN = 0, nil, nil
    for m, e in pairs(k.mons) do
        count = count + 1
        if not oldest or (e.u or 0) < oldest then oldest, oldN = e.u or 0, m end
    end
    if count > KEEP and oldN then k.mons[oldN] = nil end
end
local function fromKept(n)
    local k = kept()
    local e = k and k.mons[n]
    if not (e and type(e.d) == "string" and #e.d == 1024 and type(k.pals) == "string" and #k.pals == 384) then return nil end
    k.n = (k.n or 0) + 1
    e.u = k.n
    local pal = {}
    local base = (e.p or 0) * 64
    for c = 0, 15 do pal[c] = tonumber(k.pals:sub(base + c * 4 + 1, base + c * 4 + 4), 16) or 0 end
    return (e.d:gsub("..", UNHEX)), pal
end

-- 512 bytes of tiled 4-bit dots and a palette -> rectangles
local function rects(raw, pal)
    local px = {}
    for t = 0, 15 do
        local tx, ty = t % 4, floor(t / 4)
        for y = 0, 7 do
            for x = 0, 3 do
                local b = byte(raw, t * 32 + y * 4 + x + 1) or 0
                local at = (ty * 8 + y) * 32 + tx * 8 + x * 2
                px[at], px[at + 1] = b % 16, floor(b / 16)
            end
        end
    end
    local out, open = {}, {}
    for y = 0, 31 do
        local now, x = {}, 0
        while x < 32 do
            local c = px[y * 32 + x]
            if c == 0 then x = x + 1
            else
                local s = x
                while x < 32 and px[y * 32 + x] == c do x = x + 1 end
                local key = s * 4096 + x * 32 + c
                local r = open[key]
                if r then r[4] = r[4] + 1
                else
                    local v = pal[c] or 0
                    r = { s, y, x - s, 1, (v % 32) / 31, (floor(v / 32) % 32) / 31, (floor(v / 1024) % 32) / 31 }
                    out[#out + 1] = r
                end
                now[key] = r
            end
        end
        open = now
    end
    return { rects = out }
end

local memo = {}
function Icons.Get(n)
    if type(n) ~= "number" or n < 0 or n > 386 then return nil end
    if memo[n] then return memo[n] end
    local raw, pal
    local rom, loc, nat = source()
    if rom then
        local internal
        if n == 0 then internal = EGG
        else for i, v in pairs(nat) do if v == n then internal = i break end end end
        if internal and internal < COUNT then
            local ptr = u32(loc.tab, internal * 4) - 0x08000000
            raw = romBytes(rom, ptr, 512)
            local p = byte(loc.idx, internal + 1)
            pal = loc.pals[p]
            if raw then pcall(keep, n, raw, p, loc.pals) end
        end
    end
    if not raw then raw, pal = fromKept(n) end
    if not (raw and pal) then return nil end
    memo[n] = rects(raw, pal)
    return memo[n]
end
-- a species' name from a Gen 3 cartridge in memory (for a card shown before any save of yours taught Dex the names)
function Icons.Name(n)
    local rom = source()
    local t = rom and R.Tables(rom)
    return t and t.names and t.names[n] or nil
end
function Icons.Forget() memo = {} end         -- (for tests)
