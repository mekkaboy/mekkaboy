#!/usr/bin/env python3
"""Finds the shared music program ("m4a") in a Game Boy Advance game: where its list of songs, its players and
the handful of its routines that soundpack_gba.py calls are. Nearly every GBA game carries the same program,
compiled from the same source, so its routines look the same from game to game except for the addresses in them;
they are looked for by that likeness, in the game file itself.

    python3 m4afind.py "My Game.gba"
"""
import re, struct, sys

def _pat(text):
    """'00 b5 ?? f0' -> a compiled pattern over bytes (?? = any byte, ?x / x? = any half)."""
    out = b''
    for tok in text.split():
        if tok == '??': out += b'.'
        elif '?' in tok:
            hi, lo = tok[0], tok[1]
            vals = [v for v in range(256) if (hi == '?' or '%x' % (v >> 4) == hi) and (lo == '?' or '%x' % (v & 15) == lo)]
            out += b'[' + b''.join(re.escape(bytes([v])) for v in vals) + b']'
        else: out += re.escape(bytes([int(tok, 16)]))
    return re.compile(out, re.S)

# "start song number n": look the song up in the list, look its player up in the table of players, start it
SONG_START = _pat('00 b5 00 04 07 4? 08 49 40 0b 40 18 8? 88 5? 00 ?? 18 89 00 ?? 18 0a 68 01 68 10 1c ?? f? ?? f? 01 bc 00 47')     # (the middle differs with the compiler used)
# the routine just before it in every copy: "run the music program for one frame"
SOUND_MAIN = _pat('00 b5 ?? f? ?? f? 01 bc 00 47 00 00')
# "stop every player": a loop over the table of players
ALL_STOP = _pat('30 b5 ?? 48 00 04 00 0c 00 28 08 d0 ?? 4d 04 1c 28 68 ?? f? ?? f? 0c 35 01 3c 00 2c f8 d1')
# the part run at every picture's end, which keeps the recorded sound flowing
VSYNC = _pat('?? 48 00 68 ?? 4a 03 68 9b 1a 01 2b ?? d8 01 79 01 39 01 71 ?? dc c1 7a 01 71')
# ... and the form it takes in games that send their recorded sound down one stream only
VSYNC_ONE = _pat('00 b5 ?? 48 02 68 10 68 ?? 49 40 18 01 28 ?? d8 10 79 01 38 11 79 10 71')

def find(rom):
    """-> dict(songTable, playerTable, players, soundMain, vsync, songStart, allStop, songs) or raises ValueError."""
    def u32(o): return struct.unpack_from('<I', rom, o)[0]
    hits = [m.start() for m in SONG_START.finditer(rom) if m.start() % 2 == 0]
    if not hits: raise ValueError('this game does not seem to carry the usual music program (no "start song" routine found)')
    good = []
    for at in hits:
        lit = at + 36
        lit += lit % 4                               # the two addresses follow, on a 4-byte boundary
        players, songs = u32(lit), u32(lit + 4)
        if 0x08000000 <= players < 0x08000000 + len(rom) and 0x08000000 <= songs < 0x08000000 + len(rom): good.append((at, players, songs))
    if not good: raise ValueError('found the "start song" routine but not the lists it should point at')
    at, playerTable, songTable = good[0]
    p = dict(songStart=0x08000000 + at, playerTable=playerTable, songTable=songTable)
    if SOUND_MAIN.match(rom, at - 12): p['soundMain'] = 0x08000000 + at - 12
    else:
        raise ValueError('found the song list but not the "run one frame" routine before it')
    m = ALL_STOP.search(rom, at, at + 0x400)
    if not m: raise ValueError('found the song list but not the "stop everything" routine')
    p['allStop'] = 0x08000000 + m.start()
    # how many players: the number that routine loads first (it sits in the routine's own notes, after its code)
    ldr = rom[m.start() + 2]
    lit = ((m.start() + 2 + 4) & ~3) + ldr * 4
    n = u32(lit)
    # ... checked against the table itself: entries of 12 bytes, each two places in the console's own memory
    def entry_ok(i):
        o = playerTable - 0x08000000 + i * 12
        a, b = u32(o), u32(o + 4)
        return 0x02000000 <= a < 0x04000000 and 0x02000000 <= b < 0x04000000 and rom[o + 8] <= 16
    count = 0
    while count < 64 and entry_ok(count): count += 1
    if not (1 <= n <= 64 and n <= count): n = count
    if n < 1: raise ValueError('the table of players makes no sense')
    p['players'] = n
    v = [m.start() for m in VSYNC.finditer(rom) if m.start() % 2 == 0] or [m.start() for m in VSYNC_ONE.finditer(rom) if m.start() % 2 == 0]
    if not v: raise ValueError('found the song list but not the routine run at each picture\'s end')
    p['vsync'] = 0x08000000 + v[0]
    # how many songs the list holds
    k, base = 0, songTable - 0x08000000
    while base + k * 8 + 8 <= len(rom):
        hdr = u32(base + k * 8)
        if not (0x08000000 <= hdr < 0x08000000 + len(rom)): break
        k += 1
    p['songs'] = k
    return p

def music_player(rom, p):
    """Which player carries the music: the one most of whose pieces go round and round. (Sound effects are short and
    end; in most games music is on the first player, but not in all.)"""
    def u32(o): return struct.unpack_from('<I', rom, o)[0]
    base, seen, loops = p['songTable'] - 0x08000000, set(), {}
    for k in range(p['songs']):
        hdr, ms, _ = struct.unpack_from('<IHH', rom, base + k * 8)
        if hdr in seen or ms >= p['players']: continue
        seen.add(hdr)
        o = hdr - 0x08000000
        tracks = rom[o]
        if not 1 <= tracks <= 16: continue
        for t in range(tracks):
            ts = u32(o + 8 + t * 4) - 0x08000000
            if not 0 <= ts < len(rom): continue
            i, end, found = ts, min(len(rom) - 5, ts + 20000), False
            while i < end:
                c = rom[i]
                if c == 0xB1: break                     # the track ends
                if c == 0xB2:                           # "go back to": a loop if it points back into this track
                    found = ts <= u32(i + 1) - 0x08000000 <= i
                    break
                i += 1
            if found:
                loops[ms] = loops.get(ms, 0) + 1
                break
    if not loops: return 0
    best = max(loops, key=lambda ms: (loops[ms], -ms))
    return best if loops[best] > 2 * loops.get(0, 0) else 0     # (the first player unless another clearly is it)

if __name__ == '__main__':
    for path in sys.argv[1:]:
        rom = open(path, 'rb').read()
        try:
            p = find(rom)
            print(path.split('/')[-1][:40], ' '.join('%s=%s' % (k, ('0x%08X' % v) if v > 4096 else v) for k, v in p.items()), 'music on player', music_player(rom, p))
        except ValueError as e:
            print(path.split('/')[-1][:40], 'NOT FOUND:', e)
