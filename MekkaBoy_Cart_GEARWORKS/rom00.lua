-- A MekkaBoy Advance cartridge, written by gba2lua.py. Your own copy of a game: do not share.
local _, C = ...
if not (MekkaBoy and MekkaBoy.NewCartridge) then return end
C.banks = MekkaBoy.NewCartridge({ id = "GEARWORKS", name = "Gearworks", numBanks = 4, system = "gba", size = 65536, chip = "sram" })
