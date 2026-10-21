-- The Pokedex and the team card: the data behind them (no window yet).
--
-- Every Pokemon game the player has a save for on MekkaBoy counts (Gen 1, 2 and 3, each version and revision its own
-- save; a game's save belongs to the WoW account, so every character shares it). Only the player's own saves count:
-- the practice saves (/mb testsave, GB/TestSaves.lua) are never read here, and while they are on the Pokedex and the
-- card keep showing what was kept from the player's own.
--
-- What is kept (MekkaBoyDB.dex), so that the Pokedex works without starting every game:
--   saves[key]  one row per save (key: where MekkaBoy keeps that game's save, the cartridge's id): game, trainer,
--               badges, the game's own Pokedex caught/seen flags and the species the save holds right now (party and
--               PC boxes), as bit sets over National Dex #1-386; the party (species, level, nickname); the link
--               battle record. rev = which keeping of the save it was read from (MB.BatteryRev).
--   tables[f]   the game's own internal-number-to-National-Dex table, per family ("3" for Gen 3; "RB", "Y" for
--               Gen 1), read from the player's ROM the first time that cartridge is in memory
--   names       species names by National Dex number, read from the player's ROM (the newest generation seen)
--   carts[key]  which game a cartridge is (code and revision of an Advance game, the title of a Game Boy one)
-- A save is read again whenever its game keeps it (MB.BatteryKept, wrapped below) and at login for any save that has
-- no row yet or changed since. A Gen 1 or Gen 3 save read before its ROM was ever in memory knows everything but which
-- species it holds: that row is `pending` until the table is learned (Dex.Scan({ load = true }) reads the
-- cartridges for it).
--
-- API
--   Dex.Refresh(key)          read that save again now; returns the row (or nil, why)
--   Dex.Scan(opts)            every own save with no row or a stale one; opts.load = true also loads the cartridges of
--                             saves still pending (a cartridge stays in memory once read: Gen 3 ones are 16 MB)
--   Dex.Pokedex()             { caught = { [n] = true }, living = { [n] = true }, caughtCount, livingCount,
--                               regions = { { id, name, from, to, caught, living }, ... } (Kanto 1-151, Johto
--                               152-251, Hoenn 252-386), saves = { { key, game, gen, name, trainer, badges,
--                               badgeTotal, caught, living, pending }, ... }, pending (saves without species yet) }
--   Dex.Card()                the team card from the game being played now, else the one played most recently:
--                             { key, game, gen, name, trainer, badges, badgeMask, badgeTotal, caught,
--                               party = { { species, level, nick, egg }, ... }, record = { wins, losses, draws } or
--                               nil (Gen 1 keeps none) } or nil
--   Dex.Name(n)               a species' name (from the player's ROM), or nil
--   Dex.MayShow(name, channel) whether How I play lets that player see your card and Pokedex (open: anyone; friends:
--                             group, friends list, guild, past link partners (Friends.Known); solo: nobody)
--   Dex.EncodeCard(card) / Dex.DecodeCard(text)      one addon message (<= 255 bytes; nicknames are dropped first
--                                                    when it would not fit)
--   Dex.EncodeDex(dex) / Dex.DecodeDex(text)         the Pokedex (two bit sets and the per-save rows)
--   Dex.Split(text, size) / Dex.Join(parts)          cut a long text into addon messages and put it back together
-- Message formats (version byte after the kind; everything printable, no "|" and no zero bytes):
--   card:    C1;<game>;<trainer>;<badges:3>;<caught:2>;<wins>.<losses>.<draws>;<party: 3 per Pokemon>;<nick,nick,...>
--   pokedex: D1;<caught:65><living:65>;<row>,<row>,...   row = <game><badges:3><caught:2><living:2><trainer>
--   numbers and bit sets are in 6-bit letters (A-Z a-z 0-9 + /), most significant first; a Pokemon is
--   species + 512 * level + 65536 * egg; game letters: r b y (Red Blue Yellow), g s c (Gold Silver Crystal),
--   R S E F L (Ruby Sapphire Emerald FireRed LeafGreen), 1 2 3 (a game of that generation not told apart)
--   split part: <index:1><count:1><piece>   (index 0-based, both 6-bit letters)
local _, MB = ...
local Dex = {}
MB.Dex = Dex
local R = MB.DexRead
local floor, concat, char, byte = math.floor, table.concat, string.char, string.byte

local MAXDEX = 386
Dex.MAX = MAXDEX
Dex.REGIONS = { { id = "kanto", name = "Kanto", from = 1, to = 151 }, { id = "johto", name = "Johto", from = 152, to = 251 },
                { id = "hoenn", name = "Hoenn", from = 252, to = 386 } }
local BADGE_TOTAL = { 8, 16, 8 }
local GAME_NAME = { red = "Pokemon Red", blue = "Pokemon Blue", yellow = "Pokemon Yellow", gold = "Pokemon Gold",
                    silver = "Pokemon Silver", crystal = "Pokemon Crystal", ruby = "Pokemon Ruby", sapphire = "Pokemon Sapphire",
                    emerald = "Pokemon Emerald", firered = "Pokemon FireRed", leafgreen = "Pokemon LeafGreen" }
local GAME_LETTER = { red = "r", blue = "b", yellow = "y", gold = "g", silver = "s", crystal = "c", ruby = "R",
                      sapphire = "S", emerald = "E", firered = "F", leafgreen = "L" }
local LETTER_GAME = {}
for g, l in pairs(GAME_LETTER) do LETTER_GAME[l] = g end

local function store()
    local db = MB.DB()
    local d = db.dex
    if type(d) ~= "table" or d.v ~= 1 then d = { v = 1 } db.dex = d end
    d.saves, d.tables, d.carts = d.saves or {}, d.tables or {}, d.carts or {}
    return d
end
Dex.Store = store
-- the player's own saves, whatever practice mode is doing (MB.Saves() would hand over the practice set)
local function ownSave(key)
    local db = MB.DB()
    local s = db.gba and db.gba[key]
    if type(s) == "table" and s.sectors then return s, "gba" end
    s = db.gb and db.gb[key]
    if type(s) == "table" and s.ram then return s, "gb" end
    return nil
end
local function ownRev(key) local r = MB.DB().rev return r and r[key] or 0 end
local function now() return (time and time()) or 0 end

-- ------------------------------------------------------------- six-bit text ---
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VAL = {}
for i = 1, 64 do VAL[byte(B64, i)] = i - 1 end
local function num(v, width)
    local t = {}
    for i = width, 1, -1 do local d = v % 64 t[i] = B64:sub(d + 1, d + 1) v = floor(v / 64) end
    return concat(t)
end
local function unnum(s, from, width)
    local v = 0
    for i = from, from + width - 1 do
        local d = VAL[byte(s, i) or 0]
        if not d then return nil end
        v = v * 64 + d
    end
    return v
end
Dex.Num, Dex.Unnum = num, unnum
local SETLEN = 65                                  -- ceil(386 / 6)
local function packSet(set)
    local t = {}
    for c = 0, SETLEN - 1 do
        local v = 0
        for b = 0, 5 do
            local n = c * 6 + b + 1
            v = v * 2 + ((set and set[n]) and 1 or 0)
        end
        t[c + 1] = B64:sub(v + 1, v + 1)
    end
    return concat(t)
end
local function unpackSet(s, from)
    from = from or 1
    if type(s) ~= "string" or #s < from + SETLEN - 1 then return nil end
    local set = {}
    for c = 0, SETLEN - 1 do
        local v = VAL[byte(s, from + c)]
        if not v then return nil end
        for b = 5, 0, -1 do
            local n = c * 6 + b + 1
            if v % 2 == 1 and n <= MAXDEX then set[n] = true end
            v = floor(v / 2)
        end
    end
    return set
end
Dex.PackSet, Dex.UnpackSet = packSet, unpackSet
local function count(set, from, to)
    local n = 0
    for k in pairs(set or {}) do if k >= (from or 1) and k <= (to or MAXDEX) then n = n + 1 end end
    return n
end
Dex.Count = count

-- ---------------------------------------------------------- the ROM's tables ---
local function packTable(nat)
    local t, top = {}, 0
    for k in pairs(nat) do if k > top then top = k end end
    for i = 1, top do t[i] = num(nat[i] or 0, 2) end
    return concat(t)
end
local function unpackTable(s)
    if type(s) ~= "string" then return nil end
    local nat = {}
    for i = 1, floor(#s / 2) do
        local v = unnum(s, i * 2 - 1, 2)
        if v and v > 0 and v <= MAXDEX then nat[i] = v end
    end
    return nat
end
-- what the ROM in memory teaches: which game the cartridge is, its conversion table, its species names
local function learn(key, rom)
    if not (rom and rom.banks and rom.banks[1]) then return nil end
    local d = store()
    local gen, fam
    if rom.system == "gba" then
        local code, rev = R.RomCode(rom)
        if code then d.carts[key] = { code = code, rev = rev } end
        if not (code and R.FAMILY3[code]) then return nil end          -- (not one of these games: nothing to learn)
        gen, fam = 3, "3"
    else
        local title = R.RomTitle(rom)
        d.carts[key] = { title = title }
        local game
        game, gen = R.GameOfTitle(title)
        if not game then return nil end
        fam = (game == "yellow" and "Y") or (gen == 1 and "RB") or nil
    end
    -- known already: no need to look through the ROM again
    if (not fam or d.tables[fam]) and (d.namesGen or 0) >= gen then return { nat = fam and unpackTable(d.tables[fam]) or nil } end
    local t = R.Tables(rom)
    if not t then return nil end
    if t.nat and not d.tables[t.family] then d.tables[t.family] = packTable(t.nat) end
    if t.names then
        local have = d.namesGen or 0
        if t.gen > have then d.names, d.namesGen = t.names, t.gen end
    end
    return t
end
local function romFor(key)
    local rom = MB.Carts and MB.Carts.Peek and MB.Carts.Peek(key)
    if not (rom and rom.banks and rom.numBanks) then return nil end
    for i = 1, rom.numBanks do if type(rom.banks[i]) ~= "string" then return nil end end
    return rom
end

-- -------------------------------------------------------------------- rows ---
local function guessGame(key, gen, family)
    local c = MB.Carts and MB.Carts.Find and MB.Carts.Find(key)
    local n = c and c.name and c.name:lower() or ""
    if gen == 3 then
        for _, g in ipairs({ "ruby", "sapphire", "emerald", "firered", "leafgreen" }) do if n:find(g, 1, true) then return g end end
        return (family == "E" and "emerald") or nil
    end
    return nil
end
local function makeRow(key, system, rec, rev)
    local living
    if not rec.pending then
        living = {}
        for _, m in ipairs(rec.party) do if not m.egg and m.species and m.species > 0 then living[m.species] = true end end
        for _, s in ipairs(rec.boxes or {}) do if s > 0 and s <= MAXDEX then living[s] = true end end
    end
    local party = {}
    for i, m in ipairs(rec.party) do
        party[i] = { s = (not m.egg and m.species) or 0, l = m.level, n = m.nick, e = m.egg or nil, r = rec.pending and m.raw or nil }
    end
    local c = MB.Carts and MB.Carts.Find and MB.Carts.Find(key)
    local row = { key = key, system = system, gen = rec.gen, game = rec.game or guessGame(key, rec.gen, rec.family),
                  code = rec.code, name = c and c.name or nil, trainer = rec.trainer, tid = rec.tid,
                  badges = rec.badges.count, badgeMask = rec.badges.mask,
                  caught = packSet(rec.caught), seen = packSet(rec.seen), living = living and packSet(living) or nil,
                  party = party, record = rec.record and { rec.record.wins, rec.record.losses, rec.record.draws } or nil,
                  pending = rec.pending or nil, rev = rev, read = now() }
    row.name = row.name or GAME_NAME[row.game or ""]
    if rec.pending then row.rawBoxes = rec.rawBoxes end
    return row
end
-- a pending row whose table has since been learned: work out its species now
local function settle(row)
    if not row.pending then return end
    local fam = (row.gen == 3 and "3") or (row.gen == 1 and (row.game == "yellow" and "Y" or "RB")) or nil
    local nat = fam and unpackTable(store().tables[fam])
    if not nat then return end
    local living = {}
    for _, m in ipairs(row.party or {}) do
        if m.r and not m.e then m.s = nat[m.r] or 0 if m.s > 0 then living[m.s] = true end end
        m.r = nil
    end
    for _, r in ipairs(row.rawBoxes or {}) do local v = nat[r] if v then living[v] = true end end
    row.living, row.rawBoxes, row.pending = packSet(living), nil, nil
end

function Dex.Refresh(key, played)
    if type(key) ~= "string" then return nil, "no key" end
    local d = store()
    local save, system = ownSave(key)
    local rev = ownRev(key)
    if not save then d.saves[key] = nil return nil, "no save" end
    local rom = romFor(key)
    local t = rom and learn(key, rom) or nil
    local known = d.carts[key] or {}
    local c = MB.Carts and MB.Carts.Find and MB.Carts.Find(key)
    local how = { system = system, rom = rom, code = known.code or (c and c.code), title = known.title, nat = false }
    if not rom then
        -- the Gen 1 and Gen 3 conversion table, if an earlier cartridge taught it
        local fam
        if system == "gba" then fam = "3"
        else
            local g = R.GameOfTitle(known.title or save.title)
            fam = (g == "yellow" and "Y") or ((g == "red" or g == "blue") and "RB") or nil
        end
        how.nat = fam and unpackTable(d.tables[fam]) or false
    else
        how.nat = t and t.nat or false
    end
    local rec, why = R.Read(save, how)
    if not rec then
        d.saves[key] = { none = why or "unreadable", rev = rev, read = now() }
        return nil, why
    end
    local old = d.saves[key]
    local row = makeRow(key, system, rec, rev)
    row.played = played or (old and old.played) or nil
    if not row.played and type(save.at) == "string" and time then
        local y, mo, dd, h, mi = save.at:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+)")
        if y then
            local ok, v = pcall(time, { year = tonumber(y), month = tonumber(mo), day = tonumber(dd), hour = tonumber(h), min = tonumber(mi) })
            if ok then row.played = v end
        end
    end
    d.saves[key] = row
    return row
end

-- every row still waiting for a table it now has
local function settleAll() for _, row in pairs(store().saves) do if not row.none then settle(row) end end end

function Dex.Scan(opts)
    opts = opts or {}
    local d = store()
    local db = MB.DB()
    local keys = {}
    for k, v in pairs(db.gb or {}) do if type(v) == "table" then keys[k] = true end end
    for k, v in pairs(db.gba or {}) do if type(v) == "table" then keys[k] = true end end
    for k in pairs(d.saves) do if not keys[k] then d.saves[k] = nil end end        -- (a save that is gone)
    local done = 0
    for k in pairs(keys) do
        local row = d.saves[k]
        if not row or row.rev ~= ownRev(k) then Dex.Refresh(k) done = done + 1 end
    end
    settleAll()
    -- rows still waiting: a cartridge already in memory teaches its table; opts.load reads the cartridge for it
    for k, row in pairs(d.saves) do
        if row.pending then
            local rom = romFor(k)
            if not rom and opts.load and MB.Carts and MB.Carts.Load then rom = MB.Carts.Load(k) end
            if rom then learn(k, rom) settleAll() end
        end
    end
    return done
end

-- ------------------------------------------------------------- what it shows ---
function Dex.Name(n) local names = store().names return names and names[n] or nil end
local function rowOf(row)
    local caught = unpackSet(row.caught) or {}
    local living = row.living and unpackSet(row.living) or nil
    return caught, living
end
function Dex.Pokedex()
    local d = store()
    local caught, living, saves, pending = {}, {}, {}, 0
    for key, row in pairs(d.saves) do
        if not row.none then
            local c, l = rowOf(row)
            for n in pairs(c) do caught[n] = true end
            for n in pairs(l or {}) do living[n] = true end
            if row.pending then pending = pending + 1 end
            saves[#saves + 1] = { key = key, game = row.game, gen = row.gen, name = row.name, trainer = row.trainer,
                                  badges = row.badges, badgeMask = row.badgeMask, badgeTotal = BADGE_TOTAL[row.gen] or 8, caught = count(c),
                                  living = l and count(l) or nil, pending = row.pending or nil }
        end
    end
    table.sort(saves, function(a, b) if a.gen ~= b.gen then return a.gen < b.gen end return tostring(a.name) < tostring(b.name) end)
    local regions = {}
    for i, r in ipairs(Dex.REGIONS) do
        regions[i] = { id = r.id, name = r.name, from = r.from, to = r.to, total = r.to - r.from + 1,
                       caught = count(caught, r.from, r.to), living = count(living, r.from, r.to) }
    end
    return { caught = caught, living = living, caughtCount = count(caught), livingCount = count(living),
             regions = regions, saves = saves, pending = pending }
end

local function cardOf(row)
    local party = {}
    for i, m in ipairs(row.party or {}) do party[i] = { species = m.s or 0, level = m.l, nick = m.n, egg = m.e } end
    local rec = row.record
    return { key = row.key, game = row.game, gen = row.gen, name = row.name, trainer = row.trainer, badges = row.badges,
             badgeMask = row.badgeMask, badgeTotal = BADGE_TOTAL[row.gen] or 8, caught = count(unpackSet(row.caught)),
             party = party, record = rec and { wins = rec[1], losses = rec[2], draws = rec[3] } or nil, pending = row.pending }
end
function Dex.Card()
    local d = store()
    local db = MB.DB()
    if not db.testSaves and MB.CurrentStore then
        local cur = MB.CurrentStore()
        local row = cur and d.saves[cur]
        if row and not row.none and MB.IsRunning and MB.IsRunning() then return cardOf(row) end
    end
    local best
    for _, row in pairs(d.saves) do
        if not row.none then
            local p, bp = row.played or 0, best and (best.played or 0) or -1
            if p > bp or (p == bp and row.key == db.lastCart) then best = row end
        end
    end
    return best and cardOf(best) or nil
end

-- ------------------------------------------------------------------ privacy ---
function Dex.MayShow(name, channel)
    local mode = MB.PlayMode and MB.PlayMode() or "open"
    if mode == "solo" then return false end
    if mode == "open" then return true end
    return (MB.Friends and MB.Friends.Known and MB.Friends.Known(name, channel)) and true or false
end

-- ----------------------------------------------------------------- messages ---
local function clean(s, n) return (tostring(s or ""):gsub("[;,|%c]", " "):sub(1, n or 12)) end
local LIMIT = 255
local function mon(m) return num((m.species or 0) % 512 + 512 * math.min(127, m.level or 0) + (m.egg and 65536 or 0), 3) end
function Dex.EncodeCard(card)
    if type(card) ~= "table" then return nil end
    local g = GAME_LETTER[card.game or ""] or tostring(card.gen or 3)
    local rec = card.record and ("%d.%d.%d"):format(card.record.wins or 0, card.record.losses or 0, card.record.draws or 0) or ""
    local p, nicks = {}, {}
    for i = 1, math.min(6, #(card.party or {})) do
        local m = card.party[i]
        p[i] = mon(m)
        nicks[i] = clean(not m.egg and m.nick or "", 12)
    end
    local head = ("C1;%s;%s;%s;%s;%s;%s"):format(g, clean(card.trainer), num(card.badgeMask or 0, 3), num(math.min(4095, card.caught or 0), 2), rec, concat(p))
    local full = head .. ";" .. concat(nicks, ",")
    if #full <= LIMIT then return full end
    return head .. ";"
end
function Dex.DecodeCard(text)
    if type(text) ~= "string" or text:sub(1, 3) ~= "C1;" then return nil end
    local g, trainer, badges, caught, rec, party, nicks = text:match("^C1;([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);?(.*)$")
    if not g or #badges ~= 3 or #caught ~= 2 or #party % 3 ~= 0 or #party > 18 then return nil end
    local mask, nc = unnum(badges, 1, 3), unnum(caught, 1, 2)
    if not (mask and nc) then return nil end
    local game = LETTER_GAME[g]
    local gen = game and ((g:find("[rby]") and 1) or (g:find("[gsc]") and 2) or 3) or tonumber(g)
    if not gen then return nil end
    local names = {}
    for nm in ((nicks or "") .. ","):gmatch("([^,]*),") do names[#names + 1] = nm end
    local out = { game = game, gen = gen, name = game and GAME_NAME[game] or nil, trainer = trainer, badgeMask = mask,
                  badgeTotal = BADGE_TOTAL[gen] or 8, caught = nc, party = {} }
    local b = 0
    for i = 0, 15 do if floor(mask / 2 ^ i) % 2 == 1 then b = b + 1 end end
    out.badges = b
    for i = 1, #party / 3 do
        local v = unnum(party, i * 3 - 2, 3)
        if not v then return nil end
        local sp, lv, egg = v % 512, floor(v / 512) % 128, floor(v / 65536) % 2 == 1
        if sp > MAXDEX then return nil end
        out.party[i] = { species = sp, level = lv, egg = egg or nil, nick = (names[i] and names[i] ~= "") and names[i] or nil }
    end
    if rec ~= "" then
        local w, l, d = rec:match("^(%d+)%.(%d+)%.(%d+)$")
        if not w then return nil end
        out.record = { wins = tonumber(w), losses = tonumber(l), draws = tonumber(d) }
    end
    return out
end

function Dex.EncodeDex(dex)
    if type(dex) ~= "table" then return nil end
    local rows = {}
    for _, s in ipairs(dex.saves or {}) do
        local g = GAME_LETTER[s.game or ""] or tostring(s.gen or 3)
        local mask = s.badgeMask or (2 ^ math.min(16, s.badges or 0) - 1)
        rows[#rows + 1] = g .. num(mask, 3) .. num(math.min(4095, s.caught or 0), 2) .. num(math.min(4095, s.living or 0), 2) .. clean(s.trainer, 10)
    end
    return "D1;" .. packSet(dex.caught) .. packSet(dex.living) .. ";" .. concat(rows, ",")
end
function Dex.DecodeDex(text)
    if type(text) ~= "string" or text:sub(1, 3) ~= "D1;" then return nil end
    local caught, living = unpackSet(text, 4), unpackSet(text, 4 + SETLEN)
    if not (caught and living) or text:sub(4 + 2 * SETLEN, 4 + 2 * SETLEN) ~= ";" then return nil end
    local out = { caught = caught, living = living, caughtCount = count(caught), livingCount = count(living), saves = {}, regions = {} }
    for i, r in ipairs(Dex.REGIONS) do
        out.regions[i] = { id = r.id, name = r.name, from = r.from, to = r.to, total = r.to - r.from + 1,
                           caught = count(caught, r.from, r.to), living = count(living, r.from, r.to) }
    end
    local rest = text:sub(5 + 2 * SETLEN)
    if rest == "" then return out end
    for row in (rest .. ","):gmatch("([^,]*),") do
        if #row < 8 then return nil end
        local g = row:sub(1, 1)
        local game = LETTER_GAME[g]
        local gen = game and ((g:find("[rby]") and 1) or (g:find("[gsc]") and 2) or 3) or tonumber(g)
        local mask, c, l = unnum(row, 2, 3), unnum(row, 5, 2), unnum(row, 7, 2)
        if not (gen and mask and c and l) then return nil end
        local b = 0
        for i = 0, 15 do if floor(mask / 2 ^ i) % 2 == 1 then b = b + 1 end end
        out.saves[#out.saves + 1] = { game = game, gen = gen, name = game and GAME_NAME[game] or nil, badges = b, badgeMask = mask,
                                      badgeTotal = BADGE_TOTAL[gen] or 8, caught = c, living = l, trainer = row:sub(9) }
    end
    return out
end

-- cut a text into messages of at most `size` bytes (default 255), each "<index><count>" then its piece
function Dex.Split(text, size)
    size = (size or LIMIT) - 2
    local parts, n = {}, math.max(1, math.ceil(#text / size))
    if n > 64 then return nil end
    for i = 0, n - 1 do parts[i + 1] = B64:sub(i + 1, i + 1) .. B64:sub(n, n) .. text:sub(i * size + 1, (i + 1) * size) end
    return parts
end
-- the parts (in any order) back into the text; nil while some are missing or they do not agree
function Dex.Join(parts)
    local got, n = {}, nil
    for _, p in ipairs(parts or {}) do
        local i, c = VAL[byte(p, 1) or 0], VAL[byte(p, 2) or 0]
        if not (i and c) then return nil end
        c = c + 1
        if n and n ~= c then return nil end
        n = c
        got[i + 1] = p:sub(3)
    end
    if not n then return nil end
    for i = 1, n do if not got[i] then return nil end end
    return concat(got, "", 1, n)
end

-- ---------------------------------------------------------------- the hooks ---
-- MB.BatteryKept(key) is called whenever a game's own save has just been kept (GB/Console.lua, GBA/Screen.lua).
-- The save is read a moment later (one read for a burst of keeps), and only if it is the player's own.
local dirty, queued = {}, false
local function flush()
    queued = false
    local db = MB.DB()
    for key, at in pairs(dirty) do
        dirty[key] = nil
        if db.testSaves then
            -- the practice set was kept: nothing of it is read, but the ROM in memory can still teach its tables
            local rom = romFor(key)
            if rom then learn(key, rom) settleAll() end
        else
            pcall(Dex.Refresh, key, at)
            pcall(settleAll)
        end
    end
end
Dex.Flush = flush
function Dex.Kept(key)
    if type(key) ~= "string" then return end
    dirty[key] = now()
    if queued then return end
    queued = true
    if C_Timer and C_Timer.After then C_Timer.After(1, flush) else flush() end
end
local kept = MB.BatteryKept
MB.BatteryKept = function(key, ...)
    local r = kept(key, ...)
    pcall(Dex.Kept, key)
    return r
end
-- at login: rows for saves that have none yet, or changed since (a few seconds in, not in the login rush)
MB.onLogin[#MB.onLogin + 1] = function()
    local function go() pcall(Dex.Scan) end
    if C_Timer and C_Timer.After then C_Timer.After(5, go) else go() end
end
