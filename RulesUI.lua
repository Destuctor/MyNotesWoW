local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- DISPLAY RULES WINDOW
--
-- Edits the conditions that gate when a note appears on screen.
--
-- Every row is built from the condition type's `fields` descriptor rather than
-- from anything hardcoded here, so a new condition type gets working inputs
-- without this file changing.
--
-- The live status line at the bottom is the important part. Conditional
-- visibility is invisible when it's wrong - you find out mid-pull. Showing
-- whether the rules match right now, and which clause is holding things up,
-- turns that from guesswork into reading a sentence.
-- ============================================================================

local DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"
local Unpack = NS.Unpack
local RegisterThemed = NS.RegisterThemed

local PANEL_WIDTH = 420

-- The rule list sits on its own panel, so the window reads in the same three
-- tiers as the manager does: window background, panel, then rows on the panel.
local LIST_PANEL_INSET = 16

-- These must match the scroll frame's actual insets exactly. A ScrollFrame
-- clips its children, so content wider than its frame silently loses its
-- right-hand edge - which is what previously cut the remove button in half.
local SCROLL_INSET_LEFT = 8
local SCROLL_INSET_RIGHT = 24
local CONTENT_WIDTH = PANEL_WIDTH - (LIST_PANEL_INSET * 2)
    - SCROLL_INSET_LEFT - SCROLL_INSET_RIGHT

local ROW_SPACING = 8

-- Everything above and below the scrolling rule list, used to size the window
-- to its content instead of leaving a fixed hole under a single rule.
--
-- The match mode is one line ("Show this note when [all rules match]")
-- rather than a label stacked above its dropdown, which is where the space
-- above the list came from.
local CHROME_ABOVE = 138

-- The Add button and the gaps around it. The status band is measured at
-- refresh time rather than assumed, since it grows a row per rule.
local ADD_BUTTON_BLOCK = 50

-- With no rules the list panel is hidden outright, so the window only needs
-- room for a line of explanation - hence a lower floor than before.
local MIN_PANEL_HEIGHT = 262
local MAX_PANEL_HEIGHT = 580

local STATUS_BAND_HEIGHT = 30

-- Width available inside a rule card, after its own padding and the space the
-- remove button occupies in the top-right.
local FIELD_WIDTH = CONTENT_WIDTH - 20

-- Rule row geometry, spelled out because the type dropdown has to stop before
-- the remove button starts. These were previously a single "- 46", which was
-- 9px short: the dropdown ran under the X, and its arrow sat beneath the
-- button's hit area. Deriving the width from the real positions means the two
-- cannot drift apart again.
local ROW_LEFT_INSET = 29        -- clears the enable checkbox
local ROW_REMOVE_SIZE = 22
local ROW_REMOVE_MARGIN = 6      -- gap from the row's right edge
local ROW_REMOVE_GAP = 10        -- breathing room between dropdown and button

local TYPE_WIDTH = CONTENT_WIDTH
    - ROW_LEFT_INSET - ROW_REMOVE_SIZE - ROW_REMOVE_MARGIN - ROW_REMOVE_GAP

local rulesFrame = nil

local function GetNote()
    return NS.selectedNote
end

local function EnsureConditions(note)
    note.conditions = note.conditions or {}
    return note.conditions
end

local function NotifyChanged()
    local note = GetNote()
    if not note then return end

    if NS.RefreshFloatingNote then
        NS.RefreshFloatingNote(NS.selectedScope, note)
    end
    if NS.managerFrame and NS.managerFrame:IsShown() and NS.managerFrame.RefreshNoteList then
        NS.managerFrame:RefreshNoteList()
    end
end

-- ---------------------------------------------------------------------------
-- Field editors
--
-- One builder per field type declared by a condition. Each returns the widget
-- and the height it used, so the row can stack them without knowing what they
-- are.
-- ---------------------------------------------------------------------------

local FieldBuilders = {}

-- Options may be a plain table or a function of the rule's current config, so
-- one dropdown can narrow another (pick an instance, then its bosses).
local function ResolveOptions(field, cfg)
    local options = field.options
    if type(options) == "function" then
        options = options(cfg)
    end
    return options or {}
end

-- Prev/next buttons that step through a choice field without opening its list.
-- Worth it on the boss selector in particular, where you're usually moving one
-- position along rather than picking from cold.
local function AttachStepper(parent, dropdown, field, cfg, onChanged)
    local function Step(delta)
        local options = ResolveOptions(field, cfg)
        local current = cfg[field.key]
        if current == nil then current = false end

        local index
        for position, option in ipairs(options) do
            if option.value == current then
                index = position
                break
            end
        end

        index = (index or 1) + delta
        -- Clamped rather than wrapped: stepping off the end of a boss list and
        -- landing back on "Any boss" would be a surprise, not a convenience.
        if index < 1 or index > #options then return end

        -- Same rule as the dropdown: `false` is "no filter" for an "Any ..."
        -- entry but a real choice on a two-way field.
        local value = options[index].value
        if value == false and not field.keepFalse then
            cfg[field.key] = nil
        else
            cfg[field.key] = value
        end

        for _, dependentKey in ipairs(field.resets or {}) do
            cfg[dependentKey] = nil
        end

        dropdown:RefreshLabel()
        onChanged()
    end

    local prev = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    prev:SetText("<")
    NS.StyleActionButton(prev, 18, 22, false)
    prev:SetScript("OnClick", function() Step(-1) end)

    -- Not named `next`: that would shadow Lua's own next() inside this scope.
    local nextButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    nextButton:SetText(">")
    NS.StyleActionButton(nextButton, 18, 22, false)
    nextButton:SetScript("OnClick", function() Step(1) end)

    return prev, nextButton
end

-- Changing a choice can reveal or hide other fields, so the row is rebuilt.
-- Deferred by a frame: this runs from inside a widget's own click handler,
-- which still touches that widget afterwards, and rebuilding immediately would
-- pull it out from under itself.
local function CommitChoice()
    NotifyChanged()

    if rulesFrame then
        C_Timer.After(0, function()
            if rulesFrame and rulesFrame:IsShown() then
                rulesFrame:RefreshRules()
            end
        end)
    end
end

FieldBuilders.choice = function(parent, field, cfg, width)
    local STEPPER_WIDTH = 18
    local STEPPER_GAP = 3

    -- With steppers the three widgets live in a container, so the layout pass
    -- still deals with a single object of a known width.
    local container, host, dropdownWidth = nil, parent, width

    if field.stepper then
        container = CreateFrame("Frame", nil, parent)
        container:SetSize(width, 24)
        host = container
        dropdownWidth = width - (STEPPER_WIDTH * 2) - (STEPPER_GAP * 2) - 4
    end

    local dropdown = NS.CreateDropdown(host, dropdownWidth, {
        getOptions = function()
            local values = {}
            for _, option in ipairs(ResolveOptions(field, cfg)) do
                table.insert(values, option.value)
            end
            return values
        end,
        getCurrent = function()
            local current = cfg[field.key]
            if current == nil then current = field.default end
            -- `false` is a real, selectable value here ("Any raid"), so it has
            -- to survive rather than being treated as absent.
            if current == nil then current = false end
            return current
        end,
        labelFor = function(value)
            for _, option in ipairs(ResolveOptions(field, cfg)) do
                if option.value == value then
                    return option.label
                end
            end
            return tostring(value)
        end,
        onSelect = function(value)
            -- `false` means two different things across these fields. In an
            -- "Any raid" / "Any difficulty" entry it means no filter, and
            -- absent is the right storage: the evaluators test for a value
            -- being present. In a genuinely two-way field like in/out of
            -- combat it is a real choice that has to survive.
            --
            -- Storing nil for both is why picking "Out of combat" did nothing:
            -- it saved nil, getCurrent fell through to the default, and the
            -- dropdown snapped straight back to "In combat".
            if value == false and not field.keepFalse then
                cfg[field.key] = nil
            else
                cfg[field.key] = value
            end

            for _, dependentKey in ipairs(field.resets or {}) do
                cfg[dependentKey] = nil
            end

            CommitChoice()
        end,
    })

    if not container then
        return dropdown, 24
    end

    local prev, nextButton = AttachStepper(container, dropdown, field, cfg, CommitChoice)
    prev:SetPoint("LEFT", 0, 0)
    nextButton:SetPoint("LEFT", prev, "RIGHT", STEPPER_GAP, 0)
    dropdown:SetPoint("LEFT", nextButton, "RIGHT", STEPPER_GAP + 1, 0)

    return container, 24
end

local function BuildTextLikeField(parent, field, cfg, width, numeric)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetWidth(width - 12)
    NS.StyleEditBox(box, 22)

    if numeric then
        box:SetNumeric(false) -- allow blank; validated on commit instead
    end

    local current = cfg[field.key]
    box:SetText(current ~= nil and tostring(current) or "")

    local function Commit(self)
        local text = self:GetText() or ""
        text = text:gsub("^%s+", ""):gsub("%s+$", "")

        if text == "" then
            cfg[field.key] = nil
        elseif numeric then
            -- Blank means "any", so a non-numeric entry is discarded rather
            -- than stored as text a numeric comparison would never match.
            cfg[field.key] = tonumber(text)
            self:SetText(cfg[field.key] and tostring(cfg[field.key]) or "")
        else
            cfg[field.key] = text
        end

        NotifyChanged()
        if rulesFrame then rulesFrame:RefreshStatus() end
    end

    box:SetScript("OnEnterPressed", function(self)
        Commit(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", Commit)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    return box, 22
end

-- A list of timing windows: one note can appear at several points in a fight
-- without needing the raid, boss and difficulty repeated in a separate rule
-- for each appearance.
FieldBuilders.timewindows = function(parent, field, cfg, width)
    local ROW_HEIGHT = 24
    local ROW_GAP = 3
    local BOX_WIDTH = 52

    -- Editing converts a legacy single from/to pair into the list form, so the
    -- two representations never coexist on one rule.
    local function EnsureList()
        if not cfg.windows then
            cfg.windows = {}
            if cfg.fromSeconds or cfg.toSeconds then
                table.insert(cfg.windows, { from = cfg.fromSeconds, to = cfg.toSeconds })
            end
        end
        cfg.fromSeconds = nil
        cfg.toSeconds = nil
        return cfg.windows
    end

    local windows = NS.GetEncounterWindows(cfg) or {}
    local container = CreateFrame("Frame", nil, parent)

    local function Rebuild()
        if rulesFrame then
            C_Timer.After(0, function()
                if rulesFrame and rulesFrame:IsShown() then
                    rulesFrame:RefreshRules()
                end
            end)
        end
    end

    -- Shown as "at 90 for 60", stored as from/to.
    --
    -- A duration is how people actually describe these - "soak at 1:30 for
    -- twenty seconds" - where an end time makes you do the arithmetic. The
    -- stored pair stays from/to regardless: the evaluator, the timeline and
    -- every export string already in circulation are built on it, and none of
    -- them need to change for a relabelled pair of boxes.
    --
    -- A blank duration means "until the fight ends", the same unbounded window
    -- a blank end time always meant.
    local function ReadDuration(window)
        if not window or not window.to then return nil end
        return window.to - (window.from or 0)
    end

    local function WriteDuration(window, duration)
        window.to = duration and ((window.from or 0) + duration) or nil
    end

    local function MakeBox(index, key, xOffset, yOffset)
        local box = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        box:SetAutoFocus(false)
        box:SetSize(BOX_WIDTH - 12, 20)
        box:SetPoint("TOPLEFT", xOffset, yOffset)
        NS.StyleEditBox(box, 20)

        local window = windows[index]
        local value
        if key == "duration" then
            value = ReadDuration(window)
        else
            value = window and window[key]
        end
        box:SetText(value and tostring(value) or "")

        local function Commit(self)
            local text = (self:GetText() or ""):gsub("%s", "")
            local list = EnsureList()
            list[index] = list[index] or {}

            -- Blank means unbounded on that side, so a non-number is discarded
            -- rather than stored as text no comparison would ever match.
            local number = tonumber(text)

            if key == "duration" then
                -- Zero or negative would store an end before its start, which
                -- can never match. Read as unbounded instead.
                if number and number <= 0 then number = nil end
                WriteDuration(list[index], number)
            else
                -- Moving the start keeps the duration already set rather than
                -- silently stretching or shrinking the window.
                local duration = ReadDuration(list[index])
                list[index][key] = number
                WriteDuration(list[index], duration)
            end

            NotifyChanged()
            -- A full rebuild rather than just the status: changing the start
            -- moves the end, so the other box on this row is now stale.
            if rulesFrame then rulesFrame:RefreshRules() end
        end

        box:SetScript("OnEnterPressed", function(self) Commit(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", Commit)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        return box
    end

    local y = 0

    for index = 1, math.max(1, #windows) do
        MakeBox(index, "from", 0, -y)

        local joiner = NS.CreateFieldLabel(container, "for")
        joiner:SetWidth(20)
        joiner:SetJustifyH("CENTER")
        joiner:SetPoint("TOPLEFT", BOX_WIDTH - 2, -y - 5)

        MakeBox(index, "duration", BOX_WIDTH + 20, -y)

        -- The unit is on the duration rather than on both boxes: "at 90 for 60"
        -- is unambiguous once one of them says seconds.
        local unit = NS.CreateFieldLabel(container, "s")
        unit:SetWidth(10)
        unit:SetJustifyH("LEFT")
        unit:SetPoint("TOPLEFT", (BOX_WIDTH * 2) + 12, -y - 5)

        -- Only offered once there is more than one, since removing the only
        -- window is what the blank boxes already express.
        if #windows > 1 then
            local remove = CreateFrame("Button", nil, container, "UIPanelCloseButton")
            remove:SetSize(18, 18)
            remove:SetPoint("TOPLEFT", (BOX_WIDTH * 2) + 26, -y - 1)
            NS.SoftenCloseButton(remove)
            remove:SetScript("OnClick", function()
                local list = EnsureList()
                table.remove(list, index)
                NotifyChanged()
                Rebuild()
            end)
        end

        y = y + ROW_HEIGHT + ROW_GAP
    end

    local addButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    addButton:SetPoint("TOPLEFT", 0, -y)
    addButton:SetText("+ time")
    NS.StyleActionButton(addButton, 66, 20, false)
    addButton:SetScript("OnClick", function()
        local list = EnsureList()
        table.insert(list, {})
        NotifyChanged()
        Rebuild()
    end)

    y = y + 22

    container:SetSize(width, y)
    return container, y
end

-- A read-only time axis for the encounter timing window.
--
-- Two number boxes tell you the window is 90 to 150, but not what that means
-- inside a fight. This draws the span, marks each minute, and - once a pull is
-- underway - runs a playhead along it, so the rule can be checked against the
-- fight rather than only read.
FieldBuilders.timeline = function(parent, field, cfg, width)
    local HEIGHT = 26
    local TRACK_HEIGHT = 8

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(width, HEIGHT)

    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetPoint("TOPLEFT", 0, -4)
    bar.track:SetPoint("TOPRIGHT", 0, -4)
    bar.track:SetHeight(TRACK_HEIGHT)

    -- One texture per window, so a rule that pops several times in a fight
    -- shows every appearance on the axis at once.
    bar.windowTextures = {}

    bar.playhead = bar:CreateTexture(nil, "OVERLAY")
    bar.playhead:SetWidth(2)
    bar.playhead:SetPoint("TOP", bar, "TOP", 0, -2)
    bar.playhead:SetHeight(TRACK_HEIGHT + 4)
    bar.playhead:Hide()

    bar.ticks = {}
    bar.tickLabels = {}

    bar.startLabel = bar:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(bar.startLabel, DEFAULT_FONT_PATH, 10)
    bar.startLabel:SetPoint("TOPLEFT", 0, -14)
    bar.startLabel:SetText("0:00")

    bar.endLabel = bar:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(bar.endLabel, DEFAULT_FONT_PATH, 10)
    bar.endLabel:SetPoint("TOPRIGHT", 0, -14)

    local function FormatClock(seconds)
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end

    function bar:Refresh()
        local t = NS.GetTheme()
        local windows = NS.GetEncounterWindows(cfg) or { {} }

        -- The furthest point any window reaches, used to make sure the axis is
        -- long enough to show everything that has been configured.
        local furthest = 0
        for _, window in ipairs(windows) do
            furthest = math.max(furthest, window.to or window.from or 0)
        end

        local from, to = 0, (furthest > 0) and furthest or nil

        -- Prefer a length recorded from an actual pull of this boss. Failing
        -- that, fit the axis to whatever window is set, rounded to a whole
        -- minute, with a floor so a short window doesn't produce a scale where
        -- every tick lands on the last.
        local recorded, exactDifficulty = NS.GetEncounterDuration(
            cfg.encounterID or cfg.customEncounterID, cfg.difficultyID)

        local span, isRecorded

        if recorded then
            -- Rounded up to the next half minute so the end of the fight isn't
            -- flush against the end of the bar.
            span = math.ceil(recorded / 30) * 30
            isRecorded = true
        else
            span = math.max(300, math.ceil(((to or from) + 60) / 60) * 60)
            isRecorded = false
        end

        -- A window set beyond the recorded length still has to be visible, or
        -- the user cannot see what they have configured.
        if to and to > span then
            span = math.ceil((to + 30) / 30) * 30
            isRecorded = false
        end

        self.span = span
        self.track:SetColorTexture(Unpack(t.sliderTrack))

        -- "~" marks an estimate, so a scale that is a guess is never mistaken
        -- for a measured fight length.
        self.endLabel:SetText((isRecorded and "" or "~") .. FormatClock(span))
        self.startLabel:SetTextColor(Unpack(t.textDim))

        -- Written out rather than as `cond and Unpack(a) or Unpack(b)`: Lua
        -- truncates a multiple-return to a single value inside and/or, so that
        -- form would pass only the red channel and drop green, blue and alpha.
        if isRecorded then
            self.endLabel:SetTextColor(Unpack(t.accentBright))
        else
            self.endLabel:SetTextColor(Unpack(t.textDim))
        end

        if isRecorded then
            self.recordedNote = exactDifficulty
                and "Longest pull recorded on this difficulty."
                or "Longest pull recorded on another difficulty of this boss."
        else
            self.recordedNote = "No pull recorded yet - showing an estimate. Fight this boss once and the scale will match it."
        end

        -- One highlight per window. With no upper bound a window runs to the
        -- end of the axis, which is what "blank = rest of the fight" means.
        for index, window in ipairs(windows) do
            local texture = self.windowTextures[index]

            if not texture then
                texture = self:CreateTexture(nil, "ARTWORK")
                texture:SetHeight(TRACK_HEIGHT)
                self.windowTextures[index] = texture
            end

            local x1 = ((window.from or 0) / span) * width
            local x2 = ((window.to or span) / span) * width

            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", self.track, "TOPLEFT", x1, 0)
            texture:SetWidth(math.max(2, x2 - x1))
            texture:SetColorTexture(Unpack(t.accent, 0.85))
            texture:Show()
        end

        for index = #windows + 1, #self.windowTextures do
            self.windowTextures[index]:Hide()
        end

        for index = 1, 20 do
            local tick = self.ticks[index]
            local at = index * 60

            if at < span then
                if not tick then
                    tick = self:CreateTexture(nil, "ARTWORK")
                    tick:SetWidth(1)
                    tick:SetHeight(TRACK_HEIGHT)
                    self.ticks[index] = tick
                end
                tick:ClearAllPoints()
                tick:SetPoint("TOPLEFT", self.track, "TOPLEFT", (at / span) * width, 0)
                tick:SetColorTexture(0, 0, 0, 0.45)
                tick:Show()
            elseif tick then
                tick:Hide()
            end
        end

        -- Playhead, only while a pull is actually running.
        local state = NS.conditionState
        local elapsed = state and state.encounterStart and (GetTime() - state.encounterStart)

        if elapsed and elapsed >= 0 and elapsed <= span then
            self.playhead:ClearAllPoints()
            self.playhead:SetPoint("TOP", self.track, "TOPLEFT", (elapsed / span) * width, 4)
            self.playhead:SetColorTexture(Unpack(t.warning))
            self.playhead:Show()
        else
            self.playhead:Hide()
        end
    end

    bar:Refresh()

    -- Where the scale came from is not obvious from the bar itself, and it
    -- changes what the picture means: an estimate is a blank canvas, a
    -- recorded length is the actual fight.
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function(self)
        local t = NS.GetTheme()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Fight timeline", Unpack(t.textPrimary))
        GameTooltip:AddLine(self.recordedNote or "", 0.7, 0.75, 0.82, true)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local accumulated = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        accumulated = accumulated + elapsed
        if accumulated < 0.2 then return end
        accumulated = 0
        self:Refresh()
    end)

    return bar, HEIGHT
end

FieldBuilders.text = function(parent, field, cfg, width)
    return BuildTextLikeField(parent, field, cfg, width, false)
end

FieldBuilders.number = function(parent, field, cfg, width)
    return BuildTextLikeField(parent, field, cfg, width, true)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function CreateRulesFrame()
    if rulesFrame then return rulesFrame end

    local panel = CreateFrame("Frame", "MyNotesRulesFrame", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 460)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop(NS.FLAT_BACKDROP)
    panel:Hide()

    panel.title = panel:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.title, DEFAULT_FONT_PATH, 18)
    panel.title:SetPoint("TOPLEFT", 20, -16)
    panel.title:SetText("Display Rules")

    panel.subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.subtitle:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    panel.subtitle:SetText("")
    RegisterThemed(panel.subtitle, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    panel.headerLine = panel:CreateTexture(nil, "ARTWORK")
    panel.headerLine:SetPoint("TOPLEFT", 20, -58)
    panel.headerLine:SetPoint("TOPRIGHT", -20, -58)
    panel.headerLine:SetHeight(1)
    NS.StyleDialog(panel, panel.title, panel.headerLine)

    panel.closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    panel.closeButton:SetPoint("TOPRIGHT", -6, -6)
    panel.closeButton:SetScript("OnClick", function() panel:Hide() end)

    -- Match mode, read as a sentence across one line rather than a label
    -- stacked over its control. It is a phrase either way, and laying it out
    -- as one reclaims the height the list now uses.
    panel.modeLabel = NS.CreateFieldLabel(panel, "Show this note when")
    panel.modeLabel:SetPoint("TOPLEFT", 20, -82)

    panel.modeDropdown = NS.CreateDropdown(panel, 150, {
        getOptions = function() return { "all", "any" } end,
        labelFor = function(value)
            return value == "any" and "any rule matches" or "all rules match"
        end,
        getCurrent = function()
            local note = GetNote()
            return (note and note.conditionMode) or "all"
        end,
        onSelect = function(value)
            local note = GetNote()
            if not note then return end
            note.conditionMode = value
            NotifyChanged()
            panel:RefreshStatus()
        end,
    })
    panel.modeDropdown:SetPoint("LEFT", panel.modeLabel, "RIGHT", 10, 0)

    -- Section heading, in the accent, matching how the manager titles its
    -- columns.
    panel.rulesHeading = NS.CreateSectionLabel(panel, "Rules", "TOPLEFT", panel, "TOPLEFT", 20, -110)

    -- How many rules, as the same pill the folder headers use. Consistency is
    -- half of it; the other half is that "Rules" alone says nothing about
    -- whether there are three of them or none.
    panel.rulesCountPill = panel:CreateTexture(nil, "ARTWORK")
    panel.rulesCountPill:SetPoint("LEFT", panel.rulesHeading, "RIGHT", 8, 0)
    panel.rulesCountPill:SetSize(26, 16)
    panel.rulesCountPill:Hide()

    RegisterThemed(panel.rulesCountPill, function(self, t)
        self:SetColorTexture(Unpack(t.accent, 0.22))
    end)

    panel.rulesCount = panel:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.rulesCount, DEFAULT_FONT_PATH, 12)
    panel.rulesCount:SetPoint("CENTER", panel.rulesCountPill, "CENTER", 0, 0)
    panel.rulesCount:Hide()

    RegisterThemed(panel.rulesCount, function(self, t)
        self:SetTextColor(Unpack(t.textPrimary))
    end)

    -- The list sits on its own panel so the window reads in the manager's three
    -- tiers - background, panel, rows - rather than cards floating on the
    -- window's own backdrop.
    panel.listPanel = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    panel.listPanel:SetPoint("TOPLEFT", panel, "TOPLEFT", LIST_PANEL_INSET, -CHROME_ABOVE)
    panel.listPanel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -LIST_PANEL_INSET, -CHROME_ABOVE)
    NS.StylePanel(panel.listPanel, 0.94)

    -- Insets come from the same constants CONTENT_WIDTH is derived from, so the
    -- content can't drift wider than the frame clipping it.
    panel.scroll = CreateFrame("ScrollFrame", nil, panel.listPanel, "UIPanelScrollFrameTemplate")
    panel.scroll:SetPoint("TOPLEFT", SCROLL_INSET_LEFT, -SCROLL_INSET_LEFT)
    panel.scroll:SetPoint("BOTTOMRIGHT", -SCROLL_INSET_RIGHT, SCROLL_INSET_LEFT)

    panel.content = CreateFrame("Frame", nil, panel.scroll)
    panel.content:SetSize(CONTENT_WIDTH, 1)
    panel.scroll:SetScrollChild(panel.content)
    NS.AutoHideScrollBar(panel.scroll)
    NS.StyleScrollBar(panel.scroll)

    panel.ruleRows = {}

    -- The empty state is a line of text on the window itself, not inside the
    -- list panel. An empty bordered box is a container advertising that it has
    -- nothing in it; with no rules there is nothing to contain, so the panel is
    -- hidden outright and this takes its place.
    panel.emptyText = panel:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.emptyText, DEFAULT_FONT_PATH, 12)
    panel.emptyText:SetPoint("TOPLEFT", panel.rulesHeading, "BOTTOMLEFT", 0, -16)
    panel.emptyText:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    panel.emptyText:SetJustifyH("LEFT")
    panel.emptyText:SetSpacing(5)
    panel.emptyText:SetText("No rules yet - this note shows whenever it is turned on.\nAdd one to have it appear only in certain fights, zones or roles.")
    RegisterThemed(panel.emptyText, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)

    -- Live status.
    --
    -- Given a band of its own along the bottom edge rather than left as loose
    -- text. Conditional visibility is invisible when it is wrong - you find out
    -- mid-pull - so whether the note is showing right now, and what is holding
    -- it back, is the single most useful thing this window says. A status light
    -- carries that at a glance; the sentence explains it.
    panel.statusBand = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    panel.statusBand:SetPoint("BOTTOMLEFT", 1, 1)
    panel.statusBand:SetPoint("BOTTOMRIGHT", -1, 1)
    panel.statusBand:SetHeight(STATUS_BAND_HEIGHT)

    panel.statusBandBg = panel.statusBand:CreateTexture(nil, "BACKGROUND")
    panel.statusBandBg:SetAllPoints()

    RegisterThemed(panel.statusBandBg, function(self, t)
        self:SetColorTexture(Unpack(t.panelBg, 0.85))
    end)

    panel.statusBandTop = panel.statusBand:CreateTexture(nil, "ARTWORK")
    panel.statusBandTop:SetPoint("TOPLEFT", 0, 0)
    panel.statusBandTop:SetPoint("TOPRIGHT", 0, 0)
    panel.statusBandTop:SetHeight(1)

    RegisterThemed(panel.statusBandTop, function(self, t)
        self:SetColorTexture(Unpack(t.panelBorder))
    end)

    -- Anchored to the top of the band rather than its middle: the band grows
    -- downwards as rules are added, and the headline has to stay put while the
    -- breakdown appears underneath it.
    panel.statusDot = panel.statusBand:CreateTexture(nil, "OVERLAY")
    panel.statusDot:SetPoint("TOPLEFT", 19, -11)
    panel.statusDot:SetSize(8, 8)

    panel.statusLine = panel.statusBand:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.statusLine, DEFAULT_FONT_PATH, 12)
    panel.statusLine:SetPoint("TOPLEFT", panel.statusBand, "TOPLEFT", 33, -8)
    panel.statusLine:SetPoint("RIGHT", panel.statusBand, "RIGHT", -16, 0)
    panel.statusLine:SetJustifyH("LEFT")
    panel.addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    -- Anchored above the status band rather than to the window bottom, so both
    -- it and the list move up when the band grows a breakdown.
    panel.addButton:SetPoint("BOTTOMLEFT", panel.statusBand, "TOPLEFT", 19, 12)
    panel.addButton:SetText("+  Add rule")
    NS.StyleActionButton(panel.addButton, 120, 26, true)

    -- Set here rather than with the rest of the list panel: it anchors to the
    -- Add button, which does not exist yet at that point.
    panel.listPanel:SetPoint("BOTTOM", panel.addButton, "TOP", 0, 12)

    panel.addButton:SetScript("OnClick", function()
        local note = GetNote()
        if not note then return end

        local types = NS.GetConditionTypes()
        if #types == 0 then return end

        local conditions = EnsureConditions(note)
        local newRule = { type = types[1] }

        -- Seed declared defaults so a fresh rule is immediately meaningful
        -- rather than matching nothing until every field is filled in.
        local definition = NS.GetConditionDefinition(types[1])
        for _, field in ipairs(definition and definition.fields or {}) do
            if field.default ~= nil then
                newRule[field.key] = field.default
            end
        end

        table.insert(conditions, newRule)
        NotifyChanged()
        panel:RefreshRules()
    end)


    -- One row per rule beneath the headline: a mark saying whether that rule is
    -- satisfied, then what it is waiting for.
    panel.statusRows = {}

    local STATUS_ROW_HEIGHT = 17
    local MET_COLOR = { 0.45, 0.92, 0.60 }
    local UNMET_COLOR = { 0.98, 0.70, 0.35 }

    local function GetStatusRow(index)
        local row = panel.statusRows[index]
        if row then return row end

        row = {}

        row.mark = panel.statusBand:CreateFontString(nil, "OVERLAY")
        NS.ApplyFont(row.mark, DEFAULT_FONT_PATH, 12)
        row.mark:SetWidth(12)
        row.mark:SetJustifyH("LEFT")

        row.text = panel.statusBand:CreateFontString(nil, "OVERLAY")
        NS.ApplyFont(row.text, DEFAULT_FONT_PATH, 12)
        row.text:SetJustifyH("LEFT")

        panel.statusRows[index] = row
        return row
    end

    local function HideStatusRowsFrom(index)
        for position = index, #panel.statusRows do
            panel.statusRows[position].mark:Hide()
            panel.statusRows[position].text:Hide()
        end
    end

    function panel:RefreshStatus()
        local note = GetNote()

        if not note then
            self.statusLine:SetText("")
            self.statusDot:Hide()
            HideStatusRowsFrom(1)
            self.statusBand:SetHeight(STATUS_BAND_HEIGHT)
            return
        end

        local info = NS.DescribeConditions(note)
        local t = NS.GetTheme()

        self.statusDot:Show()

        -- The breakdown earns its space only when there is more than one rule
        -- to break down. With a single rule the headline already names it, and
        -- repeating it underneath would be noise.
        local showRows = #info.rules > 1

        -- The dot and the words always agree: dim for "not consulted", green
        -- for showing, amber for held back.
        if not note.visible then
            self.statusDot:SetColorTexture(Unpack(t.textDim))
            self.statusLine:SetTextColor(Unpack(t.textDim))
            self.statusLine:SetText("Note is turned off - rules are not consulted.")
            showRows = false

        elseif info.activeCount == 0 then
            self.statusDot:SetColorTexture(Unpack(t.textDim))
            self.statusLine:SetTextColor(Unpack(t.textDim))
            self.statusLine:SetText(#info.rules == 0
                and "Showing now - no rules."
                or "Showing now - all rules are switched off.")
            showRows = false

        elseif info.matched then
            self.statusDot:SetColorTexture(Unpack(MET_COLOR))
            self.statusLine:SetTextColor(Unpack(MET_COLOR))
            self.statusLine:SetText(showRows
                and (info.mode == "any" and "Showing now - a rule matches:" or "Showing now - all rules match:")
                or ("Showing now - " .. ((info.rules[1] and info.rules[1].text) or "no rules") .. "."))

        else
            self.statusDot:SetColorTexture(Unpack(UNMET_COLOR))
            self.statusLine:SetTextColor(Unpack(UNMET_COLOR))
            self.statusLine:SetText(showRows
                and "Hidden - waiting on:"
                or ("Hidden - waiting on " .. ((info.rules[1] and info.rules[1].text) or "its rules") .. "."))
        end

        if not showRows then
            HideStatusRowsFrom(1)
            self.statusBand:SetHeight(STATUS_BAND_HEIGHT)
            return
        end

        local y = -4

        for index, rule in ipairs(info.rules) do
            local row = GetStatusRow(index)

            row.mark:ClearAllPoints()
            row.mark:SetPoint("TOPLEFT", self.statusLine, "BOTTOMLEFT", 0, y)
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", row.mark, "RIGHT", 4, 0)
            row.text:SetPoint("RIGHT", self.statusBand, "RIGHT", -16, 0)

            if not rule.enabled then
                -- Greyed rather than dropped: a rule you switched off is still
                -- part of the setup you are looking at, and omitting it would
                -- make this list disagree with the rules above it.
                row.mark:SetText("-")
                row.mark:SetTextColor(Unpack(t.textDim))
                row.text:SetTextColor(Unpack(t.textDim))
                row.text:SetText(rule.text .. " (off)")

            elseif rule.met then
                -- ASCII marks only. A tick glyph is exactly the sort of
                -- character that silently failed to render on this client
                -- before, and a status line that renders as a blank box would
                -- defeat the point of having one.
                row.mark:SetText("+")
                row.mark:SetTextColor(Unpack(MET_COLOR))
                row.text:SetTextColor(Unpack(t.textMuted))
                row.text:SetText(rule.text)

            else
                row.mark:SetText("*")
                row.mark:SetTextColor(Unpack(UNMET_COLOR))
                row.text:SetTextColor(Unpack(t.textPrimary))
                row.text:SetText(rule.text)
            end

            row.mark:Show()
            row.text:Show()
            y = y - STATUS_ROW_HEIGHT
        end

        HideStatusRowsFrom(#info.rules + 1)
        self.statusBand:SetHeight(STATUS_BAND_HEIGHT + (#info.rules * STATUS_ROW_HEIGHT) + 4)
    end

    -- ------------------------------------------------------------------
    -- Rule rows
    -- ------------------------------------------------------------------

    local function BuildRuleRow(index, cfg, yOffset)
        local row = panel.ruleRows[index]

        if not row then
            row = CreateFrame("Frame", nil, panel.content, "BackdropTemplate")
            row:SetBackdrop(NS.FLAT_BACKDROP)
            row:SetWidth(CONTENT_WIDTH)

            -- A rail down the left edge, accent while the rule is on and grey
            -- while it is off. Two things at once: it gives an otherwise flat
            -- box some structure, and it makes a disabled rule readable from
            -- across the window rather than only by squinting at a 14px
            -- checkbox. Accent as a line rather than a fill, which is what
            -- keeps the window from turning into a wall of colour.
            row.rail = row:CreateTexture(nil, "ARTWORK")
            row.rail:SetPoint("TOPLEFT", 1, -1)
            row.rail:SetPoint("BOTTOMLEFT", 1, 1)
            row.rail:SetWidth(2)

            row.removeButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.removeButton:SetSize(ROW_REMOVE_SIZE, ROW_REMOVE_SIZE)
            row.removeButton:SetPoint("TOPRIGHT", -ROW_REMOVE_MARGIN, -7)
            NS.SoftenCloseButton(row.removeButton)
            NS.AttachTooltip(row.removeButton, "Remove rule")

            -- Switch a rule off without deleting it, so a setup can be tried
            -- both ways without losing how it was configured.
            row.enableToggle = CreateFrame("Frame", nil, row, "BackdropTemplate")
            row.enableToggle:SetSize(14, 14)
            row.enableToggle:SetPoint("TOPLEFT", 9, -13)
            row.enableToggle:SetBackdrop(NS.FLAT_BACKDROP)
            row.enableToggle:EnableMouse(true)

            row.enableFill = row.enableToggle:CreateTexture(nil, "OVERLAY")
            row.enableFill:SetPoint("TOPLEFT", 3, -3)
            row.enableFill:SetPoint("BOTTOMRIGHT", -3, 3)

            row.enableToggle:SetScript("OnMouseDown", function(self)
                local cfgRef = self:GetParent().cfg
                if not cfgRef then return end
                cfgRef.enabled = (cfgRef.enabled == false)
                NotifyChanged()
                if rulesFrame then rulesFrame:RefreshRules() end
            end)

            NS.AttachTooltip(row.enableToggle, "Rule enabled",
                "Switch this rule off without removing it.")

            RegisterThemed(row, function(self, t)
                self:SetBackdropColor(Unpack(t.rowBg))
                self:SetBackdropBorderColor(Unpack(t.rowBorder))
            end)

            panel.ruleRows[index] = row
        end

        -- Field widgets are rebuilt per refresh because changing a rule's type
        -- changes which fields exist; keeping stale ones around would leak
        -- inputs belonging to the previous type.
        if row.fieldWidgets then
            for _, widget in ipairs(row.fieldWidgets) do
                widget:Hide()
                widget:SetParent(nil)
            end
        end
        row.fieldWidgets = {}

        if not row.typeDropdown then
            row.typeDropdown = NS.CreateDropdown(row, TYPE_WIDTH, {
                getOptions = function() return NS.GetConditionTypes() end,
                labelFor = function(value)
                    local definition = NS.GetConditionDefinition(value)
                    return definition and definition.name or tostring(value)
                end,
                getCurrent = function() return row.cfg and row.cfg.type end,
                onSelect = function(value)
                    if not row.cfg then return end
                    if row.cfg.type == value then return end

                    -- Switching type discards the old parameters: they belong
                    -- to a different rule and would be meaningless here.
                    for key in pairs(row.cfg) do
                        if key ~= "type" then row.cfg[key] = nil end
                    end
                    row.cfg.type = value

                    local definition = NS.GetConditionDefinition(value)
                    for _, field in ipairs(definition and definition.fields or {}) do
                        if field.default ~= nil then
                            row.cfg[field.key] = field.default
                        end
                    end

                    NotifyChanged()
                    panel:RefreshRules()
                end,
            })
            -- Indented past the enable checkbox.
            row.typeDropdown:SetPoint("TOPLEFT", ROW_LEFT_INSET, -8)
        end

        row.cfg = cfg
        row.typeDropdown:RefreshLabel()

        do
            local t = NS.GetTheme()
            local enabled = cfg.enabled ~= false

            if enabled then
                row.rail:SetColorTexture(Unpack(t.accent, 0.80))
                row.enableToggle:SetBackdropColor(Unpack(t.accent, 0.25))
                row.enableToggle:SetBackdropBorderColor(Unpack(t.accentBright, 0.95))
                row.enableFill:SetColorTexture(Unpack(t.accentBright))
                row.enableFill:Show()
            else
                row.rail:SetColorTexture(1, 1, 1, 0.10)
                row.enableToggle:SetBackdropColor(0, 0, 0, 0.35)
                row.enableToggle:SetBackdropBorderColor(Unpack(t.toggleOffBorder))
                row.enableFill:Hide()
            end

            -- A disabled rule is dimmed whole, so a card that isn't in play
            -- reads as inactive at a glance rather than needing its checkbox
            -- inspected.
            row:SetAlpha(enabled and 1 or 0.45)
        end

        -- The condition's own description, as a tooltip on its type dropdown.
        -- Saves spending a line of the card on help text that is only needed
        -- while you are deciding which rule you want.
        local currentDefinition = NS.GetConditionDefinition(cfg.type)
        if currentDefinition then
            NS.AttachTooltip(row.typeDropdown,
                currentDefinition.name or cfg.type,
                currentDefinition.description)
        end

        row.removeButton:SetScript("OnClick", function()
            local note = GetNote()
            if not note or not note.conditions then return end
            table.remove(note.conditions, index)
            NotifyChanged()
            panel:RefreshRules()
        end)

        -- Field layout.
        --
        -- A field may declare `inline` to put its label beside the control
        -- instead of above it, `width` to size the control, and `sameLine` to
        -- continue the current row rather than starting a new one. Stacking
        -- every label above its own full-width control made a rule with five
        -- fields tall enough to need scrolling on its own.
        local definition = NS.GetConditionDefinition(cfg.type)

        local LINE_GAP = 6
        local LABEL_GAP = 8
        local START_X = 10

        local cursorX = START_X
        local lineTop = -34
        local lineHeight = 0

        for _, field in ipairs(definition and definition.fields or {}) do
            local builder = FieldBuilders[field.type]

            -- A field can hide until its prerequisites are answered, so a rule
            -- opens as a single question and grows as you fill it in rather
            -- than presenting every input at once.
            local visible = (not field.visibleWhen) or field.visibleWhen(cfg)

            if builder and visible then
                if not field.sameLine and lineHeight > 0 then
                    lineTop = lineTop - lineHeight - LINE_GAP
                    cursorX = START_X
                    lineHeight = 0
                end

                local controlWidth = field.width or FIELD_WIDTH
                local label = NS.CreateFieldLabel(row, field.label or field.key)
                label:SetJustifyH("LEFT")
                table.insert(row.fieldWidgets, label)

                local widget, height = builder(row, field, cfg, controlWidth)
                table.insert(row.fieldWidgets, widget)

                local usedWidth, usedHeight

                if field.inline then
                    local labelWidth = field.labelWidth or 70
                    label:SetWidth(labelWidth)
                    -- Right-aligned so every control in the card starts on the
                    -- same vertical edge regardless of how long its label is.
                    label:SetJustifyH("RIGHT")
                    -- Nudged down so the label sits on the control's centre
                    -- line rather than its top edge.
                    label:SetPoint("TOPLEFT", cursorX, lineTop - 6)
                    widget:SetPoint("TOPLEFT", cursorX + labelWidth + LABEL_GAP, lineTop)

                    usedWidth = labelWidth + LABEL_GAP + controlWidth
                    usedHeight = height
                else
                    label:SetPoint("TOPLEFT", cursorX, lineTop)
                    widget:SetPoint("TOPLEFT", cursorX, lineTop - 16)

                    usedWidth = controlWidth
                    usedHeight = 16 + height
                end

                cursorX = cursorX + usedWidth + LINE_GAP
                lineHeight = math.max(lineHeight, usedHeight)
            end
        end

        local innerY = lineTop - lineHeight - LINE_GAP
        local rowHeight = math.max(46, math.abs(innerY) + 4)
        row:SetHeight(rowHeight)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yOffset)
        row:Show()

        return rowHeight
    end

    function panel:RefreshRules()
        local note = GetNote()

        for _, row in ipairs(self.ruleRows) do
            row:Hide()
        end

        if not note then
            self.subtitle:SetText("No note selected")
            self.emptyText:Hide()
            self.listPanel:Hide()
            self.rulesCountPill:Hide()
            self.rulesCount:Hide()
            self:RefreshStatus()
            return
        end

        local title = NS.SafeTrim(note.title or "")
        self.subtitle:SetText(title ~= "" and title or "(untitled)")

        local conditions = note.conditions or {}
        local yOffset = 0

        for index, cfg in ipairs(conditions) do
            local height = BuildRuleRow(index, cfg, yOffset)
            yOffset = yOffset - height - ROW_SPACING
        end

        local contentHeight = math.max(1, math.abs(yOffset))
        self.content:SetHeight(contentHeight)

        local hasRules = #conditions > 0

        -- With nothing in it the list panel is hidden rather than drawn empty.
        -- A bordered box containing nothing reads as something that failed to
        -- load; the explanation below takes its place.
        self.listPanel:SetShown(hasRules)
        self.emptyText:SetShown(not hasRules)
        self.rulesCountPill:SetShown(hasRules)
        self.rulesCount:SetShown(hasRules)

        if hasRules then
            self.rulesCount:SetText(tostring(#conditions))
        end

        self.modeDropdown:RefreshLabel()

        -- Before the height is worked out, not after: the band sizes itself
        -- here to fit its breakdown, and everything below the list is measured
        -- from whatever it ends up being.
        self:RefreshStatus()

        -- Size the window to what it actually holds. A fixed height left a
        -- large gap between a single rule and the Add button, which read as
        -- something failing to load rather than as deliberate space.
        local chromeBelow = self.statusBand:GetHeight() + ADD_BUTTON_BLOCK

        local wanted
        if hasRules then
            wanted = CHROME_ABOVE + chromeBelow + math.max(contentHeight, 40)
        else
            -- Just the lines of explanation, so the window is not mostly empty
            -- space when a note has no rules.
            wanted = CHROME_ABOVE + chromeBelow
        end

        self:SetHeight(math.max(MIN_PANEL_HEIGHT, math.min(MAX_PANEL_HEIGHT, wanted)))
    end

    NS.DockDialog(panel, "RIGHT")

    NS.MakeEscapeClosable(panel)

    -- The status line reflects live game state, so it is re-checked while the
    -- window is open rather than only when something is edited.
    panel:HookScript("OnShow", function(self)
        self.statusTimer = 0
    end)

    panel:SetScript("OnUpdate", function(self, elapsed)
        self.statusTimer = (self.statusTimer or 0) + elapsed
        if self.statusTimer < 0.25 then return end
        self.statusTimer = 0
        self:RefreshStatus()
    end)

    rulesFrame = panel
    return panel
end

function NS.ToggleRules()
    if not NS.selectedNote then return end

    local panel = CreateRulesFrame()

    if panel:IsShown() then
        panel:Hide()
    else
        panel:Dock()
        panel:RefreshRules()
        panel:Show()
    end
end

-- Called when the manager's selection changes, so an open window follows it
-- rather than continuing to edit a note you have navigated away from.
function NS.RefreshRulesWindow()
    if rulesFrame and rulesFrame:IsShown() then
        rulesFrame:RefreshRules()
    end
end
