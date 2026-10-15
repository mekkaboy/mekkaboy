#!/usr/bin/env python3
"""Builds a MekkaBoy soundtrack pack from a game you own.

WoW addons cannot produce sound themselves; they can only play sound files.
So this tool runs the game's own music program on MekkaBoy's emulator, with a
faithful model of the Game Boy sound chip, and records every song, sound
effect and cry to a file. The addon then plays the right file whenever the
game starts that song or sound.

    python3 soundpack.py "My Game.gbc"         # the game's cartridge must exist already (rom2lua.py)

Options:  --only music|sfx|cries|extras   render just one part
          --budget SECONDS                stop starting new items after this long (run again to continue)
          --jobs N                        how many processes to use
          --index                         only rebuild the cartridge's Pack.lua from what is rendered

Needs Python packages: lupa, numpy, soundfile. Restart the game client when
it is done. Supported games are listed in PROFILES below. The files it writes
are made from your own game and are for your own machine, not for sharing.
"""
import argparse
import glob
import hashlib
import json
import math
import os
import sys
import time

import numpy as np
import soundfile as sf

RATE = 44100          # sample rate of the files
OVERSAMPLE = 2        # the chip is recorded at RATE * OVERSAMPLE, then filtered down
GAIN = 1.0            # loudness of the files (1.0 = the chip's full range fills the file)
QUALITY = 0.3         # Ogg Vorbis quality, 0 (small) .. 1 (large)
HIGHPASS_HZ = 30.0    # the console's output capacitor removes the DC level
FPS = 4194304 / 70224.0

# Where each supported game's sound program lives. One entry per ROM (by SHA-1).
# "engine" names the family of sound program; the classes further down know
# how to drive each family.
GEN2_COMMON = dict(
    engine="pokecrystal", chanSize=0x32, stereoBit=5,
    # What says where in a song each music channel is: song, on/off, the
    # place in the score and where to return to, octave, loop counter,
    # tempo, instrument. When all of it comes round again the song has
    # looped. (Note timers and vibrato phase are left out on purpose:
    # they land a frame early or late from one pass to the next.)
    loopChan=(0x00, 0x01, 0x03, 0x06, 0x07, 0x08, 0x09, 0x0D, 0x0F, 0x13, 0x14, 0x18, 0x19, 0x1A, 0x2D),
    # extra cries the game makes by changing pitch and length: (pitch, length) added
    cryVariants=[(0, 0), (0, 0xC0), (0, 0x40), (-0x140, 0x60)],
    dangerPeriod=30,
)
GEN1_COMMON = dict(
    engine="pokered", stack=0xDFFD,
    PlaySound=0x23B1, FadeOutAudio=0x28CB, lowHealthAlarm=0x536E,
    banks=(0x02, 0x08, 0x1F), headers=0x4000,
    updateMusic={0x02: 0x5103, 0x08: 0x5879, 0x1F: 0x5177},
    playSound={0x02: 0x5876, 0x08: 0x6035, 0x1F: 0x58EA},
    playChannel={0x02: 0x59A3, 0x08: 0x6162, 0x1F: 0x5A17},
    maxSfx={0x02: 0xB9, 0x08: 0xE9, 0x1F: 0xC2},
    noiseEnd=0x14, cryStart=0x14, cryEnd=0x86, battleBank=0x08, battleStart=0x9D, battleEnd=0xEA,
    cryData=(0x0E, 0x5446), numCries=190, moveSounds=(0x1E, 0x58BC), numMoves=165, cryMoves=(0x2C, 0x2D),
    # sounds the battle code plays with fixed pitch and tempo: (address of header in bank 8, pitch, tempo)
    fixedBattle=[(0x41F2, 0x20, 0x30), (0x4210, 0xE0, 0xFF), (0x41F5, 0x50, 0x01), (0x41DA, 0x00, 0x00), (0x42BB, 0x00, 0x80)],
    wChannelCommandPointers=0xC006, wChannelReturnAddresses=0xC016, wChannelSoundIDs=0xC026,
    wChannelLoopCounters=0xC0BE, wChannelNoteSpeeds=0xC0C6, wChannelOctaves=0xC0D6, wMusicTempo=0xC0E8,
    wNewSoundID=0xC0EE, wAudioROMBank=0xC0EF, wAudioSavedROMBank=0xC0F0,
    wFrequencyModifier=0xC0F1, wTempoModifier=0xC0F2, audioRam=(0xC000, 0xC0F3),
    wAudioFadeOutControl=0xCFC7, wAudioFadeOutCounterReloadValue=0xCFC8, wAudioFadeOutCounter=0xCFC9,
    wLowHealthAlarm=0xD083, hLoadedROMBank=0xFFB8,
    dangerPeriod=31,
)
PROFILES = {
    "f2f52230b536214ef7c9924f483392993e226cfb": dict(
        GEN2_COMMON, name="Pokemon Crystal (UE) (V1.1)",
        InitSound=0x3B4E, UpdateSound=0x3B6A, PlayMusic=0x3B97, PlaySFX=0x3C23,
        audioBank=0x3A, x_InitSound=0x4000, x_PlayMusic=0x4B30, x_PlayCry=0x4B79,
        x_PlaySFX=0x4C04, PlayStereoSFX=0x4CA6,
        cryBank=0x3C, cryTable=0x6787, numCries=251, numMusic=103, numSFX=207,
        wChannel1=0xC101, wCryPitch=0xC2B0, wCryLength=0xC2B2, wStereoPanningMask=0xC2BC,
        wLowHealthAlarm=0xC2A6, wMusicFade=0xC2A7, wOptions=0xCFCC,
        hROMBank=0xFF9D, stack=0xC0FD,
    ),
    "d8b8a3600a465308c9953dfa04f0081c05bdcb94": dict(
        GEN2_COMMON, name="Pokemon Gold (UE)",
        InitSound=0x3D4F, UpdateSound=0x3D6B, PlayMusic=0x3D98, PlaySFX=0x3E24,
        audioBank=0x3A, x_InitSound=0x4000, x_PlayMusic=0x4B30, x_PlayCry=0x4B79,
        x_PlaySFX=0x4C04, PlayStereoSFX=0x4CA6,
        cryBank=0x3C, cryTable=0x6747, numCries=251, numMusic=93, numSFX=188,
        wChannel1=0xC001, wCryPitch=0xC1B0, wCryLength=0xC1B2, wStereoPanningMask=0xC1BC,
        wLowHealthAlarm=0xC1A6, wMusicFade=0xC1A7, wOptions=0xD199,
        hROMBank=0xFF9F, stack=0xDFFD,
    ),
    # (Silver keeps its music program in exactly the places Gold does)
    "49b163f7e57702bc939d642a18f591de55d92dae": dict(
        GEN2_COMMON, name="Pokemon Silver (UE)",
        InitSound=0x3D4F, UpdateSound=0x3D6B, PlayMusic=0x3D98, PlaySFX=0x3E24,
        audioBank=0x3A, x_InitSound=0x4000, x_PlayMusic=0x4B30, x_PlayCry=0x4B79,
        x_PlaySFX=0x4C04, PlayStereoSFX=0x4CA6,
        cryBank=0x3C, cryTable=0x6747, numCries=251, numMusic=93, numSFX=188,
        wChannel1=0xC001, wCryPitch=0xC1B0, wCryLength=0xC1B2, wStereoPanningMask=0xC1BC,
        wLowHealthAlarm=0xC1A6, wMusicFade=0xC1A7, wOptions=0xD199,
        hROMBank=0xFF9F, stack=0xDFFD,
    ),
    "ea9bcae617fdf159b045185467ae58b2e4a48b9a": dict(GEN1_COMMON, name="Pokemon Red (UE)"),
    "d7037c83e1ae5b39bde3c30787637ba1d4c48ce2": dict(GEN1_COMMON, name="Pokemon Blue (UE)"),
    # Yellow: the same family, with a fourth bank of songs and sounds, one copy of the part that
    # plays music (in bank 2) serving all four, and Pikachu's voice, which is not music at all
    # but recorded sound pushed through one channel by a routine of its own.
    "cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1": dict(
        GEN1_COMMON, name="Pokemon Yellow (UE)", oneEngine=True,
        PlaySound=0x2238, FadeOutAudio=0x27C2, lowHealthAlarm=0x531E,
        banks=(0x02, 0x08, 0x1F, 0x20),
        updateMusic={0x02: 0x509D},
        playSound={0x02: 0x584E, 0x08: 0x58BB, 0x1F: 0x510D, 0x20: 0x6BD4},
        playChannel={0x02: 0x58C3, 0x08: 0x5930, 0x1F: 0x5182, 0x20: 0x6C49},
        maxSfx={0x02: 0xB9, 0x08: 0xE9, 0x1F: 0xC2, 0x20: 0x98},
        cryData=(0x0E, 0x5462), moveSounds=(0x1E, 0x5A18),
        wAudioFadeOutControl=0xCFC6, wAudioFadeOutCounterReloadValue=0xCFC7, wAudioFadeOutCounter=0xCFC8,
        wLowHealthAlarm=0xD082,
        pika=dict(bank=0x3C, entry=0x4000, body=0x401A, table=0x408E, count=42),
    ),
}

DRIVER = r"""
local floor = math.floor
M = ADDON.GB.new({ bank = function(n) return PY_BANK(n) end, numBanks = NUM_BANKS,
                   now = function() return 1000000 end, audio = { rate = ARATE } })
local SENT = 0xFEA0   -- a return address nothing else ever reaches
function CALL(addr, a, d, e)
  local sp = STACK
  M.poke(sp, SENT % 256) M.poke(sp + 1, floor(SENT / 256))
  M.setCPU({ pc = addr, sp = sp, a = a or 0, d = d or 0, e = e or 0, ime = false, halted = false })
  if not M.runUntil(SENT, 8000000) then error(string.format("routine %04x did not return", addr)) end
end
-- the same, for a routine that wants other registers set and may take long
function CALLR(addr, b, h, l, limit)
  local sp = STACK
  M.poke(sp, SENT % 256) M.poke(sp + 1, floor(SENT / 256))
  M.setCPU({ pc = addr, sp = sp, a = 0, b = b, h = h, l = l, ime = false, halted = false })
  if not M.runUntil(SENT, limit) then error(string.format("routine %04x did not return", addr)) end
end
function BOOT(n)
  for i = 1, n do M.runFrame(false) end
  M.takeAudio()
  M.poke(0xFFFF, 0)   -- the game's own interrupts stay out of it from here on
  M.poke(0xFF70, 1)   -- work RAM bank 1, where some games keep their options
end
-- the output capacitor: a one-pole high-pass, then 16-bit samples
local hpA = HP_A
local xl, xr, yl, yr = 0, 0, 0, 0
local ok, ffi = pcall(require, "ffi")
local function pack(o, n)
  if ok then
    local buf = ffi.new("int16_t[?]", n)
    for i = 1, n, 2 do
      local l, r = o[i], o[i + 1]
      yl = hpA * (yl + l - xl) xl = l
      yr = hpA * (yr + r - xr) xr = r
      buf[i - 1] = floor(yl * 68 + 0.5) buf[i] = floor(yr * 68 + 0.5)
    end
    return ffi.string(buf, n * 2)
  end
  local t = {}
  for i = 1, n, 2 do
    local l, r = o[i], o[i + 1]
    yl = hpA * (yl + l - xl) xl = l
    yr = hpA * (yr + r - xr) xr = r
    local a, b = floor(yl * 68 + 0.5) % 65536, floor(yr * 68 + 0.5) % 65536
    t[#t + 1] = string.char(a % 256, floor(a / 256), b % 256, floor(b / 256))
  end
  return table.concat(t)
end
function FLUSH() M.takeAudio() xl, xr, yl, yr = 0, 0, 0, 0 end
WATCH = {}            -- memory addresses copied out after each frame when asked
-- run n frames of the sound program (TICK is the game's once-a-frame sound
-- update); returns the audio, how many bytes each frame made, and (if asked)
-- the watched memory after each frame
function FRAMES(n, watch)
  local au, cnt, fp = {}, {}, {}
  for i = 1, n do
    local mul = M.debug().ds and 2 or 1     -- a Game Boy Color game may run the CPU at double speed
    local c0 = M.clock()
    TICK()
    local rest = c0 + 70224 * mul - M.clock()
    if rest > 0 then M.idle(rest) end
    local o, c = M.takeAudio()
    au[i] = pack(o, c)
    cnt[i] = c * 2
    if watch then
      local t = {}
      for k = 1, #WATCH do t[k] = M.peek(WATCH[k]) end
      fp[i] = string.char(unpack(t))
    end
  end
  return table.concat(au), table.concat(cnt, ","), table.concat(fp)
end
function PEEK(a) return M.peek(a) end
function POKE(a, v) M.poke(a, v) end
function TITLE() return M.title end
"""


def lowpass_taps(n=95, cutoff=0.5 / OVERSAMPLE * 0.92):
    """Windowed-sinc low-pass for stepping down from the oversampled rate."""
    k = np.arange(n) - (n - 1) / 2
    h = 2 * cutoff * np.sinc(2 * cutoff * k) * np.kaiser(n, 9.0)
    return (h / h.sum()).astype(np.float32)


TAPS = lowpass_taps()


class Machine:
    """The emulator, with the game booted and its own interrupts switched off."""

    def __init__(self, rom, prof, core_src):
        try:
            from lupa import luajit21 as rt
        except ImportError:
            try:
                from lupa import lua51 as rt
            except ImportError:
                import lupa as rt
        self.p = prof
        L = self.L = rt.LuaRuntime(encoding=None, unpack_returned_tuples=True)
        banks = [rom[i:i + 16384] for i in range(0, len(rom), 16384)]
        L.execute(b"ADDON = {}")
        L.eval(b'function(src) local f, err = loadstring(src, "@Core.lua") if not f then error(err) end f("MekkaBoy", ADDON) end')(core_src)
        g = L.globals()
        g[b"PY_BANK"] = lambda n: banks[int(n)]
        arate = RATE * OVERSAMPLE
        L.execute(b"NUM_BANKS = %d ARATE = %d STACK = %d HP_A = %.12f" % (
            len(banks), arate, prof["stack"], math.exp(-2 * math.pi * HIGHPASS_HZ / arate)))
        L.execute(DRIVER.encode())
        self._call, self._frames, self.callr = g[b"CALL"], g[b"FRAMES"], g[b"CALLR"]
        self.peek, self.poke, self.flush = g[b"PEEK"], g[b"POKE"], g[b"FLUSH"]
        g[b"BOOT"](150)
        self.nwatch = 0

    def lua(self, code):
        self.L.execute(code.encode())

    def watch(self, addrs):
        self.lua("WATCH = { %s }" % ", ".join(str(a) for a in addrs))
        self.nwatch = len(addrs)

    def call(self, addr, a=0, de=0):
        self._call(addr, a, (de >> 8) & 255, de & 255)

    def frames(self, n, watch=False):
        au, cnt, fp = self._frames(n, watch)
        a = np.frombuffer(bytes(au), dtype="<i2").reshape(-1, 2)
        counts = [int(x) // 4 for x in bytes(cnt).split(b",")]   # bytes -> stereo samples
        rows = np.frombuffer(bytes(fp), dtype=np.uint8).reshape(n, self.nwatch) if watch else None
        return a, counts, rows


# ---------------------------------------------------------------- engines
class CrystalEngine:
    """Gold, Silver and Crystal."""

    def __init__(self, m, rom):
        self.m, self.rom, p = m, rom, m.p
        self.p = p
        m.lua("TICK = function() CALL(%d) end" % p["UpdateSound"])
        fp = [p["wChannel1"] + ch * p["chanSize"] + off for ch in range(4) for off in p["loopChan"]]
        self.nfp = len(fp)
        m.watch(fp + [p["wChannel1"] + ch * p["chanSize"] + 3 for ch in range(4)])

    def reset(self):
        m, p = self.m, self.p
        m.call(p["InitSound"])
        m.poke(p["wOptions"], int(m.peek(p["wOptions"])) | (1 << p["stereoBit"]))   # the game's Stereo option
        m.poke(p["wStereoPanningMask"], 0)
        m.flush()

    def begin(self, kind, arg):
        self.reset()
        self.start(kind, arg)

    def song_state(self, rows):
        return [(r[:self.nfp].tobytes(), bool((r[self.nfp:] & 1).any())) for r in rows]

    def effect_mask(self):
        m, p, mask = self.m, self.p, 0
        for ch in range(4, 8):
            if int(m.peek(p["wChannel1"] + ch * p["chanSize"] + 3)) & 1:
                mask |= 1 << (ch - 4)
        return mask

    def jobs(self, only, wanted):
        p, jobs = self.p, []
        if only in (None, "extras"):
            jobs.append(("danger", "danger", None))
        if only in (None, "sfx"):
            jobs += [("sfx", "s%03d" % i, i) for i in range(p["numSFX"]) if wanted(i)]
        if only in (None, "cries"):
            off = p["cryBank"] * 0x4000 + (p["cryTable"] - 0x4000)
            cries = {}
            for i in range(p["numCries"]):
                e = self.rom[off + i * 6: off + i * 6 + 6]
                base, pitch, length = e[0] | e[1] << 8, e[2] | e[3] << 8, e[4] | e[5] << 8
                for dp, dl in p["cryVariants"]:
                    pp, ll = (pitch + dp) & 0xFFFF, (length + dl) & 0xFFFF
                    cries["%02x_%04x_%04x" % (base, pp, ll)] = (base, pp, ll)
            jobs += [("cry", "c" + k, v) for k, v in sorted(cries.items())]
        if only in (None, "music"):
            jobs += [("music", "m%03d" % i, i) for i in range(1, p["numMusic"]) if wanted(i)]
        return jobs

    def start(self, kind, arg):
        m, p = self.m, self.p
        if kind == "music":
            m.call(p["PlayMusic"], de=arg)
        elif kind == "sfx":
            m.call(p["PlaySFX"], de=arg)
        elif kind == "cry":
            base, pitch, length = arg
            m.poke(p["wCryPitch"], pitch & 255)
            m.poke(p["wCryPitch"] + 1, pitch >> 8)
            m.poke(p["wCryLength"], length & 255)
            m.poke(p["wCryLength"] + 1, length >> 8)
            m.poke(0x2100, p["audioBank"])
            m.poke(p["hROMBank"], p["audioBank"])
            m.call(p["x_PlayCry"], de=base)
        elif kind == "danger":
            m.poke(p["wLowHealthAlarm"], 0x80)

    def hooks(self):
        p = self.p
        return dict(audioBank=p["audioBank"], initSound=p["x_InitSound"], playMusic=p["x_PlayMusic"],
                    playCry=p["x_PlayCry"], playSFX=p["x_PlaySFX"], playStereoSFX=p["PlayStereoSFX"],
                    wChannel1=p["wChannel1"], chanSize=p["chanSize"], wCryPitch=p["wCryPitch"],
                    wCryLength=p["wCryLength"], wLowHealthAlarm=p["wLowHealthAlarm"],
                    wMusicFade=p["wMusicFade"], wOptions=p["wOptions"], stereoBit=p["stereoBit"])


class RedEngine:
    """Red and Blue. The sound program exists three times over, in three ROM
    banks, each with its own songs and sounds; a sound is known by its bank
    and its number there."""

    def __init__(self, m, rom):
        self.m, self.rom, p = m, rom, m.p
        self.p = p
        if p.get("oneEngine"):
            m.lua("""TICK = function()
  CALL(%d)                                  -- the fade-out the game runs every frame
  M.poke(0x2100, 8) M.poke(%d, 8)
  CALL(%d)                                  -- the low-health alarm
  M.poke(0x2100, 2) M.poke(%d, 2)
  CALL(%d)                                  -- the one music player, whichever bank the song is in
end""" % (p["FadeOutAudio"], p["hLoadedROMBank"], p["lowHealthAlarm"], p["hLoadedROMBank"], p["updateMusic"][2]))
        else:
            m.lua("""TICK = function()
  CALL(%d)                                  -- the fade-out the game runs every frame
  local b = M.peek(%d)
  M.poke(0x2100, b) M.poke(%d, b)
  if b == 2 then CALL(%d) elseif b == 8 then CALL(%d) CALL(%d) else CALL(%d) end
end""" % (p["FadeOutAudio"], p["wAudioROMBank"], p["hLoadedROMBank"], p["updateMusic"][2],
          p["lowHealthAlarm"], p["updateMusic"][8], p["updateMusic"][0x1F]))
        fp = []
        for ch in range(4):
            fp += [p["wChannelCommandPointers"] + 2 * ch, p["wChannelCommandPointers"] + 2 * ch + 1,
                   p["wChannelReturnAddresses"] + 2 * ch, p["wChannelReturnAddresses"] + 2 * ch + 1,
                   p["wChannelSoundIDs"] + ch, p["wChannelLoopCounters"] + ch,
                   p["wChannelOctaves"] + ch, p["wChannelNoteSpeeds"] + ch]
        fp += [p["wMusicTempo"], p["wMusicTempo"] + 1]
        self.nfp = len(fp)
        m.watch(fp + [p["wChannelSoundIDs"] + ch for ch in range(4)])

    def pika(self, clip):
        """One of Pikachu's voice clips, played by the game's own routine."""
        m, p = self.m, self.p
        k = p["pika"]
        self.reset(2)
        at = k["bank"] * 0x4000 + k["table"] - 0x4000 + clip * 3
        bank, lo, hi = self.rom[at], self.rom[at + 1], self.rom[at + 2]
        m.poke(0x2100, k["bank"])
        m.poke(p["hLoadedROMBank"], k["bank"])
        m.callr(k["body"], bank, hi, lo, 60000000)

    def byte(self, bank, addr):
        return self.rom[bank * 0x4000 + addr - 0x4000]

    def headers(self, bank):
        """Every sound in a bank: (number, how many channels). Numbers are
        positions in the bank's table of headers, and a header takes one slot
        per channel, so the numbers have gaps."""
        p, out = self.p, []
        addr = p["headers"] + 3                              # slot 0 is a blank
        while True:
            n = (addr - p["headers"]) // 3
            if n >= 0xFF:
                break
            chans = (self.byte(bank, addr) >> 6) + 1
            first = self.byte(bank, addr) & 0x0F
            ptr = self.byte(bank, addr + 1) | self.byte(bank, addr + 2) << 8
            if not (0x4000 <= ptr < 0x8000) or first > 7:
                break                                        # past the end of the table
            out.append((n, chans))
            addr += 3 * chans
        return out

    def is_music(self, bank, n):
        return self.p["maxSfx"][bank] < n < 0xFF

    def uses_modifiers(self, bank, n):
        p = self.p
        return p["cryStart"] <= n < p["cryEnd"] or (bank == p["battleBank"] and p["battleStart"] <= n < p["battleEnd"])

    def play(self, bank, n, pitch=0, tempo=0x80):
        m, p = self.m, self.p
        m.poke(p["wAudioROMBank"], bank)
        m.poke(p["wAudioSavedROMBank"], bank)
        m.poke(p["wAudioFadeOutControl"], 0)
        m.poke(p["wNewSoundID"], 0)
        m.poke(p["wFrequencyModifier"], pitch)
        m.poke(p["wTempoModifier"], tempo)
        m.call(p["PlaySound"], a=n)

    def reset(self, bank=2):
        m, p = self.m, self.p
        for a in range(*p["audioRam"]):
            m.poke(a, 0)
        m.poke(p["wLowHealthAlarm"], 0)
        m.poke(p["wAudioFadeOutCounter"], 0)
        self.play(bank, 0xFF)                                 # "stop all sound"
        m.poke(0xFF25, 0xFF)                                  # every voice to both speakers, as while a song plays
        m.flush()

    def song_state(self, rows):
        return [(r[:self.nfp].tobytes(), bool(r[self.nfp:].any())) for r in rows]

    def effect_mask(self):
        m, p, mask = self.m, self.p, 0
        for ch in range(4, 8):
            if int(m.peek(p["wChannelSoundIDs"] + ch)):
                mask |= 1 << (ch - 4)
        return mask

    def jobs(self, only, wanted):
        p, rom, jobs = self.p, self.rom, []
        if only in (None, "extras"):
            jobs.append(("danger", "danger", None))
            for clip in range(p.get("pika", {}).get("count", 0)):
                jobs.append(("pika", "spk%02d" % clip, clip))
        combos = {}                                           # (bank, n) -> set of (pitch, tempo)
        cb, ca = p["cryData"]
        mb, ma = p["moveSounds"]
        moves = [(self.byte(mb, ma + 3 * i), self.byte(mb, ma + 3 * i + 1), self.byte(mb, ma + 3 * i + 2))
                 for i in range(p["numMoves"])]
        for i in range(p["numCries"]):
            n = self.byte(cb, ca + 3 * i) * 3 + p["cryStart"]
            pitch, tempo = self.byte(cb, ca + 3 * i + 1), self.byte(cb, ca + 3 * i + 2)
            for bank in p["banks"]:
                combos.setdefault((bank, n), set()).add((pitch, tempo))
            for mv in p["cryMoves"]:                          # moves that use the monster's own cry, altered
                combos[(p["battleBank"], n)].add(((pitch + moves[mv][1]) & 255, (tempo + moves[mv][2]) & 255))
        for i, (n, pitch, tempo) in enumerate(moves):
            if i not in p["cryMoves"]:
                combos.setdefault((p["battleBank"], n), set()).add((pitch, tempo))
        for addr, pitch, tempo in p["fixedBattle"]:
            combos.setdefault((p["battleBank"], (addr - p["headers"]) // 3), set()).add((pitch, tempo))
        for bank in p["banks"]:
            for n, chans in self.headers(bank):
                if self.is_music(bank, n):
                    if only in (None, "music"):
                        jobs.append(("music", "m%02x_%02x" % (bank, n), (bank, n)))
                elif n >= p["noiseEnd"] and only in (None, "sfx", "cries"):
                    is_cry = p["cryStart"] <= n < p["cryEnd"]
                    if only == "sfx" and is_cry or only == "cries" and not is_cry:
                        continue
                    if self.uses_modifiers(bank, n):
                        for pitch, tempo in sorted(combos.get((bank, n), set()) | {(0, 0x80)}):
                            jobs.append(("sfx", "s%02x_%02x_%02x%02x" % (bank, n, pitch, tempo), (bank, n, pitch, tempo)))
                    else:
                        jobs.append(("sfx", "s%02x_%02x" % (bank, n), (bank, n, 0, 0x80)))
        return jobs

    def begin(self, kind, arg):
        if kind == "danger":
            self.reset(self.p["battleBank"])
            self.m.poke(self.p["wLowHealthAlarm"], 0x80)
        else:
            self.reset(arg[0])
            self.play(*arg)

    def hooks(self):
        p = self.p
        b = p["banks"]
        h = dict(cryStart=p["cryStart"], cryEnd=p["cryEnd"],
                 battleBank=p["battleBank"], battleStart=p["battleStart"], battleEnd=p["battleEnd"],
                 wChannelSoundIDs=p["wChannelSoundIDs"], wAudioROMBank=p["wAudioROMBank"],
                 wFrequencyModifier=p["wFrequencyModifier"], wTempoModifier=p["wTempoModifier"],
                 wAudioFadeOutControl=p["wAudioFadeOutControl"],
                 wAudioFadeOutCounterReloadValue=p["wAudioFadeOutCounterReloadValue"],
                 wLowHealthAlarm=p["wLowHealthAlarm"])
        if "pika" in p:
            h["pikaBank"], h["pikaClip"] = p["pika"]["bank"], p["pika"]["entry"]
        for i, bank in enumerate(b):
            h["bank%d" % (i + 1)] = bank
            h["playSound%d" % (i + 1)] = p["playSound"][bank]
            h["playChannel%d" % (i + 1)] = p["playChannel"][bank]
            h["maxSfx%d" % (i + 1)] = p["maxSfx"][bank]
        return h


ENGINES = {"pokecrystal": CrystalEngine, "pokered": RedEngine}


def finish(samples):
    """Oversampled 16-bit stereo -> float stereo at RATE."""
    x = samples.astype(np.float32) / (480.0 * 68.0)
    out = np.empty(((len(x) + OVERSAMPLE - 1) // OVERSAMPLE, 2), dtype=np.float32)
    for c in range(2):
        out[:, c] = np.convolve(x[:, c], TAPS, mode="same")[::OVERSAMPLE]
    out *= GAIN
    return out


def write_ogg(path, audio):
    peak = float(np.abs(audio).max()) if len(audio) else 0.0
    if peak > 0.98:
        audio = audio * (0.98 / peak)
    tmp = path + ".part"
    kw = dict(samplerate=RATE, channels=2, format="OGG", subtype="VORBIS")
    try:
        f = sf.SoundFile(tmp, "w", compression_level=1.0 - QUALITY, **kw)
    except TypeError:                                # older soundfile: default quality
        f = sf.SoundFile(tmp, "w", **kw)
    with f:
        for i in range(0, len(audio), 65536):      # small pieces: some libsndfile builds choke on big ones
            f.write(audio[i:i + 65536])
    os.replace(tmp, path)
    return peak


def trim_tail(audio, keep=0.04):
    loud = np.nonzero(np.abs(audio).max(axis=1) > 0.002)[0]
    if len(loud) == 0:
        return audio[:int(RATE * 0.05)]
    return audio[:min(len(audio), loud[-1] + int(RATE * keep))]


def render_music(m, eng, arg, min_seconds=120.0, max_seconds=240.0):
    eng.begin("music", arg)
    chunks, counts = [], []
    events = []          # (frame, place): each time the song moves on to a new place in its score
    seen = {}            # place -> index in events of the first time the song was there
    scan = 0             # events looked at so far
    pending = None       # a possible loop (event index from, event index to), waiting to be confirmed
    loop = ended = target = None
    last = None
    cap = int(max_seconds * FPS)
    search = int(480 * FPS)                  # how long to look for the loop
    while target is None or len(counts) < target:
        want = 600 if target is None else min(600, target - len(counts))
        a, c, rows = m.frames(want, watch=(target is None))
        chunks.append(a)
        base = len(counts)
        counts += c
        if target is not None:
            continue
        for i, (f, playing) in enumerate(eng.song_state(rows)):
            n = base + i + 1
            if not playing:
                ended = n                    # the song has finished: nothing is playing
                break
            if f != last:
                last = f
                events.append((n, f))
        if ended is not None:
            target = ended + 20
            continue
        while loop is None:
            if pending:
                j, k = pending
                f0, f1 = events[j][0], events[k][0]
                if len(counts) < f1 + (f1 - f0) and len(counts) < search:
                    break                    # need one more pass of the loop to compare with
                first = set(f for n, f in events[j:k])
                again = set(f for n, f in events[k:] if n < f1 + (f1 - f0))
                if len(first & again) >= 0.8 * len(first | again) and f1 - f0 >= 60:
                    loop = (f0, f1)
                else:
                    pending = None           # a passing resemblance; keep looking
            elif scan < len(events):
                f = events[scan][1]
                if f in seen:
                    pending = (seen[f], scan)
                else:
                    seen[f] = scan
                scan += 1
            else:
                break
        if loop:
            f0, period = loop[0], loop[1] - loop[0]
            loops = max(1, math.ceil((min_seconds * FPS - f0) / period))
            while loops > 1 and f0 + loops * period > cap:
                loops -= 1
            target = f0 + loops * period
        elif len(counts) >= search:
            target = cap                     # never came round: keep the first few minutes
    audio = np.concatenate(chunks)[:sum(counts[:target])]
    out = finish(audio)
    meta = dict(frames=target)
    if ended is not None:
        out = trim_tail(out)
        meta["once"] = True
    elif loop:
        meta["intro"] = round(loop[0] / FPS, 3)
        meta["period"] = round((loop[1] - loop[0]) / FPS, 3)
    else:
        fade = np.linspace(1, 0, min(len(out), RATE * 3), dtype=np.float32)
        out[-len(fade):] *= fade[:, None]
        meta["noloop"] = True
    return out, meta


def render_effect(m, eng, kind, arg, max_frames=1200):
    """A sound effect or cry: play until its channels fall silent."""
    eng.begin(kind, arg)
    mask = eng.effect_mask()
    chunks, n = [], 0
    while n < max_frames:
        a, c, _ = m.frames(1)
        chunks.append(a)
        n += 1
        if eng.effect_mask() == 0:
            break
    busy = n
    a, c, _ = m.frames(15)
    chunks.append(a)
    out = trim_tail(finish(np.concatenate(chunks)))
    return out, dict(mask=mask, busy=round(busy / FPS, 3), endless=(n >= max_frames))


# ---------------------------------------------------------------- jobs
_machine = None
_ctx = None


def _init(rom_path, core_path, out_dir, deadline):
    global _ctx
    _ctx = (rom_path, core_path, out_dir, deadline)


def make_engine(rom, core_src):
    prof = PROFILES[hashlib.sha1(rom).hexdigest()]
    m = Machine(rom, prof, core_src)
    return m, ENGINES[prof["engine"]](m, rom)


def _get_machine():
    global _machine
    if _machine is None:
        _machine = make_engine(open(_ctx[0], "rb").read(), open(_ctx[1], "rb").read())
    return _machine


def _job(job):
    kind, name, arg = job
    out_dir, deadline = _ctx[2], _ctx[3]
    if deadline and time.time() > deadline:
        return name, None
    t0 = time.time()
    m, eng = _get_machine()
    if kind == "music":
        audio, meta = render_music(m, eng, arg)
    elif kind in ("sfx", "cry"):
        audio, meta = render_effect(m, eng, kind, arg)
    elif kind == "pika":
        eng.pika(arg)
        a, c, _ = m.frames(12)
        audio = trim_tail(finish(a))
        meta = dict(mask=15, busy=round(len(audio) / RATE, 3), endless=False)
    elif kind == "danger":
        eng.begin("danger", None)
        period = m.p["dangerPeriod"]
        a, c, _ = m.frames(period * (1800 // period))        # a whole number of beeps, so it can repeat
        audio, meta = finish(a), dict(frames=period * (1800 // period))
    else:
        raise ValueError(kind)
    meta["len"] = round(len(audio) / RATE, 3)
    meta["peak"] = round(write_ogg(os.path.join(out_dir, name + ".ogg"), audio), 3)
    meta["took"] = round(time.time() - t0, 2)
    with open(os.path.join(out_dir, "meta", name + ".json"), "w") as f:
        json.dump(meta, f)
    return name, meta


def lua_value(v, indent=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, dict):
        parts = []
        for k in sorted(v, key=lambda k: (isinstance(k, str), k)):
            key = "[%d]" % k if isinstance(k, int) else (k if k.isidentifier() else '["%s"]' % k)
            parts.append("%s = %s" % (key, lua_value(v[k])))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(v)


def build_index(cart, out_dir, title, prof, sha1, hooks):
    """Write the cartridge's Pack.lua: every recording, by the name the addon asks for it by."""
    tables = dict(music={}, sfx={}, cry={})
    danger = None
    for path in glob.glob(os.path.join(out_dir, "meta", "*.json")):
        name = os.path.basename(path)[:-5]
        if not os.path.exists(os.path.join(out_dir, name + ".ogg")):
            continue
        m = json.load(open(path))
        if name == "danger":
            danger = m["len"]
        elif name[0] == "m":
            e = dict(len=m["len"])
            if m.get("once"):
                e["once"] = True
            tables["music"][name[1:]] = e
        elif name[0] in "sc":
            tables["sfx" if name[0] == "s" else "cry"][name[1:]] = dict(len=m["len"], mask=m["mask"], busy=m["busy"])
    lines = ["-- Written by Tools/soundpack.py. Lists the sound files recorded from your own game.",
             "if not (MekkaBoy and MekkaBoy.SoundPack) then return end",
             'MekkaBoy.SoundPack("%s", {' % title,
             "  game = %s," % lua_value(prof["name"]),
             "  engine = %s," % lua_value(prof["engine"]),
             "  sha1 = %s," % lua_value(sha1),
             "  dir = %s," % lua_value("Interface\\AddOns\\%s\\Sound\\" % os.path.basename(cart))]
    if danger:
        lines.append("  danger = %s," % lua_value(danger))
    lines.append("  hooks = %s," % lua_value(hooks))
    for k in ("music", "sfx", "cry"):
        lines.append("  %s = {" % k)
        for key in sorted(tables[k]):
            lines.append('    ["%s"] = %s,' % (key, lua_value(tables[k][key])))
        lines.append("  },")
    lines.append("})")
    with open(os.path.join(cart, "Pack.lua"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(tables["music"]), len(tables["sfx"]), len(tables["cry"])


def main():
    ap = argparse.ArgumentParser(description="Build a MekkaBoy soundtrack pack from your own game.")
    ap.add_argument("rom", nargs="?")
    ap.add_argument("--addons", help="the AddOns folder (default: the one this tool's MekkaBoy folder is in)")
    ap.add_argument("--id", help="the cartridge's id, if you gave rom2lua.py one")
    ap.add_argument("--only", choices=["music", "sfx", "cries", "extras"])
    ap.add_argument("--budget", type=float, default=0)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2)))
    ap.add_argument("--index", action="store_true")
    ap.add_argument("--ids", help="only these song or sound numbers, e.g. 1,5,20-30 (Gold, Silver, Crystal)")
    args = ap.parse_args()

    addon = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    addons_dir = args.addons or os.path.dirname(addon)
    rom_path = args.rom
    if not rom_path:
        found = sorted(glob.glob(os.path.join(addon, "*.gbc")) + glob.glob(os.path.join(addon, "*.gb")))
        if len(found) != 1:
            sys.exit("Which game? Give the path to its ROM.")
        rom_path = found[0]
    rom = open(rom_path, "rb").read()
    sha1 = hashlib.sha1(rom).hexdigest()
    prof = PROFILES.get(sha1)
    if not prof:
        sys.exit("This game is not supported yet (SHA-1 %s). Supported: %s" % (
            sha1, ", ".join(p["name"] for p in PROFILES.values())))
    core_path = os.path.join(addon, "GB", "Core.lua")
    import rom2lua
    title = args.id or rom2lua.cart_id(rom)
    cart = rom2lua.cart_folder(addons_dir, title)
    if not os.path.isdir(cart):
        sys.exit("There is no cartridge for this game yet (%s). Run rom2lua.py on it first." % cart)
    out_dir = os.path.join(cart, "Sound")
    os.makedirs(os.path.join(out_dir, "meta"), exist_ok=True)

    def wanted(i):
        if not args.ids:
            return True
        for part in args.ids.split(","):
            lo, _, hi = part.partition("-")
            if int(lo) <= i <= int(hi or lo):
                return True
        return False

    m, eng = make_engine(rom, open(core_path, "rb").read())
    hooks = eng.hooks()
    jobs = []
    if not args.index:
        jobs = [j for j in eng.jobs(args.only, wanted)
                if not (os.path.exists(os.path.join(out_dir, j[1] + ".ogg"))
                        and os.path.exists(os.path.join(out_dir, "meta", j[1] + ".json")))]
    del m, eng

    print("%s: %d item(s) to render with %d process(es)" % (prof["name"], len(jobs), args.jobs))
    deadline = time.time() + args.budget if args.budget else 0
    done = skipped = 0
    if jobs:
        _init(rom_path, core_path, out_dir, deadline)
        if args.jobs > 1 and len(jobs) > 1:
            import multiprocessing as mp
            with mp.Pool(args.jobs, initializer=_init, initargs=(rom_path, core_path, out_dir, deadline)) as pool:
                for name, meta in pool.imap_unordered(_job, jobs, chunksize=1):
                    if meta is None:
                        skipped += 1
                    else:
                        done += 1
                        print("  %s  %6.1fs  peak %.2f  (%.1fs)" % (name, meta["len"], meta["peak"], meta["took"]), flush=True)
        else:
            for j in jobs:
                name, meta = _job(j)
                if meta is None:
                    skipped += 1
                else:
                    done += 1
                    print("  %s  %6.1fs  peak %.2f  (%.1fs)  %s" % (name, meta["len"], meta["peak"], meta["took"],
                          {k: v for k, v in meta.items() if k not in ("len", "peak", "took")}), flush=True)
    counts = build_index(cart, out_dir, title, prof, sha1, hooks)
    cid, name = rom2lua.read_toc(cart)
    rom2lua.write_toc(cart, cid or title, name or title, rom2lua.interface_version(addons_dir), with_pack=True)
    size = sum(os.path.getsize(f) for f in glob.glob(os.path.join(out_dir, "*.ogg")))
    print("rendered %d now, %d still to do. Pack has %d songs, %d sound effects, %d cries (%.1f MB)." % (
        (done, skipped) + counts + (size / 1e6,)))
    if skipped:
        print("Run again to continue.")


if __name__ == "__main__":
    main()
