local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- SETTINGS WINDOW
--
-- Addon-wide settings, as opposed to the per-note settings that live in the
-- manager's right-hand column. The two were previously mixed into one panel
-- separated by a rule, which read as though the theme applied to the selected
-- note rather than the whole addon.
--
-- Adding a setting here means adding one entry to SETTING_ROWS below; the
-- window lays itself out and sizes to fit.
-- ============================================================================

local DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"
local Unpack = NS.Unpack
local RegisterThemed = NS.RegisterThemed
local RegisterThemeCallback = NS.RegisterThemeCallback

local PANEL_WIDTH = 340
local CONTENT_WIDTH = PANEL_WIDTH - 40
local settingsFrame = nil

-- ---------------------------------------------------------------------------
-- Individual settings
--
-- Each row declares how to build itself. `build` returns the created widget
-- and the vertical space it consumed, so the window can stack them without
-- every row needing to know its own position.
-- ---------------------------------------------------------------------------

local SETTING_ROWS = {
    {
        kind = "section",
        label = "Appearance",
    },
    {
        kind = "theme",
        label = "Theme",
        tooltip = "The colour palette used across the addon's windows.",
    },
    {
        kind = "dropdown",
        label = "Note Font",
        tooltip = "The font displayed notes use, unless a note overrides it.",
        getOptions = function() return NS.GetFontList() end,
        getCurrent = function()
            return MyNotesDB.settings.noteFont or NS.DEFAULT_FONT_NAME
        end,
        onSelect = function(value)
            MyNotesDB.settings.noteFont = value
            if NS.RefreshVisibleNotes then
                NS.RefreshVisibleNotes()
            end
        end,
        fontFor = function(value) return NS.GetFontPath(value) end,
    },
    {
        kind = "dropdown",
        label = "New Notes: Background",
        tooltip = "What new notes start with behind them. Existing notes keep whatever they already have. None is text on the screen with nothing behind it.",
        getOptions = function() return NS.NOTE_BACKGROUNDS end,
        getCurrent = function()
            return MyNotesDB.settings.defaultNoteBackground or "none"
        end,
        labelFor = function(value)
            return (NS.NOTE_BACKGROUND_LABELS and NS.NOTE_BACKGROUND_LABELS[value]) or value
        end,
        onSelect = function(value)
            -- Seeds new notes only. Restyling every existing note from here
            -- would silently overwrite per-note choices already made.
            MyNotesDB.settings.defaultNoteBackground = value
        end,
    },
    {
        kind = "dropdown",
        label = "New Notes: Edge",
        tooltip = "What new notes start with around them. Existing notes keep whatever they already have.",
        getOptions = function() return NS.NOTE_EDGES end,
        getCurrent = function()
            return MyNotesDB.settings.defaultNoteEdge or "none"
        end,
        labelFor = function(value)
            return (NS.NOTE_EDGE_LABELS and NS.NOTE_EDGE_LABELS[value]) or value
        end,
        onSelect = function(value)
            MyNotesDB.settings.defaultNoteEdge = value
        end,
    },
    {
        kind = "section",
        label = "General",
    },
    {
        kind = "toggle",
        label = "Animate notes appearing",
        tooltipTitle = "Entrance Animation",
        tooltipDesc = "A note brought on screen by a display rule rises and fades in rather than popping. Turn it off if you would rather notes appear the instant their rule matches.",
        get = function()
            return MyNotesDB.settings.noteEntrance ~= false
        end,
        set = function(enabled)
            MyNotesDB.settings.noteEntrance = enabled and true or false
        end,
    },
    {
        kind = "toggle",
        label = "Stack notes in a column",
        tooltipTitle = "Auto-stack",
        tooltipDesc = "Lay every displayed note out in one column instead of at its own position, so notes appearing from display rules can't overlap. Drag any note to move the whole column.",
        get = function()
            return MyNotesDB.settings.autoStack and true or false
        end,
        set = function(enabled)
            if NS.SetStacking then
                NS.SetStacking(enabled)
            end
        end,
    },
    {
        kind = "choice",
        label = "Unlock notes while holding",
        tooltip = "A locked note lets clicks pass through to the game world, so it cannot be moved or opened for editing. Hold this key to hand it back to the mouse for as long as the key is down.",
        getOptions = function() return NS.NOTE_UNLOCK_MODIFIERS end,
        getCurrent = function()
            return MyNotesDB.settings.unlockModifier or "ALT"
        end,
        labelFor = function(value)
            return (NS.NOTE_UNLOCK_MODIFIER_LABELS and NS.NOTE_UNLOCK_MODIFIER_LABELS[value]) or value
        end,
        onSelect = function(value)
            -- Alt is the default and is stored as absent, like every other
            -- default in the addon.
            MyNotesDB.settings.unlockModifier = (value ~= "ALT") and value or nil
        end,
    },
    {
        kind = "toggle",
        label = "Minimap button",
        tooltipTitle = "Minimap Button",
        tooltipDesc = "Shows the MyNotes button on the minimap.",
        get = function()
            return not MyNotesDB.settings.minimap.hide
        end,
        set = function(enabled)
            MyNotesDB.settings.minimap.hide = not enabled

            if NS.minimapIcon then
                if enabled then
                    NS.minimapIcon:Show("MyNotes")
                else
                    NS.minimapIcon:Hide("MyNotes")
                end
            end
        end,
    },
}

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local function BuildThemeRow(panel, yOffset)
    local label = NS.CreateFieldLabel(panel, "Theme")
    label:SetPoint("TOPLEFT", 20, yOffset)

    local swatches = {}
    local palettes = NS.GetPaletteList()
    local swatchWidth = math.floor((CONTENT_WIDTH - ((#palettes - 1) * 4)) / #palettes)

    for index, palette in ipairs(palettes) do
        local swatch = CreateFrame("Button", nil, panel, "BackdropTemplate")
        swatch:SetSize(swatchWidth, 22)
        swatch:SetBackdrop(NS.FLAT_BACKDROP)

        if index == 1 then
            swatch:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
        else
            swatch:SetPoint("LEFT", swatches[index - 1], "RIGHT", 4, 0)
        end

        swatch.fill = swatch:CreateTexture(nil, "ARTWORK")
        swatch.fill:SetPoint("TOPLEFT", 2, -2)
        swatch.fill:SetPoint("BOTTOMRIGHT", -2, 2)
        swatch.paletteKey = palette.key

        function swatch:Refresh()
            local accent = NS.GetPaletteAccent(self.paletteKey)
            local isActive = (NS.GetThemeKey() == self.paletteKey)

            self.fill:SetColorTexture(accent[1], accent[2], accent[3], isActive and 1 or 0.55)
            self:SetBackdropColor(0, 0, 0, 0.4)
            if isActive then
                self:SetBackdropBorderColor(0.95, 0.97, 1.0, 0.95)
            else
                self:SetBackdropBorderColor(0.25, 0.28, 0.34, 0.8)
            end
        end

        swatch:SetScript("OnClick", function(self)
            NS.SetTheme(self.paletteKey)
        end)

        NS.AttachTooltip(swatch, palette.name, "Use the " .. palette.name .. " palette.")
        swatch:Refresh()
        swatches[index] = swatch
    end

    panel.themeSwatches = swatches

    -- The name of the active palette, so "class" is legible rather than just a
    -- colour the user has to recognise.
    panel.themeName = panel:CreateFontString(nil, "OVERLAY")
    panel.themeName:SetFont(DEFAULT_FONT_PATH, 12, "")
    panel.themeName:SetPoint("TOPLEFT", swatches[1], "BOTTOMLEFT", 0, -6)
    RegisterThemed(panel.themeName, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)

    function panel:RefreshTheme()
        for _, swatch in ipairs(self.themeSwatches) do
            swatch:Refresh()
        end

        local key = NS.GetThemeKey()
        for _, entry in ipairs(NS.GetPaletteList()) do
            if entry.key == key then
                self.themeName:SetText(entry.name)
            end
        end
    end

    panel:RefreshTheme()

    -- label + swatches + name
    return 14 + 6 + 22 + 6 + 14
end

local function BuildToggleRow(panel, row, yOffset)
    local toggle = NS.CreateToggleRow(panel, CONTENT_WIDTH, row.label, row.tooltipTitle, row.tooltipDesc)
    toggle:SetPoint("TOPLEFT", 20, yOffset)

    toggle:SetScript("OnClick", function(self)
        row.set(not row.get())
        self:SetActive(row.get())
    end)

    toggle.RefreshFromDB = function(self)
        self:SetActive(row.get())
    end

    -- Returns the widget and the vertical space it used; the caller needs both.
    return toggle, 28
end

local function BuildDropdownRow(panel, row, yOffset)
    local label = NS.CreateFieldLabel(panel, row.label)
    label:SetPoint("TOPLEFT", 20, yOffset)

    local dropdown = NS.CreateDropdown(panel, CONTENT_WIDTH, {
        getOptions = row.getOptions,
        getCurrent = row.getCurrent,
        onSelect = row.onSelect,
        labelFor = row.labelFor,
        fontFor = row.fontFor,
    })
    dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)

    if row.tooltip then
        NS.AttachTooltip(dropdown, row.label, row.tooltip)
    end

    dropdown.RefreshFromDB = function(self)
        self:RefreshLabel()
    end

    return dropdown, 14 + 6 + 24
end

-- Same shape as a dropdown row, drawn as segmented buttons. Worth its own kind
-- rather than a flag on the dropdown: the two build entirely different widgets.
local function BuildChoiceRow(panel, row, yOffset)
    local label = NS.CreateFieldLabel(panel, row.label)
    label:SetPoint("TOPLEFT", 20, yOffset)

    local choice = NS.CreateChoiceRow(panel, CONTENT_WIDTH, {
        getOptions = row.getOptions,
        getCurrent = row.getCurrent,
        onSelect = row.onSelect,
        labelFor = row.labelFor,
    })
    choice:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)

    if row.tooltip then
        choice:SetTooltip(row.label, row.tooltip)
    end

    choice.RefreshFromDB = function(self)
        self:Refresh()
    end

    return choice, 14 + 4 + choice:GetHeight()
end

local function BuildSectionRow(panel, row, yOffset)
    NS.CreateSectionLabel(panel, row.label, "TOPLEFT", panel, "TOPLEFT", 20, yOffset)

    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", 20, yOffset - 20)
    rule:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    rule:SetHeight(1)
    RegisterThemed(rule, function(self, t)
        self:SetColorTexture(Unpack(t.divider))
    end)

    return 20 + 12
end

local function CreateSettingsFrame()
    if settingsFrame then return settingsFrame end

    local panel = CreateFrame("Frame", "MyNotesSettingsFrame", UIParent, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop(NS.FLAT_BACKDROP)
    panel:Hide()

    panel.title = panel:CreateFontString(nil, "OVERLAY")
    panel.title:SetFont(DEFAULT_FONT_PATH, 18, "")
    panel.title:SetPoint("TOPLEFT", 20, -16)
    panel.title:SetText("Settings")

    panel.hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.hint:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    panel.hint:SetText("Drag to move, Escape to close.")
    RegisterThemed(panel.hint, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    panel.headerLine = panel:CreateTexture(nil, "ARTWORK")
    panel.headerLine:SetPoint("TOPLEFT", 20, -58)
    panel.headerLine:SetPoint("TOPRIGHT", -20, -58)
    panel.headerLine:SetHeight(1)
    NS.StyleDialog(panel, panel.title, panel.headerLine)

    panel.closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    panel.closeButton:SetPoint("TOPRIGHT", -6, -6)
    panel.closeButton:SetScript("OnClick", function()
        panel:Hide()
    end)

    -- Stack the declared rows, letting each report the space it used.
    local yOffset = -76
    panel.toggles = {}

    for _, row in ipairs(SETTING_ROWS) do
        local consumed = 0

        if row.kind == "section" then
            consumed = BuildSectionRow(panel, row, yOffset)
        elseif row.kind == "theme" then
            consumed = BuildThemeRow(panel, yOffset)
        elseif row.kind == "toggle" then
            local toggle, height = BuildToggleRow(panel, row, yOffset)
            table.insert(panel.toggles, toggle)
            consumed = height
        elseif row.kind == "dropdown" then
            local dropdown, height = BuildDropdownRow(panel, row, yOffset)
            table.insert(panel.toggles, dropdown)
            consumed = height
        elseif row.kind == "choice" then
            local choice, height = BuildChoiceRow(panel, row, yOffset)
            table.insert(panel.toggles, choice)
            consumed = height
        end

        yOffset = yOffset - consumed - 10
    end

    panel:SetHeight(math.abs(yOffset) + 16)

    NS.DockDialog(panel, "RIGHT")

    NS.MakeEscapeClosable(panel)

    -- Everything on show reflects live state, so the window can't drift out of
    -- sync with settings changed elsewhere (a slash command, another window).
    panel:HookScript("OnShow", function(self)
        self:RefreshTheme()
        for _, toggle in ipairs(self.toggles) do
            if toggle.RefreshFromDB then
                toggle:RefreshFromDB()
            end
        end
    end)

    RegisterThemeCallback(function()
        if panel.RefreshTheme then
            panel:RefreshTheme()
        end
    end)

    settingsFrame = panel
    return panel
end

function NS.ToggleSettings()
    local panel = CreateSettingsFrame()

    if panel:IsShown() then
        panel:Hide()
    else
        panel:Dock()
        panel:Show()
    end
end

NS.CreateSettingsFrame = CreateSettingsFrame

-- ---------------------------------------------------------------------------
-- Blizzard settings stub
--
-- Users look in Options -> AddOns first, so there needs to be something there.
-- It's only a signpost: the settings themselves stay in the addon's own themed
-- window rather than being rebuilt in Blizzard's widget styling.
-- ---------------------------------------------------------------------------

function NS.RegisterBlizzardSettings()
    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        return
    end

    local canvas = CreateFrame("Frame", "MyNotesBlizzardOptions")
    canvas.name = "MyNotes"

    local title = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("MyNotes")

    local description = canvas:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    description:SetPoint("RIGHT", canvas, "RIGHT", -16, 0)
    description:SetJustifyH("LEFT")
    description:SetText("MyNotes keeps its settings in its own window, so they follow the addon's theme.")

    local openButton = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    openButton:SetSize(180, 26)
    openButton:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -16)
    openButton:SetText("Open MyNotes Settings")
    openButton:SetScript("OnClick", function()
        -- Close the options window first, or it sits on top of ours.
        if SettingsPanel and SettingsPanel:IsShown() then
            HideUIPanel(SettingsPanel)
        end
        NS.ToggleSettings()
    end)

    local slashHint = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    slashHint:SetPoint("TOPLEFT", openButton, "BOTTOMLEFT", 0, -16)
    slashHint:SetText("Open the note manager with /mn or /mynotes.")

    local category = Settings.RegisterCanvasLayoutCategory(canvas, "MyNotes")
    category.ID = "MyNotes"
    Settings.RegisterAddOnCategory(category)

    NS.blizzardSettingsCategory = category
end
