-- The Game Boy Advance games tried so far, by the code and version each game carries. Written by dev/make_tested.py
-- from our own test runs; it holds nothing of the games themselves. status: "played" = played at length in the game
-- client; "starts" = went through our automatic check (starts, reaches the game, finds its save again) but has not
-- been played at length; "stops" = does not run yet. weight: how heavy the game is for the console, 1 (lightest) to 10; cost is
-- the measurement behind it (work per frame against the lightest game we know).
-- sound: "exact" / "shared" = a soundtrack pack can be recorded from your own game with Tools/soundpack_gba.py
-- (see the README); "own" = the game has a music program of its own and stays silent.
local _, MB = ...
MB.TestedList = {
    ["MBAA-0"] = { name = "Azeroth Adventurers", id = "ADVENTURERS", status = "played", weight = 1, cost = 0.4, chip = "sram", sound = "native", checked = "2026-10-14", version = "0.15.4" },
    ["MBGT-0"] = { name = "City Gates", id = "CITYGATES", status = "played", weight = 1, cost = 0.2, chip = "sram", sound = "native", checked = "2026-10-14", version = "0.15.4" },
    ["MBCG-0"] = { name = "Cogling", id = "COGLING", status = "played", weight = 1, cost = 0.2, chip = "sram", sound = "native", checked = "2026-10-13", version = "0.15.4" },
    ["MBCC-0"] = { name = "Critter Crate", id = "CRITTERCRATE", status = "played", weight = 1, cost = 0.5, chip = "sram", sound = "native", checked = "2026-10-14", version = "0.15.4" },
    ["MBGW-0"] = { name = "Gearworks", id = "GEARWORKS", status = "played", weight = 1, cost = 0.4, chip = "sram", sound = "native", checked = "2026-10-13", version = "0.15.4" },
    ["A4NE-0"] = { name = "Harvest Moon: Friends of Mineral Town", id = "HARVESTMOON", status = "starts", weight = 1, cost = 1.1, chip = "sram", sound = "shared", checked = "2026-10-12", version = "0.15.4" },
    ["A7KE-0"] = { name = "Kirby: Nightmare in Dream Land", id = "KIRBY", status = "starts", weight = 3, cost = 1.5, chip = "sram", sound = "shared", checked = "2026-10-12", version = "0.15.4" },
    ["AMKE-0"] = { name = "Mario Kart: Super Circuit", id = "MARIOKART", status = "starts", weight = 8, cost = 3.2, chip = "flash64", sound = "shared", checked = "2026-10-12", version = "0.15.4" },
    ["MBOV-0"] = { name = "Overload", id = "OVERLOAD", status = "played", weight = 1, cost = 0.3, chip = "sram", sound = "native", checked = "2026-10-14", version = "0.15.4" },
    ["BPEE-0"] = { name = "Pokemon Emerald", id = "EMERALD", status = "played", weight = 1, cost = 1.0, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["BPRE-0"] = { name = "Pokemon FireRed", id = "FIRERED", status = "played", weight = 2, cost = 1.2, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["BPGE-1"] = { name = "Pokemon LeafGreen", id = "LEAFGREEN", status = "played", weight = 2, cost = 1.2, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["B24E-0"] = { name = "Pokemon Mystery Dungeon: Red Rescue Team", id = "PMDRED", status = "played", weight = 8, cost = 3.4, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["AXVE-0"] = { name = "Pokemon Ruby", id = "RUBY", status = "played", weight = 1, cost = 1.0, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["AXPE-2"] = { name = "Pokemon Sapphire", id = "SAPPHIRE", status = "played", weight = 1, cost = 1.0, chip = "flash128", sound = "exact", checked = "2026-10-12", version = "0.15.4" },
    ["B3SE-0"] = { name = "Sonic Advance 3", id = "SONICADV3", status = "starts", weight = 3, cost = 1.6, chip = "flash64", sound = "shared", checked = "2026-10-12", version = "0.15.4" },
    ["AX4E-1"] = { name = "Super Mario Advance 4: Super Mario Bros. 3", id = "SMA4", status = "starts", weight = 3, cost = 1.5, chip = "flash128", sound = "own", checked = "2026-10-12", version = "0.15.4" },
    ["BZME-0"] = { name = "The Legend of Zelda: The Minish Cap", id = "MINISHCAP", status = "starts", weight = 3, cost = 1.7, chip = "eeprom", sound = "shared", checked = "2026-10-12", version = "0.15.4" },
    ["BOCE-0"] = { name = "The Urbz: Sims in the City", id = "URBZ", status = "starts", weight = 4, cost = 2.1, chip = "flash64", sound = "own", checked = "2026-10-12", version = "0.15.4" },
}
