local ADDON, ns = ...

ns.TEX  = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\"
ns.FLAT = "Interface\\Buttons\\WHITE8X8"

ns.DEFAULTS = {
    layouts    = {},   -- [editModeLayoutName][unit] = full per-frame settings
    layoutPos  = {},   -- legacy (v2.1 positions), only read once to migrate
    lastLayout = "",
    general = {
        locked           = true,
        healthColor      = "green",   -- green | class
        barStyle         = "smooth",  -- smooth (Textures\Bar.tga) | flat
        textMode         = "percent", -- percent | value | both | none
        showRing         = true,
        idleAlpha        = 0.5,       -- player frame, out of combat
        combatAlpha      = 1,         -- player frame, in combat
        secondaryEnabled = true,
        secondarySize    = 12,
    },
    -- These are the TEMPLATE for a layout that has no settings yet (and the migration source).
    units = {
        player = { enabled = true, hideDefault = false, auras = { enabled = true, maxCount = 10, sizeRatio = 0.4, spacing = 2, timerScale = 0.9, countScale = 0.9 }, scale = 1,   portraitSize = 64, barLength = 190, barOverlap = 4, barHeight = 18,
                   showName = false, showIcons = true, mirror = false, pos = { x = 0,    y = -190 } },
        target = { enabled = true, hideDefault = false, auras = { enabled = true, maxCount = 10, sizeRatio = 0.4, spacing = 2, timerScale = 0.9, countScale = 0.9 }, scale = 1,   portraitSize = 56, barLength = 170, barOverlap = 4, barHeight = 16,
                   showName = true,  showIcons = true, mirror = true,  pos = { x = 0,    y = 200  } },
        pet    = { enabled = true, happiness = "auto", hideDefault = false, auras = { enabled = true, maxCount = 10, sizeRatio = 0.4, spacing = 2, timerScale = 0.9, countScale = 0.9 }, scale = 0.9, portraitSize = 40, barLength = 120, barOverlap = 4, barHeight = 12,
                   showName = false, showIcons = true, mirror = false, pos = { x = -440, y = -190 } },
        focus  = { enabled = true, hideDefault = false, auras = { enabled = true, maxCount = 10, sizeRatio = 0.4, spacing = 2, timerScale = 0.9, countScale = 0.9 }, scale = 0.9, portraitSize = 40, barLength = 120, barOverlap = 4, barHeight = 12,
                   showName = true,  showIcons = true, mirror = true,  pos = { x = 440,  y = -190 } },
    },
}

-- Fill in anything missing (or of the wrong type) without touching valid saved values.
function ns.CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ns.CopyDefaults(v, dst[k])
        elseif type(dst[k]) ~= type(v) then
            dst[k] = v
        end
    end
end

function ns.Print(msg)
    print("|cff33ccffCenterResources:|r " .. tostring(msg))
end

-- Run something, record any error instead of spamming the player.
function ns.Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local msg = tostring(err)
        local stack = debugstack and debugstack(2) or ""
        local file, line = stack:match("([%w%._/\\%-]+%.lua):(%d+)")
        if not file then
            local info = debug and debug.getinfo and debug.getinfo(2, "Sl")
            if info and info.short_src and info.currentline then
                file, line = info.short_src, info.currentline
            end
        end
        if file and line then
            msg = file .. ":" .. tostring(line) .. ": " .. msg
        end
        ns.lastError = msg
        ns.errorCount = (ns.errorCount or 0) + 1
        if ns.errorCount == 1 then
            ns.Print("an error was caught and hidden. Type /cr errors to see it.")
        end
    end
    return ok
end

------------------------------------------------------------
-- Edit Mode layout awareness
-- Positions are stored per Edit Mode layout (by layout name).
------------------------------------------------------------
local function ReadLayoutName()
    -- Preferred: Blizzard's own manager knows the active layout (presets included).
    if EditModeManagerFrame and EditModeManagerFrame.GetActiveLayoutInfo then
        local ok, info = pcall(EditModeManagerFrame.GetActiveLayoutInfo, EditModeManagerFrame)
        if ok and type(info) == "table" and type(info.layoutName) == "string" then
            return info.layoutName
        end
    end
    -- Fallback: raw API. Preset layouts (Modern, Classic) come first in the index
    -- space but are not in the returned list.
    if C_EditMode and C_EditMode.GetLayouts then
        local ok, info = pcall(C_EditMode.GetLayouts)
        if ok and type(info) == "table" and info.activeLayout then
            local idx = info.activeLayout
            if idx == 1 then return "Modern" end
            if idx == 2 then return "Classic" end
            local entry = info.layouts and info.layouts[idx - 2]
            if entry and entry.layoutName then return entry.layoutName end
            return "Layout" .. idx
        end
    end
    return nil
end

-- Returns true if the active layout changed.
function ns.UpdateLayoutKey()
    local key = ReadLayoutName() or ns.layoutKey or "default"
    if key ~= ns.layoutKey then
        ns.prevLayoutKey = ns.layoutKey
        ns.layoutKey = key
        if ns.DB then ns.DB.lastLayout = key end
        return true
    end
    return false
end

local function DeepCopy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = (type(v) == "table") and DeepCopy(v) or v
    end
    return out
end

local checked = setmetatable({}, { __mode = "k" })

-- Per-frame settings for a unit in the ACTIVE Edit Mode layout (position, size, hide-default,
-- aura options, ...). A layout seen for the first time starts as a copy of the previous
-- layout's settings (or, for data saved by v2.1, of the old global settings + its position).
function ns.Cfg(unit)
    local DB = ns.DB
    local key = ns.layoutKey or "default"
    local layout = DB.layouts[key]
    if not layout then layout = {}; DB.layouts[key] = layout end
    local c = layout[unit]
    if not c then
        local legacy = DB.layoutPos and DB.layoutPos[key] and DB.layoutPos[key][unit]
        local prev = ns.prevLayoutKey and DB.layouts[ns.prevLayoutKey] and DB.layouts[ns.prevLayoutKey][unit]
        if legacy then
            c = DeepCopy(DB.units[unit])
            c.pos = { x = legacy.x, y = legacy.y }
        else
            c = DeepCopy(prev or DB.units[unit])
        end
        layout[unit] = c
    end
    if not checked[c] then
        checked[c] = true
        ns.CopyDefaults(ns.DEFAULTS.units[unit], c) -- pick up options added in newer versions
    end
    return c
end

function ns.GetPos(unit)
    return ns.Cfg(unit).pos
end
