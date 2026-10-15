#!/usr/bin/env python3
"""Turns a Game Boy / Game Boy Color ROM you own into a MekkaBoy import code:
one long line of text to paste into the game (/mb import). Nothing goes in
the AddOns folder; the game keeps the pasted cartridge with your settings.

    python3 rom2code.py "My Game.gbc"                 # writes "My Game - MekkaBoy code.txt" next to the ROM
    python3 rom2code.py "My Game.gbc" --name "My Game" --out code.txt

The code is the game itself, packed: it is your copy and is not for sharing.
A pasted cartridge plays without sound; sound needs a cartridge folder made
by rom2lua.py and a soundtrack pack made by soundpack.py.
"""
import argparse
import base64
import os
import zlib

import rom2lua

BANK = 16384


def make_code(rom, name, cid=None):
    if len(rom) < 0x150 or len(rom) % BANK:
        raise SystemExit('That does not look like a Game Boy ROM (size %d).' % len(rom))
    cid = cid or rom2lua.cart_id(rom)
    payload = base64.b64encode(zlib.compress(rom, 9)).decode('ascii')
    name64 = base64.b64encode(name.encode('utf-8')).decode('ascii')
    return 'MEKKA1:%s:%s:%d:%d:%d:%d:%d:%s:END' % (
        cid, name64, len(rom) // BANK, 1 if rom[0x143] >= 0x80 else 0, len(rom),
        zlib.adler32(rom) & 0xFFFFFFFF, zlib.adler32(payload.encode('ascii')) & 0xFFFFFFFF, payload)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Make a MekkaBoy import code from a ROM you own.')
    ap.add_argument('rom')
    ap.add_argument('--name')
    ap.add_argument('--id')
    ap.add_argument('--out')
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    name = a.name or rom2lua.nice_name(a.rom)
    code = make_code(rom, name, a.id)
    out = a.out or os.path.splitext(a.rom)[0] + ' - MekkaBoy code.txt'
    with open(out, 'w', newline='') as f:
        f.write(code)
    print('%s -> %s (%d KB of text). Open it, select all, copy, then /mb import in game and paste.' % (
        os.path.basename(a.rom), out, len(code) // 1024))
