-- Reading a Pokemon game's own save (the battery save MekkaBoy keeps for each cartridge) for the Pokedex and the team
-- card (Dex.lua). Nothing here changes a save or a game; nothing here is shown or sent.
--
-- Supported (English): Red, Blue, Yellow (Gen 1); Gold, Silver, Crystal 1.0/1.1 (Gen 2); Ruby and Sapphire 1.0-1.2,
-- Emerald, FireRed 1.0/1.1, LeafGreen 1.0/1.1 (Gen 3): the games MekkaBoy links (GBA/Trade3.lua, GBA/Ghosts.lua).
--
-- R.Read(save, how) -> record or nil, why
--   save: what MekkaBoy keeps, MB.DB().gb[id] ({ ram = { hex per 8K bank }, title }) or MB.DB().gba[id]
--         ({ kind = "flash128", sectors = { hex per 4K sector } })
--   how:  { system = "gb" | "gba", rom = the cartridge's ROM if it is in memory (MB.Carts.Peek), code = the Advance
--         game's four-letter code if known, title = a Game Boy game's header title if known, nat = the conversion
--         table to use (default: R.Tables(rom).nat; false: none, leave the species pending) }
--   record = { gen, game ("red" ... "leafgreen"), code, trainer, tid, badges = { count, mask, list },
--              party = { { species, level, nick, egg, raw } ... }, boxes = { national numbers ... } (eggs left out),
--              caught = { [national] = true }, seen = { ... }, record = { wins, losses, draws } (Gen 2 and 3),
--              pending = true when species could not be turned into national numbers yet (Gen 1 and 3 need the game's
--              own conversion table from its ROM; then party[i].raw and rawBoxes hold the game's internal numbers) }
--   A save whose checksums do not add up, or that is empty, gives nil: never a guess.
--
-- R.Tables(rom) -> { family, nat = { [internal] = national } or nil (Gen 2: they are the same), names = { [national] =
--   name } } or nil. Read from the player's own ROM, never shipped:
--   Gen 3: found by scanning the ROM. The species-to-National-Dex table is the run of 16-bit numbers 1, 2, ... 251
--          (the game's first 251 species are in National order), 411 entries; the names table is 412 entries of 11
--          bytes whose first is ten '?' and a terminator, every entry a name in the game's letters. Both checked whole.
--          (Found once per cartridge; the same in every revision tried: Ruby 1.0, Sapphire 1.2, Emerald, FireRed 1.0,
--          LeafGreen 1.1.)
--   Gen 1/2: at the address the pret decompilations' symbol files give for that title (dev/pokered.sym,
--          pokeyellow.sym, pokegold.sym, pokesilver.sym, pokecrystal.sym), used only if what is there has the shape
--          of the table (the dex-order table: 190 bytes holding each of 1-151 once; names: 10 bytes each, letters then
--          padding).
local _, MB = ...
local R = {}
MB.DexRead = R

local floor, byte, char, concat, sub = math.floor, string.byte, string.char, table.concat, string.sub

-- ------------------------------------------------------------------ plumbing ---
local HEX2 = {}
for i = 0, 255 do
    local c = char(i)
    HEX2[("%02x"):format(i)] = c
    HEX2[("%02X"):format(i)] = c
end
-- a hex string (as saves are kept) to raw bytes; n = the length it must have (blank or wrong: all 0xFF)
local function unhex(h, n)
    if type(h) ~= "string" or #h ~= n * 2 then return string.rep("\255", n) end
    local b = h:gsub("..", HEX2)
    if #b ~= n then return string.rep("\255", n) end
    return b
end
R.unhex = unhex

local function u16(s, o) local a, b = byte(s, o + 1, o + 2) return a + b * 256 end                      -- o: 0-based
local function u32(s, o) local a, b, c, d = byte(s, o + 1, o + 4) return a + b * 256 + c * 65536 + d * 16777216 end
local function be16(s, o) local a, b = byte(s, o + 1, o + 2) return a * 256 + b end
local function u8(s, o) return byte(s, o + 1) end

local bxor
do
    if MB.GBA and MB.GBA.bxor then bxor = MB.GBA.bxor
    elseif bit and bit.bxor then local x = bit.bxor bxor = function(p, q) return x(p, q) % 4294967296 end
    else
        local X = {}
        for p = 0, 15 do for q = 0, 15 do
            local r, m, pp, qq = 0, 1, p, q
            for _ = 1, 4 do local a, b = pp % 2, qq % 2 if a ~= b then r = r + m end pp, qq, m = (pp - a) / 2, (qq - b) / 2, m * 2 end
            X[p * 16 + q] = r
        end end
        bxor = function(p, q)
            local r, m = 0, 1
            for _ = 1, 8 do local a, b = p % 16, q % 16 r = r + X[a * 16 + b] * m p, q, m = (p - a) / 16, (q - b) / 16, m * 16 end
            return r
        end
    end
end

-- flags in a bit array (bit 0 of the first byte is number 1): { [n] = true }
local function bitset(s, o, count)
    local t = {}
    for n = 1, count do
        local v = byte(s, o + 1 + floor((n - 1) / 8))
        if v and floor(v / 2 ^ ((n - 1) % 8)) % 2 == 1 then t[n] = true end
    end
    return t
end
local function badgeList(mask, n)
    local list, count = {}, 0
    for i = 1, n do if floor(mask / 2 ^ (i - 1)) % 2 == 1 then count = count + 1 list[#list + 1] = i end end
    return { count = count, mask = mask, list = list }
end

-- ------------------------------------------------------------------- letters ---
-- The games' own letters (English versions), written down from the public documentation of the character sets.
local G12 = {}
for i = 0, 25 do G12[0x80 + i] = char(65 + i) G12[0xA0 + i] = char(97 + i) end
for i = 0, 9 do G12[0xF6 + i] = char(48 + i) end
G12[0x7F] = " " G12[0x9A] = "(" G12[0x9B] = ")" G12[0x9C] = ":" G12[0x9D] = ";" G12[0x9E] = "[" G12[0x9F] = "]"
G12[0xBA] = "\195\169" G12[0xE0] = "'" G12[0xE3] = "-" G12[0xE6] = "?" G12[0xE7] = "!" G12[0xE8] = "."
G12[0xEF] = "\226\153\130" G12[0xF5] = "\226\153\128" G12[0xF4] = "," G12[0xF3] = "/" G12[0xF1] = "x"
local G3 = {}
for i = 0, 25 do G3[0xBB + i] = char(65 + i) G3[0xD5 + i] = char(97 + i) end
for i = 0, 9 do G3[0xA1 + i] = char(48 + i) end
G3[0x00] = " " G3[0xAB] = "!" G3[0xAC] = "?" G3[0xAD] = "." G3[0xAE] = "-" G3[0xB0] = "..." G3[0xB1] = "\"" G3[0xB2] = "\""
G3[0xB3] = "'" G3[0xB4] = "'" G3[0xB5] = "\226\153\130" G3[0xB6] = "\226\153\128" G3[0xB8] = "," G3[0xBA] = "/" G3[0x1B] = "\195\169"
G3[0xF0] = ":"
local function text(s, o, n, set, stop)
    local t = {}
    for i = 0, n - 1 do
        local c = byte(s, o + 1 + i)
        if not c or c == stop then break end
        t[#t + 1] = set[c] or "?"
    end
    return (concat(t):gsub("%s+$", ""))
end
R.text1, R.text3 = function(s, o, n) return text(s, o, n, G12, 0x50) end, function(s, o, n) return text(s, o, n, G3, 0xFF) end

-- --------------------------------------------------------------- ROM tables ---
local function romBytes(rom, at, n)            -- n bytes of a ROM at file offset `at` (banks of 16K), or nil
    local banks = rom and rom.banks
    if type(banks) ~= "table" then return nil end
    local out, got = {}, 0
    while got < n do
        local b = banks[floor((at + got) / 16384) + 1]
        if type(b) ~= "string" then return nil end
        local off = (at + got) % 16384
        local piece = sub(b, off + 1, off + (n - got))
        if piece == "" then return nil end
        out[#out + 1] = piece
        got = got + #piece
    end
    return concat(out)
end
-- find a byte string anywhere in the ROM (it may run across two banks); file offsets of every place, at most `max`
local function romFind(rom, needle, max)
    local banks, hits, n = rom.banks, {}, #needle
    for i = 1, rom.numBanks or #banks do
        local b = banks[i]
        if type(b) ~= "string" then break end
        local nxt = banks[i + 1]
        local hay = (type(nxt) == "string") and (b .. sub(nxt, 1, n - 1)) or b
        local from = 1
        while true do
            local p = hay:find(needle, from, true)
            if not p or p > #b then break end
            hits[#hits + 1] = (i - 1) * 16384 + p - 1
            if #hits >= (max or 4) then return hits end
            from = p + 1
        end
    end
    return hits
end

local GB_TABLES = {      -- by header title (and the family it belongs to): file offsets (bank * 0x4000 + address - 0x4000)
    ["POKEMON RED"] = { family = "RB", order = 0x41024, names = 0x1C21E, count = 190 },
    ["POKEMON BLUE"] = { family = "RB", order = 0x41024, names = 0x1C21E, count = 190 },
    ["POKEMON YELLOW"] = { family = "Y", order = 0x410B1, names = 0xE8000, count = 190 },
    ["POKEMON_GLD"] = { family = "GS", names = 0x1B0B74, count = 251 },
    ["POKEMON_SLV"] = { family = "GS", names = 0x1B0B74, count = 251 },
    ["PM_CRYSTAL"] = { family = "C", names = 0x53384, count = 251 },
}
local function gbTitle(s) return (s or ""):gsub("%z.*", ""):gsub("[^%w _]", ""):gsub("%s+$", "") end
local function gameOfTitle(t)
    t = gbTitle(t)
    if t == "POKEMON RED" then return "red", 1 elseif t == "POKEMON BLUE" then return "blue", 1
    elseif t == "POKEMON YELLOW" then return "yellow", 1 end
    if t:sub(1, 11) == "POKEMON_GLD" then return "gold", 2, "POKEMON_GLD" end
    if t:sub(1, 11) == "POKEMON_SLV" then return "silver", 2, "POKEMON_SLV" end
    if t:sub(1, 10) == "PM_CRYSTAL" then return "crystal", 2, "PM_CRYSTAL" end
    return nil
end
R.GameOfTitle = gameOfTitle
local function nameShaped(e, letters, pad)       -- a 10-byte Game Boy name: letters, then padding
    local stopAt = e:find(char(pad), 1, true)
    local body = stopAt and e:sub(1, stopAt - 1) or e
    if #body == 0 then return false end
    if stopAt and e:sub(stopAt):gsub(char(pad), "") ~= "" then return false end
    for i = 1, #body do if not letters[byte(body, i)] then return false end end
    return true
end
local function gbTables(rom)
    local title = gbTitle(romBytes(rom, 0x134, 16))
    local _, gen, key = gameOfTitle(title)
    local p = GB_TABLES[key or title]
    if not p then return nil end
    local out = { family = p.family, gen = gen }
    if p.order then
        local o = romBytes(rom, p.order, p.count)
        if not o then return nil end
        local seen, nat, hits = {}, {}, 0
        for i = 1, p.count do
            local v = byte(o, i)
            if v > 151 then return nil end
            if v > 0 then
                if seen[v] then return nil end
                seen[v], hits, nat[i] = true, hits + 1, v
            end
        end
        if hits ~= 151 then return nil end
        out.nat = nat
    end
    local n = romBytes(rom, p.names, p.count * 10)
    if not n then return out end
    local names, by = {}, out.nat
    for i = 1, p.count do
        local e = n:sub(i * 10 - 9, i * 10)
        if not nameShaped(e, G12, 0x50) then return out end      -- (not the shape of the table: no names)
        local num = by and by[i] or (not by and i) or nil
        if num then names[num] = text(e, 0, 10, G12, 0x50) end
    end
    out.names = names
    return out
end

local NAT_LEN = 411
local function gen3Tables(rom)
    local t = {}
    for i = 1, 251 do t[i] = char(i % 256, floor(i / 256)) end
    local hits = romFind(rom, concat(t), 2)
    if #hits ~= 1 then return nil end
    local raw = romBytes(rom, hits[1], NAT_LEN * 2)
    if not raw then return nil end
    local nat, have = {}, {}
    for i = 1, NAT_LEN do
        local v = u16(raw, (i - 1) * 2)
        if v >= 1 and v <= 386 then
            if have[v] then return nil end
            have[v] = true
            nat[i] = v
        end
    end
    for v = 1, 386 do if not have[v] then return nil end end
    local out = { family = "3", gen = 3, nat = nat }
    local first = string.rep("\172", 10) .. "\255"
    local nh = romFind(rom, first, 4)
    for _, at in ipairs(nh) do
        local blob = romBytes(rom, at, (NAT_LEN + 1) * 11)
        local names, good = {}, blob ~= nil
        for i = 1, NAT_LEN do
            if not good then break end
            local e = blob:sub(i * 11 + 1, i * 11 + 11)
            local stop = e:find("\255", 1, true)
            if not stop or stop == 1 then good = false break end
            for k = 1, stop - 1 do if not G3[byte(e, k)] then good = false break end end
            if good and nat[i] then names[nat[i]] = text(e, 0, 11, G3, 0xFF) end
        end
        if good then out.names = names break end
    end
    return out
end

local cache = setmetatable({}, { __mode = "k" })
function R.Tables(rom)
    if type(rom) ~= "table" or type(rom.banks) ~= "table" then return nil end
    if cache[rom] ~= nil then return cache[rom] or nil end
    local ok, t
    if rom.system == "gba" then ok, t = pcall(gen3Tables, rom) else ok, t = pcall(gbTables, rom) end
    t = ok and t or nil
    cache[rom] = t or false
    return t
end
-- which Advance game a ROM is: its code and revision (from the header)
function R.RomCode(rom)
    local h = romBytes(rom, 0xAC, 0x11)
    if not h then return nil end
    return h:sub(1, 4), byte(h, 0x11)
end
function R.RomTitle(rom) return gbTitle(romBytes(rom, 0x134, 16)) end

-- ------------------------------------------------------------------- Gen 1 ---
-- Offsets in the 32K save RAM (bank * 0x2000 + address - 0xA000), from the public save format; the same in Red, Blue
-- and Yellow (English).
local G1 = { name = 0x2598, owned = 0x25A3, seen = 0x25B6, badges = 0x2602, box = 0x284C, tid = 0x2605,
             party = 0x2F2C, cur = 0x30C0, sumFrom = 0x2598, sumTo = 0x3522, sum = 0x3523, boxSize = 0x462 }
local function ramBytes(save)
    local t = {}
    for i = 1, 4 do t[i] = unhex(save.ram and save.ram[i], 8192) end
    return concat(t)
end
local function g1List(s, o, cap, size, levelAt)       -- a party or box: count, species list, then the records
    local n = u8(s, o)
    if n > cap then return nil end
    if n < cap and u8(s, o + 1 + n) ~= 0xFF then return nil end
    local list = {}
    local recs = o + 2 + cap
    for i = 1, n do
        local sp = u8(s, o + i)
        if sp == 0 or sp == 0xFF then return nil end
        list[i] = { raw = sp, level = levelAt and u8(s, recs + (i - 1) * size + levelAt) or nil }
    end
    return list, n
end
local function read1(s, game)
    local sum = 0
    for i = G1.sumFrom + 1, G1.sumTo + 1 do sum = sum + byte(s, i) end
    if (255 - sum % 256) ~= u8(s, G1.sum) then return nil, "checksum" end
    local party, n = g1List(s, G1.party, 6, 44, 0x21)
    if not party then return nil, "party" end
    -- (no Pokemon yet: still a row, with the trainer and badges)
    local nicks = G1.party + 2 + 6 + 6 * 44 + 6 * 11
    for i = 1, n do party[i].nick = text(s, nicks + (i - 1) * 11, 11, G12, 0x50) end
    local rec = { gen = 1, game = game, trainer = text(s, G1.name, 11, G12, 0x50), tid = be16(s, G1.tid),
                  badges = badgeList(u8(s, G1.badges), 8), party = party,
                  caught = bitset(s, G1.owned, 151), seen = bitset(s, G1.seen, 151) }
    -- boxes: the one in use is kept with the game (the copy in its bank is stale); the others in banks 2 and 3, once
    -- the player has changed boxes at least once (top bit of the box number)
    local raw = {}
    local cur = u8(s, G1.box)
    local function add(list) for _, e in ipairs(list or {}) do raw[#raw + 1] = e.raw end end
    add((g1List(s, G1.cur, 20, 33, nil)))
    if cur >= 128 then
        for bank = 2, 3 do
            local base = bank * 0x2000
            local sumb = 0
            for i = base + 1, base + 6 * G1.boxSize do sumb = sumb + byte(s, i) end
            if (255 - sumb % 256) == u8(s, base + 6 * G1.boxSize) then
                for b = 0, 5 do
                    if (bank - 2) * 6 + b ~= cur % 128 then add((g1List(s, base + b * G1.boxSize, 20, 33, nil))) end
                end
            end
        end
    end
    rec.rawBoxes = raw
    return rec
end

-- ------------------------------------------------------------------- Gen 2 ---
local G2 = {
    GS = { name = 0x200B, tid = 0x2009, johto = 0x23E4, curBox = 0x2724, party = 0x288A, owned = 0x2A4C, seen = 0x2A6C,
           sumFrom = 0x2009, sumTo = 0x2D68, sum = 0x2D69, check2 = 0x2D6B, cur = 0x2D6C, battle = 0x31BA },
    C = { name = 0x200B, tid = 0x2009, johto = 0x23E5, curBox = 0x2700, party = 0x2865, owned = 0x2A27, seen = 0x2A47,
          sumFrom = 0x2009, sumTo = 0x2B82, sum = 0x2D0D, check2 = 0x2D0F, cur = 0x2D10, battle = 0x3260, backup = -0xE00,
          backupSum = 0x1F0D, backupCheck2 = 0x1F0F },
}
local function g2Good(s, L, delta, sumAt, check2At)
    if u8(s, 0x2008 + delta) ~= 0x63 or u8(s, check2At) ~= 0x7F then return false end
    local sum = 0
    for i = L.sumFrom + delta + 1, L.sumTo + delta + 1 do sum = sum + byte(s, i) end
    return sum % 65536 == u16(s, sumAt)
end
local function g2List(s, o, cap, size, levelAt)
    local n = u8(s, o)
    if n > cap then return nil end
    if u8(s, o + 1 + n) ~= 0xFF then return nil end
    local list = {}
    for i = 1, n do
        local sp = u8(s, o + i)
        if sp == 0 or (sp > 251 and sp ~= 0xFD) then return nil end
        local recSp = u8(s, o + 2 + cap + (i - 1) * size)
        list[i] = { species = (sp ~= 0xFD) and sp or 0, egg = sp == 0xFD or nil,
                    level = levelAt and u8(s, o + 2 + cap + (i - 1) * size + levelAt) or nil, recSp = recSp }
    end
    return list, n
end
local function read2(s, game, fam)
    local L = G2[fam]
    local d = 0
    if not g2Good(s, L, 0, L.sum, L.check2) then
        if L.backup and g2Good(s, L, L.backup, L.backupSum, L.backupCheck2) then d = L.backup
        else return nil, "checksum" end
    end
    local party, n = g2List(s, L.party + d, 6, 48, 0x1F)
    if not party then return nil, "party" end
    -- (no Pokemon yet: still a row, with the trainer and badges)
    local nicks = L.party + d + 8 + 6 * 48 + 6 * 11
    for i = 1, n do party[i].nick = not party[i].egg and text(s, nicks + (i - 1) * 11, 11, G12, 0x50) or nil end
    local johto, kanto = u8(s, L.johto + d), u8(s, L.johto + d + 1)
    local rec = { gen = 2, game = game, trainer = text(s, L.name + d, 11, G12, 0x50), tid = be16(s, L.tid + d),
                  badges = badgeList(johto + kanto * 256, 16), party = party,
                  caught = bitset(s, L.owned + d, 251), seen = bitset(s, L.seen + d, 251) }
    local w, l, dr = be16(s, L.battle), be16(s, L.battle + 2), be16(s, L.battle + 4)
    if w <= 9999 and l <= 9999 and dr <= 9999 then rec.record = { wins = w, losses = l, draws = dr } end
    local boxes, cur = {}, u8(s, L.curBox + d)
    local function add(list) for _, e in ipairs(list or {}) do if not e.egg then boxes[#boxes + 1] = e.species end end end
    add((g2List(s, L.cur, 20, 32, nil)))
    for b = 0, 13 do
        if b ~= cur then
            local base = (b < 7) and (0x4000 + b * 0x450) or (0x6000 + (b - 7) * 0x450)
            add((g2List(s, base, 20, 32, nil)))
        end
    end
    rec.boxes = boxes
    return rec
end

-- ------------------------------------------------------------------- Gen 3 ---
-- 128K flash: two copies of the game of 14 sectors each (the newer valid one counts), each sector 4K with its number,
-- checksum, a signature and a save counter at its end. Offsets within the game's blocks, by family:
--   R = Ruby/Sapphire, E = Emerald, K = FireRed/LeafGreen.
local G3L = {
    R = { party = 0x234, flags = 0x1220, badge = 0x807, battle = 0x30B8, battleIn = 1 },
    E = { party = 0x234, flags = 0x1270, badge = 0x867, battle = 0x3150, battleIn = 1 },
    K = { party = 0x034, flags = 0x0EE0, badge = 0x820, battle = 0x0A98, battleIn = 2 },
}
local FAMILY3 = { AXVE = "R", AXPE = "R", BPEE = "E", BPRE = "K", BPGE = "K" }
local GAME3 = { AXVE = "ruby", AXPE = "sapphire", BPEE = "emerald", BPRE = "firered", BPGE = "leafgreen" }
R.FAMILY3, R.GAME3 = FAMILY3, GAME3
local SECTOR_DATA = 3968
local SIG = 0x08012025
local function sectorGood(sec)
    if u32(sec, 0xFF8) ~= SIG then return false end
    local sum = 0
    for o = 0, SECTOR_DATA - 4, 4 do sum = sum + u32(sec, o) end
    sum = sum % 4294967296
    return (floor(sum / 65536) + sum) % 65536 == u16(sec, 0xFF6)
end
local function pickSlot(save)
    local best, bestCount
    for slot = 0, 1 do
        local byId, good = {}, true
        local count
        for i = 0, 13 do
            local text8 = save.sectors[slot * 14 + i + 1]
            if type(text8) ~= "string" or #text8 ~= 8192 then good = false break end
            local sec = unhex(text8, 4096)
            if not sectorGood(sec) then good = false break end
            local id = u16(sec, 0xFF4)
            if id > 13 or byId[id] then good = false break end
            byId[id] = sec
            count = u32(sec, 0xFFC)
        end
        if good then
            -- the newer one (a counter that wrapped round past the other counts as newer)
            if not best or (count > bestCount and not (count == 4294967295 and bestCount == 0)) or (count == 0 and bestCount == 4294967295) then
                best, bestCount = byId, count
            end
        end
    end
    return best, bestCount
end
-- the 24 orders the four parts of a Pokemon's record come in (personality % 24): every arrangement of
-- growth, attacks, condition, misc, in order
local ORDERS = {}
do
    local function perm(prefix, rest)
        if #rest == 0 then ORDERS[#ORDERS + 1] = prefix return end
        for i = 1, #rest do
            local p, r = { unpack(prefix) }, { unpack(rest) }
            p[#p + 1] = table.remove(r, i)
            perm(p, r)
        end
    end
    perm({}, { "G", "A", "E", "M" })
end
-- one 80-byte record (box form): species (the game's internal number), egg, nickname; nil if empty or damaged
local function mon3(s, o)
    local pid, ot = u32(s, o), u32(s, o + 4)
    local flags = u8(s, o + 19)
    if flags % 2 == 1 then return nil end                     -- a bad egg
    if pid == 0 and ot == 0 and flags == 0 then return nil end
    local key = bxor(pid, ot)
    local w, sum = {}, 0
    for i = 0, 11 do
        local v = bxor(u32(s, o + 32 + i * 4), key)
        w[i] = v
        sum = sum + v % 65536 + floor(v / 65536)
    end
    if sum % 65536 ~= u16(s, o + 28) then return nil end
    local order = ORDERS[pid % 24 + 1]
    local at = {}
    for i, k in ipairs(order) do at[k] = (i - 1) * 3 end
    local species = w[at.G] % 65536
    if species == 0 then return nil end
    local egg = floor(w[at.M + 1] / 1073741824) % 2 == 1 or floor(flags / 4) % 2 == 1
    return { raw = species, egg = egg or nil, nick = not egg and text(s, o + 8, 10, G3, 0xFF) or nil }
end
local function read3(save, code)
    if type(save) ~= "table" or type(save.sectors) ~= "table" then return nil, "no save" end
    local sec = pickSlot(save)
    if not sec then return nil, "checksum" end
    local sb2 = sec[0]
    local sb1 = concat({ sec[1]:sub(1, SECTOR_DATA), sec[2]:sub(1, SECTOR_DATA), sec[3]:sub(1, SECTOR_DATA), sec[4]:sub(1, SECTOR_DATA) })
    local fam = code and FAMILY3[code]
    if not fam then
        -- not told which game: the save's own word for it (0 Ruby/Sapphire, 1 FireRed/LeafGreen, else Emerald)
        local g = u32(sb2, 0xAC)
        fam = (g == 0 and "R") or (g == 1 and "K") or "E"
    end
    local L = G3L[fam]
    local n = u8(sb1, L.party)
    if n > 6 then return nil, "party" end
    -- (no Pokemon yet: still a row, with the trainer and badges)
    local party = {}
    for i = 1, n do
        local o = L.party + 4 + (i - 1) * 100
        local m = mon3(sb1, o)
        if not m then return nil, "party" end
        m.level = u8(sb1, o + 84)
        party[i] = m
    end
    local mask = 0
    for i = 0, 7 do
        local f = L.badge + i
        local v = u8(sb1, L.flags + floor(f / 8))
        if floor(v / 2 ^ (f % 8)) % 2 == 1 then mask = mask + 2 ^ i end
    end
    local rec = { gen = 3, game = code and GAME3[code] or nil, code = code, family = fam,
                  trainer = text(sb2, 0, 8, G3, 0xFF), tid = u16(sb2, 0x0A), badges = badgeList(mask, 8), party = party,
                  caught = bitset(sb2, 0x28, 386), seen = bitset(sb2, 0x5C, 386) }
    local blk = (L.battleIn == 2) and sb2 or sb1
    local w, l, d = 0, 0, 0
    for i = 0, 4 do
        local o = L.battle + i * 16 + 8
        w, l, d = w + u16(blk, o + 2), l + u16(blk, o + 4), d + u16(blk, o + 6)
    end
    rec.record = { wins = w, losses = l, draws = d }
    -- the PC: 14 boxes of 30 after a 4-byte box number, spread over sectors 5-13
    local parts = {}
    for i = 5, 13 do parts[#parts + 1] = sec[i]:sub(1, SECTOR_DATA) end
    local st = concat(parts)
    local raw = {}
    for b = 0, 14 * 30 - 1 do
        local m = mon3(st, 4 + b * 80)
        if m and not m.egg then raw[#raw + 1] = m.raw end
    end
    rec.rawBoxes = raw
    return rec
end

-- -------------------------------------------------------------- the reader ---
-- turn internal species numbers into National Dex numbers with the game's own table (nat); without one, pending
function R.Resolve(rec, nat)
    if rec.gen == 2 then return rec end
    if not nat then rec.pending = true return rec end
    for _, m in ipairs(rec.party) do m.species = (not m.egg and nat[m.raw]) or 0 end
    local boxes = {}
    for _, r in ipairs(rec.rawBoxes or {}) do local v = nat[r] if v then boxes[#boxes + 1] = v end end
    rec.boxes, rec.pending = boxes, nil
    return rec
end

function R.Read(save, how)
    how = how or {}
    if type(save) ~= "table" then return nil, "no save" end
    local ok, rec, why
    if how.system == "gba" or save.sectors then
        local code = how.code
        if how.rom then code = R.RomCode(how.rom) end
        if code and not FAMILY3[code] then return nil, "not a supported game" end
        ok, rec, why = pcall(read3, save, code)
    else
        if type(save.ram) ~= "table" then return nil, "no save" end
        local title = how.rom and R.RomTitle(how.rom) or how.title or save.title
        local game, gen, key = gameOfTitle(title)
        if not game then return nil, "not a supported game" end
        local s = ramBytes(save)
        if gen == 1 then ok, rec, why = pcall(read1, s, game)
        else ok, rec, why = pcall(read2, s, game, key == "PM_CRYSTAL" and "C" or "GS") end
    end
    if not ok then return nil, "unreadable (" .. tostring(rec) .. ")" end
    if not rec then return nil, why end
    local nat = how.nat
    if nat == nil and how.rom and rec.gen ~= 2 then local t = R.Tables(how.rom) nat = t and t.nat end
    return R.Resolve(rec, nat or nil), nil
end
