-- The soundtrack of a MekkaBoy native game, made by games/gba/music.py.
if not (MekkaBoy and MekkaBoy.SoundPack) then return end
MekkaBoy.SoundPack("DEADMINES", {
  game = "Deadmines Hold'em",
  engine = "native",
  dir = "Interface\\AddOns\\MekkaBoy_Cart_DEADMINES\\Sound\\",
  hooks = { mailbox = 0x03007E00 },
  music = {
    ["000"] = { len = 24.0 },
    ["001"] = { len = 22.857 },
  },
  sfx = {
    ["001"] = { len = 0.062, mask = 1, busy = 0.062 },
    ["002"] = { len = 0.062, mask = 1, busy = 0.062 },
    ["003"] = { len = 0.125, mask = 1, busy = 0.125 },
    ["004"] = { len = 0.344, mask = 3, busy = 0.344, duck = true },
    ["005"] = { len = 0.25, mask = 3, busy = 0.25 },
    ["006"] = { len = 0.156, mask = 3, busy = 0.156 },
  },
  cry = {},
})
