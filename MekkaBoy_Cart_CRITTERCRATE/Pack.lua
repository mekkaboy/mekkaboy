-- The soundtrack of a MekkaBoy native game, made by games/gba/music.py.
if not (MekkaBoy and MekkaBoy.SoundPack) then return end
MekkaBoy.SoundPack("CRITTERCRATE", {
  game = "Critter Crate",
  engine = "native",
  dir = "Interface\\AddOns\\MekkaBoy_Cart_CRITTERCRATE\\Sound\\",
  hooks = { mailbox = 0x03007E00 },
  music = {
    ["000"] = { len = 8.571 },
    ["001"] = { len = 10.909 },
    ["002"] = { len = 8.0 },
    ["003"] = { len = 6.4 },
  },
  sfx = {
    ["001"] = { len = 0.016, mask = 1, busy = 0.016 },
    ["002"] = { len = 0.062, mask = 1, busy = 0.062 },
    ["003"] = { len = 0.125, mask = 1, busy = 0.125 },
    ["004"] = { len = 0.047, mask = 1, busy = 0.047 },
    ["005"] = { len = 0.156, mask = 1, busy = 0.156 },
    ["006"] = { len = 0.281, mask = 3, busy = 0.281 },
    ["007"] = { len = 0.25, mask = 1, busy = 0.25 },
    ["008"] = { len = 0.094, mask = 1, busy = 0.094 },
  },
  cry = {},
})
