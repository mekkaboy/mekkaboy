-- (0.25) Two getting-started cards, for the two questions players ask most:
--  * "Where are the Pokemon games?" MekkaBoy plays games you own, and players who only have the games it comes with
--    did not find how to add one (the line on the idle screen was missed). The first time the console opens with no
--    game of their own on the shelf (after the first-time questions), a card says so, with one button to add one. It
--    comes back on the next two sessions while there is still none, then never.
--  * "Why is there no sound?" A game you add plays silently until a soundtrack pack is recorded from your own copy.
--    The first time each such game starts without one, a card says how (once per game).
local _, MB = ...

local function ownGame()
    for _, c in ipairs(MB.Carts.List()) do
        if c.system ~= "native" and not (type(c.code) == "string" and c.code:sub(1, 2) == "MB") then return true end
    end
    return false
end
MB.HasOwnGame = ownGame

local shownThisSession = false
function MB.OfferAddGame(force)
    if not force then
        if shownThisSession or (MB.Onboarded and not MB.Onboarded()) then return false end
        if ownGame() then return false end
        local opt = MB.DB().opt
        if (opt.addGameCards or 0) >= 3 then return false end
        opt.addGameCards = (opt.addGameCards or 0) + 1
    end
    shownThisSession = true
    return MB.ShowCard("addgame", {
        kicker = "YOUR OWN GAMES",
        title = "Play the games you own",
        body = "MekkaBoy plays Game Boy, Game Boy Color and Game Boy Advance games from your own collection. It comes with five games of its own; any other game, you add.",
        step = "It takes three steps: pick your game file in the Workshop, copy the code it gives you, and paste it into MekkaBoy.",
        buttons = {
            { "Add a game", function() if MB.Import and MB.Import.Open then MB.Import.Open() end end, true, 112 },
            { "Not now", nil, false, 96 },
        },
    })
end

-- (0.26.1) Keep WASD for moving? Asked once per account: players who had MekkaBoy before choose between that and keeping
-- their controls; new players between that and WASD moving the game. Closing the card keeps things as they are.
function MB.OfferWasd(force)
    local opt = MB.DB().opt
    if opt.wasdAsked and not force then return false end
    if MB.Onboarded and not MB.Onboarded() then return false end
    if opt.wasdPlayer == nil then
        local saves = MB.Saves and MB.Saves() or {}
        opt.wasdPlayer = (MB.DB().lastCart or next(saves.gba or {}) or next(saves.gb or {})) and "existing" or "new"
    end
    local shown = MB.ShowCard("wasd_" .. opt.wasdPlayer, {
        kicker = "CONTROLS",
        title = "Keep WASD for moving your character?",
        body = "MekkaBoy can leave W, A, S and D to WoW while you play. Your character runs with them, and the game's D-pad stays on the arrow keys. Other keys MekkaBoy doesn't use go to WoW too.",
        width = 520,
        buttons = {
            { "Keep WASD for moving", function() MB.SetWasdMove(true) MB.Print("WASD moves your character now; the D-pad is on the arrow keys. Change it any time: /mb controls") end, true, 180 },
            { opt.wasdPlayer == "existing" and "Keep it as is" or "WASD moves the game", function() MB.SetWasdMove(false) end, false, opt.wasdPlayer == "existing" and 116 or 150 },
        },
        note = "Change it any time: /mb controls",
    })
    if shown then opt.wasdAsked = true end
    return shown
end

-- the console opened: a moment later (after the first-time questions and the Together cards have had their turn)
MB.window:HookScript("OnShow", function()
    if C_Timer and C_Timer.After then
        C_Timer.After(1.5, function()
            if not MB.window:IsShown() then return end
            if MB.CardShown("addgame") then return end
            local busy = _G.MekkaBoyWelcome and _G.MekkaBoyWelcome:IsShown()
                or _G.MekkaBoyJoinCard and _G.MekkaBoyJoinCard:IsShown()
                or _G.MekkaBoyRulesetCard and _G.MekkaBoyRulesetCard:IsShown()
            if busy then return end
            local ok, asked = pcall(MB.OfferWasd)
            if ok and asked then return end
            pcall(MB.OfferAddGame)
        end)
    end
end)

-- a game started (GB/Console.lua): one of yours, with no soundtrack pack -> say how to get its sound, once per game
function MB.OnGameAttached(id, kind)
    local c = id and MB.Carts.Find(id)
    if not c or c.system == "native" or (type(c.code) == "string" and c.code:sub(1, 2) == "MB") then return end
    if MB.SoundPacks and MB.SoundPacks[id] then return end
    local opt = MB.DB().opt
    opt.silentTold = opt.silentTold or {}
    if opt.silentTold[id] then return end
    opt.silentTold[id] = true
    MB.ShowSilentCard(kind)
end
function MB.ShowSilentCard(kind)
    local body
    if kind == "gba" then
        body = "A game you add needs a soundtrack pack, recorded from your own copy. For most Advance games the Workshop records it in your browser: music, sound effects and cries. It takes a few minutes to half an hour."
    else
        body = "A game you add needs a soundtrack pack, recorded from your own copy. For Game Boy and Game Boy Color games, the recorder in MekkaBoy's Tools folder covers the Pokémon games so far, Red through Crystal; other games play silently for now."
    end
    MB.ShowCard(kind == "gba" and "silent_gba" or "silent_gb", {
        kicker = "SOUND",
        title = "This game is silent for now",
        body = body,
        step = "Step by step: mekkaboy.com/faq, under \"Why doesn't my game have sound?\"",
        buttons = { { "Got it", nil, true, 96 } },
        note = "Once a game has its pack, it plays with sound.",
    })
end


-- (for a look at the cards, e.g. after a change to their words: /mb hints, /mb hints sound, /mb hints soundgb)
MB.AddCommand("hints", "", function(rest)
    rest = (rest or ""):lower()
    if rest == "sound" then MB.ShowSilentCard("gba")
    elseif rest == "soundgb" then MB.ShowSilentCard("gb")
    elseif rest == "wasd" then MB.OfferWasd(true)
    else MB.OfferAddGame(true) end
end)
