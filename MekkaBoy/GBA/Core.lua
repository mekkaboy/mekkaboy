-- MekkaBoy Advance: a Game Boy Advance, in Lua 5.1, for the WoW client.
--
-- EXPERIMENTAL. This exists to answer one question: can a real GBA game reach
-- its title screen at a usable speed inside the client?
--
-- How it is put together:
--   1. the bus: memory and who answers at each address
--   2. the processor: both instruction sets, translated a stretch at a time
--      into Lua functions (see "the translator")
--   3. stand-ins for the routines Nintendo built into the console (the BIOS)
--   4. the screen
--   5. the system: what happens when, across one frame
local ADDON, MB = ...

local GBA = {}
if type(MB) == "table" then MB.GBA = GBA end

local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat
local W, HALF = 4294967296, 2147483648

-- 32-bit and/or/xor: WoW has a library for it; elsewhere, fall back to tables.
local band, bor, bxor
if bit and bit.band then
    local a, o, x = bit.band, bit.bor, bit.bxor
    band = function(p, q) return a(p, q) % 4294967296 end
    bor = function(p, q) return o(p, q) % 4294967296 end
    bxor = function(p, q) return x(p, q) % 4294967296 end
else
    local A, O, X = {}, {}, {}
    for p = 0, 255 do
        for q = 0, 255 do
            local ra, ro, rx, m = 0, 0, 0, 1
            local pp, qq = p, q
            for _ = 1, 8 do
                local pb, qb = pp % 2, qq % 2
                if pb + qb == 2 then ra = ra + m end
                if pb + qb >= 1 then ro = ro + m end
                if pb ~= qb then rx = rx + m end
                pp, qq, m = (pp - pb) / 2, (qq - qb) / 2, m * 2
            end
            A[p * 256 + q], O[p * 256 + q], X[p * 256 + q] = ra, ro, rx
        end
    end
    local function via(T)
        return function(p, q)
            local p0, q0 = p % 256, q % 256
            local p1, q1 = (p - p0) / 256 % 256, (q - q0) / 256 % 256
            local p2, q2 = floor(p / 65536) % 256, floor(q / 65536) % 256
            local p3, q3 = floor(p / 16777216), floor(q / 16777216)
            return T[p0 * 256 + q0] + T[p1 * 256 + q1] * 256 + T[p2 * 256 + q2] * 65536 + T[p3 * 256 + q3] * 16777216
        end
    end
    band, bor, bxor = via(A), via(O), via(X)
end
GBA.band, GBA.bor, GBA.bxor = band, bor, bxor

local POW = {}
for i = 0, 32 do POW[i] = 2 ^ i end

local function zeros(n, v)
    local t = {}
    v = v or 0
    for i = 0, n - 1 do t[i] = v end
    return t
end

-- --------------------------------------------------------------------- the bus ---
-- Working memory is kept as whole 32-bit words (most of what a game does with
-- it is 32-bit); picture memory as bytes, with a second copy split into
-- 4-bit dots for the screen painter; colors and sprite records as 16-bit.
local function buildBus(S)
    local iw, ew = zeros(8192), zeros(65536)
    local vram, vnib, vrow = zeros(0x18000), zeros(0x30000), zeros(0x6002)
    local vcls = {}                             -- (what kind of row each tile row is; the screen fills it in)
    S.vcls = vcls
    local pal, palRaw, oam = zeros(512), zeros(512), zeros(512)
    local bios = {}
    local banks, romSize = S.romBanks, S.romSize
    local BANK = S.bankSize or 16384
    local flash = zeros(131072, 255)
    local P = { [0] = 1, 256, 65536, 16777216 }
    S.iw, S.ew, S.vram, S.vnib, S.vrow, S.pal, S.palRaw, S.oam, S.bios, S.flash = iw, ew, vram, vnib, vrow, pal, palRaw, oam, bios, flash
    -- For the painter's shortcuts: stampAll ticks whenever anything a picture is made from really changes;
    -- the ...At values say when each kind of thing last did, and vstamp[] says it for each 32 bytes of picture memory.
    S.stampAll, S.palStamp = 1, 1
    S.palAt, S.oamAt, S.ioAt, S.vramAt, S.objAt = 1, 1, 1, 1, 1
    S.scrollAt = 1
    local vstamp = zeros(0xC02)
    S.vstamp = vstamp
    function S.allChanged()
        local g = S.stampAll + 1
        S.stampAll, S.palStamp = g, S.palStamp + 1
        S.palAt, S.oamAt, S.ioAt, S.vramAt, S.objAt = g, g, g, g, g
        S.scrollAt = g
        for i = 0, 0xC01 do vstamp[i] = g end
        S.oamStamp = (S.oamStamp or 0) + 1
    end

    -- The save chip. Cartridges carry one of four kinds, and the cartridge says which (S.chip):
    --   nil        128K flash, spoken to with little command sequences (the Pokemon games)
    --   "flash64"  64K flash: the same commands, another name when asked who it is, and one bank
    --   "sram"     32K of plain memory at the same addresses: what is written is simply kept
    --   "eeprom"   a small serial chip (512 bytes or 8K) reached through the END of the cartridge's own addresses,
    --              a bit at a time (see "the serial save chip" further down)
    -- Whatever the kind, the bytes live in `flash` and the save is kept in the same form (32 sectors of 4K, the
    -- unused ones blank), so everything that keeps, loads and photographs a save is the same for all four.
    local fState, fCmd, fBank, fId = 0, 0, 0, false
    local isSram = S.chip == "sram"
    local eN, eAt, eLen = 0, 0, 0               -- the serial chip: bits sent to it, bits read from its answer, the answer's length
    S.flashDirty = false
    S.flashWrites = 0                           -- (counts up with every change, so a quiet spell can be noticed)
    local fTouched = {}                         -- 4K sectors changed since they were last written out
    local fText = {}                            -- each sector as text, as last written out
    -- The save, in a form a settings file can hold: 32 sectors of 4K, each as a string of hex digits
    -- ("" for a sector that is blank). Only sectors that changed are worked out again.
    local HEX = {}
    for i = 0, 255 do HEX[i] = ("%02x"):format(i) end
    function S.getSave()
        local out = { kind = "flash128", sectors = {} }
        local piece = {}
        for n = 0, 31 do
            if fTouched[n] or not fText[n] then
                local base, blank = n * 4096, true
                for i = 0, 4095 do
                    local v = flash[base + i]
                    if v ~= 255 then blank = false end
                    piece[i + 1] = HEX[v]
                end
                fText[n] = blank and "" or table.concat(piece)
                fTouched[n] = nil
            end
            out.sectors[n + 1] = fText[n]
        end
        S.flashDirty = false
        return out
    end
    function S.loadSave(t)
        if type(t) ~= "table" or t.kind ~= "flash128" or type(t.sectors) ~= "table" then return false end
        for n = 0, 31 do
            local text = t.sectors[n + 1]
            local base = n * 4096
            if type(text) == "string" and #text == 8192 then
                for i = 0, 4095 do flash[base + i] = tonumber(text:sub(i * 2 + 1, i * 2 + 2), 16) or 255 end
                fText[n] = text
            else
                for i = 0, 4095 do flash[base + i] = 255 end
                fText[n] = ""
            end
            fTouched[n] = nil
        end
        S.flashDirty = false
        return true
    end
    local function flashRead(a)
        if isSram then return flash[a % 32768] end
        local o = a % 65536
        if fId and o < 2 then
            if S.chip == "flash64" then return (o == 0) and 0x32 or 0x1B end       -- Panasonic 64K
            return (o == 0) and 0xC2 or 0x09                                       -- Macronix 128K
        end
        return flash[fBank * 65536 + o]
    end
    local function flashWrite(a, v)
        if isSram then
            local at = a % 32768
            if flash[at] ~= v then
                flash[at] = v
                S.flashDirty = true
                S.flashWrites = S.flashWrites + 1
                fTouched[(at - at % 4096) / 4096] = true
            end
            return
        end
        local o = a % 65536
        if fCmd == 0xA0 then                    -- write one byte
            local at = fBank * 65536 + o
            if flash[at] ~= v then
                flash[at] = v
                S.flashDirty = true
                S.flashWrites = S.flashWrites + 1
                fTouched[(at - at % 4096) / 4096] = true
            end
            fCmd, fState = 0, 0
            return
        elseif fCmd == 0xB0 and o == 0 then     -- pick a bank
            fBank = (S.chip == "flash64") and 0 or v % 2     -- (the 64K chip has one bank only)
            fCmd, fState = 0, 0
            return
        end
        if fState == 0 and o == 0x5555 and v == 0xAA then fState = 1
        elseif fState == 1 and o == 0x2AAA and v == 0x55 then fState = 2
        elseif fState == 2 then
            fState = 0
            if o == 0x5555 then
                if v == 0x90 then fId = true
                elseif v == 0xF0 then fId = false
                elseif v == 0x80 then fCmd = 0x80
                elseif v == 0x10 and fCmd == 0x80 then
                    for i = 0, 131071 do flash[i] = 255 end
                    for n = 0, 31 do fTouched[n] = true end
                    S.flashDirty = true
                    S.flashWrites = S.flashWrites + 1
                    fCmd = 0
                elseif v == 0xA0 then fCmd = 0xA0
                elseif v == 0xB0 then fCmd = 0xB0 end
            elseif v == 0x30 and fCmd == 0x80 then      -- erase a 4K sector
                local base = fBank * 65536 + (o - o % 4096)
                for i = base, base + 4095 do flash[i] = 255 end
                fTouched[base / 4096] = true
                S.flashDirty = true
                S.flashWrites = S.flashWrites + 1
                fCmd = 0
            end
        elseif v == 0xF0 then fId, fState, fCmd = false, 0, 0 end
    end

    -- The cartridge's clock. A few games carry a small clock chip, wired to three pins that the game
    -- reaches through addresses 0xC4-0xC8 of the cartridge: a clock line, a data line and a "listen"
    -- line. The game sends a command a bit at a time, then reads or writes the bytes that go with it.
    -- The time itself comes from the computer's clock (S.clock, which the host may replace).
    local gPins, gDir, gReadable = 0, 0, false
    local cStep, cBits, cRead, cCmd, cActive, cLeft, cReading = 0, 0, 0, 0, false, 0, false
    local cControl = 0x40                       -- 24-hour clock, battery fine
    local cTime = { 0, 1, 1, 0, 0, 0, 0 }
    local C_BYTES = { [0] = 0, 0, 7, 0, 1, 0, 3, 0 }
    local function bcd(n) return floor(n / 10) * 16 + n % 10 end
    local NOON = { year = 2026, month = 1, day = 1, wday = 5, hour = 12, min = 0, sec = 0 }
    S.clock = S.clock or function() return os and os.date and os.date("*t") end
    S.clockUsed = false
    local function clockNow()
        local t = S.clock()
        if type(t) ~= "table" or not (t.year and t.month and t.day and t.hour and t.min and t.sec) then t = NOON end
        local hour = t.hour
        if cControl % 128 < 64 then hour = hour % 12 end
        cTime[1], cTime[2], cTime[3], cTime[4] = bcd(t.year % 100), bcd(t.month), bcd(t.day), bcd((t.wday or 1) - 1)
        cTime[5], cTime[6], cTime[7] = bcd(hour), bcd(t.min), bcd(t.sec)
        S.clockUsed = true
    end
    local function gpioOut(pins)                -- what the chip drives onto the lines the game is listening on
        if gReadable then gPins = GBA.band(gPins, gDir) + GBA.band(pins, 15 - gDir) end
    end
    local function clockPins(wasHigh)
        local sck, sio, cs = gPins % 2, floor(gPins / 2) % 2, floor(gPins / 4) % 2
        if cStep == 0 then
            if sck == 1 and cs == 0 then cStep = 1 end
        elseif cStep == 1 then
            if sck == 1 and cs == 1 then cStep = 2 end
        elseif sck == 0 then
            -- clock line low: the data line holds the next bit of whatever the game is sending
            cBits = cBits - (floor(cBits / POW[cRead]) % 2) * POW[cRead] + sio * POW[cRead]
        elseif cs == 0 then
            cRead, cLeft, cActive, cReading = 0, 0, false, false
            cStep = sck
            gpioOut(1)
        elseif not wasHigh then
            -- clock line rising, chip listening
            if floor(gDir / 2) % 2 == 1 then
                cRead = cRead + 1
                if cRead == 8 then
                    if not cActive then
                        cCmd = floor(cBits / 16) % 8
                        cReading = cBits >= 128
                        if cBits % 16 == 6 then
                            cLeft = C_BYTES[cCmd]
                            cActive = cLeft > 0
                            if cCmd == 0 then cControl = 0
                            elseif cCmd == 2 or cCmd == 6 then clockNow() end
                        end
                    else
                        if cCmd == 4 then cControl = cBits end
                        cLeft = cLeft - 1
                    end
                    cBits, cRead = 0, 0
                    if cLeft <= 0 then cActive, cReading = false, false end
                end
            else
                local out = 0
                if cCmd == 4 then out = cControl
                elseif cCmd == 2 or cCmd == 6 then out = cTime[8 - cLeft] or 0 end
                gpioOut(5 + (floor(out / POW[cRead]) % 2) * 2)
                cRead = cRead + 1
                if cRead == 8 then
                    cLeft = cLeft - 1
                    if cLeft <= 0 then cActive, cReading = false, false end
                    cRead = 0
                end
            end
        end
    end
    local function gpioWrite(o, v)
        if o == 0xC4 then
            local wasHigh = gPins % 2 == 1
            gPins = GBA.band(gPins, 15 - gDir) + GBA.band(v % 16, gDir)
            clockPins(wasHigh)
        elseif o == 0xC6 then gDir = v % 16
        elseif o == 0xC8 then gReadable = v % 2 == 1 end
    end
    local function gpioRead(o)
        if o == 0xC4 then return gPins elseif o == 0xC6 then return gDir end
        return 1
    end

    -- For memory valves (see "a photograph of the machine" at the end of this file): the small
    -- state of the save chip and the clock chip, and putting the derived tables right after the
    -- big ones have been filled in from a photograph.
    function S.busSave()
        return { fState = fState, fCmd = fCmd, fBank = fBank, fId = fId, gPins = gPins, gDir = gDir, gReadable = gReadable,
                 cStep = cStep, cBits = cBits, cRead = cRead, cCmd = cCmd, cActive = cActive, cLeft = cLeft, cReading = cReading,
                 cControl = cControl, cTime = { cTime[1], cTime[2], cTime[3], cTime[4], cTime[5], cTime[6], cTime[7] }, biosBus = biosBus }
    end
    function S.busLoad(t)
        fState, fCmd, fBank, fId = t.fState, t.fCmd, t.fBank, t.fId and true or false
        eN, eAt, eLen = 0, 0, 0                 -- (a photograph is never taken in the middle of a word with the serial chip)
        gPins, gDir, gReadable = t.gPins, t.gDir, t.gReadable and true or false
        cStep, cBits, cRead, cCmd, cActive, cLeft, cReading = t.cStep, t.cBits, t.cRead, t.cCmd, t.cActive and true or false, t.cLeft, t.cReading and true or false
        cControl = t.cControl
        biosBus = t.biosBus or 0xE25EF004       -- (older photographs: as after an interrupt, which is nearly always so)
        for i = 1, 7 do cTime[i] = t.cTime[i] or 0 end
        -- everything worked out from picture memory and the colors
        for o = 0, 0x17FFF do
            local v = vram[o]
            local lo = v % 16
            vnib[o * 2], vnib[o * 2 + 1] = lo, (v - lo) / 16
        end
        for q = 0, 0x5FFF do
            local o = q * 4
            vrow[q] = vram[o] + vram[o + 1] + vram[o + 2] + vram[o + 3]
        end
        for k in pairs(vcls) do vcls[k] = nil end
        for o = 0, 511 do pal[o] = palRaw[o] % 32768 end
        -- the save chip's contents came with the photograph: all of it counts as changed
        for n = 0, 31 do fTouched[n] = true fText[n] = nil end
        S.flashDirty = true
        S.flashWrites = S.flashWrites + 1
        S.allChanged()
    end

    local ioRead, ioWrite                       -- 16-bit, filled in by the system
    function S.setIO(rd, wr) ioRead, ioWrite = rd, wr end

    local function romByte4(o)
        if o >= romSize then local h = floor(o / 2) % 65536 return h + ((h + 1) % 65536) * 65536 end
        local s = banks[floor(o / BANK) + 1]
        local i = o % BANK
        local b1, b2, b3, b4 = byte(s, i + 1, i + 4)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    -- An address with nothing behind it does not answer 0 on the real machine: the lines keep whatever went over
    -- them last, which is the instruction the processor fetched ahead (`ob`, worked out when the stretch is
    -- translated and handed in by it; the machine's own routines hand in nothing and get 0). The built-in program
    -- cannot be read by a game at all: it gets the last thing that program itself fetched (biosBus). Games do
    -- lean on this without meaning to: The Minish Cap follows an empty pointer into both, and only the non-zero
    -- answer ends its loop.
    local biosBus = 0xE129F000
    function S.setBiosBus(v) biosBus = v end
    local function rd32(a, ob)
        local reg = floor(a / 16777216)
        if reg == 3 then return iw[(a % 32768 - a % 4) / 4]
        elseif reg == 2 then return ew[(a % 262144 - a % 4) / 4]
        elseif reg >= 8 and reg <= 13 then
            local o = a % 33554432
            return romByte4(o - o % 4)
        elseif reg == 4 then
            local o = a % 16777216
            o = o - o % 4
            if o >= 0x400 then return 0 end
            return ioRead(o) + ioRead(o + 2) * 65536
        elseif reg == 6 then
            local o = a % 131072
            if o >= 98304 then o = o - 32768 end
            o = o - o % 4
            return vram[o] + vram[o + 1] * 256 + vram[o + 2] * 65536 + vram[o + 3] * 16777216
        elseif reg == 5 then
            local o = (a % 1024 - a % 4) / 2
            return palRaw[o] + palRaw[o + 1] * 65536
        elseif reg == 7 then
            local o = (a % 1024 - a % 4) / 2
            return oam[o] + oam[o + 1] * 65536
        elseif reg == 0 then
            if not ob then return bios[(a - a % 4) / 4] or 0 end
            if a < 16384 then return biosBus end
            return ob
        elseif reg == 14 or reg == 15 then
            return flashRead(a) * 16843009
        end
        return ob or 0
    end
    local function rd16(a, ob)
        local reg = floor(a / 16777216)
        if reg == 3 then local o = a % 32768 return floor(iw[(o - o % 4) / 4] / P[o % 4 - o % 2]) % 65536
        elseif reg == 2 then local o = a % 262144 return floor(ew[(o - o % 4) / 4] / P[o % 4 - o % 2]) % 65536
        elseif reg >= 8 and reg <= 13 then
            local o = a % 33554432
            o = o - o % 2
            if o < 0xCA and gReadable and o >= 0xC4 and reg == 8 then return gpioRead(o) end
            if o >= romSize then return floor(o / 2) % 65536 end
            local i = o % BANK
            local b1, b2 = byte(banks[floor(o / BANK) + 1], i + 1, i + 2)
            return b1 + b2 * 256
        elseif reg == 4 then
            local o = a % 16777216
            o = o - o % 2
            if o >= 0x400 then return 0 end
            return ioRead(o)
        elseif reg == 6 then
            local o = a % 131072
            if o >= 98304 then o = o - 32768 end
            o = o - o % 2
            return vram[o] + vram[o + 1] * 256
        elseif reg == 5 then return palRaw[(a % 1024 - a % 2) / 2]
        elseif reg == 7 then return oam[(a % 1024 - a % 2) / 2]
        elseif reg == 0 then
            local w = ob or 0
            if not ob then w = bios[(a - a % 4) / 4] or 0 elseif a < 16384 then w = biosBus end
            return floor(w / P[a % 4 - a % 2]) % 65536
        elseif reg == 14 or reg == 15 then return flashRead(a) * 257 end
        if ob then return floor(ob / P[a % 4 - a % 2]) % 65536 end
        return 0
    end
    local function rd8(a, ob)
        local reg = floor(a / 16777216)
        if reg == 3 then local o = a % 32768 return floor(iw[(o - o % 4) / 4] / P[o % 4]) % 256
        elseif reg == 2 then local o = a % 262144 return floor(ew[(o - o % 4) / 4] / P[o % 4]) % 256
        elseif reg >= 8 and reg <= 13 then
            local o = a % 33554432
            if o >= romSize then
                if o % 2 == 1 then return floor(o / 512) % 256 end
                return floor(o / 2) % 256
            end
            return byte(banks[floor(o / BANK) + 1], o % BANK + 1)
        elseif reg == 4 then
            local o = a % 16777216
            if o >= 0x400 then return 0 end
            local h = ioRead(o - o % 2)
            if o % 2 == 1 then return floor(h / 256) end
            return h % 256
        elseif reg == 6 then
            local o = a % 131072
            if o >= 98304 then o = o - 32768 end
            return vram[o]
        elseif reg == 5 then
            local h = palRaw[(a % 1024 - a % 2) / 2]
            if a % 2 == 1 then return floor(h / 256) end
            return h % 256
        elseif reg == 7 then
            local h = oam[(a % 1024 - a % 2) / 2]
            if a % 2 == 1 then return floor(h / 256) end
            return h % 256
        elseif reg == 0 then
            local w = ob or 0
            if not ob then w = bios[(a - a % 4) / 4] or 0 elseif a < 16384 then w = biosBus end
            return floor(w / P[a % 4]) % 256
        elseif reg == 14 or reg == 15 then return flashRead(a) end
        if ob then return floor(ob / P[a % 4]) % 256 end
        return 0
    end

    local function vramByte(o, v)
        local old = vram[o]
        if old ~= v then
            vram[o] = v
            local q = (o - o % 4) / 4
            vrow[q] = vrow[q] + v - old
            vcls[q] = nil
            local lo = v % 16
            vnib[o * 2] = lo
            vnib[o * 2 + 1] = (v - lo) / 16
            local g = S.stampAll + 1
            S.stampAll = g
            vstamp[(o - o % 32) / 32] = g
            if o >= 65536 then
                S.objAt = g                         -- sprite pictures (and, in the bitmap modes, more picture)
                if S.io[0] % 8 >= 3 then S.vramAt = g end
            else S.vramAt = g end
        end
    end
    S.vramByte = vramByte
    -- four bytes of picture memory at once (at an address that is a multiple of four); true if any changed
    local function vramQuad(o, b0, b1, b2, b3, g)
        if vram[o] == b0 and vram[o + 1] == b1 and vram[o + 2] == b2 and vram[o + 3] == b3 then return false end
        vram[o], vram[o + 1], vram[o + 2], vram[o + 3] = b0, b1, b2, b3
        local q = o / 4
        vrow[q] = b0 + b1 + b2 + b3
        vcls[q] = nil
        local n = o * 2
        local lo = b0 % 16
        vnib[n], vnib[n + 1] = lo, (b0 - lo) / 16
        lo = b1 % 16
        vnib[n + 2], vnib[n + 3] = lo, (b1 - lo) / 16
        lo = b2 % 16
        vnib[n + 4], vnib[n + 5] = lo, (b2 - lo) / 16
        lo = b3 % 16
        vnib[n + 6], vnib[n + 7] = lo, (b3 - lo) / 16
        vstamp[(o - o % 32) / 32] = g
        return true
    end
    local function wr16(a, v)
        local reg = floor(a / 16777216)
        if reg == 3 then
            local o = a % 32768
            local i, p = (o - o % 4) / 4, P[o % 4 - o % 2]
            local w = iw[i]
            iw[i] = w + (v - floor(w / p) % 65536) * p
        elseif reg == 2 then
            local o = a % 262144
            local i, p = (o - o % 4) / 4, P[o % 4 - o % 2]
            local w = ew[i]
            ew[i] = w + (v - floor(w / p) % 65536) * p
        elseif reg == 4 then
            local o = a % 16777216
            o = o - o % 2
            if o < 0x400 then ioWrite(o, v) end
        elseif reg == 6 then
            local o = a % 131072
            if o >= 98304 then o = o - 32768 end
            o = o - o % 2
            local lo = v % 256
            vramByte(o, lo)
            vramByte(o + 1, (v - lo) / 256)
        elseif reg == 5 then
            local o = (a % 1024 - a % 2) / 2
            if palRaw[o] ~= v then
                palRaw[o] = v
                pal[o] = v % 32768
                S.stampAll = S.stampAll + 1
                S.palAt = S.stampAll
                S.palStamp = S.palStamp + 1
            end
        elseif reg == 7 then
            local o = (a % 1024 - a % 2) / 2
            if oam[o] ~= v then oam[o] = v S.oamStamp = (S.oamStamp or 0) + 1 S.stampAll = S.stampAll + 1 S.oamAt = S.stampAll end
        elseif reg == 14 or reg == 15 then flashWrite(a, v % 256)
        elseif reg == 8 then
            local o = a % 16777216
            if o >= 0xC4 and o < 0xCA then gpioWrite(o - o % 2, v) end
        end
    end
    local function wr32(a, v)
        local reg = floor(a / 16777216)
        if reg == 3 then iw[(a % 32768 - a % 4) / 4] = v
        elseif reg == 2 then ew[(a % 262144 - a % 4) / 4] = v
        elseif reg == 14 or reg == 15 then flashWrite(a, v % 256)
        elseif reg >= 4 and reg <= 7 then
            a = a - a % 4
            local lo = v % 65536
            wr16(a, lo)
            wr16(a + 2, (v - lo) / 65536)
        end
    end
    local function wr8(a, v)
        local reg = floor(a / 16777216)
        if reg == 3 then
            local o = a % 32768
            local i, p = (o - o % 4) / 4, P[o % 4]
            local w = iw[i]
            iw[i] = w + (v - floor(w / p) % 256) * p
        elseif reg == 2 then
            local o = a % 262144
            local i, p = (o - o % 4) / 4, P[o % 4]
            local w = ew[i]
            ew[i] = w + (v - floor(w / p) % 256) * p
        elseif reg == 4 then
            local o = a % 16777216
            if o < 0x400 then S.ioWrite8(o, v) end
        elseif reg == 6 then
            local o = a % 131072
            if o >= 98304 then o = o - 32768 end
            -- a byte written to picture memory lands in both halves of the 16-bit cell (bitmap area only keeps it)
            if o < 0x10000 or (S.bitmapMode and o < 0x14000) then
                o = o - o % 2
                vramByte(o, v)
                vramByte(o + 1, v)
            end
        elseif reg == 5 then
            wr16(a - a % 2, v * 257)
        elseif reg == 14 or reg == 15 then flashWrite(a, v)
        elseif reg == 8 then
            local o = a % 16777216
            if o == 0xC4 or o == 0xC6 or o == 0xC8 then gpioWrite(o, v) end
        end
        -- (single bytes written to sprite records are ignored by the hardware)
    end
    -- The serial save chip ("EEPROM"). It sits at the end of the cartridge's addresses (all of 0x0Dxxxxxx on a
    -- cartridge of up to 16 MB, only the last 256 bytes on a bigger one) and passes one bit per 16-bit access:
    --   to read 8 bytes:   the game sends 1 1, an address, 0   and then reads 4 empty bits and 64 bits of data
    --   to write 8 bytes:  the game sends 1 0, an address, 64 bits of data, 0   and then reads until a 1 comes back
    -- The address is 6 bits long on the 512-byte chip and 14 on the 8K one; which it is shows in how many bits were
    -- sent, and that is known the moment the game turns round and reads. Bits go most significant first.
    if S.chip == "eeprom" then
        local eFrom = (romSize > 16777216) and 0x0DFFFF00 or 0x0D000000
        local eBits, eOut = {}, {}
        local function take()                   -- the game has finished sending and now reads: what did it ask?
            local n = eN
            eN, eAt, eLen = 0, 0, 0
            if n < 9 or eBits[1] ~= 1 then return end
            local reading = eBits[2] == 1
            local w = reading and n - 3 or n - 67
            if w ~= 6 and w ~= 14 then return end
            local addr = 0
            for i = 3, 2 + w do addr = addr * 2 + eBits[i] end
            local base = (addr % 1024) * 8
            if reading then
                eOut[1], eOut[2], eOut[3], eOut[4] = 0, 0, 0, 0
                local k = 4
                for b = 0, 7 do
                    local v = flash[base + b]
                    for bit = 7, 0, -1 do
                        k = k + 1
                        eOut[k] = floor(v / POW[bit]) % 2
                    end
                end
                eLen = 68
            else
                local k = 2 + w
                for b = 0, 7 do
                    local v = 0
                    for _ = 1, 8 do k = k + 1 v = v * 2 + eBits[k] end
                    local at = base + b
                    if flash[at] ~= v then
                        flash[at] = v
                        S.flashDirty = true
                        S.flashWrites = S.flashWrites + 1
                        fTouched[(at - at % 4096) / 4096] = true
                    end
                end
            end
        end
        local plainRd16, plainWr16 = rd16, wr16
        rd16 = function(a)
            if a >= eFrom and a < 0x0E000000 then
                if eN > 0 then take() end
                if eAt < eLen then eAt = eAt + 1 return eOut[eAt] end
                return 1                        -- nothing more to say: "ready"
            end
            return plainRd16(a)
        end
        wr16 = function(a, v)
            if a >= eFrom and a < 0x0E000000 then
                if eN < 96 then eN = eN + 1 eBits[eN] = v % 2 end
                return
            end
            return plainWr16(a, v)
        end
        S.eepromFrom = eFrom
    end
    S.rd8, S.rd16, S.rd32, S.wr8, S.wr16, S.wr32 = rd8, rd16, rd32, wr8, wr16, wr32

    -- Many units at once, for the bulk-copy hardware and the built-in copy routines, which between
    -- them move most of what a game moves when it loads a new place. The common cases (into working
    -- memory or picture memory, from the cartridge or working memory, or one value repeated) go
    -- straight to the tables; anything else is refused (false) and done the ordinary way, a unit at
    -- a time. Addresses must already be rounded to the unit, and both ends count upward.
    function S.bulk(src, dst, count, wide, fixed)
        local sreg, dreg = floor(src / 16777216), floor(dst / 16777216)
        local len = count * (wide and 4 or 2)
        if count <= 0 then return true end
        if S.NOBULK then return false end       -- (a testing switch: do everything the ordinary way)
        if fixed and src >= dst and src < dst + len then return false end
        local smem, ssize, s0, rom
        if not fixed then
            if sreg == 2 then smem, ssize, s0 = ew, 262144, src % 262144
            elseif sreg == 3 then smem, ssize, s0 = iw, 32768, src % 32768
            elseif sreg >= 8 and sreg <= 13 then
                rom = src % 33554432
                if rom + len > romSize then return false end
                if S.eepromFrom and src + len > S.eepromFrom then return false end      -- (the serial save chip is not cartridge data)
            else return false end
            if smem and (s0 % 4 ~= 0 or s0 + len > ssize) then return false end
        end
        if dreg == 2 or dreg == 3 then
            local mem, size = ew, 262144
            if dreg == 3 then mem, size = iw, 32768 end
            local d0 = dst % size
            if d0 % 4 ~= 0 or len % 4 ~= 0 or d0 + len > size then return false end
            local di, words = d0 / 4, len / 4
            if fixed then
                local v = wide and rd32(src) or rd16(src) * 65537
                for i = di, di + words - 1 do mem[i] = v end
            elseif smem then
                local si = s0 / 4
                if smem == mem and not wide and si < di + words and di < si + words then return false end
                for i = 0, words - 1 do mem[di + i] = smem[si + i] end
            else
                if rom % 4 ~= 0 then return false end
                local i = di
                for o = rom, rom + len - 4, 4 do
                    local b1, b2, b3, b4 = byte(banks[floor(o / BANK) + 1], o % BANK + 1, o % BANK + 4)
                    mem[i] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
                    i = i + 1
                end
            end
            return true
        elseif dreg == 6 then
            local d0 = dst % 131072
            if d0 % 4 ~= 0 or len % 4 ~= 0 or d0 + len > 98304 then return false end
            local g = S.stampAll + 1
            local changed = false
            if fixed then
                local v = wide and rd32(src) or rd16(src) * 65537
                local b0 = v % 256
                local b1 = floor(v / 256) % 256
                local b2, b3 = floor(v / 65536) % 256, floor(v / 16777216)
                if v == 0 then
                    -- wiping: most of what is wiped is blank already, and the running totals say so at once
                    for o = d0, d0 + len - 4, 4 do
                        if vrow[o / 4] ~= 0 and vramQuad(o, 0, 0, 0, 0, g) then changed = true end
                    end
                else
                    for o = d0, d0 + len - 4, 4 do
                        if vramQuad(o, b0, b1, b2, b3, g) then changed = true end
                    end
                end
            elseif smem then
                local si = s0 / 4
                for o = d0, d0 + len - 4, 4 do
                    local w = smem[si]
                    si = si + 1
                    local b0 = w % 256
                    local r1 = (w - b0) / 256
                    local b1 = r1 % 256
                    local r2 = (r1 - b1) / 256
                    local b2 = r2 % 256
                    if vramQuad(o, b0, b1, b2, (r2 - b2) / 256, g) then changed = true end
                end
            else
                if rom % 4 ~= 0 then return false end
                local o = d0
                for p = rom, rom + len - 4, 4 do
                    local b0, b1, b2, b3 = byte(banks[floor(p / BANK) + 1], p % BANK + 1, p % BANK + 4)
                    if vramQuad(o, b0, b1, b2, b3, g) then changed = true end
                    o = o + 4
                end
            end
            if changed then
                S.stampAll = g
                if d0 < 65536 then S.vramAt = g end
                if d0 + len > 65536 then
                    S.objAt = g
                    if S.io[0] % 8 >= 3 then S.vramAt = g end
                end
            end
            return true
        elseif dreg == 7 and smem then
            -- the sprite records (most games copy the whole list across every frame)
            local d0 = dst % 1024
            if d0 % 4 ~= 0 or len % 4 ~= 0 or d0 + len > 1024 then return false end
            local oi, si, changed = d0 / 2, s0 / 4, false
            for _ = 1, len / 4 do
                local w = smem[si]
                si = si + 1
                local lo = w % 65536
                local hi = (w - lo) / 65536
                if oam[oi] ~= lo then oam[oi] = lo changed = true end
                if oam[oi + 1] ~= hi then oam[oi + 1] = hi changed = true end
                oi = oi + 2
            end
            if changed then
                S.oamStamp = (S.oamStamp or 0) + 1
                S.stampAll = S.stampAll + 1
                S.oamAt = S.stampAll
            end
            return true
        end
        return false
    end
end

-- --------------------------------------------------------------- the processor ---
-- An ARM7TDMI. Numbers are kept as 0..2^32-1 in Lua's doubles.
--
-- Rather than fetch and act on one instruction at a time, a whole stretch of
-- the game's code (up to the next jump it cannot see through) is rewritten
-- once as a Lua function and cached. While a stretch runs, the registers it
-- uses live in Lua locals; the status flags (negative/zero, carry, overflow)
-- are only worked out where something will actually look at them; and a
-- stretch that jumps back to its own start becomes a real Lua loop.
--
-- r[0..15] are the registers; r[16] is the last result (for "zero?" and
-- "negative?"), r[17] carry, r[18] overflow.
local NZ, CF, VF = 1, 2, 4
local COND_READS = { [0] = 1, 1, 2, 2, 1, 1, 4, 4, 3, 3, 5, 5, 5, 5, 0, 0 }
local MAX_STRETCH = 48
local LOOP_BUDGET = 400

local function buildCPU(S)
    local r = zeros(19)
    r[16], r[17], r[18] = 1, false, false
    S.r = r
    local iw, ew = S.iw, S.ew
    local rd8, rd16, rd32, wr8, wr16, wr32 = S.rd8, S.rd16, S.rd32, S.wr8, S.wr16, S.wr32

    -- ---- modes, and the registers each keeps to itself ----
    local mode, irqOff, fiqOff = 0x1F, true, true
    local bankSP, bankLR, spsr = { 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0 }
    local fiqHi, usrHi = { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }      -- r8-r12, for the one mode that has its own
    local BANK = { [0x10] = 1, [0x1F] = 1, [0x11] = 2, [0x12] = 3, [0x13] = 4, [0x17] = 5, [0x1B] = 6 }
    local function setMode(new)
        if new == mode then return end
        local ob, nb = BANK[mode] or 1, BANK[new] or 1
        if ob ~= nb then
            bankSP[ob], bankLR[ob] = r[13], r[14]
            r[13], r[14] = bankSP[nb], bankLR[nb]
            if ob == 2 then for i = 1, 5 do fiqHi[i] = r[7 + i] r[7 + i] = usrHi[i] end
            elseif nb == 2 then for i = 1, 5 do usrHi[i] = r[7 + i] r[7 + i] = fiqHi[i] end end
        end
        mode = new
    end
    local function getCPSR(t)
        local nz = r[16]
        return ((nz >= HALF) and 2147483648 or 0) + ((nz == 0) and 1073741824 or 0) + (r[17] and 536870912 or 0)
            + (r[18] and 268435456 or 0) + (irqOff and 128 or 0) + (fiqOff and 64 or 0) + t + mode
    end
    local function setFlags(v)
        local n, z = v >= HALF, floor(v / 1073741824) % 2 == 1
        r[16] = z and 0 or (n and HALF or 1)
        r[17] = floor(v / 536870912) % 2 == 1
        r[18] = floor(v / 268435456) % 2 == 1
    end
    local function setControl(v)
        irqOff = floor(v / 128) % 2 == 1
        fiqOff = floor(v / 64) % 2 == 1
        setMode(v % 32)
        S.stopAt = 0                    -- interrupts may have just been let in: look again
    end
    -- values of r13/r14 as the plain "user" mode sees them (for the block-transfer instructions that ask)
    local function getUsr(k, now)
        local b = BANK[mode] or 1
        if k < 13 then
            if b == 2 then return usrHi[k - 7] end
            return now
        end
        if b == 1 then return now end
        if k == 13 then return bankSP[1] end
        return bankLR[1]
    end
    local function setUsr(k, v, now)
        local b = BANK[mode] or 1
        if k < 13 then
            if b == 2 then usrHi[k - 7] = v return now end
            return v
        end
        if b == 1 then return v end
        if k == 13 then bankSP[1] = v else bankLR[1] = v end
        return now
    end
    local function getSPSR()
        local b = BANK[mode] or 1
        if b == 1 then return getCPSR(0) end
        return spsr[b]
    end
    -- msr: write the flag byte and/or the control byte of the current or saved status
    local function setPSR(saved, v, flagsToo, controlToo, t)
        if saved then
            local b = BANK[mode] or 1
            if b == 1 then return end
            local old = spsr[b]
            local lowOld, lowNew = old % 256, v % 256
            local hiOld, hiNew = floor(old / 16777216), floor(v / 16777216)
            spsr[b] = (flagsToo and hiNew or hiOld) * 16777216 + (controlToo and lowNew or lowOld)
            return
        end
        if flagsToo then setFlags(v) end
        if controlToo and mode ~= 0x10 then setControl(v % 256) end
    end
    -- "return from exception": the saved status comes back, and with it the mode and instruction set
    local setBiosBus = S.setBiosBus
    local function retSPSR(target)
        if mode == 0x12 then setBiosBus(0xE25EF004) end     -- (the end of the built-in interrupt routine)
        local b = BANK[mode] or 1
        local v = (b == 1) and getCPSR(0) or spsr[b]
        setFlags(v)
        setControl(v % 256)
        if floor(v / 32) % 2 == 1 then return target - target % 2 + 1 end
        return target - target % 4
    end

    -- ---- arithmetic helpers ----
    local function mul(a, b)
        local bl = b % 65536
        return (a * bl + (a * ((b - bl) / 65536)) % 65536 * 65536) % W
    end
    local function umull(a, b)          -- -> low word, high word
        local al, bl = a % 65536, b % 65536
        local ah, bh = (a - al) / 65536, (b - bl) / 65536
        local ll, lh, hl, hh = al * bl, al * bh, ah * bl, ah * bh
        local mid = lh + hl + floor(ll / 65536)         -- < 2^34
        local lo = (mid % 65536) * 65536 + ll % 65536
        local hi = hh + floor(mid / 65536)
        return lo, hi % W
    end
    local function smull(a, b)
        local lo, hi = umull(a, b)
        if a >= HALF then hi = hi - b end
        if b >= HALF then hi = hi - a end
        return lo, hi % W
    end
    local function add64(lo, hi, lo2, hi2)
        lo = lo + lo2
        if lo >= W then lo = lo - W hi = hi + 1 end
        return lo, (hi + hi2) % W
    end
    local function lslr(v, n, c)
        if n == 0 then return v, c elseif n < 32 then return (v * POW[n]) % W, floor(v / POW[32 - n]) % 2 == 1
        elseif n == 32 then return 0, v % 2 == 1 end
        return 0, false
    end
    local function lsrr(v, n, c)
        if n == 0 then return v, c elseif n < 32 then return floor(v / POW[n]), floor(v / POW[n - 1]) % 2 == 1
        elseif n == 32 then return 0, v >= HALF end
        return 0, false
    end
    local function asrr(v, n, c)
        if n == 0 then return v, c
        elseif n < 32 then
            local cc = floor(v / POW[n - 1]) % 2 == 1
            if v >= HALF then return floor(v / POW[n]) + (W - POW[32 - n]), cc end
            return floor(v / POW[n]), cc
        end
        if v >= HALF then return 4294967295, true end
        return 0, false
    end
    local function rorr(v, n, c)
        if n == 0 then return v, c end
        n = n % 32
        if n ~= 0 then v = floor(v / POW[n]) + (v % POW[n]) * POW[32 - n] end
        return v, v >= HALF
    end
    local SHIFT_FN = { [0] = "lslr", "lsrr", "asrr", "rorr" }

    local function swi(n, nextKey, selfKey) setBiosBus(0xE3A02004) return S.bios(n, nextKey, selfKey) end
    local function undefined(at, op)
        local function hex(v) return ("%04X%04X"):format(floor(v / 65536) % 65536, v % 65536) end
        error("MekkaBoy Advance: instruction " .. hex(op) .. " at " .. hex(at) .. " is not one this processor has")
    end

    -- ---- reading instructions ----
    local function bits(v, lo, n) return floor(v / POW[lo]) % POW[n] end
    local function costOf(at, thumb)
        local reg = floor(at / 16777216)
        if reg == 3 or reg == 0 then return 1 end
        if reg == 2 then return thumb and 3 or 6 end
        return thumb and 2 or 4
    end
    local decodeCache = {}              -- ROM never changes, so what an address holds can be remembered

    local function decodeThumb(at)
        local op = rd16(at)
        local d = { at = at, op = op, len = 2, cond = 14, rf = 0, wf = 0, thumb = true, cyc = costOf(at, true) }
        local top = floor(op / 256)
        local rd3, rs3 = op % 8, floor(op / 8) % 8
        if top < 0x18 then                              -- shift by a fixed amount: a "move" with a shifted source
            d.k, d.op2, d.S, d.rd = "dp", 13, true, rd3
            local st = floor(op / 2048) % 4
            local n = floor(op / 64) % 32
            d.sh = { kind = "reg", rm = rs3, st = st, n = n }
            d.wf = (st == 0 and n == 0) and NZ or (NZ + CF)
        elseif top < 0x20 then
            local kind = floor(op / 512) % 4
            d.k, d.op2, d.S, d.rd, d.rn = "dp", (kind % 2 == 0) and 4 or 2, true, rd3, rs3
            local x = floor(op / 64) % 8
            if kind >= 2 then d.sh = { kind = "imm", value = x } else d.sh = { kind = "reg", rm = x, st = 0, n = 0 } end
            d.wf = 7
        elseif top < 0x40 then
            local kind = floor(op / 2048) % 4
            local rd = floor(op / 256) % 8
            d.k, d.S, d.rd = "dp", true, rd
            d.sh = { kind = "imm", value = op % 256 }
            if kind == 0 then d.op2, d.wf = 13, NZ
            elseif kind == 1 then d.op2, d.rn, d.wf = 10, rd, 7
            elseif kind == 2 then d.op2, d.rn, d.wf = 4, rd, 7
            else d.op2, d.rn, d.wf = 2, rd, 7 end
        elseif top < 0x44 then
            local kind = floor(op / 64) % 16
            d.S, d.rd = true, rd3
            if kind == 2 or kind == 3 or kind == 4 or kind == 7 then
                d.k, d.op2 = "dp", 13
                d.sh = { kind = "regreg", rm = rd3, st = (kind == 7) and 3 or (kind - 2), rs = rs3 }
                d.rf, d.wf = CF, NZ + CF
                d.cyc = d.cyc + 1
            elseif kind == 13 then
                d.k, d.rm, d.rs, d.wf = "mul", rd3, rs3, NZ
                d.cyc = d.cyc + 2
            elseif kind == 9 then                       -- negate: 0 - source
                d.k, d.op2, d.rn, d.wf = "dp", 3, rs3, 7
                d.sh = { kind = "imm", value = 0 }
            else
                local map = { [0] = 0, 1, nil, nil, nil, 5, 6, nil, 8, nil, 10, 11, 12, nil, 14, 15 }
                d.k, d.op2 = "dp", map[kind]
                d.sh = { kind = "reg", rm = rs3, st = 0, n = 0 }
                if kind ~= 15 then d.rn = rd3 end
                if kind == 5 or kind == 6 then d.rf, d.wf = CF, 7
                elseif kind == 10 or kind == 11 then d.wf = 7
                else d.wf = NZ end
            end
        elseif top < 0x48 then
            local kind = floor(op / 256) % 4
            local rd = op % 8 + floor(op / 128) % 2 * 8
            local rm = floor(op / 8) % 16
            if kind == 3 then d.k, d.rm, d.term, d.exits = "bx", rm, true, true
            else
                d.k, d.rd = "dp", rd
                d.sh = { kind = "reg", rm = rm, st = 0, n = 0 }
                if kind == 0 then d.op2, d.rn = 4, rd
                elseif kind == 1 then d.op2, d.rn, d.S, d.wf = 10, rd, true, 7
                else d.op2 = 13 end
                if rd == 15 and kind ~= 1 then d.term, d.exits = true, true end
            end
        elseif top < 0x50 then
            d.k, d.load, d.size, d.rd, d.rn, d.P, d.U = "mem", true, 4, floor(op / 256) % 8, 15, true, true
            d.imm = op % 256 * 4
            d.pcval = at + 4 - (at + 4) % 4
            d.cyc = d.cyc + 2
        elseif top < 0x60 then
            local kind = floor(op / 512) % 8
            d.k, d.rd, d.rn, d.P, d.U = "mem", rd3, rs3, true, true
            d.sh = { kind = "reg", rm = floor(op / 64) % 8, st = 0, n = 0 }
            if kind == 0 then d.size = 4 elseif kind == 1 then d.size = 2 elseif kind == 2 then d.size = 1
            elseif kind == 3 then d.load, d.size, d.signed = true, 1, true
            elseif kind == 4 then d.load, d.size = true, 4
            elseif kind == 5 then d.load, d.size = true, 2
            elseif kind == 6 then d.load, d.size = true, 1
            else d.load, d.size, d.signed = true, 2, true end
            d.cyc = d.cyc + (d.load and 2 or 1)
        elseif top < 0x80 then
            local isByte, load = floor(op / 4096) % 2 == 1, floor(op / 2048) % 2 == 1
            d.k, d.rd, d.rn, d.P, d.U, d.load = "mem", rd3, rs3, true, true, load
            d.size = isByte and 1 or 4
            d.imm = floor(op / 64) % 32 * (isByte and 1 or 4)
            d.cyc = d.cyc + (load and 2 or 1)
        elseif top < 0x90 then
            local load = floor(op / 2048) % 2 == 1
            d.k, d.rd, d.rn, d.P, d.U, d.load, d.size = "mem", rd3, rs3, true, true, load, 2
            d.imm = floor(op / 64) % 32 * 2
            d.cyc = d.cyc + (load and 2 or 1)
        elseif top < 0xA0 then
            local load = floor(op / 2048) % 2 == 1
            d.k, d.rd, d.rn, d.P, d.U, d.load, d.size = "mem", floor(op / 256) % 8, 13, true, true, load, 4
            d.imm = op % 256 * 4
            d.cyc = d.cyc + (load and 2 or 1)
        elseif top < 0xB0 then
            d.k, d.op2, d.rd = "dp", 4, floor(op / 256) % 8
            d.sh = { kind = "imm", value = op % 256 * 4 }
            if floor(op / 2048) % 2 == 0 then d.rn, d.pcval = 15, at + 4 - (at + 4) % 4 else d.rn = 13 end
        elseif top == 0xB0 then
            d.k, d.rd, d.rn = "dp", 13, 13
            d.op2 = (op % 256 >= 128) and 2 or 4
            d.sh = { kind = "imm", value = op % 128 * 4 }
        elseif top == 0xB4 or top == 0xB5 or top == 0xBC or top == 0xBD then
            local list = {}
            for b = 0, 7 do if floor(op / POW[b]) % 2 == 1 then list[#list + 1] = b end end
            d.k, d.rn, d.Wb, d.list = "block", 13, true, list
            if top < 0xB8 then
                if top == 0xB5 then list[#list + 1] = 14 end
                d.load, d.P, d.U = false, true, false
            else
                if top == 0xBD then list[#list + 1] = 15 d.term, d.exits = true, true end
                d.load, d.P, d.U = true, false, true
            end
            d.cyc = d.cyc + #list + 1
        elseif top >= 0xC0 and top < 0xD0 then
            local list = {}
            for b = 0, 7 do if floor(op / POW[b]) % 2 == 1 then list[#list + 1] = b end end
            d.k, d.rn, d.Wb, d.list, d.P, d.U = "block", floor(op / 256) % 8, true, list, false, true
            d.load = floor(op / 2048) % 2 == 1
            d.cyc = d.cyc + #list + 1
        elseif top >= 0xD0 and top < 0xDE then
            local o = op % 256
            if o >= 128 then o = o - 256 end
            d.k, d.cond, d.target = "b", top - 0xD0, at + 4 + o * 2 + 1
            d.rf = COND_READS[d.cond]
        elseif top == 0xDF then
            d.k, d.n, d.term, d.exits = "swi", op % 256, true, true
        elseif top >= 0xE0 and top < 0xE8 then
            local o = op % 2048
            if o >= 1024 then o = o - 2048 end
            d.k, d.target, d.term = "b", at + 4 + o * 2 + 1, true
        elseif top >= 0xF0 and top < 0xF8 then
            local o = op % 2048
            if o >= 1024 then o = o - 2048 end
            local op2 = rd16(at + 2)
            d.k, d.len, d.term, d.link = "b", 4, true, at + 4 + 1
            d.target = (at + 4 + o * 4096 + op2 % 2048 * 2) % W + 1
            d.cyc = d.cyc * 2
        else
            d.k, d.term, d.exits = "bad", true, true
        end
        return d
    end

    local function armShifter(op)
        local rm, st = op % 16, floor(op / 32) % 4
        if floor(op / 16) % 2 == 1 then return { kind = "regreg", rm = rm, st = st, rs = floor(op / 256) % 16 } end
        return { kind = "reg", rm = rm, st = st, n = floor(op / 128) % 32 }
    end
    local function shifterFlags(sh)     -- -> flags it reads, whether it produces a carry
        if sh.kind == "imm" then return 0, sh.carry ~= nil end
        if sh.kind == "regreg" then return CF, true end
        if sh.st == 0 and sh.n == 0 then return 0, false end
        if sh.st == 3 and sh.n == 0 then return CF, true end
        return 0, true
    end

    local function decodeArm(at)
        local op = rd32(at)
        local cond = floor(op / 268435456)
        local d = { at = at, op = op, len = 4, cond = cond, rf = COND_READS[cond], wf = 0, cyc = costOf(at, false) }
        local always = cond == 14
        local c27 = floor(op / 33554432) % 8            -- bits 27-25
        local rn, rd = floor(op / 65536) % 16, floor(op / 4096) % 16
        if cond == 15 then
            d.k, d.term, d.exits, d.cond, d.rf = "bad", true, true, 14, 0
        elseif op % 268435456 - op % 16 == 0x012FFF10 then
            d.k, d.rm, d.exits, d.term = "bx", op % 16, true, always
        elseif c27 == 5 then
            local o = op % 16777216
            if o >= 8388608 then o = o - 16777216 end
            d.k, d.target, d.term = "b", (at + 8 + o * 4) % W, always
            if floor(op / 16777216) % 2 == 1 then d.link = at + 4 end
        elseif floor(op / 16777216) % 16 == 15 then
            d.k, d.n, d.exits, d.term = "swi", floor(op / 65536) % 256, true, always
        elseif c27 == 2 or c27 == 3 then                -- load or store a word or byte
            d.k, d.rn, d.rd = "mem", rn, rd
            d.P, d.U, d.Wb, d.load = bits(op, 24, 1) == 1, bits(op, 23, 1) == 1, bits(op, 21, 1) == 1, bits(op, 20, 1) == 1
            d.size = (bits(op, 22, 1) == 1) and 1 or 4
            if c27 == 3 then
                d.sh = armShifter(op)
                if shifterFlags(d.sh) == CF and d.rf % 4 < 2 then d.rf = d.rf + CF end
            else d.imm = op % 4096 end
            if rn == 15 then d.pcval = at + 8 end
            if d.load and rd == 15 then d.exits, d.term = true, always end
            d.cyc = d.cyc + (d.load and 2 or 1)
        elseif c27 == 4 then                            -- load or store a run of registers
            local list = {}
            for b = 0, 15 do if floor(op / POW[b]) % 2 == 1 then list[#list + 1] = b end end
            d.k, d.rn, d.list = "block", rn, list
            d.P, d.U, d.Sbit, d.Wb, d.load = bits(op, 24, 1) == 1, bits(op, 23, 1) == 1, bits(op, 22, 1) == 1, bits(op, 21, 1) == 1, bits(op, 20, 1) == 1
            if d.load and (list[#list] == 15 or #list == 0) then d.exits, d.term = true, always end
            d.cyc = d.cyc + #list + 1
        elseif c27 == 0 and bits(op, 4, 4) == 9 and bits(op, 22, 6) == 0 then
            d.k, d.rd, d.rm, d.rs, d.S = "mul", rn, op % 16, bits(op, 8, 4), bits(op, 20, 1) == 1
            if bits(op, 21, 1) == 1 then d.acc = rd end
            if d.S then d.wf = NZ end
            d.cyc = d.cyc + 2
        elseif c27 == 0 and bits(op, 4, 4) == 9 and bits(op, 23, 5) == 1 then
            d.k, d.rdhi, d.rdlo, d.rm, d.rs = "mull", rn, rd, op % 16, bits(op, 8, 4)
            d.signed, d.accum, d.S = bits(op, 22, 1) == 1, bits(op, 21, 1) == 1, bits(op, 20, 1) == 1
            if d.S then d.wf = NZ end
            d.cyc = d.cyc + 3
        elseif c27 == 0 and bits(op, 4, 8) == 9 and bits(op, 23, 5) == 2 and bits(op, 20, 2) == 0 then
            d.k, d.rn, d.rd, d.rm, d.size = "swp", rn, rd, op % 16, (bits(op, 22, 1) == 1) and 1 or 4
            d.cyc = d.cyc + 3
        elseif c27 == 0 and bits(op, 7, 1) == 1 and bits(op, 4, 1) == 1 and bits(op, 5, 2) ~= 0 then
            -- 16-bit and signed loads and stores
            local sh = bits(op, 5, 2)
            d.k, d.rn, d.rd = "mem", rn, rd
            d.P, d.U, d.Wb, d.load = bits(op, 24, 1) == 1, bits(op, 23, 1) == 1, bits(op, 21, 1) == 1, bits(op, 20, 1) == 1
            if bits(op, 22, 1) == 1 then d.imm = bits(op, 8, 4) * 16 + op % 16
            else d.sh = { kind = "reg", rm = op % 16, st = 0, n = 0 } end
            if sh == 1 then d.size = 2 elseif sh == 2 then d.size, d.signed = 1, true else d.size, d.signed = 2, true end
            if rn == 15 then d.pcval = at + 8 end
            d.cyc = d.cyc + (d.load and 2 or 1)
        elseif c27 == 0 and bits(op, 23, 2) == 2 and bits(op, 20, 2) == 0 and bits(op, 0, 12) == 0 and bits(op, 16, 4) == 15 then
            d.k, d.rd, d.saved = "mrs", rd, bits(op, 22, 1) == 1
            d.rf = 7
        elseif (c27 == 0 or c27 == 1) and bits(op, 23, 2) == 2 and bits(op, 20, 2) == 2 and rd == 15 then
            d.k, d.saved = "msr", bits(op, 22, 1) == 1
            d.flagsToo, d.controlToo = bits(op, 19, 1) == 1, bits(op, 16, 1) == 1
            if c27 == 1 then
                local rot, v = bits(op, 8, 4) * 2, op % 256
                if rot ~= 0 then v = floor(v / POW[rot]) + (v % POW[rot]) * POW[32 - rot] end
                d.value = v
            else d.rm = op % 16 end
            if not d.saved then
                d.exits, d.term = true, always
                if d.flagsToo and always then d.wf = 0 end
            end
        elseif c27 == 0 or c27 == 1 then                -- data processing
            local opc = bits(op, 21, 4)
            d.k, d.op2, d.S, d.rd = "dp", opc, bits(op, 20, 1) == 1, rd
            if opc ~= 13 and opc ~= 15 then d.rn = rn end
            if c27 == 1 then
                local rot, v = bits(op, 8, 4) * 2, op % 256
                if rot ~= 0 then v = floor(v / POW[rot]) + (v % POW[rot]) * POW[32 - rot] end
                d.sh = { kind = "imm", value = v }
                if rot ~= 0 then d.sh.carry = (v >= HALF) and 1 or 0 end
            else d.sh = armShifter(op) end
            if rn == 15 then d.pcval = at + 8 end
            local sReads, sCarry = shifterFlags(d.sh)
            local reads = d.rf
            local function also(f) if reads % (f * 2) < f then reads = reads + f end end
            if sReads == CF then also(CF) end
            if opc == 5 or opc == 6 or opc == 7 then also(CF) end
            d.rf = reads
            local logical = opc == 0 or opc == 1 or opc == 8 or opc == 9 or opc >= 12
            if d.S and not (rd == 15 and (opc < 8 or opc >= 12)) then
                if logical then d.wf = NZ + (sCarry and CF or 0) else d.wf = 7 end
            end
            if rd == 15 and (opc < 8 or opc >= 12) then d.exits, d.term = true, always end
            -- (a compare whose "destination" is the program counter brings the saved status back: an oddity, but a real one)
            if rd == 15 and opc >= 8 and opc < 12 and d.S then d.psrBack, d.exits, d.term, d.wf = true, true, always, 0 end
            if d.sh.kind == "regreg" then d.cyc = d.cyc + 1 end
        else
            d.k, d.term, d.exits = "bad", always, true
        end
        return d
    end

    local function decode(key)
        local d = decodeCache[key]
        if d then return d end
        if key % 2 == 1 then d = decodeThumb(key - 1) else d = decodeArm(key) end
        if key >= 134217728 then decodeCache[key] = d end
        return d
    end

    local function has(set, f) return set % (f * 2) >= f end
    -- (sets of the three flag groups are numbers 0-7; these tables combine two of them)
    local UNION, BOTH, WITHOUT = {}, {}, {}
    for a = 0, 7 do
        UNION[a], BOTH[a], WITHOUT[a] = {}, {}, {}
        for b = 0, 7 do
            local u, i = 0, 0
            for _, f in ipairs({ 1, 2, 4 }) do
                local ina, inb = a % (f * 2) >= f, b % (f * 2) >= f
                if ina or inb then u = u + f end
                if ina and inb then i = i + f end
            end
            UNION[a][b], BOTH[a][b], WITHOUT[a][b] = u, i, a - i
        end
    end
    local function union(a, b) return UNION[a][b] end

    -- which flags might still be wanted by the code at `key`? (anything unsure counts as wanted)
    local wanted
    local function wanted1(key, depth)
        local killed, want = 0, 0
        for _ = 1, 12 do
            local d = decode(key)
            want = UNION[want][WITHOUT[d.rf][killed]]
            if d.k == "b" then
                if depth <= 0 then return 7 end
                if d.cond ~= 14 then want = UNION[want][WITHOUT[wanted(d.target, depth - 1)][killed]]
                else
                    depth = depth - 1
                    key = d.target - d.len
                end
            elseif d.exits then
                want = UNION[want][WITHOUT[7][killed]]
                if d.cond == 14 then return want end
            end
            if d.cond == 14 then killed = UNION[killed][d.wf] end
            if killed == 7 or want == 7 then return want end
            key = key + d.len
        end
        return 7
    end
    local wantedMemo = {}                   -- (the cartridge never changes, so neither do these answers)
    wanted = function(key, depth)
        if key < 134217728 and key >= 16384 then return 7 end      -- code in working memory can change under us
        local m = key * 4 + depth
        local w = wantedMemo[m]
        if not w then
            w = wanted1(key, depth)
            if key >= 134217728 then wantedMemo[m] = w end
        end
        return w
    end

    -- ---- the translator ----
    local blocks, made = {}, 0
    S.blocks = blocks
    local CHUNK_ARGS = "local r, iw, ew, rd8, rd16, rd32, wr8, wr16, wr32, band, bor, bxor, mul, umull, smull, add64, floor, lslr, lsrr, asrr, rorr, "
        .. "swi, getCPSR, getSPSR, setPSR, retSPSR, getUsr, setUsr, undefined = ..."

    local function compile(start)
        local thumb = start % 2 == 1
        local tbit = thumb and 32 or 0
        -- 1. gather the stretch
        local ins, key = {}, start
        local limit = thumb and MAX_STRETCH or 32
        while #ins < limit do
            local d0 = decode(key)
            local d = {}
            for k, v in pairs(d0) do d[k] = v end       -- our own copy: notes get scribbled on it
            ins[#ins + 1] = d
            if d.term then break end
            key = key + d.len
        end
        local n = #ins
        local fallKey = ins[n].at + ins[n].len + (thumb and 1 or 0)
        local inRam = start < 134217728 and start >= 16384

        -- 2. a compare followed by something conditional: test the compared numbers directly
        local lastWriter
        for i = 1, n do
            local d = ins[i]
            local c = d.cond
            d.rfHere = d.rf
            if c ~= 14 and c ~= 4 and c ~= 5 and c ~= 6 and c ~= 7 and lastWriter and lastWriter.cmp and not S.NOFUSE then
                d.fused = lastWriter
                lastWriter.keep = true
                -- the condition no longer reads flags (anything else the instruction reads still counts)
                local rest = 0
                if d.k == "dp" then
                    local sReads = shifterFlags(d.sh)
                    if sReads == CF or d.op2 == 5 or d.op2 == 6 or d.op2 == 7 then rest = CF end
                elseif d.k == "mem" and d.sh and shifterFlags(d.sh) == CF then rest = CF
                elseif d.k == "mrs" then rest = 7 end
                d.rfHere = rest
            end
            if d.wf ~= 0 then
                lastWriter = d
                d.cmp = d.k == "dp" and d.S and d.cond == 14 and (d.op2 == 2 or d.op2 == 3 or d.op2 == 10) and d.wf == 7
            end
        end

        -- 3. which flag results does anyone need? (walking backwards)
        local live
        if not ins[n].term then live = wanted(fallKey, 2) else live = 0 end
        for i = n, 1, -1 do
            local d = ins[i]
            if d.k == "b" then
                local w2 = wanted(d.target, 2)
                if d.cond == 14 then live = w2 else live = union(live, w2) end
            elseif d.exits then
                if d.cond == 14 then live = 7 else live = union(live, 7) end
            end
            local need = BOTH[d.wf][live]
            if d.cond == 14 then live = live - need end
            d.need = S.ALLFLAGS and d.wf or need
            live = union(live, d.rfHere)
        end

        -- 4. write the Lua
        local out, used, defd = {}, {}, {}
        local flagUsed, flagSet = {}, {}
        local function emit(s) out[#out + 1] = s end
        local function R(k, d)              -- the value of register k, as this instruction sees it
            if k == 15 then return tostring(d.pcval or (d.at + (thumb and 4 or 8))) end
            used[k] = true
            return "R" .. k
        end
        local function D(k) used[k] = true defd[k] = true return "R" .. k end
        local looping = false
        if not S.NOLOOP then
            for i = 1, n do if ins[i].k == "b" and ins[i].target == start and not ins[i].link then looping = true end end
        end
        -- A loop that only looks at memory and compares, changing nothing it reads on the next turn, is a game
        -- waiting for something (usually the next frame). Nothing can change until the next interrupt, so
        -- rather than spin, such a stretch reports "I am only waiting" and the clock is moved on.
        local waitingLoop = false
        if looping and not S.NOIDLE then
            waitingLoop = true
            local anywhere, written, flagsSet = {}, {}, 0
            local body = 0              -- the loop proper ends at the last jump back; what follows is the way out
            for i = 1, n do if ins[i].k == "b" and ins[i].target == start and not ins[i].link then body = i end end
            for i = 1, body do
                local d = ins[i]
                if d.k == "dp" and not d.exits and d.rd ~= 15 then
                    if d.op2 < 8 or d.op2 >= 12 then anywhere[d.rd] = true end
                elseif d.k == "mem" and d.load and d.P and not d.Wb and d.rd ~= 15 then anywhere[d.rd] = true
                elseif d.k == "b" and not d.link then
                else waitingLoop = false end
            end
            for i = 1, body do
                if not waitingLoop then break end
                local d = ins[i]
                for _, f in ipairs({ NZ, CF, VF }) do
                    if has(d.rf, f) and not has(flagsSet, f) then waitingLoop = false end
                end
                local function reads(k) if k and k ~= 15 and anywhere[k] and not written[k] then waitingLoop = false end end
                if d.k == "dp" or d.k == "mem" then
                    reads(d.rn)
                    if d.sh then reads(d.sh.rm) reads(d.sh.rs) end
                    if d.cond ~= 14 then waitingLoop = false end
                    if d.k == "mem" or d.op2 < 8 or d.op2 >= 12 then written[d.rd] = true end
                    flagsSet = union(flagsSet, d.wf)
                end
            end
        end
        -- If such a loop looks at just one place, and that place is ordinary memory (not a hardware
        -- register), then only an interrupt can end the wait, and the stretch says so (its third answer
        -- is 2): the scheduler then need not even ask again until an interrupt has been taken.
        local waitAnswer = "true"
        if waitingLoop then
            local loads, body = 0, 0
            for i = 1, n do if ins[i].k == "b" and ins[i].target == start and not ins[i].link then body = i end end
            for i = 1, body do if ins[i].k == "mem" and ins[i].rn ~= 15 then loads = loads + 1 end end
            if loads == 1 then waitAnswer = "(a and a >= 33554432 and a < 67108864) and 2 or true" end
        end
        local function leave(target, cycles)
            return ("@WB@ do return %s, %s end"):format(tostring(target), looping and ("c + " .. cycles) or tostring(cycles))
        end
        local function setNZ(d, expr) if has(d.need, NZ) then flagSet.nz = true emit("nz = " .. expr) end end
        -- what is on the bus while instruction d runs: the one fetched ahead (in Thumb, twice over). Written
        -- into the stretch as ", number", to follow the address in a read; nothing for the built-in program.
        local function busOf(d)
            if d.at < 16384 then return "" end
            if thumb then return ", " .. tostring(rd16(d.at + 4) * 65537) end
            return ", " .. tostring(rd32(d.at + 8))
        end
        local function load32a(dst, d)      -- the address is in `a`
            local ob = busOf(d)
            emit(("if a >= 50331648 then if a < 67108864 then %s = iw[(a %% 32768 - a %% 4) / 4] else %s = rd32(a%s) end "
                .. "elseif a >= 33554432 then %s = ew[(a %% 262144 - a %% 4) / 4] else %s = rd32(a%s) end"):format(dst, dst, ob, dst, dst, ob))
        end
        local function store32a(val)
            emit(("if a >= 50331648 then if a < 67108864 then iw[(a %% 32768 - a %% 4) / 4] = %s else wr32(a, %s) end "
                .. "elseif a >= 33554432 and a < 50331648 then ew[(a %% 262144 - a %% 4) / 4] = %s else wr32(a, %s) end"):format(val, val, val, val))
        end
        local function addFlags(d, A, B)    -- t = A + B (+carry) has been computed, unwrapped
            if has(d.need, CF) then flagSet.cf = true emit("cf = t >= 4294967296") end
            emit("if t >= 4294967296 then t = t - 4294967296 end")
            if has(d.need, VF) then flagSet.vf = true emit(("vf = ((%s < 2147483648) == (%s < 2147483648)) and ((t < 2147483648) ~= (%s < 2147483648))"):format(A, B, A)) end
            setNZ(d, "t")
        end
        local function subFlags(d, A, B)    -- t = A - B (-borrow) has been computed, unwrapped
            if has(d.need, CF) then flagSet.cf = true emit("cf = t >= 0") end
            emit("if t < 0 then t = t + 4294967296 end")
            if has(d.need, VF) then flagSet.vf = true emit(("vf = ((%s < 2147483648) ~= (%s < 2147483648)) and ((t < 2147483648) ~= (%s < 2147483648))"):format(A, B, A)) end
            setNZ(d, "t")
        end
        local function condition(d)
            local c = d.cond
            if d.fused then
                local sa, sb = "(ca + 2147483648) % 4294967296", "(cb + 2147483648) % 4294967296"
                if c == 0 then return "ca == cb" elseif c == 1 then return "ca ~= cb"
                elseif c == 2 then return "ca >= cb" elseif c == 3 then return "ca < cb"
                elseif c == 8 then return "ca > cb" elseif c == 9 then return "ca <= cb"
                elseif c == 10 then return sa .. " >= " .. sb elseif c == 11 then return sa .. " < " .. sb
                elseif c == 12 then return sa .. " > " .. sb else return sa .. " <= " .. sb end
            end
            local reads = COND_READS[c]
            if has(reads, NZ) then flagUsed.nz = true end
            if has(reads, CF) then flagUsed.cf = true end
            if has(reads, VF) then flagUsed.vf = true end
            if c == 0 then return "nz == 0" elseif c == 1 then return "nz ~= 0"
            elseif c == 2 then return "cf" elseif c == 3 then return "not cf"
            elseif c == 4 then return "nz >= 2147483648" elseif c == 5 then return "nz < 2147483648"
            elseif c == 6 then return "vf" elseif c == 7 then return "not vf"
            elseif c == 8 then return "(cf and nz ~= 0)" elseif c == 9 then return "(not cf or nz == 0)"
            elseif c == 10 then return "((nz >= 2147483648) == vf)" elseif c == 11 then return "((nz >= 2147483648) ~= vf)"
            elseif c == 12 then return "(nz ~= 0 and (nz >= 2147483648) == vf)" else return "(nz == 0 or (nz >= 2147483648) ~= vf)" end
        end
        -- the second operand: emits what is needed and returns an expression for the value,
        -- and whether a carry-out was left in `sc`
        local function shifter(d, wantCarry)
            local sh = d.sh
            if sh.kind == "imm" then
                if wantCarry and sh.carry ~= nil then emit("sc = " .. (sh.carry == 1 and "true" or "false")) return tostring(sh.value), true end
                return tostring(sh.value), false
            elseif sh.kind == "regreg" then
                flagUsed.cf = true
                local m = R(sh.rm, d)
                if sh.rm == 15 then m = tostring(d.at + 12) end
                emit(("s, sc = %s(%s, %s %% 256, cf)"):format(SHIFT_FN[sh.st], m, R(sh.rs, d)))
                return "s", true
            end
            local m, st, k = R(sh.rm, d), sh.st, sh.n
            if st == 0 then
                if k == 0 then return m, false end
                if wantCarry then emit(("sc = floor(%s / %s) %% 2 == 1"):format(m, POW[32 - k])) end
                emit(("s = (%s * %s) %% 4294967296"):format(m, POW[k]))
            elseif st == 1 then
                if k == 0 then
                    if wantCarry then emit(("sc = %s >= 2147483648"):format(m)) end
                    return "0", true
                end
                if wantCarry then emit(("sc = floor(%s / %s) %% 2 == 1"):format(m, POW[k - 1])) end
                emit(("s = floor(%s / %s)"):format(m, POW[k]))
            elseif st == 2 then
                if k == 0 then
                    if wantCarry then emit(("sc = %s >= 2147483648"):format(m)) end
                    emit(("if %s >= 2147483648 then s = 4294967295 else s = 0 end"):format(m))
                else
                    if wantCarry then emit(("sc = floor(%s / %s) %% 2 == 1"):format(m, POW[k - 1])) end
                    emit(("if %s >= 2147483648 then s = floor(%s / %s) + %s else s = floor(%s / %s) end"):format(
                        m, m, POW[k], W - POW[32 - k], m, POW[k]))
                end
            else
                if k == 0 then                      -- through the carry
                    flagUsed.cf = true
                    if wantCarry then emit(("sc = %s %% 2 == 1"):format(m)) end
                    emit(("s = (cf and 2147483648 or 0) + floor(%s / 2)"):format(m))
                else
                    emit(("s = floor(%s / %s) + (%s %% %s) * %s"):format(m, POW[k], m, POW[k], POW[32 - k]))
                    if wantCarry then emit("sc = s >= 2147483648") end
                end
            end
            return "s", true
        end

        local cycles = 0
        local gen = {}

        -- jump to a worked-out address held in `t`
        local function jumpT(d, kind)
            if kind == "exchange" then emit("if t % 2 == 0 then t = t - t % 4 end")
            elseif kind == "thumb" then emit("t = t - t % 2 + 1")
            else emit("t = t - t % 4") end
            emit(leave("t", cycles + 2))
        end

        function gen.dp(d)
            local op, setS = d.op2, d.S
            local logical = op == 0 or op == 1 or op == 8 or op == 9 or op >= 12
            local dest = (op < 8 or op >= 12) and d.rd or nil
            local toPC = dest == 15
            if toPC and setS and not thumb then
                -- "return from exception": the result goes to the program counter and the saved status comes back
                d = setmetatable({ need = 0, keep = false }, { __index = d })
                setS = false
            else toPC = toPC end
            local B, hasCarry = shifter(d, setS and logical and has(d.need, CF))
            local A = d.rn and R(d.rn, d)
            if d.rn == 15 and d.sh.kind == "regreg" then A = tostring(d.at + 12) end     -- (a quirk: one step further on)
            if logical then
                local expr
                if op == 0 or op == 8 then expr = ("band(%s, %s)"):format(A, B)
                elseif op == 1 or op == 9 then expr = ("bxor(%s, %s)"):format(A, B)
                elseif op == 12 then expr = ("bor(%s, %s)"):format(A, B)
                elseif op == 13 then expr = B
                elseif op == 14 then expr = ("band(%s, 4294967295 - %s)"):format(A, B)
                else expr = ("4294967295 - %s"):format(B) end
                if dest == 15 then emit("t = " .. expr)
                elseif dest then
                    emit(("%s = %s"):format(D(dest), expr))
                    if setS then setNZ(d, "R" .. dest) end
                elseif setS and has(d.need, NZ) then flagSet.nz = true emit("nz = " .. expr) end
                if setS and has(d.need, CF) and hasCarry then flagSet.cf = true emit("cf = sc") end
            else
                local X, Y, adding, carry = A, B, false, ""
                if op == 3 or op == 7 then X, Y = B, A end
                if op == 4 or op == 5 or op == 11 then adding = true end
                if op == 5 then flagUsed.cf = true carry = " + (cf and 1 or 0)"
                elseif op == 6 or op == 7 then flagUsed.cf = true carry = " - (cf and 0 or 1)" end
                if setS and d.need == 0 and dest and dest ~= 15 then
                    if d.keep then emit(("ca, cb = %s, %s"):format(X, Y)) end
                    if Y == "0" and carry == "" then emit(("%s = %s"):format(D(dest), X))
                    else emit(("%s = (%s %s %s%s) %% 4294967296"):format(D(dest), X, adding and "+" or "-", Y, carry)) end
                elseif setS then
                    if d.keep then emit(("ca, cb = %s, %s"):format(X, Y)) end
                    if d.need ~= 0 or dest then
                        emit(("t = %s %s %s%s"):format(X, adding and "+" or "-", Y, carry))
                        if adding then addFlags(d, X, Y) else subFlags(d, X, Y) end
                        if dest and dest ~= 15 then emit(("%s = t"):format(D(dest))) end
                    end
                else
                    local expr = ("(%s %s %s%s) %% 4294967296"):format(X, adding and "+" or "-", Y, carry)
                    if dest == 15 then emit("t = " .. expr)
                    elseif dest then emit(("%s = %s"):format(D(dest), expr)) end
                end
            end
            if dest == 15 then
                if d.S and not thumb then
                    emit(("@WB@ do return retSPSR(t), %s end"):format(looping and ("c + " .. (cycles + 2)) or tostring(cycles + 2)))
                else jumpT(d, thumb and "thumb" or "arm") end
            elseif d.psrBack then
                emit(("@WB@ do return retSPSR(%s), %s end"):format(d.at + 4, looping and ("c + " .. cycles) or tostring(cycles)))
            end
        end

        function gen.mem(d)
            -- a constant kept beside the code in the cartridge: it can never change, so just use the number
            if d.load and d.rn == 15 and not d.sh and d.P and d.size == 4 and d.rd ~= 15 then
                local addr = d.pcval + (d.U and d.imm or -d.imm)
                if addr >= 134217728 then emit(("%s = %s"):format(D(d.rd), rd32(addr))) return end
            end
            local base = R(d.rn, d)
            local off
            if d.sh then off = shifter(d, false) else off = tostring(d.imm) end
            local moved
            if d.U then moved = (d.sh or d.rn == 15) and ("(%s + %s) %% 4294967296"):format(base, off) or ("%s + %s"):format(base, off)
            else moved = ("(%s - %s) %% 4294967296"):format(base, off) end
            if not d.P then emit("a = " .. base)
            elseif off == "0" then emit("a = " .. base)
            else emit("a = " .. moved) end
            if not d.load then
                local v = (d.rd == 15) and tostring(d.at + 12) or R(d.rd, d)
                if d.size == 4 then store32a(v)
                elseif d.size == 2 then emit(("wr16(a, %s %% 65536)"):format(v))
                else emit(("wr8(a, %s %% 256)"):format(v)) end
            end
            if d.rn ~= 15 and ((not d.P) or d.Wb) and not (d.load and d.rd == d.rn) then
                if not d.P then emit(("%s = %s"):format(D(d.rn), moved)) else emit(("%s = a"):format(D(d.rn))) end
            end
            if d.load then
                local dst = (d.rd == 15) and "t" or D(d.rd)
                local ob = busOf(d)
                if d.size == 4 then
                    load32a(dst, d)
                    -- (a word read from an address that is not a multiple of four comes back rotated)
                    if d.rn ~= 13 and d.rn ~= 15 then emit(("if a %% 4 ~= 0 then %s = rorr(%s, a %% 4 * 8) end"):format(dst, dst)) end
                elseif d.size == 2 then
                    if S.QUIRKS then
                        -- 16-bit reads from odd addresses (which no sane game does): rotated, or a signed byte
                        if d.signed then emit(("if a %% 2 == 1 then t = rd8(a%s) if t >= 128 then t = t + 4294967040 end else t = rd16(a%s) if t >= 32768 then t = t + 4294901760 end end %s = t"):format(ob, ob, dst))
                        else emit(("t = rd16(a%s) if a %% 2 == 1 then t = floor(t / 256) + (t %% 256) * 16777216 end %s = t"):format(ob, dst)) end
                    elseif d.signed then emit(("t = rd16(a%s) if t >= 32768 then t = t + 4294901760 end %s = t"):format(ob, dst))
                    else emit(("%s = rd16(a%s)"):format(dst, ob)) end
                else
                    if d.signed then emit(("t = rd8(a%s) if t >= 128 then t = t + 4294967040 end %s = t"):format(ob, dst))
                    else emit(("%s = rd8(a%s)"):format(dst, ob)) end
                end
                if d.rd == 15 then jumpT(d, "arm") end
            end
        end

        function gen.block(d)
            local list, cnt = d.list, #d.list
            local hasPC = d.load and list[cnt] == 15
            if cnt == 0 then list, cnt, hasPC = { 15 }, 16, d.load end      -- (no registers named: an oddity that moves only the program counter)
            local base = R(d.rn, d)
            local startAt
            if d.U then startAt = d.P and (base .. " + 4") or base
            else startAt = d.P and ("%s - %s"):format(base, cnt * 4) or ("%s - %s"):format(base, cnt * 4 - 4) end
            emit("b = " .. startAt)
            local userRegs = d.Sbit and not hasPC
            for i, reg in ipairs(list) do
                emit(("a = b + %s"):format((i - 1) * 4))
                if d.load then
                    if reg == 15 then load32a("t", d)
                    elseif userRegs and reg >= 8 and reg <= 14 then
                        load32a("s", d)
                        emit(("%s = setUsr(%s, s, %s)"):format(D(reg), reg, R(reg, d)))
                    else load32a(D(reg), d) end
                else
                    local v
                    if reg == 15 then v = tostring(d.at + 12)
                    elseif userRegs and reg >= 8 and reg <= 14 then v = ("getUsr(%s, %s)"):format(reg, R(reg, d))
                    elseif reg == d.rn and i > 1 and d.Wb then v = ("(%s %s %s)"):format(base, d.U and "+" or "-", cnt * 4)   -- (the base, already moved)
                    else v = R(reg, d) end
                    store32a(v)
                end
            end
            local inList = false
            for _, reg in ipairs(list) do if reg == d.rn then inList = true end end
            if d.Wb and not (d.load and inList) then
                emit(("%s = %s %s %s"):format(D(d.rn), base, d.U and "+" or "-", cnt * 4))
            end
            if hasPC then
                if d.Sbit then
                    emit(("@WB@ do return retSPSR(t), %s end"):format(looping and ("c + " .. (cycles + 2)) or tostring(cycles + 2)))
                else jumpT(d, thumb and "thumb" or "arm") end
            end
        end

        function gen.mul(d)
            local expr = ("mul(%s, %s)"):format(R(d.rm, d), R(d.rs, d))
            if d.acc then expr = ("(%s + %s) %% 4294967296"):format(expr, R(d.acc, d)) end
            emit(("%s = %s"):format(D(d.rd), expr))
            if d.S then setNZ(d, "R" .. d.rd) end
        end
        function gen.mull(d)
            emit(("lo, hi = %s(%s, %s)"):format(d.signed and "smull" or "umull", R(d.rm, d), R(d.rs, d)))
            if d.accum then emit(("lo, hi = add64(lo, hi, %s, %s)"):format(R(d.rdlo, d), R(d.rdhi, d))) end
            emit(("%s = lo %s = hi"):format(D(d.rdlo), D(d.rdhi)))
            if d.S and has(d.need, NZ) then flagSet.nz = true emit("nz = (hi == 0 and lo ~= 0) and 1 or hi") end
        end
        function gen.swp(d)
            emit(("a = %s"):format(R(d.rn, d)))
            local ob = busOf(d)
            if d.size == 4 then emit(("t = rd32(a%s) if a %% 4 ~= 0 then t = rorr(t, a %% 4 * 8) end wr32(a, %s) %s = t"):format(ob, R(d.rm, d), D(d.rd)))
            else emit(("t = rd8(a%s) wr8(a, %s %% 256) %s = t"):format(ob, R(d.rm, d), D(d.rd))) end
        end
        function gen.mrs(d)
            emit("@WB@")
            emit(("%s = %s"):format(D(d.rd), d.saved and "getSPSR()" or ("getCPSR(%s)"):format(tbit)))
        end
        function gen.msr(d)
            local v = d.value and tostring(d.value) or R(d.rm, d)
            if d.saved then
                emit(("setPSR(true, %s, %s, %s)"):format(v, tostring(d.flagsToo), tostring(d.controlToo)))
            else
                emit(("t = %s"):format(v))
                emit(("@WB@ setPSR(false, t, %s, %s) do return %s, %s end"):format(tostring(d.flagsToo), tostring(d.controlToo),
                    d.at + d.len + (thumb and 1 or 0), looping and ("c + " .. cycles) or tostring(cycles)))
            end
        end
        function gen.bx(d)
            emit(("t = %s"):format(R(d.rm, d)))
            jumpT(d, "exchange")
        end
        function gen.swi(d)
            local nextKey, selfKey = d.at + d.len + (thumb and 1 or 0), d.at + (thumb and 1 or 0)
            emit(("@WB@ do return swi(%s, %s, %s), %s end"):format(d.n, nextKey, selfKey, looping and ("c + " .. (cycles + 3)) or tostring(cycles + 3)))
        end
        function gen.bad(d)
            emit(("@WB@ undefined(%s, %s)"):format(d.at, d.op))
            emit(leave(d.at + (thumb and 1 or 0), 1000000))
        end

        for i = 1, n do
            local d = ins[i]
            cycles = cycles + d.cyc
            if d.k == "b" then
                local cond = (d.cond ~= 14) and condition(d) or nil
                local body = function()
                    if d.link then emit(("%s = %s"):format(D(14), d.link)) end
                end
                if d.target == start and looping and not d.link then
                    -- back to the top: carry on round the Lua loop (unless it has run long enough to hand back)
                    if cond then
                        emit(("if not (%s) then"):format(cond))
                        d.loopCycles = cycles + 2
                    elseif waitingLoop then
                        emit(("@WB@ do return %s, c + %s, %s end"):format(start, cycles + 2, waitAnswer))
                    else
                        emit(("c = c + %s if c >= %s then %s end"):format(cycles + 2, LOOP_BUDGET, leave(start, 0)))
                    end
                elseif cond then
                    emit(("if %s then"):format(cond))
                    body()
                    emit(leave(d.target, cycles + 2))
                    emit("end")
                else
                    body()
                    emit(leave(d.target, cycles + 2))
                end
            else
                local cond = (d.cond ~= 14) and condition(d) or nil
                if cond then emit(("if %s then"):format(cond)) end
                gen[d.k](d)
                if cond then emit("end") end
            end
        end
        if not ins[n].term then emit(leave(fallKey, cycles)) end
        for i = n, 1, -1 do
            local d = ins[i]
            if d.loopCycles then
                if waitingLoop then emit(("end @WB@ do return %s, c + %s, %s end"):format(start, d.loopCycles, waitAnswer))
                else emit(("end c = c + %s if c >= %s then %s end"):format(d.loopCycles, LOOP_BUDGET, leave(start, 0))) end
            end
        end

        -- registers and flags come in from r[] at the top and go back at every way out
        local wb = {}
        for k = 0, 14 do if defd[k] then wb[#wb + 1] = ("r[%s] = R%s"):format(k, k) end end
        if flagSet.nz then wb[#wb + 1] = "r[16] = nz" end
        if flagSet.cf then wb[#wb + 1] = "r[17] = cf" end
        if flagSet.vf then wb[#wb + 1] = "r[18] = vf" end
        local head = { CHUNK_ARGS, "return function()" }
        if inRam then
            -- code in working memory may have been replaced since this was written: check before trusting it
            local checks, seen = {}, {}
            for i = 1, n do
                local d = ins[i]
                for a = d.at - d.at % 4, d.at + d.len - 1, 4 do
                    if not seen[a] then
                        seen[a] = true
                        local reg = floor(a / 16777216)
                        if reg == 3 then checks[#checks + 1] = ("iw[%s] ~= %s"):format((a % 32768) / 4, iw[(a % 32768) / 4])
                        elseif reg == 2 then checks[#checks + 1] = ("ew[%s] ~= %s"):format((a % 262144) / 4, ew[(a % 262144) / 4]) end
                    end
                end
            end
            if #checks > 0 then head[#head + 1] = "if " .. concat(checks, " or ") .. " then return nil end" end
        end
        local names, loads = {}, {}
        for k = 0, 14 do if used[k] then names[#names + 1] = "R" .. k loads[#loads + 1] = ("r[%s]"):format(k) end end
        if #names > 0 then head[#head + 1] = "local " .. concat(names, ", ") .. " = " .. concat(loads, ", ") end
        if flagUsed.nz or flagSet.nz then head[#head + 1] = "local nz = r[16]" end
        if flagUsed.cf or flagSet.cf then head[#head + 1] = "local cf = r[17]" end
        if flagUsed.vf or flagSet.vf then head[#head + 1] = "local vf = r[18]" end
        head[#head + 1] = "local t, a, b, s, sc, ca, cb, lo, hi"
        if looping then head[#head + 1] = "local c = 0" head[#head + 1] = "while true do" end
        local wbText = concat(wb, " ")
        local body = concat(out, "\n"):gsub("@WB@", function() return wbText end)
        local src = concat(head, "\n") .. "\n" .. body .. "\n" .. (looping and "end\n" or "") .. "end"
        local chunk, err = loadstring(src, "=stretch")
        if not chunk then error("MekkaBoy Advance: could not build the stretch at " .. ("%04X%04X"):format(floor(start / 65536) % 65536, start % 65536) .. ": " .. tostring(err) .. "\n" .. src) end
        local f = chunk(r, iw, ew, rd8, rd16, rd32, wr8, wr16, wr32, band, bor, bxor, mul, umull, smull, add64, floor, lslr, lsrr, asrr, rorr,
            swi, getCPSR, getSPSR, setPSR, retSPSR, getUsr, setUsr, undefined)
        blocks[start] = f
        made = made + 1
        if S.keepSource then S.source = S.source or {} S.source[start] = src end
        return f
    end
    S.compile = compile
    -- (a measuring tool: with S.timer set, the time spent translating is added up in S.translating)
    S.translating = 0
    local plainCompile = compile
    compile = function(start)
        local timer = S.timer
        if not timer then return plainCompile(start) end
        local t = timer()
        local f = plainCompile(start)
        S.translating = S.translating + timer() - t
        return f
    end

    -- ---- running ----
    S.key, S.cyc, S.stopAt, S.halted = 134217728, 0, 0, false
    function S.runCPU(untilCyc)
        local blocks = blocks
        local key, cyc = S.key, S.cyc
        local prof, tprof = S.prof, S.tprof     -- (measuring tools; nil in ordinary use)
        S.stopAt = untilCyc
        while cyc < S.stopAt do
            local f = blocks[key] or compile(key)
            S.cyc = cyc
            local k, c, waiting
            if tprof then
                local t = os.clock()
                k, c, waiting = f()
                tprof[key] = (tprof[key] or 0) + os.clock() - t
                tprof[-key - 1] = (tprof[-key - 1] or 0) + 1
            else k, c, waiting = f() end
            if not k then
                blocks[key] = nil
                f = compile(key)
                k, c, waiting = f()
            end
            if prof then prof[key] = (prof[key] or 0) + c end
            key = k
            cyc = cyc + c
            if waiting then
                if waiting == 2 then S.waitRAM = true end
                if cyc < S.stopAt then
                    S.idle = S.idle + (S.stopAt - cyc)
                    cyc = S.stopAt
                end
            end
        end
        S.key, S.cyc = key, cyc
    end
    -- an interrupt: save where we were and what state, and go to the handler
    function S.interrupt()
        local key = S.key
        local t = key % 2
        local old = getCPSR(t * 32)
        setMode(0x12)
        spsr[3] = old
        irqOff = true
        r[14] = key - t + 4
        setBiosBus(0xE55EC002)
        S.key = 0x18
        S.waitRAM = false
    end
    function S.irqsAllowed() return not irqOff end
    function S.stretches() return made end
    function S.cpuState()
        return { mode = mode, irqOff = irqOff, cpsr = getCPSR((S.key % 2) * 32), key = S.key }
    end
    function S.resetCPU(entry)
        for i = 0, 15 do r[i] = 0 end
        r[16], r[17], r[18] = 1, false, false
        mode, irqOff, fiqOff = 0x1F, false, false
        for i = 1, 7 do bankSP[i], bankLR[i], spsr[i] = 0, 0, 0 end
        -- what the console's own start-up code leaves behind
        bankSP[1], bankSP[3], bankSP[4] = 0x03007F00, 0x03007FA0, 0x03007FE0
        r[13] = 0x03007F00
        S.key, S.halted, S.waitRAM = entry, false, false
    end
    S.getCPSR, S.setMode = getCPSR, setMode
    -- for memory valves. (Translated stretches are not part of a photograph: those made from the
    -- cartridge stay good, and those made from working memory check their own source before running.)
    function S.cpuSave()
        local t = { mode = mode, irqOff = irqOff, fiqOff = fiqOff, key = S.key, cyc = S.cyc, halted = S.halted and true or false,
                    waitRAM = S.waitRAM and true or false, nz = r[16], cf = r[17], vf = r[18], r = {}, sp = {}, lr = {}, spsr = {}, fiq = {}, usr = {} }
        for i = 0, 15 do t.r[i + 1] = r[i] end
        for i = 1, 7 do t.sp[i], t.lr[i], t.spsr[i] = bankSP[i], bankLR[i], spsr[i] end
        for i = 1, 5 do t.fiq[i], t.usr[i] = fiqHi[i], usrHi[i] end
        return t
    end
    function S.cpuLoad(t)
        for i = 0, 15 do r[i] = t.r[i + 1] end
        r[16], r[17], r[18] = t.nz, t.cf and true or false, t.vf and true or false
        mode, irqOff, fiqOff = t.mode, t.irqOff and true or false, t.fiqOff and true or false
        for i = 1, 7 do bankSP[i], bankLR[i], spsr[i] = t.sp[i], t.lr[i], t.spsr[i] end
        for i = 1, 5 do fiqHi[i], usrHi[i] = t.fiq[i], t.usr[i] end
        S.key, S.cyc, S.halted, S.waitRAM, S.stopAt = t.key, t.cyc, t.halted and true or false, t.waitRAM and true or false, 0
    end
end

-- ------------------------------------------------- stand-ins for the built-in routines ---
-- A real console has a small program of Nintendo's built in, which games call
-- for common jobs: divide, unpack compressed pictures, wait for the next
-- frame. We cannot ship that program, so each job is done here directly.
-- The one piece that has to exist as real code is the interrupt entry, written
-- from scratch below (six instructions that any such console must perform).
local function buildBIOS(S)
    local r = S.r
    local rd8, rd16, rd32, wr8, wr16, wr32 = S.rd8, S.rd16, S.rd32, S.wr8, S.wr16, S.wr32
    local bios = S.bios
    bios[0x18 / 4] = 0xEA000042         -- b 0x128
    bios[0x128 / 4] = 0xE92D500F        -- push r0-r3, r12, lr
    bios[0x12C / 4] = 0xE3A00301        -- r0 = 0x04000000
    bios[0x130 / 4] = 0xE28FE000        -- lr = the instruction after next
    bios[0x134 / 4] = 0xE510F004        -- jump to the game's handler, whose address is kept at 0x03007FFC
    bios[0x138 / 4] = 0xE8BD500F        -- pop r0-r3, r12, lr
    bios[0x13C / 4] = 0xE25EF004        -- return to what was interrupted

    local function signed(v) if v >= HALF then return v - W end return v end
    local function unsigned(v) return v % W end

    local banks, BANK = S.romBanks, S.bankSize
    local function cartByte(a)              -- (a byte of the cartridge, without the usual asking around)
        local o = a % 33554432
        return byte(banks[floor(o / BANK) + 1], o % BANK + 1)
    end
    -- unpacked bytes on their way out: straight into the tables where that is plain sailing
    local function deliver(out, n, dst, vramStyle)
        local reg = floor(dst / 16777216)
        local whole = n - n % 4
        if S.NOBULK then reg = -1 end
        if (reg == 2 or reg == 3) and dst % 4 == 0 then
            local mem, size = S.ew, 262144
            if reg == 3 then mem, size = S.iw, 32768 end
            local d0 = dst % size
            if d0 + n <= size then
                local i = d0 / 4
                for k = 1, whole, 4 do
                    mem[i] = out[k] + out[k + 1] * 256 + out[k + 2] * 65536 + out[k + 3] * 16777216
                    i = i + 1
                end
                for k = whole + 1, n do wr8(dst + k - 1, out[k]) end
                return
            end
        elseif reg == 6 and dst % 2 == 0 and n % 2 == 0 then
            local d0 = dst % 131072
            if d0 + n + 1 <= 98304 then
                local vramByte = S.vramByte
                for k = 1, n do vramByte(d0 + k - 1, out[k]) end
                return
            end
        end
        for i = 1, n - 1, 2 do wr16(dst + i - 1, out[i] + out[i + 1] * 256) end
        if n % 2 == 1 then
            if vramStyle then wr16(dst + n - 1, out[n]) else wr8(dst + n - 1, out[n]) end
        end
    end
    local function lz77(src, dst, vramStyle)
        local header = rd32(src)
        local size = floor(header / 256)
        src = src + 4
        local out, n = {}, 0
        local rd8 = rd8
        local sreg = floor(src / 16777216)
        if sreg >= 8 and sreg <= 13 and src % 33554432 + size * 2 + 16 < S.romSize and not S.NOBULK then rd8 = cartByte end
        while n < size do
            local flags = rd8(src)
            src = src + 1
            local mask = 128
            for _ = 1, 8 do
                if n >= size then break end
                if flags >= mask then
                    flags = flags - mask
                    local b1, b2 = rd8(src), rd8(src + 1)
                    src = src + 2
                    local len = floor(b1 / 16) + 3
                    local back = (b1 % 16) * 256 + b2 + 1
                    for _ = 1, len do
                        if n >= size then break end
                        n = n + 1
                        out[n] = out[n - back] or 0
                    end
                else
                    n = n + 1
                    out[n] = rd8(src)
                    src = src + 1
                end
                mask = mask / 2
            end
        end
        deliver(out, n, dst, vramStyle)
    end
    local function runLength(src, dst, vramStyle)
        local header = rd32(src)
        local size = floor(header / 256)
        src = src + 4
        local out, n = {}, 0
        while n < size do
            local f = rd8(src)
            src = src + 1
            if f >= 128 then
                local v = rd8(src)
                src = src + 1
                for _ = 1, f - 128 + 3 do if n < size then n = n + 1 out[n] = v end end
            else
                for _ = 1, f + 1 do if n < size then n = n + 1 out[n] = rd8(src) end src = src + 1 end
            end
        end
        for i = 1, n - 1, 2 do wr16(dst + i - 1, out[i] + out[i + 1] * 256) end
        if n % 2 == 1 then if vramStyle then wr16(dst + n - 1, out[n]) else wr8(dst + n - 1, out[n]) end end
    end
    -- Unpacking of Huffman-coded data (built-in routine 13). The data begins with a word (how many bits to a unit,
    -- 4 or 8, and how long the result is) and a table of the code tree; then come the codes, in 32-bit words read
    -- from the top bit down. A tree entry says how far on its two children are (bits 0-5) and whether the left one
    -- (bit 7) or the right one (bit 6) is a value rather than another fork. The result is written a word at a time.
    local function huffman(src, dst)
        local header = rd32(src)
        local bits = header % 16
        if bits == 0 then bits = 8 end
        local left = floor(header / 256)
        if bits ~= 4 and bits ~= 8 then return end
        local unit = POW[bits]
        local tree = src + 5
        local stream = src + 4 + (rd8(src + 4) + 1) * 2
        local at = tree
        local node = rd8(at)
        local block, seen = 0, 0
        while left > 0 do
            local word = rd32(stream)
            stream = stream + 4
            local top = 2147483648
            for _ = 1, 32 do
                local next = (at - at % 2) + (node % 64) * 2 + 2
                local value
                if word >= top then                       -- 1: the right-hand child
                    word = word - top
                    if floor(node / 64) % 2 == 1 then value = rd8(next + 1) else at = next + 1 node = rd8(at) end
                else                                      -- 0: the left-hand child
                    if node >= 128 then value = rd8(next) else at = next node = rd8(at) end
                end
                top = top / 2
                if value then
                    block = block + (value % unit) * POW[seen]
                    seen = seen + bits
                    at = tree
                    node = rd8(at)
                    if seen == 32 then
                        wr32(dst, block)
                        dst, block, seen = dst + 4, 0, 0
                        left = left - 4
                        if left <= 0 then break end
                    end
                end
            end
        end
    end
    -- Undoing a "difference filter" (built-in routines 16, 17 and 18): the data holds a first unit as it is and
    -- after it only how much each unit differs from the one before. Units are bytes (16, 17) or 16-bit (18).
    local function unfilter(src, dst, wide, vramStyle)
        local header = rd32(src)
        local size = floor(header / 256)
        src = src + 4
        if wide then
            local v = 0
            for i = 0, size - 2, 2 do
                v = (v + rd16(src + i)) % 65536
                wr16(dst + i, v)
            end
        else
            local v, out = 0, {}
            for i = 1, size do
                v = (v + rd8(src + i - 1)) % 256
                out[i] = v
            end
            if vramStyle then
                for i = 1, size - 1, 2 do wr16(dst + i - 1, out[i] + out[i + 1] * 256) end
                if size % 2 == 1 then wr16(dst + size - 1, out[size]) end
            else
                for i = 1, size do wr8(dst + i - 1, out[i]) end
            end
        end
    end
    local function bitUnpack(src, dst, info)
        local len, srcBits, dstBits = rd16(info), rd8(info + 2), rd8(info + 3)
        local offWord = rd32(info + 4)
        local offset, zeroToo = offWord % HALF, offWord >= HALF
        local acc, accBits = 0, 0
        for i = 0, len - 1 do
            local b = rd8(src + i)
            for _ = 1, 8 / srcBits do
                local v = b % POW[srcBits]
                b = floor(b / POW[srcBits])
                if v ~= 0 or zeroToo then v = v + offset end
                acc = acc + (v % POW[dstBits]) * POW[accBits]
                accBits = accBits + dstBits
                if accBits >= 32 then
                    wr32(dst, acc % W)
                    dst = dst + 4
                    acc, accBits = 0, 0
                end
            end
        end
    end
    local function cpuSet(src, dst, ctl, fast)
        local count = ctl % 2097152
        local fill = floor(ctl / 16777216) % 2 == 1
        local wide = fast or floor(ctl / 67108864) % 2 == 1
        if fast then count = count + (8 - count % 8) % 8 end
        local unit = wide and 4 or 2
        if S.bulk(src - src % unit, dst - dst % unit, count, wide, fill) then return end
        if wide then
            src, dst = src - src % 4, dst - dst % 4
            if fill then
                local v = rd32(src)
                for i = 0, count - 1 do wr32(dst + i * 4, v) end
            else
                for i = 0, count - 1 do wr32(dst + i * 4, rd32(src + i * 4)) end
            end
        else
            src, dst = src - src % 2, dst - dst % 2
            if fill then
                local v = rd16(src)
                for i = 0, count - 1 do wr16(dst + i * 2, v) end
            else
                for i = 0, count - 1 do wr16(dst + i * 2, rd16(src + i * 2)) end
            end
        end
    end
    local function ramReset(flags)
        local function bitOn(b) return floor(flags / POW[b]) % 2 == 1 end
        if bitOn(0) then for i = 0, 65535 do S.ew[i] = 0 end end
        if bitOn(1) then for i = 0, 8191 - 128 do S.iw[i] = 0 end end
        if bitOn(2) then for i = 0, 511 do S.pal[i] = 0 S.palRaw[i] = 0 end end
        if bitOn(3) then for i = 0, 0x17FFF do S.vramByte(i, 0) end end
        if bitOn(4) then for i = 0, 511 do S.oam[i] = 0 end end
        if bitOn(7) then
            local io = S.io
            io[0x20], io[0x26], io[0x30], io[0x36] = 0x100, 0x100, 0x100, 0x100
        end
        S.allChanged()
    end
    local function s16(v) v = v % 65536 if v >= 32768 then return v - 65536 end return v end
    local function affine(src, dst, count, step, isBG)
        for _ = 1, count do
            if isBG then
                local cx, cy = signed(rd32(src)), signed(rd32(src + 4))
                local dx, dy = s16(rd16(src + 8)), s16(rd16(src + 10))
                local sx, sy = s16(rd16(src + 12)), s16(rd16(src + 14))
                local theta = floor(rd16(src + 16) / 256) / 256 * 2 * math.pi
                local sn, cs = math.sin(theta), math.cos(theta)
                local pa, pb = floor(sx * cs + 0.5), floor(-sx * sn + 0.5)
                local pc, pd = floor(sy * sn + 0.5), floor(sy * cs + 0.5)
                wr16(dst, pa % 65536) wr16(dst + 2, pb % 65536) wr16(dst + 4, pc % 65536) wr16(dst + 6, pd % 65536)
                wr32(dst + 8, unsigned(cx - (pa * dx + pb * dy)))
                wr32(dst + 12, unsigned(cy - (pc * dx + pd * dy)))
                src, dst = src + 20, dst + 16
            else
                local sx, sy = s16(rd16(src)), s16(rd16(src + 2))
                local theta = floor(rd16(src + 4) / 256) / 256 * 2 * math.pi
                local sn, cs = math.sin(theta), math.cos(theta)
                wr16(dst, floor(sx * cs + 0.5) % 65536)
                wr16(dst + step, floor(-sx * sn + 0.5) % 65536)
                wr16(dst + step * 2, floor(sy * sn + 0.5) % 65536)
                wr16(dst + step * 3, floor(sy * cs + 0.5) % 65536)
                src, dst = src + 8, dst + step * 4
            end
        end
    end

    local waiting, waitFlags = false, 0
    local names = {}
    S.biosCalls = names
    local function call(n, nextKey, selfKey)
        names[n] = (names[n] or 0) + 1
        if n == 0x06 or n == 0x07 then
            local num, den = signed(r[0]), signed(r[1])
            if n == 0x07 then num, den = den, num end
            if den == 0 then den = 1 end
            local q = num / den
            q = (q >= 0) and floor(q) or -floor(-q)
            r[0], r[1], r[3] = unsigned(q), unsigned(num - q * den), unsigned(q >= 0 and q or -q)
        elseif n == 0x05 or n == 0x04 then
            if not waiting then
                waiting = true
                waitFlags = (n == 0x05) and 1 or (r[1] % 65536)
                S.ioWrite(0x208, 1)
                if n == 0x05 or r[0] ~= 0 then
                    local m = rd16(0x03007FF8)
                    wr16(0x03007FF8, m - GBA.band(m, waitFlags))
                end
            end
            local m = rd16(0x03007FF8)
            local hit = GBA.band(m, waitFlags)
            if hit ~= 0 then
                wr16(0x03007FF8, m - hit)
                waiting = false
            else
                S.halted = true
                S.stopAt = 0
                return selfKey
            end
        elseif n == 0x02 or n == 0x03 then
            S.halted = true
            S.stopAt = 0
        elseif n == 0x0B then cpuSet(r[0], r[1], r[2], false)
        elseif n == 0x0C then cpuSet(r[0], r[1], r[2], true)
        elseif n == 0x11 then lz77(r[0], r[1], false)
        elseif n == 0x12 then lz77(r[0], r[1], true)
        elseif n == 0x14 then runLength(r[0], r[1], false)
        elseif n == 0x15 then runLength(r[0], r[1], true)
        elseif n == 0x10 then bitUnpack(r[0], r[1], r[2])
        elseif n == 0x08 then r[0] = floor(math.sqrt(r[0]))
        elseif n == 0x0A then
            local x, y = s16(r[0]), s16(r[1])
            local a = math.atan2(y, x)
            if a < 0 then a = a + 2 * math.pi end
            r[0] = floor(a / (2 * math.pi) * 65536) % 65536
        elseif n == 0x09 then
            local t = s16(r[0]) / 16384
            r[0] = floor(math.atan(t) / (math.pi / 2) * 16384) % 65536
        elseif n == 0x0E then affine(r[0], r[1], r[2], 0, true)
        elseif n == 0x0F then affine(r[0], r[1], r[2], r[3], false)
        elseif n == 0x01 then ramReset(r[0] % 256)
        elseif n == 0x0D then r[0] = 0xBAAE187F
        elseif n == 0x1F then
            local freq = rd32(r[0] + 4)
            local key, fine = r[1] % 256, r[2] % 256
            r[0] = floor(freq / (2 ^ ((180 - key - fine / 256) / 12))) % W
        elseif n == 0x00 then
            S.softReset()
            return S.key
        elseif n == 0x13 then huffman(r[0], r[1])
        elseif n == 0x16 then unfilter(r[0], r[1], false, false)
        elseif n == 0x17 then unfilter(r[0], r[1], false, true)
        elseif n == 0x18 then unfilter(r[0], r[1], true, false)
        end
        -- (the sound driver calls, 0x19-0x1E and 0x20 on, are accepted and ignored)
        return nextKey
    end
    S.biosTime = {}
    function S.bios(n, nextKey, selfKey)
        local timer = S.timer
        if not timer then return call(n, nextKey, selfKey) end
        local t = timer()                   -- (a measuring tool)
        local k = call(n, nextKey, selfKey)
        S.biosTime[n] = (S.biosTime[n] or 0) + timer() - t
        return k
    end
    function S.resetBIOS() waiting = false end
    function S.biosSave() return { waiting = waiting, waitFlags = waitFlags } end
    function S.biosLoad(t) waiting, waitFlags = t.waiting and true or false, t.waitFlags or 0 end
end

-- ------------------------------------------------------------------- the screen ---
-- 240 by 160, drawn a line at a time. Layers are laid down back to front:
-- the backdrop, then for each priority from 3 down to 0 the backgrounds of
-- that priority and the sprites of that priority on top of them.
local function buildPPU(S)
    local io, vram, vnib, vrow, pal, oam, vstamp = S.io, S.vram, S.vnib, S.vrow, S.pal, S.oam, S.vstamp
    local fb = {}
    for i = 1, 240 * 160 do fb[i] = 0 end
    S.fb = fb
    S.refX, S.refY = { [2] = 0, [3] = 0 }, { [2] = 0, [3] = 0 }
    local used = { blend = 0, window = 0, affineBG = 0, affineOBJ = 0, bitmap = 0, mosaic = 0, lines = 0, shifted = 0, nSprite = 0, nRange = 0, nStash = 0, nSnap = 0, nHad = 0, nKind = 0, nOld = 0, nStill = 0, nTiles = 0, nMove = 0, wScroll = 0, wIo = 0, wPal = 0, wOam = 0, wObj = 0, wVram = 0, careful = 0, layered = 0 }
    S.used = used

    -- Is a whole row of a background's map made of nothing but blank tiles? Speech-box and overlay
    -- layers are mostly that, and such a row can be skipped outright. The answer is remembered per
    -- map row until picture memory next changes.
    local blankAt, blankFor, blankIs = {}, {}, {}
    local function rowBlank(rowBase, charBase, eight, cnt)
        local k = rowBase / 64
        local at = S.vramAt
        if blankAt[k] == at and blankFor[k] == cnt then return blankIs[k] end
        blankAt[k], blankFor[k] = at, cnt
        local known, blank = -1, true
        for mi = rowBase, rowBase + 62, 2 do
            local tile = (vram[mi] + vram[mi + 1] * 256) % 1024
            if tile ~= known then
                if charBase == 49152 and tile >= 512 then blank = false break end   -- (reaches into the sprites' pictures)
                local q = (charBase + tile * (eight and 64 or 32)) / 4
                local sum = vrow[q] + vrow[q + 1] + vrow[q + 2] + vrow[q + 3] + vrow[q + 4] + vrow[q + 5] + vrow[q + 6] + vrow[q + 7]
                if eight then sum = sum + vrow[q + 8] + vrow[q + 9] + vrow[q + 10] + vrow[q + 11] + vrow[q + 12] + vrow[q + 13] + vrow[q + 14] + vrow[q + 15] end
                if sum ~= 0 then blank = false break end
                known = tile
            end
        end
        blankIs[k] = blank
        return blank
    end

    -- one line of an ordinary tiled background
    local vcls = S.vcls         -- per row of a 16-color tile: nil not looked at yet, 0 empty, 1 no gaps, 2 some gaps
    -- (x0, x1: draw only that strip of the line. Answers true if the whole row was blank.)
    local function textBG(n, y, o, fb, pal, x0, x1)
        local cnt = io[8 + n * 2]
        local charBase = (floor(cnt / 4) % 4) * 16384
        local mapBase = (floor(cnt / 256) % 32) * 2048
        local size = floor(cnt / 16384)
        local eight = floor(cnt / 128) % 2 == 1
        local wide, tall = size % 2 == 1, size >= 2
        local yy = (y + io[0x12 + n * 4]) % (tall and 512 or 256)
        local rowBase = mapBase + (floor(yy / 8) % 32) * 64
        if yy >= 256 then rowBase = rowBase + (wide and 4096 or 2048) end
        if rowBlank(rowBase, charBase, eight, cnt) and (not wide or rowBlank(rowBase + 2048, charBase, eight, cnt)) then return true end
        local ty = yy % 8
        local xx = io[0x10 + n * 4] % 512
        local px = -(xx % 8)
        local col = floor(xx / 8)
        local cols = wide and 64 or 32
        local vram, vnib, vrow, vcls = vram, vnib, vrow, vcls
        local lo, hi = 0, 239
        if x0 then
            lo, hi = x0, x1
            local skip = floor((lo - px) / 8)           -- whole tiles to the left of the strip
            if skip > 0 then px, col = px + skip * 8, col + skip end
        end
        while px <= hi do
            local c = col % cols
            local mi = rowBase + (c % 32) * 2
            if c >= 32 then mi = mi + 2048 end
            local e = vram[mi] + vram[mi + 1] * 256
            do
                local tile = e % 1024
                local flips = floor(e / 1024) % 4
                local row = (flips >= 2) and (7 - ty) or ty
                if not eight then
                    local rb = charBase + tile * 32 + row * 4
                    local b = rb * 2
                    local cls = vcls[rb / 4]
                    if not cls then
                        local zeros = 0
                        for k = b, b + 7 do if vnib[k] == 0 then zeros = zeros + 1 end end
                        cls = (zeros == 8) and 0 or ((zeros == 0) and 1 or 2)
                        vcls[rb / 4] = cls
                    end
                    if cls == 0 then
                        -- (an empty row of the tile: nothing to draw)
                    elseif px >= lo and px + 7 <= hi then
                        local pb = floor(e / 4096) * 16
                        local p = o + px
                        if cls == 1 then
                            if flips % 2 == 1 then
                                fb[p], fb[p + 1], fb[p + 2], fb[p + 3], fb[p + 4], fb[p + 5], fb[p + 6], fb[p + 7] =
                                    pal[pb + vnib[b + 7]], pal[pb + vnib[b + 6]], pal[pb + vnib[b + 5]], pal[pb + vnib[b + 4]],
                                    pal[pb + vnib[b + 3]], pal[pb + vnib[b + 2]], pal[pb + vnib[b + 1]], pal[pb + vnib[b]]
                            else
                                fb[p], fb[p + 1], fb[p + 2], fb[p + 3], fb[p + 4], fb[p + 5], fb[p + 6], fb[p + 7] =
                                    pal[pb + vnib[b]], pal[pb + vnib[b + 1]], pal[pb + vnib[b + 2]], pal[pb + vnib[b + 3]],
                                    pal[pb + vnib[b + 4]], pal[pb + vnib[b + 5]], pal[pb + vnib[b + 6]], pal[pb + vnib[b + 7]]
                            end
                        else
                            local c0, c1, c2, c3, c4, c5, c6, c7
                            if flips % 2 == 1 then c7, c6, c5, c4, c3, c2, c1, c0 = vnib[b], vnib[b + 1], vnib[b + 2], vnib[b + 3], vnib[b + 4], vnib[b + 5], vnib[b + 6], vnib[b + 7]
                            else c0, c1, c2, c3, c4, c5, c6, c7 = vnib[b], vnib[b + 1], vnib[b + 2], vnib[b + 3], vnib[b + 4], vnib[b + 5], vnib[b + 6], vnib[b + 7] end
                            if c0 ~= 0 then fb[p] = pal[pb + c0] end
                            if c1 ~= 0 then fb[p + 1] = pal[pb + c1] end
                            if c2 ~= 0 then fb[p + 2] = pal[pb + c2] end
                            if c3 ~= 0 then fb[p + 3] = pal[pb + c3] end
                            if c4 ~= 0 then fb[p + 4] = pal[pb + c4] end
                            if c5 ~= 0 then fb[p + 5] = pal[pb + c5] end
                            if c6 ~= 0 then fb[p + 6] = pal[pb + c6] end
                            if c7 ~= 0 then fb[p + 7] = pal[pb + c7] end
                        end
                    else
                        -- a tile cut off by the edge of the screen: only the dots that show
                        local pb = floor(e / 4096) * 16
                        local from, to = 0, 7
                        if px < lo then from = lo - px end
                        if px + 7 > hi then to = hi - px end
                        local p = o + px
                        if flips % 2 == 1 then
                            b = b + 7
                            for k = from, to do
                                local ci = vnib[b - k]
                                if ci ~= 0 then fb[p + k] = pal[pb + ci] end
                            end
                        else
                            for k = from, to do
                                local ci = vnib[b + k]
                                if ci ~= 0 then fb[p + k] = pal[pb + ci] end
                            end
                        end
                    end
                else
                    local b = charBase + tile * 64 + row * 8
                    if vrow[b / 4] + vrow[b / 4 + 1] == 0 then
                    elseif px >= lo and px + 7 <= hi then
                        local p = o + px
                        local c0, c1, c2, c3, c4, c5, c6, c7
                        if flips % 2 == 1 then c7, c6, c5, c4, c3, c2, c1, c0 = vram[b], vram[b + 1], vram[b + 2], vram[b + 3], vram[b + 4], vram[b + 5], vram[b + 6], vram[b + 7]
                        else c0, c1, c2, c3, c4, c5, c6, c7 = vram[b], vram[b + 1], vram[b + 2], vram[b + 3], vram[b + 4], vram[b + 5], vram[b + 6], vram[b + 7] end
                        if c0 ~= 0 then fb[p] = pal[c0] end
                        if c1 ~= 0 then fb[p + 1] = pal[c1] end
                        if c2 ~= 0 then fb[p + 2] = pal[c2] end
                        if c3 ~= 0 then fb[p + 3] = pal[c3] end
                        if c4 ~= 0 then fb[p + 4] = pal[c4] end
                        if c5 ~= 0 then fb[p + 5] = pal[c5] end
                        if c6 ~= 0 then fb[p + 6] = pal[c6] end
                        if c7 ~= 0 then fb[p + 7] = pal[c7] end
                    else
                        for k = 0, 7 do
                            local x = px + k
                            if x >= lo and x <= hi then
                                local ci = vram[b + ((flips % 2 == 1) and (7 - k) or k)]
                                if ci ~= 0 then fb[o + x] = pal[ci] end
                            end
                        end
                    end
                end
            end
            px = px + 8
            col = col + 1
        end
    end

    local function blankNow(n, y)
        local cnt = io[8 + n * 2]
        local charBase = (floor(cnt / 4) % 4) * 16384
        local mapBase = (floor(cnt / 256) % 32) * 2048
        local size = floor(cnt / 16384)
        local eight = floor(cnt / 128) % 2 == 1
        local wide, tall = size % 2 == 1, size >= 2
        local yy = (y + io[0x12 + n * 4]) % (tall and 512 or 256)
        local rowBase = mapBase + (floor(yy / 8) % 32) * 64
        if yy >= 256 then rowBase = rowBase + (wide and 4096 or 2048) end
        return rowBlank(rowBase, charBase, eight, cnt) and (not wide or rowBlank(rowBase + 2048, charBase, eight, cnt))
    end

    local function s16(v) if v >= 32768 then return v - 65536 end return v end
    -- one line of a background that can be turned and scaled
    local function affineBG(n, y, o, fb, pal)
        used.affineBG = used.affineBG + 1
        local cnt = io[8 + n * 2]
        local charBase = (floor(cnt / 4) % 4) * 16384
        local mapBase = (floor(cnt / 256) % 32) * 2048
        local tiles = 16 * POW[floor(cnt / 16384)]          -- tiles across: 16, 32, 64, 128
        local span = tiles * 8
        local wrap = floor(cnt / 8192) % 2 == 1
        local base = (n == 2) and 0x20 or 0x30
        local pa, pc = s16(io[base]), s16(io[base + 4])
        local x, yv = S.refX[n], S.refY[n]
        if pc == 0 then
            -- not turned: the whole screen line comes from one row of the picture
            local ty = floor(yv / 256)
            if wrap then ty = ty % span elseif ty < 0 or ty >= span then return end
            local mapRow = mapBase + floor(ty / 8) * tiles
            local rowIn = (ty % 8) * 8
            if pa == 256 then
                -- and not stretched either: plain tiles, eight dots at a time
                local startX = floor(x / 256)
                local px = 0
                while px < 240 do
                    local tx = startX + px
                    if wrap then tx = tx % span end
                    if tx < 0 then px = px - tx
                    elseif tx >= span then break
                    else
                        local inTile = tx % 8
                        local b = charBase + vram[mapRow + (tx - inTile) / 8] * 64 + rowIn
                        local count = 8 - inTile
                        if px + count > 240 then count = 240 - px end
                        if vrow[b / 4] + vrow[b / 4 + 1] ~= 0 then
                            b = b + inTile
                            local p = o + px
                            for k = 0, count - 1 do
                                local ci = vram[b + k]
                                if ci ~= 0 then fb[p + k] = pal[ci] end
                            end
                        end
                        px = px + count
                    end
                end
                return
            end
            for px = 0, 239 do
                local tx = floor(x / 256)
                if wrap then tx = tx % span end
                if tx >= 0 and tx < span then
                    local ci = vram[charBase + vram[mapRow + floor(tx / 8)] * 64 + rowIn + tx % 8]
                    if ci ~= 0 then fb[o + px] = pal[ci] end
                end
                x = x + pa
            end
            return
        end
        for px = 0, 239 do
            local tx, ty = floor(x / 256), floor(yv / 256)
            if wrap then tx, ty = tx % span, ty % span end
            if tx >= 0 and tx < span and ty >= 0 and ty < span then
                local tile = vram[mapBase + floor(ty / 8) * tiles + floor(tx / 8)]
                local ci = vram[charBase + tile * 64 + (ty % 8) * 8 + tx % 8]
                if ci ~= 0 then fb[o + px] = pal[ci] end
            end
            x, yv = x + pa, yv + pc
        end
    end
    local function bitmapBG(mode, y, o, fb, pal, add)
        used.bitmap = used.bitmap + 1
        local page = (floor(io[0] / 16) % 2 == 1) and 0xA000 or 0
        if mode == 3 then
            local b = y * 480
            for px = 0, 239 do fb[o + px] = (vram[b] + vram[b + 1] * 256) % 32768 + add b = b + 2 end
        elseif mode == 4 then
            local b = page + y * 240
            for px = 0, 239 do
                local ci = vram[b + px]
                if ci ~= 0 then fb[o + px] = pal[ci] end
            end
        elseif y < 128 then
            local b = page + y * 320
            for px = 0, 159 do fb[o + px] = (vram[b] + vram[b + 1] * 256) % 32768 + add b = b + 2 end
        end
    end

    -- sprites: worked out once per frame into which lines each one crosses
    local OBJ_W = { [0] = { [0] = 8, 16, 32, 64 }, { [0] = 16, 32, 32, 64 }, { [0] = 8, 8, 16, 32 }, { [0] = 8, 8, 8, 8 } }
    local OBJ_H = { [0] = { [0] = 8, 16, 32, 64 }, { [0] = 8, 8, 16, 32 }, { [0] = 16, 32, 32, 64 }, { [0] = 8, 8, 8, 8 } }
    local lineSprites, builtFor = {}, -1
    for y = 0, 159 do lineSprites[y] = {} end
    S.lineSprites = lineSprites
    local sprX, sprY, sprW, sprH, sprBW = {}, {}, {}, {}, {}
    local lineSpecial, lineWinObj = {}, {}      -- lines crossed by a see-through sprite, or by a "window" sprite
    -- Each line also keeps a fingerprint of the sprites that cross it, so that a sprite moving in one
    -- corner does not make the painter redo the lines it never touches.
    local lineSig, newSig, lineOamAt = {}, {}, {}
    for y = 0, 159 do lineSig[y], newSig[y], lineOamAt[y] = 0, 0, 1 end
    S.lineSig, S.lineOamAt = lineSig, lineOamAt
    local function buildSprites()
        for y = 0, 159 do
            local t = lineSprites[y]
            for i = #t, 1, -1 do t[i] = nil end
            lineSpecial[y], lineWinObj[y] = false, false
            newSig[y] = 0
        end
        for i = 127, 0, -1 do
            local a0, a1 = oam[i * 4], oam[i * 4 + 1]
            local affine, double = floor(a0 / 256) % 2 == 1, floor(a0 / 512) % 2 == 1
            if affine or not double then            -- (without the turn-and-scale bit, that second bit means "hidden")
                local shape, size = floor(a0 / 16384), floor(a1 / 16384)
                local w, h = OBJ_W[shape][size], OBJ_H[shape][size]
                local bw, bh = w, h
                if affine and double then bw, bh = w * 2, h * 2 end
                local y0 = a0 % 256
                if y0 >= 160 then y0 = y0 - 256 end
                local x0 = a1 % 512
                if x0 >= 240 then x0 = x0 - 512 end
                if x0 + bw > 0 and y0 + bh > 0 then
                    sprX[i], sprY[i], sprW[i], sprH[i], sprBW[i] = x0, y0, w, h, bw
                    local objMode = floor(a0 / 1024) % 4
                    local f1, f2 = a0 + a1 * 65536 + i * 2654435761, oam[i * 4 + 2]
                    if affine then
                        local g = (floor(a1 / 512) % 32) * 16
                        f2 = f2 + (oam[g + 3] + oam[g + 7] * 7 + oam[g + 11] * 31 + oam[g + 15] * 127) * 65536
                    end
                    for y = (y0 < 0) and 0 or y0, (y0 + bh > 160) and 159 or (y0 + bh - 1) do
                        local t = lineSprites[y]
                        t[#t + 1] = i
                        if objMode == 1 then lineSpecial[y] = true elseif objMode == 2 then lineWinObj[y] = true end
                        newSig[y] = ((newSig[y] * 1000003 + f1) % 4294967291 * 1000003 + f2) % 4294967291
                    end
                end
            end
        end
        local now = S.stampAll
        for y = 0, 159 do
            if newSig[y] ~= lineSig[y] then lineSig[y] = newSig[y] lineOamAt[y] = now end
        end
    end
    local function sprite(i, y, o, oneD, fb, pal)
        local a0, a1, a2 = oam[i * 4], oam[i * 4 + 1], oam[i * 4 + 2]
        local objMode = floor(a0 / 1024) % 4
        local w, h, x0 = sprW[i], sprH[i], sprX[i]
        local row = y - sprY[i]
        local eight = floor(a0 / 8192) % 2 == 1
        local tile = a2 % 1024
        local pb = 256 + (eight and 0 or floor(a2 / 4096) * 16)
        local perRow = oneD and (w / 8) or 32
        if eight and oneD then perRow = perRow * 2 end
        if floor(a0 / 256) % 2 == 1 then
            -- turned and scaled: for every dot of its box, find which dot of the picture lands there
            used.affineOBJ = used.affineOBJ + 1
            local g = (floor(a1 / 512) % 32) * 16
            local pa, pbb, pc, pd = s16(oam[g + 3]), s16(oam[g + 7]), s16(oam[g + 11]), s16(oam[g + 15])
            local bw, bh = w, h
            if floor(a0 / 512) % 2 == 1 then bw, bh = w * 2, h * 2 end
            local dy = row - bh / 2
            for ix = 0, bw - 1 do
                local x = x0 + ix
                if x >= 0 and x < 240 then
                    local dx = ix - bw / 2
                    local tx = floor((pa * dx + pbb * dy) / 256) + w / 2
                    local ty = floor((pc * dx + pd * dy) / 256) + h / 2
                    if tx >= 0 and tx < w and ty >= 0 and ty < h then
                        local ci
                        if eight then
                            local t = (tile + floor(ty / 8) * perRow + floor(tx / 8) * 2) % 1024
                            ci = vram[0x10000 + t * 32 + (ty % 8) * 8 + tx % 8]
                        else
                            local t = (tile + floor(ty / 8) * perRow + floor(tx / 8)) % 1024
                            ci = vnib[(0x10000 + t * 32 + (ty % 8) * 4) * 2 + tx % 8]
                        end
                        if ci ~= 0 then fb[o + x] = pal[pb + ci] end
                    end
                end
            end
            return
        end
        local hflip, vflip = floor(a1 / 4096) % 2 == 1, floor(a1 / 8192) % 2 == 1
        if vflip then row = h - 1 - row end
        local trow, inRow = floor(row / 8), row % 8
        for tcol = 0, w / 8 - 1 do
            local sx = x0 + (hflip and (w - 8 - tcol * 8) or tcol * 8)
            if sx > -8 and sx < 240 then
                if eight then
                    local t = (tile + trow * perRow + tcol * 2) % 1024
                    local b = 0x10000 + t * 32 + inRow * 8
                    for k = 0, 7 do
                        local x = sx + k
                        if x >= 0 and x < 240 then
                            local ci = vram[b + (hflip and (7 - k) or k)]
                            if ci ~= 0 then fb[o + x] = pal[pb + ci] end
                        end
                    end
                else
                    local t = (tile + trow * perRow + tcol) % 1024
                    local b = (0x10000 + t * 32 + inRow * 4) * 2
                    for k = 0, 7 do
                        local x = sx + k
                        if x >= 0 and x < 240 then
                            local ci = vnib[b + (hflip and (7 - k) or k)]
                            if ci ~= 0 then fb[o + x] = pal[pb + ci] end
                        end
                    end
                end
            end
        end
    end

    -- fading the whole picture toward white or black
    local fadeUp, fadeDown = {}, {}
    local function faded(c, level, up)
        local cache = up and fadeUp or fadeDown
        local t = cache[level]
        if not t then t = {} cache[level] = t end
        local v = t[c]
        if v then return v end
        local rr = c % 32
        local gg = floor(c / 32) % 32
        local bb = floor(c / 1024)
        if up then
            rr, gg, bb = rr + floor((31 - rr) * level / 16), gg + floor((31 - gg) * level / 16), bb + floor((31 - bb) * level / 16)
        else
            rr, gg, bb = rr - floor(rr * level / 16), gg - floor(gg * level / 16), bb - floor(bb * level / 16)
        end
        v = rr + gg * 32 + bb * 1024
        t[c] = v
        return v
    end

    -- ---- the careful way, for lines where layers are mixed or masked ----
    local scratch, top, topL, sec, secL, semi, mask = {}, {}, {}, {}, {}, {}, {}
    for x = 0, 239 do scratch[x], top[x], topL[x], sec[x], secL[x], semi[x], mask[x] = -1, 0, 5, 0, 5, false, 63 end
    local firstT, secondT = {}, {}
    local mixed, mixedFor, mixedN = {}, -1, 0
    local function mix(c1, c2, eva, evb)
        if mixedFor ~= eva * 32 + evb or mixedN > 30000 then mixed, mixedFor, mixedN = {}, eva * 32 + evb, 0 end
        local key = c1 * 32768 + c2
        local v = mixed[key]
        if v then return v end
        mixedN = mixedN + 1
        local r1, r2 = c1 % 32, c2 % 32
        local g1, g2 = floor(c1 / 32) % 32, floor(c2 / 32) % 32
        local b1, b2 = floor(c1 / 1024), floor(c2 / 1024)
        local rr, gg, bb = floor((r1 * eva + r2 * evb) / 16), floor((g1 * eva + g2 * evb) / 16), floor((b1 * eva + b2 * evb) / 16)
        if rr > 31 then rr = 31 end
        if gg > 31 then gg = 31 end
        if bb > 31 then bb = 31 end
        v = rr + gg * 32 + bb * 1024
        mixed[key] = v
        return v
    end
    local function span(v, limit)       -- a window's edges along one direction
        local a, b = floor(v / 256), v % 256
        if b > limit or a > b then b = limit end
        return a, b
    end
    -- who may draw where: fills mask[] for this line; returns true if some window takes a whole layer away
    local function masks(y, dispcnt, list, oneD)
        local layersOn = floor(dispcnt / 256) % 32
        local hides = false
        local windows = floor(dispcnt / 8192)
        do
            used.window = used.window + 1
            local winin, winout = io[0x48], io[0x4A]
            local outside = winout % 64
            for x = 0, 239 do mask[x] = outside end
            if windows >= 4 and list then
                local inside = floor(winout / 256) % 64
                for k = 1, #list do
                    local i = list[k]
                    if floor(oam[i * 4] / 1024) % 4 == 2 then
                        sprite(i, y, 0, oneD, scratch, pal)
                        local x0, x1 = sprX[i], sprX[i] + sprW[i] * 2 - 1
                        if x0 < 0 then x0 = 0 end
                        if x1 > 239 then x1 = 239 end
                        for x = x0, x1 do if scratch[x] >= 0 then mask[x] = inside scratch[x] = -1 end end
                    end
                end
            end
            for w = 1, 0, -1 do
                if floor(windows / POW[w]) % 2 == 1 then
                    local y1, y2 = span(io[0x44 + w * 2], 160)
                    if y >= y1 and y < y2 then
                        local x1, x2 = span(io[0x40 + w * 2], 240)
                        local inside = (w == 0) and (winin % 64) or (floor(winin / 256) % 64)
                        for x = x1, x2 - 1 do mask[x] = inside end
                    end
                end
            end
        end
        local last = -1                         -- does any rule actually in force take a layer away?
        for x = 0, 239 do
            local m = mask[x]
            if m ~= last then
                last = m
                if GBA.band(m % 32, layersOn) ~= layersOn then hides = true break end
            end
        end
        return hides
    end
    local function careful(y, o, dispcnt, list, oneD, masked)
        local mode = dispcnt % 8
        local back = pal[0]
        for x = 0, 239 do top[x], topL[x], sec[x], secL[x], semi[x] = back, 5, back, 5, false end
        local function lay(layer, x0, x1, see)
            local bitv = POW[layer]
            for x = x0, x1 do
                local c = scratch[x]
                if c >= 0 then
                    scratch[x] = -1
                    if not masked or floor(mask[x] / bitv) % 2 == 1 then
                        if layer ~= 4 or topL[x] ~= 4 then sec[x], secL[x] = top[x], topL[x] end
                        top[x], topL[x], semi[x] = c, layer, see
                    end
                end
            end
        end
        for prio = 3, 0, -1 do
            for n = 3, 0, -1 do
                if floor(dispcnt / POW[8 + n]) % 2 == 1 and io[8 + n * 2] % 4 == prio then
                    local drew = true
                    if mode == 0 then textBG(n, y, 0, scratch, pal)
                    elseif mode == 1 then
                        if n < 2 then textBG(n, y, 0, scratch, pal) elseif n == 2 then affineBG(2, y, 0, scratch, pal) else drew = false end
                    elseif mode == 2 then
                        if n >= 2 then affineBG(n, y, 0, scratch, pal) else drew = false end
                    elseif n == 2 then bitmapBG(mode, y, 0, scratch, pal, 0) else drew = false end
                    if drew then lay(n, 0, 239, false) end
                end
            end
            if list then
                for k = 1, #list do
                    local i = list[k]
                    local a0 = oam[i * 4]
                    local objMode = floor(a0 / 1024) % 4
                    if objMode ~= 2 and floor(oam[i * 4 + 2] / 1024) % 4 == prio then
                        sprite(i, y, 0, oneD, scratch, pal)
                        local x0, x1 = sprX[i], sprX[i] + sprW[i] * 2 - 1
                        if x0 < 0 then x0 = 0 end
                        if x1 > 239 then x1 = 239 end
                        lay(4, x0, x1, objMode == 1)
                    end
                end
            end
        end
        -- mixing
        local bld = io[0x50]
        local effect = floor(bld / 64) % 4
        for l = 0, 5 do
            firstT[l] = floor(bld / POW[l]) % 2 == 1
            secondT[l] = floor(bld / POW[8 + l]) % 2 == 1
        end
        local alpha = io[0x52]
        local eva, evb = alpha % 32, floor(alpha / 256) % 32
        if eva > 16 then eva = 16 end
        if evb > 16 then evb = 16 end
        local level = io[0x54] % 32
        if level > 16 then level = 16 end
        if effect ~= 0 then used.blend = used.blend + 1 end
        for x = 0, 239 do
            local c = top[x]
            if semi[x] and secondT[secL[x]] then c = mix(c, sec[x], eva, evb)
            elseif effect ~= 0 and (not masked or mask[x] >= 32) and firstT[topL[x]] then
                if effect == 1 then
                    if secondT[secL[x]] then c = mix(c, sec[x], eva, evb) end
                elseif level > 0 then c = faded(c, level, effect == 2) end
            end
            fb[o + x] = c
        end
    end

    -- ---- the middle way: layers mixed, but nothing masked off ----
    -- Where layers mix, every color is drawn with its layer's number tucked in above it
    -- (color + layer * 32768), so what lies under a mixing layer is known for free. Those tags are
    -- left in the finished picture: whoever shows it must take colors "mod 32768".
    -- A whole-layer fade toward white or black needs no tags at all: the layer is simply drawn
    -- with an already-faded set of colors.
    local palL, palLFor = {}, -1
    for l = 0, 4 do palL[l] = {} end
    local palF, palFFor = {}, ""
    local function layered(y, o, dispcnt, list, oneD, masked, effect)
        local mode = dispcnt % 8
        local bld = io[0x50]
        for l = 0, 5 do
            firstT[l] = floor(bld / POW[l]) % 2 == 1
            secondT[l] = floor(bld / POW[8 + l]) % 2 == 1
        end
        local alpha = io[0x52]
        local eva, evb = alpha % 32, floor(alpha / 256) % 32
        if eva > 16 then eva = 16 end
        if evb > 16 then evb = 16 end
        local level = io[0x54] % 32
        if level > 16 then level = 16 end
        if effect ~= 0 then used.blend = used.blend + 1 end
        local fading = effect >= 2 and level > 0
        local tagged = effect == 1 or (list and lineSpecial[y]) or (fading and masked)
        local pals, back = nil, pal[0]
        if tagged then
            if palLFor ~= S.palStamp then
                palLFor = S.palStamp
                for l = 0, 4 do
                    local t, add = palL[l], l * 32768
                    for i = 0, 511 do t[i] = pal[i] + add end
                end
            end
            pals = palL
            back = back + 163840
        elseif fading then
            local want = S.palStamp .. ":" .. level .. ":" .. effect
            if palFFor ~= want then
                palFFor = want
                for i = 0, 511 do palF[i] = faded(pal[i], level, effect == 2) end
            end
            if firstT[5] then back = palF[0] end
        end
        for p = o, o + 239 do fb[p] = back end
        for prio = 3, 0, -1 do
            for n = 3, 0, -1 do
                if floor(dispcnt / POW[8 + n]) % 2 == 1 and io[8 + n * 2] % 4 == prio then
                    local mixing = effect == 1 and firstT[n]
                    local buf, at = fb, o
                    if mixing then buf, at = scratch, 0 end
                    local p = pals and pals[n] or ((fading and firstT[n]) and palF or pal)
                    local drew = true
                    if mode == 0 then textBG(n, y, at, buf, p)
                    elseif mode == 1 then
                        if n < 2 then textBG(n, y, at, buf, p) elseif n == 2 then affineBG(2, y, at, buf, p) else drew = false end
                    elseif mode == 2 then
                        if n >= 2 then affineBG(n, y, at, buf, p) else drew = false end
                    elseif n == 2 then bitmapBG(mode, y, at, buf, p, tagged and 65536 or 0) else drew = false end
                    if mixing and drew then
                        local add = n * 32768
                        for x = 0, 239 do
                            local c = scratch[x]
                            if c >= 0 then
                                scratch[x] = -1
                                local u = fb[o + x]
                                local ul = floor(u / 32768)
                                if secondT[ul] and (not masked or mask[x] >= 32) then
                                    fb[o + x] = mix(c - add, u - ul * 32768, eva, evb) + add
                                else fb[o + x] = c end
                            end
                        end
                    end
                end
            end
            if list then
                local p = pals and pals[4] or ((fading and firstT[4]) and palF or pal)
                for k = 1, #list do
                    local i = list[k]
                    local objMode = floor(oam[i * 4] / 1024) % 4
                    if objMode ~= 2 and floor(oam[i * 4 + 2] / 1024) % 4 == prio then
                        if objMode == 1 or (effect == 1 and firstT[4]) then
                            sprite(i, y, 0, oneD, scratch, p)
                            local x0, x1 = sprX[i], sprX[i] + sprW[i] * 2 - 1
                            if x0 < 0 then x0 = 0 end
                            if x1 > 239 then x1 = 239 end
                            local forced = objMode == 1
                            for x = x0, x1 do
                                local c = scratch[x]
                                if c >= 0 then
                                    scratch[x] = -1
                                    local u = fb[o + x]
                                    local ul = floor(u / 32768)
                                    if secondT[ul] and (forced or not masked or mask[x] >= 32) then
                                        fb[o + x] = mix(c - 131072, u - ul * 32768, eva, evb) + 131072
                                    else fb[o + x] = c end
                                end
                            end
                        else sprite(i, y, o, oneD, fb, p) end
                    end
                end
            end
        end
        if fading and masked then
            local up = effect == 2
            for x = 0, 239 do
                if mask[x] >= 32 then
                    local v = fb[o + x]
                    local l = floor(v / 32768)
                    if firstT[l] then fb[o + x] = faded(v - l * 32768, level, up) end
                end
            end
        end
    end

    -- ---- has this line changed at all? ----
    -- Each line remembers when it was last drawn. If no control register, color or (relevant) sprite
    -- has changed since, and none of the map cells and tile pictures that show on it have been written
    -- to, the line on the screen is still right and is left alone. Speech boxes, menus and standing
    -- still all leave most lines untouched.
    local lineAt = zeros(160)
    S.lineAt = lineAt
    local lineDirty = {}
    for y = 1, 160 do lineDirty[y] = true end
    S.lineDirty = lineDirty
    -- (The newest change among the map cells and tile pictures that show on this line of background n
    -- is worked out once and kept, since eight lines share a row of tiles and most frames change nothing.)
    local tcAt, tcCnt, tcCol, tcNewest = {}, {}, {}, {}
    local function textClean(n, y, at)
        local cnt = io[8 + n * 2]
        local mapBase = (floor(cnt / 256) % 32) * 2048
        local size = floor(cnt / 16384)
        local wide, tall = size % 2 == 1, size >= 2
        local yy = (y + io[0x12 + n * 4]) % (tall and 512 or 256)
        local rowBase = mapBase + (floor(yy / 8) % 32) * 64
        if yy >= 256 then rowBase = rowBase + (wide and 4096 or 2048) end
        local col = floor(io[0x10 + n * 4] % 512 / 8)
        local key = rowBase / 64
        local stamp = S.vramAt + S.objAt        -- (a tile number can reach into the sprites' pictures)
        if tcAt[key] == stamp and tcCnt[key] == cnt and tcCol[key] == col then return tcNewest[key] <= at end
        local charCell = (floor(cnt / 4) % 4) * 512
        local eight = floor(cnt / 128) % 2 == 1
        local cell = rowBase / 32
        local newest = vstamp[cell]
        if vstamp[cell + 1] > newest then newest = vstamp[cell + 1] end
        if wide then
            if vstamp[cell + 64] > newest then newest = vstamp[cell + 64] end
            if vstamp[cell + 65] > newest then newest = vstamp[cell + 65] end
        end
        local cols = wide and 64 or 32
        for i = 0, 30 do
            local c = (col + i) % cols
            local mi = rowBase + (c % 32) * 2
            if c >= 32 then mi = mi + 2048 end
            local tile = (vram[mi] + vram[mi + 1] * 256) % 1024
            if eight then
                local q = charCell + tile * 2
                if vstamp[q] > newest then newest = vstamp[q] end
                if vstamp[q + 1] > newest then newest = vstamp[q + 1] end
            elseif vstamp[charCell + tile] > newest then newest = vstamp[charCell + tile] end
        end
        tcAt[key], tcCnt[key], tcCol[key], tcNewest[key] = stamp, cnt, col, newest
        return newest <= at
    end
    local function affineClean(n, y, at)
        local base = (n == 2) and 0x20 or 0x30
        if s16(io[base + 4]) ~= 0 or s16(io[base]) ~= 256 then return false end
        local cnt = io[8 + n * 2]
        local charCell = (floor(cnt / 4) % 4) * 512
        local mapBase = (floor(cnt / 256) % 32) * 2048
        local tiles = 16 * POW[floor(cnt / 16384)]
        local span = tiles * 8
        local wrap = floor(cnt / 8192) % 2 == 1
        local ty = floor(S.refY[n] / 256)
        if wrap then ty = ty % span elseif ty < 0 or ty >= span then return true end
        local mapRow = mapBase + floor(ty / 8) * tiles
        local first = floor(floor(S.refX[n] / 256) / 8)
        for i = 0, 30 do
            local tc = first + i
            if wrap then tc = tc % tiles end
            if tc >= 0 and tc < tiles then
                local mi = mapRow + tc
                if vstamp[(mi - mi % 32) / 32] > at then return false end
                local q = charCell + vram[mi] * 2
                if vstamp[q] > at or vstamp[q + 1] > at then return false end
            end
        end
        return true
    end
    local function stepRefs(mode)
        if mode >= 1 then
            S.refX[2] = S.refX[2] + s16(io[0x22])
            S.refY[2] = S.refY[2] + s16(io[0x26])
            S.refX[3] = S.refX[3] + s16(io[0x32])
            S.refY[3] = S.refY[3] + s16(io[0x36])
        end
    end

    -- ---- a picture that has only slid ----
    -- Walking scrolls every background by the same few dots, and then nearly every line of the new
    -- picture is a line of the old one, moved. Such a line is copied across instead of being built
    -- again from its tiles; only the thin strip that came into view at the side, and the places where
    -- a sprite was or now is, are drawn properly. The same goes for a picture that has not moved at
    -- all but whose sprites have: the line is kept and only those places are redone.
    -- For that, each line remembers how it was made: where the backgrounds were scrolled to (snap),
    -- which layers were on (kind; false if it was made any way but the plain one), where along it
    -- sprites were drawn (pairs of first and last dot), and which backgrounds were blank along it.
    local snap = { at = -1 }
    local function scrollNow()
        if snap.at ~= S.scrollAt then
            snap = { io[0x10] % 512, io[0x12] % 512, io[0x14] % 512, io[0x16] % 512, io[0x18] % 512, io[0x1A] % 512, io[0x1C] % 512, io[0x1E] % 512, at = S.scrollAt }
        end
        return snap
    end
    local lineSnap, lineKind, lineBlank, lineSp, lineSpN = {}, {}, {}, {}, {}
    for y = 0, 159 do lineKind[y], lineBlank[y], lineSp[y], lineSpN[y] = false, 0, {}, 0 end
    local function noteSprites(y, list)         -- where the sprites on this line are
        local t, n = lineSp[y], 0
        if list then
            for k = 1, #list do
                local i = list[k]
                local a, b = sprX[i], sprX[i] + sprBW[i] - 1
                if a < 0 then a = 0 end
                if b > 239 then b = 239 end
                if a <= b then t[n + 1], t[n + 2] = a, b n = n + 2 end
            end
        end
        lineSpN[y] = n
    end
    -- When the picture slides down, a line's source is a line above it, which this frame has
    -- already drawn over; so in such frames each line's old contents are put aside first.
    local FAR = 16                              -- the most a picture may slide and still be reused
    local stash, stRow, stEpoch, stAt, stKind, stBlank, stSnap, stSp, stSpN = {}, {}, {}, {}, {}, {}, {}, {}, {}
    for k = 0, FAR - 1 do
        local t = {}
        for x = 0, 239 do t[x] = 0 end
        stash[k], stRow[k], stEpoch[k], stSp[k], stSpN[k] = t, -1, -1, {}, 0
    end
    local function putAside(y, o, at, os)
        local k = y % FAR
        local t = stash[k]
        for x = 0, 239 do t[x] = fb[o + x] end
        stRow[k], stEpoch[k], stAt[k], stKind[k], stBlank[k], stSnap[k] = y, S.frameNo, at, lineKind[y], lineBlank[y], os
        local from, to, n = lineSp[y], stSp[k], lineSpN[y]
        for j = 1, n do to[j] = from[j] end
        stSpN[k] = n
    end
    local movedOs, movedCs, movedFor, movedX, movedY, movedSame, movedStill      -- (the last answer to "how far has it moved")
    local redo, MOST = {}, 150                  -- the stretches of a line to redo; beyond MOST dots, just draw the line
    local function slide(y, o, dispcnt, at, dx, dy, still, os, list, oneD)
        local s = y + dy
        if s < 0 or s > 159 then used.nRange = used.nRange + 1 return false end
        local src, so, sAt, sKind, sBlank, sSnap, sSp, sSpN
        if dy < 0 then
            local k = s % FAR
            if stRow[k] ~= s or stEpoch[k] ~= S.frameNo then used.nStash = used.nStash + 1 return false end
            src, so = stash[k], 0
            sAt, sKind, sBlank, sSnap, sSp, sSpN = stAt[k], stKind[k], stBlank[k], stSnap[k], stSp[k], stSpN[k]
        else
            src, so = fb, s * 240 + 1
            sAt, sKind, sBlank, sSnap, sSp, sSpN = lineAt[s], lineKind[s], lineBlank[s], lineSnap[s], lineSp[s], lineSpN[s]
            if dy == 0 then sAt = at end
        end
        if sSnap ~= os then used.nSnap = used.nSnap + 1 return false end
        if sKind ~= dispcnt then used.nKind = used.nKind + 1 return false end
        if sAt < S.ioAt or sAt < S.palAt then used.nOld = used.nOld + 1 return false end
        local stale = sAt < S.vramAt
        local blanks = 0
        for n = 0, 3 do
            if floor(dispcnt / POW[8 + n]) % 2 == 1 then
                local was = floor(sBlank / POW[n]) % 2 == 1
                if floor(still / POW[n]) % 2 == 1 then
                    -- a background that did not move with the rest must be blank here, both then and now
                    if not was or not blankNow(n, y) then used.nStill = used.nStill + 1 return false end
                    blanks = blanks + POW[n]
                elseif stale then
                    if not textClean(n, y, sAt) then used.nTiles = used.nTiles + 1 return false end
                    if blankNow(n, y) then blanks = blanks + POW[n] end
                elseif was then blanks = blanks + POW[n] end        -- (it moved, and nothing in it has changed: still blank)
            end
        end
        -- what must be drawn properly: the strip that came into view, where sprites were, where sprites are
        local n = 0
        if dx > 0 then redo[1], redo[2], n = 240 - dx, 239, 2
        elseif dx < 0 then redo[1], redo[2], n = 0, -dx - 1, 2 end
        for j = 1, sSpN, 2 do
            local a, b = sSp[j] - dx, sSp[j + 1] - dx
            if a < 0 then a = 0 end
            if b > 239 then b = 239 end
            if a <= b then redo[n + 1], redo[n + 2] = a, b n = n + 2 end
        end
        if list then
            for k = 1, #list do
                local i = list[k]
                local a, b = sprX[i], sprX[i] + sprBW[i] - 1
                if a < 0 then a = 0 end
                if b > 239 then b = 239 end
                if a <= b then redo[n + 1], redo[n + 2] = a, b n = n + 2 end
            end
        end
        if n > 2 then
            -- in order from the left, and run together where they touch
            for j = 3, n - 1, 2 do
                local a, b = redo[j], redo[j + 1]
                local q = j - 2
                while q >= 1 and redo[q] > a do
                    redo[q + 2], redo[q + 3] = redo[q], redo[q + 1]
                    q = q - 2
                end
                redo[q + 2], redo[q + 3] = a, b
            end
            local m = 2
            for j = 3, n - 1, 2 do
                if redo[j] <= redo[m] + 1 then
                    if redo[j + 1] > redo[m] then redo[m] = redo[j + 1] end
                else
                    redo[m + 1], redo[m + 2] = redo[j], redo[j + 1]
                    m = m + 2
                end
            end
            n = m
        end
        local total = 0
        for j = 1, n, 2 do total = total + redo[j + 1] - redo[j] + 1 end
        if total > MOST then used.nSprite = used.nSprite + 1 return false end
        -- the line itself, moved across
        if dx ~= 0 or dy ~= 0 then
            local d = so + dx - o                -- (from a dot of this line to the dot it comes from)
            if dx >= 0 then
                for p = o, o + 239 - dx do fb[p] = src[p + d] end
            elseif dy == 0 then
                for p = o + 239, o - dx, -1 do fb[p] = fb[p + dx] end
            else
                for p = o - dx, o + 239 do fb[p] = src[p + d] end
            end
        end
        if n > 0 then
            local back = pal[0]
            for j = 1, n, 2 do
                for p = o + redo[j], o + redo[j + 1] do fb[p] = back end
            end
            for prio = 3, 0, -1 do
                for bg = 3, 0, -1 do
                    if floor(dispcnt / POW[8 + bg]) % 2 == 1 and io[8 + bg * 2] % 4 == prio and floor(blanks / POW[bg]) % 2 == 0 then
                        for j = 1, n, 2 do textBG(bg, y, o, fb, pal, redo[j], redo[j + 1]) end
                    end
                end
                if list then
                    for k = 1, #list do
                        local i = list[k]
                        if floor(oam[i * 4 + 2] / 1024) % 4 == prio and floor(oam[i * 4] / 1024) % 4 ~= 2 then sprite(i, y, o, oneD, fb, pal) end
                    end
                end
            end
        end
        lineBlank[y] = blanks
        used.shifted = used.shifted + 1
        return true
    end

    function S.renderLine(y)
        local dispcnt = io[0]
        local o = y * 240 + 1
        if floor(dispcnt / 128) % 2 == 1 then               -- screen switched off: white
            if lineAt[y] < S.ioAt or S.ALWAYSDRAW then
                for p = o, o + 239 do fb[p] = 32767 end
                lineKind[y], lineSnap[y] = false, nil
                lineAt[y] = S.stampAll
                lineDirty[y + 1] = true
                S.changed = true
            end
            return
        end
        local mode = dispcnt % 8
        local objOn = floor(dispcnt / 4096) % 2 == 1
        local oneD = floor(dispcnt / 64) % 2 == 1
        if objOn and builtFor ~= S.oamStamp then
            builtFor = S.oamStamp
            buildSprites()
        end
        local list = objOn and lineSprites[y] or nil
        if list and #list == 0 then list = nil end
        local at = lineAt[y]
        do
            if at >= S.ioAt and at >= S.palAt and at >= S.scrollAt and not S.ALWAYSDRAW then
                local clean = true
                if objOn and (at < lineOamAt[y] or (list and at < S.objAt)) then clean = false end
                if clean and at < S.vramAt then
                    for n = 0, 3 do
                        if floor(dispcnt / POW[8 + n]) % 2 == 1 then
                            if mode == 0 or (mode == 1 and n < 2) then clean = textClean(n, y, at)
                            elseif (mode == 1 and n == 2) or (mode == 2 and n >= 2) then clean = affineClean(n, y, at)
                            elseif mode >= 3 and n == 2 then clean = false end
                            if not clean then break end
                        end
                    end
                end
                if clean then stepRefs(mode) return end
            end
            used.lines = used.lines + 1
            if at < S.ioAt then used.wIo = used.wIo + 1
            elseif at < S.scrollAt then used.wScroll = used.wScroll + 1
            elseif at < S.palAt then used.wPal = used.wPal + 1
            elseif objOn and at < lineOamAt[y] then used.wOam = used.wOam + 1
            elseif objOn and list and at < S.objAt then used.wObj = used.wObj + 1
            else used.wVram = used.wVram + 1 end
            lineAt[y] = S.stampAll
            lineDirty[y + 1] = true
            S.changed = true
        end
        -- Windows first. On most lines no window is in play, or the same rule holds right across
        -- the line; then it is just a matter of which layers are on and whether effects apply.
        local bld = io[0x50]
        local effect = floor(bld / 64) % 4
        local windows = floor(dispcnt / 8192)
        local masked = false
        if windows ~= 0 then
            used.window = used.window + 1
            -- Which rule holds on this line? A window that spans the whole line settles it by itself
            -- (the first window outranks the second, and both outrank the sprite-shaped one); a window
            -- that is on but empty on this line does not count.
            local m = io[0x4A] % 64                     -- the "outside every window" rule
            local settled = false
            for w = 0, 1 do
                local y1, y2 = span(io[0x44 + w * 2], 160)
                if not settled and not masked and floor(windows / POW[w]) % 2 == 1 and y >= y1 and y < y2 then
                    local x1, x2 = span(io[0x40 + w * 2], 240)
                    if x1 == 0 and x2 == 240 then
                        m = (w == 0) and (io[0x48] % 64) or (floor(io[0x48] / 256) % 64)
                        settled = true
                    elseif x1 < x2 and x1 < 240 then masked = true end
                end
            end
            if not settled and not masked and windows >= 4 and list and lineWinObj[y] then masked = true end
            if not masked then
                local on = GBA.band(floor(dispcnt / 256) % 32, m % 32)
                dispcnt = dispcnt - (floor(dispcnt / 256) % 32) * 256 + on * 256
                if m < 32 then effect = 0 end
                if on < 16 then list = nil end
            end
        end
        local careful1 = masked and masks(y, dispcnt, list, oneD)
        local mixes = false
        if effect == 1 then
            local alpha = io[0x52]
            if not (alpha % 32 >= 16 and floor(alpha / 256) % 32 == 0) and bld % 64 ~= 0 then mixes = true end
        elseif effect >= 2 and io[0x54] % 32 ~= 0 and bld % 64 ~= 0 then mixes = true end
        if list and lineSpecial[y] then mixes = true end
        if careful1 then
            used.careful = used.careful + 1
            careful(y, o, dispcnt, list, oneD, true)
            lineKind[y], lineSnap[y] = false, nil
        elseif mixes or masked then
            used.layered = used.layered + 1
            layered(y, o, dispcnt, list, oneD, masked, effect)
            lineKind[y], lineSnap[y] = false, nil
        elseif mode == 0 and not S.NOSLIDE then
            -- the plain way, all four backgrounds tiled: has the picture only slid (or not moved at all)
            -- since this line was made?
            local cs, os = scrollNow(), lineSnap[y]
            local slid = false
            if os and not S.ALWAYSDRAW then
                local dx, dy, same, moving, still = 0, 0, true, false, 0
                if os == movedOs and cs == movedCs and dispcnt == movedFor then
                    dx, dy, same, still = movedX, movedY, movedSame, movedStill
                elseif os ~= cs then
                    for n = 0, 3 do
                        if floor(dispcnt / POW[8 + n]) % 2 == 1 then
                            local mx = (cs[n * 2 + 1] - os[n * 2 + 1] + 256) % 512 - 256
                            local my = (cs[n * 2 + 2] - os[n * 2 + 2] + 256) % 512 - 256
                            if mx == 0 and my == 0 then still = still + POW[n]
                            elseif not moving then moving, dx, dy = true, mx, my
                            elseif mx ~= dx or my ~= dy then same = false end
                        end
                    end
                    if not moving then still = 0 end
                    movedOs, movedCs, movedFor, movedX, movedY, movedSame, movedStill = os, cs, dispcnt, dx, dy, same, still
                end
                if same and dx > -FAR and dx < FAR and dy > -FAR and dy < FAR then
                    if dy < 0 then putAside(y, o, at, os) end
                    slid = slide(y, o, dispcnt, at, dx, dy, still, os, list, oneD)
                else used.nMove = used.nMove + 1 end
            end
            if not slid then
                local back = pal[0]
                local blanks = 0
                for p = o, o + 239 do fb[p] = back end
                for prio = 3, 0, -1 do
                    for n = 3, 0, -1 do
                        if floor(dispcnt / POW[8 + n]) % 2 == 1 and io[8 + n * 2] % 4 == prio then
                            if textBG(n, y, o, fb, pal) then blanks = blanks + POW[n] end
                        end
                    end
                    if list then
                        for k = 1, #list do
                            local i = list[k]
                            if floor(oam[i * 4 + 2] / 1024) % 4 == prio and floor(oam[i * 4] / 1024) % 4 ~= 2 then sprite(i, y, o, oneD, fb, pal) end
                        end
                    end
                end
                lineBlank[y] = blanks
            end
            lineKind[y], lineSnap[y] = dispcnt, cs
            noteSprites(y, list)
        else
            lineKind[y], lineSnap[y] = false, nil
            local back = pal[0]
            for p = o, o + 239 do fb[p] = back end
            for prio = 3, 0, -1 do
                for n = 3, 0, -1 do
                    if floor(dispcnt / POW[8 + n]) % 2 == 1 and io[8 + n * 2] % 4 == prio then
                        if mode == 0 then textBG(n, y, o, fb, pal)
                        elseif mode == 1 then
                            if n < 2 then textBG(n, y, o, fb, pal) elseif n == 2 then affineBG(2, y, o, fb, pal) end
                        elseif mode == 2 then
                            if n >= 2 then affineBG(n, y, o, fb, pal) end
                        elseif n == 2 then bitmapBG(mode, y, o, fb, pal, 0) end
                    end
                end
                if list then
                    for k = 1, #list do
                        local i = list[k]
                        if floor(oam[i * 4 + 2] / 1024) % 4 == prio and floor(oam[i * 4] / 1024) % 4 ~= 2 then sprite(i, y, o, oneD, fb, pal) end
                    end
                end
            end
        end
        -- the turn-and-scale backgrounds step on by their per-line amounts
        stepRefs(mode)
    end
end

-- ------------------------------------------------------------------- the system ---
-- The control registers, the timers, the bulk-copy hardware, and what
-- happens when across one frame: 228 lines of 1,232 processor cycles each,
-- the first 160 of them drawn.
local function buildSystem(S)
    local io = zeros(0x400)
    S.io = io
    -- what the console's start-up code leaves in the scaling registers: "not scaled" (1.0), not zero
    io[0x20], io[0x26], io[0x30], io[0x36] = 0x100, 0x100, 0x100, 0x100
    io[0] = 0x80                -- the console's start-up program hands over with the screen switched off
    local r = S.r
    local rd16, rd32, wr16, wr32 = S.rd16, S.rd32, S.wr16, S.wr32
    local IE, IF, IME = 0, 0, 0
    local vcount, inVBlank, inHBlank = 0, false, false
    local keys = 0x3FF
    S.frameNo = 0

    -- timers: worked out from the clock when someone asks, with an alarm set only if one must interrupt
    local tReload, tCtl, tStart, tValue = { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }
    local PRESCALE = { [0] = 1, 64, 256, 1024 }
    local nextAlarm = math.huge
    local sioAt = math.huge         -- when a transfer this console started on the link port will be done
    local function timerNow(i)
        local ctl = tCtl[i]
        if ctl % 256 < 128 or floor(ctl / 4) % 2 == 1 then return tValue[i] end
        local total = tValue[i] + floor((S.cyc - tStart[i]) / PRESCALE[ctl % 4])
        if total < 65536 then return total end
        local span = 65536 - tReload[i]
        return tReload[i] + (total - 65536) % span
    end
    local function alarms()
        nextAlarm = math.huge
        for i = 0, 3 do
            local ctl = tCtl[i]
            if ctl % 256 >= 128 and floor(ctl / 64) % 2 == 1 and floor(ctl / 4) % 2 == 0 then
                local p = PRESCALE[ctl % 4]
                local at = tStart[i] + (65536 - tValue[i]) * p
                if at <= S.cyc then
                    local span = (65536 - tReload[i]) * p
                    at = at + (floor((S.cyc - at) / span) + 1) * span
                end
                if at < nextAlarm then nextAlarm = at end
            end
        end
        if sioAt < nextAlarm then nextAlarm = sioAt end
    end
    local sioDone
    local function timerFire()
        if sioAt <= S.cyc then sioDone() end
        for i = 0, 3 do
            local ctl = tCtl[i]
            if ctl % 256 >= 128 and floor(ctl / 64) % 2 == 1 and floor(ctl / 4) % 2 == 0 then
                local p = PRESCALE[ctl % 4]
                local first = tStart[i] + (65536 - tValue[i]) * p
                if first <= S.cyc then
                    IF = GBA.bor(IF, 8 * POW[i])
                    -- carry on from the reload value, as of the overflow
                    local span = (65536 - tReload[i]) * p
                    local over = S.cyc - first
                    tStart[i] = S.cyc - over % span
                    tValue[i] = tReload[i]
                end
            end
        end
        alarms()
    end

    -- the bulk-copy hardware
    local dSrc, dDst, dCnt, dOn = { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }, { [0] = false, false, false, false }
    local function dmaRun(i)
        local ctl = io[0xBA + i * 12]
        S.waitRAM = false               -- (a copy may have changed whatever a waiting game is watching)
        local count = dCnt[i]
        local wide = floor(ctl / 1024) % 2 == 1
        local step = wide and 4 or 2
        local dAdj, sAdj = floor(ctl / 32) % 4, floor(ctl / 128) % 4
        local ds = (dAdj == 0 or dAdj == 3) and step or (dAdj == 1 and -step or 0)
        local ss = (sAdj == 0) and step or (sAdj == 1 and -step or 0)
        local src, dst = dSrc[i], dDst[i]
        src, dst = src - src % step, dst - dst % step
        if ds == step and ss >= 0 and S.bulk(src, dst, count, wide, ss == 0) then
            src, dst = src + ss * count, dst + ds * count
        elseif wide then
            for _ = 1, count do wr32(dst, rd32(src)) src = src + ss dst = dst + ds end
        else
            for _ = 1, count do wr16(dst, rd16(src)) src = src + ss dst = dst + ds end
        end
        dSrc[i] = src
        if dAdj ~= 3 then dDst[i] = dst end
        if floor(ctl / 16384) % 2 == 1 then IF = GBA.bor(IF, 256 * POW[i]) end
        if floor(ctl / 512) % 2 == 0 or floor(ctl / 4096) % 4 == 0 then
            io[0xBA + i * 12] = ctl % 32768             -- finished: switch itself off
            dOn[i] = false
        else
            local c = io[0xB8 + i * 12]
            if c == 0 then c = (i == 3) and 65536 or 16384 end
            dCnt[i] = c
        end
    end
    local function dmaWhen(timing)
        for i = 0, 3 do
            if dOn[i] and floor(io[0xBA + i * 12] / 4096) % 4 == timing then dmaRun(i) end
        end
    end

    -- ------------------------------------------------------------- link port ---
    -- Only the mode the multi-player games use ("multi-player", up to four consoles
    -- each putting one 16-bit word on the line per transfer), and only with
    -- something plugged in: S.linkPlug{ parent = true|false, present = true|false,
    -- exchange = fn }. The parent console starts every transfer; when one of its
    -- transfers is done, exchange(word it sent) is asked for the other console's
    -- word. A child console is clocked from outside with S.linkClock(parent's word),
    -- which hands back the word the child had ready (nil if the game is not
    -- listening). Nothing plugged in: the port does nothing, as before.
    local link = nil
    local SIO_BUSY, SIO_IRQ = 128, 16384
    local function sioMulti() return floor(io[0x128] / 4096) % 4 == 2 end
    function S.linkPlug(t)
        link = t
        sioAt = math.huge
        alarms()
    end
    function S.linkListening()          -- has the game switched the port to multi-player mode, with its interrupt on?
        return sioMulti() and floor(io[0x128] / SIO_IRQ) % 2 == 1
    end
    sioDone = function()
        sioAt = math.huge
        local cnt = io[0x128]
        if not link or cnt % 256 < SIO_BUSY then return end
        local out = io[0x12A]
        local back = link.exchange(out)
        io[0x120], io[0x122], io[0x124], io[0x126] = out, back or 0xFFFF, 0xFFFF, 0xFFFF
        io[0x128] = cnt - SIO_BUSY
        if floor(cnt / SIO_IRQ) % 2 == 1 then IF = GBA.bor(IF, 128) end
    end
    function S.linkClock(word)
        if not sioMulti() then return nil end
        local cnt = io[0x128]
        local out = io[0x12A]
        io[0x120], io[0x122], io[0x124], io[0x126] = word, out, 0xFFFF, 0xFFFF
        if floor(cnt / SIO_IRQ) % 2 == 1 then IF = GBA.bor(IF, 128) S.stopAt = 0 end
        return out
    end

    local function ioRead(o)
        if o == 0x128 and link then
            -- what the plug says: which console we are (bits 4-5), whether every console is ready (bit 3),
            -- and whether we are a child (bit 2)
            local v = io[0x128]
            v = v - floor(v / 4) % 16 * 4
            if link.parent then return v + (link.present and 8 or 0) end
            return v + 4 + (link.present and 8 or 0) + 16
        end
        if o == 0x004 then
            local v = io[4]
            return v - v % 8 + (inVBlank and 1 or 0) + (inHBlank and 2 or 0) + ((vcount == floor(v / 256)) and 4 or 0)
        elseif o == 0x006 then return vcount
        elseif o == 0x130 then return keys
        elseif o == 0x200 then return IE
        elseif o == 0x202 then return IF
        elseif o == 0x208 then return IME
        elseif o >= 0x100 and o < 0x110 then
            local i = (o - 0x100 - o % 4) / 4
            if o % 4 == 0 then return timerNow(i) end
            return tCtl[i]
        end
        return io[o]
    end
    -- For the soundtrack recorder (a tool run outside the game client; nothing here runs unless
    -- S.listen is set). The console plays sound two ways. Recorded sound is fed to the speaker a byte
    -- at a time, at a rate set by a timer, from wherever the bulk-copy hardware is pointing; the
    -- listener is told which bytes those would have been (S.listen.fifo). The four tone and noise
    -- channels inherited from the Game Boy are driven through registers; the listener is told of
    -- every byte written to them (S.listen.psg).
    local aPtr, aLast, aFrac = { 0, 0 }, { 0, 0 }, { 0, 0 }
    local function soundFlush(i)
        local L = S.listen
        if not L then return end
        local now = S.cyc
        if dOn[i] and floor(io[0xBA + i * 12] / 4096) % 4 == 3 then
            local t = floor(io[0x82] / POW[(i == 1) and 10 or 14]) % 2
            local per = (65536 - tReload[t]) * PRESCALE[tCtl[t] % 4]
            if tCtl[t] % 256 >= 128 then
                local n = (now - aLast[i]) / per + aFrac[i]
                local whole = floor(n)
                aFrac[i] = n - whole
                if whole > 0 then
                    L.fifo(i, aPtr[i], whole, aLast[i], per)
                    aPtr[i] = aPtr[i] + whole
                end
            end
        end
        aLast[i] = now
    end
    function S.soundFlush() soundFlush(1) soundFlush(2) end
    local byteWrite = false
    local function ioWrite(o, v)
        if S.listen then
            if o >= 0x60 and o < 0xA0 and not byteWrite then
                S.listen.psg(o, v % 256, S.cyc)
                S.listen.psg(o + 1, floor(v / 256), S.cyc)
            elseif o == 0xC6 or o == 0xD2 then soundFlush((o - 0xBA) / 12) end
        end
        if o < 0x58 and io[o] ~= v and o ~= 4 then
            S.stampAll = S.stampAll + 1
            -- (how far the backgrounds are scrolled is kept apart from everything else: see the screen)
            if o >= 0x10 and o < 0x20 then S.scrollAt = S.stampAll else S.ioAt = S.stampAll end
        end
        if o == 0x000 then
            io[0] = v
            S.bitmapMode = v % 8 >= 3
        elseif o == 0x004 then
            io[4] = v - v % 8
        elseif o == 0x202 then
            IF = IF - GBA.band(IF, v)
        elseif o == 0x200 then IE = v % 16384 S.stopAt = 0
        elseif o == 0x208 then IME = v % 2 S.stopAt = 0
        elseif o >= 0x28 and o < 0x40 and o % 16 >= 8 then
            -- where a turn-and-scale background starts: takes effect at once
            io[o] = v
            local n = (o < 0x30) and 2 or 3
            local base = (n == 2) and 0x28 or 0x38
            local x = io[base] + io[base + 2] % 4096 * 65536
            local y = io[base + 4] + io[base + 6] % 4096 * 65536
            if x >= 134217728 then x = x - 268435456 end
            if y >= 134217728 then y = y - 268435456 end
            if o < base + 4 then S.refX[n] = x else S.refY[n] = y end
        elseif o == 0xBA or o == 0xC6 or o == 0xD2 or o == 0xDE then
            local i = (o - 0xBA) / 12
            local was = dOn[i]
            io[o] = v
            if v >= 32768 then
                if not was then
                    dOn[i] = true
                    local b = 0xB0 + i * 12
                    dSrc[i] = io[b] + io[b + 2] * 65536
                    dDst[i] = io[b + 4] + io[b + 6] * 65536
                    local c = io[b + 8]
                    if c == 0 then c = (i == 3) and 65536 or 16384 end
                    dCnt[i] = c
                    if i == 1 or i == 2 then aPtr[i], aFrac[i], aLast[i] = dSrc[i], 0, S.cyc end
                    if floor(v / 4096) % 4 == 0 then dmaRun(i) end
                end
            else dOn[i] = false end
        elseif o >= 0x100 and o < 0x110 then
            local i = (o - 0x100 - o % 4) / 4
            if o % 4 == 0 then tReload[i] = v
            else
                local wasOn = tCtl[i] % 256 >= 128
                local now = timerNow(i)
                tCtl[i] = v % 256
                if v % 256 >= 128 and not wasOn then tValue[i] = tReload[i] else tValue[i] = now end
                tStart[i] = S.cyc
                alarms()
                S.stopAt = 0
            end
        elseif o == 0x128 then
            local busy = floor(io[0x128] / SIO_BUSY) % 2 == 1
            io[o] = v
            if link and link.parent and link.present and sioMulti() and v % 256 >= SIO_BUSY then
                if not busy or sioAt == math.huge then
                    sioAt = S.cyc + 1100            -- (about the time four consoles' words take at 115,200 bits a second)
                    alarms()
                    S.stopAt = 0
                end
            elseif v % 256 >= SIO_BUSY and not (link and link.parent) then
                io[o] = v - SIO_BUSY                 -- only a parent can start a transfer
            end
        elseif o == 0x300 then
            io[o] = v % 256
            if v >= 256 then S.halted = true S.stopAt = 0 end   -- (16-bit write reaching the "stop until interrupt" byte)
        else
            io[o] = v
        end
    end
    function S.ioWrite8(o, v)
        if o == 0x301 then S.halted = true S.stopAt = 0 return end
        if o == 0x202 then ioWrite(0x202, v) return end
        if o == 0x203 then ioWrite(0x202, v * 256) return end
        local e = o - o % 2
        local old = ioRead(e)
        if S.listen and o >= 0x60 and o < 0xA0 then
            S.listen.psg(o, v, S.cyc)
            byteWrite = true
        end
        if o % 2 == 0 then ioWrite(e, old - old % 256 + v) else ioWrite(e, old % 256 + v * 256) end
        byteWrite = false
    end
    S.ioRead, S.ioWrite = ioRead, ioWrite
    S.setIO(ioRead, ioWrite)

    local band = GBA.band
    local function runTo(target)
        while S.cyc < target do
            if nextAlarm <= S.cyc then timerFire() end
            local pending = band(IE, IF) ~= 0
            if pending then
                S.halted = false
                if IME == 1 and S.irqsAllowed() then S.interrupt() end
            end
            if S.halted or S.waitRAM then
                -- nothing to do until something happens: skip ahead
                local to = target
                if nextAlarm < to then to = nextAlarm end
                S.idle = S.idle + (to - S.cyc)
                S.cyc = to
            else
                local to = target
                if nextAlarm < to then to = nextAlarm end
                if to <= S.cyc then to = S.cyc + 1 end
                S.runCPU(to)
            end
        end
    end

    -- The music engine nearly every GBA game uses mixes a few hundred sound samples every frame, in
    -- software, and that is a large share of what the processor does. Nothing here can play them, so
    -- the engine is told to mix only a handful. Its sequencing (which games do wait on) runs as normal.
    local function quietMixer()
        local p = rd32(0x03007FF0)
        if p < 0x02000000 or p >= 0x04000000 then return end
        if rd32(p) ~= 0x68736D53 then return end
        if rd32(p + 16) > 16 then wr32(p + 16, 16) S.mixerQuieted = true end
    end

    S.idle = 0
    function S.runFrame(render)
        S.frameNo = S.frameNo + 1
        local base = S.cyc
        local renderLine = S.renderLine
        S.changed = false               -- (the painter sets this when it has had to redraw a line)
        for line = 0, 227 do
            vcount = line
            local stat = io[4]
            if line == floor(stat / 256) and floor(stat / 32) % 2 == 1 then IF = GBA.bor(IF, 4) end
            if line == 160 then
                inVBlank = true
                if floor(stat / 8) % 2 == 1 then IF = GBA.bor(IF, 1) end
                dmaWhen(1)
                if not S.LOUDMIXER then quietMixer() end
            elseif line == 227 then inVBlank = false
            elseif line == 0 then
                -- the turn-and-scale backgrounds go back to their starting points
                for n = 2, 3 do
                    local b = (n == 2) and 0x28 or 0x38
                    local x = io[b] + io[b + 2] % 4096 * 65536
                    local y = io[b + 4] + io[b + 6] % 4096 * 65536
                    if x >= 134217728 then x = x - 268435456 end
                    if y >= 134217728 then y = y - 268435456 end
                    S.refX[n], S.refY[n] = x, y
                end
            end
            if link and link.line then link.line(line) end
            inHBlank = false
            local lineStart = base + line * 1232
            runTo(lineStart + 960)
            if line < 160 and render then renderLine(line) end
            inHBlank = true
            if floor(io[4] / 16) % 2 == 1 then IF = GBA.bor(IF, 2) end
            if line < 160 then dmaWhen(2) end
            runTo(lineStart + 1232)
        end
        if S.listen then S.soundFlush() end
    end

    function S.setKey(name, down)
        local bitOf = { a = 1, b = 2, select = 4, start = 8, right = 16, left = 32, up = 64, down = 128, r = 256, l = 512 }
        local b = bitOf[name]
        if not b then return end
        local isUp = floor(keys / b) % 2 == 1
        if down and isUp then keys = keys - b elseif not down and not isUp then keys = keys + b end
    end
    function S.softReset()
        S.resetCPU(134217728)
        S.resetBIOS()
    end
    function S.debug()
        return { IE = IE, IF = IF, IME = IME, vcount = vcount, dispcnt = io[0], halted = S.halted }
    end
    -- for memory valves
    local function four(t) return { t[0], t[1], t[2], t[3] } end
    local function unfour(t, from, bool)
        for i = 0, 3 do
            if bool then t[i] = from[i + 1] and true or false else t[i] = from[i + 1] end
        end
    end
    function S.sysSave()
        local regs = {}
        for o = 0, 0x3FE, 2 do regs[o / 2 + 1] = io[o] end
        return { io = regs, IE = IE, IF = IF, IME = IME, vcount = vcount, inVBlank = inVBlank, inHBlank = inHBlank, frameNo = S.frameNo,
                 tReload = four(tReload), tCtl = four(tCtl), tStart = four(tStart), tValue = four(tValue),
                 dSrc = four(dSrc), dDst = four(dDst), dCnt = four(dCnt), dOn = four(dOn),
                 aPtr = { aPtr[1], aPtr[2] }, aLast = { aLast[1], aLast[2] }, aFrac = { aFrac[1], aFrac[2] },
                 refX = { S.refX[2], S.refX[3] }, refY = { S.refY[2], S.refY[3] }, mixerQuieted = S.mixerQuieted and true or false }
    end
    function S.sysLoad(t)
        for o = 0, 0x3FE, 2 do io[o] = t.io[o / 2 + 1] or 0 end
        IE, IF, IME = t.IE, t.IF, t.IME
        vcount, inVBlank, inHBlank = t.vcount, t.inVBlank and true or false, t.inHBlank and true or false
        S.frameNo = t.frameNo
        unfour(tReload, t.tReload) unfour(tCtl, t.tCtl) unfour(tStart, t.tStart) unfour(tValue, t.tValue)
        unfour(dSrc, t.dSrc) unfour(dDst, t.dDst) unfour(dCnt, t.dCnt) unfour(dOn, t.dOn, true)
        for i = 1, 2 do aPtr[i], aLast[i], aFrac[i] = t.aPtr[i], t.aLast[i], t.aFrac[i] end
        S.refX[2], S.refX[3], S.refY[2], S.refY[3] = t.refX[1], t.refX[2], t.refY[1], t.refY[2]
        S.mixerQuieted = t.mixerQuieted and true or false
        S.bitmapMode = io[0] % 8 >= 3
        keys = 0x3FF                    -- (no button is held in a photograph: whoever loads it presses their own)
        sioAt = math.huge
        alarms()
    end
end

-- ------------------------------------------------- a photograph of the machine ---
-- Everything needed to put the machine back exactly as it stands between two
-- frames: memory, the processor, the timers, the save chip. The big tables
-- are packed as text that a settings file can hold: hex, with the long blank
-- runs counted rather than spelled out (most of a console's memory is blank,
-- so a photograph comes to about a tenth of a megabyte). Translated code is
-- not included (see the processor).
local PACK = {}
do
    local TOHEX, FROMHEX = {}, {}
    for i = 0, 255 do
        local hx = ("%02x"):format(i)
        TOHEX[char(i)] = hx
        FROMHEX[hx] = char(i)
    end
    function PACK.text(bin)
        local hex = bin:gsub(".", TOHEX)
        hex = hex:gsub("0000000000000000+", function(run) return "g" .. #run .. "g" end)
        hex = hex:gsub("ffffffffffffffff+", function(run) return "h" .. #run .. "h" end)
        return "x" .. hex
    end
    function PACK.bin(text)
        if type(text) ~= "string" then return nil, "the save is incomplete" end
        if text:sub(1, 1) ~= "x" then return nil, "the save was made by a newer MekkaBoy" end
        local body = text:sub(2)
        body = body:gsub("g(%d+)g", function(n) return ("0"):rep(tonumber(n)) end)
        body = body:gsub("h(%d+)h", function(n) return ("f"):rep(tonumber(n)) end)
        if #body % 2 ~= 0 or body:find("[^0-9a-f]") then return nil, "the save is damaged" end
        return (body:gsub("%x%x", FROMHEX))
    end
    -- tables of numbers <-> binary strings
    function PACK.words(t, n)               -- 32-bit, t[0..n-1]
        local out, k = {}, 0
        for i = 0, n - 1, 4 do
            local a, b, c, d = t[i], t[i + 1], t[i + 2], t[i + 3]
            local a0, b0, c0, d0 = a % 256, b % 256, c % 256, d % 256
            local a1, b1, c1, d1 = (a - a0) / 256 % 256, (b - b0) / 256 % 256, (c - c0) / 256 % 256, (d - d0) / 256 % 256
            local a2, b2, c2, d2 = floor(a / 65536) % 256, floor(b / 65536) % 256, floor(c / 65536) % 256, floor(d / 65536) % 256
            k = k + 1
            out[k] = char(a0, a1, a2, floor(a / 16777216) % 256, b0, b1, b2, floor(b / 16777216) % 256,
                          c0, c1, c2, floor(c / 16777216) % 256, d0, d1, d2, floor(d / 16777216) % 256)
        end
        return concat(out)
    end
    function PACK.unwords(t, n, s)
        for i = 0, n - 1, 4 do
            local p = i * 4
            local a0, a1, a2, a3, b0, b1, b2, b3, c0, c1, c2, c3, d0, d1, d2, d3 = byte(s, p + 1, p + 16)
            t[i], t[i + 1] = a0 + a1 * 256 + a2 * 65536 + a3 * 16777216, b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
            t[i + 2], t[i + 3] = c0 + c1 * 256 + c2 * 65536 + c3 * 16777216, d0 + d1 * 256 + d2 * 65536 + d3 * 16777216
        end
    end
    function PACK.halves(t, n)              -- 16-bit, t[0..n-1]
        local out, k = {}, 0
        for i = 0, n - 1, 8 do
            local piece = {}
            for j = 0, 7 do
                local v = t[i + j]
                piece[j * 2 + 1], piece[j * 2 + 2] = v % 256, floor(v / 256) % 256
            end
            k = k + 1
            out[k] = char(unpack(piece))
        end
        return concat(out)
    end
    function PACK.unhalves(t, n, s)
        for i = 0, n - 1 do
            local lo, hi = byte(s, i * 2 + 1, i * 2 + 2)
            t[i] = lo + hi * 256
        end
    end
    function PACK.bytes(t, n)               -- t[0..n-1]
        local out, k = {}, 0
        for i = 0, n - 1, 128 do
            k = k + 1
            out[k] = char(unpack(t, i, i + 127))
        end
        return concat(out)
    end
    function PACK.unbytes(t, n, s)
        for i = 0, n - 1, 16 do
            t[i], t[i + 1], t[i + 2], t[i + 3], t[i + 4], t[i + 5], t[i + 6], t[i + 7],
            t[i + 8], t[i + 9], t[i + 10], t[i + 11], t[i + 12], t[i + 13], t[i + 14], t[i + 15] = byte(s, i + 1, i + 16)
        end
    end
end
GBA.PACK = PACK

local BIG = {   -- name, table on S, entries, bytes each, pack, unpack
    { "ew", "ew", 65536, 4, PACK.words, PACK.unwords }, { "iw", "iw", 8192, 4, PACK.words, PACK.unwords },
    { "vram", "vram", 0x18000, 1, PACK.bytes, PACK.unbytes }, { "pal", "palRaw", 512, 2, PACK.halves, PACK.unhalves },
    { "oam", "oam", 512, 2, PACK.halves, PACK.unhalves }, { "flash", "flash", 131072, 1, PACK.bytes, PACK.unbytes },
}
-- a short fingerprint of the game's code (its first 16K and its size): a resume point from a different build is no use
local function romStampOf(S)
    local stamp
    return function()
        if stamp then return stamp end
        local bank = S.romBanks[1] or ""
        local sum = 0
        for i = 1, #bank, 61 do sum = (sum * 31 + bank:byte(i)) % 1000000007 end
        stamp = tostring(S.romSize) .. ":" .. tostring(#bank) .. ":" .. tostring(sum)
        return stamp
    end
end
local function buildState(S)
    S.romStamp = romStampOf(S)
    function S.saveState()
        local st = { v = 1, kind = "gba", rom = S.romStamp(), cpu = S.cpuSave(), bus = S.busSave(), sys = S.sysSave(), bios = S.biosSave(), m = {} }
        for _, b in ipairs(BIG) do st.m[b[1]] = PACK.text(b[5](S[b[2]], b[3])) end
        return st
    end
    -- false and a reason if the photograph cannot be used; the machine is only touched once all of it has been read
    function S.loadState(st)
        if type(st) ~= "table" or st.v ~= 1 or st.kind ~= "gba" or type(st.m) ~= "table" then return false, "not a save for this kind of game" end
        for _, part in ipairs({ "cpu", "bus", "sys", "bios" }) do
            if type(st[part]) ~= "table" then return false, "the save is incomplete" end
        end
        if type(st.cpu.r) ~= "table" or #st.cpu.r ~= 16 or type(st.sys.io) ~= "table" or type(st.bus.cTime) ~= "table" then return false, "the save is incomplete" end
        if st.rom and st.rom ~= S.romStamp() then return false, "the game has changed since this resume point was kept" end
        -- (our own cartridges change build by build; one of theirs kept before resume points carried a stamp may be from any build)
        if not st.rom and (S.romBanks[1] or ""):sub(0xAD, 0xAE) == "MB" then return false, "the game has changed since this resume point was kept" end
        local bins = {}
        for _, b in ipairs(BIG) do
            local bin, why = PACK.bin(st.m[b[1]])
            if not bin then return false, why end
            if #bin ~= b[3] * b[4] then return false, "the save is damaged" end
            bins[b[1]] = bin
        end
        for _, b in ipairs(BIG) do b[6](S[b[2]], b[3], bins[b[1]]) end
        S.cpuLoad(st.cpu)
        S.biosLoad(st.bios)
        S.sysLoad(st.sys)
        S.busLoad(st.bus)           -- (last: it also tells the screen that everything has changed)
        return true
    end
end

-- opts.bank(n) -> the n-th 16K piece of the game (n from 0), opts.size = bytes in the game
function GBA.new(opts)
    local S = { romSize = opts.size, bankSize = opts.bankSize or 16384 }
    local banks = {}
    S.romBanks = setmetatable(banks, { __index = function(t, k)
        local s = opts.bank(k - 1)
        t[k] = s
        return s
    end })
    for k, v in pairs(opts.debug or {}) do S[k] = v end
    S.clock = opts.clock            -- (returns the time of day as a table, the way os.date("*t") does)
    S.chip = opts.chip              -- (which save chip the cartridge carries: nil = 128K flash, "flash64")
    buildBus(S)
    if opts.save then S.loadSave(opts.save) end
    buildSystem(S)          -- (makes S.io, which the screen reads)
    buildCPU(S)
    buildBIOS(S)
    buildPPU(S)
    buildState(S)
    S.softReset()
    return S
end

return GBA
