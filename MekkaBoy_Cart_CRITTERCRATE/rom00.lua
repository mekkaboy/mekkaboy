-- A MekkaBoy Advance cartridge, written by gba2lua.py. Your own copy of a game: do not share.
local _, C = ...
if not (MekkaBoy and MekkaBoy.NewCartridge) then return end
C.banks = MekkaBoy.NewCartridge({ id = "CRITTERCRATE", name = "Critter Crate", numBanks = 72, system = "gba", size = 1179648, chip = "sram" })
