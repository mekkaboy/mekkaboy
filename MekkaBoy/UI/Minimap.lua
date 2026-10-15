-- The button on the rim of the minimap: left-click opens or closes the
-- console, right-click opens the settings, and it can be dragged around the
-- rim. The same icon sits in the game's own addon menu (see MekkaBoy.toc).
local _, MB = ...

local ICON = "Interface\\AddOns\\MekkaBoy\\Art\\icon.tga"
local button

local function place()
    if not button then return end
    local angle = math.rad(MB.Opt("minimapAngle", 215))
    local radius = ((Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function build()
    if button or not Minimap then return end
    button = CreateFrame("Button", "MekkaBoyMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local back = button:CreateTexture(nil, "BACKGROUND")
    back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    back:SetSize(20, 20)
    back:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", 7, -6)
    local rim = button:CreateTexture(nil, "OVERLAY")
    rim:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    rim:SetSize(53, 53)
    rim:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            if MB.OpenOptions then MB.OpenOptions() end
        else
            MB.Toggle()
        end
    end)
    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("MekkaBoy", 1, 0.82, 0.3)
        GameTooltip:AddLine("Left-click: open or close the console.\nRight-click: settings.\nDrag: move this button.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- dragging: the button follows the mouse around the rim
    local function follow()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        if not (mx and px and scale and scale > 0) then return end
        local angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
        MB.DB().opt.minimapAngle = math.floor(angle + 0.5) % 360
        place()
    end
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", follow) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
end

-- show or hide it as the setting says (on unless switched off)
function MB.ApplyMinimapButton()
    if not Minimap then return end
    if MB.Opt("minimap", true) then
        build()
        place()
        button:Show()
    elseif button then
        button:Hide()
    end
end
MB.onLogin[#MB.onLogin + 1] = function() pcall(MB.ApplyMinimapButton) end

MB.AddCommand("minimap", "minimap on|off - the button on the minimap", function(rest)
    local db = MB.DB()
    if rest == "on" then db.opt.minimap = true elseif rest == "off" then db.opt.minimap = false
    else db.opt.minimap = not MB.Opt("minimap", true) end
    MB.ApplyMinimapButton()
    MB.Print("The minimap button is " .. (db.opt.minimap and "shown." or "hidden. /mb minimap on brings it back."))
end)
