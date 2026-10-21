# MekkaBoy (beta)

Current version: 0.21.0 beta.

A Game Boy, Game Boy Color and Game Boy Advance emulator addon for WoW Forever.
Website: https://mekkaboy.com · Download: https://www.curseforge.com/wow/addons/mekkaboy

This repository is the addon exactly as it ships: the `MekkaBoy` folder, its helper
folders, and the five original games. To install from here, download the repository
as a zip and put the eleven folders into your `Interface\AddOns` folder (or use the
CurseForge app, which does it for you).

**Reporting a bug:** type `/mb bug` in game and open an issue with what it shows,
or use https://mekkaboy.com/feedback/ if you don't have a GitHub account. Please
don't paste SavedVariables files or link logs; they contain character names.

**How it's tested:** every game on the tested list (`/mb tested`, or
https://mekkaboy.com/tested/) has been run in MekkaBoy's own emulator core, and link
play for Pokémon Emerald was verified by two players in the live beta on 15 October
2026. Each push here is checked by CI: every Lua file must parse as Lua 5.1 and every
`.toc` must list only files that exist.

MekkaBoy is a Lua addon for WoW Forever. Type `/mb` and a handheld emulator
opens on your screen, with a shelf of cartridges, four memory valves for save
states, rewind and fast-forward. It closes itself in combat and pauses for ready
checks, queues, summons, trades, duels and flight landings.

MekkaBoy ships with five original games and no others. A game ROM you own can be
added through the Workshop (https://workshop.mekkaboy.com). A game you add plays
**without sound** unless you record a soundtrack pack from your own copy with the
tools in the download (see Sound); the five included games have their music.

Not affiliated with, endorsed or sponsored by Nintendo or Blizzard
Entertainment. Game Boy, Game Boy Color and Game Boy Advance are trademarks of
Nintendo. World of Warcraft is a trademark of Blizzard Entertainment.

## Install

Every folder in the download goes in the game's `Interface\AddOns` folder,
side by side: `MekkaBoy`, the `MekkaBoy_Slot1` to `4` and `MekkaBoy_States`
helpers, and one `MekkaBoy_Cart_...` folder per game that comes with it. Start
the game client afterwards (a new folder needs a full start, not `/reload`).

## The five games that come with it

Each is a cartridge on the shelf (Select while the console is off or paused,
or `/mb carts`). All five are in beta: they play start to finish and will keep
changing.

- **Deadmines Hold'em** - Texas Hold'em below decks against a crew of Defias
  card sharks: five decks of stakes and a daily wheel, chips only, no money of
  any kind. Played on your own for now; multiplayer tables are coming.
- **City Gates** - tower defense at the gates of all six capitals.
- **Critter Crate** - a crate arrives and something inside is scratching. Raise
  what comes out.
- **Overload** - blackjack in a Booty Bay den, against the house or a friend
  over the link.
- **Gearworks** - falling cogs; over the link, the lines you clear land in the
  other player's machine.

## Playing

- Click the screen or press Enter to switch on; Esc pauses, Esc again puts it
  away. Every button on the console can be clicked; hover over one for its key.
- **While the console is open it has the keyboard to itself.** Nothing you
  press moves your character. Put the console away to get your keys back.
  Print Screen is let through.
- It will not open in combat, and combat puts it away. Things that need you
  pause the game and say why on its screen: a ready check, a queue that pops,
  a summon, a resurrect offer, a group invite, a duel, a trade window, and
  your flight landing. Each can be switched off in the settings.
- Two looks: **Minimal**, a see-through window with the controls on a slim
  bar (played on the keyboard), and **Console**, the MekkaBoy handheld with
  every button clickable (`/mb look minimal|console`, or the Look slider in
  the settings). The first time you open MekkaBoy it asks how you want to play
  and which look you want; `/mb welcome` asks again.
- Both looks come in six colorways: Gunmetal, Midnight, Arcane, Verdant,
  Ivory and Rose Gold (`/mb color <name>`, or the Color slider in the
  settings).

| Button | Key |
|---|---|
| D-pad | Arrow keys, or WASD |
| A / B | X / Z |
| Start / Select | Enter / Backspace |
| L / R (Advance games) | Q / E, or the bars on top of the console |
| Fast-forward (hold) | Tab, or the >> key on the console |
| Rewind (hold; Game Boy games) | ` (backtick), or the << key |
| Load / save memory valve 1-4 | F1 - F4 / Shift + F1 - F4 |
| Volume | = and -, or the wheel under the screen |
| Turbo A / Turbo B | C / V |

`/mb keys` lists them, `/mb bind <button> <key>` changes one, `/mb help` lists
every command. Opening it: `/mb`, the minimap button, the addon menu, or a key
of your own under Key Bindings > AddOns > MekkaBoy. Settings: Options >
AddOns > MekkaBoy or `/mb options`.

## Adding a game you own

Type `/mb setup` and follow the three steps in the window: a page in your web
browser (the MekkaBoy Workshop; a copy ships in this folder as
`Workshop.html`) turns your own game file into a code, and you paste the code
into the game. The page works entirely in your browser; your game is not sent
anywhere. The game goes on the shelf at once and is kept with your settings;
no restart is needed.

A Game Boy Advance game is too big to paste. Drop it on the same page and
press **Save the cartridge**: the page saves a zip holding one folder,
`MekkaBoy_Cart_<NAME>`. Close the game client, put that folder in
`Interface\AddOns` so that it sits **next to** `MekkaBoy` (not inside it, and
not inside the folder your computer makes when it unzips: the `.toc` file
must be directly inside `MekkaBoy_Cart_<NAME>`). Start the client again and
the game is on the shelf. The page says first whether the game has been
tried, whether it saves, and how heavy it is for the console; `/mb tested`
lists the tried ones in the game, each with a weight from 1 to 10 (from 6 up,
expect it to run slow).

The code or folder is your copy of your game. Do not share it, and do not
ask others for theirs.

## Saving

Games save as they did on the real thing. Saves, memory valves and the
"resume where I left off" point are kept with the addon's settings, which the
game client writes when you log out or `/reload`; do one of those before
closing the client. The five games that come with MekkaBoy keep one save for
each character and tell the time by the realm's clock, which the server keeps
(Critter Crate's pets live in real time, so your computer's clock does not
move them; `/mb clock` shows the realm's time beside your computer's). A game made from your own copy keeps one save for the whole
account, on your computer's clock. Rewind keeps the last 40 seconds of a Game Boy game
(`/mb rewind 90` keeps more). Cheats: GameShark and Game Genie codes for Game
Boy games, `/mb cheat add <code>`.

## Sound

The five games that come with MekkaBoy have their music and sounds. A game you
add plays silently: an addon cannot make sound, only play sound files, so
sound for your own game needs a soundtrack pack recorded from your own copy
with the Python tools in the `Tools` folder (`soundpack.py`,
`soundpack_gba.py`; see the notes at the top of each). The pack is part of
your copy of the game: do not share it.

The console has a volume wheel of its own (`/mb volume 0-100`) that leaves
the rest of the game's sound alone, and it keeps the song going while
another window is in front (`/mb sound background off` to stop that).

## Link play

Two players who both have MekkaBoy and their own copy of a game can connect
their consoles for supported games: the games' own trade and battle rooms, as
with a link cable. No party is needed: `/mb link <name>` asks the other
player, who answers with `/mb link` (in a party, both of you just type
`/mb link`). Whoever typed it first leads, and the chat window says where each
of you should go. `/mb tested` and the Workshop
page say which games link. It works in the open world; the game client does
not carry addon messages during boss fights, keystone runs or PvP matches.
`/mb link off` ends it. Each console runs its own copy of the game; when the
game reaches for the cable, MekkaBoy stands in for the other console and sends
only what changes hands. Rewind and memory valves are off while a link is open.

If the other player's game stops in the middle of a trade or a battle (they
go offline, pause, or hit a loading screen), yours waits for them instead of
finishing on its own, so a trade can't complete on one side only. If they are
gone for a minute, the link closes; type `/mb reset` if your game then shows a
communication error.

**Trading where you stand** (Pokémon Emerald, FireRed 1.0, LeafGreen 1.1).
Once linked, either player types `/mb trade`. Your game is saved and held
still, the other player gets a pop-up, and if they say yes both games open
their own trade screen right there, with no Pokémon Center. Afterwards you are
back on the square you stood on. It is refused in places a trade's save could
leave you stuck (elevators, secret bases, the Safari Zone, the Battle Frontier,
on the water). Between Emerald and FireRed/LeafGreen the games' own rule
applies: Champion in Emerald, the Sevii Islands finished in FireRed/LeafGreen.
`/mb trade off` calls it off before the trade screen opens.

**Battling where you stand** works the same way: `/mb battle`. Your Pokémon
are healed for the battle and come back exactly as they were (no free heal),
your bag is untouched, and the win or loss goes in each game's link battle
record. As in the Colosseum, each game saves before the battle and again
after it. Single battles only.

**If the link drops while a trade saves** (Emerald, FireRed, LeafGreen): the
two games save a trade a moment apart, so a client closing in that moment
could leave it kept on one side only. MekkaBoy keeps your save from just
before the trade until both games are known to have kept it. If they didn't,
the player whose game kept it is offered to undo it on their side; nothing
changes unless they press Undo. `/mb trades` lists any trade still being
checked.

## Team card and Pokédex

Target a player who has MekkaBoy and click the MekkaBoy mark above their
portrait: their **team card** shows the trainer and game they are on (playing
now, or when they last played), their party and levels, badges, how many
Pokémon they have caught across all their saves, and their link battle record.
**Link** on the card asks them to link; **Their Pokédex** shows their National
Pokédex (caught out of 386), their Living Pokédex (in a party or PC box right
now), Kanto / Johto / Hoenn, and each save. `/mb card` and `/mb dex` show your
own; the friends list has a My Pokédex button.

Who can see yours follows How I play: Open, anyone; Friends only, the people
you know; Solo, nobody. Pictures come from your own Ruby, Sapphire, Emerald,
FireRed or LeafGreen once you have opened it; otherwise a dashed square.
Pokémon in Red, Blue, Yellow and the Advance games' saves are counted in full
once you have opened that game in this version.

## Together Mode (experimental)

In the Pokémon games, `/mb together <name>` lets you and a friend see each
other's trainer walking in your own copies of the game (they add you too).
Walk up to theirs and press A: in Emerald, FireRed and LeafGreen you are offered
a trade or a battle right there; in the other games, the chat says how to link. `/mb together why` says
what is happening, `/mb together off` stops it.

## Limits

- Game Boy Advance games: no rewind and no cheat codes yet; memory valves
  and resume work, and are kept in the `MekkaBoy_States` helper.
- Timing is accurate to the instruction, not to the cycle. Games run; a few
  timing torture tests do not pass. Cartridge types: plain, MBC1, MBC2, MBC3
  (with clock), MBC30, MBC5; on the Advance side all four kinds of save chip.
- No infrared, printer, camera or wireless adapter.

## Rules this addon follows

It is free, its code is readable, it shows no advertisements and asks for
nothing in game. It sends addon messages only to players you choose (your
party, or someone you name with `/mb link` or `/mb together`), only while that
is open, plus a one-line version check.
