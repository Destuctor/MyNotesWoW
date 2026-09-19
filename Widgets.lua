local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- WIDGET KIT
--
-- The addon's reusable UI pieces, shared by every window it draws.
--
-- These began life as locals inside CreateManagerFrame, which meant nothing
-- outside that one function could use them. Adding a second window forced the
-- choice between duplicating them or piling more UI into an already large
-- file; extracting them here is what makes a third and fourth window cheap.
--
-- Everything colour-related goes through NS.RegisterThemed, so any widget
-- built with these follows a palette change automatically.
-- ============================================================================

local DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"
local RegisterThemed = NS.RegisterThemed
local Unpack = NS.Unpack

-- A plain 1px-border backdrop, used by nearly every surface the addon draws.
local FLAT_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = false,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

NS.FLAT_BACKDROP = FLAT_BACKDROP

-- ---------------------------------------------------------------------------
-- Surfaces
-- ---------------------------------------------------------------------------

function NS.StylePanel(panel, alpha)
    panel:SetBackdrop(FLAT_BACKDROP)

    if not panel.softTop then
        panel.softTop = panel:CreateTexture(nil, "BORDER")
        panel.softTop:SetPoint("TOPLEFT", 1, -1)
        panel.softTop:SetPoint("TOPRIGHT", -1, -1)
        panel.softTop:SetHeight(30)
    end

    -- A 1px lip along the very top edge. Catching the "light" here is what
    -- separates a panel from the window behind it instead of both reading as
    -- one flat sheet of charcoal.
    if not panel.topLip then
        panel.topLip = panel:CreateTexture(nil, "ARTWORK")
        panel.topLip:SetPoint("TOPLEFT", 1, -1)
        panel.topLip:SetPoint("TOPRIGHT", -1, -1)
        panel.topLip:SetHeight(1)
        panel.topLip:SetColorTexture(1, 1, 1, 0.045)
    end

    RegisterThemed(panel, function(self, t)
        self:SetBackdropColor(Unpack(t.panelBg, alpha))
        self:SetBackdropBorderColor(Unpack(t.panelBorder))
        self.softTop:SetColorTexture(Unpack(t.panelTop))
    end)
end

-- Every floating window the addon opens shares one look: dialog-strata
-- surface, titled header, accent rule beneath it.
function NS.StyleDialog(panel, titleFontString, headerLine)
    RegisterThemed(panel, function(self, t)
        self:SetBackdropColor(Unpack(t.windowBg, 0.985))
        self:SetBackdropBorderColor(Unpack(t.windowBorder))
    end)

    if titleFontString then
        RegisterThemed(titleFontString, function(self, t)
            self:SetTextColor(Unpack(t.textPrimary))
        end)
    end

    if headerLine then
        -- Matches the manager window's own header rule: a 2px accent line with
        -- a soft glow bleeding beneath it, rather than a 1px hairline. Set here
        -- rather than at each call site so every dialog stays consistent with
        -- the main window and with each other.
        headerLine:SetHeight(2)

        if not headerLine.glow then
            local glow = panel:CreateTexture(nil, "ARTWORK")
            glow:SetPoint("TOPLEFT", headerLine, "BOTTOMLEFT", 0, 0)
            glow:SetPoint("TOPRIGHT", headerLine, "BOTTOMRIGHT", 0, 0)
            glow:SetHeight(6)
            headerLine.glow = glow
        end

        RegisterThemed(headerLine, function(self, t)
            self:SetColorTexture(Unpack(t.accent, 0.35))
            self.glow:SetColorTexture(Unpack(t.accent, 0.08))
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

-- Section headings are drawn in the accent colour itself.
--
-- They previously used near-white text with a small accent tick beside them,
-- which left the window with almost no accent-coloured text anywhere. Spending
-- the accent on headings rather than on filled backgrounds is what gives a
-- layout rhythm without anything having to shout - so the tick is gone, since
-- the colour now does that job on its own.
function NS.CreateSectionLabel(parent, text, anchor, relativeTo, relativePoint, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetFont(DEFAULT_FONT_PATH, 14, "")
    label:SetPoint(anchor, relativeTo, relativePoint, x, y)
    label:SetText(text)

    RegisterThemed(label, function(self, t)
        self:SetTextColor(Unpack(t.accent))
    end)

    return label
end

-- Field labels ("Title", "Body", "Opacity"). Kept on the addon's own font at a
-- consistent size, rather than mixing in Blizzard's font objects.
function NS.CreateFieldLabel(parent, text)
    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetFont(DEFAULT_FONT_PATH, 12, "")
    label:SetText(text)
    RegisterThemed(label, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)
    return label
end

-- HookScript rather than SetScript: callers often set their own OnEnter for
-- hover styling, and a tooltip should never silently replace it.
function NS.AttachTooltip(widget, title, desc)
    widget:HookScript("OnEnter", function(self)
        local t = NS.GetTheme()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, Unpack(t.textPrimary))
        if desc then
            GameTooltip:AddLine(desc, 0.7, 0.75, 0.82, true)
        end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- ---------------------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------------------

function NS.StyleActionButton(button, width, height, isPrimary)
    button:SetSize(width or 96, height or 28)
    button:SetNormalFontObject("GameFontHighlight")
    button:SetHighlightFontObject("GameFontHighlight")
    button:SetDisabledFontObject("GameFontDisable")

    -- The template's Left/Middle/Right texture pieces are direct fields on the
    -- button object. Anonymous buttons have no GetName(), so a _G[name.."Left"]
    -- lookup silently fails and never hides them.
    local left = button.Left or (button:GetName() and _G[button:GetName() .. "Left"])
    local middle = button.Middle or (button:GetName() and _G[button:GetName() .. "Middle"])
    local right = button.Right or (button:GetName() and _G[button:GetName() .. "Right"])
    if left then left:SetAlpha(0) end
    if middle then middle:SetAlpha(0) end
    if right then right:SetAlpha(0) end

    if not button.bg then
        button.bg = button:CreateTexture(nil, "ARTWORK", nil, -8)
        button.bg:SetAllPoints()
    end
    if not button.border then
        button.border = button:CreateTexture(nil, "BORDER")
        button.border:SetPoint("TOPLEFT")
        button.border:SetPoint("BOTTOMRIGHT")
        button.border:SetColorTexture(0, 0, 0, 0)
    end
    -- Top-edge highlight gives the button a slight convex read, so it sits
    -- above the panel rather than being a flat rectangle painted on it.
    if not button.topGlow then
        button.topGlow = button:CreateTexture(nil, "ARTWORK", nil, -7)
        button.topGlow:SetPoint("TOPLEFT", 1, -1)
        button.topGlow:SetPoint("TOPRIGHT", -1, -1)
        button.topGlow:SetHeight(math.max(6, math.floor((height or 28) * 0.42)))
    end

    RegisterThemed(button, function(self, t)
        if isPrimary == "danger" then
            self.bg:SetColorTexture(Unpack(t.btnDangerBg))
            self.topGlow:SetColorTexture(1, 1, 1, 0.07)
        elseif isPrimary then
            self.bg:SetColorTexture(Unpack(t.btnPrimaryBg))
            self.topGlow:SetColorTexture(Unpack(t.accent, 0.22))
        else
            self.bg:SetColorTexture(Unpack(t.btnBg))
            self.topGlow:SetColorTexture(1, 1, 1, 0.035)
        end
    end)

    button:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local hl = button:GetHighlightTexture()
    if hl then
        hl:SetAllPoints()
        hl:SetVertexColor(1, 1, 1, 0.06)
    end

    button:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
    local pushed = button:GetPushedTexture()
    if pushed then
        pushed:SetAllPoints()
        pushed:SetVertexColor(0, 0, 0, 0.18)
    end

    local text = button:GetFontString()
    if text then
        text:SetFont(DEFAULT_FONT_PATH, 13, "")
    end

    -- Dimming the whole button is deliberate over recolouring its background:
    -- it carries the text and any highlight with it in one step, and a disabled
    -- button reads as unavailable rather than as a differently-coloured button.
    function button:SetEnabledState(enabled)
        if enabled then
            self:Enable()
            self:SetAlpha(1)
        else
            self:Disable()
            self:SetAlpha(0.35)
        end
    end
end

function NS.StyleEditBox(box, height)
    box:SetHeight(height or box:GetHeight() or 24)
    box:SetFont(DEFAULT_FONT_PATH, 13, "")
    if box.Left then box.Left:SetAlpha(0) end
    if box.Middle then box.Middle:SetAlpha(0) end
    if box.Right then box.Right:SetAlpha(0) end

    if not box.bg then
        box.bg = CreateFrame("Frame", nil, box, "BackdropTemplate")
        box.bg:SetPoint("TOPLEFT", -6, 6)
        box.bg:SetPoint("BOTTOMRIGHT", 6, -6)
        box.bg:SetFrameLevel(math.max(0, box:GetFrameLevel() - 1))
        box.bg:SetBackdrop(FLAT_BACKDROP)
    end

    RegisterThemed(box, function(self, t)
        self:SetTextColor(Unpack(t.textNormal))
        self.bg:SetBackdropColor(Unpack(t.inputBg))
        -- A focused field picks up the accent so it's obvious where typing goes.
        if self:HasFocus() then
            self.bg:SetBackdropBorderColor(Unpack(t.accent, 0.9))
        else
            self.bg:SetBackdropBorderColor(Unpack(t.inputBorder))
        end
    end)

    box:HookScript("OnEditFocusGained", function(self)
        local t = NS.GetTheme()
        self.bg:SetBackdropBorderColor(Unpack(t.accent, 0.9))
    end)
    box:HookScript("OnEditFocusLost", function(self)
        local t = NS.GetTheme()
        self.bg:SetBackdropBorderColor(Unpack(t.inputBorder))
    end)
end

-- A full-width toggle row: indicator swatch on the left, spelled-out label
-- beside it.
function NS.CreateToggleRow(parent, width, label, tooltipTitle, tooltipDesc)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width, 28)
    button:SetBackdrop(FLAT_BACKDROP)

    button.indicator = CreateFrame("Frame", nil, button, "BackdropTemplate")
    button.indicator:SetSize(14, 14)
    button.indicator:SetPoint("LEFT", 8, 0)
    button.indicator:SetBackdrop(FLAT_BACKDROP)

    button.indicatorFill = button.indicator:CreateTexture(nil, "OVERLAY")
    button.indicatorFill:SetPoint("TOPLEFT", 3, -3)
    button.indicatorFill:SetPoint("BOTTOMRIGHT", -3, 3)

    button.label = button:CreateFontString(nil, "OVERLAY")
    button.label:SetFont(DEFAULT_FONT_PATH, 13, "")
    button.label:SetPoint("LEFT", button.indicator, "RIGHT", 9, 0)
    button.label:SetText(label)

    function button:SetActive(isActive)
        self.isActive = isActive
        local t = NS.GetTheme()

        if isActive then
            self:SetBackdropColor(Unpack(t.toggleOnBg))
            self:SetBackdropBorderColor(Unpack(t.toggleOnBorder))
            self.indicator:SetBackdropColor(Unpack(t.accent, 0.25))
            self.indicator:SetBackdropBorderColor(Unpack(t.accentBright, 0.95))
            self.indicatorFill:SetColorTexture(Unpack(t.accentBright))
            self.indicatorFill:Show()
            self.label:SetTextColor(Unpack(t.textPrimary))
        else
            self:SetBackdropColor(Unpack(t.toggleOffBg))
            self:SetBackdropBorderColor(Unpack(t.toggleOffBorder))
            self.indicator:SetBackdropColor(0, 0, 0, 0.35)
            self.indicator:SetBackdropBorderColor(Unpack(t.toggleOffBorder))
            self.indicatorFill:Hide()
            self.label:SetTextColor(Unpack(t.textMuted))
        end
    end

    -- Re-apply on theme change, preserving whatever state it's in.
    RegisterThemed(button, function(self)
        self:SetActive(self.isActive)
    end)

    button:SetScript("OnEnter", function(self)
        if not self.isActive then
            local t = NS.GetTheme()
            self:SetBackdropColor(Unpack(t.rowHoverBg))
        end
    end)
    button:SetScript("OnLeave", function(self)
        self:SetActive(self.isActive)
    end)

    NS.AttachTooltip(button, tooltipTitle, tooltipDesc)
    button:SetActive(false)
    return button
end

function NS.CreateFlatSlider(parent, width, minVal, maxVal, step)
    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(width, 16)
    slider:SetHitRectInsets(0, 0, -6, -6)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step or 1)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end
    slider:EnableMouse(true)

    slider.track = slider:CreateTexture(nil, "BACKGROUND")
    slider.track:SetPoint("LEFT", 0, 0)
    slider.track:SetPoint("RIGHT", 0, 0)
    slider.track:SetHeight(4)

    slider.fill = slider:CreateTexture(nil, "ARTWORK")
    slider.fill:SetPoint("LEFT", slider.track, "LEFT", 0, 0)
    slider.fill:SetHeight(4)

    slider.thumb = slider:CreateTexture(nil, "OVERLAY")
    slider.thumb:SetSize(14, 14)
    slider:SetThumbTexture(slider.thumb)

    RegisterThemed(slider, function(self, t)
        self.track:SetColorTexture(Unpack(t.sliderTrack))
        self.fill:SetColorTexture(Unpack(t.sliderFill))
        self.thumb:SetColorTexture(Unpack(t.sliderThumb))
    end)

    slider:SetScript("OnValueChanged", function(self, value)
        local minv, maxv = self:GetMinMaxValues()
        local pct = (maxv > minv) and ((value - minv) / (maxv - minv)) or 0
        local trackWidth = self.track:GetWidth() or width
        self.fill:SetWidth(math.max(0.001, trackWidth * pct))
        if self.OnValueChangedCallback and not self.suppressCallback then
            self.OnValueChangedCallback(value)
        end
    end)

    function slider:SetValueSilent(value)
        self.suppressCallback = true
        self:SetValue(value)
        self.suppressCallback = false
    end

    return slider
end

-- A row of small segmented buttons, one per option.
--
-- For a setting with three or four choices this beats a dropdown outright:
-- every option is visible without a click, picking one takes one click instead
-- of two, and there is no floating list left open over the panel. It is also
-- shorter - a label plus a dropdown is two stacked controls, this is one.
--
-- `spec` fields match CreateDropdown's, minus fontFor:
--   getOptions  function() -> array of values
--   getCurrent  function() -> the currently selected value
--   onSelect    function(value)
--   labelFor    optional function(value) -> display text
function NS.CreateChoiceRow(parent, width, spec)
    local GAP = 3
    local ROW_HEIGHT = 20
    local TEXT_PADDING = 14

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width, ROW_HEIGHT)
    row.buttons = {}

    local function PaintButton(button)
        local t = NS.GetTheme()

        if button.value == spec.getCurrent() then
            button:SetBackdropColor(Unpack(t.accent, 0.18))
            button:SetBackdropBorderColor(Unpack(t.accent, 0.95))
            button.text:SetTextColor(Unpack(t.accent))
        elseif button.hovered then
            button:SetBackdropColor(Unpack(t.rowHoverBg))
            button:SetBackdropBorderColor(Unpack(t.inputBorder))
            button.text:SetTextColor(Unpack(t.textNormal))
        else
            button:SetBackdropColor(Unpack(t.inputBg))
            button:SetBackdropBorderColor(Unpack(t.inputBorder))
            button.text:SetTextColor(Unpack(t.textDim))
        end
    end

    -- Repaints every button, so selecting one clears the others. Cheap enough
    -- to do wholesale: these rows are three or four buttons long.
    function row:Repaint()
        for _, button in ipairs(self.buttons) do
            if button:IsShown() then
                PaintButton(button)
            end
        end
    end

    function row:Refresh()
        local options = spec.getOptions()
        local count = #options

        for _, button in ipairs(self.buttons) do
            button:Hide()
        end

        if count == 0 then
            self:SetHeight(1)
            return
        end

        -- Widest label decides how many fit on a line. Equal widths across the
        -- line, so the row reads as one control rather than as loose buttons.
        local widest = 0

        for index, value in ipairs(options) do
            local button = self.buttons[index]

            if not button then
                button = CreateFrame("Button", nil, self, "BackdropTemplate")
                button:SetBackdrop(FLAT_BACKDROP)
                button:SetHeight(ROW_HEIGHT)

                button.text = button:CreateFontString(nil, "OVERLAY")
                NS.ApplyFont(button.text, DEFAULT_FONT_PATH, 11)
                button.text:SetPoint("CENTER", 0, 0)
                button.text:SetWordWrap(false)

                -- The tooltip is handled here rather than through
                -- NS.AttachTooltip: the row is a bare frame completely covered
                -- by its buttons, so a tooltip hooked to the row itself would
                -- never see a mouse.
                button:SetScript("OnEnter", function(self)
                    self.hovered = true
                    PaintButton(self)

                    if row.tooltipTitle then
                        local t = NS.GetTheme()
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        GameTooltip:SetText(row.tooltipTitle, Unpack(t.textPrimary))
                        if row.tooltipDesc then
                            GameTooltip:AddLine(row.tooltipDesc, 0.7, 0.75, 0.82, true)
                        end
                        GameTooltip:Show()
                    end
                end)
                button:SetScript("OnLeave", function(self)
                    self.hovered = nil
                    PaintButton(self)
                    GameTooltip:Hide()
                end)
                button:SetScript("OnClick", function(self)
                    spec.onSelect(self.value)
                    row:Repaint()
                end)

                self.buttons[index] = button
            end

            button.value = value
            button.text:SetText(spec.labelFor and spec.labelFor(value) or tostring(value))
            widest = math.max(widest, button.text:GetStringWidth() + TEXT_PADDING)
        end

        local perLine = math.floor((width + GAP) / (widest + GAP))
        perLine = math.max(1, math.min(count, perLine))

        local lines = math.ceil(count / perLine)
        local buttonWidth = math.floor((width - ((perLine - 1) * GAP)) / perLine)

        for index, _ in ipairs(options) do
            local button = self.buttons[index]
            local line = math.floor((index - 1) / perLine)
            local column = (index - 1) % perLine

            button:SetWidth(buttonWidth)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT",
                column * (buttonWidth + GAP),
                -(line * (ROW_HEIGHT + GAP)))

            PaintButton(button)
            button:Show()
        end

        self:SetHeight((lines * ROW_HEIGHT) + ((lines - 1) * GAP))
    end

    -- Set after construction, and read at hover time, so it applies to buttons
    -- the row has not built yet.
    function row:SetTooltip(title, desc)
        self.tooltipTitle = title
        self.tooltipDesc = desc
    end

    RegisterThemed(row, function(self)
        self:Repaint()
    end)

    row:Refresh()

    return row
end

-- Every dropdown list ever created, so that opening one can close the rest.
-- Weak-keyed: a list belonging to a discarded window should not keep it alive.
local openLists = setmetatable({}, { __mode = "k" })

-- Closes any open dropdown list. Called when one opens, and by windows that
-- want a clean slate (hiding a panel, starting a drag).
function NS.CloseOpenDropdowns(except)
    for list in pairs(openLists) do
        if list ~= except and list:IsShown() then
            list:Hide()
        end
    end
end

-- A dropdown built from a scrolling list.
--
-- `spec` fields:
--   getOptions  function() -> array of values
--   getCurrent  function() -> the currently selected value
--   onSelect    function(value)
--   labelFor    optional function(value) -> display text (defaults to value)
--   fontFor     optional function(value) -> font path, so each row can be
--               drawn in the thing it represents. That is the whole point for
--               a font picker: a list of names tells you nothing.
function NS.CreateDropdown(parent, width, spec)
    local ROW_HEIGHT = 18
    local MAX_VISIBLE = 10

    local dropdown = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dropdown:SetSize(width, 24)
    dropdown:SetBackdrop(FLAT_BACKDROP)

    dropdown.label = dropdown:CreateFontString(nil, "OVERLAY")
    dropdown.label:SetFont(DEFAULT_FONT_PATH, 12, "")
    dropdown.label:SetPoint("LEFT", 8, 0)
    dropdown.label:SetPoint("RIGHT", -20, 0)
    dropdown.label:SetJustifyH("LEFT")
    dropdown.label:SetWordWrap(false)

    dropdown.chevron = dropdown:CreateFontString(nil, "OVERLAY")
    dropdown.chevron:SetFont(DEFAULT_FONT_PATH, 10, "")
    dropdown.chevron:SetPoint("RIGHT", -7, -1)
    dropdown.chevron:SetText("v")

    -- Parented to UIParent, not the dropdown: a list opening downward out of a
    -- short panel would otherwise be clipped by, or draw beneath, its neighbours.
    local list = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetBackdrop(FLAT_BACKDROP)
    list:SetWidth(width)
    list:Hide()
    dropdown.list = list

    list.scroll = CreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
    list.scroll:SetPoint("TOPLEFT", 4, -4)
    list.scroll:SetPoint("BOTTOMRIGHT", -22, 4)

    list.content = CreateFrame("Frame", nil, list.scroll)
    list.content:SetSize(1, 1)
    list.scroll:SetScrollChild(list.content)
    NS.AutoHideScrollBar(list.scroll)
    NS.StyleScrollBar(list.scroll)

    list.rows = {}

    RegisterThemed(dropdown, function(self, t)
        self:SetBackdropColor(Unpack(t.inputBg))
        self:SetBackdropBorderColor(Unpack(t.inputBorder))
        self.label:SetTextColor(Unpack(t.textNormal))
        self.chevron:SetTextColor(Unpack(t.textDim))
    end)

    RegisterThemed(list, function(self, t)
        self:SetBackdropColor(Unpack(t.windowBg, 0.98))
        self:SetBackdropBorderColor(Unpack(t.accent, 0.7))
    end)

    function dropdown:RefreshLabel()
        local current = spec.getCurrent()

        -- Show the current value in its own font, so the closed state previews
        -- the choice rather than just naming it. Applied unconditionally: if
        -- fontFor returns nothing this has to fall back to the default, or the
        -- label keeps the font of whatever was selected previously.
        NS.ApplyFont(self.label, (spec.fontFor and spec.fontFor(current)) or DEFAULT_FONT_PATH, 12)

        self.label:SetText(spec.labelFor and spec.labelFor(current) or tostring(current or ""))
    end

    local function BuildRows()
        local options = spec.getOptions()
        local current = spec.getCurrent()
        local t = NS.GetTheme()

        for _, row in ipairs(list.rows) do
            row:Hide()
        end

        for index, value in ipairs(options) do
            local row = list.rows[index]

            if not row then
                row = CreateFrame("Button", nil, list.content)
                row:SetHeight(ROW_HEIGHT)
                row.highlight = row:CreateTexture(nil, "BACKGROUND")
                row.highlight:SetAllPoints()
                row.highlight:Hide()
                row.text = row:CreateFontString(nil, "OVERLAY")
                -- A FontString created without a font object has no font, and
                -- SetText on a fontless string errors. Give it one up front.
                NS.ApplyFont(row.text, DEFAULT_FONT_PATH, 12)
                row.text:SetPoint("LEFT", 6, 0)
                row.text:SetPoint("RIGHT", -6, 0)
                row.text:SetJustifyH("LEFT")
                row.text:SetWordWrap(false)

                row:SetScript("OnEnter", function(self)
                    self.highlight:Show()
                end)
                row:SetScript("OnLeave", function(self)
                    self.highlight:Hide()
                end)

                list.rows[index] = row
            end

            row:SetWidth(width - 26)
            row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
            row.highlight:SetColorTexture(Unpack(t.rowHoverBg))

            -- Font before text, always: setting an unloadable font clears the
            -- string's font, so the following SetText would then fail.
            NS.ApplyFont(row.text, (spec.fontFor and spec.fontFor(value)) or DEFAULT_FONT_PATH, 12)
            row.text:SetText(spec.labelFor and spec.labelFor(value) or tostring(value))

            if value == current then
                row.text:SetTextColor(Unpack(t.accent))
            else
                row.text:SetTextColor(Unpack(t.textNormal))
            end

            row:SetScript("OnClick", function()
                spec.onSelect(value)
                dropdown:RefreshLabel()
                list:Hide()
            end)

            row:Show()
        end

        local count = #options
        list.content:SetSize(width - 26, math.max(1, count * ROW_HEIGHT))
        list:SetHeight(math.min(count, MAX_VISIBLE) * ROW_HEIGHT + 8)
    end

    dropdown:SetScript("OnClick", function(self)
        if list:IsShown() then
            list:Hide()
            return
        end

        -- Only one menu open at a time. Two overlapping lists is never what
        -- anyone wants, and with the panel scrolling behind them a forgotten
        -- one can end up floating over unrelated controls.
        NS.CloseOpenDropdowns()
        NS.HideContextMenu()

        BuildRows()
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        list:Show()
        list:Raise()
    end)

    openLists[list] = true

    -- Clicking anywhere else closes it. A dropdown that can only be dismissed
    -- by picking something is a trap.
    list:SetScript("OnShow", function(self)
        self:EnableMouse(true)
    end)
    list:SetScript("OnHide", function(self)
        self:EnableMouse(false)
    end)

    dropdown:HookScript("OnHide", function()
        list:Hide()
    end)

    dropdown:RefreshLabel()
    return dropdown
end

function NS.CreateFilterTab(parent, text, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 24)
    button:SetNormalFontObject("GameFontHighlightSmall")
    button:SetText(text)
    local fs = button:GetFontString()
    fs:SetPoint("CENTER", 0, 0)

    -- Tabs were the only interactive element in the window with no hover
    -- response, which made them read as labels rather than controls.
    button:SetScript("OnEnter", function(self)
        if not self.isActive and self.bg then
            local t = NS.GetTheme()
            self.bg:SetColorTexture(Unpack(t.rowHoverBg))
            self:GetFontString():SetTextColor(Unpack(t.textPrimary))
        end
    end)
    button:SetScript("OnLeave", function(self)
        if not self.isActive then
            NS.StyleFilterTab(self, false)
        end
    end)

    return button
end

-- Paints a tab for its state. Tabs are repainted on demand rather than through
-- the theme registry, so callers must re-run this after a palette change.
function NS.StyleFilterTab(button, isActive)
    if not button.bg then
        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
    end
    if not button.bottomBar then
        button.bottomBar = button:CreateTexture(nil, "ARTWORK")
        button.bottomBar:SetPoint("BOTTOMLEFT", 0, 0)
        button.bottomBar:SetPoint("BOTTOMRIGHT", 0, 0)
        button.bottomBar:SetHeight(2)
    end

    local t = NS.GetTheme()
    button.isActive = isActive

    if isActive then
        button.bg:SetColorTexture(Unpack(t.tabActiveBg))
        button.bottomBar:SetColorTexture(Unpack(t.accentBright, 0.9))
        button:GetFontString():SetTextColor(Unpack(t.textPrimary))
    else
        button.bg:SetColorTexture(Unpack(t.toggleOffBg, 0.7))
        button.bottomBar:SetColorTexture(0, 0, 0, 0)
        button:GetFontString():SetTextColor(Unpack(t.textMuted))
    end
end

-- UIPanelScrollFrameTemplate keeps its scrollbar visible whether or not there
-- is anything to scroll, so a short list still shows arrows and a thumb. Wire
-- this to OnScrollRangeChanged and the bar only appears when it means something.
function NS.AutoHideScrollBar(scrollFrame)
    local bar = scrollFrame.ScrollBar
    if not bar then return end

    local function Update(self)
        local range = self:GetVerticalScrollRange() or 0
        if range > 1 then
            bar:Show()
        else
            bar:Hide()
        end
    end

    scrollFrame:HookScript("OnScrollRangeChanged", Update)
    Update(scrollFrame)
end

-- Replaces Blizzard's scroll bar chrome with a flat themed track and thumb.
--
-- The stock UIPanelScrollFrameTemplate bar spends 16px at each end on step
-- arrows nobody uses, which on a short list leaves the thumb almost no track
-- to move along - it ends up a few pixels tall and very hard to grab. Hiding
-- them gives the thumb the whole height.
--
-- The arrows are found by walking the bar's children rather than by name.
-- Blizzard has reshuffled these internals across expansions, and guessing at a
-- field name that no longer exists would silently leave the bar unstyled - the
-- same way guessing at a return position once emptied the raid list.
function NS.StyleScrollBar(scrollFrame, width)
    local bar = scrollFrame and scrollFrame.ScrollBar
    if not bar or bar.myNotesStyled then return end

    bar.myNotesStyled = true
    width = width or 10

    for _, child in ipairs({ bar:GetChildren() }) do
        if child.GetObjectType and child:GetObjectType() == "Button" then
            child:Hide()
            child:SetAlpha(0)
            child:EnableMouse(false)
        end
    end

    bar:SetWidth(width)

    -- Blizzard's own backdrop art sits in layers we do not own, so it is
    -- covered rather than removed.
    if not bar.myNotesTrack then
        bar.myNotesTrack = bar:CreateTexture(nil, "BACKGROUND")
        bar.myNotesTrack:SetPoint("TOPLEFT", 0, 0)
        bar.myNotesTrack:SetPoint("BOTTOMRIGHT", 0, 0)
        bar.myNotesTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
    end

    NS.RegisterThemed(bar.myNotesTrack, function(self, t)
        self:SetVertexColor(0, 0, 0, 0.30)
    end)

    -- GetThumbTexture is a Slider method, so it is stable regardless of how the
    -- template's child frames are arranged.
    local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
    if thumb then
        thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
        -- Tall enough to be a comfortable target on a long list; the client
        -- shrinks it proportionally as the content grows.
        thumb:SetSize(width, 48)

        NS.RegisterThemed(thumb, function(self, t)
            self:SetVertexColor(Unpack(t.accent, 0.85))
        end)

        bar:HookScript("OnEnter", function()
            local t = NS.GetTheme()
            thumb:SetVertexColor(Unpack(t.accentBright, 1))
        end)
        bar:HookScript("OnLeave", function()
            local t = NS.GetTheme()
            thumb:SetVertexColor(Unpack(t.accent, 0.85))
        end)
    end
end

-- Re-anchor a frame to its current top-left corner, in screen space.
--
-- Call this immediately before StartSizing("BOTTOMRIGHT"). That grows a frame
-- by moving the bottom-right corner while the opposite corner stays put - but
-- a frame anchored by its CENTER has no corner that stays put. Growing it
-- pushes the top-left outward as well, so the dragged corner travels at half
-- the speed of the cursor and the two drift apart, with a visible lurch at the
-- moment the drag starts. Pinning the top-left first gives the resize
-- something to hold still against.
--
-- GetLeft/GetTop report in the frame's own coordinate space, but the offsets
-- below are read in UIParent's. Those are the same number only while the two
-- scales match. They do today, but "today" is doing a lot of work in that
-- sentence, and the failure mode is a window that leaps across the screen.
function NS.AnchorForResize(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end

    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * scale, top * scale)
end

-- The standard close button is the only pure-white element in an otherwise
-- muted window, which made "close" the loudest thing on screen. Sizing it down
-- didn't help; the problem is contrast. Muted by default, full strength on
-- hover so it still reads as reachable.
function NS.SoftenCloseButton(button)
    button:SetAlpha(0.55)
    button:HookScript("OnEnter", function(self) self:SetAlpha(1) end)
    button:HookScript("OnLeave", function(self) self:SetAlpha(0.55) end)
end

-- ---------------------------------------------------------------------------
-- Window scaffolding
--
-- The Markup Help window established a pattern worth reusing: a movable
-- dialog that remembers where it was put, and that swallows its own Escape so
-- it closes before the window underneath it.
-- ---------------------------------------------------------------------------

-- `settingsKey` names a table under MyNotesDB.settings where the position is
-- stored. `defaultAnchor` is a function(panel) run when there's no saved spot.
-- The addon's side panels - markup help, settings, display rules, share - are
-- docked to the manager rather than floating free.
--
-- They used to be independently draggable, each remembering its own spot on
-- the screen. That sounded flexible and was not: the panels drifted away from
-- the window they describe, three of them saved positions that landed on top
-- of each other, and moving the manager left them behind. Anchoring to the
-- manager means they follow it for free - a WoW anchor is live, so there is no
-- update loop here at all - and one panel per side means they never overlap.
-- Negative by one pixel, so the two 1px borders overlap into a single shared
-- edge. At zero they sit side by side and read as a seam rather than a join.
local DOCK_GAP = -1
local dockedPanels = setmetatable({}, { __mode = "k" })

-- Hides every docked panel on `side` except `except`. Two panels docked to the
-- same edge would sit exactly on top of each other, so opening one closes the
-- other rather than burying it.
function NS.CloseDockedPanels(side, except)
    for panel, panelSide in pairs(dockedPanels) do
        if panel ~= except and panelSide == side and panel:IsShown() then
            panel:Hide()
        end
    end
end

function NS.DockDialog(panel, side)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")

    panel.dockSide = side
    dockedPanels[panel] = side

    function panel:Dock()
        local manager = NS.managerFrame
        self:ClearAllPoints()

        -- Every one of these is opened from the manager, but the manager can
        -- be closed while one is still up. Centred is the only sensible place
        -- for a panel with nothing to dock to.
        if not (manager and manager:IsShown()) then
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            return
        end

        if self.dockSide == "LEFT" then
            self:SetPoint("TOPRIGHT", manager, "TOPLEFT", -DOCK_GAP, 0)
        else
            self:SetPoint("TOPLEFT", manager, "TOPRIGHT", DOCK_GAP, 0)
        end
    end

    -- Dragging a docked panel moves the manager, so the whole cluster travels
    -- as one. Dragging the panel itself would only tear it off the window it
    -- belongs to, which is the behaviour being replaced.
    panel:SetScript("OnDragStart", function(self)
        local manager = NS.managerFrame

        if manager and manager:IsShown() and manager:IsMovable() then
            manager:StartMoving()
            self.draggingManager = manager
        end
    end)

    panel:SetScript("OnDragStop", function(self)
        local manager = self.draggingManager
        if not manager then return end

        self.draggingManager = nil
        manager:StopMovingOrSizing()

        if manager.SaveRect then
            manager.SaveRect(manager)
        end
    end)

    panel:HookScript("OnShow", function(self)
        -- A list left open in the panel this one is replacing would otherwise
        -- keep floating over the new one: dropdown lists are parented to
        -- UIParent so that they can escape their panel, which also means
        -- hiding the panel does not hide them.
        NS.CloseOpenDropdowns()
        NS.CloseDockedPanels(self.dockSide, self)
        self:Dock()
    end)
end

-- Escape closes this panel and stops there, leaving whatever is behind it open.
--
-- This can't be done by adding the panel to UISpecialFrames: CloseSpecialWindows
-- hides *every* shown frame in that list in one pass, so a single Escape would
-- dismiss the panel and its parent window together.
function NS.MakeEscapeClosable(panel)
    panel:EnableKeyboard(true)
    panel:SetPropagateKeyboardInput(true)

    panel:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            -- Order matters: the flag is read after this handler returns, so it
            -- has to be set before Hide().
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Reset on show, not on hide: clearing the flag from inside Hide() would
    -- run during the same key dispatch and let the Escape we just swallowed
    -- through to the parent window. A hidden frame gets no keyboard input, so
    -- leaving it set until next show is harmless.
    panel:HookScript("OnShow", function(self)
        self:SetPropagateKeyboardInput(true)
    end)
end

-- ---------------------------------------------------------------------------
-- Context menu
--
-- Built here rather than on Blizzard's menu system. UIDropDownMenu was
-- deprecated and replaced during Dragonflight/War Within, and which of the two
-- a given client has is exactly the kind of guess that has bitten this addon
-- before. A dozen lines of our own frame works on every client and already
-- matches the addon's palette.
-- ---------------------------------------------------------------------------

local contextMenu = nil

-- items: { { text = "...", onClick = function() end, isTitle = true } }
function NS.ShowContextMenu(anchor, items)
    NS.CloseOpenDropdowns()

    if not contextMenu then
        contextMenu = CreateFrame("Frame", "MyNotesContextMenu", UIParent, "BackdropTemplate")
        contextMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        contextMenu:SetBackdrop(FLAT_BACKDROP)
        contextMenu.buttons = {}

        RegisterThemed(contextMenu, function(self, t)
            self:SetBackdropColor(Unpack(t.windowBg, 0.98))
            self:SetBackdropBorderColor(Unpack(t.windowBorder))
        end)

        -- Closes on any click elsewhere. A menu that needs dismissing with a
        -- second deliberate click is a menu people leave open by accident.
        contextMenu:SetScript("OnUpdate", function(self)
            if not self:IsShown() then return end
            if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                if not self:IsMouseOver() then self:Hide() end
            end
        end)
    end

    local ROW = 20
    local PAD = 6
    local width = 150

    for _, button in ipairs(contextMenu.buttons) do
        button:Hide()
    end

    local y = -PAD

    for index, item in ipairs(items or {}) do
        local button = contextMenu.buttons[index]

        if not button then
            button = CreateFrame("Button", nil, contextMenu)
            button:SetHeight(ROW)

            button.label = button:CreateFontString(nil, "OVERLAY")
            button.label:SetFont(DEFAULT_FONT_PATH, 12, "")
            button.label:SetPoint("LEFT", 8, 0)
            button.label:SetJustifyH("LEFT")

            button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
            button.highlight:SetAllPoints()
            button.highlight:SetColorTexture(1, 1, 1, 0.08)

            contextMenu.buttons[index] = button
        end

        button:SetPoint("TOPLEFT", PAD, y)
        button:SetPoint("TOPRIGHT", -PAD, y)
        button.label:SetText(item.text or "")

        local theme = NS.GetTheme()
        if item.isTitle then
            button.label:SetTextColor(Unpack(theme.accent))
            button:EnableMouse(false)
            button.highlight:SetAlpha(0)
        elseif item.isChecked then
            button.label:SetTextColor(Unpack(theme.textPrimary))
            button:EnableMouse(true)
            button.highlight:SetAlpha(1)
        else
            button.label:SetTextColor(Unpack(theme.textMuted))
            button:EnableMouse(true)
            button.highlight:SetAlpha(1)
        end

        button:SetScript("OnClick", function()
            contextMenu:Hide()
            if item.onClick then item.onClick() end
        end)

        width = math.max(width, button.label:GetStringWidth() + 28)
        button:Show()
        y = y - ROW
    end

    contextMenu:SetSize(width, math.abs(y) + PAD)
    contextMenu:ClearAllPoints()

    -- Anchored to the cursor, which is where a right-click menu belongs.
    local scale = UIParent:GetEffectiveScale()
    local x, cursorY = GetCursorPosition()
    contextMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, cursorY / scale)
    contextMenu:Show()

    return contextMenu
end

function NS.HideContextMenu()
    if contextMenu then contextMenu:Hide() end
end

-- ---------------------------------------------------------------------------
-- Ornamented bar
--
-- A 3-slice horizontal bar: fixed-width decorated caps at each end, with a
-- panel stretching between them. Only the middle stretches, so end ornament
-- keeps its proportions at any window width - a single texture spanning the
-- whole bar would smear its detail as the window widened.
--
-- One cap texture serves all four positions. SetTexCoord mirrors it
-- horizontally for the right end and vertically for the bottom bar, so the
-- art is authored once.
--
-- Everything is tinted through the palette rather than baked, so the bar
-- follows the active theme - including class colour, which no painted-in
-- colour could.
-- ---------------------------------------------------------------------------

-- The cap art is the chevron and gem only. The tick mark that runs inward from
-- it in the mockup is a 1px line, so it is drawn rather than stored - keeping
-- the texture less than half the width it would otherwise need.
local BAR_CAP_TEXTURE = "Interface\\AddOns\\MyNotes\\Media\\barcap.tga"

-- The art occupies the top-left of a 128x128 file; the rest is transparent
-- padding, because WoW wants power-of-two dimensions.
local BAR_CAP_U = 68 / 128
local BAR_CAP_V = 108 / 128

-- Authored width over height, so the cap keeps its proportions whatever the
-- bar's height is set to.
local BAR_CAP_ASPECT = 68 / 108

-- Where the cap art's own two accent lines sit, as a fraction of its height.
--
-- Measured off the file rather than eyeballed: reading the alpha down the art's
-- inner edge puts the bright line's centre 5.8px into a 108px cap and the dim
-- one 5.0px up from its bottom. The long rails were drawn flush to the bar's
-- edges instead, so each one met the ornament a couple of pixels off and the
-- line visibly stepped where the art began.
local BAR_RAIL_TOP_FRACTION = 5.8 / 108
local BAR_RAIL_BOTTOM_FRACTION = 5.0 / 108

local BAR_RAIL_HEIGHT = 2
local BAR_RAIL_LOW_HEIGHT = 1

-- Drawn when there is no cap art: a bevelled block with a diamond, marking the
-- ends and holding the layout so the bar can be judged in game before any
-- texture is authored. Swapping in the real art replaces this wholesale.
local function BuildPlaceholderCap(cap, side)
    cap.outer = cap:CreateTexture(nil, "ARTWORK")
    cap.outer:SetPoint("TOP" .. side, cap, "TOP" .. side, 0, 0)
    cap.outer:SetPoint("BOTTOM" .. side, cap, "BOTTOM" .. side, 0, 0)
    cap.outer:SetWidth(3)

    local inward = (side == "LEFT") and 1 or -1

    cap.inner = cap:CreateTexture(nil, "ARTWORK")
    cap.inner:SetPoint("TOP" .. side, cap, "TOP" .. side, 7 * inward, -4)
    cap.inner:SetPoint("BOTTOM" .. side, cap, "BOTTOM" .. side, 7 * inward, 4)
    cap.inner:SetWidth(2)

    -- A square turned 45 degrees stands in for the gem in the mockup.
    cap.gem = cap:CreateTexture(nil, "OVERLAY")
    cap.gem:SetSize(9, 9)
    cap.gem:SetPoint(side, cap, side, 14 * inward, 0)
    cap.gem:SetRotation(math.rad(45))

    cap.pieces = { cap.outer, cap.inner, cap.gem }
end

-- `parent` hosts the bar; `height` is its thickness. Returns the frame, whose
-- `content` region is the clear area between the caps - anchor anything the
-- bar carries to that rather than to the bar itself.
function NS.CreateOrnamentBar(parent, height, capWidth)
    height = height or 56
    capWidth = capWidth or 64

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height)

    -- The panel and rails start where the ornament actually ends, not at the
    -- clearance width. Those are different numbers - clearance is how far the
    -- buttons stay clear, while the art is only as wide as its own aspect
    -- against the bar height - and using the wrong one left a visible gap
    -- between the chevron and the start of the accent line.
    --
    -- The 2px overlap tucks the panel under the ornament so the two meet with
    -- no seam at any bar height.
    local artWidth = height * BAR_CAP_ASPECT
    local inset = math.max(0, artWidth - 2)

    bar.panel = bar:CreateTexture(nil, "BACKGROUND")
    bar.panel:SetPoint("TOPLEFT", inset, 0)
    bar.panel:SetPoint("BOTTOMRIGHT", -inset, 0)

    -- The bright line along the bar's top edge, as in the mockup.
    bar.rail = bar:CreateTexture(nil, "ARTWORK")
    bar.rail:SetHeight(BAR_RAIL_HEIGHT)

    bar.railLow = bar:CreateTexture(nil, "ARTWORK")
    bar.railLow:SetHeight(BAR_RAIL_LOW_HEIGHT)

    -- Each rail is centred on the line the ornament carries at that edge, so
    -- the two meet as one continuous stroke. Re-run on a flip, because
    -- mirroring the art swaps which of its two lines each rail has to meet.
    function bar:LayoutRails()
        local topFraction = self.flipped and BAR_RAIL_BOTTOM_FRACTION or BAR_RAIL_TOP_FRACTION
        local bottomFraction = self.flipped and BAR_RAIL_TOP_FRACTION or BAR_RAIL_BOTTOM_FRACTION

        local topOffset = (height * topFraction) - (BAR_RAIL_HEIGHT / 2)
        local bottomOffset = (height * bottomFraction) - (BAR_RAIL_LOW_HEIGHT / 2)

        self.rail:ClearAllPoints()
        self.rail:SetPoint("TOPLEFT", inset, -topOffset)
        self.rail:SetPoint("TOPRIGHT", -inset, -topOffset)

        self.railLow:ClearAllPoints()
        self.railLow:SetPoint("BOTTOMLEFT", inset, bottomOffset)
        self.railLow:SetPoint("BOTTOMRIGHT", -inset, bottomOffset)
    end

    bar.caps = {}

    for _, side in ipairs({ "LEFT", "RIGHT" }) do
        local cap = CreateFrame("Frame", nil, bar)
        cap:SetWidth(capWidth)
        cap:SetPoint("TOP", 0, 0)
        cap:SetPoint("BOTTOM", 0, 0)
        cap:SetPoint(side, bar, side, 0, 0)

        -- The art keeps its authored proportions against the bar's height
        -- rather than filling the clearance width, which would squash it.
        -- The art keeps its authored proportions against the bar's height
        -- rather than filling the clearance width, which would squash it.
        -- Anchored by one vertical edge plus an explicit width: pinning TOP and
        -- BOTTOM as well would over-constrain and fight the width.
        local artWidth = height * BAR_CAP_ASPECT

        cap.art = cap:CreateTexture(nil, "ARTWORK")
        cap.art:SetPoint("TOP" .. side, cap, "TOP" .. side, 0, 0)
        cap.art:SetPoint("BOTTOM" .. side, cap, "BOTTOM" .. side, 0, 0)
        cap.art:SetWidth(artWidth)
        cap.art:Hide()

        BuildPlaceholderCap(cap, side)

        bar.caps[side] = cap
    end

    -- `flipped` mirrors the caps vertically, for a bar sitting at the bottom
    -- of a window whose ornament should point the other way.
    function bar:SetFlipped(flipped)
        self.flipped = flipped and true or false
        self:RefreshCapArt()
    end

    function bar:RefreshCapArt()
        self:LayoutRails()

        local bottom = self.flipped and 1 or 0
        local top = self.flipped and 0 or 1

        for side, cap in pairs(self.caps) do
            if BAR_CAP_TEXTURE then
                cap.art:SetTexture(BAR_CAP_TEXTURE)
                -- Left is the authored orientation; right is mirrored in x.
                local vTop = (top == 1) and BAR_CAP_V or 0
                local vBottom = (bottom == 1) and BAR_CAP_V or 0

                if side == "LEFT" then
                    cap.art:SetTexCoord(0, BAR_CAP_U, vBottom, vTop)
                else
                    cap.art:SetTexCoord(BAR_CAP_U, 0, vBottom, vTop)
                end
                cap.art:Show()
            else
                cap.art:Hide()
            end

            for _, piece in ipairs(cap.pieces) do
                piece:SetShown(not BAR_CAP_TEXTURE)
            end
        end
    end

    RegisterThemed(bar, function(self, t)
        self.panel:SetColorTexture(Unpack(t.panelBg, 0.92))
        self.rail:SetColorTexture(Unpack(t.accent, 0.55))
        self.railLow:SetColorTexture(Unpack(t.accent, 0.20))

        for _, cap in pairs(self.caps) do
            -- Art is authored greyscale so it can be tinted; the placeholder
            -- pieces take the same colours so both read the same.
            cap.art:SetVertexColor(Unpack(t.accent, 0.95))
            cap.outer:SetColorTexture(Unpack(t.accent, 0.90))
            cap.inner:SetColorTexture(Unpack(t.accent, 0.55))
            cap.gem:SetColorTexture(Unpack(t.accentBright, 1))
        end
    end)

    bar:RefreshCapArt()
    return bar
end

-- Points every ornament bar at a cap texture. Called once the art exists;
-- until then the bars draw their placeholder caps.
function NS.SetBarCapTexture(path)
    BAR_CAP_TEXTURE = path
end

-- The heavier inset border used by boxes you type into or read results from,
-- as opposed to FLAT_BACKDROP's 1px line around panels and popups. Shared
-- because the body editor and the preview strip had identical copies of it.
NS.INPUT_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}
