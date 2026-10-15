-- Cheat codes: GameShark (8 hex digits, writes a value to memory every frame)
-- and Game Genie (6 or 9 hex digits, changes what the game reads from its ROM).
local _, MB = ...

local Cheats = {}
MB.Cheats = Cheats

local function xor8(a, b)
    local r, bit = 0, 1
    for _ = 1, 8 do
        if a % 2 ~= b % 2 then r = r + bit end
        a, b, bit = (a - a % 2) / 2, (b - b % 2) / 2, bit * 2
    end
    return r
end

-- Returns a table describing the code, or nil and a reason.
--   { kind = "gs", addr =, value = }
--   { kind = "gg", addr =, value =, compare = (may be nil) }
function Cheats.parse(text)
    local code = (text or ""):upper():gsub("[%s%-]", "")
    if not code:match("^%x+$") then return nil, "codes are made of the digits 0-9 and letters A-F" end
    local n = {}
    for i = 1, #code do n[i] = tonumber(code:sub(i, i), 16) end
    if #code == 8 then
        -- GameShark ttVVLLHH: value VV to address HHLL
        local addr = (n[7] * 16 + n[8]) * 256 + n[5] * 16 + n[6]
        if addr < 0xA000 or addr > 0xDFFF then return nil, "that GameShark code points outside the game's memory" end
        return { kind = "gs", addr = addr, value = n[3] * 16 + n[4], code = code }
    elseif #code == 6 or #code == 9 then
        -- Game Genie ABC-DEF(-GHI): value AB at address (F xor 15)CDE, only where the old byte matches
        local c = { kind = "gg", value = n[1] * 16 + n[2], addr = (15 - n[6]) * 4096 + n[3] * 256 + n[4] * 16 + n[5] }
        if c.addr >= 0x8000 then return nil, "that Game Genie code points outside the game's ROM" end
        if #code == 9 then
            local t = n[7] * 16 + n[9]
            t = ((t - t % 4) / 4 + (t % 4) * 64) % 256 -- rotate right by two bits
            c.compare = xor8(t, 0xBA)
        end
        c.code = (#code == 9) and (code:sub(1, 3) .. "-" .. code:sub(4, 6) .. "-" .. code:sub(7, 9))
            or (code:sub(1, 3) .. "-" .. code:sub(4, 6))
        return c
    end
    return nil, "a GameShark code has 8 digits; a Game Genie code has 6 or 9"
end

-- Splits a game's saved cheat list into what the console needs each frame.
-- list = { { code = "...", on = true }, ... }
function Cheats.compile(list)
    local pokes, patches = {}, {}
    for _, entry in ipairs(list or {}) do
        if entry.on ~= false then
            local c = Cheats.parse(entry.code)
            if c and c.kind == "gs" then
                pokes[#pokes + 1] = c
            elseif c then
                patches[#patches + 1] = c
            end
        end
    end
    return pokes, patches
end
