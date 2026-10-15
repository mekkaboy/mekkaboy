-- /mb bench: how much speed does this computer have to spare?
-- It times the game in the slot (or the last one played) running flat out on
-- a private copy, times a full repaint of the screen, and reports what play
-- has been costing. Results go to chat and to the settings file
-- (MekkaBoyDB.bench) so they can be read back when someone asks for help.
local _, MB = ...

local Bench = {}
MB.Bench = Bench

local clock = debugprofilestop or function() return os.clock() * 1000 end
local GB_FRAME_MS = 1000 / 59.73
local function say(msg) MB.Print(msg) end

local function privateCopy()
    local db = MB.DB()
    local id = db.lastCart
    local last = id and MB.Carts.Find and MB.Carts.Find(id)
    if not id or (last and last.system == "gba") then        -- (this test is for the Game Boy machine)
        id = nil
        for _, c in ipairs(MB.Carts.List and MB.Carts.List() or {}) do
            if c.system ~= "gba" then id = c.id break end
        end
    end
    if not id then return nil, "there is no game to try" end
    local rom = MB.Carts.Load(id)
    if not rom then return nil, "could not load " .. tostring(id) end
    local ok, m = pcall(MB.GB.new, { bank = function(n) return rom.banks[n + 1] end, numBanks = rom.numBanks,
                                     save = db.gb and db.gb[id], now = time })
    if not ok then return nil, tostring(m) end
    -- where the player actually is, if a resume point exists; otherwise from power-on
    local st = db.states and db.states[id] and db.states[id].resume
    if st and MB.GB.decodeState then pcall(function() m.loadState(MB.GB.decodeState(st)) end) end
    return m, rom.name or id
end

function Bench.Run()
    if Bench.busy then say("The speed test is already running.") return end
    local m, name = privateCopy()
    if not m then say("Speed test: " .. tostring(name) .. ".") return end
    Bench.busy = true
    say("Speed test: a few seconds. The game may stutter while it runs.")
    local out = { version = 2, at = date and date("%Y-%m-%d %H:%M") or "?", fps = GetFramerate and GetFramerate() or 0, game = name }
    local stage, n, spent = 1, 0, 0
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function()
        local ok, err = pcall(function()
            if stage == 1 then                  -- settle
                for _ = 1, 30 do m.runFrame(true) end
                stage = 2
            elseif stage == 2 or stage == 3 then -- with the picture, then without
                local t0 = clock()
                for _ = 1, 20 do m.runFrame(stage == 2) end
                spent, n = spent + (clock() - t0), n + 20
                if n >= 120 then
                    if stage == 2 then out.msDrawn = spent / n else out.msBlind = spent / n end
                    stage, n, spent = stage + 1, 0, 0
                end
            elseif stage == 4 then              -- every dot of the real screen
                if MB.RedrawAll and MB.window and MB.window:IsShown() and MB.Machine and MB.Machine() then
                    local t0 = clock()
                    for _ = 1, 3 do MB.RedrawAll() end
                    out.redrawMs = (clock() - t0) / 3
                end
                stage = 5
            else
                driver:SetScript("OnUpdate", nil)
                Bench.busy = false
                out.speed, out.speedBlind = GB_FRAME_MS / out.msDrawn, GB_FRAME_MS / out.msBlind
                say(("%s, flat out: %.1f ms a frame = %.1fx real speed (%.1f ms, %.1fx, with no picture)."):format(
                    name, out.msDrawn, out.speed, out.msBlind, out.speedBlind))
                if out.redrawMs then say(("Repainting every dot of the screen: %.1f ms."):format(out.redrawMs)) end
                local p = MB.Perf and MB.Perf()
                if p and p.running then
                    out.play = p
                    say(("In play just now: game %.1f ms + picture %.1f ms a frame, showing every %s; WoW at %.0f frames a second."):format(
                        p.game, p.paint, p.every == 1 and "picture" or p.every == 2 and "2nd picture" or "3rd picture", out.fps))
                end
                MB.DB().bench = out
            end
        end)
        if not ok then
            driver:SetScript("OnUpdate", nil)
            Bench.busy = false
            say("The speed test stopped: " .. tostring(err))
        end
    end)
end


MB.AddCommand("bench", "bench - time this computer: how much speed MekkaBoy has to spare here", function(rest)
    Bench.Run()
end)
