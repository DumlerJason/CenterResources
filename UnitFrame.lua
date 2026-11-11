local ADDON, ns = ...

ns.blocks = {}
local blocks = ns.blocks
ns.UNITS = { "player", "target", "pet", "focus" }

local PVP_COLORS = {
    Horde    = { 0.85, 0.15, 0.15 },
    Alliance = { 0.20, 0.45, 0.95 },
    FFA      = { 1.00, 0.60, 0.10 },
    default  = { 0.80, 0.80, 0.80 },
}

-- Secondary resource per class (generic: shows only if the class has one and the client reports a max).
local SECONDARY = {
    ROGUE = "ComboPoints", DRUID = "ComboPoints", PALADIN = "HolyPower",
    WARLOCK = "SoulShards", MONK = "Chi", MAGE = "ArcaneCharges", EVOKER = "Essence",
}

------------------------------------------------------------
-- Helpers (secret-value safe: values go straight into
-- StatusBar / FontString APIs, no arithmetic on them)
------------------------------------------------------------
local function SetBarValue(bar, cur, max)
    bar:SetMinMaxValues(0, max)
    if Enum and Enum.StatusBarInterpolation then
        bar:SetValue(cur, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        bar:SetValue(cur)
    end
end

local function SetBarText(fs, cur, pct)
    local mode = ns.DB.general.textMode
    if mode == "none" then fs:SetText(""); return end
    local ok = pcall(function()
        if mode == "percent" then
            fs:SetFormattedText("%.0f%%", pct)
        elseif mode == "value" then
            fs:SetText(AbbreviateLargeNumbers(cur))
        else
            fs:SetFormattedText("%s  %.0f%%", AbbreviateLargeNumbers(cur), pct)
        end
    end)
    if not ok then fs:SetText("") end
end

local function GetPercent(apiFunc, cur, max, ...)
    if apiFunc and CurveConstants and CurveConstants.ScaleTo100 then
        local ok, pct = pcall(apiFunc, ...)
        if ok then return pct end
    end
    local ok, pct = pcall(function() return cur / max * 100 end)
    return ok and pct or 0
end

local function HasPower(unit)
    local ok, res = pcall(function() return UnitPowerMax(unit) > 0 end)
    if ok then return res end
    return true
end

local function UnitColor(unit)
    if UnitExists(unit) then
        if UnitIsPlayer(unit) then
            local _, class = UnitClass(unit)
            local c = class and RAID_CLASS_COLORS[class]
            if c then return c.r, c.g, c.b end
        end
        local reaction = UnitReaction(unit, "player")
        local c = reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
        if c then return c.r, c.g, c.b end
    end
    return 0.2, 0.8, 0.2
end

local function MakeText(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local font = fs:GetFont()
    fs:SetFont(font, size or 12, "OUTLINE")
    fs:SetTextColor(1, 1, 1)
    return fs
end

local function MakeBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(ns.FLAT)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", 1, -1)
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.text = MakeText(bar, 11)
    bar.text:SetPoint("CENTER")
    return bar
end

local function BarPath()
    return (ns.DB.general.barStyle == "flat") and ns.FLAT or (ns.TEX .. "Bar")
end

------------------------------------------------------------
-- Position save / restore (scale-independent offsets from screen center)
------------------------------------------------------------
local function SavePosition(b)
    local root = b.root
    local s = root:GetScale()
    local cx, cy = root:GetCenter()
    local ux, uy = UIParent:GetCenter()
    local pos = ns.GetPos(b.unit)
    if cx and ux then
        pos.x = math.floor(cx * s - ux + 0.5)
        pos.y = math.floor(cy * s - uy + 0.5)
    end
    root:ClearAllPoints()
    root:SetPoint("CENTER", UIParent, "CENTER", pos.x / s, pos.y / s)
end

------------------------------------------------------------
-- Auras: debuffs over the health bar, buffs over the power bar.
-- Midnight-safe: aura fields go straight into texture / cooldown / text APIs.
------------------------------------------------------------
local DISPEL_COLORS = {
    Magic = { 0.2, 0.6, 1 }, Curse = { 0.7, 0.2, 1 }, Disease = { 0.7, 0.5, 0.1 },
    Poison = { 0.1, 0.7, 0.2 }, Bleed = { 0.85, 0.1, 0.1 }, Enrage = { 1, 0.45, 0 },
}
local dispelCurve

local function GetDispelCurve()
    if dispelCurve == nil then
        dispelCurve = false
        pcall(function()
            local types = Enum and (Enum.SpellDispelType or Enum.DispelType)
            if C_CurveUtil and C_CurveUtil.CreateColorCurve and types and Enum.LuaCurveType then
                local curve = C_CurveUtil.CreateColorCurve()
                curve:SetType(Enum.LuaCurveType.Step)
                curve:AddPoint(0, CreateColor(0.8, 0.1, 0.1, 1))
                for name, value in pairs(types) do
                    local c = DISPEL_COLORS[name]
                    if c then curve:AddPoint(value, CreateColor(c[1], c[2], c[3], 1)) end
                end
                dispelCurve = curve
            end
        end)
    end
    return dispelCurve or nil
end

-- Every tooltip (the unit frame's own and the aura tooltips) goes to the same spot.
function ns.AnchorTooltip(b)
    GameTooltip:SetOwner(b.root, "ANCHOR_RIGHT")
end

local function ShowAuraTooltip(icon)
    if not icon.auraID then return end
    ns.AnchorTooltip(icon.block)
    local ok = false
    if icon.harmful then
        if GameTooltip.SetUnitDebuffByAuraInstanceID then
            ok = pcall(GameTooltip.SetUnitDebuffByAuraInstanceID, GameTooltip, icon.unit, icon.auraID, "HARMFUL")
        end
    else
        if GameTooltip.SetUnitBuffByAuraInstanceID then
            ok = pcall(GameTooltip.SetUnitBuffByAuraInstanceID, GameTooltip, icon.unit, icon.auraID, "HELPFUL")
        end
    end
    if ok then GameTooltip:Show() else GameTooltip:Hide() end
end

local function MakeAuraIcon(parent, block)
    local f = CreateFrame("Frame", nil, parent)
    f.block = block

    -- Hover for the tooltip, but let every click fall through to whatever is underneath.
    f:EnableMouse(true)
    if f.SetPropagateMouseClicks then
        pcall(f.SetPropagateMouseClicks, f, true)
    elseif f.SetPassThroughButtons then
        pcall(f.SetPassThroughButtons, f, "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
    end
    f:SetScript("OnEnter", function(self) self.hovering = true; ShowAuraTooltip(self) end)
    f:SetScript("OnLeave", function(self) self.hovering = false; GameTooltip:Hide() end)
    f:SetScript("OnHide", function(self)
        if self.hovering then self.hovering = false; GameTooltip:Hide() end
    end)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetPoint("TOPLEFT", -1, 1)
    f.border:SetPoint("BOTTOMRIGHT", 1, -1)
    f.border:SetColorTexture(1, 1, 1, 1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints()
    f.cd:SetDrawEdge(false)
    local over = CreateFrame("Frame", nil, f)
    over:SetAllPoints()
    over:SetFrameLevel(f.cd:GetFrameLevel() + 2)
    f.count = MakeText(over, 10)
    f.count:SetPoint("BOTTOMRIGHT", 2, -1)
    return f
end

local auraFonts = {}
local function GetAuraFont(px)
    px = math.max(6, math.floor(px + 0.5))
    local name = "CenterResourcesAuraTimer" .. px
    if not auraFonts[name] then
        local f = CreateFont(name)
        local path = GameFontNormalSmall:GetFont()
        f:SetFont(path, px, "OUTLINE")
        auraFonts[name] = true
    end
    return name
end

local function PositionIcon(set, i)
    local icon = set.icons[i]
    local size, gap = set.size, set.gap
    icon:SetSize(size, size)
    icon:ClearAllPoints()
    -- one single row, growing outward from the portrait side
    if set.onLeft then
        icon:SetPoint("BOTTOMRIGHT", set.container, "BOTTOMRIGHT", -(i - 1 + (set.offset or 0)) * (size + gap), 0)
    else
        icon:SetPoint("BOTTOMLEFT", set.container, "BOTTOMLEFT", (i - 1 + (set.offset or 0)) * (size + gap), 0)
    end
    local font = icon.count:GetFont()
    icon.count:SetFont(font, set.countPx, "OUTLINE")
    icon.cd:SetHideCountdownNumbers(set.timerPx < 7.5)
    pcall(icon.cd.SetCountdownFont, icon.cd, GetAuraFont(set.timerPx))
end

-- The happiness icon sits below the power bar, not above it.
function ns.PositionHappy(b)
    local set = b.auraSets.buffs
    local h = b.happy
    if not h or not set.size then return end
    h:SetSize(set.size, set.size)
    h:ClearAllPoints()
    if set.onLeft then
        h:SetPoint("TOPRIGHT", b.power, "BOTTOMRIGHT", 0, -3)
    else
        h:SetPoint("TOPLEFT", b.power, "BOTTOMLEFT", 0, -3)
    end
end

-- Sizes scale with the portrait size, so smaller frames (pet, focus) get smaller icons.
local function LayoutAuras(b, L, overlap, D, healthOnLeft)
    local a = ns.Cfg(b.unit).auras
    local size = math.max(8, math.floor(D * a.sizeRatio + 0.5))
    local timerPx = size * 0.40 * a.timerScale
    local countPx = math.max(7, math.floor(size * 0.45 * a.countScale + 0.5))
    for name, set in pairs(b.auraSets) do
        local bar = (name == "debuffs") and b.health or b.power
        set.onLeft = ((name == "debuffs") == healthOnLeft)
        set.size, set.gap = size, a.spacing
        set.timerPx, set.countPx = timerPx, countPx
        set.max = math.max(1, a.maxCount)
        set.container:ClearAllPoints()
        if set.onLeft then
            set.container:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", -overlap, 3)
        else
            set.container:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", overlap, 3)
        end
        for i = 1, #set.icons do PositionIcon(set, i) end
    end
    if b.happy then ns.PositionHappy(b) end
end

-- Returns a list of { id = auraInstanceID, data = auraData-or-nil }
local function GetAuraList(unit, filter, max)
    local list = {}
    if not C_UnitAuras then return list end
    if C_UnitAuras.GetUnitAuras then
        local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter, max)
        if ok and type(auras) == "table" then
            for _, a in ipairs(auras) do
                list[#list + 1] = { id = a.auraInstanceID, data = a }
            end
            return list
        end
    end
    if C_UnitAuras.GetUnitAuraInstanceIDs then
        local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, max)
        if ok and type(ids) == "table" then
            for _, id in ipairs(ids) do list[#list + 1] = { id = id } end
        end
    end
    return list
end

local function ApplyAuraIcon(icon, unit, entry, harmful)
    local id = entry.id
    local data = entry.data or C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id)
    if not data then return false end
    icon.tex:SetTexture(data.icon)
    icon.unit, icon.auraID, icon.harmful = unit, id, harmful

    pcall(function()
        local d = C_UnitAuras.GetAuraDuration(unit, id)
        if d then icon.cd:SetCooldownFromDurationObject(d, true) else icon.cd:Clear() end
    end)

    icon.count:SetText("")
    pcall(function() icon.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(unit, id, 2)) end)

    if harmful then
        local ok = false
        local curve = GetDispelCurve()
        if curve then
            ok = pcall(function()
                local col = C_UnitAuras.GetAuraDispelTypeColor(unit, id, curve)
                icon.border:SetVertexColor(col:GetRGBA())
            end)
        end
        if not ok then icon.border:SetVertexColor(0.8, 0.1, 0.1, 1) end
    else
        icon.border:SetVertexColor(0, 0, 0, 1)
    end
    icon:Show()
    if icon.hovering then ShowAuraTooltip(icon) end
    return true
end

local function MakeNativeAuraButton(button, harmful, set, block)
    button:EnableMouse(true)
    button._crUnit = block and block.unit or button._crUnit
    button._crFilter = harmful and "HARMFUL" or "HELPFUL"

    if button._crNativeReady then
        return
    end
    button._crNativeReady = true

    local size = button._crNativeSize or 16
    button:SetSize(size, size)

    local tex = button:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.Icon = tex
    button.icon = tex
    button:SetIcon(tex)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints()
    button.Cooldown = cd
    button:SetDurationCooldown(cd)
    if set then
        cd:SetHideCountdownNumbers((set.timerPx or size) < 7.5)
        if cd.SetCountdownFont then pcall(cd.SetCountdownFont, cd, GetAuraFont(set.timerPx or size)) end
    end

    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -1, 1)
    if set then
        local font = count:GetFont() or GameFontNormalSmall:GetFont()
        count:SetFont(font, set.countPx or 10, "OUTLINE")
    end
    button.Count = count
    button:SetApplicationCount(count)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 0)
    button.Border = border

    button:SetScript("OnEnter", function(self)
        local unit = self._crUnit or (block and block.unit) or self.unit
        local id = self.auraInstanceID or self._crAuraID
        if not unit or not id then return end
        ns.AnchorTooltip(block)
        local filter = self._crFilter or (harmful and "HARMFUL" or "HELPFUL")
        if filter == "HARMFUL" and GameTooltip.SetUnitDebuffByAuraInstanceID then
            pcall(GameTooltip.SetUnitDebuffByAuraInstanceID, GameTooltip, unit, id, "HARMFUL")
        elseif filter == "HELPFUL" and GameTooltip.SetUnitBuffByAuraInstanceID then
            pcall(GameTooltip.SetUnitBuffByAuraInstanceID, GameTooltip, unit, id, "HELPFUL")
        else
            pcall(GameTooltip.SetUnit, GameTooltip, unit)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnHide", function() GameTooltip:Hide() end)

    if harmful then
        button:SetDispelTypeTexture(border, {
            showWhenHelpful = false,
            showWhenHarmful = true,
            style = Enum.CustomAuraButtonDispelTypeTextureStyle.Border,
        })
    else
        button:SetDispelTypeTexture(border, {
            showWhenHelpful = true,
            showWhenHarmful = false,
            style = Enum.CustomAuraButtonDispelTypeTextureStyle.Border,
        })
    end
end

local function TryAltAuraMethod(b)
    local cfg = ns.Cfg(b.unit).auras
    if not cfg.enabled then
        if b.altAuras then
            for _, native in pairs(b.altAuras) do
                if native and native.Hide then pcall(native.Hide, native) end
            end
        end
        return true
    end

    local unitID = UnitExists(b.unit) and (UnitGUID(b.unit) or UnitName(b.unit) or b.unit) or nil
    if b.altAuras and b.altAuras._unitID ~= unitID then
        for _, native in pairs(b.altAuras) do
            if native and native.SetUnit then pcall(native.SetUnit, native, nil) end
            if native and native.ClearAllAuras then pcall(native.ClearAllAuras, native) end
            if native and native.Hide then pcall(native.Hide, native) end
        end
        b.altAuras = {}
    end

    if not b.altAuras then
        b.altAuras = {}
    end
    b.altAuras._unitID = unitID

    for _, name in ipairs({ "debuffs", "buffs" }) do
        local set = b.auraSets[name]
        local native = b.altAuras[name]

        if not native then
            local ok, frame = pcall(CreateFrame, "AuraContainer", nil, b.root, "CustomAuraContainerTemplate")
            if not ok or not frame then
                ns.Print("Native aura method failed to create " .. name .. " AuraContainer for " .. b.unit .. ": " .. tostring(frame or "unknown"))
                return true
            end

            native = frame
            b.altAuras[name] = native
            native._crUnit = b.unit
            native._crNativeSize = math.max(8, math.floor((set.size or 16) + 0.5))
            native._crNativeGap = cfg.spacing
            native:SetFrameLevel(b.root:GetFrameLevel() + 2)
            native:SetSize(math.max(1, (native._crNativeSize + native._crNativeGap) * math.max(1, cfg.maxCount) - native._crNativeGap), native._crNativeSize + 4)
            native:Hide()
        end

        local offset = (b.happyIcon and name == "buffs") and 1 or 0
        local startX = offset * (native._crNativeSize + native._crNativeGap)
        native:ClearAllPoints()
        if set.onLeft then
            native:SetPoint("BOTTOMRIGHT", set.container, "BOTTOMRIGHT", -startX, 0)
        else
            native:SetPoint("BOTTOMLEFT", set.container, "BOTTOMLEFT", startX, 0)
        end

        if native.SetFlowLayoutAnchorPoint then pcall(native.SetFlowLayoutAnchorPoint, native, set.onLeft and "BOTTOMRIGHT" or "BOTTOMLEFT") end
        if native.SetFlowLayoutGrowthDirection then
            local dirX = set.onLeft and -1 or 1
            pcall(native.SetFlowLayoutGrowthDirection, native, dirX, 1)
        end
        if native.SetFlowLayoutPadding then pcall(native.SetFlowLayoutPadding, native, 0, 0, 0, 0) end
        if AnchorUtil and AnchorUtil.FlowLayoutAxis and native.SetFlowLayoutAxis then
            pcall(native.SetFlowLayoutAxis, native, AnchorUtil.FlowLayoutAxis.Horizontal)
        end
        if native.SetFlowLayoutMaximumLineSize then pcall(native.SetFlowLayoutMaximumLineSize, native, math.max(1, native:GetWidth())) end

        if native and native.AddAuraGroup and not native._crReady then
            local ok, err = pcall(function()
                native:AddAuraGroup(name, set.filter, {
                    maxFrameCount = cfg.maxCount,
                    layout = {
                        elementWidth = native._crNativeSize or 16,
                        elementHeight = native._crNativeSize or 16,
                        elementSpacing = native._crNativeGap or cfg.spacing,
                        lineSpacing = native._crNativeGap or cfg.spacing,
                        groupSpacing = 0,
                        groupLineSpacing = 0,
                        forceNewLine = false,
                    },
                    initializeFrame = function(button)
                        button._crNativeSize = native._crNativeSize or 16
                        MakeNativeAuraButton(button, name == "debuffs", set, b)
                    end,
                })
                native:UpdateAllAuras()
            end)
            if not ok then
                native:Hide()
                native._crReady = false
                ns.Print("Native aura method failed for " .. b.unit .. " " .. name .. ": " .. tostring(err))
                return true
            end
            native._crReady = true
        end

        if native and native._crReady then
            local ok, err = pcall(function()
                local offset = (b.happyIcon and name == "buffs") and 1 or 0
                local startX = offset * (native._crNativeSize + native._crNativeGap)
                native:ClearAllPoints()
                if set.onLeft then
                    native:SetPoint("BOTTOMRIGHT", set.container, "BOTTOMRIGHT", -startX, 0)
                else
                    native:SetPoint("BOTTOMLEFT", set.container, "BOTTOMLEFT", startX, 0)
                end
                if native.SetFlowLayoutGrowthDirection then
                    local dirX = set.onLeft and -1 or 1
                    pcall(native.SetFlowLayoutGrowthDirection, native, dirX, 1)
                end

                if native.SetUnit then pcall(native.SetUnit, native, nil) end
                if native.ClearAllAuras then pcall(native.ClearAllAuras, native) end
                native:Hide()
                native._crUnit = b.unit

                if native.SetEnabled then native:SetEnabled(true) end
                if native.SetUnit then native:SetUnit(b.unit) end
                if native.UpdateAllAuras then native:UpdateAllAuras() end
                if UnitExists(b.unit) then
                    native:Show()
                else
                    native:Hide()
                end
            end)
            if not ok then
                native:Hide()
                native._crReady = false
                ns.Print("Native aura method update failed for " .. b.unit .. " " .. name .. ": " .. tostring(err))
                return true
            end

            for i = 1, #set.icons do
                set.icons[i]:Hide()
            end
        end
    end

    for _, name in ipairs({ "debuffs", "buffs" }) do
        local native = b.altAuras and b.altAuras[name]
        if native and native:IsShown() then
            return true
        end
    end
    return true
end

function ns.UpdateAuras(b)
    -- Native AuraContainer rendering is now the only aura path.
    TryAltAuraMethod(b)
end

------------------------------------------------------------
-- Pet happiness (WoW Forever: three states, exact value is restricted)
-- Preferred: Blizzard's own happiness icon in the FIRST buff slot.
-- Fallback:  a coloured pip beside the portrait, like the PvP flag.
------------------------------------------------------------
local HAPPY_TEX = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
local HAPPY_COORDS = {
    [1] = { 0.375,  0.5625, 0, 0.359375 },  -- unhappy
    [2] = { 0.1875, 0.375,  0, 0.359375 },  -- content
    [3] = { 0,      0.1875, 0, 0.359375 },  -- happy
}
local MOOD = {
    [1] = { "Unhappy", 0.9, 0.2, 0.2 },
    [2] = { "Content", 1.0, 0.85, 0.2 },
    [3] = { "Happy",   0.2, 0.9, 0.2 },
}
local happyTexOK

local function HappyIconUsable()
    if happyTexOK == nil then
        happyTexOK = true
        if GetFileIDFromPath then
            local ok, id = pcall(function()
                return GetFileIDFromPath(HAPPY_TEX) or GetFileIDFromPath(HAPPY_TEX .. ".blp")
            end)
            if ok and not id then happyTexOK = false end
        end
    end
    return happyTexOK
end

local function Plain(v)
    return type(v) == "number" and not (issecretvalue and issecretvalue(v))
end

-- WoW Forever has no global GetPetHappiness; it is C_PetInfo.GetPetHappiness().
-- (The classic global is kept as a fallback for other clients.)
local function CallHappiness()
    local fn = (C_PetInfo and C_PetInfo.GetPetHappiness) or GetPetHappiness
    if not fn then return nil end
    local a, b, c = fn()
    if a == nil then a, b, c = fn("pet") end -- some builds want the unit token
    return a, b, c
end

-- Returns state (1-3), damage %, loyalty rate; or nil when unavailable.
local function ReadHappiness()
    if not UnitExists("pet") then return nil end
    local ok, h, dmg, loy = pcall(function()
        local a, b, c = CallHappiness()
        if Plain(a) and a >= 1 and a <= 3 then
            return a, Plain(b) and b or nil, Plain(c) and c or nil
        end
    end)
    if ok then return h, dmg, loy end
    return nil
end

function ns.ShowHappinessTooltip(b)
    local h, dmg, loy = ReadHappiness()
    if not h then return end
    local m = MOOD[h]
    ns.AnchorTooltip(b)
    GameTooltip:ClearLines()
    GameTooltip:SetText("Pet is " .. m[1], m[2], m[3], m[4])
    if dmg then
        GameTooltip:AddLine(string.format("Damage: %d%%", dmg), 1, 1, 1)
    end
    if loy and loy ~= 0 then
        GameTooltip:AddLine(loy > 0 and "Gaining loyalty" or "Losing loyalty", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

function ns.UpdateHappiness(b)
    if b.unit ~= "pet" or not b.happy then return end
    local mode = ns.Cfg("pet").happiness
    local h = ReadHappiness()
    local style = mode
    if mode == "auto" then style = HappyIconUsable() and "icon" or "pip" end

    local showIcon = (h and style == "icon") and true or false
    local showPip  = (h and style == "pip") and true or false

    if showIcon then
        local c, m = HAPPY_COORDS[h], MOOD[h]
        b.happy.tex:SetTexCoord(c[1], c[2], c[3], c[4])
        b.happy.border:SetVertexColor(m[2], m[3], m[4], 1)
        ns.PositionHappy(b)
        b.happy:Show()
    else
        b.happy:Hide()
    end
    if showPip then
        local m = MOOD[h]
        b.happyPip:SetVertexColor(m[2], m[3], m[4])
        b.happyPip:Show()
    else
        b.happyPip:Hide()
    end

    -- the buff row shifts by one slot while the icon is shown
    if b.happyIcon ~= showIcon then
        b.happyIcon = showIcon
        ns.UpdateAuras(b)
    end
end

-- For /cr pet: shows exactly what the client reports so problems are easy to diagnose.
function ns.DescribeHappiness()
    local lines = {}
    local function S(v)
        if issecretvalue and issecretvalue(v) then return "<secret>" end
        return tostring(v)
    end
    local function Try(label, fn, ...)
        if not fn then
            lines[#lines + 1] = label .. ": does not exist"
            return
        end
        local ok, a, b, c = pcall(fn, ...)
        lines[#lines + 1] = label .. " -> ok=" .. S(ok) .. "  " .. S(a) .. ", " .. S(b) .. ", " .. S(c)
    end
    Try("C_PetInfo.GetPetHappiness()", C_PetInfo and C_PetInfo.GetPetHappiness)
    Try("GetPetHappiness() (classic global)", GetPetHappiness)
    lines[#lines + 1] = "pet exists: " .. S(UnitExists("pet")) ..
        "   icon texture usable: " .. S(HappyIconUsable()) ..
        "   setting: " .. S(ns.Cfg("pet").happiness)
    local h, dmg, loy = ReadHappiness()
    lines[#lines + 1] = "addon reads: state=" .. S(h) .. " damage=" .. S(dmg) .. " loyalty=" .. S(loy)
    return lines
end

function ns.DescribeAuraState()
    local lines = {}
    local function S(v)
        if v == nil then return "nil" end
        if type(v) == "boolean" then return v and "true" or "false" end
        if type(v) == "table" then return "table" end
        if issecretvalue and issecretvalue(v) then return "<secret>" end
        return tostring(v)
    end

    for _, unit in ipairs(ns.UNITS) do
        local b = ns.blocks and ns.blocks[unit]
        local cfg = b and ns.Cfg(unit).auras or nil
        lines[#lines + 1] = "unit=" .. unit .. " enabled=" .. S(cfg and cfg.enabled)
        if not b then
            lines[#lines + 1] = "  no block created"
        else
            local f = b.altAuras
            local anyNative = false
            if type(f) == "table" then
                for _, native in pairs(f) do
                    if native and native.IsShown and native:IsShown() then anyNative = true end
                end
            elseif f and f.IsShown then
                anyNative = f:IsShown()
            end
            lines[#lines + 1] = "  AuraContainer exists=" .. S(f ~= nil) .. " ready=" .. S(b.altAurasReady) .. " visible=" .. S(anyNative)
            if type(f) == "table" then
                lines[#lines + 1] = "  groups=" .. S(next(f) ~= nil)
            end
        end
    end
    return lines
end

------------------------------------------------------------
-- Block creation
------------------------------------------------------------
local function CreateBlock(unit)
    local b = { unit = unit }

    local root = CreateFrame("Button", "CenterResources_" .. unit, UIParent, "SecureUnitButtonTemplate")
    b.root = root
    root.unit = unit
    root:SetFrameStrata("LOW")
    root:SetAttribute("unit", unit)
    root:SetAttribute("*type1", "target")
    root:SetAttribute("*type2", "togglemenu")
    root:RegisterForClicks("AnyUp")
    root:RegisterForDrag("LeftButton")
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    local lvl = root:GetFrameLevel()

    -- bars (not clickable: plain StatusBars take no mouse input)
    b.health = MakeBar(root); b.health:SetFrameLevel(lvl + 1)
    b.power  = MakeBar(root); b.power:SetFrameLevel(lvl + 1)

    -- portrait, masked into a circle, above the bars
    local pf = CreateFrame("Frame", nil, root)
    pf:SetAllPoints(root)
    pf:SetFrameLevel(lvl + 3)
    b.portraitFrame = pf

    b.disk = pf:CreateTexture(nil, "BACKGROUND")
    b.disk:SetAllPoints()
    b.disk:SetTexture(ns.TEX .. "Mask")
    b.disk:SetVertexColor(0, 0, 0, 0.65)

    b.portrait = pf:CreateTexture(nil, "ARTWORK")
    b.portrait:SetAllPoints()
    local mask = pf:CreateMaskTexture()
    mask:SetAllPoints()
    mask:SetTexture(ns.TEX .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    b.portrait:AddMaskTexture(mask)

    b.ring = pf:CreateTexture(nil, "OVERLAY")
    b.ring:SetAllPoints()
    b.ring:SetTexture(ns.TEX .. "Ring")

    -- status icons
    local icons = CreateFrame("Frame", nil, root)
    icons:SetAllPoints(root)
    icons:SetFrameLevel(lvl + 6)
    b.iconFrame = icons

    b.pvp = icons:CreateTexture(nil, "OVERLAY")
    b.pvp:SetTexture(ns.TEX .. "Pip")

    b.combat = icons:CreateTexture(nil, "OVERLAY")
    b.combat:SetTexture("Interface\\CharacterFrame\\UI-StateIcon")
    b.combat:SetTexCoord(0.5, 1, 0, 0.484375)

    b.leader = icons:CreateTexture(nil, "OVERLAY")
    b.leader:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")

    b.marker = icons:CreateTexture(nil, "OVERLAY")
    b.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")

    b.resting = MakeText(icons, 14)
    b.resting:SetText("zZz")
    b.resting:SetTextColor(0.6, 0.8, 1)

    b.level = MakeText(icons, 12)
    b.name  = MakeText(icons, 12)

    -- secondary resource row (player only)
    b.pips = {}
    if unit == "player" then
        b.sec = CreateFrame("Frame", nil, root)
        b.sec:SetFrameLevel(lvl + 2)
    end

    -- aura containers (icons are created on demand)
    b.auraSets = {
        debuffs = { filter = "HARMFUL", icons = {}, container = CreateFrame("Frame", nil, root) },
        buffs   = { filter = "HELPFUL", icons = {}, container = CreateFrame("Frame", nil, root) },
    }
    for _, set in pairs(b.auraSets) do
        set.container:SetSize(1, 1)
        set.container:SetFrameLevel(lvl + 2)
    end

    if unit == "pet" then
        b.happy = MakeAuraIcon(b.auraSets.buffs.container, b)
        b.happy.tex:SetTexture(HAPPY_TEX)
        b.happy:SetScript("OnEnter", function() ns.ShowHappinessTooltip(b) end)
        b.happy:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b.happy:Hide()
        b.happyPip = icons:CreateTexture(nil, "OVERLAY")
        b.happyPip:SetTexture(ns.TEX .. "Pip")
        b.happyPip:Hide()
    end

    -- unlock overlay
    local ov = CreateFrame("Frame", nil, root)
    ov:SetFrameLevel(lvl + 8)
    local ot = ov:CreateTexture(nil, "BACKGROUND")
    ot:SetAllPoints()
    ot:SetColorTexture(0.2, 1, 0.2, 0.18)
    ov.label = MakeText(ov, 12)
    ov.label:SetPoint("TOP", 0, -2)
    ov.label:SetText(unit:sub(1, 1):upper() .. unit:sub(2) .. " - drag to move")
    ov:Hide()
    b.overlay = ov

    -- scripts
    root:SetScript("OnDragStart", function(self)
        if not ns.DB.general.locked and not InCombatLockdown() then self:StartMoving() end
    end)
    root:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false)
        SavePosition(b)
    end)
    root:SetScript("OnEnter", function(self)
        if UnitExists(unit) then
            ns.AnchorTooltip(b)
            pcall(GameTooltip.SetUnit, GameTooltip, unit)
            GameTooltip:Show()
        end
    end)
    root:SetScript("OnLeave", function() GameTooltip:Hide() end)
    root:HookScript("OnShow", function() ns.Safe(ns.UpdateBlock, b) end)

    blocks[unit] = b
    return b
end

function ns.InitBlocks()
    for _, unit in ipairs(ns.UNITS) do CreateBlock(unit) end
end

------------------------------------------------------------
-- Layout (out of combat only; protected frames)
------------------------------------------------------------
local function LayoutPips(b, n, powerType)
    local size = ns.DB.general.secondarySize
    local gap = 3
    b.sec:SetSize(math.max(1, n * size + (n - 1) * gap), size)
    local c = PowerBarColor and PowerBarColor[powerType] or { r = 1, g = 0.9, b = 0.2 }
    for i = 1, 10 do
        local pip = b.pips[i]
        if i <= n then
            if not pip then
                pip = CreateFrame("StatusBar", nil, b.sec)
                pip:SetStatusBarTexture(ns.FLAT)
                local bg = pip:CreateTexture(nil, "BACKGROUND")
                bg:SetPoint("TOPLEFT", -1, 1)
                bg:SetPoint("BOTTOMRIGHT", 1, -1)
                bg:SetColorTexture(0, 0, 0, 0.65)
                pip:SetMinMaxValues(i - 1, i)
                b.pips[i] = pip
            end
            pip:SetSize(size, size)
            pip:ClearAllPoints()
            pip:SetPoint("TOPLEFT", b.sec, "TOPLEFT", (i - 1) * (size + gap), 0)
            pip:SetStatusBarColor(c.r, c.g, c.b)
            pip:Show()
        elseif pip then
            pip:Hide()
        end
    end
    b.secN, b.secSize, b.secType = n, size, powerType
end

local function ApplyLock(b)
    local c = ns.Cfg(b.unit)
    local g = ns.DB.general
    local root = b.root
    local L = c.barLength - c.portraitSize * c.barOverlap / 100

    b.overlay:SetShown(not g.locked and c.enabled)
    if g.locked then
        root:SetHitRectInsets(0, 0, 0, 0)
    else
        root:SetHitRectInsets(-L, -L, -10, -30)
    end

    if b.unit == "player" then
        root:SetShown(c.enabled)
    elseif c.enabled and g.locked then
        RegisterUnitWatch(root)          -- show/hide with the unit, even in combat
    else
        UnregisterUnitWatch(root)
        root:SetShown(c.enabled and not g.locked) -- preview while unlocked
    end
end

local function LayoutBlock(b)
    local c = ns.Cfg(b.unit)
    local g = ns.DB.general
    local root = b.root
    local D, L, H = c.portraitSize, c.barLength, c.barHeight
    local R = D / 2

    root:SetScale(c.scale)
    root:SetSize(D, D)
    root:ClearAllPoints()
    local pos = ns.GetPos(b.unit)
    root:SetPoint("CENTER", UIParent, "CENTER", pos.x / c.scale, pos.y / c.scale)

    local overlap = D * c.barOverlap / 100
    local left, right = b.health, b.power
    if c.mirror then left, right = b.power, b.health end

    left:ClearAllPoints()
    left:SetSize(L, H)
    left:SetPoint("RIGHT", root, "LEFT", overlap, 0)
    left:SetReverseFill(true)

    right:ClearAllPoints()
    right:SetSize(L, H)
    right:SetPoint("LEFT", root, "RIGHT", -overlap, 0)
    right:SetReverseFill(false)

    local fontSize = math.max(9, math.floor(H * 0.65))
    for _, bar in ipairs({ b.health, b.power }) do
        local font = bar.text:GetFont()
        bar.text:SetFont(font, fontSize, "OUTLINE")
    end

    b.ring:SetShown(g.showRing)

    -- icons around the portrait
    b.iconFrame:SetShown(c.showIcons)
    local s = math.max(10, D * 0.26)
    local function Place(obj, deg, size, push)
        local rad = math.rad(deg)
        obj:ClearAllPoints()
        obj:SetPoint("CENTER", root, "CENTER", math.cos(rad) * R * (push or 1), math.sin(rad) * R * (push or 1))
        if size then obj:SetSize(size, size) end
    end
    Place(b.pvp,     45,  s * 0.7)
    Place(b.combat,  135, s * 1.1)
    Place(b.leader, -135, s * 0.9)
    Place(b.marker,  90,  s * 1.0, 1.05)
    Place(b.resting, -45, nil)
    Place(b.level,  -90,  nil, 1.0)
    if b.happyPip then Place(b.happyPip, -45, s * 0.7) end

    b.name:ClearAllPoints()
    b.name:SetPoint("TOP", b.health, "BOTTOM", 0, -2)
    b.name:SetShown(c.showName)

    if b.sec then
        b.sec:ClearAllPoints()
        b.sec:SetPoint("TOP", root, "BOTTOM", 0, -16)
    end

    LayoutAuras(b, L, overlap, D, not c.mirror)

    -- unlock overlay extents
    local ext = L - overlap + 6
    b.overlay:ClearAllPoints()
    b.overlay:SetPoint("TOPLEFT", root, "TOPLEFT", -ext, 14)
    b.overlay:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", ext, -26)
end

------------------------------------------------------------
-- Updates
------------------------------------------------------------
function ns.UpdateHealth(b)
    local unit = b.unit
    if not UnitExists(unit) then
        SetBarValue(b.health, 1, 1)
        b.health.text:SetText("")
        return
    end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    SetBarValue(b.health, cur, max)
    local pct = GetPercent(UnitHealthPercent, cur, max,
        unit, true, CurveConstants and CurveConstants.ScaleTo100)
    SetBarText(b.health.text, cur, pct)
end

function ns.UpdatePower(b)
    local unit = b.unit
    if not UnitExists(unit) then
        SetBarValue(b.power, 1, 1)
        b.power.text:SetText("")
        b.power:SetStatusBarColor(0.3, 0.4, 0.9)
        b.power:Show()
        return
    end
    if not HasPower(unit) then
        b.power:Hide()
        return
    end
    b.power:Show()
    local pType, token = UnitPowerType(unit)
    local cur, max = UnitPower(unit, pType), UnitPowerMax(unit, pType)
    SetBarValue(b.power, cur, max)
    local c = PowerBarColor and ((token and PowerBarColor[token]) or PowerBarColor[pType])
    if c then b.power:SetStatusBarColor(c.r, c.g, c.b) else b.power:SetStatusBarColor(0.5, 0.5, 0.5) end
    local pct = GetPercent(UnitPowerPercent, cur, max,
        unit, pType, false, CurveConstants and CurveConstants.ScaleTo100)
    SetBarText(b.power.text, cur, pct)
end

function ns.UpdateColors(b)
    local g = ns.DB.general
    if g.healthColor == "class" then
        b.health:SetStatusBarColor(UnitColor(b.unit))
    else
        b.health:SetStatusBarColor(0.2, 0.8, 0.2)
    end
    if g.showRing then
        b.ring:SetVertexColor(UnitColor(b.unit))
    end
end

function ns.UpdatePortrait(b)
    local unit = b.unit
    SetPortraitTexture(b.portrait, UnitExists(unit) and unit or "player")
    b.portrait:SetDesaturated(UnitExists(unit) and UnitIsDeadOrGhost(unit) and true or false)
end

function ns.UpdateInfo(b)
    local unit = b.unit
    if not UnitExists(unit) then
        b.name:SetText(""); b.level:SetText("")
        return
    end
    b.name:SetText(UnitName(unit) or "")
    local lvl = UnitLevel(unit)
    if lvl and lvl > 0 then b.level:SetText(lvl) else b.level:SetText("??") end
end

function ns.UpdateIcons(b)
    local unit = b.unit
    local exists = UnitExists(unit)

    -- PvP pip
    local col
    if exists and UnitIsPVPFreeForAll(unit) then
        col = PVP_COLORS.FFA
    elseif exists and UnitIsPVP(unit) then
        col = PVP_COLORS[UnitFactionGroup(unit) or ""] or PVP_COLORS.default
    end
    if col then
        b.pvp:SetVertexColor(col[1], col[2], col[3])
        b.pvp:Show()
    else
        b.pvp:Hide()
    end

    b.combat:SetShown(exists and UnitAffectingCombat(unit) and true or false)
    b.resting:SetShown(unit == "player" and IsResting() and true or false)
    b.leader:SetShown(exists and UnitIsGroupLeader(unit) and true or false)

    local idx = exists and GetRaidTargetIndex(unit)
    if idx then
        SetRaidTargetIconTexture(b.marker, idx)
        b.marker:Show()
    else
        b.marker:Hide()
    end
end

local function FindSecondary()
    local _, class = UnitClass("player")
    local key = class and SECONDARY[class]
    local t = key and Enum and Enum.PowerType and Enum.PowerType[key]
    if not t then return nil end
    local ok, max = pcall(UnitPowerMax, "player", t)
    if not ok then return nil end
    if issecretvalue and issecretvalue(max) then return nil end
    if type(max) == "number" and max > 0 then return t, math.min(max, 10) end
    return nil
end

function ns.UpdateSecondary(b)
    if not b.sec then return end
    if not ns.DB.general.secondaryEnabled then b.sec:Hide(); return end
    local t, n = FindSecondary()
    if not t then b.sec:Hide(); return end
    b.sec:Show()
    if b.secN ~= n or b.secSize ~= ns.DB.general.secondarySize or b.secType ~= t then
        LayoutPips(b, n, t)
    end
    local cur = UnitPower("player", t)
    for i = 1, n do b.pips[i]:SetValue(cur) end
end

function ns.UpdateAlpha()
    local b = blocks.player
    if not b then return end
    local g = ns.DB.general
    if not g.locked then
        b.root:SetAlpha(1)
    elseif UnitAffectingCombat("player") then
        b.root:SetAlpha(g.combatAlpha)
    else
        b.root:SetAlpha(g.idleAlpha)
    end
end

function ns.UpdateBlock(b)
    ns.Safe(ns.UpdateColors, b)
    ns.Safe(ns.UpdateHealth, b)
    ns.Safe(ns.UpdatePower, b)
    ns.Safe(ns.UpdatePortrait, b)
    ns.Safe(ns.UpdateInfo, b)
    ns.Safe(ns.UpdateIcons, b)
    ns.Safe(ns.UpdateSecondary, b)
    ns.Safe(ns.UpdateHappiness, b)
    ns.Safe(ns.UpdateAuras, b)
end

------------------------------------------------------------
-- Refresh (applies settings; deferred during combat)
------------------------------------------------------------
-- Optionally hide Blizzard's own unit frames. We only touch alpha and the clickable
-- area (no re-parenting, no moving), which is the least likely way to cause taint.
local BLIZZ = { player = "PlayerFrame", target = "TargetFrame", pet = "PetFrame", focus = "FocusFrame" }
local hooked, hidden, touched = {}, {}, {}
local settingAlpha = false

function ns.ApplyBlizzard(unit)
    local f = _G[BLIZZ[unit]]
    if not f then return end
    local hide = ns.Cfg(unit).hideDefault
    if hide then
        if not hooked[f] then
            hooked[f] = true
            hooksecurefunc(f, "SetAlpha", function(self, a)
                if hidden[self] and a ~= 0 and not settingAlpha then
                    settingAlpha = true
                    self:SetAlpha(0)
                    settingAlpha = false
                end
            end)
        end
        hidden[f] = true
        touched[f] = true
        settingAlpha = true
        f:SetAlpha(0)
        settingAlpha = false
        f:SetHitRectInsets(10000, 10000, 10000, 10000)
    elseif touched[f] then
        hidden[f] = nil
        touched[f] = nil
        f:SetAlpha(1)
        f:SetHitRectInsets(0, 0, 0, 0)
    end
end

function ns.RefreshAll()
    local path = BarPath()
    for _, unit in ipairs(ns.UNITS) do
        local b = blocks[unit]
        if b then
            b.health:SetStatusBarTexture(path)
            b.power:SetStatusBarTexture(path)
            ns.Safe(LayoutBlock, b)
            ns.Safe(ApplyLock, b)
            ns.Safe(ns.ApplyBlizzard, unit)
            if b.sec then b.secN = nil end -- force pip relayout
            ns.UpdateBlock(b)
        end
    end
    ns.UpdateAlpha()
end

function ns.Refresh()
    if InCombatLockdown() then
        if not ns.pendingRefresh then
            ns.Print("in combat - changes will apply when combat ends.")
        end
        ns.pendingRefresh = true
        return
    end
    ns.RefreshAll()
end
