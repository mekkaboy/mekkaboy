-- The team card and the Pokedex, between players: asking for someone's, answering for your own, keeping the last
-- Pokedex each player sent (the windows are UI/Card.lua; the data is Dex.lua's).
--
-- Messages, on Friends' addon name (lane 5) and kind "F" (older versions ignore these letters, so they simply do not
-- answer, and the asker says so after a few seconds):
--   Fc1                    "may I see your team card?"
--   Fd1                    "may I see your Pokedex?"
--   FC1<part>              a card, in Dex.Split parts (<index><count><piece>, each message <= 255 bytes)
--   FD1<part>              a Pokedex, the same way
--   FN1c / FN1d            "they keep it private" (How I play is Friends only and you are not someone they know)
-- What the parts put together say:
--   card:     K1;<live 0|1>;<seconds since last played>;<shares e|f>;<game being played>#<Dex.EncodeCard text, or nothing>
--   pokedex:  K1;<saves still pending>;<shares e|f>#<Dex.EncodeDex text>
--   (the card's "caught" is the whole National Pokedex count across the player's saves, not that one save's)
-- Who is answered is How I play (Dex.MayShow): Open, anyone; Friends only, people you know (others get FN); Solo,
-- nobody, and no answer at all. Asking happens only when you click or type something, never in a loop; answers are
-- rate-limited (one per player and kind every 10 s, a few a minute in all) and their parts go out 0.35 s apart.
-- Answers are only taken from a player we just asked. The last Pokedex from each player is kept
-- (MekkaBoyDB.dexSeen, the 40 most recent players) so it can be shown when they are offline.
local _, MB = ...
local Card = {}
MB.Card = Card
local F, Dex = MB.Friends, MB.Dex
if not (F and Dex) then return end
local Print = MB.Print

local LANE = 5
local WAIT = 6                       -- seconds an answer may take before "didn't answer"
local ANSWER_EVERY = 10              -- per asker and kind
local FRESH = 15                     -- an answer this recent is shown again without asking
local ANSWERS_PER_MINUTE = 8         -- in all
local GAP = 0.35                     -- between the parts of one answer
local KEEP_SEEN = 40

local function now() return GetTime() end
local function wall() return (time and time()) or 0 end
local function plain(name) return MB.Link.Plain(name) end
local function send(text, target) return MB.Link.Send(text, "WHISPER", target, LANE) end
local function clean(t, n) return (tostring(t or ""):gsub("[;#|%c]", " "):sub(1, n or 40)) end
local SHARE = { open = "e", friends = "f" }

-- ---------------------------------------------------------------- your own ---
local function playingGame()
    local id = MB.CurrentCart and MB.CurrentCart()
    local c = id and MB.Carts and MB.Carts.Find and MB.Carts.Find(id)
    return c and c.name or nil
end
-- is the game behind this card on the console right now?
local function live(card)
    if not card or not (MB.IsRunning and MB.IsRunning()) then return false end
    local cur = MB.CurrentStore and MB.CurrentStore()
    return cur == card.key and MB.window and MB.window:IsShown() and true or false
end
-- your card, as the windows show it: { mine, who, card (or nil), live, played, playing, share }
function Card.Mine()
    local card = Dex.Card()
    local dex = Dex.Pokedex()
    local out = { mine = true, who = (UnitName and UnitName("player")) or "You", playing = playingGame(), share = MB.PlayMode(), at = wall() }
    if card then
        card.caught = dex.caughtCount
        out.card, out.live = card, live(card)
        local row = Dex.Store().saves[card.key]
        out.played = row and row.played or nil
    else
        out.live = (MB.IsRunning and MB.IsRunning() and MB.window and MB.window:IsShown()) and true or false   -- (the game in the slot)
    end
    return out
end
function Card.MyDex()
    local dex = Dex.Pokedex()
    return { mine = true, who = (UnitName and UnitName("player")) or "You", dex = dex, pending = dex.pending, share = MB.PlayMode(), at = wall() }
end
local function cardText()
    local m = Card.Mine()
    local ago = m.played and math.max(0, wall() - m.played) or 0
    local head = ("K1;%d;%d;%s;%s#"):format(m.live and 1 or 0, math.min(ago, 99999999), SHARE[m.share] or "e", clean(m.playing))
    return head .. (m.card and (Dex.EncodeCard(m.card) or "") or "")
end
local function dexText()
    local d = Card.MyDex()
    return ("K1;%d;%s#"):format(d.pending or 0, SHARE[d.share] or "e") .. (Dex.EncodeDex(d.dex) or "")
end
Card.CardText, Card.DexText = cardText, dexText

-- --------------------------------------------------------------- answering ---
local out = {}                       -- messages waiting their turn: { text, to }
local nextOut = 0
local answeredAt, answerTimes = {}, {}
local function answer(kind, sender, channel)
    if MB.PlayMode() == "solo" then return end                      -- (Solo: nobody is told anything)
    local key = kind .. plain(sender)
    if answeredAt[key] and now() - answeredAt[key] < ANSWER_EVERY then return end
    local recent = 0
    for i = #answerTimes, 1, -1 do
        if now() - answerTimes[i] < 60 then recent = recent + 1 else table.remove(answerTimes, i) end
    end
    if recent >= ANSWERS_PER_MINUTE then return end
    answeredAt[key] = now()
    answerTimes[#answerTimes + 1] = now()
    if not Dex.MayShow(sender, channel) then
        out[#out + 1] = { text = "FN1" .. kind, to = sender }
        return
    end
    local ok, text = pcall(kind == "c" and cardText or dexText)
    if not ok or not text then return end
    local parts = Dex.Split(text, 252)
    if not parts then return end
    for _, p in ipairs(parts) do out[#out + 1] = { text = (kind == "c" and "FC1" or "FD1") .. p, to = sender } end
end

-- ----------------------------------------------------------------- asking ---
-- state per player and kind: Card.State(name, "card" | "dex") -> { name, status = "asking" | "ok" | "private" |
-- "timeout" | "solo", at (GetTime), data (the card or the Pokedex), got (wall time it arrived) }
local state = { card = {}, dex = {} }
local parts = {}                     -- kind .. plain sender -> list of parts so far
local function changed() if Card.Changed then pcall(Card.Changed) end end
local function find(kind, sender)
    local t = state[kind]
    if t[plain(sender)] then return t[plain(sender)] end
    for _, e in pairs(t) do if MB.Link.NameIs(e.name, sender) then return e end end
    return nil
end
function Card.State(name, kind) return name and find(kind or "card", name) or nil end

function Card.Ask(name, kind)
    kind = kind or "card"
    if type(name) ~= "string" or name == "" then return nil end
    local key = plain(name)
    local e = state[kind][key]
    if MB.PlayMode() == "solo" then
        e = { name = name, status = "solo", at = now() }
        state[kind][key] = e
        changed()
        return e
    end
    if e and e.status == "asking" and now() - e.at < WAIT then return e end   -- (already asking)
    -- (answered a moment ago: shown again as it is, since they would not answer again so soon: ANSWER_EVERY)
    if e and (e.status == "ok" or e.status == "private") and e.answeredAt and now() - e.answeredAt < FRESH then return e end
    local old = e
    e = { name = name, status = "asking", at = now(), data = old and old.data or nil, got = old and old.got or nil }
    state[kind][key] = e
    parts[kind .. key] = {}
    local spellings = MB.Link.Spellings(name)
    local sent = 0
    for i, s in ipairs(spellings) do
        if i > 3 then break end
        if not MB.Link.Unreachable(s) then out[#out + 1] = { text = kind == "card" and "Fc1" or "Fd1", to = s } sent = sent + 1 end
    end
    if sent == 0 then out[#out + 1] = { text = kind == "card" and "Fc1" or "Fd1", to = name } end
    changed()
    return e
end

-- (what another player sent is shown as plain text: no colour codes, links or pictures)
local function plainText(t) return t and (tostring(t):gsub("|", "/"):gsub("%c", " ")) or nil end
local function parseCard(text)
    local hash = text:find("#", 1, true)
    if not hash then return nil end
    local liveF, ago, share, playing = text:sub(1, hash - 1):match("^K1;([01]);(%d+);([ef]);(.*)$")
    if not liveF then return nil end
    local body = text:sub(hash + 1)
    local card
    if body ~= "" then
        card = Dex.DecodeCard(body)
        if not card then return nil end
        card.trainer = plainText(card.trainer)
        for _, m in ipairs(card.party) do m.nick = plainText(m.nick) end
    end
    return { card = card, live = liveF == "1", played = wall() - tonumber(ago), share = share == "f" and "friends" or "open",
             playing = playing ~= "" and plainText(playing) or nil }
end
local function parseDex(text)
    local hash = text:find("#", 1, true)
    if not hash then return nil end
    local pending, share = text:sub(1, hash - 1):match("^K1;(%d+);([ef])$")
    if not pending then return nil end
    local dex = Dex.DecodeDex(text:sub(hash + 1))
    if not dex then return nil end
    for _, row in ipairs(dex.saves) do row.trainer = plainText(row.trainer) end
    return { dex = dex, pending = tonumber(pending), share = share == "f" and "friends" or "open" }
end
Card.ParseCard, Card.ParseDex = parseCard, parseDex

local function seenStore()
    local db = MB.DB()
    if type(db.dexSeen) ~= "table" then db.dexSeen = {} end
    return db.dexSeen
end
local function keepDex(sender, text)
    local s = seenStore()
    s[plain(sender)] = { name = sender, text = text, at = wall() }
    local n, oldest, oldKey = 0, nil, nil
    for k, v in pairs(s) do
        n = n + 1
        if type(v) ~= "table" or not oldest or (v.at or 0) < oldest then oldest, oldKey = type(v) == "table" and v.at or -1, k end
    end
    if n > KEEP_SEEN and oldKey then s[oldKey] = nil end
end
-- the last Pokedex that player sent: { name, data = parsed, at (wall time) } or nil
function Card.Seen(name)
    if type(name) ~= "string" then return nil end
    local s = seenStore()
    local e = s[plain(name)]
    if not e then for _, v in pairs(s) do if type(v) == "table" and MB.Link.NameIs(v.name, name) then e = v break end end end
    if type(e) ~= "table" or type(e.text) ~= "string" then return nil end
    local data = parseDex(e.text)
    return data and { name = e.name, data = data, at = e.at } or nil
end

local function took(kind, sender, piece)
    local e = find(kind, sender)
    if not (e and (e.status == "asking" or (e.status == "timeout" and now() - e.at < 30))) then return end   -- (not asked for)
    local key = kind .. plain(e.name)
    local list = parts[key] or {}
    parts[key] = list
    if #list >= 64 then return end
    list[#list + 1] = piece
    local text = Dex.Join(list)
    if not text then return end
    parts[key] = {}
    local data = kind == "card" and parseCard(text) or parseDex(text)
    if not data then return end
    e.status, e.data, e.got, e.from, e.answeredAt = "ok", data, wall(), sender, now()
    if kind == "dex" then pcall(keepDex, e.name, text) end
    changed()
end

local heard = F.Heard
F.Heard = function(text, channel, sender, ...)
    local what = text:sub(2, 2)
    if what == "c" or what == "d" or what == "C" or what == "D" or what == "N" then
        if MB.Link.IsMe(sender) or text:sub(3, 3) ~= "1" then return end
        if what == "c" or what == "d" then answer(what, sender, channel)
        elseif what == "C" then took("card", sender, text:sub(4))
        elseif what == "D" then took("dex", sender, text:sub(4))
        else
            local kind = text:sub(4, 4) == "d" and "dex" or "card"
            local e = find(kind, sender)
            if e and e.status == "asking" then e.status, e.answeredAt = "private", now() changed() end
        end
        return
    end
    return heard(text, channel, sender, ...)
end

-- --------------------------------------------------------------- the clock ---
local tick = CreateFrame("Frame")
tick:SetScript("OnUpdate", function()
    local t = now()
    if #out > 0 and t >= nextOut then
        nextOut = t + GAP
        local m = table.remove(out, 1)
        send(m.text, m.to)
    end
    for _, kind in ipairs({ "card", "dex" }) do
        for _, e in pairs(state[kind]) do
            if e.status == "asking" and t - e.at > WAIT then e.status = "timeout" e.at = t changed() end
        end
    end
end)
function Card.Queue() return out end           -- (for tests)

-- ---------------------------------------------------------------- commands ---
MB.AddCommand("card", "card [name] - your Pokemon team card (or ask that player for theirs)", function(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not Card.ShowCard then return end
    if rest == "" then Card.ShowCard() else Card.ShowCard(rest) end
end)
MB.AddCommand("dex", "dex [name] - your Pokedex across every Pokemon save (or that player's)", function(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not Card.ShowDex then return end
    if rest == "" then Card.ShowDex() else Card.ShowDex(rest) end
end)
