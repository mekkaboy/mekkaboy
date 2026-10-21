-- Together: other trainers, walking in your game (EXPERIMENTAL; /mb together, once /mb ghosts). In the Pokemon
-- games (Gen 1 and 2 on the Game Boy, Gen 3 on the Advance), friends who share with you appear on the same map (in this file, a friend drawn is a "ghost"): drawn over your picture where their trainer stands, walking
-- as they walk, a couple of seconds behind. Nothing in either game changes: the game never knows they are there,
-- they do not block your way, and the link (/mb link) is still how you trade and battle.
--
-- What it reads from your game (found by watching memory while a trainer walks, in each game; see lab/ghosts):
-- the map, the trainer's tile and facing, and the camera (the scroll registers). A ghost's picture (Brendan or May,
-- Red or Leaf, on foot or on a bike) is taken from your own copy of the game at run time, from the game's own list of
-- pictures; nothing of the game is stored or sent, only the game's number for the picture.
--
-- Messages (whispered to each friend, on an addon name of their own so they never eat into the link's), about one a
-- second while moving (one every three while linked), one every 8 s standing still:
--   G2;<seq>;<family>;<group>;<map>;<x>;<y>;<facing>;<picture>;<state>;<events>   (G1: the same without <state>)
--   picture: the game's number for the trainer's look (Brendan or May, on a bike, surfing)
--   state: 0 on the map, 1 in a battle, 2 paused (the console stopped or hidden), 3 leaving (game closed, Together off,
--   logging out: drawn no more at once)
--   <x>,<y>: where the first event starts. events: a step is <u|d|l|r><ago><length>, a turn is t<facing><ago>
--   (ago: how long before the packet was sent; length: how long the step took; both in 1/60 s of real time, base 64)
local _, MB = ...
local G = {}
MB.Ghosts = G
local Print = MB.Print
local floor = math.floor

-- Where each game keeps what Together reads, by the game's code. First measured by watching memory in the user's own
-- copies (lab/ghosts/find_pos.py, probe2-5.py), then checked against the pret decompilations' builds (pokeemerald,
-- pokefirered, pokeruby; reference only: lab/ghosts/collect_symbols.py writes these tables). RAM is the same in every
-- revision of a game. family: games that share the same maps.
--   obj: the player's entry in the moving-objects list. +5 picture number, +8 0xFF for the player, +9 map, +10 map
--        group, +16 tile now (x, y; 16 bits each), +20 tile before the step, +24 facing (low 4 bits: 1 down, 2 up,
--        3 left, 4 right)
--   main: the game's main state; bit 1 of the byte at +inBattle is set in a battle
--   grid: the map grid around you (width, height, pointer to 16-bit cells: tile number in the low 10 bits);
--        header: the map's header, whose first word points at its layout (+0x10, +0x14: the two tile sets; a tile
--        set's behavior list at +attrOff, attrSize bytes a tile, behavior = value % behavior); tile numbers below
--        primary are in the first set. tallGrass: the behaviors the game draws grass over a trainer on.
local PROFILES = {
    BPEE = { obj = 0x02037350, family = "E", main = 0x030022C0, inBattle = 0x439, grid = 0x03005DC0, header = 0x02037318, attrOff = 0x10, attrSize = 2, behavior = 256, primary = 512, tallGrass = { [2] = true } },
    BPRE = { obj = 0x02036E38, family = "K", main = 0x030030F0, inBattle = 0x439, grid = 0x03005040, header = 0x02036DFC, attrOff = 0x14, attrSize = 4, behavior = 512, primary = 640, tallGrass = { [2] = true, [209] = true } },
    BPGE = { obj = 0x02036E38, family = "K", main = 0x030030F0, inBattle = 0x439, grid = 0x03005040, header = 0x02036DFC, attrOff = 0x14, attrSize = 4, behavior = 512, primary = 640, tallGrass = { [2] = true, [209] = true } },
    AXVE = { obj = 0x030048A0, family = "R", main = 0x03001770, inBattle = 0x43D, grid = 0x03004870, header = 0x0202E828, attrOff = 0x10, attrSize = 2, behavior = 256, primary = 512, tallGrass = { [2] = true } },
    AXPE = { obj = 0x030048A0, family = "R", main = 0x03001770, inBattle = 0x43D, grid = 0x03004870, header = 0x0202E828, attrOff = 0x10, attrSize = 2, behavior = 256, primary = 512, tallGrass = { [2] = true } },
}
-- Pictures in the game, by code and revision (the byte at 0xBC): the tall-grass blades the game draws over a trainer
-- (16x16, 4 bits a dot, its resting frame first), the Pokemon a trainer surfs on (three 32x32 frames: down, up,
-- left), and the grass's colors. Each is used only if the copy's bytes there add up to the sum given (a check, so a
-- copy that differs goes without; the sum is h = (h * 31 + byte) mod 2^31 - 1).
local PICTURES = {
    BPEE0 = { grass = 0x084F8738, grassSum = 759943483, blob = 0x084F5418, blobSum = 1835063127, pal = 0x084F77D8, palSum = 1760535050 },
    BPRE0 = { grass = 0x0839A008, grassSum = 2134882889, blob = 0x08396B08, blobSum = 386484909, pal = 0x08398FC8, palSum = 728365454 },
    BPRE1 = { grass = 0x0839A078, grassSum = 2134882889, blob = 0x08396B78, blobSum = 386484909, pal = 0x08399038, palSum = 728365454 },
    BPGE0 = { grass = 0x08399FE8, grassSum = 2134882889, blob = 0x08396AE8, blobSum = 386484909, pal = 0x08398FA8, palSum = 728365454 },
    BPGE1 = { grass = 0x0839A058, grassSum = 2134882889, blob = 0x08396B58, blobSum = 386484909, pal = 0x08399018, palSum = 728365454 },
    AXVE0 = { grass = 0x0836A4C8, grassSum = 759943483, blob = 0x083670E8, blobSum = 1835063127, pal = 0x083694A8, palSum = 1760535050 },
    AXVE1 = { grass = 0x0836A4E0, grassSum = 759943483, blob = 0x08367100, blobSum = 1835063127, pal = 0x083694C0, palSum = 1760535050 },
    AXVE2 = { grass = 0x0836A4E0, grassSum = 759943483, blob = 0x08367100, blobSum = 1835063127, pal = 0x083694C0, palSum = 1760535050 },
    AXPE0 = { grass = 0x0836A458, grassSum = 759943483, blob = 0x08367078, blobSum = 1835063127, pal = 0x08369438, palSum = 1760535050 },
    AXPE1 = { grass = 0x0836A470, grassSum = 759943483, blob = 0x08367090, blobSum = 1835063127, pal = 0x08369450, palSum = 1760535050 },
    AXPE2 = { grass = 0x0836A470, grassSum = 759943483, blob = 0x08367090, blobSum = 1835063127, pal = 0x08369450, palSum = 1760535050 },
}
-- the surfing pictures (Brendan, May and the rivals; Red, Leaf)
local SURFING = { E = { [2] = true, [92] = true, [103] = true, [108] = true }, R = { [2] = true, [92] = true, [103] = true, [108] = true },
                  K = { [2] = true, [9] = true } }
-- Emerald and Ruby/Sapphire share most of Hoenn: a map that is the same place in both (same name, same size) is shown
-- across the two; others only within the same game.
-- generated by lab/ghosts/make_hoenn_maps.py from the pokeruby and pokeemerald decompilations' map lists
-- (group * 256 + map). Ruby/Sapphire maps whose Emerald twin (same name, same size) has another number:
local R_TO_E = {
    [1283] = 1284, [1538] = 1539, [1539] = 1540, [1541] = 1542, [1542] = 1543, [1543] = 1544, [2309] = 2310, [2310] = 2311,
    [2311] = 2312, [2312] = 2313, [2314] = 2315, [2316] = 2317, [3340] = 3339, [3341] = 3340, [3342] = 3341, [3343] = 3342,
    [3344] = 3343, [3345] = 3344, [3346] = 3345, [3347] = 3346, [3348] = 3347, [3349] = 3348, [3350] = 3349, [6657] = 6668,
    [6659] = 6669,
}
-- Ruby/Sapphire maps with no Emerald twin of the same size
local R_ONLY = {
    [18] = true, [24] = true, [50] = true, [51] = true, [52] = true, [53] = true, [515] = true, [770] = true, [1025] = true, [1026] = true, [1030] = true, [1281] = true,
    [1282] = true, [1284] = true, [1285] = true, [1286] = true, [1536] = true, [1537] = true, [1540] = true, [1793] = true, [2053] = true, [2306] = true, [2307] = true, [2308] = true,
    [2313] = true, [2315] = true, [2566] = true, [2819] = true, [2822] = true, [3075] = true, [3332] = true, [3335] = true, [3339] = true, [3351] = true, [3584] = true, [3588] = true,
    [3595] = true, [3843] = true, [3852] = true, [4101] = true, [4102] = true, [4103] = true, [4104] = true, [4105] = true, [4106] = true, [4109] = true, [6173] = true, [6183] = true,
    [6184] = true, [6185] = true, [6186] = true, [6218] = true, [6219] = true, [6220] = true, [6424] = true, [6427] = true, [6428] = true, [6429] = true, [6430] = true, [6431] = true,
    [6432] = true, [6433] = true, [6434] = true, [6435] = true, [6436] = true, [6437] = true, [6438] = true, [6439] = true, [6660] = true, [6661] = true, [6662] = true, [6663] = true,
    [6664] = true,
}
-- Emerald maps with no Ruby/Sapphire twin of the same size
local E_ONLY = {
    [18] = true, [24] = true, [50] = true, [51] = true, [52] = true, [53] = true, [54] = true, [55] = true, [56] = true, [515] = true, [770] = true, [1025] = true,
    [1026] = true, [1030] = true, [1281] = true, [1282] = true, [1283] = true, [1285] = true, [1286] = true, [1287] = true, [1536] = true, [1537] = true, [1538] = true, [1541] = true,
    [1793] = true, [2053] = true, [2306] = true, [2307] = true, [2308] = true, [2309] = true, [2314] = true, [2316] = true, [2566] = true, [2819] = true, [2822] = true, [3075] = true,
    [3332] = true, [3335] = true, [3350] = true, [3584] = true, [3588] = true, [3595] = true, [3843] = true, [3852] = true, [3853] = true, [3854] = true, [4101] = true, [4102] = true,
    [4103] = true, [4104] = true, [4105] = true, [4106] = true, [4109] = true, [4110] = true, [6173] = true, [6183] = true, [6184] = true, [6185] = true, [6186] = true, [6218] = true,
    [6219] = true, [6220] = true, [6230] = true, [6231] = true, [6232] = true, [6233] = true, [6234] = true, [6235] = true, [6236] = true, [6237] = true, [6238] = true, [6239] = true,
    [6240] = true, [6241] = true, [6242] = true, [6243] = true, [6244] = true, [6245] = true, [6246] = true, [6247] = true, [6248] = true, [6249] = true, [6250] = true, [6251] = true,
    [6424] = true, [6427] = true, [6428] = true, [6429] = true, [6430] = true, [6431] = true, [6432] = true, [6433] = true, [6434] = true, [6435] = true, [6436] = true, [6437] = true,
    [6438] = true, [6439] = true, [6444] = true, [6445] = true, [6446] = true, [6447] = true, [6448] = true, [6449] = true, [6450] = true, [6451] = true, [6452] = true, [6453] = true,
    [6454] = true, [6455] = true, [6456] = true, [6457] = true, [6458] = true, [6459] = true, [6460] = true, [6657] = true, [6659] = true, [6660] = true, [6661] = true, [6662] = true,
    [6663] = true, [6664] = true, [6670] = true, [6671] = true, [6672] = true, [6673] = true, [6674] = true, [6675] = true, [6676] = true, [6677] = true, [6678] = true, [6679] = true,
    [6680] = true, [6681] = true, [6682] = true, [6683] = true, [6684] = true, [6685] = true, [6686] = true, [6687] = true, [6688] = true, [6689] = true, [6690] = true, [6691] = true,
    [6692] = true, [6693] = true, [6694] = true, [6695] = true, [6696] = true, [6697] = true, [6698] = true, [6699] = true, [6700] = true, [6701] = true, [6702] = true, [6703] = true,
    [6704] = true, [6705] = true, [6706] = true, [6707] = true, [6708] = true, [6709] = true, [6710] = true, [6711] = true, [6712] = true, [6713] = true, [6714] = true, [6715] = true,
    [6716] = true, [6717] = true, [6718] = true, [6719] = true, [6720] = true, [6721] = true, [6722] = true, [6723] = true, [6724] = true, [6725] = true, [6726] = true, [6727] = true,
    [6728] = true, [6729] = true, [6730] = true, [6731] = true, [6732] = true, [6733] = true, [6734] = true, [6735] = true, [6736] = true, [6737] = true, [6738] = true, [6739] = true,
    [6740] = true, [6741] = true, [6742] = true, [6743] = true, [6744] = true,
}
-- The Game Boy games (Gen 1 and 2), by the cartridge's title and version byte: where each keeps its map, its tile
-- (16x16 dots), its facing (0 down, 4 up, 8 left, 12 right), its look and whether it is in a battle, from the pret
-- decompilations' builds (pokered, pokeyellow, pokegold, pokecrystal; reference only: lab/together_gb/collect_gb.py).
-- Gen 1: look 0 walking, 1 bike, 2 surfing; pics: bank, address and sum of the three pictures (six 16x16 frames:
-- standing down, up, left; walking down, up, left). Gen 2: sprite = the player's object (its first byte: the
-- picture number); sprites = the game's list of pictures (6 bytes each: address, size, bank, kind, palette).
local GB_PROFILES = {
    ["POKEMON RED/0"] = { gen = 1, family = "RB", map = 0xD35E, y = 0xD361, x = 0xD362, facing = 0xC109, look = 0xD700, battle = 0xD057, pics = { { 5, 0x4180, 764014812 }, { 5, 0x4000, 851806420 }, { 5, 0x76C0, 1485436187 } } },
    ["POKEMON BLUE/0"] = { gen = 1, family = "RB", map = 0xD35E, y = 0xD361, x = 0xD362, facing = 0xC109, look = 0xD700, battle = 0xD057, pics = { { 5, 0x4180, 764014812 }, { 5, 0x4000, 851806420 }, { 5, 0x76C0, 1485436187 } } },
    ["POKEMON YELLOW/0"] = { gen = 1, family = "Y", map = 0xD35D, y = 0xD360, x = 0xD361, facing = 0xC109, look = 0xD6FF, battle = 0xD056, pics = { { 5, 0x4571, 764014812 }, { 5, 0x43F1, 851806420 }, { 5, 0x7AB1, 1485436187 } } },
    ["POKEMON_GLDAAUE/0"] = { gen = 2, family = "GS", group = 0xDA00, map = 0xDA01, y = 0xDA02, x = 0xDA03, facing = 0xD205, sprite = 0xD1FD, battle = 0xD116, sprites = { 5, 0x47DE, 674802083 } },
    ["POKEMON_SLVAAXE/0"] = { gen = 2, family = "GS", group = 0xDA00, map = 0xDA01, y = 0xDA02, x = 0xDA03, facing = 0xD205, sprite = 0xD1FD, battle = 0xD116, sprites = { 5, 0x47DE, 674802083 } },
    ["PM_CRYSTAL/0"] = { gen = 2, family = "GC", group = 0xDCB5, map = 0xDCB6, y = 0xDCB7, x = 0xDCB8, facing = 0xD4DE, sprite = 0xD4D6, battle = 0xD22D, sprites = { 5, 0x4736, 1624649434 } },
    ["PM_CRYSTAL/1"] = { gen = 2, family = "GC", group = 0xDCB5, map = 0xDCB6, y = 0xDCB7, x = 0xDCB8, facing = 0xD4DE, sprite = 0xD4D6, battle = 0xD22D, sprites = { 5, 0x4736, 1624649434 } },
}
-- generated by lab/together_gb/make_gb_maps.py from the pret decompilations' map lists (reference only)
-- Gen 1: Red/Blue and Yellow maps that are not the same place under the same number
local RB_ONLY = { [63] = true }
local Y_ONLY = { [63] = true, [248] = true }
-- Gen 2 (group * 256 + map): Gold/Silver maps whose Crystal twin has another number; maps with no twin
local GS_TO_C = { [797] = 805, [798] = 806, [799] = 807, [800] = 808, [801] = 809, [802] = 810, [803] = 811, [804] = 812, [805] = 813, [806] = 814, [807] = 815, [808] = 816, [809] = 817, [810] = 818, [811] = 819, [812] = 820, [813] = 821, [814] = 822, [815] = 823, [816] = 824, [817] = 825, [818] = 826, [819] = 827, [820] = 828, [821] = 829, [822] = 830, [823] = 831, [824] = 832, [825] = 833, [826] = 834, [827] = 835, [828] = 836, [829] = 837, [830] = 838, [831] = 839, [832] = 840, [833] = 841, [834] = 842, [835] = 843, [836] = 844, [837] = 845, [838] = 846, [839] = 847, [840] = 848, [841] = 849, [842] = 851, [843] = 852, [844] = 853, [845] = 854, [846] = 855, [847] = 856, [848] = 857, [849] = 858, [850] = 859, [2825] = 2836, [2826] = 2825, [2827] = 2826, [2828] = 2827, [2829] = 2828, [2830] = 2829, [2831] = 2830, [2832] = 2831, [2833] = 2832, [2834] = 2833, [2836] = 2838, [2837] = 2839, [2838] = 2840 }
local GS_ONLY = { [1026] = true }
local C_ONLY = { [797] = true, [798] = true, [799] = true, [800] = true, [801] = true, [802] = true, [803] = true, [804] = true, [850] = true, [1026] = true, [2834] = true, [2837] = true, [5125] = true, [5126] = true, [5642] = true, [5643] = true, [5644] = true, [5645] = true, [5646] = true, [5647] = true, [5648] = true }
local function placeKey(family, group, map)
    if family == "RB" or family == "Y" then
        if (family == "RB" and RB_ONLY[map]) or (family == "Y" and Y_ONLY[map]) then return family .. map end
        return "1." .. map
    elseif family == "GS" or family == "GC" then
        local id = group * 256 + map
        if (family == "GS" and GS_ONLY[id]) or (family == "GC" and C_ONLY[id]) then return family .. group .. "." .. map end
        if family == "GS" then id = GS_TO_C[id] or id end
        return "2." .. floor(id / 256) .. "." .. id % 256
    end
    local id = group * 256 + map
    if family == "R" and not R_ONLY[id] then id = R_TO_E[id] or id return "H" .. floor(id / 256) .. "." .. id % 256 end
    if family == "E" and not E_ONLY[id] then return "H" .. group .. "." .. map end
    return family .. group .. "." .. map
end
G.PlaceKey = placeKey
local STAND = { [1] = 0, [2] = 1, [3] = 2, [4] = 2 }    -- the sheet: 0-2 standing down/up/left, 3-4 walking down,
local WALK = { [1] = { 3, 4 }, [2] = { 5, 6 }, [3] = { 7, 8 }, [4] = { 7, 8 } }    -- 5-6 up, 7-8 left (right = left mirrored)
local DIRS = { d = { 0, 1, 1 }, u = { 0, -1, 2 }, l = { -1, 0, 3 }, r = { 1, 0, 4 } }
local B64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
local function enc(n, w) local t = {} for i = w, 1, -1 do local d = n % 64 t[i] = B64:sub(d + 1, d + 1) n = floor(n / 64) end return table.concat(t) end
local DEC = {} for i = 1, 64 do DEC[B64:sub(i, i)] = i - 1 end
local function dec(s) local n = 0 for i = 1, #s do local d = DEC[s:sub(i, i)] if not d then return nil end n = n * 64 + d end return n end

local DELAY = 2.5         -- seconds a ghost runs behind the trainer it shows (over twice the time between packets)
local SEND_EVERY = 1      -- seconds between packets while moving
local SEND_LINKED = 3     -- the same while linked (the link needs the line more)
local KEEP_ALIVE = 8      -- seconds between packets while standing still
local FORGET = 30         -- seconds without a word before a ghost goes
local LANE = 5            -- the addon name ghost packets go out on (GB/Link.lua: lanes 1-4 are the link's)
local COMMAND_WORDS = { on = true, off = true, why = true, forget = true, list = true, help = true, names = true,
                        realm = true, block = true, unblock = true }
-- Together with the whole realm: everyone who chose it shares one hidden chat channel (one message a second reaches
-- them all; whispering each player would not), and each MekkaBoy draws the players on its own map
local REALM_CHANNEL = "MekkaBoyTogether"
local REALM_DRAW = 8      -- at most this many drawn at once (friends first, then the nearest)
local REALM_KEEP = 40     -- players from the realm kept in mind at once

local on = false
local myKey, stepSheetJob, decode4 -- (below)
local sheetJob, yieldBanks = nil, 0     -- (the search for the pictures, in pieces: below)
local m, prof             -- the machine and its profile, when a game Together knows is running
local kind                -- "gba" (Gen 3) or "gb" (Gen 1, 2)
-- the screen: its size, where my trainer's picture's top left is, and how tall a trainer's picture is at rest
local SW, SH, AX, AY, BASEH = 240, 160, 112, 56, 32
local me                  -- my trainer as last read
local ghosts = {}         -- friend key -> ghost
local friends = {}        -- friend key (plain name) -> { name, spelling (the one that reaches them), heard }
local alias = {}          -- another plain spelling a friend's messages carry -> friend key
local strangers = {}      -- players met through the realm channel, not added as friends: key -> { name, heard }
local realm = { num = 0, sent = 0, heard = {}, joins = 0 }   -- the realm channel: its number here, and what went on there
-- "on" (share and see), "watch" (see, unseen), "off", or nil (not asked yet)
-- (a stable build: the realm is not offered yet, and nobody is asked)
local function realmMode() if not MB.Alpha() or (MB.PlayMode and MB.PlayMode() ~= "open") then return "off" end return MB.Opt("realm", nil) end   -- (the realm only when playing Open)
local function solo() return MB.PlayMode and MB.PlayMode() == "solo" end
local NOT_YET = "Playing with everyone on the realm is still being tested and comes in a later version. Friends you add with /mb together <name> work now."
local function realmShare() return realmMode() == "on" end
local function realmShow() local r = realmMode() return r == "on" or r == "watch" end
local function blocked() local db = MB.DB() db.togetherBlocked = db.togetherBlocked or {} return db.togetherBlocked end
local sheetAt, sheetFor   -- where my trainer's picture sheet is in the game (byte offset), and for which game
local pics                -- the game's picture list (see "pictures" below)
local dirty = false       -- a ghost moved or went: the picture needs redrawing even if the game's did not change
local failed = false

local function rd16(a) return m.rd8(a) + m.rd8(a + 1) * 256 end
-- the display registers and sprite records, straight from the machine's own tables (cheaper than reading the bus)
local function io(off) local t = m.io return t and t[off] or rd16(0x04000000 + off) end
local function oam(i, w) local t = m.oam return t and t[i * 4 + w] or rd16(0x07000000 + i * 8 + w * 2) end
local function code()
    local t = {}
    for i = 0, 3 do t[#t + 1] = string.char(m.rd8(0x080000AC + i)) end
    return table.concat(t)
end
local function friendOf(sender)
    local key = MB.Link.Plain(sender)
    if friends[key] then return friends[key], key end
    local a = alias[key]
    if a and friends[a] then return friends[a], a end
    for k, f in pairs(friends) do if MB.Link.NameIs(sender, f.name) then return f, k end end
end
local function linkedNow() local s = MB.Link.Session and MB.Link.Session() return s and s.state == "linked" end

-- ---- my trainer ----
local function gbByte(a)                         -- (Gen 2 keeps these in the second bank of work memory)
    if prof.gen == 2 and a >= 0xD000 then return m.peekBank(1, a) end
    return m.peek(a)
end
local GB_FACING = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
local function readMe()
    if kind == "gb" then
        -- the tile changes when a step ends (in Gen 3, when it begins): the step's start is when the scroll began
        local x, y = gbByte(prof.x), gbByte(prof.y)
        local facing = GB_FACING[floor(gbByte(prof.facing) % 16 / 4)]
        local gid = prof.gen == 1 and gbByte(prof.look) or gbByte(prof.sprite)
        return prof.gen == 2 and gbByte(prof.group) or 0, gbByte(prof.map), x, y, x, y, facing, gid
    end
    local o = prof.obj
    if m.rd8(o + 8) ~= 0xFF then return nil end
    return m.rd8(o + 10), m.rd8(o + 9), rd16(o + 16), rd16(o + 18), rd16(o + 20), rd16(o + 22), m.rd8(o + 24) % 16, m.rd8(o + 5)
end
local function newMe()
    return { events = {}, seq = 0, frame = 0, sentAt = 0, aliveAt = 0, cam = { 0, 0 }, last = nil, C = nil,
             fps = 60, fpsT = nil, fpsF = 0 }
end

-- the camera: the map layers' scroll, followed frame by frame so that it never wraps
local function camera(s)
    local h, v, wrap
    -- (followed in steps of under 128 dots a frame, so counting round 256 is right for both: a Game Boy Advance map layer
    -- is drawn 256 or 512 dots wide, and the games keep the scroll round 256 for the smaller one: counted round 512, a
    -- step from 0 to 255 looked like a 255-dot jump and friends vanished off the edge until I stood still again)
    if kind == "gb" then h, v = m.peek(0xFF43), m.peek(0xFF42) else h, v = io(0x14) % 512, io(0x16) % 512 end
    wrap = 256
    local moved = false
    if s.last then
        local half = wrap / 2
        local dh, dv = (h - s.last[1] + half) % wrap - half, (v - s.last[2] + half) % wrap - half
        s.cam[1], s.cam[2] = s.cam[1] + dh, s.cam[2] + dv
        moved = dh ~= 0 or dv ~= 0
    else
        s.cam[1], s.cam[2] = h, v
    end
    s.last = s.last or {}
    s.last[1], s.last[2] = h, v
    return moved
end

local function send(text)
    if solo() then return end                         -- (How I play: Solo shares nothing)
    local done, now = {}, GetTime()
    if realmShare() and GetChannelName then           -- (looked up fresh: a stale number was refused as "bad channel")
        local n = GetChannelName(REALM_CHANNEL)
        realm.num = type(n) == "number" and n or 0
    end
    local onChannel = realmShare() and realm.num > 0
    if onChannel then
        local refused = MB.Link.Send(text, "CHANNEL", realm.num, LANE)
        realm.sent = realm.sent + 1
        if refused then realm.refused = refused end
    end
    for _, f in pairs(friends) do
        -- (a friend heard on the channel lately hears my channel messages too: no whisper needed)
        if onChannel and f.viaRealmAt and now - f.viaRealmAt < 15 then done[f] = true end
        if f.spelling and not done[f] and not MB.Link.Unreachable(f.spelling) then
            done[f] = true
            local refused = MB.Link.Send(text, "WHISPER", f.spelling, LANE)
            f.sent = (f.sent or 0) + 1
            if refused then f.refused = refused end
        end
    end
end
-- 1/60 s of real time, from emulated frames (the game may run slower or faster than 60 a second)
local function wall(s, frames) return floor(frames * 60 / s.fps + 0.5) end
local function packet(s, force)
    -- everything but a step still under way goes; that one waits for the next packet
    local out, keep = {}, {}
    for _, e in ipairs(s.events) do
        if e.dir and not e.len then keep[#keep + 1] = e else out[#out + 1] = e end
    end
    if #out == 0 and not force then return end
    s.seq = s.seq % 250 + 1
    local ev = {}
    for _, e in ipairs(out) do
        local ago = math.max(0, math.min(4095, wall(s, s.frame - e.at)))
        if e.dir then ev[#ev + 1] = e.dir .. enc(ago, 2) .. enc(math.max(1, math.min(63, wall(s, e.len))), 1)
        else ev[#ev + 1] = "t" .. e.facing .. enc(ago, 2) end
    end
    local first = out[1] or keep[1]
    local ax, ay = first and first.fx or s.x, first and first.fy or s.y
    send(("G2;%d;%s;%d;%d;%d;%d;%d;%d;%d;%s"):format(s.seq, prof.family, s.group, s.map, ax, ay, s.facing or 1, s.gid or 0, s.state or 0, table.concat(ev)))
    s.events = keep
    s.sentAt, s.aliveAt = GetTime(), GetTime()
end

-- every emulated frame (GB/Console.lua): where am I, and did I take a step? (render: this frame is the one shown)
function G.Frame(machine, render)
    if not on or not prof or machine ~= m then return end
    local s = me
    s.frame = s.frame + 1
    local now = GetTime()
    s.ranAt = now
    if sheetJob then stepSheetJob() end
    if not s.fpsT or now - (s.lastNow or now) > 0.25 then s.fpsT, s.fpsF = now, s.frame      -- (a pause or a hitch: start again)
    elseif now - s.fpsT >= 1 then
        s.fps = math.max(10, math.min(480, (s.frame - s.fpsF) / (now - s.fpsT)))
        s.fpsT, s.fpsF = now, s.frame
    end
    s.lastNow = now
    local group, map, x, y, px, py, facing, gid = readMe()
    local moved = camera(s)
    -- (how long the camera has been still: on the Game Boy it scrolls every other frame while walking, so one still
    -- frame does not mean a stop)
    local wasStill = (s.still or 99) >= 2
    if moved then s.still = 0 else s.still = (s.still or 0) + 1 end
    if moved and wasStill then s.moveStart = s.frame end
    local state
    if kind == "gb" then state = gbByte(prof.battle) ~= 0 and 1 or 0
    else state = floor(m.rd8(prof.main + prof.inBattle) / 2) % 2 end   -- (1: in a battle)
    if s.map and state ~= (s.state or 0) then s.state = state packet(s, true) end     -- (a battle began or ended)
    s.state = state
    if render then
        s.camShown = s.camShown or {}
        s.camShown[1], s.camShown[2] = s.cam[1], s.cam[2]
        if s.C then s.CShown = s.CShown or {} s.CShown[1], s.CShown[2] = s.C[1], s.C[2] else s.CShown = nil end
    end
    if not group then                              -- (no trainer to read, as in some games' battles: keep in touch)
        if s.map and now - s.aliveAt >= KEEP_ALIVE then packet(s, true) end
        return
    end
    if not s.map or group ~= s.group or map ~= s.map then
        -- a new map (a door, stairs, flying): what is left on the old one goes first, then where I am now
        if s.map then
            if s.stepping and not s.stepping.len then s.stepping.len = s.frame - s.stepping.at end
            packet(s)
        end
        s.group, s.map, s.x, s.y, s.facing, s.gid = group, map, x, y, facing, gid
        s.events, s.stepping, s.C, s.CShown = {}, nil, nil, nil
        packet(s, true)
        dirty = true
        return
    end
    if gid ~= s.gid then
        s.gid = gid
        packet(s, true)                                     -- (on a bike, off it, surfing: show the new picture at once)
    end
    if x ~= s.x or y ~= s.y then
        if s.stepping and not s.stepping.len then s.stepping.len = s.frame - s.stepping.at end    -- (the step before, ended)
        local dx, dy = x - s.x, y - s.y
        if math.abs(dx) + math.abs(dy) == 1 then
            local dir = (dy > 0 and "d") or (dy < 0 and "u") or (dx < 0 and "l") or "r"
            s.stepping = { at = s.frame, dir = dir, fx = s.x, fy = s.y }
            if kind == "gb" then                  -- (the step is already over: it began when the scroll did)
                local at = math.max(s.moveStart or s.frame, s.frame - 32)
                s.stepping.at, s.stepping.len = at, math.max(1, s.frame - at)
                s.moveStart = s.frame
            end
            s.events[#s.events + 1] = s.stepping
            s.x, s.y = x, y
        else
            -- a jump we cannot show as steps: what came before goes, then where I am now
            packet(s)
            s.events, s.stepping = {}, nil
            s.x, s.y = x, y
            packet(s, true)
        end
    elseif facing ~= s.facing and x == px and y == py then
        s.events[#s.events + 1] = { at = s.frame, facing = facing, fx = x, fy = y }
    end
    s.facing = facing
    if s.stepping and px == x and py == y then
        s.stepping.len = s.stepping.len or (s.frame - s.stepping.at)
        s.stepping = nil
    end
    -- standing still and the camera at rest: where the camera is when I stand on this tile
    if px == x and py == y and not moved and (kind ~= "gb" or s.still >= 3) then
        s.C = s.C or {}
        s.C[1], s.C[2] = s.cam[1] - x * 16, s.cam[2] - y * 16
    end
    local every = linkedNow() and SEND_LINKED or SEND_EVERY
    if #s.events >= 40 or (#s.events > 0 and now - s.sentAt >= every) then packet(s) end
    if now - s.aliveAt >= KEEP_ALIVE then packet(s, true) end
    -- friends whose name has not been worked out yet: try again now and then
    if now - (G.retryAt or 0) > 15 then
        G.retryAt = now
        for _, f in pairs(friends) do
            if (not f.spelling or MB.Link.Unreachable(f.spelling)) and now - (f.askedAt or 0) > 15 then G.Ask(f) end
        end
    end
end

-- ---- the ghosts ----
local function prune(g, now)
    while #g.moves > 1 and g.moves[2].t <= now do
        local mv = table.remove(g.moves, 1)
        g.sx, g.sy, g.sf, g.skey = mv.x2, mv.y2, mv.facing, mv.key
    end
    while #g.moves > 200 do table.remove(g.moves, 1) end
end
function G.Heard(text, channel, sender)
    if text:sub(1, 3) == "GP;" then G.ProbeHeard(text, channel, sender) return end
    if not on or solo() then return end
    local viaRealm = channel == "CHANNEL"
    local now = GetTime()
    if viaRealm then
        if not realmShow() then return end
        if MB.Link.IsMe(sender) then realm.echoAt = now return end    -- (my own, back from the server: the channel works)
    elseif channel ~= "WHISPER" then return end
    local f, key = friendOf(sender)
    if not f then
        if not viaRealm then return end           -- (whispers: only friends you added are drawn)
        key = MB.Link.Plain(sender)
        if blocked()[key] then return end
        f = strangers[key]
        if not f then
            local n, stalest, sk = 0, nil, nil
            for k, o in pairs(strangers) do
                n = n + 1
                if not stalest or (o.heard or 0) < stalest then stalest, sk = o.heard or 0, k end
            end
            if n >= REALM_KEEP and sk then strangers[sk] = nil ghosts[sk] = nil end
            f = { name = sender, stranger = true }
            strangers[key] = f
        end
    elseif viaRealm then
        f.viaRealmAt = now
    end
    if viaRealm then realm.heard[key] = now end
    -- no more than four a second from anyone, and each packet once (a friend's may come both ways)
    if f.winAt and now - f.winAt < 1 then
        f.winN = f.winN + 1
        if f.winN > 4 then return end
    else f.winAt, f.winN = now, 1 end
    local seq, fam, group, map, x, y, facing, gid, state, events = text:match("^G2;(%d+);(%a%a?);(%d+);(%d+);(%d+);(%d+);(%d);(%d+);(%d);(.*)$")
    if not seq then
        seq, fam, group, map, x, y, facing, gid, events = text:match("^G1;(%d+);(%a);(%d+);(%d+);(%d+);(%d+);(%d);(%d+);(.*)$")
        state = "0"
    end
    if not seq then return end
    if f.lastSeq == seq and now - (f.lastSeqAt or 0) < 10 then return end
    f.lastSeq, f.lastSeqAt = seq, now
    group, map, x, y, facing, gid = tonumber(group), tonumber(map), tonumber(x), tonumber(y), tonumber(facing), tonumber(gid)
    if group > 255 or map > 255 or x > 4000 or y > 4000 or facing < 1 or facing > 4 or gid > 1023 or #events > 240 or (tonumber(state) or 0) > 3 then return end
    if not f.spelling and not f.stranger then f.spelling = sender end
    f.heard, f.got = now, (f.got or 0) + 1
    local g = ghosts[key]
    if not g then
        g = { name = f.name, moves = {}, firstSeen = now }
        ghosts[key] = g
    end
    g.stranger = f.stranger
    local was = g.state
    if g.gid ~= gid or was ~= (tonumber(state) or 0) then dirty = true end    -- (a mark or a picture changed: paint again)
    g.heard, g.gid, g.family, g.state = now, gid, fam, tonumber(state) or 0
    if g.state == 3 then ghosts[key] = nil dirty = true return end         -- (they left: gone at once)
    local mapKey = placeKey(fam, group, map)
    -- this packet's moves, timed from when they happened
    local base = now + DELAY
    local list, cx, cy, i = {}, x, y, 1
    while i <= #events do
        local k = events:sub(i, i)
        if DIRS[k] then
            local ago, len = dec(events:sub(i + 1, i + 2)), dec(events:sub(i + 3, i + 3))
            if not (ago and len) then break end
            local d = DIRS[k]
            list[#list + 1] = { t = base - ago / 60, len = math.max(1, len) / 60, x1 = cx, y1 = cy, x2 = cx + d[1], y2 = cy + d[2], facing = d[3], key = mapKey }
            cx, cy = cx + d[1], cy + d[2]
            i = i + 4
        elseif k == "t" then
            local fc, ago = tonumber(events:sub(i + 1, i + 1)), dec(events:sub(i + 2, i + 3))
            if not (fc and ago) or fc < 1 or fc > 4 then break end
            list[#list + 1] = { t = base - ago / 60, len = 0, x1 = cx, y1 = cy, x2 = cx, y2 = cy, facing = fc, key = mapKey }
            i = i + 4
        else break end
    end
    -- keep the spacing, but never before now or before the moves already waiting
    prune(g, now)
    local last = g.moves[#g.moves]
    local earliest = math.max(now + 0.05, last and (last.t + last.len) or 0)
    local first = list[1] and list[1].t or earliest
    local shift = (first < earliest) and (earliest - first) or 0
    for _, mv in ipairs(list) do mv.t = mv.t + shift end
    -- where the moves we have end: if not this packet's starting tile (a packet lost, a door, a jump), go there
    local ex, ey, ek = (last and last.x2) or g.sx, (last and last.y2) or g.sy, (last and last.key) or g.skey
    if ex ~= x or ey ~= y or ek ~= mapKey then
        g.moves[#g.moves + 1] = { t = list[1] and list[1].t or earliest, len = 0, x1 = x, y1 = y, x2 = x, y2 = y, facing = facing, key = mapKey }
    end
    for _, mv in ipairs(list) do
        local prev = g.moves[#g.moves]
        if prev and mv.t < prev.t + prev.len then mv.t = prev.t + prev.len end
        g.moves[#g.moves + 1] = mv
    end
    if f.stranger then
        -- (players from the realm come and go without a word)
    elseif not f.told then
        f.told = true
        Print(("%s is sharing their walk with you. Meet them on the same map; /mb link %s to trade or battle."):format(f.name, f.name))
    elseif me and me.map and mapKey ~= myKey(me) and g.lastKey ~= mapKey and now - (g.saidAway or 0) > 20 then
        g.saidAway = now
        Print(("%s is on another map right now."):format(f.name))
    end
    g.lastKey = mapKey
end

-- where a ghost is now (in pixels in its map), its facing, its picture, and which map it is on
local function place(g, now)
    prune(g, now)
    local mv = g.moves[1]
    if not mv then return nil end
    if now < mv.t then                            -- (the next move has not begun: where the last one left it)
        if not g.skey then return nil end
        return g.sx * 16, g.sy * 16, STAND[g.sf or 1] or 0, g.sf == 4, g.skey, g.sf or 1, g.sx, g.sy, g.sx, g.sy
    end
    g.sx, g.sy, g.sf, g.skey = mv.x2, mv.y2, mv.facing, mv.key
    local p = (mv.len > 0) and math.min(1, (now - mv.t) / mv.len) or 1
    local px = floor((mv.x1 + (mv.x2 - mv.x1) * p) * 16 + 0.5)
    local py = floor((mv.y1 + (mv.y2 - mv.y1) * p) * 16 + 0.5)
    local frame = STAND[mv.facing] or 0
    if p < 0.5 and (mv.x1 ~= mv.x2 or mv.y1 ~= mv.y2) then
        if mv ~= g.lastMove then g.stepNo, g.lastMove = (g.stepNo or 0) + 1, mv end
        frame = WALK[mv.facing][(g.stepNo % 2) + 1]
        if kind == "gb" then                      -- (Game Boy: one walking frame, mirrored every other step up and down)
            frame = mv.facing == 1 and 3 or mv.facing == 2 and 4 or 5
            local flip = mv.facing == 4 or (mv.facing <= 2 and g.stepNo % 2 == 1)
            if p >= 1 then return px, py, frame, flip, mv.key, mv.facing, mv.x2, mv.y2, mv.x2, mv.y2 end
            return px, py, frame, flip, mv.key, mv.facing, mv.x1, mv.y1, mv.x2, mv.y2
        end
    end
    if p >= 1 then return px, py, frame, mv.facing == 4, mv.key, mv.facing, mv.x2, mv.y2, mv.x2, mv.y2 end
    return px, py, frame, mv.facing == 4, mv.key, mv.facing, mv.x1, mv.y1, mv.x2, mv.y2
end

-- ---- pictures: every trainer's picture, from the game's own list (found once per game, from my own picture) ----
-- My trainer's frame on screen is found in the game; the frame table that holds it, the picture record that holds
-- the table (its "images" field, +0x1C), and the long list of records that holds that record (index = the
-- picture number every moving object carries, +5 in its entry) follow by pointers. Palettes: my colors on screen
-- are found the same way, in the game's list of (colors, tag) pairs; a record names its palette by tag (+2).
-- (lab/ghosts/chase2.py is the reference; checked on all five games.)
local romSize, bankSize
local function romByte(a) local b = m.romBanks[floor(a / bankSize) + 1] return b and b:byte(a % bankSize + 1) or 0 end
local function romU16(a) return romByte(a) + romByte(a + 1) * 256 end
local function romU32(a) return romU16(a) + romU16(a + 2) * 65536 end
local function isPtr(a) local v = romU32(a) return v >= 0x08000000 and v < 0x08000000 + romSize end
local function romFind(pat)                      -- every place pat is in the game (yields now and then inside the sheet job)
    local out, n = {}, #pat
    for b = 1, math.ceil(romSize / bankSize) do
        if coroutine.running() and sheetJob then
            yieldBanks = yieldBanks + 1
            if yieldBanks >= 64 then yieldBanks = 0 coroutine.yield() end     -- (about 1 MB a step)
        end
        local bank = m.romBanks[b]
        if bank then
            local at = bank:find(pat, 1, true)
            while at do out[#out + 1] = (b - 1) * bankSize + at - 1 at = bank:find(pat, at + 1, true) end
            local nxt = m.romBanks[b + 1]
            if nxt and n > 1 then                -- (across the join with the next piece)
                local seam = bank:sub(-(n - 1)) .. nxt:sub(1, n - 1)
                local at2 = seam:find(pat, 1, true)
                while at2 do out[#out + 1] = b * bankSize - (n - 1) + at2 - 1 at2 = seam:find(pat, at2 + 1, true) end
            end
        end
    end
    return out
end
local function le32(v) return string.char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256) end
local function words(v)                          -- 4-byte-aligned words equal to v
    local out = {}
    for _, a in ipairs(romFind(le32(v))) do if a % 4 == 0 then out[#out + 1] = a end end
    return out
end
local function buildPictures(sheet, palBytes)
    for _, e in ipairs(words(0x08000000 + sheet)) do
        for _, f in ipairs(words(0x08000000 + e)) do
            local r = f - 0x1C
            for _, L in ipairs(words(0x08000000 + r)) do
                local st = L
                while st >= 4 and isPtr(st - 4) do st = st - 4 end
                local n = 0
                while isPtr(st + 4 * n) do n = n + 1 end
                if n >= 100 then
                    local tag, pals = romU16(r + 2), {}
                    for _, P in ipairs(romFind(palBytes)) do      -- (the same colors may be in the game several times)
                        for _, pe in ipairs(words(0x08000000 + P)) do
                            if romU16(pe + 4) == tag then
                                local a = pe
                                while a >= 8 and isPtr(a - 8) and romU16(a - 4) ~= 0 do a = a - 8 end
                                while isPtr(a) do pals[romU16(a + 4)] = romU32(a) - 0x08000000 a = a + 8 end
                                break
                            end
                        end
                        if next(pals) then break end
                    end
                    return { list = st, n = n, pals = pals, mine = (L - st) / 4 }
                end
            end
        end
    end
end
-- The search scans the whole game several times over. So that nothing freezes, it runs as a coroutine that yields
-- after every piece of the game it looks through, a few steps per emulated frame (G.Frame), and the overlay just
-- asks whether it is done.
local function startSheetJob()
    local s = me
    if not (s and s.x) then return end
    local group, map, x, y, px, py, facing = readMe()
    if not group or x ~= px or y ~= py or not STAND[facing] then return end         -- (standing still: the frame is known)
    for i = 0, 127 do
        local a0, a1, a2 = oam(i, 0), oam(i, 1), oam(i, 2)
        if a0 % 256 == 56 and a1 % 512 == 112 and floor(a0 / 16384) == 2 and floor(a1 / 16384) == 2 then
            romSize, bankSize = m.romSize, m.bankSize
            local function block(base, n)
                local t = {}
                for k = 0, n - 1 do t[k + 1] = string.char(m.rd8(base + k)) end
                return table.concat(t)
            end
            local frame, palBytes, stand = block(0x06010000 + (a2 % 1024) * 32, 256), block(0x05000200 + floor(a2 / 4096) * 32, 32), STAND[facing]
            sheetJob = coroutine.create(function()
                local found = romFind(frame)[1]
                if not found then return nil end
                sheetAt = found - 256 * stand
                return buildPictures(sheetAt, palBytes)
            end)
            return
        end
    end
end
function stepSheetJob()
    if sheetFor == m or not sheetJob then return end
    yieldBanks = 0
    local ok, p = coroutine.resume(sheetJob)
    if not ok then sheetFor, sheetJob = m, nil return end
    if coroutine.status(sheetJob) == "dead" then
        sheetFor, sheetJob, pics = m, nil, p or nil
        if pics then G.lookup = { list = pics.list, n = pics.n, mine = pics.mine } end
    end
end
local function findSheet()
    if sheetFor == m then return pics end
    if not sheetJob then startSheetJob() end
    return nil
end

-- a picture in the game: 8x8 pieces in order, 4 bits a dot (0: see-through); colors: 16 15-bit colors at pal
function decode4(fp, w, h, pal, flip)
    local colors = {}
    for i = 1, 15 do colors[i] = romU16(pal + 2 * i) end
    local dots, tw = {}, w / 8
    for t = 0, w * h / 64 - 1 do
        local tx, ty = t % tw, floor(t / tw)
        for r = 0, 7 do
            for col = 0, 7 do
                local b = romByte(fp + t * 32 + r * 4 + floor(col / 2))
                local n = (col % 2 == 0) and (b % 16) or floor(b / 16)
                if n > 0 then
                    local x = tx * 8 + col
                    if flip then x = w - 1 - x end
                    dots[(ty * 8 + r) * w + x] = colors[n]
                end
            end
        end
    end
    return dots
end
local pixCache = {}       -- picture, frame and mirror -> { w, h, dots = { index -> color (15 bits) } } (false: none)
local function framePixels(gid, k, flip)
    local key = gid * 64 + k * 2 + (flip and 1 or 0)
    local c = pixCache[key]
    if c ~= nil then return c or nil end
    c = false
    if pics and gid >= 0 and gid < pics.n then
        local rec = romU32(pics.list + 4 * gid) - 0x08000000
        local w, h, tag = romU16(rec + 8), romU16(rec + 10), romU16(rec + 2)
        local images = romU32(rec + 0x1C) - 0x08000000
        local fp, size = romU32(images + 8 * k) - 0x08000000, romU32(images + 8 * k + 4)
        local pal = pics.pals[tag]
        if pal and size == w * h / 2 and w <= 64 and h <= 64 and w % 8 == 0 and h % 8 == 0 then
            c = { w = w, h = h, dots = decode4(fp, w, h, pal, flip), pal = pal }
        end
    end
    pixCache[key] = c
    return c or nil
end

-- ---- the game's own extras for a trainer: grass blades over one in tall grass, the Pokemon under one surfing ----
local extras              -- false: not for this copy; else { grass = dots (16x16), blob = address, cache = {} }
local function sumAt(a, n) local h = 0 for i = a - 0x08000000, a - 0x08000000 + n - 1 do h = (h * 31 + romByte(i)) % 2147483647 end return h end
local function getExtras()
    if extras ~= nil then return extras end
    extras = false
    local p = PICTURES[code() .. m.rd8(0x080000BC)]
    if p and sumAt(p.grass, 128) == p.grassSum and sumAt(p.pal, 32) == p.palSum then
        extras = { grass = decode4(p.grass - 0x08000000, 16, 16, p.pal - 0x08000000, false), cache = {} }
        if sumAt(p.blob, 3 * 512) == p.blobSum then extras.blob = p.blob - 0x08000000 end
    end
    return extras
end
-- the Pokemon a friend surfs on, in the colors of their own picture: frame 0 down, 1 up, 2 left (right: mirrored)
local BLOB_FRAME = { [1] = 0, [2] = 1, [3] = 2, [4] = 2 }
local function blobPixels(pal, facing)
    local x = getExtras()
    if not (x and x.blob and pal) then return nil end
    local key = pal * 8 + facing
    local c = x.cache[key]
    if c == nil then
        c = { w = 32, h = 32, dots = decode4(x.blob + BLOB_FRAME[facing] * 512, 32, 32, pal, facing == 4) }
        x.cache[key] = c
    end
    return c
end
-- the tile behavior at a place on my map (the game's own map grid, around me)
local function rd32(a) return rd16(a) + rd16(a + 2) * 65536 end
local function behaviorAt(x, y)
    local G0 = prof.grid
    local w, h = rd32(G0), rd32(G0 + 4)
    if x < 0 or y < 0 or x >= w or y >= h or w > 400 or h > 400 then return nil end
    local cell = rd16(rd32(G0 + 8) + 2 * (x + y * w)) % 1024
    if cell == 1023 then return nil end
    local lay = rd32(prof.header)
    local first = cell < prof.primary
    local set = rd32(lay + (first and 0x10 or 0x14))
    local a = rd32(set + prof.attrOff) + prof.attrSize * (first and cell or cell - prof.primary)
    local v = prof.attrSize == 2 and rd16(a) or rd32(a)
    return v % prof.behavior
end
G.BehaviorAt = function(x, y) return kind == "gba" and prof and m and behaviorAt(x, y) end

-- ---- the Game Boy games' pictures and screen ----
-- A trainer's picture: 2 bits a dot, four 8x8 pieces a frame (top left, top right, bottom left, bottom right), six
-- frames (standing down, up, left; walking down, up, left), from the cartridge. The dots keep the color's number
-- (1-3; 0 is see-through) and are colored when drawn, with the game's sprite colors of the moment.
local gbPics              -- false: this copy failed the check; else { [picture number] = { bank, address, palette } }
local function romSum(b, a, n) local h = 0 for i = 0, n - 1 do h = (h * 31 + m.peekRom(b, a + i)) % 2147483647 end return h end
local function gbPictures()
    if gbPics ~= nil then return gbPics end
    gbPics = false
    if prof.gen == 1 then
        local t = {}
        for i, p in ipairs(prof.pics) do
            if romSum(p[1], p[2], 6 * 64) ~= p[3] then return gbPics end
            t[i - 1] = { p[1], p[2], 0 }
        end
        gbPics = t
    else
        local b, a, sum = prof.sprites[1], prof.sprites[2], prof.sprites[3]
        if romSum(b, a, 6 * 102) ~= sum then return gbPics end
        gbPics = setmetatable({}, { __index = function(t, id)
            if id < 1 or id > 102 then return nil end
            local e = a + 6 * (id - 1)
            local ptr, bank, pal = m.peekRom(b, e) + m.peekRom(b, e + 1) * 256, m.peekRom(b, e + 3), m.peekRom(b, e + 5) % 8
            local v = { bank, ptr, pal }
            rawset(t, id, v)
            return v
        end })
    end
    return gbPics
end
local gbCache = {}
local function gbFrame(gid, k, flip)
    local key = gid * 64 + k * 2 + (flip and 1 or 0)
    local c = gbCache[key]
    if c ~= nil then return c or nil end
    c = false
    local P = gbPictures()
    local p = P and P[gid]
    if p and p[2] >= 0x4000 and p[2] + 6 * 64 <= 0x8000 then
        local dots = {}
        for t = 0, 3 do
            local tx, ty = t % 2, floor(t / 2)
            for r = 0, 7 do
                local base = p[2] + k * 64 + t * 16 + r * 2
                local lo, hi = m.peekRom(p[1], base), m.peekRom(p[1], base + 1)
                for col = 0, 7 do
                    local bit = 2 ^ (7 - col)
                    local n = floor(lo / bit) % 2 + 2 * (floor(hi / bit) % 2)
                    if n > 0 then
                        local x = tx * 8 + col
                        if flip then x = 15 - x end
                        dots[(ty * 8 + r) * 16 + x] = n
                    end
                end
            end
        end
        c = { w = 16, h = 16, dots = dots, slot = p[3], indexed = true }
    end
    gbCache[key] = c
    return c or nil
end
-- the colors a Game Boy picture's dots are drawn in now: Gen 2 and color Gen 1 by the picture's palette; the
-- original Game Boy games by the first sprite shades
local function gbColors(slot)
    local t = {}
    for i = 1, 3 do t[i] = m.objColor((m.cgb and slot or 0) * 4 + i) end
    return t
end
-- Gen 1's picture for my palette, in a color game: the palette my own trainer is drawn with
local function gbMySlot()
    for i = 0, 39 do
        if m.peek(0xFE00 + 4 * i) == 76 and m.peek(0xFE01 + 4 * i) == 72 then return m.peek(0xFE03 + 4 * i) % 8 end
    end
    return 0
end
-- the map is on screen: the screen on, and my trainer's picture at its place (not in a battle, a menu's own screen)
local function gbPlainMap()
    if floor(m.peek(0xFF40) / 128) % 2 == 0 then return false end
    for i = 0, 39 do
        if m.peek(0xFE00 + 4 * i) == 76 and m.peek(0xFE01 + 4 * i) == 72 then return true end
    end
    return false
end
-- text (boxes, menus) at a dot of the screen: Gen 1 draws it with picture numbers 0x60 and up (its maps use fewer),
-- Gen 2 with its text palette, 7 (its maps use 0-6); on the window layer where it is up, else the background
local function gbText()
    local lcdc = m.peek(0xFF40)
    local winOn = floor(lcdc / 32) % 2 == 1
    local wy, wx = m.peek(0xFF4A), m.peek(0xFF4B) - 7
    local bgMap = floor(lcdc / 8) % 2 == 1 and 0x9C00 or 0x9800
    local winMap = floor(lcdc / 64) % 2 == 1 and 0x9C00 or 0x9800
    local scx, scy = m.peek(0xFF43), m.peek(0xFF42)
    local gen2 = prof.gen == 2
    local seen = {}
    return function(x, y)
        local at
        if winOn and y >= wy and x >= wx and wy < 144 then at = winMap + floor((y - wy) / 8) * 32 + floor((x - wx) / 8)
        else at = bgMap + floor((y + scy) % 256 / 8) * 32 + floor((x + scx) % 256 / 8) end
        local r = seen[at]
        if r == nil then
            if gen2 and m.cgb then r = m.peekVram(1, at) % 8 == 7 else r = m.peekVram(0, at) >= 0x60 end
            seen[at] = r
        end
        return r
    end
end

-- is the game showing the map, plainly? (no fade, and my trainer drawn at the middle of the screen)
local function plainMap()
    local dispcnt = io(0)
    if floor(dispcnt / 128) % 2 == 1 then return false end            -- (screen switched off)
    local bld = io(0x50)
    if floor(bld / 64) % 4 >= 2 and io(0x54) % 32 > 0 then return false end   -- (fading in or out)
    for i = 0, 127 do
        local a0, a1 = oam(i, 0), oam(i, 1)
        local y, x = a0 % 256, a1 % 512
        if floor(a0 / 256) % 4 ~= 2 and y >= 40 and y <= 64 and x >= 100 and x <= 124 then return true end
    end
    return false
end
-- the text layer (windows, menus): which 8x8 cells of the screen it covers
local function textCells()
    if floor(io(0) / 256) % 2 == 0 then return nil end
    local cnt = io(8)
    local base = 0x06000000 + floor(cnt / 256) % 32 * 2048
    local h, v = io(0x10) % 512, io(0x12) % 512
    local seen = {}
    return function(x, y)
        local cx, cy = floor(x / 8), floor(y / 8)
        local key = cy * 32 + cx
        local r = seen[key]
        if r == nil then
            local mx, my = floor((cx * 8 + h) / 8) % 32, floor((cy * 8 + v) / 8) % 32
            r = rd16(base + (my * 32 + mx) * 2) % 1024 ~= 0
            seen[key] = r
        end
        return r
    end
end
-- the map's top layer (BG1 in all five games, drawn above trainers: tree tops, roof edges): is its dot here solid?
local function topLayer()
    if floor(io(0) / 512) % 2 == 0 then return nil end              -- (BG1 off)
    local cnt = io(0x0A)
    if cnt % 4 >= 2 or floor(cnt / 128) % 2 == 1 then return nil end  -- (not above trainers; or 256 colors: not handled)
    local cb, mb, size = floor(cnt / 4) % 4 * 0x4000, floor(cnt / 256) % 32 * 0x800, floor(cnt / 16384)
    local h, v = io(0x14) % 512, io(0x16) % 512
    local wide, tall = size % 2 == 1, size >= 2
    local rows = {}
    return function(x, y)
        local X, Y = (x + h) % (wide and 512 or 256), (y + v) % (tall and 512 or 256)
        local blk = floor(X / 256) + floor(Y / 256) * (wide and 2 or 1)
        local e = rd16(0x06000000 + mb + blk * 0x800 + (floor((Y % 256) / 8) * 32 + floor((X % 256) / 8)) * 2)
        local px, py = X % 8, Y % 8
        if floor(e / 1024) % 2 == 1 then px = 7 - px end
        if floor(e / 2048) % 2 == 1 then py = 7 - py end
        local rk = (e % 1024) * 8 + py
        local row = rows[rk]
        if not row then
            local a = 0x06000000 + cb + (e % 1024) * 32 + py * 4
            row = { m.rd8(a), m.rd8(a + 1), m.rd8(a + 2), m.rd8(a + 3) }
            rows[rk] = row
        end
        local b = row[floor(px / 2) + 1]
        return ((px % 2 == 0) and (b % 16) or floor(b / 16)) ~= 0
    end
end

local over, lines, oldLines = {}, {}, {}
local labels = {}         -- the ghosts drawn in the last picture: { x, y (the dot above their head), name }, for GB/Console.lua
G.labels = labels
function myKey(s) return placeKey(prof.family, s.group, s.map) end
-- for the painter (GB/Console.lua): dots to show instead of the game's, and the lines to look at again
function G.Overlay(machine)
    for k in pairs(labels) do labels[k] = nil end
    if not on or machine ~= m or not prof then
        dirty = false
        if next(oldLines) then local l = oldLines oldLines = {} over = {} return over, l end
        return nil
    end
    local now = GetTime()
    for k in pairs(over) do over[k] = nil end
    local had = oldLines
    lines = {}                                    -- (a fresh table: the old one is kept as "had" until the painter has used it)
    local s = me
    local cam, C = s and (s.camShown or s.cam), s and (s.CShown or s.C)
    local plain, pictures, picture
    if kind == "gb" then plain, pictures, picture = gbPlainMap, gbPictures, gbFrame
    else plain, pictures, picture = plainMap, findSheet, framePixels end
    if s and C and s.map and plain() and pictures() then
        local myx, myy = cam[1] - C[1], cam[2] - C[2]
        local mk = myKey(s)
        local text, top
        local list = {}
        -- (the player I am linked with is drawn by the game itself, in the link rooms: no second picture of them)
        local ses = MB.Link.Session and MB.Link.Session()
        local partner = ses and ses.state == "linked" and ses.partner
        for key, g in pairs(ghosts) do
            if now - (g.heard or 0) > FORGET then ghosts[key] = nil
            elseif partner and MB.Link.NameIs(g.name, partner) then
                -- (kept in mind, not drawn)
            else
                local px, py, frame, flip, gk, facing, x1, y1, x2, y2 = place(g, now)
                if px and gk == mk then
                    list[#list + 1] = { px = px, py = py, frame = frame, flip = flip, gid = g.gid or 0, name = g.name, facing = facing,
                                        x1 = x1, y1 = y1, x2 = x2, y2 = y2, state = g.state, stranger = g.stranger }
                end
            end
        end
        if #list > REALM_DRAW then            -- (a crowd: friends first, then the nearest)
            for _, g in ipairs(list) do g.far = (g.stranger and 100000 or 0) + math.abs(g.px - myx) + math.abs(g.py - myy) end
            table.sort(list, function(a, b) return a.far < b.far end)
            for i = #list, REALM_DRAW + 1, -1 do list[i] = nil end
        end
        table.sort(list, function(a, b) return a.py < b.py end)        -- (the one further down is drawn on top)
        -- my own trainer stays in front: the dots of my picture are kept
        local mine = #list > 0 and picture(s.gid or (pics and pics.mine) or 0, STAND[s.facing or 1] or 0, s.facing == 4)
        local mw, mh = mine and mine.w or 16, mine and mine.h or BASEH
        local mx0, my0 = AX - (mw - 16) / 2, AY - (mh - BASEH)
        if #list > 0 then
            if kind == "gb" then text = gbText() else text, top = textCells(), topLayer() end
        end
        local function put(x, y, color)
            if x >= 0 and x < SW and y >= 0 and y < SH then
                local behindMe = mine and x >= mx0 and x < mx0 + mw and y >= my0 and y < my0 + mh and mine.dots[(y - my0) * mw + (x - mx0)]
                if not behindMe and not (text and text(x, y)) and not (top and top(x, y)) then
                    over[y * SW + x + 1] = color
                    lines[y + 1] = true
                end
            end
        end
        local bob = -floor(now * 15) % 8                  -- (the surf bob: a dot every 4 frames, up 4 and back down)
        bob = -(bob <= 4 and bob or 8 - bob)
        local xs = #list > 0 and kind == "gba" and getExtras()
        local mySlot = #list > 0 and kind == "gb" and prof.gen == 1 and m.cgb and gbMySlot()
        for _, g in ipairs(list) do
            local pic = picture(g.gid, g.frame, g.flip) or picture((pics and pics.mine) or s.gid or 0, g.frame, g.flip)
            if pic then
                local w = pic.w
                local sx, sy = AX + g.px - myx - (w - 16) / 2, AY + g.py - myy - (pic.h - BASEH)
                local surf = kind == "gba" and SURFING[prof.family][g.gid]
                local lut = pic.indexed and gbColors(mySlot or pic.slot)
                if surf then sy = sy + bob end
                if sx > -w and sx < SW and sy > -pic.h - 8 and sy < SH then
                    if MB.Opt("ghostNames", true) or g.state == 1 or g.state == 2 then
                        local name = MB.Link.Short(g.name)
                        if g.state == 1 then name = name .. " (in a battle)" elseif g.state == 2 then name = name .. " (paused)" end
                        labels[#labels + 1] = { x = sx + w / 2, y = sy - (pic.h - BASEH) - 2, name = name }
                    end
                    -- the Pokemon under a surfing friend first (the game puts it 8 dots below the trainer's picture)
                    local blob = surf and blobPixels(pic.pal, g.facing or 1)
                    if blob then
                        for k, color in pairs(blob.dots) do put(sx + k % 32, sy + 8 + floor(k / 32), color) end
                    end
                    -- tall grass: the game's blades over the part of the trainer on a grass tile (the one it stands on,
                    -- and the one it is leaving)
                    local g1 = xs and xs.grass and prof.tallGrass[behaviorAt(g.x2, g.y2) or -1] and (g.x2 * 65536 + g.y2)
                    local g2 = xs and xs.grass and (g.x1 ~= g.x2 or g.y1 ~= g.y2) and prof.tallGrass[behaviorAt(g.x1, g.y1) or -1] and (g.x1 * 65536 + g.y1)
                    for k, color in pairs(pic.dots) do
                        local x, y = sx + k % w, sy + floor(k / w)
                        if lut then color = lut[color] end
                        if g1 or g2 then
                            local tx, ty = floor((x - AX + myx) / 16), floor((y - AY - BASEH + 16 + myy) / 16)
                            local t = tx * 65536 + ty
                            if t == g1 or t == g2 then
                                local blade = xs.grass[(y - (AY + BASEH - 16 + ty * 16 - myy)) * 16 + (x - (AX + tx * 16 - myx))]
                                if blade then color = blade end
                            end
                        end
                        put(x, y, color)
                    end
                end
            end
        end
    end
    local redo = {}
    for y in pairs(had) do redo[y] = true end
    for y in pairs(lines) do redo[y] = true end
    oldLines = lines
    dirty = false
    if not next(redo) then return nil end
    return over, redo
end
-- does the picture need painting again although the game's own did not change? (a ghost walking on my map)
local drawnPartner = false        -- (whom the last picture left out for being my link partner)
function G.Moving()
    if dirty then return true end
    local ses = MB.Link.Session and MB.Link.Session()
    local partner = ses and ses.state == "linked" and ses.partner or false
    if partner ~= drawnPartner then drawnPartner = partner return true end     -- (a link began or ended: paint again)
    if not on or not me or not me.map then return false end
    local now, mk, busy = GetTime(), myKey(me), false
    for key, g in pairs(ghosts) do
        if now - (g.heard or 0) > FORGET then
            ghosts[key] = nil
            if g.skey == mk then busy = true end           -- (one last paint, without it)
        else
            prune(g, now)
            local mv = g.moves[1]
            if mv and (g.skey == mk or mv.key == mk) and (now < mv.t + mv.len + 0.05 or (g.moves[2] and g.moves[2].t <= now + 0.05)) then busy = true end
        end
    end
    return busy
end

-- A pressed while my trainer faces a friend's ghost on the next tile: in Emerald, FireRed and LeafGreen, offer a trade
-- right there (GBA/Trade3.lua); in the other games, say how to trade or battle with them
local DIR_OF = { [1] = { 0, 1 }, [2] = { 0, -1 }, [3] = { -1, 0 }, [4] = { 1, 0 } }
function G.Pressed(button)
    if not on or not prof or not me or not me.map then return end
    local d = DIR_OF[me.facing or 0]
    if not d then return end
    local mk, tx, ty = myKey(me), me.x + d[1], me.y + d[2]
    for _, g in pairs(ghosts) do
        if g.skey == mk and g.sx == tx and g.sy == ty then
            if not g.toldAt or GetTime() - g.toldAt > 10 then
                g.toldAt = GetTime()
                local T3 = MB.Trade3
                if kind == "gba" and T3 and T3.Supported() and MB.Friends and MB.Friends.Ask then
                    local name = g.name
                    local s = MB.Link.Session and MB.Link.Session()
                    local linked = s and s.state == "linked" and MB.Link.NameIs(s.partner, name)
                    MB.Friends.Ask("together", ("|cffffd100%s|r is here.\nTrade Pokemon or battle right where you stand?%s"):format(name,
                        linked and "" or " (MekkaBoy links you first: they get a pop-up.)"), "Trade", "Not now", function() T3.Request(name) end, nil, 30,
                        "Battle", function() T3.Request(name, nil, "battle") end)
                else
                    Print(("This is %s. To trade or battle: /mb link %s (they answer with /mb link), then both of you go to the link desk."):format(g.name, g.name))
                end
            end
            return
        end
    end
end

-- something in here went wrong (GB/Console.lua calls these under pcall): switch ghosts off rather than the game
function G.Fail(err)
    if failed then return end
    if not G.failing then G.failing = true pcall(G.SayBye) G.failing = nil end
    failed, on, dirty = true, false, true
    for k in pairs(labels) do labels[k] = nil end
    Print("Together hit an error and switched off (the game is fine): " .. tostring(err))
end

-- leaving: one last word, so that friends stop drawing me at once (game closed, Together off, logging out)
function G.SayBye()
    local s = me
    if not (on and prof and s and s.map) then return end
    s.state = 3
    packet(s, true)
    s.state, s.ranAt = 0, nil                    -- (only that packet says goodbye)
end
-- paused: the console stopped running the game (paused, hidden): friends see me standing, marked, and keep me
do
    local tick = CreateFrame("Frame")
    tick:SetScript("OnUpdate", function()
        local s = me
        if not (on and prof and s and s.map and s.ranAt) then return end
        local now = GetTime()
        if now - s.ranAt < 0.75 then return end
        if s.state ~= 2 and s.state ~= 3 then s.state = 2 packet(s, true) end
        if now - s.aliveAt >= KEEP_ALIVE then packet(s, true) end
    end)
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGOUT")
    ev:SetScript("OnEvent", function() pcall(G.SayBye) end)
end

-- the console tells us which machine is running
function G.MachineChanged(machine, sysKind)
    pcall(G.SayBye)
    m, prof, me, sheetFor, sheetAt, pixCache, pics, kind = nil, nil, nil, nil, nil, {}, nil, nil
    gbPics, gbCache = nil, {}
    ghosts = {}
    for k in pairs(labels) do labels[k] = nil end
    sheetJob = nil
    if not machine then return end
    if sysKind == "gb" and machine.peekRom then
        -- a Game Boy game: known by the cartridge's title and version byte
        local t = {}
        for a = 0x134, 0x142 do local b = machine.peekRom(0, a) if b == 0 then break end t[#t + 1] = string.char(b) end
        local p = GB_PROFILES[table.concat(t) .. "/" .. machine.peekRom(0, 0x14C)]
        if not p then return end
        m, prof, kind = machine, p, "gb"
        SW, SH, AX, AY, BASEH = 160, 144, 64, 60, 16
        me = newMe()
        return
    end
    if sysKind ~= "gba" or not machine.romBanks then return end
    m = machine
    romSize, bankSize, extras = m.romSize, m.bankSize, nil
    local p = PROFILES[code()]
    if not p then return end
    prof, kind = p, "gba"
    SW, SH, AX, AY, BASEH = 240, 160, 112, 56, 32
    me = newMe()
end

-- ---- friends ----
local function saved() local db = MB.DB() db.ghostFriends = db.ghostFriends or {} return db.ghostFriends end
-- Who answered: the friends kept from earlier sessions are told about in one line, once all of them have answered or
-- been asked four times (about a minute); a friend just added, or one who comes online later, gets a line of their own.
local roll = { yes = {}, no = {} }
local NOT_REACHED = "offline, the other faction, or a MekkaBoy older than 0.16.1"
local function names(list)
    if #list <= 4 then
        if #list == 1 then return list[1] end
        return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
    end
    return table.concat(list, ", ", 1, 3) .. (" and %d more"):format(#list - 3)
end
local function flushRoll()
    if roll.done then return end
    roll.done = true
    local yes, no = roll.yes, roll.no
    table.sort(yes) table.sort(no)
    if #yes == 0 and #no == 0 then return end
    local line = "Together: "
    if #yes > 0 then line = line .. "your walk reaches " .. names(yes) .. "." end
    if #no > 0 then
        line = line .. (#yes > 0 and " Not answering yet (" or "no friends answering yet (") .. NOT_REACHED .. "): "
            .. names(no) .. ". /mb together why shows each one."
    end
    Print(line)
end
local function heard(f, yes)
    if f.fresh or roll.done then
        if yes then Print(("%s's MekkaBoy answered: your walk reaches them."):format(f.name))
        else Print(("%s has not answered yet: %s. Your walk is not reaching them."):format(f.name, NOT_REACHED)) end
        return
    end
    if yes then        -- (answered after all, before the line went out)
        for i = #roll.no, 1, -1 do if roll.no[i] == f.name then table.remove(roll.no, i) end end
    end
    local list = yes and roll.yes or roll.no
    list[#list + 1] = f.name
    if not roll.started then
        roll.started = true
        if C_Timer and C_Timer.After then C_Timer.After(75, flushRoll) end     -- (in case someone is never settled)
    end
    for _, o in pairs(friends) do
        if o.askedAt and not o.fresh and not (o.saidYes or o.saidNo) then return end
    end
    flushRoll()
end
function G.Ask(f)
    f.askedAt = GetTime()
    f.asks = (f.asks or 0) + 1
    if f.asks == 4 and not f.spelling and not f.saidNo then
        f.saidNo = true
        heard(f, false)
    end
    MB.Link.Resolve(f.name, function(spelling, theirs)
        local first = not f.spelling
        f.spelling, f.asks = spelling, 0
        local k = MB.Link.Plain(theirs)
        if not friends[k] then alias[k] = MB.Link.Plain(f.name) end    -- (their messages carry this spelling)
        if first and not f.saidYes then
            f.saidYes = true
            heard(f, true)
        end
    end, f.unit)
    f.unit = nil
end
local function addFriend(name, unit)
    local key = MB.Link.Plain(name)
    local f = friends[key] or { name = name }
    friends[key] = f
    saved()[key] = name
    f.unit, f.fresh = unit, true          -- (just added: told about on their own)
    G.Ask(f)
    return f
end
MB.onLogin[#MB.onLogin + 1] = function()
    for key, name in pairs(MB.DB().ghostFriends or {}) do friends[key] = { name = name } end
    if MB.Opt("ghosts", false) and (next(friends) or realmShow()) then on = true end         -- (as you left it last time)
end

-- ---- the realm ----
local function chanNumber()
    if not GetChannelName then return 0 end
    local n = GetChannelName(REALM_CHANNEL)
    return type(n) == "number" and n or 0
end
local function ourChannel(name) return type(name) == "string" and name:lower():find(REALM_CHANNEL:lower(), 1, true) ~= nil end
local function hideChannel()          -- (it carries hidden messages only: kept out of every chat window)
    if not ChatFrame_RemoveChannel then return end
    for i = 1, (NUM_CHAT_WINDOWS or 1) do
        local cf = _G and _G["ChatFrame" .. i] or (i == 1 and DEFAULT_CHAT_FRAME)
        if cf then pcall(ChatFrame_RemoveChannel, cf, REALM_CHANNEL) end
    end
end
-- in the channel while the realm is chosen and a game Together knows has been started (then kept until switched off)
function G.RealmTick()
    local now = GetTime()
    realm.num = chanNumber()
    local want = on and realmShow()
    if want and (prof or realm.mine) then
        if realm.num == 0 and JoinTemporaryChannel and now - (realm.joinAt or -99) > 15 then
            realm.joinAt, realm.joins, realm.mine, realm.hidden = now, realm.joins + 1, true, false
            pcall(JoinTemporaryChannel, REALM_CHANNEL)
            realm.num = chanNumber()
        end
        if realm.num > 0 and not realm.hidden then hideChannel() realm.hidden = true end
    elseif not want and realm.mine and realm.num > 0 then
        if LeaveChannelByName then pcall(LeaveChannelByName, REALM_CHANNEL) end
        realm.mine, realm.num = false, 0
    end
    for k, f in pairs(strangers) do
        if now - (f.heard or 0) > 120 then strangers[k] = nil end
    end
end
do
    local t, wait = CreateFrame("Frame"), 0
    t:SetScript("OnUpdate", function(_, e)
        wait = wait - (e or 0)
        if wait > 0 then return end
        wait = 2
        pcall(G.RealmTick)
    end)
    if ChatFrame_AddMessageEventFilter then          -- (the channel's join and leave notices stay out of chat too)
        local function quiet(_, _, _, _, _, chanString, _, _, _, _, chanName)
            return ourChannel(chanName) or ourChannel(chanString)
        end
        for _, e in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL" }) do
            ChatFrame_AddMessageEventFilter(e, quiet)
        end
    end
end
function G.RealmLine()
    if not MB.Alpha() then return "Realm: not in this version (friends you add work)" end
    local mode = realmMode()
    if mode == nil then return "Realm: not chosen yet (you are asked when you start a game Together knows)" end
    if mode == "off" then return "Realm: off (only friends you add). /mb together realm on to play with everyone on the realm" end
    local now, players = GetTime(), 0
    for _, t in pairs(realm.heard) do if now - t < 60 then players = players + 1 end end
    local chan = realm.num > 0 and ("channel #" .. realm.num) or (realm.joins > 0 and "joining the channel" or "channel not joined yet (start a game Together knows)")
    return ("Realm: %s, %s; %d players heard in the last minute; your own messages come back: %s; sent %d%s"):format(
        mode == "watch" and "watching (you are not shown)" or "on", chan, players,
        realm.echoAt and (now - realm.echoAt < 60 and "yes" or "not lately") or "not yet", realm.sent,
        realm.refused and (" (the server refused one: " .. tostring(realm.refused) .. ")") or "")
end

local REALM_SAY = {
    on = "Playing together with the realm: other MekkaBoy players on the same map see your trainer, and you see theirs. To play on your own: /mb together realm off. To see others without being seen: /mb together realm watch.",
    watch = "Watching the realm: you see other MekkaBoy players on your map; they do not see you (friends you added still do). /mb together realm on to be seen too, /mb together realm off to see nobody from the realm.",
    off = "Playing on your own. To play with other MekkaBoy players on the realm: /mb together realm on. Friends you add with /mb together <name> still work.",
}
local function setRealm(mode, quiet)
    if mode ~= "on" and realmShare() then pcall(G.SayBye) end    -- (no longer shown: the goodbye goes out while it still can)
    MB.DB().opt.realm = mode
    if mode ~= "off" then on, failed = true, false MB.DB().opt.ghosts = true end
    if mode == "off" then
        for k in pairs(strangers) do ghosts[k] = nil end
        strangers = {}
    end
    dirty = true
    pcall(G.RealmTick)
    if not quiet then Print(REALM_SAY[mode]) end
end

-- The first time a game Together knows starts: one question, before the game runs.
local question
local function ask(resume)
    if not question then
        local parent = MB.window or UIParent
        local q = CreateFrame("Frame", nil, parent)
        q:SetSize(330, 150)
        q:SetPoint("CENTER", parent, "CENTER", 0, 20)
        q:SetFrameStrata("DIALOG")
        q:EnableMouse(true)
        local back = q:CreateTexture(nil, "BACKGROUND")
        back:SetAllPoints(q)
        back:SetColorTexture(0.08, 0.06, 0.04, 0.96)
        local edge = q:CreateTexture(nil, "BORDER")
        edge:SetPoint("TOPLEFT", q, "TOPLEFT", 2, -2)
        edge:SetPoint("BOTTOMRIGHT", q, "BOTTOMRIGHT", -2, 2)
        edge:SetColorTexture(0.18, 0.13, 0.07, 0.96)
        local title = q:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", q, "TOP", 0, -14)
        title:SetText("Play with others on the realm?")
        local body = q:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        body:SetPoint("TOP", title, "BOTTOM", 0, -10)
        body:SetWidth(300)
        body:SetText("Other MekkaBoy players on the same map would see your trainer walking in their game, and you would see theirs.")
        local function button(label, x, mode)
            local b = CreateFrame("Button", nil, q)
            b:SetSize(140, 26)
            b:SetPoint("BOTTOM", q, "BOTTOM", x, 14)
            local bb = b:CreateTexture(nil, "BACKGROUND")
            bb:SetAllPoints(b)
            bb:SetColorTexture(0.35, 0.24, 0.1, 0.95)
            local glow = b:CreateTexture(nil, "HIGHLIGHT")
            glow:SetAllPoints(b)
            glow:SetColorTexture(1, 0.82, 0.3, 0.25)
            local words = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            words:SetPoint("CENTER")
            words:SetText(label)
            b:SetScript("OnClick", function() G.Answer(mode) end)
            return b
        end
        q.yes = button("Yes, play together", -75, "on")
        q.no = button("No, just me", 75, "off")
        question = q
    end
    question.resume = resume
    question:Show()
end
-- the answer (the buttons, or /mb together realm on|off while the question is up): remember it, say how to change it, play
function G.Answer(mode)
    local resume = question and question.resume
    if question then question.resume = nil question:Hide() end
    setRealm(mode)
    if resume then resume() end
end
function G.Asking() return question ~= nil and question:IsShown() end
function G.Question() return question end      -- (for tests)
-- (GB/Console.lua, as a game starts: true when the question is up and the game should wait for the answer)
function G.AskFirst(resume)
    if not prof or realmMode() ~= nil then return false end
    if MB.Onboarded and not MB.Onboarded() then return false end      -- (the first-time questions answer this: UI/Onboarding.lua)
    ask(resume)
    return true
end

-- ---- which shared routes reach other players: /mb together realm probe ----
-- Every joined chat channel (the zone's General and the rest), say, yell and guild get a hidden "GP;<route>" now and then
-- for a minute; whoever hears one notes the route and the sender. Run by two players at once, it shows which routes
-- carry between players here (a custom channel came back to each player alone on this realm's beta).
local probe
local function probeRoutes()
    local r = {}
    if GetChannelList then
        local list = { GetChannelList() }
        for i = 1, #list, 3 do
            local id, name, disabled = list[i], list[i + 1], list[i + 2]
            if type(id) == "number" and type(name) == "string" and not disabled then r[#r + 1] = { "CHANNEL", id, name } end
        end
    end
    r[#r + 1] = { "SAY", nil, "say" }
    r[#r + 1] = { "YELL", nil, "yell" }
    if IsInGuild and IsInGuild() then r[#r + 1] = { "GUILD", nil, "guild" } end
    return r
end
local function probeRecord()
    local db = MB.DB()
    db.togetherProbe = db.togetherProbe or { routes = {} }
    return db.togetherProbe
end
local function probeRoute(label)
    local rec = probeRecord()
    rec.routes[label] = rec.routes[label] or { sent = 0, heardFrom = {} }
    return rec.routes[label]
end
function G.ProbeHeard(text, channel, sender)
    local label = text:match("^GP;([^;]*)")
    if not label or #label > 60 then return end
    local r = probeRoute(label)
    if MB.Link.IsMe(sender) then r.cameBack = true return end
    local first = not r.heardFrom[sender]
    r.heardFrom[sender] = (r.heardFrom[sender] or 0) + 1
    if first then Print(("Probe: heard %s on %s."):format(sender, label)) end
end
local function probeFinish()
    probe = nil
    local rec = probeRecord()
    Print("Probe finished. What each route did:")
    local names = {}
    for label in pairs(rec.routes) do names[#names + 1] = label end
    table.sort(names)
    for _, label in ipairs(names) do
        local r = rec.routes[label]
        local who = {}
        for n in pairs(r.heardFrom) do who[#who + 1] = n end
        Print(("  %s: sent %d%s; came back to you: %s; heard from others: %s"):format(label, r.sent,
            r.refused and (" (refused: " .. tostring(r.refused) .. ")") or "", r.cameBack and "yes" or "no",
            #who > 0 and table.concat(who, ", ") or "nobody"))
    end
    Print("Screenshot this (it is also saved for /reload).")
end
function G.Probe()
    if probe then Print("The probe is already running.") return end
    local rec = probeRecord()
    rec.when, rec.version, rec.routes = date and date("%Y-%m-%d %H:%M") or "", MB.VERSION, {}
    probe = { started = GetTime(), nextAt = 0, routes = probeRoutes() }
    local labels = {}
    for _, r in ipairs(probe.routes) do labels[#labels + 1] = r[3] end
    Print(("Probe: one minute, on %s. Your friend runs /mb together realm probe at the same time."):format(table.concat(labels, ", ")))
end
do
    local t = CreateFrame("Frame")
    t:SetScript("OnUpdate", function()
        if not probe then return end
        local now = GetTime()
        if now - probe.started > 60 then pcall(probeFinish) return end
        if now < probe.nextAt then return end
        probe.nextAt = now + 5
        for _, r in ipairs(probe.routes) do
            local rr = probeRoute(r[3])
            rr.sent = rr.sent + 1
            local refused = MB.Link.Send(("GP;%s;%s"):format(r[3], MB.VERSION), r[1], r[2], LANE)
            if refused then rr.refused = refused end
        end
    end)
end

local function together(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local word = rest:lower()
    if solo() and not (word == "off" or word == "why" or word == "list" or word == "help" or word:sub(1, 7) == "forget " or word:sub(1, 8) == "unblock " or word:sub(1, 6) == "block ") then
        Print("You are playing Solo, so Together is off. /mb play friends (or open) turns it back on.")
        return
    end
    if word == "realm" or word:sub(1, 6) == "realm " then
        if not MB.Alpha() then Print(NOT_YET) return end
        local what = word:sub(7)
        if what == "on" or what == "off" or what == "watch" then
            if G.Asking() then G.Answer(what) else setRealm(what) end
        elseif what == "probe" then
            G.Probe()
        elseif what == "who" then
            if realm.num > 0 and ListChannelByName then
                Print("Asking the server who is in the realm channel (the list comes in chat):")
                pcall(ListChannelByName, REALM_CHANNEL)
            else Print("Not in the realm channel yet. " .. G.RealmLine()) end
        else
            Print(G.RealmLine())
            Print("/mb together realm on | watch | off; realm who lists who the server has in the channel; realm probe tests which routes reach other players.")
        end
        return
    elseif word:sub(1, 6) == "block " or word:sub(1, 8) == "unblock " then
        local un = word:sub(1, 2) == "un"
        local name = rest:sub(un and 9 or 7):gsub("^%s+", "")
        if name == "" then Print("/mb together block <name>") return end
        local key = MB.Link.Plain(name)
        blocked()[key] = (not un) and name or nil
        if not un then ghosts[key] = nil strangers[key] = nil dirty = true end
        Print(un and ("%s is no longer blocked."):format(name) or ("%s is blocked: never drawn from the realm. /mb together unblock %s undoes it."):format(name, name))
        return
    elseif word == "off" then
        pcall(G.SayBye)
        on, dirty = false, true
        MB.DB().opt.ghosts = false
        Print("Together off: you no longer share your walk, and nobody is drawn.")
        return
    elseif word == "why" then
        Print("Together: " .. G.Why())
        Print("  " .. G.RealmLine())
        for _, line in ipairs(G.FriendLines()) do Print("  " .. line) end
        return
    elseif word == "names on" or word == "names off" then
        MB.DB().opt.ghostNames = (word == "names on")
        dirty = true
        Print(word == "names on" and "Names are shown over your friends' trainers." or "Names over your friends' trainers are off.")
        return
    elseif word == "forget" or word:sub(1, 7) == "forget " then
        local name = rest:sub(8)
        if name == "" then Print("/mb together forget <name>") return end
        local key = MB.Link.Plain(name)
        for k, f in pairs(friends) do if MB.Link.NameIs(f.name, name) or k == key then friends[k] = nil ghosts[k] = nil saved()[k] = nil end end
        dirty = true
        Print(("%s forgotten."):format(name))
        return
    elseif word == "on" or word == "" or word == "list" or word == "help" then
        local list = {}
        for _, f in pairs(friends) do list[#list + 1] = f.name end
        if #list == 0 then Print("/mb together <name> adds a friend (they add you too). Then you see each other walking in the same Pokemon game.") return end
        if word == "help" then Print("/mb together <name> adds a friend; on, off, why; names on|off; forget <name>; realm on|watch|off|who; block|unblock <name>.") return end
        if word ~= "list" then
            on, failed = true, false
            MB.DB().opt.ghosts = true
            for _, f in pairs(friends) do if not f.spelling then G.Ask(f) end end
        end
        Print(("Together %s, with: %s. Experimental. You meet friends playing a game of the same group: Red/Blue/Yellow, Gold/Silver/Crystal, FireRed/LeafGreen, Ruby/Sapphire/Emerald."):format(on and "on" or "off", table.concat(list, ", ")))
        if on and m and not prof then Print("Together does not know this game yet.") end
        return
    end
    if word == "target" then
        if not (UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target")) then Print("Target a player first.") return end
        local name = GetUnitName and GetUnitName("target", true) or UnitName("target")
        addFriend(name, "target")
        rest = name
    else
        if COMMAND_WORDS[word] or rest:find("[%c|;]") then Print("That is not a player's name.") return end
        addFriend(rest)
    end
    on, failed = true, false
    MB.DB().opt.ghosts = true
    local mine = UnitName and UnitName("player") or "you"
    local a, b = UnitName and UnitName("player")
    if type(b) == "string" and b ~= "" then mine = a .. " " .. b end
    Print(("Sharing your walk with %s, and drawing theirs once they add you (they type: /mb together %s). /mb together off stops."):format(rest, mine))
    if m and not prof then Print("Together does not know this game. It knows the Pokemon games Red/Blue/Yellow, Gold/Silver/Crystal, FireRed/LeafGreen, Ruby/Sapphire/Emerald.")
    elseif not m then Print("Start a Pokemon game (Red/Blue/Yellow, Gold/Silver/Crystal, FireRed/LeafGreen, Ruby/Sapphire/Emerald) to share your walk.") end
end
MB.AddCommand("together", "together <name>|target - walk together: see a friend's trainer in your Pokemon game (they see you once they add you too); together on|off|why; together names on|off; together forget <name>", together)
MB.AddCommand("ghosts", "", together)      -- (the old name, kept quietly so earlier notes still work)

G.PROFILES = PROFILES
function G.TopAt(x, y)    -- (for tests: is the map's top layer solid at this screen dot?)
    if not m or kind ~= "gba" then return nil end
    local top = topLayer()
    return top and top(x, y) or false
end
function G.PlayModeChanged()     -- (How I play changed: Solo says goodbye to friends at once and stops drawing them)
    if solo() then pcall(G.SayBye) ghosts, dirty = {}, true end
end
function G.Why()          -- (for tests and /mb together why: what stops friends being drawn now)
    if solo() then return "off: you are playing Solo (/mb play friends or open turns it back on)" end
    if not on then return failed and "off (after an error)" or "off" end
    if not prof then return m and "not a game Together knows" or "no Pokemon game running" end
    local s = me
    if not (s and s.map) then return "no trainer read yet" end
    if not s.C then return "camera not anchored (stand still a moment)" end
    if not (kind == "gb" and gbPlainMap or plainMap)() then return "the map is not on screen" end
    if not (kind == "gb" and gbPictures or findSheet)() then return "your trainer's picture was not found in the game" end
    local n, same, waiting = 0, 0, 0
    for _, g in pairs(ghosts) do n = n + 1 if g.skey == myKey(s) then same = same + 1 end end
    for _, f in pairs(friends) do if not f.spelling then waiting = waiting + 1 end end
    return ("ok: %d friends drawn, %d on your map (%s); %d friends not reached yet"):format(n, same, myKey(s), waiting)
end
-- one line per friend: found or not, which spelling, walk messages sent to them and heard from them
function G.FriendLines()
    local out, now = {}, GetTime()
    for _, f in pairs(friends) do
        local reach
        if not f.spelling then reach = "not found yet"
        elseif MB.Link.Unreachable(f.spelling) then reach = ("found as \"%s\", but the server just said nobody is online by that name"):format(f.spelling)
        else reach = ("found as \"%s\""):format(f.spelling) end
        out[#out + 1] = ("%s: %s; sent %d, heard %d%s%s"):format(f.name, reach, f.sent or 0, f.got or 0,
            f.heard and (" (last %d s ago)"):format(now - f.heard) or "",
            f.refused and (" (the server refused one: " .. tostring(f.refused) .. ")") or "")
    end
    table.sort(out)
    return out
end
function G.State() return { on = on, me = me, ghosts = ghosts, friends = friends, sheetAt = sheetAt, profile = prof, extras = extras } end
