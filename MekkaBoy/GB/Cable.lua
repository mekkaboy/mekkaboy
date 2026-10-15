-- The link cable, part two: the stand-in.
--
-- Two Game Boys on a real cable swap a byte every few thousandths of a
-- second. Two MekkaBoys can only pass about one chat message a second, so a
-- live cable is out of the question. Instead each MekkaBoy plugs its game
-- into a stand-in for the other player. The stand-in answers the game's link
-- port at full speed, and the two stand-ins tell each other, in a handful of
-- messages, the few things that actually matter: who leads, which room was
-- picked, each player's party, each choice.
--
-- It knows where a game is in its conversation by watching the game's own
-- link routines (the same trick the sound driver uses), so it only works for
-- games listed in GAMES below. This file knows nothing about chat: whoever
-- attaches a stand-in gives it a function that carries a message across.
local _, MB = ...

local Cable = {}
MB.Cable = Cable

local char, byte, sub = string.char, string.byte, string.sub

local FRAME = 70224            -- CPU cycles in one video frame
local BLOCK_GAP = 6000         -- cycles between bytes when we drive the clock through a block

-- Pokemon Red and Blue (the two share every address below).
local GEN1 = {
    family = "gen1",
    status = 0xFFAA,           -- hSerialConnectionStatus: 0xFF none, 1 follows the clock, 2 leads it
    nybble = 0xCC42,           -- wSerialExchangeNybbleSendData
    counter = 0xCC47,          -- wUnknownSerialCounter: the "closed because of inactivity" countdown
    -- { bank, address } of places in the game's link code
    sync = { 0x00, 0x227F },        -- Serial_SyncAndExchangeNybble
    syncEnd = { 0x00, 0x22B3 },     --   .loop3
    bytes = { 0x00, 0x216F },       -- Serial_ExchangeBytes
    menu = { 0x01, 0x5C52 },        -- LinkMenu.waitForInputLoop
    menuEnd = { 0x01, 0x5CA1 },     -- LinkMenu.doneChoosingMenuSelection
    battle = { 0x0F, 0x563B },      -- LinkBattleExchangeData.syncLoop1
    battleEnd = { 0x0F, 0x5654 },   --   .syncLoop3
    close = { 0x01, 0x72D7 },       -- CloseLinkConnection
}

-- Pokemon Yellow: the same conversation and the same memory, with the code in other places.
local YELLOW = {
    family = "gen1",
    status = 0xFFAA, nybble = 0xCC42, counter = 0xCC47,
    sync = { 0x00, 0x20DB }, syncEnd = { 0x00, 0x210F },
    bytes = { 0x00, 0x1FCB },
    menu = { 0x3D, 0x5855 }, menuEnd = { 0x3D, 0x58B4 },
    battle = { 0x0F, 0x57AD }, battleEnd = { 0x0F, 0x57C6 },
    close = { 0x01, 0x71AC },
}

-- Pokemon Gold and Silver (the two share every address below). The second
-- generation talks the same way with a few more steps: each player picks a
-- room with their own receptionist, and a trade also swaps the mail.
local GEN2 = {
    family = "gen2",
    status = 0xFFCD,           -- hSerialConnectionStatus
    action = 0xCE56,           -- wPlayerLinkAction
    timeout = 0xCE5B,          -- wLinkTimeoutFrames: counts down while waiting for the other player
    byteTimeout = 0xCE5D,      -- wLinkByteTimeout: counts down while waiting for one byte
    sync = { 0x00, 0x082E },        -- WaitLinkTransfer
    syncEnd = { 0x00, 0x0862 },     --   .acknowledge
    bytes = { 0x00, 0x0710 },       -- Serial_ExchangeBytes
    raw = { 0x0A, 0x4380 },         -- ExchangeBytes (the mail: no opening byte to wait for)
    room = { 0x0A, 0x5D1E },        -- Link_EnsureSync
    roomEnd = { 0x0A, 0x5D47 },     --   .done
    battle = { 0x0F, 0x6728 },      -- LinkBattleSendReceiveAction.waiting
    battleEnd = { 0x0F, 0x6741 },   --   .acknowledge
    close = { 0x0A, 0x5AD9 },       -- WaitForOtherPlayerToExit
    close2 = { 0x0A, 0x5D0B },      -- Link_ResetSerialRegistersAfterLinkClosure
}

-- Pokemon Crystal, version 1.1
local CRYSTAL = {
    family = "gen2",
    status = 0xFFCB, action = 0xCF56, timeout = 0xCF5B, byteTimeout = 0xCF5D,
    sync = { 0x00, 0x087D }, syncEnd = { 0x00, 0x08B1 },
    bytes = { 0x00, 0x075F }, raw = { 0x0A, 0x43F2 },
    room = { 0x0A, 0x5F17 }, roomEnd = { 0x0A, 0x5F40 },
    battle = { 0x40, 0x4A5E }, battleEnd = { 0x40, 0x4A77 },
    close = { 0x0A, 0x5C92 }, close2 = { 0x0A, 0x5F04 },
}

-- The games the link knows, by the ROM's own checksum (header bytes 0x14E and 0x14F). That number
-- alone says little (a modified game usually keeps it), and the stand-in leans on the exact places
-- of the game's link routines. So each entry also carries a fingerprint of the code at every one of
-- those places, and a copy whose code is different is turned away.
local HOOKS = { "sync", "syncEnd", "bytes", "raw", "menu", "menuEnd", "room", "roomEnd", "battle", "battleEnd", "close", "close2" }
local GAMES = {
    [0x91E6] = { GEN1, 0x4225AB },        -- Pokemon Red (USA, Europe)
    [0x9D0A] = { GEN1, 0x4225AB },        -- Pokemon Blue (USA, Europe)
    [0x047C] = { YELLOW, 0x62FEAE },      -- Pokemon Yellow (USA, Europe)
    [0x682D] = { GEN2, 0xF5A62E },        -- Pokemon Gold (USA, Europe)
    [0x0DAE] = { GEN2, 0xF5A62E },        -- Pokemon Silver (USA, Europe)
    [0x18D2] = { CRYSTAL, 0x7D15F8 },     -- Pokemon Crystal (USA, Europe), version 1.1
}

local function fingerprint(m, p)
    local h = 0
    for _, k in ipairs(HOOKS) do
        local at = p[k]
        if at then
            for i = 0, 31 do h = (h * 257 + m.peekRom(at[1], at[2] + i)) % 16777213 end
        end
    end
    return h
end

-- the profile for the game in machine m; or nil, and true if the game is one we know but changed
local checked = setmetatable({}, { __mode = "k" })
local function profileOf(m)
    local c = checked[m]
    if c == nil then
        local e = GAMES[m.peek(0x14E) * 256 + m.peek(0x14F)]
        if not e then c = { false, false }
        elseif m.peekRom and fingerprint(m, e[1]) == e[2] then c = { e[1], false }
        else c = { false, true } end
        checked[m] = c
    end
    return c[1] or nil, c[2]
end

-- true if this is a game the link knows by name, but not this copy of it (another version, or modified)
function Cable.Changed(m)
    if not (m and m.peek) then return false end
    local _, changed = profileOf(m)
    return changed
end

-- "gen1" or "gen2", or nil if this game's link is not supported
function Cable.Family(m)
    local p = m and m.peek and profileOf(m)
    return p and p.family
end

-- Can a game of one family link with a game of another? Within a generation
-- always; across the first two, through the second generation's Time Capsule.
-- (The Advance games, "gen3", only link with each other, as on real hardware.)
function Cable.Compatible(a, b)
    if not (a and b) then return false end
    if a == b then return true end
    return (a == "gen1" and b == "gen2") or (a == "gen2" and b == "gen1")
end

local Ghost = {}
Ghost.__index = Ghost

local function clear(g)
    g.k, g.j = 0, 0                 -- how many syncs and blocks this session has seen
    g.phase = "idle"
    g.rN, g.rB, g.rM = {}, {}, nil  -- what the other side has told us: nybbles, blocks, menu choice
    g.dq, g.dp = nil, 0             -- a block being fed to the game
    g.zeros = 0
    g.sentM = false
end

function Ghost:tx(kind, rest)
    self.send(kind .. char(self.epoch) .. (rest or ""))
end

-- keep the game's "inactivity" countdown from running out while the other player catches up
function Ghost:hold()
    if self.phase ~= "sync" or self.rN[self.k % 256] then return end
    local m, at = self.m, self.p.counter or self.p.timeout
    local hi, lo = m.peek(at), m.peek(at + 1)
    if (hi ~= 0 or lo ~= 0) and not (hi == 255 and lo == 255) then
        m.poke(at, 3)
        m.poke(at + 1, 0)
    end
end

-- the same for the second generation's wait for a single byte
function Ghost:holdByte()
    local at = self.p.byteTimeout
    if at then self.m.poke(at + 1, 0x50) end
end

-- the kind of exchange the game is in shows in the top half of the byte it sends
local function prefixOf(g, v)
    if v >= 0x60 and v < 0x90 then g.prefix = v - v % 16 end
    return g.prefix
end

function Ghost:nextBlockByte()
    if not self.dq then
        local d = self.rB[self.j % 256]
        if not d then return nil end
        self.rB[self.j % 256] = nil
        if #d ~= self.blockLen then          -- should never happen between two sound games
            d = (d .. char(0):rep(self.blockLen)):sub(1, self.blockLen)
            self.note("The two games disagree about what they are swapping.")
        end
        -- the game throws the first byte away: a mark that the other end has begun
        self.dq, self.dp = char(self.rawBlock and 0 or 0xFD) .. d, 0
    end
    self.dp = self.dp + 1
    local v = byte(self.dq, self.dp)
    if self.dp >= #self.dq then
        self.dq = nil
        self.phase = "idle"
    end
    return v
end

-- The game here is leading the clock and has just sent `out`. What comes back?
function Ghost:onClock(out)
    local m, p = self.m, self.p
    if not self.established then
        if out == 0x01 and m.peek(p.status) == 0xFF then
            if self.host then
                -- our player has asked the attendant for a link: they lead
                self.epoch = self.epoch % 250 + 1
                clear(self)
                self.established = true
                self:tx("E")
                self.note("lead")
                return 0x02
            elseif self.gotE and p.family == "gen2" then
                -- a second-generation game takes turns offering to lead and to follow;
                -- the other player leads already, so answer its offer to lead with "follow me"
                self.established = true
                self.note("follow")
                return 0x01
            end
        end
        return nil
    end
    self:hold()
    local ph = self.phase
    if ph == "sync" then
        local n = self.rN[self.k % 256]
        local pre = prefixOf(self, out)
        if n and out >= 0x60 and out < 0x90 then return pre + n end
        return 0
    elseif ph == "menu" then
        if self.mixed then return self.rM or 0xD0 end        -- the Time Capsule's side picks the room
        if out >= 0xD0 and out <= 0xDF and out % 16 >= 4 and not self.sentM then
            self.sentM = true
            self:tx("M", char(out))
        end
        return 0xD0
    elseif ph == "room" then
        return self.rM or (self.mixed and 0xD0) or 0
    elseif ph == "block" then
        if self.rawBlock and not (self.dq or self.rB[self.j % 256]) then
            self:holdByte()
            return false                 -- not a byte until the other player's mail is here
        end
        return self:nextBlockByte() or 0
    end
    return 0
end

-- The game here is waiting for the other end's clock, with `sb` ready to go.
-- Return a byte to hand it, or nil for "not now".
function Ghost:onWait(sb)
    local m, p = self.m, self.p
    local now = m.clock()
    if not self.established then
        if self.host or not self.gotE then return nil end
        local st = m.peek(p.status)
        if st == 0x01 then
            self.established = true
            self.note("follow")
        elseif st == 0xFF and sb == 0x02 then
            return 0x01              -- "I lead": the game answers by following
        else
            return nil
        end
    end
    self:hold()
    local ph = self.phase
    local since = now - self.last
    if since < 0 then since = FRAME end       -- the clock went backwards: a state was loaded
    if ph == "sync" then
        local n = self.rN[self.k % 256]
        local pre = prefixOf(self, sb)
        if not n or since < FRAME then return nil end
        self.last = now
        return pre + n
    elseif ph == "zeros" then
        if self.zeros <= 0 or since < FRAME then return nil end
        self.zeros = self.zeros - 1
        self.last = now
        return 0
    elseif ph == "menu" then
        if since < FRAME then return nil end
        self.last = now
        return self.rM or 0xD0
    elseif ph == "room" then
        local v = self.rM or (self.mixed and 0xD0)
        if not v or since < BLOCK_GAP then return nil end
        self.last = now
        return v
    elseif ph == "block" then
        if self.dq or self.rB[self.j % 256] then
            if since < BLOCK_GAP then return nil end
            self.last = now
            return self:nextBlockByte()
        end
        if self.rawBlock then                  -- nothing may arrive before the mail itself
            self:holdByte()
            return nil
        end
        if since < FRAME then return nil end   -- keep the game from giving up while the block is on its way
        self.last = now
        return 0
    end
    return nil
end

-- ------------------------------------------- watching the game's routines ---
local function startSync(g)
    g.k = g.k + 1
    g.phase = "sync"
    g:tx("N", char(g.k % 256, g.m.peek(g.p.nybble or g.p.action) % 16))
end

local function close(g)
    g.established = false
    g.gotE = false
    clear(g)
    g:tx("X")
    g.note("closed")
end

local function endSync(g)
    if g.phase ~= "sync" then return end
    g.rN[g.k % 256] = nil
    g.phase = "zeros"
    g.zeros = 3
end

local function watch(g)
    local m, p = g.m, g.p
    local function at(where, fn)
        return { bank = where[1], addr = where[2], fn = function(a, b, c, d, e, h, l)
            if g.established then fn(a, b, c, d, e, h, l) end
        end }
    end
    local function block(raw)
        return function(_, b, c, _, _, h, l)
            local from, n = h * 256 + l, b * 256 + c
            local t = {}
            for i = 0, n - 1 do t[i + 1] = char(m.peek(from + i)) end
            g.j = g.j + 1
            g.phase = "block"
            g.blockLen = n
            g.rawBlock = raw
            g.dq = nil
            g:tx("B", char(g.j % 256) .. table.concat(t))
        end
    end
    local list = {
        at(p.sync, function() startSync(g) end),
        at(p.syncEnd, function() endSync(g) end),
        at(p.battle, function() if g.phase ~= "sync" then startSync(g) end end),
        at(p.battleEnd, function() endSync(g) end),
        at(p.bytes, block(false)),
        at(p.close, function() close(g) end),
    }
    if p.menu then
        -- first generation: one menu, and the leader's choice of room counts for both
        list[#list + 1] = at(p.menu, function()
            if g.phase ~= "menu" then
                g.phase = "menu"
                g.sentM = false
                g.note(g.mixed and "capsule" or "room")
            end
        end)
        list[#list + 1] = at(p.menuEnd, function()
            g.phase = "idle"
            g.rM = nil
        end)
    end
    if p.room then
        -- second generation: each player has told a receptionist which room; the games compare
        list[#list + 1] = at(p.room, function(a)
            g.phase = "room"
            g:tx("M", char(0xD0 + a % 16))
        end)
        list[#list + 1] = at(p.roomEnd, function()
            g.phase = "idle"
            g.rM = nil
        end)
        list[#list + 1] = at(p.raw, block(true))
        list[#list + 1] = at(p.close2, function() close(g) end)
    end
    return list
end

-- ------------------------------------------------------------- messages ---
function Ghost:receive(msg)
    local kind, epoch = sub(msg, 1, 1), byte(msg, 2)
    if not epoch then return end
    if kind == "E" then
        if self.host then return end
        self.epoch = epoch
        self.gotE = true
        self.established = false
        clear(self)
        self.note("invited")
        return
    end
    if epoch ~= self.epoch then return end
    if kind == "N" then
        self.rN[byte(msg, 3)] = byte(msg, 4) % 16
    elseif kind == "M" then
        self.rM = byte(msg, 3)
    elseif kind == "B" then
        self.rB[byte(msg, 3)] = sub(msg, 4)
    elseif kind == "X" then
        local was = self.established
        self.established = false
        self.gotE = false
        if was then
            if self.phase == "idle" or self.phase == "zeros" then self.m.poke(self.p.status, 0xFF) end
            self.note("left")
        end
        clear(self)
    end
end

-- a button the player may not press just now (the leader picks the room; with
-- a Time Capsule on the other end, the player there does)
function Ghost:blocksKey(name)
    return (self.mixed or not self.host) and self.established and self.phase == "menu" and (name == "a" or name == "b")
end

-- true while the two games are in a link session (no rewinding or loading states then)
function Ghost:busy() return self.established end

function Ghost:detach()
    local m = self.m
    if self.established then self:tx("X") end
    self.established = false
    if m.setBreakpoints then m.setBreakpoints(nil, "cable") end
    if m.linkCable then m.linkCable(nil) end
    if m.linkClock then m.linkClock(nil) end
end

-- Plug a stand-in into machine m.
--   opts.host    true for the player who leads (talks to the attendant first)
--   opts.send    function(message) carries a message to the other stand-in, in order and intact
--   opts.note    function(what) optional: "lead", "invited", "follow", "room", "capsule", "closed", "left", or a sentence
--   opts.epoch   optional: the last stand-in's .epoch, when a game is plugged in again mid-session
--   opts.peer    optional: the other game's family, when it is not the same as this one's
-- Returns the stand-in, or nil if this game's link is not supported.
function Cable.Attach(m, opts)
    local p = m and m.linkClock and profileOf(m)
    if not p then return nil end
    local g = setmetatable({ m = m, p = p, host = opts.host and true or false, send = opts.send,
                             note = opts.note or function() end,
                             epoch = opts.epoch or 0, established = false, gotE = false, last = 0, prefix = 0x60,
                             mixed = (opts.peer ~= nil and opts.peer ~= p.family) }, Ghost)
    clear(g)
    if m.peek(p.status) ~= 0xFF then m.poke(p.status, 0xFF) end   -- left over from an older session
    if g.epoch > 0 then g:tx("X") end     -- a game plugged in again mid-session: the other end starts afresh too
    m.setBreakpoints(watch(g), "cable")
    m.linkCable(function(out) return g:onClock(out) end)
    m.linkClock(function(sb) return g:onWait(sb) end)
    return g
end
