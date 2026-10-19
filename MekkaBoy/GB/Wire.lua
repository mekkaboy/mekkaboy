-- The link cable, part three: the wire.
--
-- Chat between addons is a poor wire. A message holds 255 bytes and no zero
-- bytes; the server passes roughly one a second after a short burst and
-- silently throws away the rest; nothing says whether a message arrived.
-- This file turns that into what the stand-ins (GB/Cable.lua) need: messages
-- of any size and any bytes, delivered whole, once, and in order.
--
-- It does so the usual way: number every frame, have the other end say how
-- far it has got, send again what goes unanswered, and never send faster
-- than the server allows. It knows nothing about the game or about chat:
-- whoever makes a wire hands it a function that sends one frame and feeds
-- it the frames that arrive.
--
-- The server counts messages separately for each addon name ("prefix") they
-- are sent under, so a wire may be given several lanes: the same frames,
-- shared out over a few names, each kept within its own allowance. A lane
-- the server pushes back on rests for a moment while the others carry on,
-- so if it turns out to count them all together, the wire simply slows to
-- what one lane would carry.
local _, MB = ...

local Wire = {}
MB.Wire = Wire
Wire.__index = Wire

local char, byte, sub, concat = string.char, string.byte, string.sub, table.concat
local floor = math.floor

local SEQS = 250               -- frame numbers go round after this many
local WINDOW = 16              -- frames that may be out and unanswered at once
local BURST = 8                -- frames we may send in a rush (the server allows about 10)
local REFILL = 1.1             -- seconds to earn back one frame of that allowance
local LINGER = 0.06            -- wait this long for more to say before sending a part-full frame
local RESEND = 3               -- seconds before sending an unanswered frame again
local ACK_WAIT = 0.4           -- say "got it" on its own if we have nothing else to send by then
local GIVE_UP = 10             -- sends of one frame before deciding the other end is gone
local NO_DATA = 251            -- frame number of a frame that only says "got it"

-- Any bytes -> bytes with no zeros and no "|" (chat's own escape character,
-- avoided to be safe): a run of n zeros (n <= 250, never 124) becomes 255, n;
-- a 255 becomes 255, 255; a "|" becomes 255, 254. Takes as much of raw (from
-- `from`) as fits in `room` bytes; returns the packed text and where it stopped.
local function pack(raw, from, room)
    local out, n, i, len = {}, 0, from, #raw
    while i <= len and n < room do
        local b = byte(raw, i)
        if b == 0 then
            if n + 2 > room then break end
            local run = 1
            while run < 250 and byte(raw, i + run) == 0 do run = run + 1 end
            if run == 124 then run = 123 end
            out[#out + 1] = char(255, run)
            n, i = n + 2, i + run
        elseif b == 255 or b == 124 then
            if n + 2 > room then break end
            out[#out + 1] = (b == 255) and "\255\255" or "\255\254"
            n, i = n + 2, i + 1
        else
            -- a stretch of ordinary bytes goes across as it is
            local j = i
            while j < len and n + (j - i + 1) < room do
                local nb = byte(raw, j + 1)
                if nb == 0 or nb == 255 or nb == 124 then break end
                j = j + 1
            end
            out[#out + 1] = sub(raw, i, j)
            n, i = n + (j - i + 1), j + 1
        end
    end
    return concat(out), i
end

local function unpack_(text)
    local out, i, len = {}, 1, #text
    while i <= len do
        local b = byte(text, i)
        if b == 255 then
            local n = byte(text, i + 1) or 255
            out[#out + 1] = (n == 255) and "\255" or (n == 254) and "|" or char(0):rep(n)
            i = i + 2
        else
            local j = i
            while j < len and byte(text, j + 1) ~= 255 do j = j + 1 end
            out[#out + 1] = sub(text, i, j)
            i = j + 1
        end
    end
    return concat(out)
end
Wire.pack, Wire.unpack = pack, unpack_

-- opts.send(frame, lane) -> true if the frame was handed to the server
-- opts.lanes   optional: how many lanes send() can use (default 1)
-- opts.deliver(message)   a whole message from the other end
-- opts.now() -> seconds
-- opts.id   1..250: marks the frames this end sends
-- opts.peer  1..250: the mark on the other end's frames (anything else is ignored,
--            including our own frames when the channel echoes them back to us)
-- opts.room  optional: bytes a frame may hold (default 255)
-- opts.lost()   optional: the other end has stopped answering
-- opts.share  optional: lanes from Wire.Lanes, shared with other wires this end runs at the same time (a table's
--             host has one wire per guest, and the server counts all of them together)
function Wire.Lanes(n, now)
    local t = {}
    for i = 1, n or 1 do t[i] = { tokens = BURST, tokenAt = now(), holdUntil = 0 } end
    return t
end
function Wire.New(opts)
    local w = setmetatable({
        send = opts.send, deliver = opts.deliver, now = opts.now, id = opts.id, peer = opts.peer or opts.id, lost = opts.lost,
        room = (opts.room or 255) - 3,
        out = "", outAt = nil,          -- bytes not yet framed, and when the oldest was queued
        sent = {}, base = 0, next = 0,  -- frames out: sent[seq] = { text, at, tries }; base = oldest unanswered
        want = 0, early = {},           -- next frame number we expect; frames that came ahead of it
        inbuf = "",
        ackDue = nil,
        lanes = {}, lane = 0,
        frames = 0, resent = 0, refused = 0, dead = false,
    }, Wire)
    if opts.share then w.lanes = opts.share else w.lanes = Wire.Lanes(opts.lanes, opts.now) end
    return w
end

-- queue a message for the other end
-- (beat: only a sign of life, which leaves pushedAt, the time of the last real message, alone)
function Wire:push(msg, beat)
    local n = #msg
    self.out = self.out .. char(floor(n / 256), n % 256) .. msg
    self.outAt = self.outAt or self.now()
    if not beat then self.pushedAt = self.now() end
end

-- everything queued may go at once, without the short wait for more (the sender knows nothing more is coming)
function Wire:hurry() self.now_ = true self:tick() end

-- find a lane with allowance left and take one frame's worth from it
local function spend(w)
    local now = w.now()
    local n = #w.lanes
    for k = 1, n do
        local i = (w.lane + k - 1) % n + 1
        local l = w.lanes[i]
        local earned = floor((now - l.tokenAt) / REFILL)
        if earned > 0 then
            l.tokens = math.min(BURST, l.tokens + earned)
            l.tokenAt = (l.tokens == BURST) and now or (l.tokenAt + earned * REFILL)
        end
        if l.tokens > 0 and now >= l.holdUntil then
            l.tokens = l.tokens - 1
            if l.tokens == BURST - 1 then l.tokenAt = now end
            w.lane = i
            return i, l
        end
    end
    return nil
end

-- a number 0..251 as one byte that is never 0 nor "|"
local function num(v) v = v + 1 if v >= 124 then v = v + 1 end return v end
local function unnum(b) if b > 124 then b = b - 1 end return b - 1 end

local function transmit(w, seq, text)
    local frame = char(w.id, num(seq), num(w.want)) .. text
    local i, l = spend(w)
    if not i then return false end
    if not w.send(frame, i) then
        -- the server would not take it: this lane has no allowance after all, whatever we reckoned
        l.tokens = 0
        l.tokenAt = w.now()
        l.holdUntil = w.now() + 1
        w.refused = w.refused + 1
        return false
    end
    w.frames = w.frames + 1
    w.ackDue = nil
    return true
end

local function outstanding(w) return (w.next - w.base) % SEQS end

-- call this often (every screen frame is fine)
function Wire:tick()
    if self.dead then return end
    local now = self.now()
    -- 1. the oldest unanswered frame, if it has waited long enough
    local old = self.sent[self.base]
    if old and now - old.at > RESEND * math.min(old.tries, 3) then
        if old.tries >= GIVE_UP then
            self.dead = true
            if self.lost then self.lost() end
            return
        end
        if transmit(self, self.base, old.text) then
            old.at, old.tries = now, old.tries + 1
            self.resent = self.resent + 1
        end
        return
    end
    -- 2. new frames
    local waited = false
    while #self.out > 0 and outstanding(self) < WINDOW do
        if #self.out < self.room - 8 and now - self.outAt < LINGER and not self.now_ then break end
        local text, stop = pack(self.out, 1, self.room)
        if not transmit(self, self.next, text) then waited = true break end
        self.sent[self.next] = { text = text, at = now, tries = 1 }
        self.next = (self.next + 1) % SEQS
        self.out = sub(self.out, stop)
        self.outAt = (#self.out > 0) and now or nil
    end
    self.now_ = nil
    -- (time spent with something to say and no allowance left to say it: the server's limit, felt)
    if (waited or (#self.out > 0 and outstanding(self) >= WINDOW)) and self.tickAt then
        self.starved = (self.starved or 0) + (now - self.tickAt)
    end
    self.tickAt = now
    -- 3. a bare "got it"
    if self.ackDue and now - self.ackDue > ACK_WAIT then
        transmit(self, NO_DATA, "")
    end
end

local function takeMessages(w)
    while true do
        local buf = w.inbuf
        if #buf < 2 then return end
        local n = byte(buf, 1) * 256 + byte(buf, 2)
        if #buf < 2 + n then return end
        w.inbuf = sub(buf, 3 + n)
        w.deliver(sub(buf, 3, 2 + n))
    end
end

-- a frame has arrived from the other end
function Wire:receive(frame)
    if self.dead or #frame < 3 or byte(frame, 1) ~= self.peer then return end
    local seq, ack = unnum(byte(frame, 2)), unnum(byte(frame, 3))
    -- what the other end has got lets go of our copies
    local gone = (ack - self.base) % SEQS
    if gone > 0 and gone <= outstanding(self) then
        local now = self.now()
        for _ = 1, gone do
            -- (how long a frame took to be answered: the line's round trip, plus up to ACK_WAIT when the other end
            -- had nothing to say back; frames sent more than once tell us nothing)
            local e = self.sent[self.base]
            if e and e.tries == 1 then
                local r = now - e.at
                self.rtt = self.rtt and (self.rtt * 0.9 + r * 0.1) or r
                self.rttLow = math.min(self.rttLow or r, r)
            end
            self.sent[self.base] = nil
            self.base = (self.base + 1) % SEQS
        end
    end
    if seq == NO_DATA then return end
    local ahead = (seq - self.want) % SEQS
    if ahead == 0 then
        self.inbuf = self.inbuf .. unpack_(sub(frame, 4))
        self.want = (self.want + 1) % SEQS
        while self.early[self.want] do            -- frames that overtook this one
            self.inbuf = self.inbuf .. unpack_(self.early[self.want])
            self.early[self.want] = nil
            self.want = (self.want + 1) % SEQS
        end
        takeMessages(self)
    elseif ahead < WINDOW * 2 then
        self.early[seq] = sub(frame, 4)
    end
    -- (anything else is a frame we already have: say "got it" again)
    self.ackDue = self.ackDue or self.now()
end

-- true when everything pushed has arrived at the other end
function Wire:idle() return #self.out == 0 and outstanding(self) == 0 end
