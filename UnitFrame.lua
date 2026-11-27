local ADDON, ns = ...

ns.blocks = {}
local blocks = ns.blocks
ns.UNITS = { "player", "target", "targettarget", "pet", "focus" }
-- Names shown on the unlock overlay (anything not listed is just the capitalised unit token).
ns.UNIT_LABELS = { targettarget = "Target of Target" }

local PVP_COLORS = {
    Horde    = { 0.85, 0.15, 0.15 },
    Alliance = { 0.20, 0.45, 0.95 },
    FFA      = { 1.00, 0.60, 0.10 },
    default  = { 0.80, 0.80, 0.80 },
}

-- Portrait artwork. All four files are 256x256 with a transparent margin around the shape
-- (room for a future glow). Insets are in texels of the 256 canvas.
local ART = {
    size        = 256,
    ringInset   = 16,   -- portrait_ring.tga: transparent margin on each side
    borderInset = 12,   -- portrait_border.tga: transparent margin on each side
    -- Which inset should land exactly on the portrait diameter D (portraitSize)? Using the
    -- border's means the outer edge of the frame sits on D, which is where the status badges
    -- are placed. All files share one canvas size, so they stay aligned with each other.
    fitInset    = 12,
    ring   = "portrait_ring",
    border = "portrait_border",
    mask   = "portrait_mask",
    portraitScale = 0.92,                       -- portrait + mask + backdrop size vs. the canvas (smaller = more of the frame shows)
    portraitZoom  = 1.10,   -- 1.0 = whole portrait image, 1.2 = zoomed in 20% (crops the edges)
    portraitShift = 0.05,   -- + moves the image DOWN inside the frame, - moves it up (fraction of the image height)
    borderColor   = { 1.00, 0.82, 0.00, 1 },    -- Blizzard-style gold
    showBorder   = false,                -- portrait_border.tga hidden; set true to bring it back
    backingColor = { 0, 0, 0, 0.6 },     -- black backing circle, same opacity as the bar backdrops
    backingPad   = 4,                    -- extra pixels of black around the portrait edge    
}

-- Combat glow (player frame only): see the rules above ns.UpdateGlow; every transition takes GLOW.fade.
--   ring_glow.tga is 16px larger than portrait_ring.tga on each axis (272 vs 256 canvas).
--   bar_glow.tga (272x32) is drawn as an 8px-edge 9-slice around each bar: the corners stay 8x8 real
--   pixels, the edges stretch along the bar, and the transparent centre is skipped.
local GLOW = {
    fade     = 0.15,                       -- seconds to fade in and out
    color    = { 1.00, 0.00, 0.00 },
    ringFile = "ring_glow",  ringSize = 272,           -- ring canvas size ART.size = 256
    barFile  = "bar_glow",   barTexW = 272, barTexH = 32, barEdge = 8,   -- 272x32; visible glow band is 8px on every side, interior transparent
    units    = { player = true },          -- player frame only
}

-- Incoming heals and shields (absorbs), drawn as translucent overlays on the health bar.
--   Incoming heals start where the current health ends (clamped to the missing health).
--   Shields: shieldStyle "end"      = drawn from the OUTER end of the bar inwards (always visible, even at full health)
--            shieldStyle "attached" = drawn after health + incoming heals (hidden when health is full)
local PREDICT = {
    units       = { player = true, target = true },
    healColor   = { 1.00, 1.00, 1.00, 0.40 },     -- translucent white
    shieldColor = { 1.00, 0.97, 0.70, 0.50 },     -- translucent light yellow / white
    shieldStyle = "end",
}

-- Faction emblems drawn ON TOP of the coloured Pip.tga disc.
local PVP_ICONS = {
    Horde    = "Interface\\TargetingFrame\\UI-PVP-Horde",
    Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance",
    FFA      = "Interface\\TargetingFrame\\UI-PVP-FFA",
}
local PVP_TC = { 0, 0.609375, 0, 0.640625 }

-- Status badge ("pip") artwork. Both files are 64x64 with a transparent margin; insets in texels.
local PIP = {
    size        = 64,
    bgInset     = 18,   -- pip_background.tga margin
    borderInset = 12,   -- pip_border.tga margin
    fitInset    = 12,   -- the border's outer edge defines the badge diameter
    bg     = "pip_background",
    border = "pip_border",
    borderColor = ART.borderColor,
}
-- how big the background disc is relative to the badge's outer (border) diameter
PIP.discRatio = (PIP.size - 2 * PIP.bgInset) / (PIP.size - 2 * PIP.fitInset)

-- Background colour (r, g, b, a) of every badge except PvP (which is faction-coloured).
local BADGE_BG = { 0, 0, 0, 1 }     -- fully opaque so nothing shows through a badge

-- Show/hide a badge's background and its border together.
local function ShowBadge(bg, shown)
    bg:SetShown(shown)
    if bg.border then bg.border:SetShown(shown) end
end

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

local function SetBarText(fs, cur, max)
    local ok = pcall(function()
        fs:SetText(string.format("%s/%s", AbbreviateNumbers(cur), AbbreviateNumbers(max)))
    end)
    if not ok then fs:SetText("") end
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

-- Return the block for the unit name.
function ns.GetUnitFrame(unit)
    return blocks[unit]
end

-- Every tooltip (the unit frame's own and the aura tooltips) goes to the same spot.
function ns.AnchorTooltip(b)
    GameTooltip:SetOwner(b.root, "ANCHOR_RIGHT")
end

local auraFonts = {}
local function GetAuraFont(px)
    local localPx = math.max(6, math.floor(px + 0.5))
    local name = "CenterResourcesAuraTimer" .. localPx
    if not auraFonts[name] then
        local f = CreateFont(name)
        local path = GameFontNormalSmall:GetFont()
        f:SetFont(path, localPx, "OUTLINE")
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

    -- Hide the swipe timer.
    --icon.cd:SetDrawSwipe(false)             -- no dark radial sweep
    --icon.cd:SetDrawBling(false)             -- no finish flash
    --icon.cd:SetHideCountdownNumbers(true)   -- main cooldown keeps swipe only

    pcall(icon.cd.SetCountdownFont, icon.cd, GetAuraFont(set.timerPx))
end

-- Sizes scale with the portrait size, so smaller frames (pet, focus, target of target) get smaller icons.
local function LayoutAuras(b, L, overlap, D, healthOnLeft)
    local a = ns.Cfg(b.unit).auras
    local size = math.max(8, math.floor(D * a.sizeRatio + 0.5))

    -- lock timer font to 50% and counter font to 40% of size
    local timerPx = size * 0.4 --a.timerScale
    local countPx = math.max(7, math.floor(size * 0.4 )) --* a.countScale + 0.5))
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
end

-- Detailed aura timer text, kept to at most 3 characters:
--   60 seconds or under  -> seconds  ("45")
--   up to 99 minutes     -> minutes  ("79m")
--   up to 99 hours       -> hours    ("12h")
--   over 99 hours        -> days     ("5d")
-- The engine's Cooldown countdown numbers accept a NumericFormatter (SetCountdownFormatter).
-- The input is remaining SECONDS. Each breakpoint below applies from its `threshold` upward, and
-- the highest threshold that fits wins. The tiny +0.001 makes the boundary exclusive, so exactly
-- 60s is still "60" and exactly 99m is still "99m".
-- `step` + rounding Up rounds the value up to the next whole unit first; `div` then converts
-- seconds into that unit (60 = minutes, 3600 = hours, 86400 = days).
local MINUTES_FROM = 60 + 0.001            -- over 60 seconds
local HOURS_FROM   = 99 * 60 + 0.001       -- over 99 minutes
local DAYS_FROM    = 99 * 3600 + 0.001     -- over 99 hours

local auraTimeFormatter, auraTimeFormatterTried
local function GetAuraTimeFormatter()
    if auraTimeFormatterTried then return auraTimeFormatter end
    auraTimeFormatterTried = true
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end
    local up = Enum and Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Up or 1
    local ok, f = pcall(function()
        local fmt = C_StringUtil.CreateNumericRuleFormatter()
        fmt:SetBreakpoints({
            { threshold = 0,            step = 1,    rounding = up, format = "%ds" },
            { threshold = MINUTES_FROM, step = 60,   rounding = up, format = "%dm",
              components = { { div = 60 } } },
            { threshold = HOURS_FROM,   step = 3600, rounding = up, format = "%dh",
              components = { { div = 3600 } } },
            { threshold = DAYS_FROM,    step = 86400, rounding = up, format = "%dd",
              components = { { div = 86400 } } },
        })
        return fmt
    end)
    if ok then auraTimeFormatter = f else ns.Print("Aura time formatter failed: " .. tostring(f)) end
    return auraTimeFormatter
end

local function MakeNativeAuraButton(button, harmful, set, block)
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

    -- Enable cancelling auras.
    if block and block.unit == "player" and not harmful and button.SetCancelAuraButtons then
        pcall(button.SetCancelAuraButtons, button, "RightButtonDown")
    end

    -- No dark radial swipe, no edge line, no finish flash.
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)

    -- Timer text ABOVE the icon. The engine feeds this Cooldown and draws its countdown number
    -- centred on the Cooldown frame. With the swipe off, the frame's size only affects where
    -- the text sits, so move/resize the frame to be a strip sitting on top of the icon.
    local timerH = math.max(8, math.floor((set and set.timerPx or size * 0.5) + 4))
    cd:ClearAllPoints()
    cd:SetPoint("BOTTOMLEFT", button, "TOPLEFT", -4, 1)
    cd:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", 4, 1)
    cd:SetHeight(timerH)
    cd:SetFrameLevel(button:GetFrameLevel() + 3)
    if cd.EnableMouse then cd:EnableMouse(false) end

    -- Set to true to hide the timer text completely.
    local HIDE_TIMER_TEXT = false
    cd:SetHideCountdownNumbers(HIDE_TIMER_TEXT or (set and (set.timerPx or size) < 7.5) or false)
    if cd.SetCountdownFont then pcall(cd.SetCountdownFont, cd, GetAuraFont(set and set.timerPx or size)) end
    if cd.SetCountdownFormatter then
        local fmt = GetAuraTimeFormatter()
        if fmt then pcall(cd.SetCountdownFormatter, cd, fmt) end
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

function ns.UpdateAuras(b)
    -- updated to always use the alt method.
    local cfg = ns.Cfg(b.unit).auras
    if not cfg.enabled then
        if b.altAuras then
            for _, native in pairs(b.altAuras) do
                if native and native.Hide then pcall(native.Hide, native) end
            end
        end
        return
    end

    local unitID = UnitExists(b.unit) and (UnitGUID(b.unit) or UnitName(b.unit) or b.unit) or nil

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
                ns.Print("Alternative aura method failed to create " .. name .. " AuraContainer for " .. b.unit .. ": " .. tostring(frame or "unknown"))
                return
            end

            native = frame
            b.altAuras[name] = native
            native._crUnit = b.unit
            native._crNativeSize = math.max(8, math.floor((set.size or 16) + 0.5))
            native._crNativeGap = cfg.spacing
            native:SetFrameLevel(b.root:GetFrameLevel() + 2)
            native:Hide()
        end
        native:ClearAllPoints()
        if set.onLeft then
            native:SetPoint("BOTTOMRIGHT", set.container, "BOTTOMRIGHT", 0, 0)
        else
            native:SetPoint("BOTTOMLEFT", set.container, "BOTTOMLEFT", 0, 0)
        end

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
                return
            end
            native._crReady = true
        end

        if native and native._crReady then
            local ok, err = pcall(function()
                native:ClearAllPoints()
                if set.onLeft then
                    native:SetPoint("BOTTOMRIGHT", set.container, "BOTTOMRIGHT", 0, 0)
                else
                    native:SetPoint("BOTTOMLEFT", set.container, "BOTTOMLEFT", 0, 0)
                end

                if native.SetFlowLayoutGrowthDirection then
                    -- when onLeft, the direction is 0, not -1 to prevent the appearance of icons shifting more and more to the left.
                    local dirX = set.onLeft and 0 or 1
                    pcall(native.SetFlowLayoutGrowthDirection, native, dirX, 1)
                end

                if native.SetUnit then
                    pcall(native.SetUnit, native, nil)
                end
                if native.ClearAllAuras then
                    pcall(native.ClearAllAuras, native)
                end
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
                return
            end

            for i = 1, #set.icons do
                set.icons[i]:Hide()
            end
        end
    end
end

------------------------------------------------------------
-- Pet happiness (WoW Forever: three states, exact value is restricted)
-- Shown as a badge on the portrait edge (like the PvP flag): a mood-coloured disc (Pip.tga)
-- with Blizzard's happiness face on top. If the face texture is missing, the coloured disc
-- alone still shows the mood.
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

-- Optionally hide Blizzard's own unit frames. We only touch alpha and the clickable
-- area (no re-parenting, no moving), which is the least likely way to cause taint.
local BLIZZ = {
                player = "PlayerFrame",
                target = "TargetFrame",
                targettarget = "TargetFrameToT",
                pet = "PetFrame",
                focus = "FocusFrame"
            }
local hooked, hidden, touched = {}, {}, {}
local settingAlpha = false


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
    if b.unit ~= "pet" or not b.happyPip then return end
    local h = (ns.Cfg("pet").happiness ~= "off") and ReadHappiness() or nil
    if h then
        local c = HAPPY_COORDS[h]
        ShowBadge(b.happyPip, true)
        if HappyIconUsable() then
            b.happyFace:SetTexCoord(c[1], c[2], c[3], c[4])
            b.happyFace:Show()
        else
            b.happyFace:Hide()
        end
        b.happyHit:Show()
    else
        ShowBadge(b.happyPip, false)
        b.happyFace:Hide()
        b.happyHit:Hide()
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

    -- combat glow: sits behind everything else on the frame
    local gf = CreateFrame("Frame", nil, root)
    gf:SetAllPoints(root)
    gf:SetFrameLevel(lvl)
    gf:SetAlpha(0)
    b.glowFrame = gf
    b.glowTA, b.glowR, b.glowG, b.glowB = 0, GLOW.color[1], GLOW.color[2], GLOW.color[3]
    b.glowTR, b.glowTG, b.glowTB = b.glowR, b.glowG, b.glowB
    b.glowRing = gf:CreateTexture(nil, "BACKGROUND")
    b.glowRing:SetTexture(ns.TEX .. GLOW.ringFile)
    b.glowRing:SetVertexColor(unpack(GLOW.color))
    -- bar glow = 8 slices per bar (TL, T, TR, L, R, BL, B, BR); texcoords come from the 272x32 file
    local e, tw, th = GLOW.barEdge, GLOW.barTexW, GLOW.barTexH
    local u1, u2, v1, v2 = e / tw, 1 - e / tw, e / th, 1 - e / th
    local SLICES = {   -- name, left, right, top, bottom texcoords
        TL = { 0,  u1, 0,  v1 }, T = { u1, u2, 0,  v1 }, TR = { u2, 1, 0,  v1 },
        L  = { 0,  u1, v1, v2 },                          R  = { u2, 1, v1, v2 },
        BL = { 0,  u1, v2, 1  }, B = { u1, u2, v2, 1  }, BR = { u2, 1, v2, 1  },
    }
    b.glowBars = {}
    for i = 1, 2 do
        local set = {}
        for name, tc in pairs(SLICES) do
            local t = gf:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(ns.TEX .. GLOW.barFile)
            t:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            t:SetVertexColor(unpack(GLOW.color))
            set[name] = t
        end
        b.glowBars[i] = set
    end

    -- bars (not clickable: plain StatusBars take no mouse input)
    b.health = MakeBar(root); b.health:SetFrameLevel(lvl + 1)
    b.power  = MakeBar(root); b.power:SetFrameLevel(lvl + 1)

    -- incoming heal / shield overlays (player and target only). They live in a clipping frame the
    -- size of the health bar, above the health fill but below the portrait and the health text.
    if PREDICT.units[unit] then
        local clip = CreateFrame("Frame", nil, root)
        clip:SetFrameLevel(lvl + 1)
        clip:SetClipsChildren(true)
        local function Overlay(col)
            local sb = CreateFrame("StatusBar", nil, clip)
            sb:SetFrameLevel(lvl + 2)
            sb:SetStatusBarTexture(ns.FLAT)
            sb:SetStatusBarColor(col[1], col[2], col[3], col[4])
            sb:SetMinMaxValues(0, 1)
            sb:SetValue(0)
            return sb
        end
        b.predict = { clip = clip, heal = Overlay(PREDICT.healColor), shield = Overlay(PREDICT.shieldColor) }
        b.predict.calc = ns.MakePredictionCalculator()
        -- keep the health text above the overlays
        local tf = CreateFrame("Frame", nil, root)
        tf:SetAllPoints(b.health)
        tf:SetFrameLevel(lvl + 3)
        b.predict.textFrame = tf
        if pcall(b.health.text.SetParent, b.health.text, tf) then
            b.health.text:ClearAllPoints()
            b.health.text:SetPoint("CENTER", b.health, "CENTER")
        end
    end

    -- portrait, masked into a circle, above the bars
    local pf = CreateFrame("Frame", nil, root)
    pf:SetAllPoints(root)
    pf:SetFrameLevel(lvl + 3)
    b.portraitFrame = pf

    -- Every portrait layer is sized in LayoutBlock to the same 256-style canvas, centred on pf.
    -- fully opaque black disc as wide as the portrait ring: hides glow / bar ends behind the portrait
    b.solid = pf:CreateTexture(nil, "BACKGROUND", nil, -8)
    b.solid:SetTexture(ns.TEX .. ART.mask)
    b.solid:SetVertexColor(0, 0, 0, 1)

    b.disk = pf:CreateTexture(nil, "BACKGROUND")           -- dark backdrop behind the portrait
    b.disk:SetTexture(ns.TEX .. ART.mask)
    b.disk:SetVertexColor(unpack(ART.backingColor))

    b.portrait = pf:CreateTexture(nil, "ARTWORK")          -- the 3D/2D portrait, under the frame
    b.portraitMask = pf:CreateMaskTexture()
    b.portraitMask:SetTexture(ns.TEX .. ART.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    b.portrait:AddMaskTexture(b.portraitMask)

    b.ring = pf:CreateTexture(nil, "OVERLAY", nil, 1)      -- class/reaction coloured ring
    b.ring:SetTexture(ns.TEX .. ART.ring)

    b.border = pf:CreateTexture(nil, "OVERLAY", nil, 2)    -- bevelled border, on top of the ring
    b.border:SetTexture(ns.TEX .. ART.border)
    b.border:SetVertexColor(unpack(ART.borderColor))       -- gold; the greyscale bevel survives the tint

    -- status icons
    local icons = CreateFrame("Frame", nil, root)
    icons:SetAllPoints(root)
    icons:SetFrameLevel(lvl + 6)
    b.iconFrame = icons

    -- Draw order inside the icon frame: backgrounds at OVERLAY sublevel 0, icons/text at 2-3,
    -- so an icon always renders ON TOP of its background disc.
    -- A badge = background (pip_background, sublevel 0) + icon (2-3) + border (pip_border, 4).
    -- The border is stored on the background as bg.border and shown/hidden with ShowBadge().
    local function BadgeBG(col)
        local c = col or BADGE_BG
        local t = icons:CreateTexture(nil, "OVERLAY", nil, 0)
        t:SetTexture(ns.TEX .. PIP.bg)
        t:SetVertexColor(c[1], c[2], c[3], 1)   -- always opaque
        t:SetAlpha(1)
        t:Hide()
        t.border = icons:CreateTexture(nil, "OVERLAY", nil, 4)
        t.border:SetTexture(ns.TEX .. PIP.border)
        t.border:SetVertexColor(unpack(PIP.borderColor))
        t.border:Hide()
        return t
    end

    -- PvP: b.pvp is the faction-coloured disc (Pip.tga); b.pvpIcon is the emblem on top of it.
    b.pvp = BadgeBG()
    b.pvpIcon = icons:CreateTexture(nil, "OVERLAY", nil, 2)
    b.pvpIcon:Hide()

    b.combatBG = BadgeBG()
    b.combat = icons:CreateTexture(nil, "OVERLAY", nil, 2)
    b.combat:SetTexture("Interface\\CharacterFrame\\UI-StateIcon")
    b.combat:SetTexCoord(0.5, 1, 0, 0.484375)

    b.leaderBG = BadgeBG()
    b.leader = icons:CreateTexture(nil, "OVERLAY", nil, 2)
    b.leader:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")

    b.marker = icons:CreateTexture(nil, "OVERLAY")
    b.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")

    b.resting = MakeText(icons, 14)
    b.resting:SetText("zZz")
    b.resting:SetTextColor(0.6, 0.8, 1)
    b.resting:SetDrawLayer("OVERLAY", 3)

    b.levelBG = BadgeBG()
    b.level = MakeText(icons, 12)
    b.level:SetDrawLayer("OVERLAY", 3)
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
        b.happyPip = BadgeBG()                                   -- mood-coloured disc
        b.happyFace = icons:CreateTexture(nil, "OVERLAY", nil, 2) -- face, drawn on top of the disc
        b.happyFace:SetTexture(HAPPY_TEX)
        -- Draw the face untinted. (Tinting it dark turned the whole square cell black, because
        -- the happiness texture has no transparent background.) A circle mask trims the square
        -- cell so only a round face sits on the coloured disc.
        b.happyFace:SetVertexColor(1, 1, 1, 1)
        local fmask = icons:CreateMaskTexture()
        fmask:SetAllPoints(b.happyFace)
        fmask:SetTexture(ns.TEX .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        b.happyFace:AddMaskTexture(fmask)
        b.happyFace:Hide()

        -- invisible hover area for the tooltip; clicks fall through to the unit frame
        local hit = CreateFrame("Frame", nil, icons)
        hit:SetFrameLevel(icons:GetFrameLevel() + 2)
        hit:EnableMouse(true)
        if hit.SetPropagateMouseClicks then
            pcall(hit.SetPropagateMouseClicks, hit, true)
        elseif hit.SetPassThroughButtons then
            pcall(hit.SetPassThroughButtons, hit, "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5")
        end
        hit:SetScript("OnEnter", function() ns.ShowHappinessTooltip(b) end)
        hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        hit:Hide()
        b.happyHit = hit
    end

    -- unlock overlay
    local ov = CreateFrame("Frame", nil, root)
    ov:SetFrameLevel(lvl + 8)
    local ot = ov:CreateTexture(nil, "BACKGROUND")
    ot:SetAllPoints()
    ot:SetColorTexture(0.2, 1, 0.2, 0.18)
    ov.label = MakeText(ov, 12)
    ov.label:SetPoint("TOP", 0, -2)
    ov.label:SetText((ns.UNIT_LABELS[unit] or (unit:sub(1, 1):upper() .. unit:sub(2))) .. " - drag to move")
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

-- Anchor the heal / shield overlays to the health bar. The health bar fills towards its outer end:
-- reverse fill = it grows to the LEFT, normal fill = it grows to the RIGHT.
local function LayoutPredict(b, L)
    local p = b.predict
    if not p then return end
    local rev = b.health:GetReverseFill() and true or false
    local tex = b.health:GetStatusBarTexture()
    p.clip:ClearAllPoints()
    p.clip:SetAllPoints(b.health)

    local function AnchorAfter(sb, edgeTex)   -- start where edgeTex (a fill texture) ends
        sb:ClearAllPoints()
        sb:SetWidth(L)
        sb:SetReverseFill(rev)
        if rev then
            sb:SetPoint("TOPRIGHT", edgeTex, "TOPLEFT", 0, 0)
            sb:SetPoint("BOTTOMRIGHT", edgeTex, "BOTTOMLEFT", 0, 0)
        else
            sb:SetPoint("TOPLEFT", edgeTex, "TOPRIGHT", 0, 0)
            sb:SetPoint("BOTTOMLEFT", edgeTex, "BOTTOMRIGHT", 0, 0)
        end
    end

    AnchorAfter(p.heal, tex)
    if PREDICT.shieldStyle == "attached" then
        AnchorAfter(p.shield, p.heal:GetStatusBarTexture())
    else
        p.shield:ClearAllPoints()
        p.shield:SetAllPoints(b.health)
        p.shield:SetReverseFill(not rev)      -- fills from the outer end towards the portrait
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

    -- portrait artwork: scale the 256 canvas so the chosen inset lands on the portrait diameter
    local S = D * ART.size / (ART.size - 2 * ART.fitInset)
    local function Fit(t, size)
        t:ClearAllPoints()
        t:SetPoint("CENTER", b.portraitFrame, "CENTER", 0, 0)
        t:SetSize(size, size)
    end
    for _, t in ipairs({ b.ring, b.border }) do Fit(t, S) end
    -- portrait, its mask and the dark backdrop shrink together so the mask edge stays aligned
    for _, t in ipairs({ b.portrait, b.portraitMask }) do Fit(t, S * ART.portraitScale) end
    Fit(b.disk, S * ART.portraitScale + 2 * ART.backingPad)   -- a little larger than the portrait, like the bar backdrops
    b.border:SetShown(ART.showBorder)
    -- opaque disc: as wide as the portrait backdrop and (when shown) the ring / border artwork
    do
        local solid = S * ART.portraitScale + 2 * ART.backingPad
        local inset
        if g.showRing then inset = ART.ringInset end
        if ART.showBorder then inset = math.min(inset or ART.borderInset, ART.borderInset) end
        if inset then solid = math.max(solid, S * (ART.size - 2 * inset) / ART.size) end
        Fit(b.solid, solid)
    end

    -- glow artwork: ring glow scales with the ring canvas; bar glow is a 9-slice hugging each bar
    Fit(b.glowRing, S * GLOW.ringSize / ART.size)
    b.glowRing:ClearAllPoints()
    b.glowRing:SetPoint("CENTER", b.portraitFrame, "CENTER", 0, 0)
    for i, bar in ipairs({ b.health, b.power }) do
        local s, e = b.glowBars[i], GLOW.barEdge
        for _, t in pairs(s) do t:ClearAllPoints() end
        -- corners: fixed e x e squares just outside each bar corner
        s.TL:SetSize(e, e); s.TL:SetPoint("BOTTOMRIGHT", bar, "TOPLEFT", 0, 0)
        s.TR:SetSize(e, e); s.TR:SetPoint("BOTTOMLEFT",  bar, "TOPRIGHT", 0, 0)
        s.BL:SetSize(e, e); s.BL:SetPoint("TOPRIGHT",    bar, "BOTTOMLEFT", 0, 0)
        s.BR:SetSize(e, e); s.BR:SetPoint("TOPLEFT",     bar, "BOTTOMRIGHT", 0, 0)
        -- edges: e thick, stretched along the bar side
        s.T:SetHeight(e); s.T:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 0); s.T:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 0)
        s.B:SetHeight(e); s.B:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0); s.B:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 0)
        s.L:SetWidth(e);  s.L:SetPoint("TOPRIGHT", bar, "TOPLEFT", 0, 0);   s.L:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", 0, 0)
        s.R:SetWidth(e);  s.R:SetPoint("TOPLEFT", bar, "TOPRIGHT", 0, 0);   s.R:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT", 0, 0)
    end

    -- icons around the portrait
    b.iconFrame:SetShown(c.showIcons)
    local s = math.max(10, D * 0.26)
    local function Place(obj, deg, size, push)
        local rad = math.rad(deg)
        obj:ClearAllPoints()
        obj:SetPoint("CENTER", root, "CENTER", math.cos(rad) * R * (push or 1), math.sin(rad) * R * (push or 1))
        if size then obj:SetSize(size, size) end
    end
    -- Badge = background + icon + border, all centred on the same point of the portrait edge.
    local B    = math.max(24, s * 1.5)                          -- outer (border) diameter
    local C    = B * PIP.size / (PIP.size - 2 * PIP.fitInset)   -- size of the 64-style canvas
    local disc = B * PIP.discRatio                              -- visible background diameter
    -- iconScale: icon size as a fraction of the disc (ignored for text).
    -- badgeScale: shrinks/grows only the background + border, never the contents.
    local function Badge(bg, obj, deg, iconScale, badgeScale)
        local rad = math.rad(deg)
        local x, y = math.cos(rad) * R, math.sin(rad) * R
        for _, t in ipairs({ bg, bg.border }) do
            t:ClearAllPoints()
            t:SetPoint("CENTER", root, "CENTER", x, y)
            t:SetSize(C * (badgeScale or 1), C * (badgeScale or 1))
        end
        obj:ClearAllPoints()
        obj:SetPoint("CENTER", root, "CENTER", x, y)
        if iconScale then obj:SetSize(disc * iconScale, disc * iconScale) end   -- unaffected by badgeScale
        return x, y
    end
    Badge(b.pvp,       b.pvpIcon,  45,  1.0, 0.6)
    Badge(b.combatBG,  b.combat,   135, 1.0, 0.6)
    Badge(b.leaderBG,  b.leader,  -135, 1.0, 0.6)
    Badge(b.levelBG,   b.level,   -90, nil, 0.6)               -- text keeps its font size; badge is 75%
    Place(b.resting, -45, nil)                                  -- "zZz": no background or border
    Place(b.marker,  90,  s * 1.0, 1.05)
    if b.happyPip then
        local x, y = Badge(b.happyPip, b.happyFace, -30, 1.0, 0.6)
        b.happyHit:ClearAllPoints()
        b.happyHit:SetPoint("CENTER", root, "CENTER", x, y)
        b.happyHit:SetSize(B, B)
    end

    b.name:ClearAllPoints()
    b.name:SetPoint("TOP", b.health, "BOTTOM", 0, -2)
    b.name:SetShown(c.showName)

    if b.sec then
        b.sec:ClearAllPoints()
        b.sec:SetPoint("TOP", root, "BOTTOM", 0, -16)
    end

    LayoutAuras(b, L, overlap, D, not c.mirror)
    LayoutPredict(b, L)

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
    if not b or not b.unit then return end
    
    local unit = b.unit
    if not UnitExists(unit) then
        SetBarValue(b.health, 1, 1)
        b.health.text:SetText("")
        ns.Safe(ns.UpdatePrediction, b)
        return
    end

    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    --if issecretvalue and (issecretvalue(cur) or issecretvalue(max)) then return end
    SetBarValue(b.health, cur, max)
    -- local pct = GetPercent(UnitHealthPercent, cur, max,
    --     unit, true, CurveConstants and CurveConstants.ScaleTo100)
    SetBarText(b.health.text, cur, max)
    ns.Safe(ns.UpdatePrediction, b)
end

------------------------------------------------------------
-- Incoming heals and shields (Midnight-style heal prediction)
--   UnitGetDetailedHealPrediction fills a UnitHealPredictionCalculator; its results may be SECRET
--   values, so they go straight into StatusBar:SetValue (no arithmetic, no comparisons).
--   Fallback when the calculator is missing: UnitGetIncomingHeals / UnitGetTotalAbsorbs.
------------------------------------------------------------
function ns.MakePredictionCalculator()
    if not (CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction) then return nil end
    local ok, calc = pcall(CreateUnitHealPredictionCalculator)
    if not ok or not calc then return nil end
    if Enum then
        local hm, am = Enum.UnitIncomingHealClampMode, Enum.UnitDamageAbsorbClampMode
        if hm then pcall(function() calc:SetIncomingHealClampMode(hm.MissingHealth) end) end
        if am then
            pcall(function()
                calc:SetDamageAbsorbClampMode(PREDICT.shieldStyle == "attached" and am.MissingHealth or am.MaximumHealth)
            end)
        end
    end
    return calc
end

function ns.UpdatePrediction(b)
    local p = b and b.predict
    if not p then return end
    local unit = b.unit
    local function Clear()
        pcall(p.heal.SetValue, p.heal, 0)
        pcall(p.shield.SetValue, p.shield, 0)
    end
    if not UnitExists(unit) then Clear() return end

    local ok = pcall(function()
        local inc, abs
        if p.calc then
            UnitGetDetailedHealPrediction(unit, nil, p.calc)
            inc = p.calc:GetIncomingHeals()          -- 1st return = all incoming heals
            abs = p.calc:GetDamageAbsorbs()          -- 1st return = amount
        else
            inc = UnitGetIncomingHeals(unit)
            abs = UnitGetTotalAbsorbs(unit)
        end
        local max = UnitHealthMax(unit)
        SetBarValue(p.heal, inc, max)
        SetBarValue(p.shield, abs, max)
    end)
    if not ok then Clear() end
end

-- /cr predict : what the heal prediction APIs report on this client
function ns.DescribePrediction()
    local out = {}
    local function Add(s) out[#out + 1] = s end
    Add("CreateUnitHealPredictionCalculator: " .. tostring(CreateUnitHealPredictionCalculator ~= nil))
    Add("UnitGetDetailedHealPrediction: " .. tostring(UnitGetDetailedHealPrediction ~= nil))
    Add("UnitGetIncomingHeals: " .. tostring(UnitGetIncomingHeals ~= nil) .. ", UnitGetTotalAbsorbs: " .. tostring(UnitGetTotalAbsorbs ~= nil))
    Add("Enum.UnitIncomingHealClampMode: " .. tostring(Enum and Enum.UnitIncomingHealClampMode ~= nil) ..
        ", Enum.UnitDamageAbsorbClampMode: " .. tostring(Enum and Enum.UnitDamageAbsorbClampMode ~= nil))
    for _, unit in ipairs({ "player", "target" }) do
        local b = blocks[unit]
        if not b or not b.predict then
            Add(unit .. ": no overlay")
        else
            Add(unit .. ": calculator " .. (b.predict.calc and "created" or "NOT available (fallback APIs)") ..
                ", shield style " .. PREDICT.shieldStyle)
            if b.predict.calc and UnitExists(unit) then
                local ok, err = pcall(UnitGetDetailedHealPrediction, unit, nil, b.predict.calc)
                Add("  UnitGetDetailedHealPrediction: " .. (ok and "ok" or ("ERROR " .. tostring(err))))
                if ok then
                    local ok2, secret = pcall(function() return b.predict.calc:HasSecretValues() end)
                    Add("  HasSecretValues: " .. (ok2 and tostring(secret) or "n/a"))
                end
            end
        end
    end
    return out
end

function ns.UpdatePower(b)
    if not b then return end

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
    SetBarText(b.power.text, cur, max)
end

-- Is this unit a pet / minion controlled by a player of the SAME faction as the player (own pet included)?
-- All comparisons happen inside the pcall, so a secret value just makes this return false.
local function IsFriendlyPlayerPet(unit)
    local ok, res = pcall(function()
        if not UnitExists(unit) or UnitIsPlayer(unit) then return false end
        if UnitIsUnit(unit, "pet") then return true end
        if not UnitPlayerControlled(unit) then return false end
        local mine, theirs = UnitFactionGroup("player"), UnitFactionGroup(unit)
        if mine and theirs then return mine == theirs end
        return UnitIsFriend("player", unit) and true or false
    end)
    return ok and res == true
end

function ns.UpdateColors(b)
    local g = ns.DB.general
    local unit = b.unit
    if unit == "target" or unit == "targettarget" or unit == "focus" then
        -- Health bar follows the engine's selection colour (red/yellow/green/orange...).
        local r, gg, bb
        -- Same-faction players use the same green as the player's own bar.
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local ok, same = pcall(function() return UnitFactionGroup(unit) == UnitFactionGroup("player") end)
            if ok and same == true then r, gg, bb = 0.2, 0.8, 0.2 end
        end
        -- Pets of same-faction players are green as well.
        if not r and IsFriendlyPlayerPet(unit) then r, gg, bb = 0.2, 0.8, 0.2 end
        if not r and UnitExists(unit) and UnitSelectionColor then
            local ok, cr, cg, cb = pcall(UnitSelectionColor, unit)
            if ok and Plain(cr) and Plain(cg) and Plain(cb) then r, gg, bb = cr, cg, cb end
        end
        if r then b.health:SetStatusBarColor(r, gg, bb)
        else b.health:SetStatusBarColor(0.2, 0.8, 0.2) end
    else
        -- player and pet: always green
        b.health:SetStatusBarColor(0.2, 0.8, 0.2)
    end
    if g.showRing then
        b.ring:SetVertexColor(UnitColor(b.unit))
    end
end

function ns.UpdatePortrait(b)
    local unit = b.unit
    SetPortraitTexture(b.portrait, UnitExists(unit) and unit or "player")
    -- Choose which part of the portrait image shows through the mask. The window can't leave the
    -- image, so shifting needs some zoom (portraitZoom > 1) to have anywhere to move.
    do
        local h  = 0.5 / ART.portraitZoom
        local cy = math.max(h, math.min(1 - h, 0.5 - ART.portraitShift))
        b.portrait:SetTexCoord(0.5 - h, 0.5 + h, cy - h, cy + h)
    end
    b.portrait:SetDesaturated(UnitExists(unit) and UnitIsDeadOrGhost(unit) and true or false)
end

-- ---------------------------------------------------------------------------------------------
-- Level number colours (names are always white)
--   TARGET, TARGET OF TARGET and FOCUS share the same rules; player and pet levels are white.
--     attackable unit (mob or unfriendly player) ... a calculated colour (see DIFF table below)
--     friendly NPC / friendly player ................ white
--     unattackable, non-friendly NPC ................ UnitSelectionColor (the engine's orange)
-- ---------------------------------------------------------------------------------------------
local WHITE = { 1.00, 1.00, 1.00 }

-- Calculated mob difficulty colours (GetCreatureDifficultyColor / GetQuestDifficultyColor disagree
-- with the client's nameplates, so the thresholds are our own). diff = mob level - player level.
-- Tune these against the nameplates: every diff >= DIFF.red is red, ... every diff <= DIFF.grey is grey.
local DIFF = {
    red    =  5,   -- diff >=  5
    orange =  3,   -- diff 3..4
    yellow = -2,   -- diff -2..2
    grey   = -7,   -- diff <= -7 grey; between yellow and grey is green
}
local DIFF_COLORS = {
    red    = { 1.00, 0.10, 0.10 },
    orange = { 1.00, 0.50, 0.25 },
    yellow = { 1.00, 1.00, 0.00 },
    green  = { 0.25, 0.75, 0.25 },
    grey   = { 0.50, 0.50, 0.50 },
}

local function DifficultyColor(unit)
    local lvl, mine = UnitLevel(unit), UnitLevel("player")
    if not (Plain(lvl) and Plain(mine)) then return WHITE end
    if lvl <= 0 then return DIFF_COLORS.red end   -- "??" (skull)
    local d = lvl - mine
    if d >= DIFF.red then return DIFF_COLORS.red end
    if d >= DIFF.orange then return DIFF_COLORS.orange end
    if d >= DIFF.yellow then return DIFF_COLORS.yellow end
    if d > DIFF.grey then return DIFF_COLORS.green end
    return DIFF_COLORS.grey
end

local function PickLevelColor(unit)
    if UnitCanAttack("player", unit) then return DifficultyColor(unit) end
    if UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return WHITE end
    -- unattackable, non-friendly NPC: use the selection colour
    if UnitSelectionColor then
        local r, g, b = UnitSelectionColor(unit)
        if Plain(r) and Plain(g) and Plain(b) then return { r, g, b } end
    end
    return WHITE
end

local function SafeColor(fn, unit)
    local ok, c = pcall(fn, unit)   -- any restricted value -> plain white
    c = (ok and c) or WHITE
    return c[1], c[2], c[3]
end

function ns.UpdateInfo(b)
    local unit = b.unit
    if not UnitExists(unit) then
        b.name:SetText(""); b.level:SetText("")
        ShowBadge(b.levelBG, false)
        return
    end
    ShowBadge(b.levelBG, true)
    b.name:SetText(UnitName(unit) or "")
    local lvl = UnitLevel(unit)
    if lvl and lvl > 0 then b.level:SetText(lvl) else b.level:SetText("??") end

    b.name:SetTextColor(1, 1, 1)
    if unit == "target" or unit == "targettarget" or unit == "focus" then
        b.level:SetTextColor(SafeColor(PickLevelColor, unit))
    else
        b.level:SetTextColor(1, 1, 1)
    end
end

function ns.UpdateIcons(b)
    local unit = b.unit
    local exists = UnitExists(unit)

    -- PvP pip
    local col, iconPath
    if exists and UnitIsPVPFreeForAll(unit) then
        col, iconPath = PVP_COLORS.FFA, PVP_ICONS.FFA
    elseif exists and UnitIsPVP(unit) then
        local fac = UnitFactionGroup(unit) or ""
        col, iconPath = PVP_COLORS[fac] or PVP_COLORS.default, PVP_ICONS[fac]
    end
    if col then
        b.pvp:SetVertexColor(col[1], col[2], col[3])   -- the only coloured badge background
        ShowBadge(b.pvp, true)
        if iconPath then
            b.pvpIcon:SetTexture(iconPath)
            b.pvpIcon:SetTexCoord(unpack(PVP_TC))
            b.pvpIcon:SetDesaturated(true)   -- light grey emblem stays visible on a same-colour disc
            b.pvpIcon:Show()
        else
            b.pvpIcon:Hide()
        end
    else
        ShowBadge(b.pvp, false)
        b.pvpIcon:Hide()
    end

    local inCombat = exists and UnitAffectingCombat(unit) and true or false
    b.combat:SetShown(inCombat);  ShowBadge(b.combatBG, inCombat)
    local resting = unit == "player" and IsResting() and true or false
    b.resting:SetShown(resting)
    local leader = exists and UnitIsGroupLeader(unit) and true or false
    b.leader:SetShown(leader);  ShowBadge(b.leaderBG, leader)

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
    --if issecretvalue and issecretvalue(max) then return nil end
    --if type(max) == "number" and max > 0 then return t, math.min(max, 10) end
    --return nil
    return t, max
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

-- Glow state machine. Target state = (alpha, r, g, b); every change takes GLOW.fade seconds.
-- Colours blend while visible; when the glow is fully faded out a new colour is applied instantly.
local function SetGlowColor(b, r, g, bl)
    b.glowR, b.glowG, b.glowB = r, g, bl
    b.glowRing:SetVertexColor(r, g, bl)
    for _, set in ipairs(b.glowBars) do
        for _, t in pairs(set) do t:SetVertexColor(r, g, bl) end
    end
end

local function Approach(cur, tgt, step)
    if cur < tgt then return math.min(tgt, cur + step) end
    return math.max(tgt, cur - step)
end

local function GlowOnUpdate(self, dt)
    local b = self.block
    local step = dt / GLOW.fade
    local a = Approach(self:GetAlpha(), b.glowTA, step)
    self:SetAlpha(a)
    local r = Approach(b.glowR, b.glowTR, step)
    local g = Approach(b.glowG, b.glowTG, step)
    local bl = Approach(b.glowB, b.glowTB, step)
    if r ~= b.glowR or g ~= b.glowG or bl ~= b.glowB then SetGlowColor(b, r, g, bl) end
    if a == b.glowTA and r == b.glowTR and g == b.glowTG and bl == b.glowTB then
        self:SetScript("OnUpdate", nil)
    end
end

-- Threat colour for status 1..3 (GetThreatStatusColor, with the stock colours as a fallback)
local THREAT_FALLBACK = { [1] = { 1, 1, 0.47 }, [2] = { 1, 0.6, 0 }, [3] = { 1, 0, 0 } }
local function ThreatColor(status)
    if GetThreatStatusColor then
        local ok, r, g, bl = pcall(GetThreatStatusColor, status)
        if ok and Plain(r) and Plain(g) and Plain(bl) then return r, g, bl end
    end
    local c = THREAT_FALLBACK[status]
    return c[1], c[2], c[3]
end

local function SafeTrue(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok or (issecretvalue and issecretvalue(v)) then return false end
    return v == true
end

-- Glow rules (player frame):
--   UnitThreatSituation("player") = 1/2/3 ............... GetThreatStatusColor(status)
--   status 0 or nil (or unreadable) AND still in combat .. combat red
--   anything else (0/nil and out of combat) .............. no glow
function ns.UpdateGlow(b)
    if not GLOW.units[b.unit] then return end
    local ta, r, g, bl = 0, b.glowTR or GLOW.color[1], b.glowTG or GLOW.color[2], b.glowTB or GLOW.color[3]
    if ns.DB.general.locked then
        local ok, status = pcall(UnitThreatSituation, "player")
        if ok and Plain(status) and status >= 1 and status <= 3 then
            ta = 1
            r, g, bl = ThreatColor(status)
        elseif SafeTrue(UnitAffectingCombat, "player") then
            ta, r, g, bl = 1, GLOW.color[1], GLOW.color[2], GLOW.color[3]
        end
    end
    if ta == b.glowTA and r == b.glowTR and g == b.glowTG and bl == b.glowTB then return end
    b.glowTA, b.glowTR, b.glowTG, b.glowTB = ta, r, g, bl
    local gf = b.glowFrame
    gf.block = b
    if gf:GetAlpha() == 0 and ta > 0 then SetGlowColor(b, r, g, bl) end   -- invisible: snap colour
    gf:SetScript("OnUpdate", GlowOnUpdate)
end

function ns.UpdateBlock(b)
    ns.Safe(ns.UpdateGlow, b)
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
-- Refers to Blizzard settings at the top of this file.
local function SetFrameHidden(f, hide)
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

function ns.ApplyBlizzard(unit)
    local f = _G[BLIZZ[unit]]
    if f then SetFrameHidden(f, ns.Cfg(unit).hideDefault) end
end

-- Blizzard's own buff / debuff / weapon-enchant bars (global option on the General tab).
-- Same method as the unit frames: alpha 0 + a huge hit-rect inset. Frames that do not exist
-- on this client are skipped.
local AURA_BAR_FRAMES = { "BuffFrame", "DebuffFrame", "TemporaryEnchantFrame" }
function ns.ApplyAuraBars()
    local hide = ns.DB.general.hideAuraBars and true or false
    for _, name in ipairs(AURA_BAR_FRAMES) do
        local f = _G[name]
        if f then SetFrameHidden(f, hide) end
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
    ns.Safe(ns.ApplyAuraBars)
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