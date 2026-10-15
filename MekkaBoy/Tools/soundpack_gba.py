#!/usr/bin/env python3
"""Builds a MekkaBoy soundtrack pack from a Game Boy Advance game you own.

WoW addons cannot produce sound themselves; they can only play sound files.
So this tool runs the game's own music program on MekkaBoy's emulator and
records every song, sound effect and cry to a file. The addon then plays the
right file whenever the game starts that song or sound.

    python3 soundpack_gba.py "My Game.gba"      # the game's cartridge must exist already (gba2lua.py)
    python3 soundpack_gba.py "My Game.gba" --cart MYGAME      # a game the tool has no notes on (see below)

Options:  --only music|sfx|cries      record just one part
          --ids 1,5,20-30             only these song numbers
          --jobs N                    how many processes to use
          --index                     only rebuild the cartridge's Pack.lua from what is recorded

Needs Python packages: lupa, numpy, scipy, soundfile. Restart the game client
when it is done. The files it writes are made from your own game and are for
your own machine, not for sharing.

Which games. The ones in PROFILES below are known exactly, cries and all. For
any other game give --cart with the name you gave its cartridge: the tool then
looks for the shared music program in the game itself (m4afind.py) and records
its songs and sounds. That works for the many games that carry that program
unchanged; a game with a music program of its own cannot be done this way,
and the tool says so.

How it works. Nearly every GBA game uses the same music program. Once the game
has started it up, the game itself is left standing and only that program is
run, sixty times a second, exactly as the game would run it. It is asked to
start a song; what it sends to the console's sound hardware is collected:
the stream of recorded sound it mixes (two streams, left and right), and what
it writes to the four tone and noise channels inherited from the Game Boy,
which are then played through MekkaBoy's model of that sound chip.
"""
import argparse
import glob
import hashlib
import json
import math
import os
import struct
import sys
import time

import numpy as np
import soundfile as sf

RATE = 32000          # sample rate of the files (the console's own recorded sound runs at about 13 kHz)
QUALITY = 0.25        # Ogg Vorbis quality, 0 (small) .. 1 (large)
HIGHPASS_HZ = 30.0    # the console's output capacitor removes the standing level
GAIN = 0.9
FRAME = 280896        # processor cycles in one frame
FPS = 16777216 / FRAME
CLOCK = 16777216

# Where each supported game keeps its music program. One entry per ROM (by SHA-1).
# The addresses come from the published research into these games.
PROFILES = {
    "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc": dict(
        name="Pokemon FireRed (USA)", cart="FIRERED",
        songTable=0x084A32CC, playerTable=0x084A329C, players=4,
        soundMain=0x081DD0E8, vsync=0x081DC9D4, songStart=0x081DD0F4, allStop=0x081DD228,
        playCry=0x08071F78, speciesToCry=0x08043304, cryPlayer=0x02037ECC, cryPlayers=(0x03006F70, 0x03006FB0),
        cryTable=0x0848C914, cryTableReverse=0x0848DB44, species=440),
    "f3ae088181bf583e55daf962a92bb46f4f1d07b7": dict(
        name="Pokemon Emerald (USA)", cart="EMERALD",
        songTable=0x086B49F0, playerTable=0x086B49C0, players=4,
        soundMain=0x082E0124, vsync=0x082DFA10, songStart=0x082E0130, allStop=0x082E0264,
        playCry=0x080A344C, speciesToCry=0x0806D510, cryPlayer=0x020383E8, cryPlayers=(0x030073A0, 0x030073E0),
        cryTable=0x0869DCF4, cryTableReverse=0x0869EF24, species=440),
    "7862c67bdecbe21d1d69ce082ce34327e1c6ed5e": dict(
        name="Pokemon LeafGreen (USA) (V1.1)", cart="LEAFGREEN",
        songTable=0x084A2C18, playerTable=0x084A2BE8, players=4,
        soundMain=0x081DD134, vsync=0x081DCA20, songStart=0x081DD140, allStop=0x081DD274,
        playCry=0x08071F8C, speciesToCry=0x08043318, cryPlayer=0x02037ECC, cryPlayers=(0x03006F70, 0x03006FB0),
        cryTable=0x0848C260, cryTableReverse=0x0848D490, species=440),
    "89b45fb172e6b55d51fc0e61989775187f6fe63c": dict(
        name="Pokemon Sapphire (USA, Europe) (V1.2)", cart="SAPPHIRE",
        songTable=0x08455500, playerTable=0x084554D0, players=4,
        soundMain=0x081DDE94, vsync=0x081DD780, songStart=0x081DDEA0, allStop=0x081DDFD4,
        playCry=0x080751E4, speciesToCry=0x0803F904, cryPlayer=0x0202F79C, cryPlayers=(0x03006FF0, 0x03007030),
        cryTable=0x08452604, cryTableReverse=0x08453834, species=440),
    # (a copy of Ruby V1.0 with a release group's opening screen added in front; the game itself sits where V1.0 has it)
    "b60bf8da9bbdd47d0354522d6934d3bbc95ef3a8": dict(
        name="Pokemon Ruby (USA) (V1.0, with an added opening screen)", cart="RUBY",
        songTable=0x0845548C, playerTable=0x0845545C, players=4,
        soundMain=0x081DDEEC, vsync=0x081DD7D8, songStart=0x081DDEF8, allStop=0x081DE02C,
        playCry=0x080751C0, speciesToCry=0x0803F904, cryPlayer=0x0202F79C, cryPlayers=(0x03006FF0, 0x03007030),
        cryTable=0x08452590, cryTableReverse=0x084537C0, species=440),
    # (no cries of the main games' kind: every creature sound is one of the ordinary sounds)
    "9f4cfc5b5f4859d17169a485462e977c7aac2b89": dict(
        name="Pokemon Mystery Dungeon: Red Rescue Team (USA)", cart="PMDRED",
        songTable=0x09E866BC, playerTable=0x09E8665C, players=8,
        soundMain=0x080AEF9C, vsync=0x080AE8C8, songStart=0x080AEFA8, allStop=0x080AF0DC),
}
# The ways a cry is bent that are worth their own recording: (letter, the game's "mode" number).
# n as heard in the Pokedex and at the start of a battle; d cut short, for double battles;
# f lowered, on fainting; w slightly lowered, when sent out badly hurt.
CRY_MODES = (("n", 0), ("d", 1), ("f", 5), ("w", 11))
CRY_VOLUME, CRY_PRIORITY = 120, 10

DRIVER = r'''
local M = GBA.new({ bank = PY_BANK, size = ROM_SIZE, debug = { LOUDMIXER = true } })
local rd8, rd16, rd32, wr32 = M.rd8, M.rd16, M.rd32, M.wr32
local floor = math.floor

-- what the sound hardware is sent
local fifo = { {}, {} }
local psg, npsg = {}, 0
M.listen = {
  fifo = function(i, ptr, n, cyc0, per)
    local b = {}
    for k = 0, n - 1 do b[k + 1] = rd8(ptr + k) end
    local t = fifo[i]
    t[#t + 1] = cyc0 .. "," .. per .. "," .. n
    t[#t + 1] = string.char(unpack(b))
  end,
  psg = function(o, v, cyc) psg[npsg + 1], psg[npsg + 2], psg[npsg + 3] = o, v, cyc npsg = npsg + 3 end,
}

-- the Game Boy sound chip, for the four old channels
local apu = loadstring(APU_SRC, "apu")()(RATE, {})
local MAP = { [0x60] = 0x10, [0x62] = 0x11, [0x63] = 0x12, [0x64] = 0x13, [0x65] = 0x14, [0x68] = 0x16, [0x69] = 0x17, [0x6C] = 0x18, [0x6D] = 0x19,
  [0x70] = 0x1A, [0x72] = 0x1B, [0x73] = 0x1C, [0x74] = 0x1D, [0x75] = 0x1E, [0x78] = 0x20, [0x79] = 0x21, [0x7C] = 0x22, [0x7D] = 0x23,
  [0x80] = 0x24, [0x81] = 0x25, [0x84] = 0x26 }
for o = 0x90, 0x9F do MAP[o] = o - 0x60 end

-- start the game and let it set its music program up
function BOOT(limit)
  for i = 1, limit do
    -- (a tap on A now and then: some copies open with a screen that waits for a button)
    if i % 90 == 0 then M.setKey("a", true) elseif i % 90 == 5 then M.setKey("a", false)
    elseif i % 90 == 45 then M.setKey("start", true) elseif i % 90 == 50 then M.setKey("start", false) end
    M.runFrame(false)
    local info = rd32(0x03007FF0)
    if i > 30 and info >= 0x02000000 and info < 0x04000000 and rd32(info) == 0x68736D53 and rd32(BGM + 0x34) == 0x68736D53 then
      M.setKey("a", false) M.setKey("start", false)
      for _ = 1, 8 do M.runFrame(false) end
      return i
    end
  end
  error("the game never started its music program")
end

-- call one of the game's own routines and come back
local RET = 0x09FFFFF1
local done = false
M.blocks[RET] = function() done = true M.stopAt = 0 return RET, 0 end
function CALL(addr, a0, a1, a2, a3, onStack)
  local r = M.r
  local save = {}
  for i = 0, 18 do save[i] = r[i] end
  local key = M.key
  r[0], r[1], r[2], r[3] = a0 or 0, a1 or 0, a2 or 0, a3 or 0
  if onStack then r[13] = r[13] - 8 wr32(r[13], onStack) end
  r[14] = RET
  M.key = addr
  done = false
  local guard = 0
  while not done do
    M.runCPU(M.cyc + 4000000)
    guard = guard + 1
    if guard > 100 then error("a routine of the game's did not come back") end
  end
  local ret = r[0]
  for i = 0, 18 do r[i] = save[i] end
  M.key = key
  return ret
end

-- one frame of nothing but the music program, at the moments the game would run it
local base
local function frame()
  base = base or M.cyc
  local t = base + 150 * 1232
  if M.cyc < t then M.cyc = t end
  CALL(VSYNC)
  t = base + 160 * 1232
  if M.cyc < t then M.cyc = t end
  CALL(SOUNDMAIN)
  base = base + FRAME
  if M.cyc < base then M.cyc = base end
  M.soundFlush()
end

-- where a song has got to: enough to know the same place when it comes round again
local function place(player)
  local n = rd8(player + 8)
  local tracks = rd32(player + 0x2C)
  local t = {}
  for i = 0, n - 1 do
    local a = tracks + i * 0x50
    local flags = rd8(a)
    if flags >= 128 then
      local level = rd8(a + 2)       -- (how deep in "play this passage, then come back"; only that many return places count)
      local s = i .. ":" .. rd32(a + 0x40) .. ":" .. rd8(a + 1) .. ":" .. level .. ":" .. rd8(a + 3)
      for k = 0, level - 1 do s = s .. ":" .. rd32(a + 0x44 + k * 4) end
      t[#t + 1] = s
    end
  end
  return table.concat(t, "|")
end

-- Run n frames. Returns, per frame, "status,clock,place" of the watched player (or of nothing).
function FRAMES(n, player)
  local rows = {}
  for i = 1, n do
    frame()
    if player then
      rows[i] = rd32(player + 4) .. "," .. rd32(player + 12) .. "," .. place(player)
    end
  end
  return table.concat(rows, "\n")
end

-- Hand over everything collected since the last call, and start afresh.
function TAKE()
  local a, b = fifo[1], fifo[2]
  fifo = { {}, {} }
  -- the old channels: play the register writes through the chip, up to now
  for k = 1, npsg, 3 do
    local g = MAP[psg[k]]
    if g then apu.write(g, psg[k + 1], psg[k + 2] / 4) end
  end
  psg, npsg = {}, 0
  apu.advance(M.cyc / 4)
  local out, n = apu.take()
  local parts = {}
  for k = 1, n, 4000 do
    local t = {}
    for j = k, math.min(n, k + 3999) do local v = out[j] t[#t + 1] = string.char(v % 256, floor(v / 256)) end
    parts[#parts + 1] = table.concat(t)
  end
  local headsA, dataA, headsB, dataB = {}, {}, {}, {}
  for k = 1, #a, 2 do headsA[#headsA + 1] = a[k] dataA[#dataA + 1] = a[k + 1] end
  for k = 1, #b, 2 do headsB[#headsB + 1] = b[k] dataB[#dataB + 1] = b[k + 1] end
  return table.concat(headsA, ";"), table.concat(dataA), table.concat(headsB, ";"), table.concat(dataB), table.concat(parts), M.cyc, M.io[0x82]
end
function NOW() return M.cyc end
PEEK8, PEEK32 = rd8, rd32
'''


class Machine:
    """The emulator with the game started, the game itself left standing, and its music program ours to run."""

    def __init__(self, rom, prof, core_src, apu_src):
        from lupa import luajit21 as rt
        self.p = prof
        L = self.L = rt.LuaRuntime(encoding=None, unpack_returned_tuples=True)
        banks = [rom[i:i + 16384] for i in range(0, len(rom), 16384)]
        g = L.globals()
        g[b"PY_BANK"] = lambda n: banks[int(n)] if int(n) < len(banks) else b"\0" * 16384
        g[b"APU_SRC"] = apu_src
        L.execute(b"GBA = (function(...) " + core_src + b'\nend)("MekkaBoy", {})')
        players = self.players = [struct.unpack_from("<I", rom, prof["playerTable"] - 0x08000000 + i * 12)[0] for i in range(prof["players"])]
        L.execute(("ROM_SIZE = %d RATE = %d FRAME = %d BGM = %d VSYNC = %d SOUNDMAIN = %d" % (
            len(rom), RATE, FRAME, players[0], prof["vsync"] + 1, prof["soundMain"] + 1)).encode())
        L.execute(DRIVER.encode())
        self._call, self._frames, self._take = g[b"CALL"], g[b"FRAMES"], g[b"TAKE"]
        self.peek8, self.peek32, self.now = g[b"PEEK8"], g[b"PEEK32"], g[b"NOW"]
        g[b"BOOT"](2400)
        self.quiet()

    def call(self, addr, *args, stack=None):
        a = list(args) + [0] * (4 - len(args))
        return int(self._call(addr + 1, a[0], a[1], a[2], a[3], stack))

    def quiet(self):
        """Stop everything and let the echoes die away; throw away what was collected."""
        self.call(self.p["allStop"])
        self._frames(45, None)
        self._take()
        self.t0 = int(self.now())

    def frames(self, n, player=None):
        rows = self._frames(n, player)
        if player is None:
            return None
        out = []
        for line in bytes(rows).split(b"\n"):
            status, clock, where = line.split(b",", 2)
            out.append((int(status), int(clock), where))
        return out

    def take(self):
        """Everything played since the last quiet(), as float stereo at RATE."""
        ha, da, hb, db, psg, cyc, cnt = self._take()
        t0, t1 = self.t0, int(cyc)
        n_out = int(round((t1 - t0) / CLOCK * RATE))
        psg = np.frombuffer(bytes(psg), dtype="<u2").astype(np.float32).reshape(-1, 2)
        cnt = int(cnt)

        def stream(heads, data):
            data = np.frombuffer(bytes(data), dtype=np.int8).astype(np.float32)
            heads = bytes(heads)
            if not heads:
                return np.zeros(n_out, dtype=np.float32)
            per = None
            line = None
            pos = 0
            for h in heads.split(b";"):
                c0, p, n = h.split(b",")
                c0, p, n = float(c0), float(p), int(n)
                if per is None:
                    per = p
                    line = np.zeros(int((t1 - t0) / per) + 2, dtype=np.float32)
                k = int(round((c0 - t0) / per))
                if 0 <= k < len(line):
                    m = min(n, len(line) - k)
                    line[k:k + m] = data[pos:pos + m]
                pos += n
            return resample_exact(line, per, n_out)

        a, b = stream(ha, da), stream(hb, db)
        # which stream goes to which side, and how loud (the game says, in a register)
        va, vb = (1.0 if cnt & 4 else 0.5), (1.0 if cnt & 8 else 0.5)
        ds = 4.0 / 512.0                       # a full-range byte at full volume fills the output
        left = (a * va * ds if cnt & 0x200 else 0) + (b * vb * ds if cnt & 0x2000 else 0)
        right = (a * va * ds if cnt & 0x100 else 0) + (b * vb * ds if cnt & 0x1000 else 0)
        ratio = (0.25, 0.5, 1.0, 0.0)[cnt & 3]
        k = (128.0 / 60.0) / 512.0 * ratio     # each old channel can span a quarter of the output
        out = np.zeros((n_out, 2), dtype=np.float32)
        out[:, 0] += left
        out[:, 1] += right
        m = min(n_out, len(psg))
        out[:m] += psg[:m] * k
        return out


def resample_exact(x, per, n_out):
    """Samples one every `per` processor cycles -> exactly n_out samples at RATE, cleanly."""
    from scipy import fft
    n_in = len(x)
    if n_in < 2:
        return np.zeros(n_out, dtype=np.float32)
    pad = fft.next_fast_len(n_in + 256, real=True)
    xp = np.zeros(pad, dtype=np.float32)
    xp[:n_in] = x
    src_rate = CLOCK / per
    m = int(round(pad * RATE / src_rate))
    X = fft.rfft(xp)
    Y = np.zeros(m // 2 + 1, dtype=X.dtype)
    k = min(len(X), len(Y))
    Y[:k] = X[:k]
    y = fft.irfft(Y, m) * (m / pad)
    y = y[:n_out] if len(y) >= n_out else np.concatenate([y, np.zeros(n_out - len(y))])
    return y.astype(np.float32)


def finish(audio):
    """Take out the standing level, keep within range (the console clips too)."""
    from scipy.signal import lfilter
    al = math.exp(-2 * math.pi * HIGHPASS_HZ / RATE)
    out = lfilter([1, -1], [1, -al], audio, axis=0).astype(np.float32)
    return np.clip(out, -1, 1) * GAIN


def write_ogg(path, audio):
    peak = float(np.abs(audio).max()) if len(audio) else 0.0
    tmp = path + ".part"
    kw = dict(samplerate=RATE, channels=2, format="OGG", subtype="VORBIS")
    try:
        f = sf.SoundFile(tmp, "w", compression_level=1.0 - QUALITY, **kw)
    except TypeError:
        f = sf.SoundFile(tmp, "w", **kw)
    with f:
        for i in range(0, len(audio), 65536):        # small pieces: some libsndfile builds choke on big ones
            f.write(audio[i:i + 65536])
    os.replace(tmp, path)
    return peak


def trim_tail(audio, keep=0.05):
    loud = np.nonzero(np.abs(audio).max(axis=1) > 0.003)[0]
    if len(loud) == 0:
        return audio[:int(RATE * 0.05)]
    return audio[:min(len(audio), loud[-1] + int(RATE * keep))]


def playing(status):
    return status < 0x80000000 and (status & 0xFFFF) != 0


MIN_MUSIC_SECONDS = 100.0


def render_song(m, n, player, music, min_seconds=None, max_seconds=200.0):
    """Song or sound number n, on the given player. Music is recorded through a whole number of
    turns of its loop; anything else until it ends."""
    if min_seconds is None:
        min_seconds = MIN_MUSIC_SECONDS
    m.quiet()
    m.call(m.p["songStart"], n)
    rows = []
    cap = int((max_seconds if music else 30.0) * FPS)
    search = int(400 * FPS) if music else cap
    seen = {}                   # place -> (frame, clock) the first time the song was there
    loop = ended = target = None
    while target is None or len(rows) < target:
        want = 600 if target is None else min(600, target - len(rows))
        got = m.frames(want, player)
        base = len(rows)
        rows += got
        if target is not None:
            continue
        for i, (status, clock, where) in enumerate(got):
            f = base + i + 1
            if not playing(status):
                ended = f
                break
            if music and loop is None and where:
                first = seen.get(where)
                if first is None:
                    seen[where] = (f, clock)
                elif f - first[0] >= 120 and clock > first[1]:
                    loop = (first[0], f)
        if ended is not None:
            target = ended + 100             # let the last notes and the echo ring out
        elif loop:
            f0, period = loop[0], loop[1] - loop[0]
            loops = max(1, math.ceil((min_seconds * FPS - f0) / period))
            while loops > 1 and f0 + loops * period > cap:
                loops -= 1
            target = max(len(rows), f0 + loops * period)
        elif len(rows) >= search:
            target = cap if music else len(rows)
    audio = finish(m.take())
    audio = audio[:int(round(target / FPS * RATE))]
    meta = dict(frames=target)
    if ended is not None:
        audio = trim_tail(audio)
        meta["once"] = True
    elif loop:
        meta["intro"] = round(loop[0] / FPS, 3)
        meta["period"] = round((loop[1] - loop[0]) / FPS, 3)
    else:
        fade = np.linspace(1, 0, min(len(audio), RATE * (3 if music else 1)), dtype=np.float32)
        audio[-len(fade):] *= fade[:, None]
        meta["noloop"] = True
    return audio, meta


def render_cry(m, species, mode):
    m.quiet()
    m.call(m.p["playCry"], species, 0, CRY_VOLUME, CRY_PRIORITY, stack=mode)
    player = int(m.peek32(m.p["cryPlayer"]))
    total = 0
    while total < 600:
        got = m.frames(20, player)
        total += 20
        if not playing(got[-1][0]):
            break
    m.frames(60)
    audio = trim_tail(finish(m.take()))
    return audio, dict(frames=total + 60, once=True)


# ---------------------------------------------------------------- the work list
def song_list(rom, prof):
    """(number, player index, tracks) for every distinct song in the game's table."""
    out, seen, n = [], set(), 0
    base = prof["songTable"] - 0x08000000
    while True:
        hdr, ms, me = struct.unpack_from("<IHH", rom, base + n * 8)
        if hdr < 0x08000000 or hdr >= 0x08000000 + len(rom):
            break
        tracks = rom[hdr - 0x08000000]
        if hdr not in seen and tracks > 0 and ms < prof["players"]:
            out.append((n, ms, tracks))
        seen.add(hdr)
        n += 1
    return out, n


_ctx = None
_machine = None


def _init(rom_path, core_path, apu_path, out_dir, cart=None, music_seconds=None):
    global _ctx, MIN_MUSIC_SECONDS
    _ctx = (rom_path, core_path, apu_path, out_dir, cart)
    if music_seconds:
        MIN_MUSIC_SECONDS = music_seconds


def profile_for(rom, cart=None):
    """The notes on this game: the known ones, or (given the cartridge's name) what m4afind.py finds in the game."""
    prof = PROFILES.get(hashlib.sha1(rom).hexdigest())
    if prof or not cart:
        return prof
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import m4afind
    found = m4afind.find(rom)                   # (raises ValueError, with the reason, when the game has another music program)
    prof = dict(name=cart, cart=cart, songTable=found["songTable"], playerTable=found["playerTable"], players=found["players"],
                soundMain=found["soundMain"], vsync=found["vsync"], songStart=found["songStart"], allStop=found["allStop"])
    bgm = m4afind.music_player(rom, found)
    if bgm:
        prof["bgm"] = bgm
    return prof


def apu_source(gb_core_text):
    i0 = gb_core_text.index("local DUTY = ")
    i1 = gb_core_text.index("local DMG_SHADE")
    return ("local floor = math.floor\n" + gb_core_text[i0:i1] + "\nreturn newAPU").encode()


def _get_machine():
    global _machine
    if _machine is None:
        rom = open(_ctx[0], "rb").read()
        prof = profile_for(rom, _ctx[4])
        _machine = Machine(rom, prof, open(_ctx[1], "rb").read(), apu_source(open(_ctx[2], encoding="utf-8").read()))
    return _machine


def _job(job):
    kind, name, arg = job
    out_dir = _ctx[3]
    t0 = time.time()
    try:
        m = _get_machine()
        if kind == "song":
            n, ms = arg
            bgm = m.p.get("bgm", 0)
            audio, meta = render_song(m, n, m.players[ms], music=(ms == bgm))
            if ms != bgm:
                meta["mask"] = (1 << (ms - 1)) if bgm == 0 else (1 << ms)
        else:
            species, mode = arg
            audio, meta = render_cry(m, species, mode)
    except Exception as e:                     # one bad item must not stop the rest
        global _machine
        _machine = None
        return name, dict(error=str(e)[:300])
    meta["len"] = round(len(audio) / RATE, 3)
    meta["peak"] = round(write_ogg(os.path.join(out_dir, name + ".ogg"), audio), 3)
    meta["rms"] = round(float(np.sqrt((audio ** 2).mean())) if len(audio) else 0.0, 4)
    meta["took"] = round(time.time() - t0, 2)
    with open(os.path.join(out_dir, "meta", name + ".json"), "w") as f:
        json.dump(meta, f)
    return name, meta


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua_value(x) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v, key=lambda k: (isinstance(k, str), k)):
            key = "[%d]" % k if isinstance(k, int) else (k if k.isidentifier() else '["%s"]' % k)
            parts.append("%s = %s" % (key, lua_value(v[k])))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(v)


def build_index(cart_dir, out_dir, prof, sha1, rom, entries):
    tables = dict(music={}, sfx={}, cry={})
    for path in glob.glob(os.path.join(out_dir, "meta", "*.json")):
        name = os.path.basename(path)[:-5]
        if not os.path.exists(os.path.join(out_dir, name + ".ogg")):
            continue
        m = json.load(open(path))
        if m.get("rms", 1) < 0.0005:           # nothing audible came of it: not worth a file
            continue
        if name[0] == "m":
            e = dict(len=m["len"])
            if m.get("once"):
                e["once"] = True
            tables["music"][name[1:]] = e
        elif name[0] == "s":
            e = dict(len=m["len"], mask=m.get("mask", 1), busy=m["len"])
            if not m.get("once"):
                e["loops"] = True
            tables["sfx"][name[1:]] = e
        elif name[0] == "c":
            tables["cry"][name[1:]] = dict(len=m["len"], mask=256, busy=m["len"])
    players = [struct.unpack_from("<I", rom, prof["playerTable"] - 0x08000000 + i * 12)[0] for i in range(prof["players"])]
    hooks = dict(songTable=prof["songTable"], songs=entries, players=players)
    if prof.get("bgm"):
        hooks["bgm"] = prof["bgm"] + 1         # (which of the players, counted from 1, carries the music)
    if "playCry" in prof:
        hooks.update(cryPlayers=list(prof["cryPlayers"]), cryTable=prof["cryTable"], cryTableReverse=prof["cryTableReverse"])
    cart = os.path.basename(cart_dir)
    lines = ["-- Written by Tools/soundpack_gba.py. Lists the sound files recorded from your own game.",
             "if not (MekkaBoy and MekkaBoy.SoundPack) then return end",
             'MekkaBoy.SoundPack("%s", {' % prof["cart"],
             "  game = %s," % lua_value(prof["name"]),
             '  engine = "m4a",',
             "  sha1 = %s," % lua_value(sha1),
             "  dir = %s," % lua_value("Interface\\AddOns\\%s\\Sound\\" % cart),
             "  hooks = %s," % lua_value(hooks)]
    for k in ("music", "sfx", "cry"):
        lines.append("  %s = {" % k)
        for key in sorted(tables[k]):
            lines.append('    ["%s"] = %s,' % (key, lua_value(tables[k][key])))
        lines.append("  },")
    lines.append("})")
    with open(os.path.join(cart_dir, "Pack.lua"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    toc = os.path.join(cart_dir, cart + ".toc")
    if os.path.exists(toc):
        text = open(toc, encoding="utf-8").read()
        if "Pack.lua" not in text:
            with open(toc, "w", encoding="utf-8", newline="\n") as f:
                f.write(text.rstrip("\n") + "\nPack.lua\n")
    return len(tables["music"]), len(tables["sfx"]), len(tables["cry"])


def parse_ids(text):
    out = set()
    for part in text.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return out


def main():
    ap = argparse.ArgumentParser(description="Build a MekkaBoy soundtrack pack from your own Game Boy Advance game.")
    ap.add_argument("rom")
    ap.add_argument("--addons", help="the AddOns folder (default: the one this tool's MekkaBoy folder is in)")
    ap.add_argument("--only", choices=["music", "sfx", "cries"])
    ap.add_argument("--ids")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2)))
    ap.add_argument("--index", action="store_true")
    ap.add_argument("--redo", action="store_true", help="record again even what is already there")
    ap.add_argument("--cart", help="the cartridge's name (as given to gba2lua.py --id), for a game not in the tool's own list")
    ap.add_argument("--music-seconds", type=float, default=100.0, help="record each song for at least this long (whole turns of its loop)")
    args = ap.parse_args()

    addon = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    addons_dir = args.addons or os.path.dirname(addon)
    rom = open(args.rom, "rb").read()
    sha1 = hashlib.sha1(rom).hexdigest()
    try:
        prof = profile_for(rom, args.cart)
    except ValueError as e:
        sys.exit("No soundtrack pack can be made for this game: %s." % e)
    if not prof:
        sys.exit("This game is not in the tool's own list (%s). Give --cart <the cartridge's name> to have it look in the game itself." % ", ".join(p["name"] for p in PROFILES.values()))
    if args.cart and prof["cart"] == args.cart and sha1 not in PROFILES:
        toc = os.path.join(addons_dir, "MekkaBoy_Cart_" + args.cart, "MekkaBoy_Cart_%s.toc" % args.cart)
        if os.path.exists(toc):
            for line in open(toc, encoding="utf-8"):
                if line.startswith("## X-MekkaBoy-Name:"):
                    prof["name"] = line.split(":", 1)[1].strip()
        print("Found the music program in the game: %d songs and sounds, %d players, music on player %d" % (
            song_list(rom, prof)[1], prof["players"], prof.get("bgm", 0) + 1), flush=True)
    cart_dir = os.path.join(addons_dir, "MekkaBoy_Cart_" + prof["cart"])
    if not os.path.isdir(cart_dir):
        sys.exit("Make the cartridge first (gba2lua.py): %s does not exist." % cart_dir)
    out_dir = os.path.join(cart_dir, "Sound")
    os.makedirs(os.path.join(out_dir, "meta"), exist_ok=True)
    songs, entries = song_list(rom, prof)

    if not args.index:
        ids = parse_ids(args.ids) if args.ids else None
        jobs = []
        for n, ms, tracks in songs:
            kind = "music" if ms == prof.get("bgm", 0) else "sfx"
            if (args.only in (None, kind)) and (ids is None or n in ids):
                jobs.append(("song", ("m" if kind == "music" else "s") + "%03d" % n, (n, ms)))
        if args.only in (None, "cries") and ids is None and "playCry" in prof:
            core = open(os.path.join(addon, "GBA", "Core.lua"), "rb").read()
            m = Machine(rom, prof, core, apu_source(open(os.path.join(addon, "GB", "Core.lua"), encoding="utf-8").read()))
            first = {}
            for s in range(1, prof["species"]):
                cry = m.call(prof["speciesToCry"], s - 1)
                if 0 <= cry < (prof["cryTableReverse"] - prof["cryTable"]) // 12:
                    first.setdefault(cry, s)
            del m
            for cry, s in sorted(first.items()):
                for letter, mode in CRY_MODES:
                    jobs.append(("cry", "c%03d_%s" % (cry, letter), (s, mode)))
        if not args.redo:
            jobs = [j for j in jobs if not os.path.exists(os.path.join(out_dir, "meta", j[1] + ".json"))]
        # the long ones first, spread across the processes
        jobs.sort(key=lambda j: 0 if j[1][0] == "m" else 1)
        print("%d items to record, on %d processes" % (len(jobs), args.jobs), flush=True)
        t0 = time.time()
        init = (args.rom, os.path.join(addon, "GBA", "Core.lua"), os.path.join(addon, "GB", "Core.lua"), out_dir, args.cart, args.music_seconds)
        done = 0
        if args.jobs <= 1:
            _init(*init)
            results = map(_job, jobs)
        else:
            import multiprocessing as mp
            pool = mp.Pool(args.jobs, initializer=_init, initargs=init)
            results = pool.imap_unordered(_job, jobs)
        for name, meta in results:
            done += 1
            if "error" in meta:
                print("  %s FAILED: %s" % (name, meta["error"]), flush=True)
            elif done % 25 == 0 or name[0] == "m":
                print("  %4d/%d  %s  %.1f s of sound in %.1f s%s" % (done, len(jobs), name, meta["len"], meta["took"],
                      "" if meta.get("once") else ("  loop %.1f+%.1f" % (meta["intro"], meta["period"]) if "period" in meta else "  no loop found")), flush=True)
        print("recorded in %.0f s" % (time.time() - t0), flush=True)

    counts = build_index(cart_dir, out_dir, prof, sha1, rom, entries)
    print("Pack.lua: %d songs, %d sounds, %d cries" % counts)


if __name__ == "__main__":
    main()
