-- MekkaBoy sound. An addon cannot make sound, only play sound files, so the
-- sound comes from a "soundtrack pack": every song, sound effect and cry of a
-- game, recorded ahead of time from the game itself by Tools/soundpack.py.
-- This file watches the running game's own music program and plays the
-- matching recording the moment the game starts a song or a sound.
--
-- Two ways of playing, chosen with /mb sound duck on|off:
--   duck on  - like the console: a cry or fanfare silences the song while it
--              plays. For that the addon borrows the game client's Music
--              channel while the console runs: Music is switched on and its
--              volume follows the Sound Effects slider (so songs and effects
--              keep their Game Boy balance), and is turned to nothing for the
--              length of a cry. Both settings are put back afterwards.
--   duck off - the client's volume settings are not touched. Songs and effects
--              all play as sound effects; a song keeps playing under cries.
-- Either way the world's own music is hushed while the console runs.
--
-- The console's own volume (the wheel on the body, /mb volume). The client
-- has no volume for a single sound, only for its five channels, so a volume
-- of our own means having a channel to ourselves. Songs already have one
-- (Music, above). Once the wheel has been turned, effects and cries move
-- from Sound Effects to the Ambience channel, which is borrowed the same way:
-- switched on, set to the wheel's level, and put back afterwards. The cost:
-- the world's own background noises (wind, birdsong) follow the wheel too
-- while the console runs. Until the wheel is touched, and after
-- /mb volume auto, everything is as before: the volume follows the Sound
-- Effects slider and Ambience is left alone. Needs duck on.
local _, MB = ...

local S = {}
MB.Sound = S
MB.SoundPacks = MB.SoundPacks or {}

local floor, max = math.floor, math.max
local SILENCE = "Interface\\AddOns\\MekkaBoy\\Sound\\silence.ogg"

local machine, pack, hooks      -- the running game and its pack, if it has one
local driver = nil              -- how to listen to this game's kind of music program
local session = false           -- are we holding the Music channel?
local live = false              -- is the game advancing at normal speed, forwards?
local paused = false
local music = nil               -- { id, handle, ends, once }
local effects = {}              -- sounds in flight: { handle, mask, ends }
local danger = nil              -- the low-health alarm: { handle, ends }
local duckUntil = 0             -- songs are silent until then (a cry or fanfare is playing)
local softUntil = 0             -- songs are turned down, not off, until then (Game Boy Advance cries)
local hushed = false            -- the game has stopped its song but may yet carry on with it
local volume = nil              -- what we last set the Music volume to
local fxChannel = "SFX"         -- where effects and cries play: "SFX", or "Ambience" with a volume of our own
local fxVolume = nil            -- what we last set the Ambience volume to
local fxRefused = false         -- this client would not play on Ambience: effects stay on Sound Effects
local silenced = false          -- the volume has been all the way down: the song must be started afresh when it comes back

-- A song the game client has let go of does not come back by itself. It lets go of one when the game's window
-- goes to the background (with "Sound in Background" off) and when the Music volume stands at nothing. Newer
-- clients can say whether a sound is still sounding; where this one can, a song found gone is started again.
local askOK = true              -- false once the client's answers have proved no use
local everHeard = false         -- has the client ever answered "yes, still sounding"?
local misses, lookAt, lookWait, quietAt = 0, 0, 1, 0
local note = { back = 0, afterQuiet = 0, failedStarts = 0 }
-- "Silent" for a song that is to carry on afterwards (under a cry, during a pause). At no volume at all the
-- client lets go of the song, so where it can be asked afterwards whether the song survived, the volume is only
-- brought down to something nobody can hear (about a five-thousandth); if it did not survive it is started again.
local HUSH = 0.0002
local function canAsk() return askOK and C_Sound and C_Sound.IsPlaying and true or false end
local function quietLevel() return canAsk() and HUSH or 0 end
local function sounding(handle)
    local ask = askOK and C_Sound and C_Sound.IsPlaying
    if not ask then return nil end
    local ok, yes = pcall(ask, handle)
    if not ok then askOK = false note.gaveUp = "error" return nil end
    if yes then everHeard = true return true end
    return false
end

local function enabled() return MB.Opt("sound", true) end
local ducking = true            -- this session's way of playing (see above)

local GetCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCVar = (C_CVar and C_CVar.SetCVar) or SetCVar

local function overlap(a, b)
    if bit and bit.band then return bit.band(a, b) ~= 0 end
    for i = 0, 8 do
        if floor(a / 2 ^ i) % 2 == 1 and floor(b / 2 ^ i) % 2 == 1 then return true end
    end
    return false
end

local function bits(mask)
    local n = 0
    for i = 0, 3 do n = n + floor(mask / 2 ^ i) % 2 end
    return n
end

-- ------------------------------------------------- borrowed settings ---
-- While the console runs, the client's "Sound in Background" setting is switched on, so that the song is not
-- dropped when another window is in front (all of WoW's sound then carries on there, as that setting does).
-- Put back with the rest. /mb sound background off leaves the setting alone.
local BG = "Sound_EnableSoundWhenGameIsInBG"
local function borrowBackground()
    local db = MB.DB()
    if db.soundRestoreBG or not MB.Opt("soundBackground", true) then return end
    local ok, was = pcall(GetCVar, BG)
    if not ok or was == nil then return end         -- (a client without the setting)
    db.soundRestoreBG = tostring(was)
    if tostring(was) ~= "1" then pcall(SetCVar, BG, "1") end
end
local function restoreSettings()
    local db = MB.DB()
    if db.soundRestoreBG then
        pcall(SetCVar, BG, db.soundRestoreBG)
        db.soundRestoreBG = nil
    end
    local keep = db.soundRestore
    if not keep then return end
    db.soundRestore = nil
    if keep.volume then SetCVar("Sound_MusicVolume", keep.volume) end
    if keep.enable then SetCVar("Sound_EnableMusic", keep.enable) end
    if keep.fxVolume then SetCVar("Sound_AmbienceVolume", keep.fxVolume) end
    if keep.fxEnable then SetCVar("Sound_EnableAmbience", keep.fxEnable) end
end

-- the wheel's level, 0..1, or nil while it has never been turned
local function own()
    local v = MB.Opt("volume", nil)
    if type(v) ~= "number" then return nil end
    return (v < 0 and 0) or (v > 1 and 1) or v
end
-- how loud the console is: the wheel's level, or else the Sound Effects slider
local function level() return own() or tonumber(GetCVar("Sound_SFXVolume")) or 1 end

-- (while the console runs) give effects and cries a channel whose volume is ours to set
local function tuneEffects()
    local v = ducking and not fxRefused and own()
    local keep = MB.DB().soundRestore
    if not (v and keep) then
        fxChannel = "SFX"
        return
    end
    if not keep.fxVolume then
        keep.fxVolume, keep.fxEnable = GetCVar("Sound_AmbienceVolume"), GetCVar("Sound_EnableAmbience")
        SetCVar("Sound_EnableAmbience", "1")
        fxVolume = nil
    end
    fxChannel = "Ambience"
    if fxVolume ~= v then
        fxVolume = v
        SetCVar("Sound_AmbienceVolume", v)
    end
end

-- play an effect or a cry. Returns willPlay, handle.
local function playFx(path)
    if fxChannel == "SFX" then return PlaySoundFile(path, "SFX") end
    local ok, willPlay, handle = pcall(PlaySoundFile, path, fxChannel)
    if ok and willPlay then return willPlay, handle end
    -- it would not play there. If it will as a plain sound effect, this client has no such channel
    -- for addons: go back to the Sound Effects slider for effects, for good.
    willPlay, handle = PlaySoundFile(path, "SFX")
    if willPlay then
        fxRefused, fxChannel = true, "SFX"
        local keep = MB.DB().soundRestore
        if keep and keep.fxVolume then
            SetCVar("Sound_AmbienceVolume", keep.fxVolume)
            SetCVar("Sound_EnableAmbience", keep.fxEnable)
            keep.fxVolume, keep.fxEnable = nil, nil
        end
    end
    return willPlay, handle
end

local function setVolume(v)
    if ducking and volume ~= v then
        volume = v
        SetCVar("Sound_MusicVolume", v)
    end
end

local function stopHandle(handle, fadeMs)
    if handle then pcall(StopSound, handle, fadeMs or 0) end
end

-- --------------------------------------------------------------- music ---
local function stopMusic(fadeMs)
    if music then
        stopHandle(music.handle, fadeMs)
        music = nil
    end
end

-- Songs, effects and cries are listed in the pack under the name of their
-- file: song "012" is m012.ogg, effect "08_a0" is s08_a0.ogg, and so on.
local function startMusic(key)
    stopMusic()
    local e = pack.music[key]
    if not e then return end
    local willPlay, handle = PlaySoundFile(pack.dir .. "m" .. key .. ".ogg", ducking and "Music" or "SFX")
    music = { id = key, handle = willPlay and handle or nil, began = GetTime(), ends = GetTime() + e.len, once = e.once }
end

-- --------------------------------------------------------- effects ---
local function stopEffects()
    for i = #effects, 1, -1 do
        stopHandle(effects[i].handle)
        effects[i] = nil
    end
    if danger then
        stopHandle(danger.handle)
        danger = nil
    end
    duckUntil, softUntil = 0, 0
end

local function stopEffectsOn(mask)
    for i = #effects, 1, -1 do
        if overlap(effects[i].mask, mask) then
            stopHandle(effects[i].handle)
            table.remove(effects, i)
        end
    end
end

local function playEffect(file, e, duck)
    local now = GetTime()
    for i = #effects, 1, -1 do
        local x = effects[i]
        if x.ends <= now then
            table.remove(effects, i)
        elseif overlap(x.mask, e.mask) then   -- a new sound takes over the channels it needs
            stopHandle(x.handle)
            table.remove(effects, i)
        end
    end
    local willPlay, handle = playFx(pack.dir .. file)
    if willPlay then
        effects[#effects + 1] = { handle = handle, mask = e.mask, ends = now + e.len }
    end
    -- On the console, a cry or a fanfare silences the song while it plays.
    if duck and ducking then
        duckUntil = max(duckUntil, now + e.busy)
        setVolume(quietLevel())
    end
end

-- ------------------------------------------- what the game is doing ---
local function word(addr) return machine.peek(addr) + machine.peek(addr + 1) * 256 end

local function listening() return session and live and not paused end

-- a slip in here must never jam the game itself
local function safe(fn)
    return function(...) pcall(fn, ...) end
end

-- On the console a sound that takes most of the voices silences the song.
local function loud(x) return bits(x.mask) >= 3 and x.busy >= 0.5 end

local function playSong(key)
    if pack.music[key] then startMusic(key) else stopMusic() end
end

-- One driver per family of music program. A driver gives:
--   breakpoints   places in the game to watch, and what to do there
--   currentSong() the song the game is in the middle of, from its memory
--   fading()      nil, or how many milliseconds the game is fading the song out over
--   alarm()       is the low-health alarm sounding?
local drivers = {}

-- Pokemon Gold, Silver and Crystal
function drivers.pokecrystal()
    local h = hooks
    local bank = h.audioBank
    local function effect(d, e)
        local key = ("%03d"):format(d * 256 + e)
        local x = pack.sfx[key]
        if x then playEffect("s" .. key .. ".ogg", x, loud(x)) end
    end
    return {
        breakpoints = {
            { bank = bank, addr = h.playMusic, fn = safe(function(_, _, _, d, e)
                if listening() then playSong(("%03d"):format(d * 256 + e)) end
            end) },
            { bank = bank, addr = h.initSound, fn = safe(function()
                if not listening() then return end
                stopMusic()
                stopEffects()
            end) },
            { bank = bank, addr = h.playSFX, fn = safe(function(_, _, _, d, e)
                if listening() and not S.fast then effect(d, e) end
            end) },
            { bank = bank, addr = h.playStereoSFX, fn = safe(function(_, _, _, d, e)
                -- with the game's sound set to mono this routine hands over to the one above
                if not listening() or S.fast then return end
                if floor(machine.peek(h.wOptions) / 2 ^ h.stereoBit) % 2 == 1 then effect(d, e) end
            end) },
            { bank = bank, addr = h.playCry, fn = safe(function(_, _, _, d, e)
                if not listening() or S.fast then return end
                local key = ("%02x_%04x_%04x"):format(d * 256 + e, word(h.wCryPitch), word(h.wCryLength))
                local x = pack.cry[key]
                if x then playEffect("c" .. key .. ".ogg", x, true) end
            end) },
        },
        currentSong = function()
            for ch = 0, 3 do
                local base = h.wChannel1 + ch * h.chanSize
                if machine.peek(base + 3) % 2 == 1 then return ("%03d"):format(word(base)) end
            end
        end,
        fading = function()
            local fade = machine.peek(h.wMusicFade)
            if fade > 0 and fade < 128 then return floor(8 * (fade % 64 + 1) / 59.7 * 1000) end
        end,
        alarm = function() return machine.peek(h.wLowHealthAlarm) >= 128 end,
    }
end

-- Pokemon Red and Blue. The music program exists three times, in three ROM
-- banks, each with its own songs and sounds: a sound is its bank and number.
-- Cries and battle sounds are also bent in pitch and tempo by two settings,
-- so those are recorded once per setting the game is known to use.
function drivers.pokered()
    local h = hooks
    local pending = nil
    local list = {}
    local function bent(bank, id)
        return (id >= h.cryStart and id < h.cryEnd)
            or (bank == h.battleBank and id >= h.battleStart and id < h.battleEnd)
    end
    local nBanks = 0
    while h["bank" .. (nBanks + 1)] do nBanks = nBanks + 1 end     -- (three in Red and Blue, four in Yellow)
    for i = 1, nBanks do
        local bank, maxSfx = h["bank" .. i], h["maxSfx" .. i]
        -- the game asks for a sound...
        list[#list + 1] = { bank = bank, addr = h["playSound" .. i], fn = safe(function(a)
            pending = nil
            if not listening() then return end
            if a == 0xFF then                        -- "stop everything"
                stopMusic()
                stopEffects()
            elseif a > maxSfx then
                playSong(("%02x_%02x"):format(bank, a))
            elseif a >= h.cryStart and not S.fast then   -- (lower numbers are the songs' own drum sounds)
                pending = a
            end
        end) }
        -- ...and the sound is let through (a more important one may be playing instead)
        list[#list + 1] = { bank = bank, addr = h["playChannel" .. i], fn = safe(function()
            local id = pending
            pending = nil
            if not id or not listening() then return end
            local key, x
            if bent(bank, id) then
                key = ("%02x_%02x_%02x%02x"):format(bank, id, machine.peek(h.wFrequencyModifier), machine.peek(h.wTempoModifier))
                x = pack.sfx[key]
                if not x then                        -- a setting we have no recording of: play it unbent
                    key = ("%02x_%02x_0080"):format(bank, id)
                    x = pack.sfx[key]
                end
            else
                key = ("%02x_%02x"):format(bank, id)
                x = pack.sfx[key]
            end
            if x then playEffect("s" .. key .. ".ogg", x, loud(x)) end
        end) }
    end
    if h.pikaBank then
        -- Yellow: Pikachu's voice is recorded sound, played by a routine of its own (the game stands still for it)
        list[#list + 1] = { bank = h.pikaBank, addr = h.pikaClip, fn = safe(function(_, _, _, _, e)
            if not listening() or S.fast then return end
            local key = ("pk%02d"):format(e)
            local x = pack.sfx[key]
            if x then playEffect("s" .. key .. ".ogg", x, true) end
        end) }
    end
    return {
        breakpoints = list,
        currentSong = function()
            for ch = 0, 3 do
                local id = machine.peek(h.wChannelSoundIDs + ch)
                if id ~= 0 then return ("%02x_%02x"):format(machine.peek(h.wAudioROMBank), id) end
            end
        end,
        fading = function()
            if machine.peek(h.wAudioFadeOutControl) ~= 0 then
                return floor(8 * (machine.peek(h.wAudioFadeOutCounterReloadValue) + 1) / 59.7 * 1000)
            end
        end,
        alarm = function()
            local v = machine.peek(h.wLowHealthAlarm)
            return v >= 128 and v ~= 255 and machine.peek(h.wAudioROMBank) == h.battleBank
        end,
    }
end

-- Game Boy Advance games: the music program nearly all of them share ("m4a"). There is nowhere
-- to set a breakpoint in a translated game, and no need: the program keeps a small record for each
-- of its players (one for the song, three for sound effects, two for cries) saying which piece it
-- holds, whether it is going, and how far in it is. Those records are read after every frame.
function drivers.m4a()
    local h = hooks
    local rd8, rd32 = machine.rd8, machine.rd32
    local number = {}                       -- where a piece lives in the cartridge -> its number in the game's list
    for n = h.songs - 1, 0, -1 do number[rd32(h.songTable + n * 8)] = n end
    local cries = h.cryTable and (h.cryTableReverse - h.cryTable) / 12 or 0
    -- Which player carries the music: the first, unless the pack says otherwise (h.bgm; a few games keep their
    -- songs on another, The Minish Cap on its 32nd). Every other player is a channel for sound effects, and a new
    -- sound on a channel cuts off the one before it (the "mask" is that channel's own bit).
    local bgmAt = h.bgm or 1
    local players = {}
    for i, at in ipairs(h.players) do
        local mask = 0
        if i ~= bgmAt then mask = h.bgm and 2 ^ (i - 1) or 2 ^ (i - 2) end
        players[#players + 1] = { at = at, bgm = (i == bgmAt), mask = mask, hdr = 0, on = false, clock = 0 }
    end
    local bgmPlayer = h.players[bgmAt]
    for _, at in ipairs(h.cryPlayers or {}) do players[#players + 1] = { at = at, cry = true, mask = 256, hdr = 0, on = false, clock = 0 } end
    local function keyOf(hdr)
        local n = number[hdr]
        return n and ("%03d"):format(n)
    end
    local function going(status) return status < 2147483648 and status % 65536 ~= 0 end
    local function cry(hdr)
        if hdr < 33554432 or hdr >= 67108864 then return end
        local idx = (rd32(hdr + 4) - h.cryTable) / 12
        if idx < 0 or idx >= cries or idx % 1 ~= 0 then return end      -- (played backwards for a move, or not a cry at all)
        -- the game bends a cry by pitch and length; pick the recording made the same way
        local length = rd8(hdr + 0x2E) + rd8(hdr + 0x2F) * 256
        local pitch = rd8(hdr + 0x2A) * 256 + rd8(hdr + 0x12) * 2 - 128
        local how = (length <= 30 and "d") or (pitch < 14720 and "f") or (pitch < 15180 and "w") or "n"
        local key = ("%03d_%s"):format(idx, how)
        if not pack.cry[key] then key = ("%03d_n"):format(idx) end
        local x = pack.cry[key]
        if x then
            playEffect("c" .. key .. ".ogg", x, false)
            softUntil = GetTime() + x.len
        end
    end
    local function look(act)
        for i = 1, #players do
            local p = players[i]
            local hdr, status, clock = rd32(p.at), rd32(p.at + 4), rd32(p.at + 12)
            local on = going(status)
            -- a fresh start: another piece, or the count of beats gone back to the beginning
            -- (a piece carried on with after a pause keeps its count)
            local started = on and (hdr ~= p.hdr or clock < p.clock or (not p.on and p.clock == 0))
            if not act then
                -- (just taking stock)
            elseif p.bgm then
                if started then
                    hushed = false
                    playSong(keyOf(hdr) or "")
                elseif on and not p.on then                 -- carried on with, after a fanfare say
                    hushed = false
                    local key = keyOf(hdr)
                    if key and not (music and music.id == key) then playSong(key) end
                elseif p.on and not on then
                    if ducking and music and not music.fading then hushed = true else stopMusic() end
                end
            elseif p.cry then
                if started and not S.fast then cry(hdr) end
            else
                if started then
                    local key = keyOf(hdr)
                    local x = key and pack.sfx[key]
                    p.fx = nil
                    stopEffectsOn(p.mask)
                    if x and not S.fast then
                        playEffect("s" .. key .. ".ogg", x, false)
                        p.fx = { key = key, ends = GetTime() + x.len, loops = x.loops }
                    end
                elseif p.on and not on then
                    if p.fx and p.fx.loops then stopEffectsOn(p.mask) end
                    p.fx = nil
                elseif on and p.fx and p.fx.loops and GetTime() >= p.fx.ends then
                    -- a sound that goes round and round (rain, say) has reached the end of its recording
                    local x = pack.sfx[p.fx.key]
                    playEffect("s" .. p.fx.key .. ".ogg", x, false)
                    p.fx.ends = GetTime() + x.len
                end
            end
            p.hdr, p.on, p.clock = hdr, on, clock
        end
    end
    return {
        poll = function() look(true) end,
        prime = function() hushed = false look(false) end,
        currentSong = function()
            local at = bgmPlayer
            if going(rd32(at + 4)) then return keyOf(rd32(at)) end
        end,
        fading = function()
            local at = bgmPlayer
            local every = machine.rd16(at + 0x24)
            local level = machine.rd16(at + 0x28)
            if every > 0 and level % 4 < 2 and going(rd32(at + 4)) then
                return floor(floor(level / 16) * every / 59.7 * 1000)
            end
        end,
        alarm = function() return false end,
    }
end

-- MekkaBoy's own games (games/gba): the game writes what it wants into a mailbox in its working memory
-- (a magic word, song number, a count that changes with each request, sound number, its count), and the
-- recording of that number plays. Song 255 means silence.
function drivers.native()
    local rd8, rd32 = machine.rd8, machine.rd32
    local at = hooks.mailbox or 0x03007E00
    local last = {}
    local function key(n) return ("%03d"):format(n) end
    local function look(act)
        if rd32(at) ~= 0x4E53424D then return end
        local song, songSeq, fx, fxSeq = rd8(at + 4), rd8(at + 5), rd8(at + 6), rd8(at + 7)
        if act then
            if songSeq ~= last.songSeq then
                hushed = false
                if song == 255 then stopMusic() else playSong(key(song)) end
            end
            if fxSeq ~= last.fxSeq and not S.fast then
                local x = pack.sfx[key(fx)]
                if x then playEffect("s" .. key(fx) .. ".ogg", x, x.duck and true or false) end
            end
        end
        last.songSeq, last.fxSeq = songSeq, fxSeq
    end
    return {
        poll = function() look(true) end,
        prime = function() look(false) end,
        currentSong = function()
            if rd32(at) ~= 0x4E53424D then return nil end
            local song = rd8(at + 4)
            if song ~= 255 then return key(song) end
        end,
        fading = function() return nil end,
        alarm = function() return false end,
    }
end

local function resync()
    stopEffects()
    hushed = false
    if driver.prime then driver.prime() end
    local key = driver.currentSong()
    if key and pack.music[key] then
        startMusic(key)
    else
        stopMusic()
    end
end

local function setBreakpoints()
    if not (machine and machine.setBreakpoints) then return end
    if not (pack and driver and enabled()) then
        machine.setBreakpoints(nil)
        return
    end
    machine.setBreakpoints(driver.breakpoints)
end

-- ----------------------------------------------------------- ticker ---
local ticker = CreateFrame("Frame")
ticker:Hide()
local pollAcc = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    if not session then return end
    local now = GetTime()
    if music and now >= music.ends then
        if music.once then music = nil else startMusic(music.id) end
    end
    local base = level()
    tuneEffects()
    -- The game client drops a song left at no volume at all (and will not start one there), so a
    -- song does not come back by itself when the volume does: it is started again from its opening.
    if base <= 0 then
        silenced = true
    elseif silenced and machine and pack and driver and listening() then
        silenced = false
        resync()
    end
    if paused or hushed or now < duckUntil then setVolume(math.min(quietLevel(), base))
    elseif now < softUntil then setVolume(base * 0.35)
    else setVolume(base) end

    -- a song that should be heard: is it still there? (see `sounding`; a start the client refused counts as gone)
    if paused or hushed or now < duckUntil or base <= 0 then quietAt = now end
    if music and not music.once and quietAt ~= now and now >= lookAt and machine and listening() then
        lookAt = now + 0.5
        if now - music.began >= 1 and now - quietAt >= 0.5 and now < music.ends - 1 then
            local there = true
            if not music.handle then there = false else there = sounding(music.handle) end
            if there == false then
                misses = misses + 1
                if music.handle and not everHeard and misses > 3 then
                    askOK, note.gaveUp = false, "never a yes"       -- (it says no to everything: not to be gone by)
                else
                    note.back = note.back + 1
                    if not music.handle then note.failedStarts = note.failedStarts + 1 end
                    if now - quietAt < 10 then note.afterQuiet = note.afterQuiet + 1 end
                    startMusic(music.id)
                    lookAt = now + lookWait
                    lookWait = math.min(lookWait * 2, 8)
                end
            elseif there then misses, lookWait = 0, 1 end
        end
    end

    pollAcc = pollAcc + elapsed
    if pollAcc < 0.1 then return end
    pollAcc = 0
    if not (machine and listening()) then return end
    -- the game fading a song out
    local fadeMs = music and not music.fading and driver.fading()
    if fadeMs then
        music.fading = true
        stopHandle(music.handle, fadeMs)
        music.handle = nil
        music.once = true
    end
    -- the low-health alarm
    if pack.danger then
        local on = driver.alarm() and not S.fast
        if on and (not danger or now >= danger.ends) then
            local willPlay, handle = playFx(pack.dir .. "danger.ogg")
            danger = { handle = willPlay and handle or nil, ends = now + pack.danger }
        elseif not on and danger then
            stopHandle(danger.handle)
            danger = nil
        end
    end
end)

local function beginSession()
    if session then return end
    session = true
    ducking = MB.Opt("duck", true)
    volume = nil
    if ducking then
        local db = MB.DB()
        if not db.soundRestore then
            db.soundRestore = { volume = GetCVar("Sound_MusicVolume"), enable = GetCVar("Sound_EnableMusic") }
        end
        SetCVar("Sound_EnableMusic", "1")
        setVolume(level())
    end
    fxVolume = nil
    silenced = false
    tuneEffects()
    borrowBackground()
    PlayMusic(SILENCE)      -- hushes the world's music while the console plays
    ticker:Show()
end

local function endSession()
    if not session then return end
    session = false
    ticker:Hide()
    stopMusic()
    stopEffects()
    StopMusic()
    restoreSettings()
end

-- ------------------------------------------------ the console's calls ---
-- a game has been switched on (or replaced)
function S.Attach(m, title)
    if session then stopMusic() stopEffects() end
    machine = m
    pack = m and MB.SoundPacks[title] or nil
    hooks = pack and pack.hooks
    driver = nil
    if pack then
        local make = drivers[pack.engine]
        local ok, d = pcall(make or error)       -- a pack for a music program this version does not know
        if ok and hooks then driver = d else pack, hooks = nil, nil end
    end
    setBreakpoints()
end

-- the game is running
function S.Run()
    if not (machine and pack and enabled()) then return end
    local fresh = not session
    beginSession()
    paused, live = false, true
    if fresh or not music then
        local base = level()
        if base > 0 then setVolume(base) silenced = false end     -- (a song will not start at no volume)
        resync()
    end
end

-- (Game Boy Advance) a frame or more of the game has gone by: see what its music program is up to
function S.Poll()
    if session and listening() and driver and driver.poll then pcall(driver.poll) end
end

-- the game is paused. A song cannot be paused: it carries on unheard and is heard again, further along, when the
-- game carries on (see HUSH). Where the client cannot say afterwards whether the song is still there, it is
-- stopped instead and starts again from its opening.
function S.Pause()
    if not session then return end
    paused = true
    for i = #effects, 1, -1 do
        stopHandle(effects[i].handle)
        effects[i] = nil
    end
    if danger then stopHandle(danger.handle) danger = nil end
    if ducking and canAsk() then setVolume(math.min(HUSH, level()))
    else
        stopMusic()
        if ducking then setVolume(0) end
    end
end

-- for the notes kept at logout: can this client say whether a sound is still sounding, and how often a song had
-- to be brought back
function S.Notes()
    return { canAsk = (C_Sound and C_Sound.IsPlaying) and true or false, trusted = askOK, heardYes = everHeard, gaveUp = note.gaveUp,
             broughtBack = note.back, afterQuiet = note.afterQuiet, failedStarts = note.failedStarts,
             inBackground = select(2, pcall(GetCVar, "Sound_EnableSoundWhenGameIsInBG")) }
end

-- the console was put away, or the game stopped
function S.Stop()
    live, paused = false, false
    endSession()
end

-- the game jumped somewhere else (a memory valve was loaded)
function S.Resync()
    if session and machine and pack then resync() end
end

-- rewinding: silence, then pick the song up again where the game ends up
function S.SetRewinding(on)
    if not session then return end
    if on and live then
        live = false
        stopMusic()
        stopEffects()
    elseif not on and not live then
        live = true
        resync()
    end
end

S.fast = false   -- fast-forward: songs carry on, effects are skipped

function S.Describe()
    if not machine then return "Switch the console on first." end
    if not pack then
        return "No soundtrack pack for this game. Tools/soundpack.py (or soundpack_gba.py) builds one from your own copy; see the README."
    end
    local songs, fx, cries = 0, 0, 0
    for _ in pairs(pack.music) do songs = songs + 1 end
    for _ in pairs(pack.sfx) do fx = fx + 1 end
    for _ in pairs(pack.cry) do cries = cries + 1 end
    return ("Sound is %s, ducking %s, in the background %s. Pack: %s - %d songs, %d sound effects, %d cries. %s")
        :format(enabled() and "on" or "off", MB.Opt("duck", true) and "on" or "off", MB.Opt("soundBackground", true) and "on" or "off",
                pack.game or "?", songs, fx, cries, S.DescribeVolume())
end

-- ------------------------------------------------------------ volume ---
function S.Level() return level() end              -- 0..1, for the wheel on the body
function S.DescribeVolume()
    local v = own()
    if not v then return "Volume follows your Sound Effects slider (turn the console's wheel, or /mb volume 0-100, for a volume of its own)." end
    if not MB.Opt("duck", true) then return "The console's own volume needs /mb sound duck on; until then it follows your Sound Effects slider." end
    if fxRefused then
        return ("Console volume %d%% for songs. This game client would not give effects a channel of their own, so those follow your Sound Effects slider."):format(floor(v * 100 + 0.5))
    end
    return ("Console volume %d%%, apart from the rest of WoW (/mb volume auto goes back to following the Sound Effects slider)."):format(floor(v * 100 + 0.5))
end

-- set the console's own volume: 0..1, or nil to follow the Sound Effects slider again
function S.SetVolume(v)
    local db = MB.DB()
    if v == nil then
        db.opt.volume = nil
        -- hand Ambience back now; effects still sounding there finish at the world's level
        local keep = db.soundRestore
        if keep and keep.fxVolume then
            SetCVar("Sound_AmbienceVolume", keep.fxVolume)
            SetCVar("Sound_EnableAmbience", keep.fxEnable)
            keep.fxVolume, keep.fxEnable = nil, nil
        end
        fxChannel, fxVolume = "SFX", nil
    else
        db.opt.volume = (v < 0 and 0) or (v > 1 and 1) or v
        if session then tuneEffects() end
    end
    return level()
end

-- one notch up or down (a tenth). Returns the new level.
function S.Nudge(steps)
    local now = floor(level() * 10 + 0.5) + steps
    return S.SetVolume(((now < 0 and 0) or (now > 10 and 10) or now) / 10)
end

MB.AddCommand("volume", "volume <0-100>|up|down|auto - the console's own volume, apart from the rest of WoW (auto: follow the Sound Effects slider)", function(rest)
    rest = (rest or ""):lower()
    local n = tonumber(rest)
    if rest == "auto" then S.SetVolume(nil)
    elseif rest == "up" then S.Nudge(1)
    elseif rest == "down" then S.Nudge(-1)
    elseif n and n >= 0 and n <= 100 then S.SetVolume(n / 100)
    elseif rest ~= "" then MB.Print("Use /mb volume 0 to 100, up, down, or auto.") return end
    if MB.SetVolumeKnob then MB.SetVolumeKnob(level()) end
    MB.Print(S.DescribeVolume())
end)

-- the sound settings changed: start again the new way
function S.Reapply()
    setBreakpoints()
    local was = live
    S.Stop()                      -- hands back anything borrowed; the new way starts clean
    if enabled() and (was or (MB.IsRunning and MB.IsRunning()) or (MB.Advance and MB.Advance.IsOpen and MB.Advance.IsOpen())) then S.Run() end
end
function S.SetEnabled(on)
    MB.DB().opt.sound = on and true or false
    S.Reapply()
end

function S.SetBackground(on)
    MB.DB().opt.soundBackground = on and true or false
    S.Reapply()
end
MB.AddCommand("sound", "sound on|off, sound duck on|off, sound background on|off - the game's music and sounds (needs a soundtrack pack); duck: songs go silent under cries, as on the console; background: sound carries on while another window is in front", function(rest)
    local db = MB.DB()
    local changed = true
    if rest == "on" then db.opt.sound = true
    elseif rest == "off" then db.opt.sound = false
    elseif rest == "duck on" then db.opt.duck = true
    elseif rest == "duck off" then db.opt.duck = false
    elseif rest == "background on" then db.opt.soundBackground = true
    elseif rest == "background off" then db.opt.soundBackground = false
    else changed = false end
    if changed then S.Reapply() end
    MB.Print(S.Describe())
end)

-- If the game client closed while the console was open, the borrowed
-- settings are still in our keeping: put them back first thing.
MB.onLogin[#MB.onLogin + 1] = restoreSettings
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function() S.Stop() restoreSettings() end)
