-- (0.26) Save codes and backups. A game's own save can be copied out as one line of text (a "save code") and pasted
-- back in: on another computer, on an alt (our own games keep a save per character), or after a fresh install. The same
-- code is how backups are kept: the save as it was when you started playing that day, and the save as it was before
-- anything replaced it (Start over, a pasted save, a backup put back). Backups live in MekkaBoy_States, the side addon
-- that is read only when it is needed, so the main settings file stays small.
--
-- A code is:  MEKKASAVE1:<system>:<cart id>:<game code>:<name>:<when>:<bytes>:<sum>:<how>:<data>:END
--   system  gb (Game Boy and Color) or gba;   how  z (zlib, by the game client) or r (MekkaBoy's own run-length)
--   data    the save's bytes, packed, as base64;   sum  adler32 of the bytes, so a damaged paste is caught
-- Only the game's own save travels: memory valves and the resume point stay where they are.
local _, MB = ...

local SC = {}
MB.SaveCode = SC

local floor, char, concat = math.floor, string.char, table.concat
local MAGIC = "MEKKASAVE1"
local KEEP = 5                 -- backups kept per game (the oldest goes first)

-- ------------------------------------------------------------ helpers ---
local function adler32(s)
    if MB.Import and MB.Import.adler32 then return MB.Import.adler32(s) end
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521 b = (b + a) % 65521 end
    return b * 65536 + a
end
SC.adler32 = adler32

local H2C = {}
do
    local d = "0123456789abcdef"
    for i = 0, 255 do
        local hi, lo = floor(i / 16) + 1, i % 16 + 1
        for _, a in ipairs({ d:sub(hi, hi), d:sub(hi, hi):upper() }) do
            for _, b in ipairs({ d:sub(lo, lo), d:sub(lo, lo):upper() }) do H2C[a .. b] = char(i) end
        end
    end
end
local C2H = {}
for i = 0, 255 do C2H[char(i)] = ("%02x"):format(i) end
local function hexToBytes(h) return (h:gsub("..", H2C)) end
local function bytesToHex(b) return (b:gsub(".", C2H)) end

-- base64, by the client when it can, else here
local ABC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64V = {}
for i = 1, 64 do B64V[ABC:byte(i)] = i - 1 end
local function b64enc(s)
    local E = C_EncodingUtil
    if E and E.EncodeBase64 and not SC.forceLua then
        local ok, r = pcall(E.EncodeBase64, s)
        if ok and type(r) == "string" then return r end
    end
    local out, n = {}, #s
    for i = 1, n, 3 do
        local a, b, c = s:byte(i, i + 2)
        local x = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = floor(x / 262144), floor(x / 4096) % 64
        local c3, c4 = floor(x / 64) % 64, x % 64
        out[#out + 1] = ABC:sub(c1 + 1, c1 + 1) .. ABC:sub(c2 + 1, c2 + 1)
            .. (b and ABC:sub(c3 + 1, c3 + 1) or "=") .. (c and ABC:sub(c4 + 1, c4 + 1) or "=")
    end
    return concat(out)
end
local function b64dec(s)
    s = s:gsub("[^%w%+/]", "")
    local out, n = {}, #s
    for i = 1, n, 4 do
        local v1, v2, v3, v4 = B64V[s:byte(i)], B64V[s:byte(i + 1) or 0], B64V[s:byte(i + 2) or 0], B64V[s:byte(i + 3) or 0]
        if not (v1 and v2) then break end
        local x = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
        out[#out + 1] = char(floor(x / 65536))
        if v3 then out[#out + 1] = char(floor(x / 256) % 256) end
        if v4 then out[#out + 1] = char(x % 256) end
    end
    return concat(out)
end
SC.b64enc, SC.b64dec = b64enc, b64dec

-- MekkaBoy's own packing, for a client without zlib: a control byte c, then
--   c < 128: c+1 bytes as they are;   c >= 128: one byte, repeated c-125 times (3 to 130)
local function rlePack(s)
    local out, lit, n, i = {}, {}, #s, 1
    local function flushLit()
        local k = 1
        while k <= #lit do
            local m = math.min(128, #lit - k + 1)
            out[#out + 1] = char(m - 1) .. concat(lit, "", k, k + m - 1)
            k = k + m
        end
        lit = {}
    end
    while i <= n do
        local c = s:sub(i, i)
        local j = i
        while j < n and j - i < 129 and s:sub(j + 1, j + 1) == c do j = j + 1 end
        local run = j - i + 1
        if run >= 3 then
            flushLit()
            out[#out + 1] = char(run + 125) .. c
        else
            for k = i, j do lit[#lit + 1] = c end
        end
        i = j + 1
    end
    flushLit()
    return concat(out)
end
local function rleUnpack(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 128 then
            out[#out + 1] = s:sub(i + 1, i + c + 1)
            i = i + c + 2
        else
            out[#out + 1] = s:sub(i + 1, i + 1):rep(c - 125)
            i = i + 2
        end
    end
    return concat(out)
end
SC.rlePack, SC.rleUnpack = rlePack, rleUnpack

local function zlibMethod() return Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib or 1 end
local function pack(raw)
    local E = C_EncodingUtil
    if E and E.CompressString and not SC.forceLua then
        local ok, z = pcall(E.CompressString, raw, zlibMethod())
        if ok and type(z) == "string" and #z > 0 then return "z", b64enc(z) end
    end
    return "r", b64enc(rlePack(raw))
end
local function unpackData(how, data, size)
    if how == "r" then return rleUnpack(b64dec(data)) end
    if how ~= "z" then error("an unknown packing") end
    local E = C_EncodingUtil
    if E and E.DecodeBase64 and E.DecompressString and not SC.forceLua then
        local ok, raw = pcall(function() return E.DecompressString(E.DecodeBase64(data), zlibMethod()) end)
        if ok and type(raw) == "string" and #raw == size then return raw end
    end
    if MB.Import and MB.Import.InflateText then return MB.Import.InflateText(data, size) end
    error("this game client can't unpack it")
end

-- ---------------------------------------------- a save <-> its bytes ---
-- Advance: "A", then for each of the 32 sectors of 4K: 0 (blank) or 1 and its 4096 bytes.
-- Game Boy: "B", a line "rtcBase|rtcHaltAt|title", the number of RAM banks, then each bank: its length (2 bytes) and bytes.
local function toBytes(kind, save)
    if kind == "gba" then
        if type(save) ~= "table" or save.kind ~= "flash128" or type(save.sectors) ~= "table" then return nil end
        local out = { "A" }
        for n = 1, 32 do
            local h = save.sectors[n]
            if type(h) == "string" and #h == 8192 then out[#out + 1] = "\1" .. hexToBytes(h) else out[#out + 1] = "\0" end
        end
        return concat(out)
    end
    if type(save) ~= "table" or type(save.ram) ~= "table" then return nil end
    local head = ("%s|%s|%s\n"):format(tostring(save.rtcBase or ""), tostring(save.rtcHaltAt or ""), (tostring(save.title or "")):gsub("[|\n]", " "))
    local out = { "B", head, char(#save.ram) }
    for i = 1, #save.ram do
        local b = hexToBytes(save.ram[i] or "")
        out[#out + 1] = char(floor(#b / 256), #b % 256) .. b
    end
    return concat(out)
end
local function fromBytes(raw)
    local tag = raw:sub(1, 1)
    if tag == "A" then
        local t, at = { kind = "flash128", sectors = {} }, 2
        for n = 1, 32 do
            local f = raw:byte(at)
            if f == 1 then
                local b = raw:sub(at + 1, at + 4096)
                if #b ~= 4096 then return nil end
                t.sectors[n] = bytesToHex(b)
                at = at + 4097
            elseif f == 0 then
                t.sectors[n] = ""
                at = at + 1
            else
                return nil
            end
        end
        return t, "gba"
    elseif tag == "B" then
        local nl = raw:find("\n", 2, true)
        if not nl then return nil end
        local a, b, title = raw:sub(2, nl - 1):match("^([^|]*)|([^|]*)|(.*)$")
        local t = { ram = {}, rtcBase = tonumber(a), rtcHaltAt = tonumber(b), title = (title ~= "") and title or nil }
        local nb, at = raw:byte(nl + 1), nl + 2
        if not nb then return nil end
        for i = 1, nb do
            local hi, lo = raw:byte(at, at + 1)
            if not lo then return nil end
            local len = hi * 256 + lo
            local bytes = raw:sub(at + 2, at + 1 + len)
            if #bytes ~= len then return nil end
            t.ram[i] = bytesToHex(bytes)
            at = at + 2 + len
        end
        return t, "gb"
    end
    return nil
end
SC.toBytes, SC.fromBytes = toBytes, fromBytes

-- (0.26 qa) a save that holds nothing: the game was never saved in its own menu (every Advance sector blank, or every
-- byte of a Game Boy's RAM the same). Progress kept only in the resume point or a memory valve is not in it.
function SC.IsBlank(kind, save)
    if type(save) ~= "table" then return true end
    if kind == "gba" then
        for n = 1, 32 do local h = save.sectors and save.sectors[n] if type(h) == "string" and h ~= "" then return false end end
        return true
    end
    local first
    for _, h in ipairs(save.ram or {}) do
        if type(h) == "string" and h ~= "" then
            local b = h:sub(1, 2):lower()
            first = first or b
            if b ~= first or h:lower() ~= b:rep(#h / 2) then return false end
        end
    end
    return true
end

local function clean(s) return (tostring(s or ""):gsub("[:\r\n]", " ")) end
-- (a time keeps its colon as a dot inside the code: "2026-11-24 18.20")
local function whenIn(s) return (clean(tostring(s or ""):gsub(":", "."))) end
local function whenOut(s) return (tostring(s or ""):gsub("(%d)%.(%d)", "%1:%2")) end

-- a save -> its code (or nil and why not). cart = { id, name, code }.
function SC.Make(kind, cart, save, when)
    local raw = toBytes(kind, save)
    if not raw or SC.IsBlank(kind, save) then return nil, "blank" end
    local how, data = pack(raw)
    return concat({ MAGIC, kind, clean(cart.id), clean(cart.code), clean(cart.name), whenIn(when or save.at or ""),
                    tostring(#raw), tostring(adler32(raw)), how, data, "END" }, ":")
end

-- the label of a code, without unpacking it (or nil and why not): { kind, id, code, name, when, size, sum, how, data }
function SC.Read(text)
    if type(text) ~= "string" then return nil, "Paste a save code first." end
    local s = text:find(MAGIC .. ":", 1, true)
    if not s then
        if text:find("MEKKA1:", 1, true) then return nil, "That's a game code, not a save. Add games with Add a game." end
        return nil, "That isn't a MekkaBoy save code. A save code starts with " .. MAGIC .. "."
    end
    text = text:sub(s)
    local f = {}
    for part in (text .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end
    for i = 1, #f do if i == 10 then f[i] = f[i]:gsub("%s", "") else f[i] = f[i]:gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "") end end
    if #f < 11 or f[11] ~= "END" then return nil, "The code is cut short. Copy all of it, from MEKKASAVE1 to END." end
    local info = { kind = f[2], id = f[3], code = f[4] ~= "" and f[4] or nil, name = f[5], when = whenOut(f[6]),
                   size = tonumber(f[7]), sum = tonumber(f[8]), how = f[9], data = f[10] }
    if (info.kind ~= "gb" and info.kind ~= "gba") or not info.size or not info.sum then return nil, "The code's label makes no sense." end
    return info
end

-- a code -> the save (or nil and why not), and its label
function SC.Open(text)
    local info, why = SC.Read(text)
    if not info then return nil, why end
    local ok, raw = pcall(unpackData, info.how, info.data, info.size)
    if not ok or type(raw) ~= "string" then return nil, "The code could not be unpacked: " .. tostring(raw):gsub("^.-:%d+: ", "") end
    if #raw ~= info.size or adler32(raw) ~= info.sum then return nil, "The code was damaged on the way in (some characters are wrong). Copy it again." end
    local save, kind = fromBytes(raw)
    if not save or kind ~= info.kind then return nil, "The save inside the code makes no sense." end
    if SC.IsBlank(kind, save) then return nil, "That code holds an empty save: the game had never been saved in its own menu when it was copied." end
    save.at = info.when ~= "" and info.when or nil
    return save, info
end

-- ------------------------------------------------------------ backups ---
-- MekkaBoyBackups[saveKey] = { { code =, at =, why =, sum = }, ... } oldest first, in the side addon (MB.OpenSideStore);
-- if that can't be read, a smaller list (2 a game) in the main settings.
local function store()
    if MB.OpenSideStore and MB.OpenSideStore() then
        MekkaBoyBackups = MekkaBoyBackups or {}
        return MekkaBoyBackups, KEEP
    end
    local db = MB.DB()
    db.backups = db.backups or {}
    return db.backups, 2
end
local function today() return date and date("%Y-%m-%d") or "?" end
local function now() return date and date("%Y-%m-%d %H:%M") or "?" end

local WHY = { day = "When you started playing", startover = "Before you started over", paste = "Before a pasted save",
              restore = "Before a backup was put back" }
SC.WHY = WHY

-- keep a copy of a save. why: day (once a day, when the game is first switched on), startover, paste, restore.
-- Returns true when one was kept.
function SC.Backup(key, kind, cart, save, why)
    if not (key and save) then return false end
    local raw = toBytes(kind, save)
    if not raw or SC.IsBlank(kind, save) then return false end      -- (nothing to keep)
    local all, keep = store()
    local list = all[key] or {}
    all[key] = list
    local sum = adler32(raw)
    local last = list[#list]
    if why == "day" and last and last.day == today() then return false end    -- (one a day is plenty)
    if last and last.sum == sum and last.size == #raw then                      -- (the same save as the newest backup)
        if why ~= "day" then last.why, last.at = why, now() end
        return false
    end
    local how, data = pack(raw)
    local code = concat({ MAGIC, kind, clean(cart.id), clean(cart.code), clean(cart.name), whenIn(save.at or ""),
                          tostring(#raw), tostring(sum), how, data, "END" }, ":")
    list[#list + 1] = { code = code, at = now(), day = today(), why = why, sum = sum, size = #raw }
    while #list > keep do table.remove(list, 1) end
    return true
end

-- the backups of a save, newest first: { { at, why, words, code } }
function SC.Backups(key)
    local all = store()
    local list, out = {}, {}
    -- (0.26 qa) both places, should the side addon have been out of reach when some were kept
    local db = MB.DB()
    local srcs = { all[key] or false, (db.backups and db.backups ~= all and db.backups[key]) or false }
    for i = 1, 2 do
        for _, b in ipairs(srcs[i] or {}) do list[#list + 1] = b end
    end
    local seq = {}
    for i, b in ipairs(list) do seq[b] = i end
    table.sort(list, function(a, b)
        if tostring(a.at) ~= tostring(b.at) then return tostring(a.at) < tostring(b.at) end
        return seq[a] < seq[b]
    end)
    for i = #list, 1, -1 do
        local b = list[i]
        out[#out + 1] = { at = b.at, why = b.why, words = WHY[b.why] or "Kept", code = b.code, index = i }
    end
    return out
end

-- (called by the console as a game is switched on) the first time a game is played on a day, its save as it was
function MB.BackupOnStart(rom, key)
    if not rom or rom.system == "native" or MB.DB().testSaves then return end
    local kind = rom.system == "gba" and "gba" or "gb"
    local save = MB.Saves()[kind][key]
    if not save then return end
    local c = MB.Carts.Find(rom.id) or { id = rom.id, name = rom.name }
    SC.Backup(key, kind, c, save, "day")
end
