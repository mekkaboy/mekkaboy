-- The team preview's data (Gen 3: Emerald, FireRed 1.0, LeafGreen 1.1, the games a trade or battle where you stand
-- runs in, GBA/Trade3.lua): the party of the game that is running right now, read from its memory, and the words to
-- show it with, read from the viewer's own ROM. Nothing here changes the game. The window is UI/Preview.lua.
--
-- The live party: gPlayerPartyCount and gPlayerParty in the running game's memory (the decompilations' symbol maps,
-- dev/pokeleafgreen_rev1.sym and the Emerald and FireRed ones beside lab/trade3/make_table.py, reference only), each
-- 100-byte record decrypted and checked by DexRead's own Gen 3 code (R.Mon3, the same as a save's); the level is the
-- party record's own (+84). Species are turned into National Dex numbers with the game's own table (DexRead), so the
-- two games of a link (the same family, or Emerald with FireRed/LeafGreen) agree on them; held items are the games'
-- shared item numbers.
--
-- The words, from the viewer's own ROM (never shipped), at the address the symbol map gives for that ROM, used only
-- if what is there has the table's shape:
--   gTypeNames    18 names of 7 bytes, each letters then the end mark (number 9 is "???")
--   gSpeciesInfo  412 records of 28 bytes (the first all zeros), the two types at +6 and +7, every type 0-17
--   gItems        records of 44 bytes, the name (14) first, each record's own number at +14 equal to its place (0 for
--                 the numbers the game does not use, at least 300 its own), the description's address at +20
-- Derived once per ROM and kept (MekkaBoyDB.dex.team3[game]: types by National Dex number, the type names, the item
-- names) the way Dex keeps the species tables; item descriptions (the tooltips) are read when asked for.
--
-- API
--   Team.Live(m)        the running game's party: { trainer, code, mons = { { species, level, nick, item, egg,
--                       unknown }, ... } } or nil, why
--   Team.Encode(team) / Team.Decode(text)
--       P1;<game code>;<trainer>;<5 per Pokemon>;<nick,nick,...>    (6-bit letters as Dex.lua: species + 512 *
--       level + 65536 * egg + 131072 * unreadable in 3, the held item in 2; about 100 bytes, at most 200: nicknames
--       are dropped if it would be longer). No Pokemon: the team couldn't be read.
--   Team.Words(m)       the viewer's names: { types = fn(national) -> t1, t2 (or nil), typeName = fn(i), itemName =
--                       fn(id), itemText = fn(id) (its description), speciesName = fn(national) } or nil
local _, MB = ...
local Team = {}
MB.Team3 = Team
local floor, concat, char = math.floor, table.concat, string.char

-- per ROM (code .. revision): RAM and ROM addresses, from the symbol maps
local AT = {
    BPEE0 = { count = 0x020244E9, mons = 0x020244EC, sb2 = 0x03005D90, typeNames = 0x0831AE38, species = 0x083203CC, items = 0x085839A0, itemCount = 377 },
    BPRE0 = { count = 0x02024029, mons = 0x02024284, sb2 = 0x0300500C, typeNames = 0x0824F1A0, species = 0x08254784, items = 0x083DB028, itemCount = 375 },
    BPGE1 = { count = 0x02024029, mons = 0x02024284, sb2 = 0x0300500C, typeNames = 0x0824F1EC, species = 0x082547D0, items = 0x083DAED4, itemCount = 375 },
}
Team.AT = AT
local SPECIES_COUNT, TYPES = 412, 18

local function keyOf(m)
    if not (m and m.rd8) then return nil end
    local t = {}
    for i = 0, 3 do t[i + 1] = char(m.rd8(0x080000AC + i)) end
    return concat(t) .. m.rd8(0x080000BC), concat(t)
end
Team.KeyOf = keyOf
local function bytes(m, a, n)
    local t = {}
    for i = 0, n - 1 do t[i + 1] = char(m.rd8(a + i)) end
    return concat(t)
end
local function rd16(m, a) return m.rd8(a) + m.rd8(a + 1) * 256 end
local function rd32(m, a) return m.rd8(a) + m.rd8(a + 1) * 256 + m.rd8(a + 2) * 65536 + m.rd8(a + 3) * 16777216 end

-- the game's own internal-to-National table (DexRead's, from the ROM in memory; else the one Dex learned)
local function natTable()
    local R = MB.DexRead
    local id = MB.CurrentCart and MB.CurrentCart()
    local rom = id and MB.Carts and MB.Carts.Peek and MB.Carts.Peek(id)
    if rom and rom.banks then
        local sys = rom.system
        if not sys then rom.system = "gba" end               -- (a cartridge's ROM may not say which system it is)
        local t = R and R.Tables(rom)
        if not sys then rom.system = nil end
        if t and t.nat then return t.nat, t.names end
    end
    local d = MB.Dex and MB.Dex.Store and MB.Dex.Store()
    local s = d and d.tables and d.tables["3"]
    if type(s) ~= "string" then return nil end
    local nat = {}
    for i = 1, floor(#s / 2) do
        local v = MB.Dex.Unnum(s, i * 2 - 1, 2)
        if v and v > 0 and v <= 386 then nat[i] = v end
    end
    return nat
end
Team.NatTable = natTable

-- ------------------------------------------------------------- the party ---
function Team.Live(m)
    local key, code = keyOf(m)
    local p = key and AT[key]
    if not p then return nil, "not a game the preview knows" end
    local R = MB.DexRead
    if not (R and R.Mon3) then return nil, "no reader" end
    local n = m.rd8(p.count)
    if n > 6 then return nil, "party" end
    local nat = natTable()
    local raw = bytes(m, p.mons, 600)
    local team = { code = code, mons = {} }
    local sb2 = rd32(m, p.sb2)
    if sb2 >= 0x02000000 and sb2 < 0x02040000 then team.trainer = R.text3(bytes(m, sb2, 8), 0, 8) end
    for i = 1, n do
        local o = (i - 1) * 100
        local ok, mon = pcall(R.Mon3, raw, o)
        local e = { level = raw:byte(o + 85) }
        if ok and mon then
            e.egg = mon.egg
            e.species = (not mon.egg and nat and nat[mon.raw]) or 0
            e.nick = mon.nick
            e.item = (not mon.egg) and (mon.item or 0) or 0
            if not mon.egg and e.species == 0 then e.unknown = true end
        else
            e.species, e.item, e.unknown = 0, 0, true
        end
        team.mons[i] = e
    end
    return team
end

-- --------------------------------------------------------------- messages ---
local function clean(s, n) return (tostring(s or ""):gsub("[;,#|%c]", " "):sub(1, n or 20)) end
function Team.Encode(team)
    if type(team) ~= "table" then return nil end
    local num = MB.Dex.Num
    local p, nicks = {}, {}
    for i = 1, math.min(6, #(team.mons or {})) do
        local e = team.mons[i]
        local v = (e.species or 0) % 512 + 512 * math.min(127, e.level or 0) + (e.egg and 65536 or 0) + (e.unknown and 131072 or 0)
        p[i] = num(v, 3) .. num(math.min(4095, e.item or 0), 2)
        nicks[i] = clean(not e.egg and e.nick or "", 20)
    end
    local code = tostring(team.code or ""):match("^%u%u%u%u$") or ""
    local head = ("P1;%s;%s;%s"):format(code, clean(team.trainer, 16), concat(p))
    local full = head .. ";" .. concat(nicks, ",")
    if #full <= 200 then return full end
    return head .. ";"
end
local function plain(t) return t and (tostring(t):gsub("|", "/"):gsub("%c", " ")) or nil end
function Team.Decode(text)
    if type(text) ~= "string" then return nil end
    local code, trainer, mons, nicks = text:match("^P1;(%u*);([^;]*);([^;]*);?(.*)$")
    if not trainer or #mons % 5 ~= 0 or #mons > 30 then return nil end
    local unnum = MB.Dex.Unnum
    local names = {}
    for nm in ((nicks or "") .. ","):gmatch("([^,]*),") do names[#names + 1] = nm end
    local out = { code = code ~= "" and code or nil, trainer = trainer ~= "" and plain(trainer) or nil, mons = {} }
    for i = 1, #mons / 5 do
        local v, item = unnum(mons, i * 5 - 4, 3), unnum(mons, i * 5 - 1, 2)
        if not (v and item) then return nil end
        local sp = v % 512
        if sp > 386 then return nil end
        local egg, unknown = floor(v / 65536) % 2 == 1, floor(v / 131072) % 2 == 1
        out.mons[i] = { species = sp, level = floor(v / 512) % 128, egg = egg or nil, unknown = unknown or nil, item = item,
                        nick = (names[i] and names[i] ~= "") and plain(names[i]) or nil }
    end
    return out
end

-- ------------------------------------------------------------------ words ---
local function store()
    local d = MB.Dex and MB.Dex.Store and MB.Dex.Store()
    if not d then return {} end
    if type(d.team3) ~= "table" then d.team3 = {} end
    return d.team3
end
local function letters(s, n)        -- an entry of the game's letters ending in its end mark within n bytes: the text, or nil
    local R = MB.DexRead
    local stop = s:find("\255", 1, true)
    if not stop or stop == 1 or stop > n then return nil end
    local t = R.text3(s, 0, stop)
    if t:find("?", 1, true) and t ~= "???" then return nil end
    return t
end
-- read and check the three tables of the ROM that is running (nil if any is not the shape it should be)
local function derive(m, p)
    local R = MB.DexRead
    -- the type names
    local names = {}
    local tn = bytes(m, p.typeNames, TYPES * 7)
    for i = 0, TYPES - 1 do
        local e = tn:sub(i * 7 + 1, i * 7 + 7)
        local t = letters(e, 7)
        if not t or (i == 9) ~= (t == "???") then return nil, "type names" end
        names[i] = t
    end
    -- each species' two types (by the game's own number), the first record empty
    local sp = bytes(m, p.species, SPECIES_COUNT * 28)
    for i = 1, 28 do if sp:byte(i) ~= 0 then return nil, "species: first record" end end
    local nat = natTable()
    if not nat then return nil, "no National Dex table" end
    local types, hp = {}, 0
    for i = 1, SPECIES_COUNT - 1 do
        local a, b = sp:byte(i * 28 + 7), sp:byte(i * 28 + 8)
        if a >= TYPES or b >= TYPES then return nil, "species: types" end
        if sp:byte(i * 28 + 1) > 0 then hp = hp + 1 end
        if nat[i] then types[nat[i]] = { a, b } end
    end
    if hp < 380 then return nil, "species: too few" end
    for n = 1, 386 do if not types[n] then return nil, "species: missing" end end
    -- the items: each record's own number where it should be
    local it = bytes(m, p.items, p.itemCount * 44)
    local items, own = {}, 0
    for i = 0, p.itemCount - 1 do
        local o = i * 44
        local id = it:byte(o + 15) + it:byte(o + 16) * 256
        if id ~= i and id ~= 0 then return nil, "items: numbers" end                 -- (the unused numbers' records say 0)
        if id == i then own = own + 1 end
        local stop = it:sub(o + 1, o + 14):find("\255", 1, true)
        if not stop then return nil, "items: names" end
        if id == i then items[i] = R.text3(it, o, 14) end
    end
    if own < 300 then return nil, "items: too few" end
    return { types = types, typeNames = names, items = items }
end
local function packTypes(types)
    local t = {}
    for n = 1, 386 do local e = types[n] t[n] = MB.Dex.Num(e[1] * 18 + e[2], 2) end
    return concat(t)
end
local function unpackTypes(s)
    if type(s) ~= "string" or #s ~= 386 * 2 then return nil end
    local types = {}
    for n = 1, 386 do
        local v = MB.Dex.Unnum(s, n * 2 - 1, 2)
        if not v then return nil end
        types[n] = { floor(v / 18), v % 18 }
    end
    return types
end

local function titleCase(s) return (tostring(s or ""):lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)) end
Team.TitleCase = titleCase
-- the game's own type names are cut to six letters; these three are written out in full
local LONG = { FIGHT = "Fighting", ELECTR = "Electric", PSYCHC = "Psychic" }

local made = setmetatable({}, { __mode = "k" })            -- machine -> words
function Team.Words(m)
    if made[m] ~= nil then return made[m] or nil end
    local key = keyOf(m)
    local p = key and AT[key]
    if not p then made[m] = false return nil end
    -- kept from before (the type names 1-based in the saved variables, as a list; item names by number as text)
    local kept, d = store()[key], nil
    if type(kept) == "table" and kept.v == 1 and type(kept.typeNames) == "table" and type(kept.items) == "table" then
        local types = unpackTypes(kept.types)
        if types and #kept.typeNames == TYPES then
            d = { types = types, typeNames = {}, items = {} }
            for i, v in ipairs(kept.typeNames) do d.typeNames[i - 1] = v end
            for i, v in pairs(kept.items) do local k = tonumber(i) if k then d.items[k] = v end end
        end
    end
    if not d then
        local ok, got, why = pcall(derive, m, p)
        d = ok and got or nil
        if not d then Team.lastError = ok and why or got end          -- (which check said no, for /mb bug and the tests)
        if d then
            local tn, it = {}, {}
            for i = 0, TYPES - 1 do tn[i + 1] = d.typeNames[i] end
            for i, v in pairs(d.items) do it[tostring(i)] = v end
            store()[key] = { v = 1, types = packTypes(d.types), typeNames = tn, items = it }
        end
    end
    if not d then made[m] = false return nil end
    local _, speciesNames = natTable()
    local descs = {}
    local w = {}
    function w.types(n)
        local e = n and d.types[n]
        if not e then return nil end
        return e[1], (e[2] ~= e[1]) and e[2] or nil
    end
    function w.typeName(i)
        local t = d.typeNames[i]
        if not t then return nil end
        return LONG[t] or titleCase(t)
    end
    -- the old-school chip: the game's own six-letter capitals, as its menus print them (FIGHT, ELECTR, PSYCHC)
    function w.typeTag(i)
        local t = d.typeNames[i]
        if not t then return nil end
        return tostring(t):upper()
    end
    function w.itemName(id)
        local t = id and d.items[id]
        return (t and t ~= "" and t ~= "????????") and titleCase(t) or nil
    end
    function w.itemText(id)
        if not (id and id > 0 and w.itemName(id)) then return nil end
        if descs[id] == nil then
            descs[id] = false
            local ok, txt = pcall(function()
                local at = rd32(m, p.items + id * 44 + 20)
                if at < 0x08000000 or at >= 0x0A000000 then return nil end
                local raw = bytes(m, at, 240)
                local stop = raw:find("\255", 1, true)
                if not stop then return nil end
                return (MB.DexRead.text3(raw:sub(1, stop - 1):gsub("\254", "\0"), 0, stop - 1):gsub("%s+", " "))
            end)
            if ok and txt and txt ~= "" then descs[id] = txt end
        end
        return descs[id] or nil
    end
    function w.speciesName(n)
        local name = (speciesNames and speciesNames[n]) or (MB.Dex.Name and MB.Dex.Name(n)) or (MB.DexIcons and MB.DexIcons.Name and MB.DexIcons.Name(n))
        return name and titleCase(name) or nil
    end
    made[m] = w
    return w
end
function Team.Forget(m) if m then made[m] = nil else made = setmetatable({}, { __mode = "k" }) end end      -- (for tests)
