#!/usr/bin/env python3
"""Makes a MekkaBoy cartridge from a Game Boy / Game Boy Color ROM you own.

Addons cannot read ordinary files, so a game is turned into a small addon of
its own, a "cartridge": a folder named MekkaBoy_Cart_<id> next to the
MekkaBoy folder, holding the game as Lua data. MekkaBoy lists every cartridge
it finds and only reads one into memory when you put it in the console.

    python3 rom2lua.py "My Game.gbc"
    python3 rom2lua.py "My Game.gbc" --name "My Game" --addons "C:/.../Interface/AddOns"

  --name    what the console calls the game (default: taken from the file name)
  --id      the cartridge's id, which also names its saves (default: the title
            inside the ROM; only needed if two of your games share a title)
  --addons  the AddOns folder (default: the one this tool's MekkaBoy folder is in)

Restart the game client afterwards. Use only games you own; a cartridge is
your copy of the game and is not for sharing.
"""
import argparse
import os
import re

PARTS = 16
BANK = 16384


def lua_string(data):
    out = ['"']
    for b in data:
        if 32 <= b < 127 and b not in (34, 92):
            out.append(chr(b))
        else:
            out.append('\\%03d' % b)
    out.append('"')
    return ''.join(out)


def rom_title(rom):
    title = ''
    # Game Boy Color games keep 11 letters of title; the next 4 are a maker's code
    for b in rom[0x134:(0x13F if rom[0x143] >= 0x80 else 0x143)]:
        if not 32 <= b < 127:
            break
        title += chr(b)
    return title.strip()


def cart_id(rom):
    """The id MekkaBoy knows a game by: the ROM's title, made safe for a folder name."""
    cid = re.sub(r'[^A-Za-z0-9]+', '_', rom_title(rom)).strip('_')
    return cid or 'GAME_%02X%02X' % (rom[0x14E], rom[0x14F])


def nice_name(path):
    name = os.path.splitext(os.path.basename(path))[0]
    name = re.sub(r'\s*[\(\[][^\)\]]*[\)\]]', '', name)      # (USA) [!] and the like
    return re.sub(r'\s+', ' ', name.replace('_', ' ')).strip() or 'Game'


def cart_folder(addons_dir, cid):
    return os.path.join(addons_dir, 'MekkaBoy_Cart_' + cid)


def interface_version(addons_dir):
    try:
        for line in open(os.path.join(addons_dir, 'MekkaBoy', 'MekkaBoy.toc'), encoding='utf-8'):
            if line.startswith('## Interface:'):
                return line.split(':', 1)[1].strip()
    except OSError:
        pass
    return '16001'


def write_toc(folder, cid, name, interface, with_pack=None):
    """(Re)write the cartridge's list of files. with_pack: None = keep it if Pack.lua is there."""
    if with_pack is None:
        with_pack = os.path.exists(os.path.join(folder, 'Pack.lua'))
    lines = ['## Interface: ' + interface,
             '## Title: MekkaBoy Cartridge - ' + name,
             '## Notes: A game for MekkaBoy, made from your own copy. Not for sharing.',
             '## LoadOnDemand: 1',
             '## RequiredDeps: MekkaBoy',
             '## X-MekkaBoy-Cart: ' + cid,
             '## X-MekkaBoy-Name: ' + name]
    lines += ['rom%02d.lua' % i for i in range(PARTS + 1)]
    if with_pack:
        lines.append('Pack.lua')
    with open(os.path.join(folder, os.path.basename(folder) + '.toc'), 'w', newline='\n', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')


def read_toc(folder):
    """id and name of an existing cartridge folder, or (None, None)."""
    cid = name = None
    try:
        for line in open(os.path.join(folder, os.path.basename(folder) + '.toc'), encoding='utf-8'):
            if line.startswith('## X-MekkaBoy-Cart:'):
                cid = line.split(':', 1)[1].strip()
            elif line.startswith('## X-MekkaBoy-Name:'):
                name = line.split(':', 1)[1].strip()
    except OSError:
        pass
    return cid, name


def convert(rom_path, addons_dir, name=None, cid=None):
    rom = open(rom_path, 'rb').read()
    if len(rom) < 0x150 or len(rom) % BANK:
        raise SystemExit('%s does not look like a Game Boy ROM (size %d)' % (rom_path, len(rom)))
    banks = [rom[i:i + BANK] for i in range(0, len(rom), BANK)]
    cid = cid or cart_id(rom)
    if not re.fullmatch(r'[A-Za-z0-9_]+', cid):
        raise SystemExit('An id may only use letters, digits and _.')
    name = (name or nice_name(rom_path)).replace('\n', ' ').strip()
    folder = cart_folder(addons_dir, cid)
    os.makedirs(folder, exist_ok=True)
    head = ('-- A MekkaBoy cartridge, written by Tools/rom2lua.py. Your own copy of a game: do not share.\n'
            'local _, C = ...\n'
            'if not (MekkaBoy and MekkaBoy.NewCartridge) then return end\n'
            'C.banks = MekkaBoy.NewCartridge({ id = %s, name = %s, numBanks = %d, cgb = %s })\n'
            % (lua_string(cid.encode()), lua_string(name.encode('utf-8')), len(banks),
               'true' if rom[0x143] >= 0x80 else 'false'))
    with open(os.path.join(folder, 'rom00.lua'), 'w', newline='\n') as f:
        f.write(head)
    per = -(-len(banks) // PARTS)
    total = len(head)
    for p in range(PARTS):
        chunk = banks[p * per:(p + 1) * per]
        lines = ['-- Written by Tools/rom2lua.py.', 'local _, C = ...',
                 'local B = C.banks', 'if not B then return end']
        for k, data in enumerate(chunk):
            lines.append('B[%d] = %s' % (p * per + k + 1, lua_string(data)))
        text = '\n'.join(lines) + '\n'
        total += len(text)
        with open(os.path.join(folder, 'rom%02d.lua' % (p + 1)), 'w', newline='\n') as f:
            f.write(text)
    write_toc(folder, cid, name, interface_version(addons_dir))
    print('%s -> cartridge "%s" (id %s), %d banks, %.1f MB of Lua in %s' % (
        os.path.basename(rom_path), name, cid, len(banks), total / 1e6, folder))
    return folder


def default_addons_dir():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Make a MekkaBoy cartridge from a ROM you own.')
    ap.add_argument('rom')
    ap.add_argument('--name')
    ap.add_argument('--id')
    ap.add_argument('--addons', default=default_addons_dir())
    a = ap.parse_args()
    convert(a.rom, a.addons, a.name, a.id)
