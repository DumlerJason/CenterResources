local ADDON, ns = ...

local controls = {}

local function Register(ctrl)
    controls[#controls + 1] = ctrl
    return ctrl
end

------------------------------------------------------------
-- Widgets (built from plain frames/textures: no templates to break)
------------------------------------------------------------
local function NewSlider(parent, label, minV, maxV, step, get, set, suffix)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(260, 42)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT"); lbl:SetText(label)
    local val = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    val:SetPoint("TOPRIGHT")

    local s = CreateFrame("Slider", nil, f)
    s:SetPoint("BOTTOMLEFT", 0, 2)
    s:SetPoint("BOTTOMRIGHT", 0, 2)
    s:SetHeight(16)
    s:SetOrientation("HORIZONTAL")
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.25, 0.25, 0.25, 1)
    track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(4)
    s:SetThumbTexture(ns.FLAT)
    local th = s:GetThumbTexture()
    th:SetSize(10, 16); th:SetVertexColor(0.95, 0.78, 0.2)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)

    local fmt = step < 1 and "%.2f" or "%d"
    s:SetScript("OnValueChanged", function(self, v)
        if self.updating then return end
        v = tonumber(string.format(step < 1 and "%.2f" or "%.0f", v))
        val:SetText(string.format(fmt, v) .. (suffix or ""))
        set(v)
    end)
    function f:Refresh()
        s.updating = true
        local v = get()
        s:SetValue(v)
        val:SetText(string.format(fmt, v) .. (suffix or ""))
        s.updating = false
    end
    return Register(f)
end

local function NewCheck(parent, label, get, set)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(260, 24)
    local box = f:CreateTexture(nil, "BACKGROUND")
    box:SetSize(18, 18); box:SetPoint("LEFT"); box:SetColorTexture(0.45, 0.45, 0.45, 1)
    local inner = f:CreateTexture(nil, "BORDER")
    inner:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
    inner:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
    inner:SetColorTexture(0.05, 0.05, 0.05, 1)
    local mark = f:CreateTexture(nil, "ARTWORK")
    mark:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4)
    mark:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -4, 4)
    mark:SetColorTexture(0.95, 0.78, 0.2, 1)
    local txt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    txt:SetPoint("LEFT", box, "RIGHT", 8, 0); txt:SetText(label)

    function f:Refresh() mark:SetShown(get() and true or false) end
    f:SetScript("OnClick", function()
        set(not get())
        f:Refresh()
    end)
    return Register(f)
end

local function NewButtonBase(parent, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 22)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.2, 0.2, 0.2, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.text:SetPoint("CENTER")
    return b
end

local function NewCycle(parent, label, values, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(260, 42)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT"); lbl:SetText(label)
    local btn = NewButtonBase(f, 170)
    btn:SetPoint("BOTTOMLEFT", 0, 0)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local function Index()
        local cur = get()
        for i, v in ipairs(values) do if v[1] == cur then return i end end
        return 1
    end
    function f:Refresh() btn.text:SetText(values[Index()][2]) end
    btn:SetScript("OnClick", function(_, mouse)
        local i = Index() + (mouse == "RightButton" and -1 or 1)
        if i > #values then i = 1 elseif i < 1 then i = #values end
        set(values[i][1])
        f:Refresh()
    end)
    return Register(f)
end

local function NewButton(parent, text, width, onclick)
    local b = NewButtonBase(parent, width)
    b.text:SetText(text)
    b:SetScript("OnClick", function() onclick(b) end)
    return b
end

------------------------------------------------------------
-- Panel
------------------------------------------------------------
local COL_W, ROW_H = 290, 46

local function Place(obj, content, col, row)
    obj:SetPoint("TOPLEFT", content, "TOPLEFT", col * COL_W, -row * ROW_H)
end

local function G() return ns.DB.general end

local function BuildUnitTab(content, unit)
    local function C() return ns.Cfg(unit) end
    local function A() return ns.Cfg(unit).auras end

    local function bool(key)
        return function() return C()[key] end, function(v) C()[key] = v; ns.Refresh() end
    end
    local function num(key)
        return function() return C()[key] end, function(v) C()[key] = v; ns.Refresh() end
    end
    local function abool(key)
        return function() return A()[key] end, function(v) A()[key] = v; ns.Refresh() end
    end
    -- "mult" converts the stored value to what the slider shows (e.g. 0.4 -> 40)
    local function anum(key, mult)
        return function() return math.floor(A()[key] * mult + 0.5) end,
               function(v) A()[key] = v / mult; ns.Refresh() end
    end

    -- two pages: Frame / Auras
    local p1 = CreateFrame("Frame", nil, content); p1:SetAllPoints(content)
    local p2 = CreateFrame("Frame", nil, content); p2:SetAllPoints(content)
    local sw = {}
    local function ShowPage(i)
        p1:SetShown(i == 1); p2:SetShown(i == 2)
        for j, btn in ipairs(sw) do btn.sel:SetShown(j == i) end
    end
    for i, label in ipairs({ "Frame", "Auras" }) do
        local btn = NewButtonBase(content, 100)
        btn:SetPoint("TOPLEFT", (i - 1) * 106, 0)
        btn.text:SetText(label)
        btn.sel = btn:CreateTexture(nil, "ARTWORK")
        btn.sel:SetPoint("BOTTOMLEFT"); btn.sel:SetPoint("BOTTOMRIGHT"); btn.sel:SetHeight(3)
        btn.sel:SetColorTexture(0.95, 0.78, 0.2, 1)
        btn:SetScript("OnClick", function() ShowPage(i) end)
        sw[i] = btn
    end
    ShowPage(1)

    local function P(obj, page, col, row) Place(obj, page, col, row + 0.65) end

    local function Note(page)
        local nf = CreateFrame("Frame", nil, page)
        nf:SetSize(560, 20)
        nf:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -7.0 * ROW_H)
        local nt = nf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nt:SetPoint("LEFT")
        function nf:Refresh()
            nt:SetText("Everything on this tab is saved for the current Edit Mode layout: |cff33ccff" ..
                tostring(ns.layoutKey or "unknown") .. "|r")
        end
        Register(nf)
    end

    -- Page 1: frame
    local g, s = bool("enabled")
    P(NewCheck(p1, "Show this frame", g, s), p1, 0, 0)
    g, s = num("scale")
    P(NewSlider(p1, "Scale", 0.5, 2, 0.05, g, s), p1, 0, 1)
    g, s = num("portraitSize")
    P(NewSlider(p1, "Portrait size", 32, 128, 2, g, s), p1, 0, 2)
    g, s = num("barLength")
    P(NewSlider(p1, "Bar length", 60, 400, 5, g, s), p1, 0, 3)
    g, s = num("barHeight")
    P(NewSlider(p1, "Bar height", 6, 40, 1, g, s), p1, 0, 4)

    g, s = bool("showName")
    P(NewCheck(p1, "Show name below health bar", g, s), p1, 1, 0)
    g, s = bool("showIcons")
    P(NewCheck(p1, "Show status icons", g, s), p1, 1, 1)
    g, s = bool("mirror")
    P(NewCheck(p1, "Mirror (health on the right)", g, s), p1, 1, 2)
    P(NewButton(p1, "Reset position", 170, function()
        local d = ns.DEFAULTS.units[unit].pos
        local p = ns.GetPos(unit)
        p.x, p.y = d.x, d.y
        ns.Refresh()
    end), p1, 1, 3)
    g, s = bool("hideDefault")
    P(NewCheck(p1, "Hide Blizzard's default frame", g, s), p1, 1, 4)
    g, s = num("barOverlap")
    P(NewSlider(p1, "Bar overlap under portrait (%)", 0, 20, 1, g, s, "%"), p1, 1, 5)
    if unit == "pet" then
        P(NewCycle(p1, "Pet happiness indicator",
            { { "auto", "Automatic" }, { "icon", "Icon in first buff slot" },
              { "pip", "Pip beside portrait" }, { "off", "Off" } },
            function() return C().happiness end,
            function(v) C().happiness = v; ns.Refresh() end), p1, 0, 5)
    end
    Note(p1)

    -- Page 2: auras
    g, s = abool("enabled")
    P(NewCheck(p2, "Show buffs and debuffs", g, s), p2, 0, 0)
    g, s = abool("altMethod")
    P(NewCheck(p2, "Use alternative WoW Forever aura method", g, s), p2, 0, 1)
    g, s = anum("sizeRatio", 100)
    P(NewSlider(p2, "Icon size (% of portrait)", 20, 80, 2, g, s, "%"), p2, 0, 2)
    g, s = anum("spacing", 1)
    P(NewSlider(p2, "Space between icons", 0, 12, 1, g, s, " px"), p2, 0, 3)
    g, s = anum("maxCount", 1)
    P(NewSlider(p2, "Max icons per row", 1, 20, 1, g, s), p2, 0, 4)
    g, s = anum("timerScale", 100)
    P(NewSlider(p2, "Timer text size", 50, 150, 5, g, s, "%"), p2, 1, 1)
    g, s = anum("countScale", 100)
    P(NewSlider(p2, "Stack count text size", 50, 150, 5, g, s, "%"), p2, 1, 2)
    Note(p2)
end

local function BuildGeneralTab(content)
    Place(NewCheck(content, "Lock frames (uncheck to drag them)",
        function() return G().locked end,
        function(v) G().locked = v; ns.Refresh() end), content, 0, 0)

    Place(NewCycle(content, "Health bar colour",
        { { "green", "Green" }, { "class", "Class / reaction" } },
        function() return G().healthColor end,
        function(v) G().healthColor = v; ns.Refresh() end), content, 0, 1)

    Place(NewCycle(content, "Bar texture",
        { { "smooth", "Smooth (Bar.tga)" }, { "flat", "Flat" } },
        function() return G().barStyle end,
        function(v) G().barStyle = v; ns.Refresh() end), content, 0, 2)

    Place(NewCycle(content, "Bar text",
        { { "percent", "Percent" }, { "value", "Value" }, { "both", "Value + percent" }, { "none", "None" } },
        function() return G().textMode end,
        function(v) G().textMode = v; ns.Refresh() end), content, 0, 3)

    Place(NewCheck(content, "Show portrait ring",
        function() return G().showRing end,
        function(v) G().showRing = v; ns.Refresh() end), content, 0, 4)

    Place(NewSlider(content, "Player opacity in combat", 0, 1, 0.05,
        function() return G().combatAlpha end,
        function(v) G().combatAlpha = v; ns.UpdateAlpha() end), content, 1, 0)

    Place(NewSlider(content, "Player opacity out of combat", 0, 1, 0.05,
        function() return G().idleAlpha end,
        function(v) G().idleAlpha = v; ns.UpdateAlpha() end), content, 1, 1)

    Place(NewCheck(content, "Secondary resource row (combo points etc.)",
        function() return G().secondaryEnabled end,
        function(v) G().secondaryEnabled = v; ns.Refresh() end), content, 1, 2)

    Place(NewSlider(content, "Secondary pip size", 6, 30, 1,
        function() return G().secondarySize end,
        function(v) G().secondarySize = v; ns.Refresh() end), content, 1, 3)

    local armed = false
    local btn = NewButton(content, "Reset ALL settings", 170, function(self)
        if not armed then
            armed = true
            self.text:SetText("Click again to confirm")
            C_Timer.After(4, function() armed = false; self.text:SetText("Reset ALL settings") end)
            return
        end
        armed = false
        self.text:SetText("Reset ALL settings")
        wipe(ns.DB)
        ns.CopyDefaults(ns.DEFAULTS, ns.DB)
        ns.Refresh()
        ns.RefreshOptions()
    end)
    Place(btn, content, 1, 4)

    local lf = CreateFrame("Frame", nil, content)
    lf:SetSize(560, 20)
    lf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -5 * ROW_H)
    local lt = lf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lt:SetPoint("LEFT")
    function lf:Refresh()
        lt:SetText("Frame settings are saved per Edit Mode layout (current: |cff33ccff" ..
            tostring(ns.layoutKey or "unknown") .. "|r). Settings on this tab apply to all layouts.")
    end
    Register(lf)
end

function ns.RefreshOptions()
    for _, c in ipairs(controls) do c:Refresh() end
end

function ns.BuildOptions()
    local panel = CreateFrame("Frame")
    panel.name = "CenterResources"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("CenterResources")

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetText("Texture files live in Interface/AddOns/CenterResources/Textures (see README.txt). Restart the game after changing them.")

    local tabNames = { "General", "Player", "Target", "Pet", "Focus" }
    local tabKeys  = { nil, "player", "target", "pet", "focus" }
    local tabs = {}

    local function Select(i)
        for j, t in ipairs(tabs) do
            t.content:SetShown(j == i)
            t.btn.sel:SetShown(j == i)
        end
    end

    for i, name in ipairs(tabNames) do
        local btn = NewButtonBase(panel, 90)
        btn:SetPoint("TOPLEFT", 16 + (i - 1) * 96, -64)
        btn.text:SetText(name)
        btn.sel = btn:CreateTexture(nil, "ARTWORK")
        btn.sel:SetPoint("BOTTOMLEFT"); btn.sel:SetPoint("BOTTOMRIGHT"); btn.sel:SetHeight(3)
        btn.sel:SetColorTexture(0.95, 0.78, 0.2, 1)

        local content = CreateFrame("Frame", nil, panel)
        content:SetPoint("TOPLEFT", 16, -104)
        content:SetSize(580, 300)
        if tabKeys[i] then BuildUnitTab(content, tabKeys[i]) else BuildGeneralTab(content) end

        btn:SetScript("OnClick", function() Select(i) end)
        tabs[i] = { btn = btn, content = content }
    end
    Select(1)

    panel:SetScript("OnShow", ns.RefreshOptions)
    ns.RefreshOptions()

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(cat)
        ns.settingsCategory = cat
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
    ns.panel = panel
end

function ns.OpenOptions()
    if Settings and Settings.OpenToCategory and ns.settingsCategory then
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and ns.panel then
        InterfaceOptionsFrame_OpenToCategory(ns.panel)
        InterfaceOptionsFrame_OpenToCategory(ns.panel)
    else
        ns.Print("could not open the settings panel; use the slash commands (/cr help).")
    end
end
