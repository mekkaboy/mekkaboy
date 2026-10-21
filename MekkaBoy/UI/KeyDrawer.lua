-- The key drawer: a strip that slides out from under the console (or the Minimal window, dressed to match it) and says which keyboard key works each
-- button, from the player's own bindings (/mb bind). It is not part of the console's size: closed, there is
-- nothing; open, it hangs below the body. The ? button on the console opens and closes it, and it opens by
-- itself the very first time the console does, so a new player sees the keys once. Open or closed is kept.
local _, MB = ...

local win = MB.window
local W, ROW, PAD = 560, 18, 12
local drawer = CreateFrame("Frame", "MekkaBoyKeyDrawer", win)
drawer:SetSize(W, PAD * 2 + ROW * 5)
drawer:SetPoint("TOP", win, "BOTTOM", 0, -16)
drawer:SetFrameLevel(win:GetFrameLevel() + 2)
drawer:EnableMouse(true)                               -- (a click on it does not fall through to the world)
drawer:Hide()
MB.keyDrawer = drawer

local bg = drawer:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(drawer)
local edges = {}
for _, edge in ipairs({ { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "TOPRIGHT" } }) do
    local t = drawer:CreateTexture(nil, "BORDER")
    t:SetPoint(edge[1], 0, 0) t:SetPoint(edge[2], 0, 0) t.across = true
    edges[#edges + 1] = t
end
for _, side in ipairs({ "LEFT", "RIGHT" }) do
    local t = drawer:CreateTexture(nil, "BORDER")
    t:SetPoint("TOP" .. side, 0, 0) t:SetPoint("BOTTOM" .. side, 0, 0)
    edges[#edges + 1] = t
end

-- ten cells, two columns of five: the name, then the key(s)
local cells = {}
for i = 1, 10 do
    local name = drawer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetJustifyH("LEFT")
    local keys = drawer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    keys:SetJustifyH("LEFT")
    cells[i] = { name = name, keys = keys }
end
local function layout(w)
    drawer:SetWidth(w) drawer.w = w
    for i, c in ipairs(cells) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        c.name:ClearAllPoints() c.keys:ClearAllPoints()
        c.name:SetPoint("TOPLEFT", PAD + col * (w / 2), -(PAD + row * ROW))
        c.keys:SetPoint("TOPLEFT", PAD + col * (w / 2) + (w < W and 108 or 120), -(PAD + row * ROW))
    end
end

local PRETTY = { BACKSPACE = "Backspace", ENTER = "Enter", TAB = "Tab", ESCAPE = "Esc", SPACE = "Space", UP = "Up", DOWN = "Down",
                 LEFT = "Left", RIGHT = "Right", ["`"] = "` key" }
local function pretty(k) return PRETTY[k] or k end
local function keysOf(button)                          -- the player's keys for a button, as a list
    local label = MB.KeyLabel and MB.KeyLabel(button)
    local t = {}
    if label then for k in label:gmatch("[^ ]+") do if k ~= "or" then t[#t + 1] = pretty(k) end end end
    return t
end
local function one(button) local t = keysOf(button) return #t > 0 and table.concat(t, " or ") or "-" end
local function pair(b1, b2) return one(b1) .. "  /  " .. one(b2) end
local function dpad()
    local u, d, l, r = keysOf("up"), keysOf("down"), keysOf("left"), keysOf("right")
    local arrows = u[1] == "Up" and d[1] == "Down" and l[1] == "Left" and r[1] == "Right"
    local wasd = u[2] == "W" and d[2] == "S" and l[2] == "A" and r[2] == "D"
    if arrows and wasd then return "Arrows or WASD" end
    if arrows and not u[2] and not d[2] and not l[2] and not r[2] then return "Arrows" end
    return ("%s %s %s %s"):format(u[1] or "-", l[1] or "-", d[1] or "-", r[1] or "-")
end

-- dressed like the window it hangs under: the console's brass, or the Minimal look's glass in the chosen colorway
local GOLD, DIM, WHITE = { 1, 0.82, 0.3 }, { 0.55, 0.52, 0.46 }, { 1, 1, 1 }
local ink = { name = GOLD, keys = WHITE, dim = DIM }
local GAP = -16                                        -- (console: just under the body picture, which hangs 20 below the frame)
local function glassy() return MB.Look and MB.Look() == "glass" and MB.GlassColors end
function MB.PaintKeyDrawer()
    if glassy() then
        local c, a = MB.GlassColors()
        bg:SetColorTexture(c.bg[1], c.bg[2], c.bg[3], math.max(a, 0.8))     -- (small text: a little less see-through than the window)
        for _, t in ipairs(edges) do
            t:SetColorTexture(c.edge[1], c.edge[2], c.edge[3], c.edge[4])
            if t.across then t:SetHeight(1) else t:SetWidth(1) end
        end
        ink = { name = c.soft, keys = c.ink, dim = { c.soft[1], c.soft[2], c.soft[3], 0.5 } }
        GAP = -6
        layout((MB.WindowSize and MB.WindowSize()) or win:GetWidth())
    else
        bg:SetColorTexture(0.11, 0.09, 0.07, 0.94)
        for _, t in ipairs(edges) do
            t:SetColorTexture(0.78, 0.6, 0.28, 1)
            if t.across then t:SetHeight(2) else t:SetWidth(2) end
        end
        ink = { name = GOLD, keys = WHITE, dim = DIM }
        GAP = -16
        layout(W)
    end
    if not drawer.sliding then drawer:ClearAllPoints() drawer:SetPoint("TOP", win, "BOTTOM", 0, GAP) end
    MB.RefreshKeyDrawer()
end
MB.keyDrawerInk = function() return ink end          -- (for tests)
local function set(i, name, keys, dim)
    local c = cells[i]
    c.name:SetText(name)
    c.keys:SetText(keys)
    local n, k = dim and ink.dim or ink.name, dim and ink.dim or ink.keys
    c.name:SetTextColor(n[1], n[2], n[3], n[4] or 1)
    c.keys:SetTextColor(k[1], k[2], k[3], k[4] or 1)
end

-- fills the cells; L/R are dimmed for a Game Boy game, rewind for an Advance game
function MB.RefreshKeyDrawer()
    local _, kind = nil, nil
    if MB.CurrentCart then _, kind = MB.CurrentCart() end
    local gba, gb = kind == "gba", kind == nil or kind == "gb"
    set(1, "D-pad", dpad())
    set(2, "A  /  B", pair("a", "b"))
    set(3, "Start  /  Select", pair("start", "select"))
    set(4, "L  /  R", pair("l", "r") .. (gba and "" or "   (Advance)"), not gba)
    set(5, "Turbo A  /  B", pair("turboa", "turbob"))
    set(6, "Fast-forward", one("ff") .. " (hold)")
    set(7, "Rewind", one("rewind") .. (gb and " (hold)" or "   (Game Boy)"), not gb)
    set(8, "Memory valves", "F1-F4,  Shift saves")
    set(9, "Volume", pair("volup", "voldown"))
    set(10, "Pause", "Esc")
end

-- a short slide down from under the body; closing is immediate
local slideAt, lookAt, lastKind = nil, 0, false
drawer:SetScript("OnUpdate", function(self, elapsed)
    lookAt = lookAt + (elapsed or 0)
    if lookAt > 0.5 then                                -- another kind of cartridge in the slot: L/R and rewind change
        lookAt = 0
        local kind = MB.CurrentCart and select(2, MB.CurrentCart())
        if kind ~= lastKind then lastKind = kind MB.RefreshKeyDrawer() end
    end
    if not slideAt then return end
    slideAt = slideAt + (elapsed or 0)
    local f = math.min(1, slideAt / 0.12)
    self.sliding = f < 1
    self:ClearAllPoints()
    self:SetPoint("TOP", win, "BOTTOM", 0, GAP + (1 - f) * 24)
    self:SetAlpha(f)
    if f >= 1 then slideAt = nil end
end)

function MB.KeyDrawerOpen() return drawer:IsShown() end
function MB.SetKeyDrawer(open, keep)
    if open then
        MB.PaintKeyDrawer()
        if not drawer:IsShown() then slideAt = 0 drawer:SetAlpha(0) drawer:Show() end
    else
        slideAt = nil
        drawer:Hide()
    end
    if keep ~= false then MB.DB().opt.keyDrawer = open and true or false end
end
function MB.ToggleKeyDrawer() MB.SetKeyDrawer(not drawer:IsShown()) end

-- with the console: as it was left, and open the first time ever
win:HookScript("OnShow", function()
    local want = MB.Opt("keyDrawer", nil)
    if want == nil then want = true end
    MB.SetKeyDrawer(want)
end)
