-- Runs the game on the console: pixels, keys, pacing, save states, rewind,
-- fast-forward, cheats, colors, and the cartridge slot. Games are cartridges
-- (GB/Carts.lua), each made from a ROM you own.
--
-- One console plays three kinds of cartridge. Game Boy and Game Boy Color
-- games run on GB/Core.lua; Game Boy Advance games on GBA/Core.lua. What is
-- particular to a kind of machine (how big its picture is, how it is started,
-- where its save goes) sits in a small table, a "system": GBSYS below for the
-- first two, MB.AdvanceSystem (GBA/Screen.lua) for the third. Everything else
-- here is the same for all of them.
local _, MB = ...

-- GB/Sound.lua normally provides this. If it is missing (files added while the
-- game client was running are not seen until it restarts), carry on silently.
MB.Sound = MB.Sound or setmetatable({}, { __index = function() return function() end end })


local CELL = 2                -- design units per game pixel (see UI/Body.lua)
local GBSYS = {
    kind = "gb",
    W = 160, H = 144, fps = 59.73,
    budget = 10,              -- most emulation time allowed per screen frame, ms
    budgetFF = 14,            -- ... while fast-forwarding
    mostOwed = 3,             -- game frames one screen frame may make up for
    pictureMax = 3,           -- show at least every 3rd picture
    pictureMs = 10,           -- if a frame (game + picture) costs more than this on average, show fewer pictures
    pictureOpt = "picture",
    states = true,            -- memory valves and "resume where I left off"
    rewind = true,            -- a state is quick enough to take five times a second
    pad = { up = true, down = true, left = true, right = true, a = true, b = true, start = true, select = true },
}
local sys = GBSYS             -- the system of the game that is running (or ran last)
local REWIND_EVERY = 12       -- emulated frames between rewind snapshots (5 a second)
local SLOTS = 4

local clock = debugprofilestop or function() return GetTime() * 1000 end
local floor = math.floor
local Print = MB.Print
local screen = MB.screen

-- ------------------------------------------------------------ settings ---
-- button -> keys. The defaults are what desktop Game Boy emulators use
-- (mGBA's layout: B and A on Z and X, as they sit on the console; Enter and
-- Backspace for Start and Select; Tab to fast-forward; ` to rewind; F1-F4 to
-- load a state and Shift+F1-F4 to save one). WASD works as a second D-pad:
-- emulators leave those keys to the GBA's shoulder buttons, which a Game Boy
-- Color does not have. Turbo A/B have no common default; C and V sit next to
-- Z and X. L and R (Game Boy Advance games only) are on Q and E, either side
-- of that second D-pad. /mb bind changes any of them.
local DEFAULT_KEYS = {
    up = { "UP", "W" }, down = { "DOWN", "S" }, left = { "LEFT", "A" }, right = { "RIGHT", "D" },
    a = { "X" }, b = { "Z" }, start = { "ENTER" }, select = { "BACKSPACE" },
    l = { "Q" }, r = { "E" },
    turboa = { "C" }, turbob = { "V" },
    ff = { "TAB" }, rewind = { "`" },
    volup = { "=" }, voldown = { "-" },
}
local BUTTON_ORDER = { "up", "down", "left", "right", "a", "b", "start", "select", "l", "r",
                       "turboa", "turbob", "ff", "rewind", "volup", "voldown" }
local BUTTON_NAMES = {
    up = "Up", down = "Down", left = "Left", right = "Right", a = "A", b = "B", start = "Start",
    select = "Select", l = "L (Advance games)", r = "R (Advance games)", turboa = "Turbo A", turbob = "Turbo B", ff = "Fast-forward (hold)",
    rewind = "Rewind (hold)", volup = "Volume up", voldown = "Volume down",
}
local STATE_KEYS = { F1 = 1, F2 = 2, F3 = 3, F4 = 4 }   -- load; with Shift: save
local PAD = { up = true, down = true, left = true, right = true, a = true, b = true, start = true, select = true, l = true, r = true }

-- Palettes for original (monochrome) Game Boy games: four 15-bit colors, lightest first.
local function rgb15(r, g, b) return floor(r / 8) + floor(g / 8) * 32 + floor(b / 8) * 1024 end
local PALETTES = {
    gray   = { rgb15(255, 255, 255), rgb15(170, 170, 170), rgb15(85, 85, 85), rgb15(0, 0, 0) },
    green  = { rgb15(155, 188, 15), rgb15(139, 172, 15), rgb15(48, 98, 48), rgb15(15, 56, 15) },
    pocket = { rgb15(196, 207, 161), rgb15(139, 149, 109), rgb15(77, 83, 60), rgb15(31, 31, 31) },
    brown  = { rgb15(255, 255, 255), rgb15(255, 173, 99), rgb15(132, 49, 0), rgb15(0, 0, 0) },
    blue   = { rgb15(255, 255, 255), rgb15(99, 165, 255), rgb15(0, 0, 255), rgb15(0, 0, 0) },
    red    = { rgb15(255, 255, 255), rgb15(255, 132, 132), rgb15(148, 58, 58), rgb15(0, 0, 0) },
    leaf   = { rgb15(255, 255, 255), rgb15(123, 255, 49), rgb15(0, 132, 0), rgb15(0, 0, 0) },
    ember  = { rgb15(255, 246, 211), rgb15(249, 168, 117), rgb15(235, 107, 111), rgb15(124, 63, 88) },
}
local PALETTE_ORDER = { "gray", "green", "pocket", "brown", "blue", "red", "ember" }
-- A Game Boy Color picks colors for some original Game Boy games by itself:
-- one palette for the background and one for each of the two sprite layers.
-- These are the choices it makes for the games listed.
local GAME_PALETTES = {
    POKEMON_RED  = { "red", "leaf", "red" },
    POKEMON_BLUE = { "blue", "red", "blue" },
}

-- The cartridge in the slot (its id), or nil. Until you choose, that is the
-- one you played last; with a single cartridge on the shelf, that one.
local slot = nil
local function inserted()
    if slot and MB.Carts.Find(slot) then return slot end
    slot = nil
    local last = MB.DB().lastCart
    if last and MB.Carts.Find(last) then
        slot = last
    else
        local list = MB.Carts.List()
        if #list == 1 then slot = list[1].id end
    end
    return slot
end
local function romReady() return inserted() ~= nil end
MB.onLogin[#MB.onLogin + 1] = function() slot = nil end   -- "the one you played last" is only known once saved settings arrive

-- The keyboard belongs to the console whenever it is open: this frame is
-- visible with the window and keeps every key, so nothing you press while
-- playing moves your character or opens a menu. Close the console (ESC, or
-- the red stud) to get your normal keys back. It is never open in combat.
local keyCapture = CreateFrame("Frame", nil, MB.window)
keyCapture:SetAllPoints(MB.window)
keyCapture:EnableMouse(false)
keyCapture:EnableKeyboard(true)
local running = false                -- is the game advancing (as opposed to paused)?

-- -------------------------------------------------------------- state ---
local machine, saveKey
local storeKey                       -- where its save, valves and resume point are kept (MB.SaveKey: ours keep one per character)
local grids = {}                     -- one screenful of dots for each kind of machine, made when first needed
local grid                           -- the one in use: { holder, rows, tex, shown, RC, GC, BC }
local keymap = {}                    -- key name -> button
local held = {}                      -- buttons currently held
local holders = {}                   -- button -> the inputs holding it down (each key, the on-screen pad...): it is let go
                                     -- only when the last of them is (Up and W both held, Up let go: still Up)
-- A key let go while the keyboard is with something else (a chat line, a window of the game client that came up
-- by itself, another program) is never reported to an addon: its button would stay down and the hero walk on
-- by himself. So the keys held are checked against the keyboard itself on every frame (for each key the client
-- was seen to answer truthfully about, asked at the moment it went down), and all are let go while a text box,
-- or the client's own window of errors and warnings, has the keyboard.
local keysDown, keyTrusted = {}, {}  -- key -> the button it holds down; key -> can the client be asked about it
local keyIsDown = IsKeyDown
-- What the client makes of this addon's work, for the settings file (written at logout): how long the main loop's
-- turns ran, the client's warnings about scripts that run long, keys that had to be let go unseen.
local watch = { turns = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, longest = 0, sinceWarning = 0, letGo = 0, elsewhere = 0, warnings = {}, warned = 0 }
local owed, frameCost = 0, 4
-- how often the picture is shown: every frame, every 2nd or every 3rd. The game itself always runs at full
-- speed; on a slow computer (or a busy scene) showing every other picture is what keeps WoW itself smooth.
local pictureEvery, sinceDrawn = 1, 0
local costDrawn, costBlind, costPaint, blindSeen = 4, 2, 1, false     -- running averages, ms
local scanAll = true                 -- the next picture must check every line, not only those the game redrew
local setColor                      -- the textures' SetVertexColor, fetched once
local statFrames, statTime = 0, 0
-- /mb profile: a run of one-second samples of where the time goes (prof = nil when not recording)
local prof
local dotsSet, turnMaxSec, gcPrev = 0, 0, nil
local frameNo = 0
local broken = false
local history, lastSnap = {}, nil    -- rewind snapshots, oldest first
local rewindAcc = 0
local pokes = {}                     -- GameShark writes applied every frame
local note, noteUntil = nil, 0       -- a short message shown on the status plate
local speedText = ""
local waiting = false                -- linked, and held still until the other player's game answers
local secShown = 0

local function playing() return running end
function MB.IsRunning() return running end
function MB.Machine() return machine end       -- the running game, for the link and for tools
-- the cartridge in the slot (its id), its system and whether it is playing: for /mb bug
function MB.CurrentCart() return saveKey, sys and sys.kind, running and true or false end
function MB.CurrentStore() return storeKey or saveKey end      -- where the running game's battery save is kept

-- the system the cartridge in the slot needs
local function slotSys()
    local c = inserted() and MB.Carts.Find(inserted())
    if c and c.system == "gba" then return MB.AdvanceSystem or GBSYS end
    if c and c.system == "native" then return MB.NativeSystem or GBSYS end
    return GBSYS
end
local NOT_ADVANCE = "Not for Advance games yet"

local function gameName()
    local c = inserted() and MB.Carts.Find(inserted())
    return c and c.name or "Game"
end

local function refreshStatus()
    if note and GetTime() < noteUntil then
        MB.SetStatus(note)
    elseif playing() and waiting then
        MB.SetStatus("Waiting for the other player's game")
    elseif playing() then
        MB.SetStatus(gameName() .. speedText)
    elseif broken then
        MB.SetStatus("Out of order")
    elseif romReady() then
        MB.SetStatus(gameName())
    else
        MB.SetStatus("No cartridge")
    end
end

local function flash(msg)
    note, noteUntil = msg, GetTime() + 2.5
    refreshStatus()
end

local function rebuildKeymap()
    keymap = {}
    local saved = MB.Opt("keys", nil) or {}
    for button, keys in pairs(DEFAULT_KEYS) do
        if not saved[button] then
            for _, k in ipairs(keys) do keymap[k] = button end
        end
    end
    for button, keys in pairs(saved) do -- your own choices win over defaults
        for _, k in ipairs(keys) do keymap[k] = button end
    end
end
rebuildKeymap()
MB.onLogin[#MB.onLogin + 1] = rebuildKeymap   -- saved bindings arrive after this file has run

function MB.KeyLabel(button)
    local saved = MB.Opt("keys", nil)
    local keys = (saved and saved[button]) or DEFAULT_KEYS[button]
    return keys and table.concat(keys, " or ") or nil
end

function MB.HelpText()
    return "Click the screen to play. ESC pauses.\n"
        .. "D-pad: arrow keys or WASD.  A: " .. MB.KeyLabel("a") .. ".  B: " .. MB.KeyLabel("b") .. ".\n"
        .. "Start: " .. MB.KeyLabel("start") .. ".  Select: " .. MB.KeyLabel("select") .. ".\n"
        .. "L and R (Advance games): " .. MB.KeyLabel("l") .. " and " .. MB.KeyLabel("r") .. ".\n"
        .. "Fast-forward: hold " .. MB.KeyLabel("ff") .. ".  Rewind: hold " .. MB.KeyLabel("rewind") .. ".\n"
        .. "Volume: " .. MB.KeyLabel("volup") .. " and " .. MB.KeyLabel("voldown") .. ", or the wheel under the screen.\n"
        .. "Load a state: F1-F4.  Save one: Shift+F1-F4.\n"
        .. "Change cartridge: " .. MB.KeyLabel("select") .. " while paused, or /mb carts.\n"
        .. "While the console is open it has the keyboard to itself;\nESC twice (or the red stud) puts it away.\n"
        .. "Click here to list every /mb command."
end

-- ------------------------------------------------------------- screen ---
-- Each band of the screen is drawn by the client into a picture of its own, which it reuses until a dot in the
-- band changes. This is not a nicety: without it the client draws every dot afresh every frame, and with more than
-- about 16,000 such dots on screen it stops drawing its whole interface and then freezes (seen 12 October 2026).
-- So there is no way to switch it off (/mb plain is gone).
local function applyBuffering()
    for _, g in pairs(grids) do
        for _, row in ipairs(g.rows) do
            if row.SetFlattensRenderLayers and row.SetIsFrameBuffer then
                row:SetFlattensRenderLayers(true) -- must come first
                row:SetIsFrameBuffer(true)
            end
        end
    end
end

-- The dots. The screen is as big as a Game Boy Advance picture (240 x 160);
-- a Game Boy picture (160 x 144) sits in the middle of it at the same dot
-- size, as it did on the real thing. Each kind has its own set of dots, made
-- the first time such a game is switched on.
-- The dots are held by frames of two screen lines each ("bands"), for two
-- limits of the client:
--  * a single frame cannot hold them all (past roughly 16,000 child regions
--    the client stops drawing the whole interface);
--  * the client keeps only so many frames drawn into pictures of their own
--    (see applyBuffering): some 225 to 232 in all, and one more closes it with
--    "ASSERT(s_cachedTextureList.size() < CachedTextureUnmanaged)". A frame a
--    line would take 160 of those for an Advance game and 144 more for a Game
--    Boy game; two lines to a frame takes 80 and 72, and leaves room for
--    other addons that do the same.
local BAND = 2
local function buildScreen()
    local W, H = sys.W, sys.H
    local g = grids[sys.kind]
    if not g then
        g = { rows = {}, tex = {}, shown = {}, RC = {}, GC = {}, BC = {} }
        local holder = CreateFrame("Frame", nil, screen)
        holder:SetSize(W * CELL, H * CELL)
        local room = MB.Layout.screen
        holder:SetPoint("TOPLEFT", floor((room[3] - W * CELL) / 2), -floor((room[4] - H * CELL) / 2))
        g.holder = holder
        local rows, tex, shown = g.rows, g.tex, g.shown
        local i = 0
        for y0 = 0, H - 1, BAND do
            local lines = math.min(BAND, H - y0)
            local row = CreateFrame("Frame", nil, holder)
            row:SetSize(W * CELL, lines * CELL)
            row:SetPoint("TOPLEFT", 0, -y0 * CELL)
            rows[#rows + 1] = row
            for l = 0, lines - 1 do                     -- (dots are numbered line by line, as the painter counts them)
                for x = 0, W - 1 do
                    i = i + 1
                    local t = row:CreateTexture(nil, "ARTWORK")
                    t:SetColorTexture(1, 1, 1, 1)
                    t:SetSize(CELL, CELL)
                    t:SetPoint("TOPLEFT", x * CELL, -l * CELL)
                    t:SetVertexColor(0, 0, 0)
                    tex[i] = t
                    shown[i] = 0
                end
            end
        end
        setColor = tex[1].SetVertexColor
        grids[sys.kind] = g
        applyBuffering()
    end
    for _, other in pairs(grids) do other.holder:SetShown(other == g) if other.labelFrame then other.labelFrame:SetShown(other == g) end end
    grid = g
    scanAll = true
end

-- 15-bit Game Boy color -> what to show. "lcd" imitates the washed, slightly
-- cross-mixed colors of the real Game Boy Color screen; "raw" is the plain value.
function GBSYS.color(c, RC, GC, BC)
    local r5 = c % 32
    local g5 = ((c - r5) / 32) % 32
    local b5 = (c - r5 - g5 * 32) / 1024
    local r, g, b
    if MB.Opt("color", "lcd") == "raw" then
        r, g, b = r5 / 31, g5 / 31, b5 / 31
    else
        r = math.min(960, r5 * 26 + g5 * 4 + b5 * 2) / 960
        g = math.min(960, g5 * 24 + b5 * 8) / 960
        b = math.min(960, r5 * 6 + g5 * 4 + b5 * 22) / 960
    end
    RC[c], GC[c], BC[c] = r, g, b
    return r
end

-- Names over friends' ghosts (GBA/Ghosts.lua): small labels anchored to the dot above each ghost's head
local function placeLabels(g, labels)
    local pool = g.labels
    local n = labels and #labels or 0
    if not pool then
        if n == 0 then return end                                -- (made only once a label is needed)
        pool = {} g.labels = pool
        -- (a frame of its own, above the rows of dots: a frame's own text would be drawn under its child frames;
        -- beside the holder rather than inside it, since the holder's children are the rows)
        local lf = CreateFrame("Frame", nil, screen)
        lf:SetAllPoints(g.holder)
        lf:SetFrameLevel(g.holder:GetFrameLevel() + 2)
        g.labelFrame = lf
    end
    for i = 1, n do
        local fs = pool[i]
        if not fs then
            fs = g.labelFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetTextColor(1, 0.95, 0.8)
            fs:SetShadowColor(0, 0, 0, 1)
            pool[i] = fs
        end
        local l = labels[i]
        local x = math.max(12, math.min(sys.W - 12, floor(l.x + 0.5)))
        local y = math.max(7, math.min(sys.H, floor(l.y + 0.5)))      -- (never above the top edge of the screen)
        fs:SetText(l.name)
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOM", g.holder, "TOPLEFT", x * CELL, -y * CELL)
        fs:Show()
    end
    for i = n + 1, #pool do pool[i]:Hide() end
end

-- Put the game's picture on the screen. Only dots whose color changed are
-- touched, and only lines the game says it redrew are even looked at.
local function present()
    local g = grid
    local fb, dirty = machine.fb, machine.lineDirty
    local shown, tex, RC, GC, BC, set = g.shown, g.tex, g.RC, g.GC, g.BC, setColor
    local colorOf = sys.color
    local W, H = sys.W, sys.H
    local all = scanAll or not dirty
    scanAll = false
    local over, overLines
    if MB.Ghosts then
        local gok, o, l = pcall(MB.Ghosts.Overlay, machine)
        if gok then over, overLines = o, l else MB.Ghosts.Fail(o) end
        placeLabels(g, MB.Ghosts.labels)
    end
    local i, n = 0, 0
    for y = 1, H do
        local ol = overLines and overLines[y]
        if all or (dirty and dirty[y]) or ol then
            if dirty then dirty[y] = false end
            if ol then
                for k = i + 1, i + W do
                    local c = over[k] or fb[k]
                    if c ~= shown[k] then
                        shown[k] = c
                        n = n + 1
                        local r = RC[c] or colorOf(c, RC, GC, BC)
                        set(tex[k], r, GC[c], BC[c])
                    end
                end
            else
                -- (the common case, kept as short as it will go: this runs for every dot of every line redrawn)
                for k = i + 1, i + W do
                    local c = fb[k]
                    if c ~= shown[k] then
                        shown[k] = c
                        n = n + 1
                        local r = RC[c] or colorOf(c, RC, GC, BC)
                        set(tex[k], r, GC[c], BC[c])
                    end
                end
            end
        end
        i = i + W
    end
    dotsSet = dotsSet + n
end

local function redrawAll()
    scanAll = true
    if not grid then return end
    grid.RC, grid.GC, grid.BC = {}, {}, {}
    for i = 1, sys.W * sys.H do grid.shown[i] = -1 end
    if machine then present() end
end
function MB.RedrawAll() redrawAll() end     -- for the speed test

-- -------------------------------------------------------- game control ---
local function applyPalette()
    if not machine or sys ~= GBSYS then return end
    local function shades(name)
        local p = PALETTES[name] or PALETTES.gray
        return { [0] = p[1], p[2], p[3], p[4] }
    end
    local chosen = (MB.Opt("palettes", nil) or {})[saveKey]      -- your own choice for this game
    local auto = GAME_PALETTES[saveKey]
    if chosen or not auto then
        local t = shades(chosen or MB.Opt("palette", "gray"))
        machine.setDmgPalette(t, t, t)
    else
        machine.setDmgPalette(shades(auto[1]), shades(auto[2]), shades(auto[3]))
    end
end

local function applyCheats()
    if not machine or sys ~= GBSYS then return end
    local list = MB.DB().cheats[saveKey]
    local patches
    pokes, patches = MB.Cheats.compile(MB.Opt("cheats", true) and list or nil)
    machine.setRomPatches(patches)
end

local function idleMessage()
    if broken then return "The works have jammed.\n/mb reset to try again." end
    local count = #MB.Carts.List()
    if count == 0 then return "No cartridge yet.\nClick the screen or press " .. MB.KeyLabel("start") .. " to add a game you own." end
    if not romReady() then return "Press " .. MB.KeyLabel("start") .. " to choose a cartridge" end
    local swap = count > 1 and ("\n" .. MB.KeyLabel("select") .. ": change cartridge") or ""
    if machine then return "Paused\nClick the screen or press " .. MB.KeyLabel("start") .. " to play" .. swap end
    return gameName() .. "\nClick the screen or press " .. MB.KeyLabel("start") .. " to switch on" .. swap
end

local function pause()
    running = false
    for button in pairs(held) do MB.SetPressed(button, false) end
    for button in pairs(PAD) do MB.SetPressed(button, false) end
    held, holders = {}, {}
    for key in pairs(keysDown) do keysDown[key] = nil end
    if machine then sys.release(machine) end
    waiting = false
    MB.SetPower(false)
    MB.SetScreenMessage(idleMessage())
    refreshStatus()
    MB.Sound.Pause()
end

-- Something in the world needs the player (a ready check, a dungeon group...): stop the game and
-- say why on the screen. Returns false when no game was running (nothing to stop).
function MB.PauseFor(reason)
    if not running then return false end
    pause()
    MB.SetScreenMessage(reason .. "\nClick the screen or press " .. MB.KeyLabel("start") .. " to play on")
    return true
end
-- a few words on the status plate, for a moment
function MB.Note(msg) flash(msg) end

-- Is this key press the player's own "open or close MekkaBoy" key (Key Bindings > AddOns)?
-- The open console keeps the keyboard, so it has to notice that key itself.
local function isToggleKey(key)
    if not GetBindingKey then return false end
    local chord = ((IsAltKeyDown and IsAltKeyDown()) and "ALT-" or "") .. ((IsControlKeyDown and IsControlKeyDown()) and "CTRL-" or "")
        .. ((IsShiftKeyDown and IsShiftKeyDown()) and "SHIFT-" or "") .. key
    if chord == key and keymap[key] then return false end       -- a key the game itself uses stays the game's
    local k1, k2 = GetBindingKey("MEKKABOY_TOGGLE")
    return chord == k1 or chord == k2
end

-- Where this game's memory valves (and its resume point) are kept, which is the system's business:
-- with the settings for a Game Boy game, in a side file of their own for an Advance game.
local function gameStates(which)
    return (which or sys or slotSys()).statesFor(storeKey or MB.SaveKey(saveKey))
end
function GBSYS.statesFor(key)
    local states = MB.Saves().states
    states[key] = states[key] or {}
    return states[key]
end
-- (a system's "pack" and "unpack" turn a state into something a settings file can hold, and back)
function GBSYS.pack(st) return MB.GB.encodeState(st) end
function GBSYS.unpack(st) return MB.GB.decodeState(st) end

function GBSYS.release(m) m.releaseAllKeys() end

-- (a system's "new" makes the machine for a cartridge, with its save in it; it may also return a
-- few words for the status plate)
function GBSYS.new(rom)
    local saves = MB.Saves()
    if MB.DB().testSaves and saves.gb[rom.id] == nil and MB.TestSaves then
        -- practice saves are on and this game has not been played with them yet: put the ready-made one in
        saves.gb[rom.id] = MB.TestSaves.For("gb", rom.banks[1]:byte(0x14F) * 256 + rom.banks[1]:byte(0x150)) or false
    end
    return MB.GB.new({
        bank = function(n) return rom.banks[n + 1] end,
        numBanks = rom.numBanks,
        save = saves.gb[rom.id] or nil,
        now = time,
    })
end

-- (a system's "keep" hands the game's own save to the settings)
function GBSYS.keep(m, key)
    if m.hasBattery then MB.Saves().gb[key] = m.getSave() MB.BatteryKept(key) end
end

-- Create the machine. fresh = true ignores the "resume where I left off" state.
local function start(fresh)
    if machine or broken then return machine ~= nil end
    if not (MB.GB and romReady()) then return false end
    local rom, why = MB.Carts.Load(inserted())
    if not rom then
        Print(why)
        return false
    end
    local want = GBSYS
    if rom.system == "gba" then
        want = MB.GBA and MB.AdvanceSystem
        if not want then
            Print("The Game Boy Advance part is not loaded: restart the game client.")
            return false
        end
    elseif rom.system == "native" then
        want = MB.NativeSystem
        if not want then
            Print("The native cartridge part is not loaded: restart the game client.")
            return false
        end
    end
    sys = want
    saveKey = rom.id
    storeKey = MB.SaveKey(rom.id, rom)
    MB.DB().lastCart = rom.id
    local ok, res, word = pcall(sys.new, rom, storeKey)
    if not (ok and res) then
        broken = true
        Print("The game failed to start: " .. tostring(res))
        return false
    end
    machine = res
    history, lastSnap, frameNo = {}, nil, 0
    frameCost, costDrawn, costBlind, costPaint, blindSeen = 4, 4, 2, 1, false
    pictureEvery, sinceDrawn = 1, 0
    applyPalette()
    applyCheats()
    if sys.states and not fresh and MB.Opt("resume", true) then
        local states = gameStates()
        local st = states.resume
        if st and states.resumeRev and states.resumeRev ~= MB.BatteryRev(storeKey) then
            -- the battery save was kept after this resume point was made: it is the newer progress
            states.resume, states.resumeRev, st = nil, nil, nil
            Print("Your game's own save is newer than the resume point, so it starts from the save.")
        end
        if st then
            local ok2, good, why = pcall(function() return machine.loadState(sys.unpack(st)) end)
            if ok2 and good then
                if sys.loaded then sys.loaded(machine) end
                word = nil          -- (it carries on from where it was: no need to say which save is in)
            else
                states.resume, states.resumeRev = nil, nil
                if ok2 and why then Print("The resume point was not used (" .. tostring(why) .. "); the game starts from its save.") end
            end
        end
    end
    if sys.kind == "native" then
        for _, g in pairs(grids) do g.holder:Hide() if g.labelFrame then g.labelFrame:Hide() end end      -- a native cartridge draws on the screen itself
    else
        buildScreen()
    end
    MB.Sound.Attach(machine, saveKey)
    if MB.Link and MB.Link.MachineChanged then MB.Link.MachineChanged(sys.kind ~= "native" and machine or nil) end
    if MB.Ghosts then MB.Ghosts.MachineChanged(machine, sys.kind) end
    if word then flash(word) end
    return true
end

-- Battery saves and the resume point live in memory until the game writes
-- its settings file (logout or /reload); this hands them over.
function MB.SaveGame()
    if not (machine and saveKey) then return end
    sys.keep(machine, storeKey or saveKey, true)
    if not sys.states then return end
    local states = gameStates()
    if MB.Opt("resume", true) then
        local ok, st = pcall(function() return sys.pack(machine.saveState()) end)
        if ok then states.resume, states.resumeRev = st, MB.BatteryRev(storeKey or saveKey)
        else states.resume, states.resumeRev = nil, nil end         -- (an old one would be older than the save just kept)
    elseif states.resume then
        states.resume, states.resumeRev = nil, nil                  -- resume is off: the save just kept is the newest progress
    end
end

-- Put a battery save back (a trade undone on this side, GBA/Trade3.lua) and restart the game from it. Only for the
-- game running now; the resume point goes too, since it is from after the trade.
function MB.RestoreBattery(store, save)
    if not (machine and sys.kind == "gba" and (storeKey or saveKey) == store and type(save) == "table" and save.sectors) then return false end
    pause()
    machine = nil
    MB.Sound.Stop()
    MB.Sound.Attach(nil)
    if MB.Link and MB.Link.MachineChanged then MB.Link.MachineChanged(nil) end
    if MB.Ghosts then MB.Ghosts.MachineChanged(nil) end
    MB.Saves().gba[store] = { kind = save.kind or "flash128", sectors = save.sectors, at = (date and date("%Y-%m-%d %H:%M") or "?") .. " (before an undone trade)" }
    MB.BatteryKept(store)
    local states = gameStates()
    states.resume, states.resumeRev = nil, nil
    history, lastSnap = {}, nil
    broken = false
    if start(true) then
        pcall(machine.runFrame, true)
        present()
        MB.SetScreenMessage(gameName() .. " restarted from before the trade\nClick the screen to play")
    end
    return true
end

-- true while two games are in a link session: no going back in time then
local function linkBusy() return (MB.Link and MB.Link.Busy and MB.Link.Busy()) or (MB.Trade3 and MB.Trade3.Busy()) end
local function linkBlocks(button) return MB.Link and MB.Link.BlocksKey and MB.Link.BlocksKey(button) end

-- A game can ask the console not to rewind it mid-action (MekkaBoy's own games set a hint while a hand/turn is live, so
-- memory valves and /mb reset cannot be used to undo an outcome). A 4-byte magic guards the hint, so a game that never
-- sets it is never treated as busy, and a non-Advance machine that has nothing there reads no magic.
local function gameBusy()
    if not (machine and machine.rd32 and machine.rd8) then return false end
    local ok, busy = pcall(function() return machine.rd32(0x03007E08) == 0x4843424D and machine.rd8(0x03007E0C) ~= 0 end)
    return (ok and busy) and true or false
end
-- The same hint carries a 24-bit fingerprint of the game's progress. A valve is stamped with it when saved, and loads only
-- while the game's fingerprint still matches, so a valve cannot rewind such a game past a round it has played.
-- nil for a game that publishes no hint (every outside game): its valves are untouched.
local function gameRecord()
    if not (machine and machine.rd32 and machine.rd8) then return nil end
    local ok, v = pcall(function()
        if machine.rd32(0x03007E08) ~= 0x4843424D then return nil end
        return machine.rd8(0x03007E0D) + machine.rd8(0x03007E0E) * 256 + machine.rd8(0x03007E0F) * 65536
    end)
    if ok then return v end
    return nil
end

-- what a refused valve says, per game (the fingerprint moves on a played hand in Overload, on a trade in Critter Crate)
local RECORD_WORDS = { OVERLOAD = "That valve is from before a round you played", CRITTERCRATE = "That valve is from before a trade" }

local function saveSlot(n)
    if not slotSys().states then flash(NOT_ADVANCE) return end
    if not machine then flash("Switch it on first") return end
    if linkBusy() then flash("Not while linked") return end
    if gameBusy() then flash("Not in the middle of a round") return end
    local ok, st = pcall(function() return sys.pack(machine.saveState()) end)
    if not ok then flash("Could not save") MB.DB().lastError = { game = saveKey, error = "valve: " .. tostring(st):sub(1, 400) } return end
    st.when = date and date("%b %d %H:%M") or ""
    st.record = gameRecord()                       -- (nil for a game without the hint)
    gameStates()[n] = st
    flash(("Saved to valve %d"):format(n))
end

local function loadSlot(n)
    if not slotSys().states then flash(NOT_ADVANCE) return end
    if linkBusy() then flash("Not while linked") return end
    if gameBusy() then flash("Not in the middle of a round") return end
    if not machine and not start() then flash("No cartridge") return end
    local st = gameStates()[n]
    if not st then flash(("Valve %d is empty"):format(n)) return end
    local live = gameRecord()
    -- a valve with a record, on a game that has not published one yet (just switched on or reset): wait for it, or the
    -- check would be skipped. A valve kept before the game had a record counts as 0 (its count started at 0); one from an
    -- older build of the game is then turned away by the machine itself ("the game has changed").
    if st.record ~= nil and live == nil then flash("Let the game start, then load the valve") return end
    if live ~= nil and (st.record or 0) ~= live then flash(RECORD_WORDS[(saveKey or ""):match("^([^@]+)") or ""] or "That valve is from before something that can't be undone") return end
    local ok, good, why = pcall(function() return machine.loadState(sys.unpack(st)) end)
    if ok and good then
        if sys.loaded then sys.loaded(machine) end
        history, lastSnap = {}, nil
        pcall(machine.runFrame, true)
        present()
        MB.Sound.Resync()
        flash(("Loaded valve %d"):format(n))
    else
        flash("Could not load: " .. tostring(ok and why or good))
    end
end

-- when a valve was last saved (for its tooltip)
function MB.StateInfo(n)
    saveKey = saveKey or inserted()
    if not saveKey or not slotSys().states then return nil end
    local st = gameStates(slotSys())[n]
    return st and ((st.when and st.when ~= "") and st.when or "earlier") or nil
end

local function crashed(err)
    broken = true
    MB.DB().lastError = { game = saveKey, at = date and date("%Y-%m-%d %H:%M:%S") or "?", error = tostring(err):sub(1, 4000) }
    pcall(MB.SaveGame)
    machine = nil
    MB.Sound.Stop()
    MB.Sound.Attach(nil)
    if MB.Link and MB.Link.MachineChanged then MB.Link.MachineChanged(nil) end
    if MB.Ghosts then MB.Ghosts.MachineChanged(nil) end
    pause()
    Print("The emulator hit an error and stopped: " .. tostring(err))
end

-- one emulated frame, with everything that rides along with it
local function step(render)
    frameNo = frameNo + 1
    if held.turboa and not holders.a and not linkBlocks("a") then machine.setKey("a", frameNo % 4 < 2) end   -- (A held as well: held)
    if held.turbob and not holders.b and not linkBlocks("b") then machine.setKey("b", frameNo % 4 < 2) end
    for i = 1, #pokes do machine.poke(pokes[i].addr, pokes[i].value) end
    local ok, err = pcall(machine.runFrame, render)
    if not ok then crashed(err) return false end
    local ghosts = MB.Ghosts                     -- (other trainers walking in a Gen 3 game: GBA/Ghosts.lua)
    if ghosts then
        local gok, gerr = pcall(ghosts.Frame, machine, render)
        if not gok then ghosts.Fail(gerr) end
    end
    if MB.Trade3 and sys.kind == "gba" then      -- (Gen 3 trades: where you stand, and each trade's save watched)
        local tok, terr = pcall(MB.Trade3.Frame, machine)
        if not tok then Print("Trade: " .. tostring(terr)) pcall(MB.Trade3.Fail) end
    end
    if sys.rewind and frameNo % REWIND_EVERY == 0 and MB.Opt("rewind", true) and not linkBusy() then
        lastSnap = machine.saveState(lastSnap)
        history[#history + 1] = lastSnap
        if #history > MB.Opt("rewindSeconds", 40) * 5 then table.remove(history, 1) end
    end
    return true
end

-- ------------------------------------------------------ cartridge slot ---
-- Take the game out: it is saved first, exactly as when you log out.
local function eject()
    if grid and grid.labels then placeLabels(grid, nil) end
    if machine then
        pcall(MB.SaveGame)
        pause()
        MB.Sound.Stop()
        MB.Sound.Attach(nil)
        if sys.stop then pcall(sys.stop, machine) end
        machine = nil
        if MB.Link and MB.Link.MachineChanged then MB.Link.MachineChanged(nil) end
    if MB.Ghosts then MB.Ghosts.MachineChanged(nil) end
    end
    saveKey, storeKey, broken = nil, nil, false
    history, lastSnap = {}, nil
    pokes = {}
end

-- (for /mb testsave: the game is put away, saved, before the saves it reads are changed)
function MB.EjectGame()
    local had = saveKey
    eject()
    if had then
        MB.SetScreenMessage(idleMessage())
        refreshStatus()
    end
end

local picking = nil                  -- choosing a cartridge: { list =, index = }
local switchOn
local PICK_ROWS = 7

local function drawPicker()
    local list, at = picking.list, picking.index
    local first = math.max(1, math.min(at - floor(PICK_ROWS / 2), #list - PICK_ROWS + 1))
    local lines = { "Cartridges", "" }
    for i = first, math.min(#list, first + PICK_ROWS - 1) do
        local name = list[i].name
        if #name > 26 then name = name:sub(1, 25) .. "..." end
        lines[#lines + 1] = (i == at) and ("> " .. name .. " <") or name
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Up and Down, then " .. MB.KeyLabel("a") .. ".  " .. MB.KeyLabel("b") .. " goes back."
    MB.SetScreenMessage(table.concat(lines, "\n"))
    MB.SetStatus(("Cartridge %d of %d"):format(at, #list))
end

local function closePicker()
    picking = nil
    MB.SetScreenMessage(idleMessage())
    refreshStatus()
end

local function openPicker()
    local list = MB.Carts.List()
    if #list == 0 then
        MB.SetScreenMessage(idleMessage())
        return
    end
    if playing() then pause() end
    picking = { list = list, index = 1 }
    local now = inserted()
    for i, c in ipairs(list) do
        if c.id == now then picking.index = i end
    end
    drawPicker()
end

-- put a cartridge in and switch on
local function insert(id)
    picking = nil
    if not MB.Carts.Find(id) then return false end
    if id ~= saveKey then
        eject()
        slot = id
        MB.DB().lastCart = id
    end
    MB.SetScreenMessage(idleMessage())
    refreshStatus()
    switchOn()
    return true
end

-- put a cartridge in and switch on, opening the console if need be
function MB.PlayCart(id)
    if InCombatLockdown() then Print("Not in combat.") return false end
    if not MB.window:IsShown() then MB.Show(false) end
    return insert(id)
end

local function pickerButton(button)
    local n = #picking.list
    if button == "up" then
        picking.index = (picking.index - 2) % n + 1
        drawPicker()
    elseif button == "down" then
        picking.index = picking.index % n + 1
        drawPicker()
    elseif button == "a" or button == "start" then
        insert(picking.list[picking.index].id)
    elseif button == "b" or button == "select" then
        closePicker()
    end
end

-- --------------------------------------------------------------- input ---
switchOn = function()
    if broken then return end
    if playing() then return end
    if InCombatLockdown() then
        flash("Not in combat")
        return
    end
    if picking then
        insert(picking.list[picking.index].id)
        return
    end
    if not romReady() and #MB.Carts.List() > 1 then
        openPicker()
        return
    end
    if #MB.Carts.List() == 0 and MB.Import then      -- nothing to play yet: show how to add a game
        MB.Import.Open()
        return
    end
    if not start() then
        MB.SetScreenMessage(idleMessage())
        refreshStatus()
        return
    end
    -- the first game Together knows: one question (play with the realm?) before it runs; the answer starts it
    if MB.Ghosts and MB.Ghosts.AskFirst then
        local ok, asking = pcall(MB.Ghosts.AskFirst, switchOn)
        if ok and asking then
            MB.SetScreenMessage("One question before you play")
            refreshStatus()
            return
        end
    end
    owed = 0
    running = true
    MB.SetPower(true)
    MB.SetScreenMessage(nil)
    speedText = ""
    refreshStatus()
    MB.Sound.Run()
end
MB.OnScreenClick = switchOn

local function applyHeld(button, down)
    if PAD[button] then
        -- (while linked, the player who leads picks the room: the other's A and B wait)
        if down and linkBlocks(button) then return end
        if machine and sys.pad[button] then machine.setKey(button, down) end
        -- (talking to a friend's ghost: every way of pressing A, the keyboard and the pad and the on-screen button)
        if down and button == "a" and MB.Ghosts and MB.Ghosts.Pressed then pcall(MB.Ghosts.Pressed, "a") end
    elseif down then
        if button == "rewind" and not sys.rewind then flash(NOT_ADVANCE) return end
        held[button] = true
    else
        held[button] = nil
        if machine and button == "turboa" and not holders.a then machine.setKey("a", false) end   -- (an A held some other way stays)
        if machine and button == "turbob" and not holders.b then machine.setKey("b", false) end
    end
end
-- one input (src: "key:W", "pad", ...) presses or lets go of a button
local function setHeld(button, down, src)
    src = src or "pad"
    local h = holders[button]
    if down then
        if not h then h = {} holders[button] = h end
        h[src] = true
        applyHeld(button, true)
        return true
    end
    if h then h[src] = nil if next(h) then return false end end   -- (another input still holds it)
    holders[button] = nil
    applyHeld(button, false)
    return true
end
local function shown(button) return button == "turboa" and "a" or button == "turbob" and "b" or button end

local function keyLetGo(key)
    local button = keysDown[key]
    if not button then return end
    keysDown[key] = nil
    if setHeld(button, false, "key:" .. key) then MB.SetPressed(shown(button), false) end
end
local function checkKeys()
    if not next(keysDown) then return end
    local elsewhere = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if not elsewhere then
        local f = ScriptErrorsFrame
        if type(f) == "table" and f.IsShown and f:IsShown() then elsewhere = true end
    end
    for key in pairs(keysDown) do
        if elsewhere then
            watch.elsewhere = watch.elsewhere + 1
            keyLetGo(key)
        elseif keyTrusted[key] and not keyIsDown(key) then
            watch.letGo = watch.letGo + 1
            keyLetGo(key)
        end
    end
end

-- the on-screen buttons
function MB.OnPad(button, down)
    if playing() then
        setHeld(button, down, "pad")
    elseif down and not InCombatLockdown() then
        if picking then pickerButton(button)
        elseif button == "start" then switchOn()
        elseif button == "select" then openPicker() end
    end
end
function MB.OnAction(button, down)
    if playing() then setHeld(button, down, "action") end
end
-- the volume wheel (and its keys): one notch louder or quieter
function MB.VolumeText()
    local v = MB.Sound.Level()
    return v and ("Volume %d%%"):format(floor(v * 100 + 0.5)) or "Volume"
end
function MB.OnVolume(steps)
    local v = MB.Sound.Nudge(steps)
    if not v then return end
    MB.SetVolumeKnob(v)
    flash(MB.Opt("duck", true) and MB.VolumeText() or "Needs /mb sound duck on")
end
function MB.OnMemory(n, save)
    if save then saveSlot(n) else loadSlot(n) end
end

keyCapture:SetScript("OnKeyDown", function(self, key)
    if InCombatLockdown() then return end -- (the console closes for combat; belt and braces)
    if key == "PRINTSCREEN" then
        self:SetPropagateKeyboardInput(true)   -- the one key let through: screenshots
        return
    end
    self:SetPropagateKeyboardInput(false)      -- everything else stays here
    if key == "ESCAPE" then
        if picking then closePicker() elseif running then pause() else MB.Hide() end
        return
    end
    if isToggleKey(key) then
        if picking then closePicker() end
        MB.Hide()
        return
    end
    if picking then
        if keymap[key] then pickerButton(keymap[key]) end
        return
    end
    local slot = STATE_KEYS[key]
    if slot then
        if IsShiftKeyDown and IsShiftKeyDown() then saveSlot(slot) else loadSlot(slot) end
        return
    end
    local button = keymap[key]
    if not button then return end
    if button == "volup" or button == "voldown" then
        MB.OnVolume(button == "volup" and 1 or -1)
        return
    end
    if not running then
        if button == "start" then switchOn()         -- Start wakes it; it is not passed to the game
        elseif button == "select" then openPicker() end
        return
    end
    setHeld(button, true, "key:" .. key)
    MB.SetPressed(shown(button), true)
    keysDown[key] = button
    if keyIsDown and keyTrusted[key] == nil then
        local ok, down = pcall(keyIsDown, key)
        keyTrusted[key] = (ok and down == true) or false
    end
end)

keyCapture:SetScript("OnKeyUp", function(_, key)
    local button = keysDown[key] or keymap[key]         -- (the button it pressed, even if the keys were changed since)
    keysDown[key] = nil
    if not button or not running then return end
    if setHeld(button, false, "key:" .. key) then MB.SetPressed(shown(button), false) end
end)

-- ---------------------------------------------------------- main loop ---
keyCapture:SetScript("OnUpdate", function(_, elapsed)
    if not machine or not running then return end
    if elapsed > 0.25 then elapsed = 0.25 end
    checkKeys()
    if sys.kind == "native" then                 -- no emulation: the cartridge's own code runs once a frame
        local t0 = clock()
        if not pcall(machine.tick, elapsed) then crashed("the cartridge's tick failed") end
        local ran = clock() - t0
        if ran > watch.longest then watch.longest = ran end
        return
    end

    local rewinding = held.rewind and sys.rewind and not linkBusy()
    MB.Sound.SetRewinding(rewinding and true or false)
    if rewinding then
        -- step back through the snapshots, newest first
        rewindAcc = rewindAcc + elapsed
        if rewindAcc >= 0.066 then
            rewindAcc = 0
            local n = #history
            if n > 0 then
                local st = history[n]
                if n > 1 then history[n] = nil end
                lastSnap = history[#history]
                if pcall(machine.loadState, st) then
                    pcall(machine.runFrame, true)
                    present()
                end
            end
            MB.SetStatus(("Rewinding - %d s left"):format(floor(#history / 5)))
        end
        owed = 0
        return
    end

    local ff = held.ff or MB.Opt("ffLock", false)
    MB.Sound.fast = ff and true or false
    local speed = ff and MB.Opt("ffSpeed", 4) or 1
    local budget = ff and sys.budgetFF or sys.budget
    local FPS = sys.fps
    owed = owed + elapsed * FPS * speed
    if owed > sys.mostOwed * speed then owed = sys.mostOwed * speed end -- too slow to keep up: run slower, don't pile up
    -- linked, and waiting for the other player's game to answer: the game is held still, so that
    -- its own short patience for that answer does not run out (see GBA/Cable.lua)
    local hold = (MB.Link and MB.Link.Waiting and MB.Link.Waiting()) and true or false
    -- (a trade where you stand is being set up: the game is saved, a little each tick, and held still: GBA/Trade3.lua)
    local trade = MB.Trade3
    if trade and trade.Holding() then
        hold = true
        local tok, terr = pcall(trade.Tick, machine)
        if not tok then Print("The trade could not be set up: " .. tostring(terr)) pcall(trade.Fail) end
    end
    if hold then owed = 0 end
    if hold ~= waiting then
        waiting = hold
        refreshStatus()
    end
    local t0 = clock()
    local drew = false
    while owed >= 1 do
        owed = owed - 1
        -- only the last frame of a batch is drawn; the others just advance the game
        local last = (owed < 1) or (clock() - t0 + (blindSeen and costBlind or frameCost) > budget)
        sinceDrawn = sinceDrawn + 1
        local render = last and sinceDrawn >= pictureEvery
        local t1 = clock()
        if not step(render) then return end
        local cost = clock() - t1
        frameCost = frameCost * 0.9 + cost * 0.1
        statFrames = statFrames + 1
        if render then
            costDrawn = costDrawn * 0.95 + cost * 0.05
            drew = machine.changed ~= false      -- (false when the picture is the same as the last one shown)
            sinceDrawn = 0
            break
        end
        costBlind, blindSeen = costBlind * 0.95 + cost * 0.05, true
        if last then break end
    end
    MB.Sound.Poll()
    if not drew and MB.Ghosts then                -- (a friend's ghost walks on a still picture)
        local gok, busy = pcall(MB.Ghosts.Moving)
        if not gok then MB.Ghosts.Fail(busy) elseif busy then drew = true end
    end
    if drew then
        local t1 = clock()
        present()
        costPaint = costPaint * 0.95 + (clock() - t1) * 0.05
        secShown = secShown + 1
    end
    do  -- how long this turn ran: under 10, 20, 30, 40, 60, 80, 100, 150, 250 ms, or over
        local ran = clock() - t0
        local b = (ran < 10 and 1) or (ran < 20 and 2) or (ran < 30 and 3) or (ran < 40 and 4) or (ran < 60 and 5) or (ran < 80 and 6) or (ran < 100 and 7) or (ran < 150 and 8) or (ran < 250 and 9) or 10
        watch.turns[b] = watch.turns[b] + 1
        if ran > watch.longest then watch.longest = ran end
        if ran > watch.sinceWarning then watch.sinceWarning = ran end
        if ran > turnMaxSec then turnMaxSec = ran end
    end

    statTime = statTime + elapsed
    if statTime >= 1 then
        local pct = floor(statFrames / statTime / FPS * 100 + 0.5)
        if sys.second then
            sys.second(machine, storeKey or saveKey, { speed = statFrames / statTime / FPS * 100, pictures = secShown / statTime, every = pictureEvery,
                                           game = costDrawn, blind = costBlind, paint = costPaint }, flash)
        end
        if prof then
            local gc = collectgarbage("count")
            prof.samples[#prof.samples + 1] = {
                speed = statFrames / statTime / FPS * 100, pictures = secShown / statTime, every = pictureEvery,
                emulate = costBlind, draw = math.max(0, costDrawn - costBlind), paint = costPaint,
                dots = secShown > 0 and dotsSet / secShown or 0, garbageKB = gcPrev and math.max(0, gc - gcPrev) or 0,
                wowFps = GetFramerate and GetFramerate() or 0, turnMax = turnMaxSec, ff = ff and true or false,
            }
            gcPrev = gc
            if GetTime() >= prof.untilT then MB.ProfileFinish() end
        end
        dotsSet, turnMaxSec = 0, 0
        statFrames, statTime, secShown = 0, 0, 0
        -- say nothing while all is well; speak up when fast-forwarding or struggling
        if ff then speedText = (" - %d%% speed"):format(pct)
        elseif pct < 92 and not waiting then speedText = (" - %d%% speed"):format(pct)
        else speedText = "" end
        if note and GetTime() >= noteUntil then note = nil end
        refreshStatus()
        -- how many pictures can this computer afford just now?
        local want = MB.Opt(sys.pictureOpt, 0)
        if want >= 1 and want <= sys.pictureMax then pictureEvery = want
        elseif not ff then
            local full = costDrawn + costPaint
            local blind = blindSeen and costBlind or costDrawn * 0.5
            local pick = sys.pictureMax
            for k = 1, sys.pictureMax do
                -- stepping back up to more pictures needs clear room, so it does not flicker between two rates
                local room = (k < pictureEvery) and sys.pictureMs * 0.8 or sys.pictureMs
                if (full + (k - 1) * blind) / k <= room then pick = k break end
            end
            pictureEvery = pick
        end
    end
end)

-- a self-check: how many dots on the screen differ from the game's latest picture? (0 right after a picture is shown)
function MB.ScreenCheck()
    if not (machine and grid and machine.fb) then return 0 end
    local fb, n, shown = machine.fb, 0, grid.shown
    for i = 1, sys.W * sys.H do if shown[i] ~= fb[i] then n = n + 1 end end
    return n
end

-- what each dot of the screen shows now (for tests: the game's picture with anything drawn over it)
function MB.ShownDots() return grid and grid.shown end

-- /mb profile: what a played stretch of a game cost, second by second, kept in the settings (MekkaBoyDB.profiles, the
-- last 12) so it can be read after logging out. emulate = a frame run without a picture, draw = what drawing the
-- picture adds, paint = putting the changed dots on WoW's screen (dots = how many changed per picture).
local function profileSummary(p)
    local keys = { "speed", "pictures", "emulate", "draw", "paint", "dots", "garbageKB", "wowFps", "turnMax" }
    local out = {}
    for _, k in ipairs(keys) do
        local v = {}
        for _, smp in ipairs(p.samples) do if not smp.ff then v[#v + 1] = smp[k] end end
        table.sort(v)
        if #v > 0 then
            local sum = 0 for _, x in ipairs(v) do sum = sum + x end
            out[k] = { avg = sum / #v, median = v[math.floor((#v + 1) / 2)], worst = (k == "speed" or k == "wowFps") and v[1] or v[#v] }
        end
    end
    return out
end
function MB.ProfileFinish()
    local p = prof
    if not p then return end
    prof = nil
    p.summary = profileSummary(p)
    p.seconds = #p.samples
    local db = MB.DB()
    db.profiles = db.profiles or {}
    table.insert(db.profiles, p)
    while #db.profiles > 12 do table.remove(db.profiles, 1) end
    local s = p.summary
    if not s.speed then Print("Profile \"" .. p.label .. "\": no time recorded while the game was running.") return end
    Print(("Profile \"%s\" (%s, %d s): speed %d%% (worst %d%%), %.0f pictures a second, WoW %d fps (worst %d)."):format(p.label, p.game or "?",
        p.seconds, s.speed.avg + 0.5, s.speed.worst + 0.5, s.pictures.avg, s.wowFps.avg + 0.5, s.wowFps.worst + 0.5))
    Print(("  per frame: emulate %.1f ms, draw %.1f ms; per picture: paint %.1f ms for %d changed dots; garbage %d KB a second; longest turn %d ms.")
        :format(s.emulate.avg, s.draw.avg, s.paint.avg, s.dots.avg + 0.5, s.garbageKB.avg + 0.5, s.turnMax.worst + 0.5))
    Print("  Kept with your settings: it reaches us when you log out or /reload.")
end
MB.AddCommand("profile", "profile [seconds] [label] | profile stop - measure where the game's time goes while you play (for speed work)", function(rest)
    rest = rest or ""
    if rest == "stop" then
        if prof then MB.ProfileFinish() else Print("No profile is running.") end
        return
    end
    if not (machine and sys and sys.kind ~= "native") then Print("Put a Game Boy or Advance game in and switch it on first.") return end
    local secs, label = rest:match("^(%d+)%s*(.*)$")
    secs = tonumber(secs) or 30
    if secs < 5 then secs = 5 elseif secs > 300 then secs = 300 end
    label = (label and label ~= "" and label) or (rest:match("^%D.*") ) or gameName()
    prof = { label = label, game = saveKey, name = gameName(), system = sys.kind, version = MB.VERSION, at = date and date("%Y-%m-%d %H:%M") or "?",
             scale = MB.Opt("scale", 0), pictureOpt = MB.Opt(sys.pictureOpt, 0), untilT = GetTime() + secs, samples = {} }
    gcPrev = collectgarbage("count")
    Print(("Profiling %s for %d s. Play as you normally would (walking around a town is a good test); /mb profile stop ends it early."):format(label, secs))
end)

-- for the speed test and for anyone curious: what a frame is costing right now
function MB.Perf()
    return { game = costDrawn, blind = costBlind, paint = costPaint, every = pictureEvery, running = running and machine ~= nil }
end

MB.window:HookScript("OnShow", function()
    MB.SetVolumeKnob(MB.Sound.Level())
    if not playing() then
        MB.SetScreenMessage(idleMessage())
        refreshStatus()
    end
end)
MB.window:HookScript("OnHide", function()
    picking = nil
    if playing() then pause() end
    MB.Sound.Stop()
    if machine and sys.away then sys.away(machine, storeKey or saveKey) end
    -- closing the window is leaving, not pausing: Together friends stop drawing me at once (they draw me again when I play on)
    if MB.Ghosts and MB.Ghosts.SayBye then pcall(MB.Ghosts.SayBye) end
end)

-- The client warns of addon scripts that run long ("Script from ... has exceeded its execution time limit"). Its
-- warnings are heard here, and its own list of them is read at logout, so that the settings file shows whether
-- MekkaBoy was ever named and how long its turns had been running. Nothing is done about them here.
local function clientList()
    -- the client's own list of errors and warnings, as far as it names this addon (its window keeps it in plain tables)
    local f = ScriptErrorsFrame
    if type(f) ~= "table" or type(f.order) ~= "table" then return nil end
    local out = {}
    local messages, count, times = f.messages, f.count, f.times
    for i = 1, #f.order do
        local said = type(messages) == "table" and messages[i] or f.order[i]
        if type(said) == "string" and said:find("MekkaBoy", 1, true) and #out < 12 then
            out[#out + 1] = { said = said:sub(1, 300), count = type(count) == "table" and tonumber(count[i]) or nil,
                              time = type(times) == "table" and times[i] ~= nil and tostring(times[i]) or nil }
        end
    end
    return out
end
local warned = CreateFrame("Frame")
watch.listening = pcall(warned.RegisterEvent, warned, "LUA_WARNING") and true or false
warned:SetScript("OnEvent", function(_, _, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))):sub(1, 300) end
    local said = table.concat(parts, " | ")
    if not said:find("MekkaBoy", 1, true) then return end
    watch.warned = watch.warned + 1
    if #watch.warnings < 10 then
        watch.warnings[#watch.warnings + 1] = { at = date and date("%Y-%m-%d %H:%M:%S") or "?", said = said, game = saveKey,
                                                 longestTurnSinceLast = watch.sinceWarning, playing = running and true or false }
    end
    watch.sinceWarning = 0
end)
function MB.ClientNotes()
    local ok, list = pcall(clientList)
    return { at = date and date("%Y-%m-%d %H:%M:%S") or "?", version = MB.VERSION, turnsMs = watch.turns, longestTurnMs = watch.longest,
             keysLetGo = watch.letGo, keysLetGoElsewhere = watch.elsewhere, canAskKeys = keyIsDown ~= nil,
             listening = watch.listening, warned = watch.warned, warnings = watch.warnings, clientList = ok and list or nil,
             sound = MB.Sound and MB.Sound.Notes and select(2, pcall(MB.Sound.Notes)) or nil }
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function()
    MB.SaveGame()
    MB.DB().client = MB.ClientNotes()
end)

-- ------------------------------------------------------------ commands ---
local function onOff(name, rest, default)
    local db = MB.DB()
    if rest == "on" then db.opt[name] = true
    elseif rest == "off" then db.opt[name] = false
    else db.opt[name] = not MB.Opt(name, default) end
    return db.opt[name]
end

MB.AddCommand("save", "save [1-4] - save to a memory valve (Shift+F1 to Shift+F4)", function(rest)
    local n = tonumber(rest) or 1
    if n < 1 or n > SLOTS or n % 1 ~= 0 then Print("Valves are numbered 1 to " .. SLOTS .. ".") return end
    saveSlot(n)
    Print(note or "")
end)

MB.AddCommand("load", "load [1-4] - load from a memory valve (F1 to F4)", function(rest)
    local n = tonumber(rest) or 1
    if n < 1 or n > SLOTS or n % 1 ~= 0 then Print("Valves are numbered 1 to " .. SLOTS .. ".") return end
    loadSlot(n)
    Print(note or "")
end)

MB.AddCommand("states", "states - list what the memory valves hold", function()
    saveKey = saveKey or inserted()
    if not saveKey then Print("No cartridge.") return end
    local st = gameStates(slotSys())
    Print("Memory valves for " .. saveKey .. ":")
    for n = 1, SLOTS do print(("  %d: %s"):format(n, st[n] and ((st[n].when ~= "" and st[n].when) or "saved") or "empty")) end
    print("  resume point: " .. (st.resume and "saved" or "none"))
end)

MB.AddCommand("carts", "carts - list your cartridges", function()
    local list = MB.Carts.List()
    if #list == 0 then
        Print("No cartridges yet. /mb setup adds a game you own.")
        return
    end
    local now = inserted()
    Print(#list .. " cartridge(s). /mb cart <number> puts one in:")
    for i, c in ipairs(list) do
        local tried = ""
        if c.system == "gba" and MB.Tested then
            -- (a cartridge says which game it is in its label; one made by an older gba2lua.py does not, unless it is in memory)
            local key = c.code or (MB.Carts.Peek and MB.Tested.KeyOf(MB.Carts.Peek(c.id)))
            if key then tried = "  - " .. MB.Tested.Short(key) end
        end
        print(("  %d: %s%s%s%s%s"):format(i, c.name, c.system == "gba" and "  [Advance]" or c.system == "native" and "  [native]" or "", tried, c.id == now and "  (in the slot)" or "",
            c.old and "  - made for an older game client, see /mb oldcarts" or ""))
    end
end)

MB.AddCommand("cart", "cart <number or name> - put a cartridge in (the game in the slot is saved first)", function(rest)
    local list = MB.Carts.List()
    local want = tonumber(rest) and list[tonumber(rest)]
    if not want and rest ~= "" then
        for _, c in ipairs(list) do
            if c.name:lower():find(rest:lower(), 1, true) or c.id:lower() == rest:lower() then want = c break end
        end
    end
    if not want then
        Print("No cartridge matches that. /mb carts lists them.")
    elseif InCombatLockdown() then
        Print("Not in combat.")
    else
        if not MB.window:IsShown() then MB.Show(false) end
        insert(want.id)
        if running then Print(want.name .. " is in the slot.") end
    end
end)

MB.AddCommand("reset", "reset - restart the game from power-on (battery save is kept)", function()
    if gameBusy() then Print("Not in the middle of a round - finish the hand first.") return end
    if machine then
        sys.keep(machine, storeKey or saveKey, true)
        pause()
        machine = nil
        MB.Sound.Stop()
    end
    broken = false
    if start(true) then
        pcall(machine.runFrame, true)
        present()
        MB.SetScreenMessage(gameName() .. " restarted\nClick the screen to play")
        flash("Restarted")
    end
end)

MB.AddCommand("resume", "resume on|off - pick up exactly where you left off after logging out", function(rest)
    Print("Resume where you left off is " .. (onOff("resume", rest, true) and "on." or "off."))
end)

-- /mb color <name> picks the console's colorway (UI/Body.lua); /mb color lcd|raw is the Game Boy Color screen.
-- /mb colour still works for anyone who learned it before 0.20.1, unlisted.
local function colorCommand(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local word = rest:lower()
    if word ~= "lcd" and word ~= "raw" then
        if MB.ColorwayCommand then MB.ColorwayCommand(rest) end
        if rest == "" then Print("Game Boy Color screen: " .. (MB.Opt("color", "lcd") == "lcd" and "lcd" or "raw") .. " (/mb color lcd|raw).") end
        return
    end
    MB.DB().opt.color = word
    redrawAll()
    Print("Game Boy Color screen colors: " .. (word == "lcd" and "like the real screen (lcd)." or "plain (raw)."))
end
MB.AddCommand("color", "color <name> - the console's color: Gunmetal, Midnight, Arcane, Verdant, Ivory, Rose Gold (color lcd|raw: the Game Boy Color screen)", colorCommand)
MB.AddCommand("colour", "", colorCommand)

MB.AddCommand("palette", "palette <name>|auto - colors for an original Game Boy game: " .. table.concat(PALETTE_ORDER, ", "), function(rest)
    rest = rest:lower()
    local db = MB.DB()
    local game = saveKey or inserted()
    if slotSys() ~= GBSYS then Print("Palettes are for original Game Boy games.") return end
    if rest == "auto" and game then
        if db.opt.palettes then db.opt.palettes[game] = nil end
        applyPalette()
        Print("Palette for this game: chosen by the console.")
        return
    end
    if not PALETTES[rest] then Print("Palettes: " .. table.concat(PALETTE_ORDER, ", ") .. ", or auto.") return end
    if game then                     -- remembered per game
        db.opt.palettes = db.opt.palettes or {}
        db.opt.palettes[game] = rest
    else
        db.opt.palette = rest
    end
    applyPalette()
    Print("Palette for " .. (game and "this game" or "original Game Boy games") .. ": " .. rest .. ".")
end)

MB.AddCommand("scale", "scale <1-6|auto> - size of the console, in screen pixels per game pixel", function(rest)
    local n = tonumber(rest)
    if rest == "auto" then MB.DB().opt.scale = nil
    elseif n and n >= 1 and n <= 6 and n % 1 == 0 then MB.DB().opt.scale = n
    else Print("Scale is a whole number from 1 to 6, or auto.") return end
    Print("Console scale: " .. MB.ApplyScale() .. (MB.Opt("scale", nil) and "." or " (auto)."))
end)

MB.AddCommand("ff", "ff [2-8|lock] - fast-forward speed, or lock it on/off", function(rest)
    local n = tonumber(rest)
    if rest == "lock" then
        Print("Fast-forward is " .. (onOff("ffLock", "", false) and "locked on." or "back to hold-to-use."))
    elseif n and n >= 2 and n <= 8 then
        MB.DB().opt.ffSpeed = n
        Print(("Fast-forward speed: up to %dx (as fast as your machine allows)."):format(n))
    else
        Print(("Fast-forward: hold %s. Speed up to %dx. /mb ff 2-8 changes it; /mb ff lock toggles it on."):format(MB.KeyLabel("ff"), MB.Opt("ffSpeed", 4)))
    end
end)

MB.AddCommand("rewind", "rewind on|off|<seconds> - how much the rewind key can undo (default 40 seconds)", function(rest)
    local n = tonumber(rest)
    if n and n >= 5 and n <= 300 then
        MB.DB().opt.rewindSeconds = floor(n)
        Print(("Rewind keeps the last %d seconds."):format(floor(n)))
    else
        local on = onOff("rewind", rest, true)
        if not on then history, lastSnap = {}, nil end
        Print("Rewind is " .. (on and "on." or "off."))
    end
end)

MB.AddCommand("cheat", "cheat add <code> | list | del <n> | on <n> | off <n> | clear - GameShark and Game Genie codes", function(rest)
    saveKey = saveKey or inserted()
    if not saveKey then Print("No cartridge.") return end
    if slotSys() ~= GBSYS then Print("Cheat codes work with Game Boy and Game Boy Color games only.") return end
    local db = MB.DB()
    db.cheats[saveKey] = db.cheats[saveKey] or {}
    local list = db.cheats[saveKey]
    local verb, arg = rest:match("^(%S*)%s*(.-)$")
    verb = verb:lower()
    if verb == "add" then
        local c, why = MB.Cheats.parse(arg)
        if not c then Print("Not a code I can use: " .. why .. ".") return end
        list[#list + 1] = { code = c.code, on = true }
        Print(("Added %s code %s."):format(c.kind == "gs" and "GameShark" or "Game Genie", c.code))
    elseif verb == "del" or verb == "on" or verb == "off" then
        local n = tonumber(arg)
        if not n or not list[n] then Print("No cheat with that number. /mb cheat list shows them.") return end
        if verb == "del" then
            Print("Removed " .. table.remove(list, n).code .. ".")
        else
            list[n].on = (verb == "on")
            Print(list[n].code .. " is " .. verb .. ".")
        end
    elseif verb == "clear" then
        db.cheats[saveKey] = {}
        Print("All cheats for " .. saveKey .. " removed.")
    else
        if #list == 0 then Print("No cheats for " .. saveKey .. ". /mb cheat add <code> adds one.") end
        for i, c in ipairs(list) do print(("  %d. %s  %s"):format(i, c.code, c.on ~= false and "on" or "off")) end
    end
    applyCheats()
end)

MB.AddCommand("keys", "keys - show the controls", function()
    Print("Controls (change one with /mb bind <button> <key>):")
    for _, button in ipairs(BUTTON_ORDER) do
        print(("  %-22s %s"):format(BUTTON_NAMES[button], MB.KeyLabel(button)))
    end
    print("  Load state 1-4         F1, F2, F3, F4")
    print("  Save state 1-4         Shift + F1, F2, F3, F4")
    print("  Pause, then close      ESCAPE")
    print("  While the console is open it keeps every key (except Print Screen). The ? button on it shows them too.")
    if MB.window:IsShown() and MB.SetKeyDrawer then MB.SetKeyDrawer(true) end
end)

MB.AddCommand("bind", "bind <button> <key> | bind reset - change a control, e.g. /mb bind a K", function(rest)
    local db = MB.DB()
    if rest:lower() == "reset" then
        db.opt.keys = nil
        rebuildKeymap()
    if MB.KeyDrawerOpen and MB.KeyDrawerOpen() then MB.RefreshKeyDrawer() end
        Print("Controls back to defaults.")
        return
    end
    local button, key = rest:match("^(%S+)%s+(%S+)$")
    button = button and button:lower()
    if not button or not DEFAULT_KEYS[button] then
        Print("Buttons: " .. table.concat(BUTTON_ORDER, ", ") .. ".")
        return
    end
    key = key:upper()
    if key == "ESCAPE" then Print("ESC always pauses and can't be rebound.") return end
    db.opt.keys = db.opt.keys or {}
    for _, keys in pairs(db.opt.keys) do -- a key does one thing
        for i = #keys, 1, -1 do if keys[i] == key then table.remove(keys, i) end end
    end
    db.opt.keys[button] = { key }
    rebuildKeymap()
    if MB.KeyDrawerOpen and MB.KeyDrawerOpen() then MB.RefreshKeyDrawer() end
    Print(("%s is now on %s."):format(BUTTON_NAMES[button], key))
end)

MB.AddCommand("picture", "picture auto|1|2|3 - show every picture, every 2nd or every 3rd (auto picks for your computer)", function(rest)
    local n = tonumber(rest)
    if rest == "auto" then MB.DB().opt.picture = 0
    elseif n and n >= 1 and n <= 3 then MB.DB().opt.picture = floor(n) pictureEvery = floor(n)
    elseif rest ~= "" then Print("Use /mb picture auto, 1, 2 or 3.") return end
    local want = MB.Opt("picture", 0)
    if want >= 1 then Print(("Showing every %s picture. /mb picture auto lets MekkaBoy choose."):format(want == 1 and "" or want == 2 and "2nd" or "3rd"):gsub("  ", " "))
    else Print(("Picture rate is automatic: every %s just now (game %.1f ms + picture %.1f ms a frame)."):format(
        pictureEvery == 1 and "frame" or pictureEvery == 2 and "2nd frame" or "3rd frame", costDrawn, costPaint)) end
end)
-- (/mb plain and /mb fast are gone: plain drawing can blank the client's interface and freeze it. A setting saved by
-- an earlier version is forgotten.)
MB.onLogin[#MB.onLogin + 1] = function() MB.DB().opt.plain = nil end

MB.SetScreenMessage(idleMessage())
refreshStatus()
