-- The soundtrack of a MekkaBoy native game, made by games/gba/music.py.
if not (MekkaBoy and MekkaBoy.SoundPack) then return end
MekkaBoy.SoundPack("GEARWORKS", {
  game = "Gearworks",
  engine = "native",
  dir = "Interface\\AddOns\\MekkaBoy_Cart_GEARWORKS\\Sound\\",
  hooks = { mailbox = 0x03007E00 },
  music = {
    ["000"] = { len = 9.524 },
    ["001"] = { len = 6.857 },
  },
  sfx = {
    ["001"] = { len = 0.016, mask = 1, busy = 0.016 },
    ["002"] = { len = 0.031, mask = 1, busy = 0.031 },
    ["003"] = { len = 0.094, mask = 2, busy = 0.094 },
    ["004"] = { len = 0.219, mask = 3, busy = 0.219 },
    ["005"] = { len = 0.312, mask = 3, busy = 0.312 },
  },
  cry = {},
})
