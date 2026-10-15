-- The soundtrack of a MekkaBoy native game, made by games/gba/music.py.
if not (MekkaBoy and MekkaBoy.SoundPack) then return end
MekkaBoy.SoundPack("CITYGATES", {
  game = "City Gates",
  engine = "native",
  dir = "Interface\\AddOns\\MekkaBoy_Cart_CITYGATES\\Sound\\",
  hooks = { mailbox = 0x03007E00 },
  music = {
    ["000"] = { len = 9.6 },
    ["001"] = { len = 6.4 },
  },
  sfx = {
    ["001"] = { len = 0.016, mask = 1, busy = 0.016 },
    ["002"] = { len = 0.031, mask = 1, busy = 0.031 },
    ["003"] = { len = 0.062, mask = 2, busy = 0.062 },
    ["004"] = { len = 0.125, mask = 2, busy = 0.125 },
    ["005"] = { len = 0.125, mask = 3, busy = 0.125 },
  },
  cry = {},
})
