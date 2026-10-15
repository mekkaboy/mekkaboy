#!/usr/bin/env python3
"""Adds a game you own to MekkaBoy, and tells you first what to expect of it.

    python3 addgame.py "My Game.gba"              # look at the game, say what to expect, make its cartridge
    python3 addgame.py "My Game.gba" --sound      # ... and record its songs and sounds too (takes minutes)
    python3 addgame.py "My Game.gba" --look       # only look and tell; make nothing

  --id      the cartridge's id: what /mb cart takes, and what its saves are kept under (default: ours for a
            game we know, else the title inside the game)
  --name    what the console calls the game (default: ours for a game we know, else from the file name)
  --addons  the AddOns folder (default: the one this tool's MekkaBoy folder is in)

What it tells you, all read from the game file itself in a moment:
  * whether we have tried this game, and how that went (the list is Tools/tested.json; it holds no game data);
  * whether the game will be able to save (which save chip its cartridge carried);
  * whether it can have sound (most games share one music program, which can be recorded; a few have their own);
  * how heavy it is for the console, from 1 to 10, when we have measured it;
  * how much room its cartridge takes.
A Game Boy or Game Boy Color game (.gb, .gbc) is handed to rom2lua.py.

Use only games you own. A cartridge and a soundtrack pack are your copy of the game and are not for sharing.
"""
import argparse, json, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gba2lua

def tested():
    try: return json.load(open(os.path.join(HERE, 'tested.json')))
    except (OSError, ValueError): return {}

def look(rom, path):
    """Everything there is to know about the game without running it."""
    title, code, version = gba2lua.label(rom)
    key = '%s-%d' % (code, version)
    listed = tested()
    entry, exact = listed.get(key), True
    if not entry:
        for k, e in listed.items():
            if k[:4] == code: entry, exact = e, False
    chip, chip_words = gba2lua.save_chip(rom)
    info = dict(title=title, code=code, version=version, key=key, size=len(rom), entry=entry, exact=exact, chip=chip, chipWords=chip_words)
    # sound: one of our six exactly-known games, the shared music program, or neither
    try:
        import hashlib
        import m4afind
        known = None
        try:
            import soundpack_gba                                    # (needs numpy and soundfile; only its list is wanted here)
            known = soundpack_gba.PROFILES.get(hashlib.sha1(rom).hexdigest())
        except Exception:
            pass
        if known: info['sound'] = dict(kind='exact')
        else:
            f = m4afind.find(rom)
            info['sound'] = dict(kind='shared', entries=f['songs'], players=f['players'])
    except ValueError as e:
        info['sound'] = dict(kind='own', why=str(e))
    info['name'] = (entry or {}).get('name') or gba2lua.default_name(path)
    info['id'] = (entry or {}).get('id') or gba2lua.default_id(rom)
    return info

SLOW = 6                                    # (as in GBA/Tested.lua)
def weight(e):
    w = e.get('weight') or max(1, min(10, int(1 + (e.get('cost', 1) - 1) * 3 + 0.5)))
    if w >= SLOW: return 'weight %d of 10: a heavy game, expect it to run slow' % w
    return 'weight %d of 10' % w

def report(info, out=print):
    e = info['entry']
    out('%s   (%s, %s, version %d, %.0f MB)' % (info['name'], info['title'], info['code'], info['version'], info['size'] / 2 ** 20))
    if not e:
        out('  Tried:   not by us. It may play, play with faults, or stop. Tell us how it goes.')
    else:
        words = dict(played='played at length in the game client', starts='starts and plays in our tests; not yet played at length', stops='does not run yet')[e['status']]
        out('  Tried:   %s (MekkaBoy %s)%s.' % (words, e['version'], '' if info['exact'] else '; that was another version of this game'))
        if e.get('note'): out('           %s' % e['note'])
    if info['chip']: out('  Saving:  yes (%s).' % info['chipWords'])
    else: out('  Saving:  no save chip found in it: a game with passwords, or one that does not save.')
    s = info['sound']
    if s['kind'] == 'exact': out('  Sound:   yes, songs, sounds and cries, recorded from your own game: add --sound (about half an hour).')
    elif s['kind'] == 'shared': out('  Sound:   yes, recorded from your own game: add --sound (%d songs and sounds; some minutes, and 40 to 120 MB).' % s['entries'])
    else: out('  Sound:   none. This game has a music program of its own, which cannot be recorded this way: it plays silently.')
    if e and e['status'] != 'stops': out('  Speed:   %s.' % weight(e))
    else: out('  Speed:   not measured. Games that move the whole picture all the time (racing, fast platformers) run slower.')
    out('  Room:    about %.0f MB for the cartridge.' % (info['size'] * 2.75 / 2 ** 20))

def main():
    ap = argparse.ArgumentParser(description='Add a game you own to MekkaBoy.')
    ap.add_argument('rom'); ap.add_argument('--id'); ap.add_argument('--name'); ap.add_argument('--addons')
    ap.add_argument('--sound', action='store_true', help='also record the game\'s songs and sounds')
    ap.add_argument('--look', action='store_true', help='only look at the game and say what to expect')
    ap.add_argument('--replace', action='store_true', help='make the cartridge again even if one with this id is there')
    a = ap.parse_args()
    addons = a.addons or os.path.dirname(os.path.dirname(HERE))
    ext = os.path.splitext(a.rom)[1].lower()
    if ext in ('.gb', '.gbc', '.sgb'):
        if a.look: sys.exit('A Game Boy or Game Boy Color game: rom2lua.py makes its cartridge (those games all run).')
        cmd = [sys.executable, os.path.join(HERE, 'rom2lua.py'), a.rom, '--addons', addons]
        if a.id: cmd += ['--id', a.id]
        if a.name: cmd += ['--name', a.name]
        sys.exit(subprocess.call(cmd))
    rom = open(a.rom, 'rb').read()
    if len(rom) < 0xC0 or rom[0xB2] != 0x96: sys.exit('%s does not look like a Game Boy Advance game.' % a.rom)
    info = look(rom, a.rom)
    if a.name: info['name'] = a.name
    if a.id:
        if not re.fullmatch(r'[A-Za-z0-9_]+', a.id): sys.exit('--id may hold letters, digits and _ only')
        info['id'] = a.id
    report(info)
    if a.look: return
    if info['entry'] and info['entry']['status'] == 'stops':
        print('\nThis game does not run in MekkaBoy yet, so no cartridge was made. (--replace makes one anyway.)')
        if not a.replace: return
    folder = os.path.join(addons, 'MekkaBoy_Cart_' + info['id'])
    toc = os.path.join(folder, 'MekkaBoy_Cart_%s.toc' % info['id'])
    if os.path.exists(toc) and not a.replace:
        other = ''
        for line in open(toc, encoding='utf-8', errors='replace'):
            if line.startswith('## X-MekkaBoy-Code:'): other = line.split(':', 1)[1].strip()
        if other and other != info['key']:
            print('\nA cartridge called %s is there already and it is another game (%s). Give this one its own name with --id.' % (info['id'], other))
            sys.exit(1)
        print('\nThe cartridge %s is there already; left as it is (--replace makes it again).' % info['id'])
    else:
        if not os.path.isdir(os.path.join(addons, 'MekkaBoy')):
            sys.exit('\n%s does not look like the AddOns folder (there is no MekkaBoy in it). Say where it is with --addons.' % addons)
        made = gba2lua.convert(a.rom, addons, info['id'], info['name'], quiet=True)
        print('\nMade the cartridge %s (%.0f MB) in %s' % (made['id'], made['bytes'] / 2 ** 20, made['folder']))
    if a.sound:
        if info['sound']['kind'] == 'own':
            print('No sound was recorded: this game has a music program of its own.')
        else:
            print('Recording its songs and sounds: this takes a while...', flush=True)
            cmd = [sys.executable, os.path.join(HERE, 'soundpack_gba.py'), a.rom, '--addons', addons]
            if info['sound']['kind'] == 'shared': cmd += ['--cart', info['id']]
            if subprocess.call(cmd) != 0:
                print('The recording did not finish (it needs the Python packages lupa, numpy, scipy and soundfile). The cartridge itself is fine and plays silently.')
    print('Restart the game client fully, then: /mb cart %s' % info['id'].lower())

if __name__ == '__main__':
    main()
