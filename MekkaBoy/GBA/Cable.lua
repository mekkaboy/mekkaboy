-- The Advance link cable: a stand-in for the other player's console.
--
-- Two Game Boy Advances on a real cable swap nine words sixty times a second.
-- Two MekkaBoys can pass about one chat message a second, so, as on the Game
-- Boy side (GB/Cable.lua), each game is plugged into a stand-in instead. The
-- stand-in answers the game's link port at full speed and tells the other
-- stand-in only what matters.
--
-- Unlike the Game Boy games, the Advance Pokemon games all talk through one
-- shared piece of link code, and that code tolerates a slow partner: every
-- frame each console sends a packet of eight words, an all-zero packet means
-- "nothing to say", and whatever is said is acted on when it arrives. So this
-- stand-in needs to know nothing about trades or battles. It forwards each
-- packet that says something, keeps the spacing between them, and fills the
-- silence with empty packets.
--
-- One console is the "parent" (it starts every transfer) and the other the
-- "child". The player who typed /mb link first has the parent.
--
-- The games open and close the link several times in one visit (once to
-- meet, again for each trade screen or battle), and with messages taking
-- their time, each stand-in hears of the other's comings and goings late.
-- So both count the links they have finished (the "round"), and every
-- message says which round it belongs to: news from a link already left
-- behind is not mistaken for news about the next one.
--
-- The games are patient about most things but not about meeting: after
-- opening a link they give the other console only a few seconds to answer
-- before showing an error that can only be cleared by switching off. On a
-- slow chat line that is not always enough. So while a game is waiting for
-- that first answer, the stand-in asks for the game itself to be held still
-- (see Ghost:waiting): its clock does not run, and nothing times out.
local _, MB = ...

local Cable = {}
MB.AdvanceCable = Cable

local char, byte, concat = string.char, string.byte, table.concat
local floor = math.floor

local HELLO, GO = 0xB9A0, 0x8FFF     -- what the games say while counting consoles, and the parent's "everyone is here"
local KEYS, NO_KEY = 0xCAFE, 0x11    -- "the buttons I am holding", sent every frame in a link room; 0x11 = none
local LONGEST = 16                   -- frames of one repeated packet sent as a single message
local FIRST_LINE, EVERY = 4, 12      -- a child's nine transfers a frame happen on these screen lines
local SETTLED = 20                   -- frames of silence from our game before it counts as waiting for an answer
local SOON = 900                     -- frames after one link closes in which the next is expected to open
local HOLD_FOR = 20                  -- seconds a game may be held still at one go

-- The games that share the link code this stand-in understands, by the code in the cartridge header.
local GAMES = {
    AXVE = "gen3",      -- Pokemon Ruby
    AXPE = "gen3",      -- Pokemon Sapphire
    BPEE = "gen3",      -- Pokemon Emerald
    BPRE = "gen3",      -- Pokemon FireRed
    BPGE = "gen3",      -- Pokemon LeafGreen
}

local function codeOf(m)
    local t = {}
    for i = 0, 3 do t[i + 1] = char(m.rd8(0x080000AC + i)) end
    return concat(t)
end

-- MekkaBoy's own games (games/gba) do not use the link port at all: they keep a mailbox in working memory
-- (+0 "MBLK", +4 status, +5 outSeq, +6 outLen, +7 outAck, +8 inSeq, +9 inLen, +10 inAck, +12 out, +76 in) and
-- the stand-in carries each message as it is, in order. Any such game counts as one family: "native".
local LINKBOX, LINK_MAX = 0x03007E10, 64
local function isNative(m)
    return codeOf(m):sub(1, 2) == "MB" and m.rd32(LINKBOX) == 0x4B4C424D
end

-- "gen3", "native", or nil if this game's link is not supported
function Cable.Family(m)
    if not (m and m.linkPlug and m.rd8) then return nil end
    if isNative(m) then return "native" end
    return GAMES[codeOf(m)]
end
-- A native game may ask for a table of more than two (the mailbox's +141: players wanted, 0 = an ordinary
-- two-player link). The host of such a table links with up to players-1 guests, all talking only to it.
function Cable.Seats(m)
    if Cable.Family(m) ~= "native" then return 0 end
    local n = m.rd8(LINKBOX + 141)
    if n < 3 or n > 5 then return 0 end
    return n
end
function Cable.Code(m) return (m and m.rd8) and codeOf(m) or "" end

local Ghost = {}
Ghost.__index = Ghost

local function reset(g)
    g.idx = 0                       -- which of a frame's nine transfers is next
    g.cur = { 0, 0, 0, 0, 0, 0, 0, 0 }
    g.feed = nil                    -- the other player's packet being handed to the game this frame
    g.run, g.runCount, g.runGap = nil, 0, 0      -- packets going out: one being repeated
    g.quiet = 0                     -- frames since our game last said anything
    g.rx, g.rxHead, g.rxTail = {}, 1, 0      -- packets that have arrived: { gap, count, words }
    g.playing, g.playLeft = nil, 0
    g.since = 255                   -- frames since the other player's last packet was handed over
    g.sent, g.got = 0, 0
    g.hellos = 0
end

function Ghost:tx(kind, rest)
    self.send(kind .. (rest or ""))
end

-- ----------------------------------------------------------- our packets ---
local function flush(g)
    if not g.run then return end
    local w = g.run
    local mask, t = 0, {}
    for i = 1, 8 do
        if w[i] ~= 0 then
            mask = mask + 2 ^ (i - 1)
            t[#t + 1] = char(w[i] % 256, floor(w[i] / 256))
        end
    end
    g:tx("D", char(g.round % 250 + 1, g.runGap, g.runCount, mask) .. concat(t))
    g.sent = g.sent + 1
    g.run, g.runCount = nil, 0
end

-- the game here has finished a frame's packet
local function said(g)
    local c = g.cur
    local idle = true
    for i = 1, 8 do if c[i] ~= 0 then idle = false break end end
    if not idle and c[1] == KEYS and c[2] == NO_KEY then
        -- "holding nothing" is as good as silence to the other game
        idle = true
        for i = 3, 8 do if c[i] ~= 0 then idle = false break end end
    end
    if idle then
        local had = g.run
        flush(g)
        -- (the game has stopped talking: what it said goes now, not after the wire's short wait for more. In a
        -- battle every step waits for the other side's answer, so each hop saved is felt)
        if had and g.hurry then g.hurry() end
        if g.quiet < 255 then g.quiet = g.quiet + 1 end
        return
    end
    local r = g.run
    if r and g.runCount < LONGEST and r[1] == c[1] and r[2] == c[2] and r[3] == c[3] and r[4] == c[4]
        and r[5] == c[5] and r[6] == c[6] and r[7] == c[7] and r[8] == c[8] then
        g.runCount = g.runCount + 1
    else
        flush(g)
        g.run, g.runCount, g.runGap = { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8] }, 1, g.quiet
    end
    g.quiet = 0
end

-- ------------------------------------------------- the other player's packets ---
local EMPTY = { 0, 0, 0, 0, 0, 0, 0, 0 }

-- choose what the game here is handed this frame
local function nextFeed(g)
    if g.playLeft > 0 then
        g.playLeft = g.playLeft - 1
        g.since = 0
        g.feed = g.playing
        return
    end
    local head = g.rx[g.rxHead]
    if head and g.since >= head.gap then
        g.rx[g.rxHead] = nil
        g.rxHead = g.rxHead + 1
        g.playing, g.playLeft = head.words, head.count - 1
        g.since = 0
        g.feed = head.words
        g.got = g.got + 1
        return
    end
    if g.since < 255 then g.since = g.since + 1 end
    g.feed = EMPTY
end

-- One transfer in the middle of a link: `out` is the word the game here put on the line.
-- Returns the word the other console puts on it.
local function dataWord(g, out)
    local i = g.idx
    local back
    if i == 0 then
        -- the first word of a frame is each console's sum of the last frame; they must agree, and they do
        back = out
        nextFeed(g)
    else
        g.cur[i] = out
        back = g.feed[i]
    end
    if i == 8 then
        g.idx = 0
        said(g)
    else
        g.idx = i + 1
    end
    return back
end

-- --------------------------------------------------------------- the plug ---
local function announce(g)
    g:tx("P", (g.localOn and "1" or "0") .. char(g.round % 250 + 1))
end

local function phaseTo(g, phase)
    if g.phase == phase then return end
    local was = g.phase
    g.phase = phase
    if was == "data" then
        flush(g)
        g.round = g.round + 1           -- one more link finished
        g.closedAt = g.frame
    end
    if phase == "hand" then reset(g) end
    if g.note then
        if phase == "data" then g.note("joined") elseif was == "data" then g.note("closed") end
    end
end

-- is the other game there, for the link this game is about to make (not one it has already left)?
local function partnerThere(g)
    return g.remoteOn and g.remoteRound >= g.round
end

-- once a frame: is the game here using the link port at all?
local function poll(g)
    g.frame = g.frame + 1
    local on = g.m.linkListening()
    if on ~= g.localOn then
        g.localOn = on
        g.openedAt = g.frame
        phaseTo(g, on and "hand" or "off")
        announce(g)
    end
end

local function attachParent(g)
    local plug = { parent = true, present = true }
    g.plug = plug
    function plug.exchange(out)
        if g.phase == "data" then return dataWord(g, out) end
        if g.phase ~= "hand" then return nil end
        if not partnerThere(g) then return nil end
        if out == GO then
            -- our player has confirmed the link: from the next transfer on, packets
            g:tx("G", char(g.round % 250 + 1))
            phaseTo(g, "data")
            g.idx = 0
        end
        return HELLO
    end
    function plug.line(line)
        if line == 0 then poll(g) end
    end
end

local function attachChild(g)
    local plug = { parent = false, present = true }
    g.plug = plug
    local m = g.m
    function plug.line(line)
        if line == 0 then poll(g) return end
        local k = line - FIRST_LINE
        if k < 0 or k % EVERY ~= 0 or k > 8 * EVERY then return end
        if g.phase == "data" then
            -- (the sum that opens a frame is echoed: see dataWord)
            local word = (g.idx == 0) and m.io[0x12A] or g.feed[g.idx]
            local out = m.linkClock(word)
            if out then dataWord(g, out) end
        elseif g.phase == "hand" then
            -- (the game takes the parent's "everyone is here" only after it has counted the consoles
            -- the same way twice running, so it must have had a few plain greetings first)
            if g.go == g.round and g.hellos >= 3 then
                if m.linkClock(GO) then
                    g.go = nil
                    phaseTo(g, "data")
                    g.idx = 0
                end
            elseif g.go == g.round or partnerThere(g) then
                if m.linkClock(HELLO) then g.hellos = g.hellos + 1 end
            end
        end
    end
end

-- ------------------------------------------------------------- messages ---
-- the other stand-in is in a later round than ours: a link we never joined has come and gone
local function catchUp(g, round)
    if g.phase == "data" or round <= g.round then return end
    g.round = round
    g.go = nil
    announce(g)
end

local function roundOf(g, b)
    -- rounds go round after 250: take the one nearest ours
    local r = (b or 1) - 1
    local base = g.round - g.round % 250
    local best = base + r
    if best - g.round > 125 then best = best - 250 elseif g.round - best > 125 then best = best + 250 end
    return best
end

function Ghost:receive(msg)
    local kind = msg:sub(1, 1)
    if kind == "P" then
        local on = msg:sub(2, 2) == "1"
        local round = roundOf(self, byte(msg, 3))
        local was = self.remoteOn
        self.remoteOn, self.remoteRound = on, round
        catchUp(self, round)
        if on ~= was and self.note then self.note(on and "there" or "away") end
    elseif kind == "G" then
        if self.host then return end
        local round = roundOf(self, byte(msg, 2))
        catchUp(self, round)
        if round == self.round then self.go = round end
    elseif kind == "D" then
        local round = roundOf(self, byte(msg, 2))
        local gap, count, mask = byte(msg, 3), byte(msg, 4), byte(msg, 5)
        if not mask or round ~= self.round then return end     -- (left over from a link this game has already closed)
        local w, at = {}, 6
        for i = 1, 8 do
            if mask % 2 == 1 then
                w[i] = (byte(msg, at) or 0) + (byte(msg, at + 1) or 0) * 256
                at = at + 2
            else
                w[i] = 0
            end
            mask = floor(mask / 2)
        end
        self.rxTail = self.rxTail + 1
        self.rx[self.rxTail] = { gap = gap, count = count, words = w }
    end
end

-- Should the game be held still for now? True while it has opened a link and is waiting for the
-- other console's first answer, which the games allow only a few seconds for. `now` is the time in
-- seconds. Whoever runs the game asks this before each frame, and skips the frame on true.
function Ghost:waiting(now)
    -- (the other player's game has stopped: this one waits for it, however long, rather than carry on alone; the
    -- link decides when it has waited long enough, GB/Link.lua)
    if self.partnerAway and (self.phase == "data" or self.phase == "hand") then return true end
    local want = false
    if self.phase == "data" then
        -- joined, said its piece, and nothing has come back yet
        want = self.rxTail == 0 and self.quiet >= SETTLED
    elseif self.phase == "hand" and self.closedAt and self.frame - self.closedAt < SOON
        and self.frame - self.openedAt >= SETTLED then
        -- opening the next link of a visit (a trade screen, a battle): the other game is not there yet
        if self.host then want = not (self.remoteOn and self.remoteRound >= self.round)
        else want = self.go ~= self.round end
    end
    if not want then
        self.heldSince = nil
        return false
    end
    self.heldSince = self.heldSince or now
    if now - self.heldSince > HOLD_FOR then return false end     -- long enough: let the game decide for itself
    return true
end

-- true while the two games are in a link session
function Ghost:busy() return self.phase == "data" end
function Ghost:blocksKey() return false end

function Ghost:detach()
    if self.localOn then
        self.localOn = false
        announce(self)
    end
    self.m.linkPlug(nil)
end

-- ------------------------------------------------- the stand-in for MekkaBoy's own games ---
-- At a table of more than two, the host's stand-in is plugged into every guest at once: each message the game
-- sends names a seat (+11: 1..4 one guest, anything else everyone), and each message handed in says which seat
-- it came from (+140). The status byte carries this console's seat (bits 2-4) and +142 the seats now linked.
local Native = {}
Native.__index = Native
function Native:tx(kind, rest, to) self.send(kind .. (rest or ""), to) end
local function nativeStatus(g)
    local m = g.m
    m.wr8(LINKBOX + 4, 1 + (g.host and 2 or 0) + 4 * (g.seat or 0))
    m.wr8(LINKBOX + 142, g.mask or 1)
end
local function nativePoll(g)
    local m = g.m
    if m.rd32(LINKBOX) ~= 0x4B4C424D then return end
    if g.seats then nativeStatus(g) end
    -- something to send?
    local outSeq, outAck = m.rd8(LINKBOX + 5), m.rd8(LINKBOX + 7)
    if outSeq ~= outAck then
        local len = m.rd8(LINKBOX + 6)
        local t = {}
        for i = 0, len - 1 do t[i + 1] = char(m.rd8(LINKBOX + 12 + i)) end
        local to = m.rd8(LINKBOX + 11)
        if to < 1 or to > 4 then to = nil end
        g:tx("N", concat(t), to)
        m.wr8(LINKBOX + 7, outSeq)
        g.sent = g.sent + 1
    end
    -- room for the next message that has arrived?
    local inSeq, inAck = m.rd8(LINKBOX + 8), m.rd8(LINKBOX + 10)
    if inSeq == inAck and g.rxHead <= g.rxTail then
        local msg, from = g.rx[g.rxHead], g.fromOf[g.rxHead] or 0
        g.rx[g.rxHead], g.fromOf[g.rxHead] = nil, nil
        g.rxHead = g.rxHead + 1
        for i = 1, #msg do m.wr8(LINKBOX + 12 + LINK_MAX + i - 1, byte(msg, i)) end
        m.wr8(LINKBOX + 140, from)
        m.wr8(LINKBOX + 9, #msg)
        m.wr8(LINKBOX + 8, (inSeq + 1) % 256)
        g.got = g.got + 1
    end
end
-- from: the seat the message came from (the host's stand-in knows; a guest's hears only the host, seat 0)
function Native:receive(msg, from)
    local kind, rest = msg:sub(1, 1), msg:sub(2)
    if kind == "N" then
        if #rest > LINK_MAX then rest = rest:sub(1, LINK_MAX) end
        self.rxTail = self.rxTail + 1
        self.rx[self.rxTail] = rest
        self.fromOf[self.rxTail] = from or 0
    elseif kind == "H" then
        if not self.saidJoined then self.saidJoined = true if self.note then self.note("joined") end end
    end
end
function Native:busy() return true end
function Native:blocksKey() return false end
function Native:detach()
    self.m.wr8(LINKBOX + 4, 0)
    if self.seats then self.m.wr8(LINKBOX + 142, 0) end
    self.m.linkPlug(nil)
end
-- a table's seats changed (the host: a guest came or went); mask has bit 0 for the host and bit k for seat k
function Native:setMembers(mask)
    self.mask = mask
    if self.m.rd32(LINKBOX) == 0x4B4C424D then nativeStatus(self) end
end
local function attachNative(m, opts)
    local g = setmetatable({ m = m, host = opts.host and true or false, send = opts.send, note = opts.note, phase = "data",
                             round = 0, epoch = 0, rx = {}, fromOf = {}, rxHead = 1, rxTail = 0, sent = 0, got = 0,
                             seats = opts.seats, seat = opts.seat or 0, mask = opts.members }, Native)
    g.plug = { parent = g.host, present = true, exchange = function() return nil end,
               line = function(line) if line == 0 then nativePoll(g) end end }
    if g.seats then nativeStatus(g) else m.wr8(LINKBOX + 4, 1 + (g.host and 2 or 0)) end
    m.linkPlug(g.plug)
    g:tx("H")
    return g
end

-- Plug a stand-in into machine m.
--   opts.host    true for the player whose console is the parent
--   opts.send    function(message) carries a message to the other stand-in, in order and intact
--   opts.note    function(what) optional: "there", "away", "joined", "closed"
--   opts.round   optional: the last stand-in's .round, when a game is plugged in again mid-session
--   (a table of more than two, native games only:) opts.seats players at the table, opts.seat this console's seat
--                (0 = the host), opts.members the bit mask of seats linked; opts.send(message, seat) where seat is
--                1..4 for one guest or nil for everyone (a guest's messages always go to the host)
-- Returns the stand-in, or nil if this game's link is not supported.
function Cable.Attach(m, opts)
    local fam = Cable.Family(m)
    if not fam then return nil end
    if fam == "native" then return attachNative(m, opts) end
    local g = setmetatable({ m = m, host = opts.host and true or false, send = opts.send, note = opts.note, hurry = opts.hurry,
                             phase = "off", localOn = false, remoteOn = false, round = opts.round or 0, remoteRound = 0, frame = 0, openedAt = 0 }, Ghost)
    reset(g)
    if g.host then attachParent(g) else attachChild(g) end
    m.linkPlug(g.plug)
    announce(g)
    return g
end
