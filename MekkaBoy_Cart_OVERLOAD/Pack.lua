-- The soundtrack of a MekkaBoy native game, made by games/gba/music.py.
if not (MekkaBoy and MekkaBoy.SoundPack) then return end
MekkaBoy.SoundPack("OVERLOAD", {
  game = "Overload",
  engine = "native",
  dir = "Interface\\AddOns\\MekkaBoy_Cart_OVERLOAD\\Sound\\",
  hooks = { mailbox = 0x03007E00 },
  music = {
    ["000"] = { len = 19.2 },
    ["001"] = { len = 20.87 },
  },
  sfx = {
    ["001"] = { len = 0.062, mask = 1, busy = 0.062 },
    ["002"] = { len = 0.062, mask = 1, busy = 0.062 },
    ["003"] = { len = 0.156, mask = 3, busy = 0.156 },
    ["004"] = { len = 0.187, mask = 3, busy = 0.187 },
    ["005"] = { len = 0.25, mask = 3, busy = 0.25 },
    ["006"] = { len = 0.344, mask = 3, busy = 0.344, duck = true },
  },
  cry = {},
})
