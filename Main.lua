local ADDON, ns = ...

local ev = CreateFrame("Frame")
local handlers = {}

local function RegE(event) pcall(ev.RegisterEvent, ev, event) end
local function RegU(event, ...) pcall(ev.RegisterUnitEvent, ev, event, ...) end

local function ForUnit(fn)
    return function(unit)
        local b = ns.blocks[unit]
        if b then ns.Safe(fn, b) end
    end
end

local function ForAll(fn)
    return function()
        for _, b in pairs(ns.blocks) do ns.Safe(fn, b) end
    end
end

handlers.UNIT_HEALTH        = ForUnit(ns.UpdateHealth)
handlers.UNIT_MAXHEALTH     = ForUnit(ns.UpdateHealth)
handlers.UNIT_POWER_UPDATE  = ForUnit(function(b) ns.UpdatePower(b); ns.UpdateSecondary(b) end)
handlers.UNIT_MAXPOWER      = handlers.UNIT_POWER_UPDATE
handlers.UNIT_DISPLAYPOWER  = handlers.UNIT_POWER_UPDATE
handlers.UNIT_PORTRAIT_UPDATE = ForUnit(ns.UpdatePortrait)
handlers.UNIT_MODEL_CHANGED = ForUnit(ns.UpdatePortrait)
handlers.UNIT_LEVEL         = ForUnit(ns.UpdateInfo)
handlers.UNIT_NAME_UPDATE   = ForUnit(ns.UpdateInfo)
handlers.UNIT_FACTION       = ForUnit(function(b) ns.UpdateIcons(b); ns.UpdateColors(b) end)
handlers.UNIT_FLAGS         = ForUnit(ns.UpdateIcons)
handlers.UNIT_AURA          = ForUnit(ns.UpdateAuras)

handlers.PLAYER_TARGET_CHANGED = function() if ns.blocks.target then ns.UpdateBlock(ns.blocks.target) end end
handlers.PLAYER_FOCUS_CHANGED  = function() if ns.blocks.focus then ns.UpdateBlock(ns.blocks.focus) end end
handlers.UNIT_HAPPINESS        = function() if ns.blocks.pet then ns.Safe(ns.UpdateHappiness, ns.blocks.pet) end end
handlers.PET_UI_UPDATE         = handlers.UNIT_HAPPINESS
handlers.UNIT_PET              = function() if ns.blocks.pet then ns.UpdateBlock(ns.blocks.pet) end end

handlers.PLAYER_UPDATE_RESTING = ForAll(ns.UpdateIcons)
handlers.PARTY_LEADER_CHANGED  = ForAll(ns.UpdateIcons)
handlers.GROUP_ROSTER_UPDATE   = ForAll(ns.UpdateIcons)
handlers.RAID_TARGET_UPDATE    = ForAll(ns.UpdateIcons)
handlers.PLAYER_FLAGS_CHANGED  = ForAll(ns.UpdateIcons)

handlers.PLAYER_DEAD    = ForAll(ns.UpdatePortrait)
handlers.PLAYER_ALIVE   = ForAll(ns.UpdatePortrait)
handlers.PLAYER_UNGHOST = ForAll(ns.UpdatePortrait)

handlers.PLAYER_REGEN_DISABLED = function()
    ns.UpdateAlpha()
    ForAll(ns.UpdateIcons)()
end
handlers.PLAYER_REGEN_ENABLED = function()
    if ns.pendingRefresh then
        ns.pendingRefresh = false
        ns.RefreshAll()
    end
    ns.UpdateAlpha()
    ForAll(ns.UpdateIcons)()
end

handlers.PLAYER_ENTERING_WORLD = function()
    ns.UpdateLayoutKey()
    ns.Refresh()
    ns.RefreshOptions()
    ns.UpdateAlpha()
end

-- Fires when the Edit Mode layout is switched, edited, created or deleted.
handlers.EDIT_MODE_LAYOUTS_UPDATED = function()
    ns.UpdateLayoutKey()
    ns.Refresh()
    ns.RefreshOptions()
end

function handlers.ADDON_LOADED(name)
    if name ~= ADDON then return end
    ev:UnregisterEvent("ADDON_LOADED")

    CenterResourcesDB = CenterResourcesDB or {}
    ns.DB = CenterResourcesDB
    ns.CopyDefaults(ns.DEFAULTS, ns.DB)
    ns.layoutKey = (ns.DB.lastLayout ~= "" and ns.DB.lastLayout) or "default"

    ns.InitBlocks()
    ns.Safe(ns.BuildOptions)
    ns.RefreshAll()

    -- happiness changes slowly and event support varies, so also re-check every couple of seconds
    C_Timer.NewTicker(2, function()
        local pb = ns.blocks.pet
        if pb and pb.root:IsShown() then ns.Safe(ns.UpdateHappiness, pb) end
    end)

    for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
        "UNIT_DISPLAYPOWER", "UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED", "UNIT_LEVEL",
        "UNIT_NAME_UPDATE", "UNIT_FACTION", "UNIT_FLAGS", "UNIT_AURA" }) do
        RegU(e, "player", "target", "pet", "focus")
    end
    RegU("UNIT_PET", "player")
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED", "PLAYER_FOCUS_CHANGED", "UNIT_HAPPINESS", "PET_UI_UPDATE", "EDIT_MODE_LAYOUTS_UPDATED", "PLAYER_UPDATE_RESTING", "PARTY_LEADER_CHANGED", "GROUP_ROSTER_UPDATE",
        "RAID_TARGET_UPDATE", "PLAYER_FLAGS_CHANGED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
        RegE(e)
    end
end

ev:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(...) end
end)
ev:RegisterEvent("ADDON_LOADED")

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
SLASH_CENTERRESOURCES1 = "/cr"
SLASH_CENTERRESOURCES2 = "/centerres"
SlashCmdList["CENTERRESOURCES"] = function(msg)
    if not ns.DB then return end
    local cmd = (msg or ""):lower():match("^(%S*)")

    if cmd == "" or cmd == "options" or cmd == "config" then
        ns.OpenOptions()
    elseif cmd == "unlock" then
        ns.DB.general.locked = false; ns.Refresh(); ns.RefreshOptions()
        ns.Print("unlocked - drag the green boxes, then /cr lock")
    elseif cmd == "lock" then
        ns.DB.general.locked = true; ns.Refresh(); ns.RefreshOptions()
        ns.Print("locked")
    elseif cmd == "reset" then
        wipe(ns.DB); ns.CopyDefaults(ns.DEFAULTS, ns.DB)
        ns.Refresh(); ns.RefreshOptions()
        ns.Print("all settings reset")
    elseif cmd == "pet" then
        for _, line in ipairs(ns.DescribeHappiness()) do ns.Print(line) end
    elseif cmd == "layout" then
        ns.Print("current Edit Mode layout: " .. tostring(ns.layoutKey))
    elseif cmd == "errors" then
        ns.Print(ns.lastError and ("last error: " .. ns.lastError) or "no errors recorded")
    else
        ns.Print("/cr = settings, /cr unlock, /cr lock, /cr reset, /cr layout, /cr pet, /cr errors")
    end
end
