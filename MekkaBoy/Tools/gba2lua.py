#!/usr/bin/env python3
"""Makes a MekkaBoy Advance cartridge from a Game Boy Advance ROM you own. EXPERIMENTAL.

    python3 gba2lua.py "My Game.gba"
    python3 gba2lua.py "My Game.gba" --id MYGAME --name "My Game" --addons <AddOns folder>

  --name    what the console calls the game (default: taken from the file name)
  --id      the cartridge's id, which also names its saves and is what /mb cart takes (default: the title inside
            the game)
  --addons  the AddOns folder (default: the one this tool's MekkaBoy folder is in)

Tools/addgame.py does this and tells you more about the game first. A cartridge is your copy of the game and is
not for sharing."""
import argparse, os, re
PARTS, BANK = 16, 16384
def lua_string(data):
    out, n = ['"'], len(data)
    for i, b in enumerate(data):
        if 32 <= b < 127 and b not in (34, 92): out.append(chr(b))
        else:
            nxt = data[i + 1] if i + 1 < n else 0
            out.append('\\%03d' % b if 48 <= nxt < 58 else '\\%d' % b)      # (three digits only when a digit follows)
    out.append('"')
    return ''.join(out)
def save_chip(rom):
    """Which chip the game keeps its saves on, from the name its save routines carry (None: none found)."""
    for tag, chip, words in ((b'FLASH1M_V', 'flash128', '128K flash'), (b'FLASH512_V', 'flash64', '64K flash'), (b'FLASH_V', 'flash64', '64K flash'),
                             (b'EEPROM_V', 'eeprom', 'a serial chip, EEPROM'), (b'SRAM_F_V', 'sram', 'battery-backed memory, SRAM'), (b'SRAM_V', 'sram', 'battery-backed memory, SRAM')):
        if tag in rom: return chip, words
    return None, None
def label(rom):
    """What the game says of itself: (title, four-letter code, version number)."""
    title = rom[0xA0:0xAC].split(b'\0')[0].decode('ascii', 'replace').strip()
    return title, rom[0xAC:0xB0].decode('ascii', 'replace'), rom[0xBC]
def default_id(rom):
    return re.sub(r'[^A-Za-z0-9]', '', label(rom)[0]).upper()[:16] or ('GAME' + label(rom)[1])
def default_name(path):
    name = os.path.splitext(os.path.basename(path))[0]
    name = re.sub(r'\s*[\(\[][^\)\]]*[\)\]]', '', name).strip()        # (USA), [!] and the like
    m = re.match(r'^(.*), (The|A|An)( - .*)?$', name)                     # "Legend of Zelda, The - X" -> "The Legend of Zelda - X"
    if m: name = m.group(2) + ' ' + m.group(1) + (m.group(3) or '')
    return name.replace('"', "'") or 'Game'
def convert(path, addons, cid=None, name=None, quiet=False):
    rom = open(path, 'rb').read()
    size = len(rom)
    if size < 0xC0 or rom[0xB2] != 0x96:
        raise SystemExit('%s does not look like a Game Boy Advance game.' % path)
    cid = cid or default_id(rom)
    name = name or default_name(path)
    say = (lambda *a: None) if quiet else print
    chip, chipWords = save_chip(rom)
    say('Saves to: %s' % (chipWords or 'nothing MekkaBoy recognizes (a game with passwords, or without saving): if it does save, tell us which game'))
    if chip == 'flash128': chip = None           # (what MekkaBoy assumes when a cartridge does not say)
    if size % BANK: rom += b'\xff' * (BANK - size % BANK)
    banks = [rom[i:i + BANK] for i in range(0, len(rom), BANK)]
    folder = os.path.join(addons, 'MekkaBoy_Cart_' + cid)
    os.makedirs(folder, exist_ok=True)
    head = ('-- A MekkaBoy Advance cartridge, written by gba2lua.py. Your own copy of a game: do not share.\n'
            'local _, C = ...\n'
            'if not (MekkaBoy and MekkaBoy.NewCartridge) then return end\n'
            'C.banks = MekkaBoy.NewCartridge({ id = "%s", name = "%s", numBanks = %d, system = "gba", size = %d%s })\n' % (cid, name, len(banks), size, ', chip = "%s"' % chip if chip else ''))
    open(os.path.join(folder, 'rom00.lua'), 'w', newline='\n').write(head)
    per = -(-len(banks) // PARTS)
    total = len(head)
    for p in range(PARTS):
        lines = ['-- Written by gba2lua.py.', 'local _, C = ...', 'local B = C.banks', 'if not B then return end', 'local rep = string.rep']
        for k, data in enumerate(banks[p * per:(p + 1) * per]):
            if len(set(data)) == 1: lines.append('B[%d] = rep("\\%d", %d)' % (p * per + k + 1, data[0], BANK))     # all one byte: padding
            else: lines.append('B[%d] = %s' % (p * per + k + 1, lua_string(data)))
        text = '\n'.join(lines) + '\n'
        total += len(text)
        open(os.path.join(folder, 'rom%02d.lua' % (p + 1)), 'w', newline='\n').write(text)
    toc = ['## Interface: 16001', '## Title: MekkaBoy Advance Cartridge - ' + name,
           '## Notes: A game for MekkaBoy Advance (experimental), made from your own copy. Not for sharing.',
           '## LoadOnDemand: 1', '## RequiredDeps: MekkaBoy', '## X-MekkaBoy-Cart: ' + cid, '## X-MekkaBoy-Name: ' + name, '## X-MekkaBoy-System: gba',
           '## X-MekkaBoy-Code: %s-%d' % (label(rom)[1], label(rom)[2])]       # (which game this is, for the list of tried games)
    toc += ['rom%02d.lua' % i for i in range(PARTS + 1)]
    if os.path.exists(os.path.join(folder, 'Pack.lua')): toc.append('Pack.lua')            # (a soundtrack pack made earlier stays)
    open(os.path.join(folder, 'MekkaBoy_Cart_%s.toc' % cid), 'w', newline='\n').write('\n'.join(toc) + '\n')
    say('%s -> %s: %d pieces, %.1f MB of Lua' % (os.path.basename(path), folder, len(banks), total / 1e6))
    return dict(id=cid, name=name, folder=folder, bytes=total)
if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('rom'); ap.add_argument('--id'); ap.add_argument('--name'); ap.add_argument('--addons')
    a = ap.parse_args()
    if a.id and not re.fullmatch(r'[A-Za-z0-9_]+', a.id): raise SystemExit('--id may hold letters, digits and _ only')
    addons = a.addons or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    made = convert(a.rom, addons, a.id, a.name)
    print('Restart the game client, then: /mb cart %s' % made['id'].lower())
