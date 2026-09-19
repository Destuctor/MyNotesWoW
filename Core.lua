local addonName = ...
local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS
NS.addonName = addonName
NS.selectedNote = NS.selectedNote or nil
NS.selectedScope = NS.selectedScope or "account"
NS.managerFrame = NS.managerFrame or nil
NS.DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"

-- ============================================================================
-- SAVED VARIABLES
-- ============================================================================

MyNotesDB = MyNotesDB or {}
MyNotesCharDB = MyNotesCharDB or {}

local visibleNoteFrames = {}

local DEFAULT_FONT_PATH = "Fonts\\ARIALN.TTF"

-- Markup rendering lives in Markup.lua.
local RenderDisplayText = NS.RenderMarkup


local defaults = {
    notes = {},
    settings = {
        nextID = 1,
        manager = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
            width = 1120,
            height = 660,
        },
        newNoteScope = "account",
        searchText = "",
        -- Folder names, in the order they appear in the list. Kept as an
        -- explicit list rather than derived from the notes so that an empty
        -- folder survives emptying it - otherwise the folder you just cleared
        -- out vanishes while you are still using it.
        folders = {},
        collapsedFolders = {},
        theme = "midnight",
        noteFont = "Arial Narrow",
        -- Seeds new notes on each axis independently, matching the per-note
        -- controls. Existing notes keep whatever they already have.
        defaultNoteBackground = "none",
        defaultNoteEdge = "none",
        noteEntrance = true,
        minimap = {
            hide = false,
            minimapPos = 220,
        },
    },
}

local function CopyDefaults(src, dst)
    if type(src) ~= "table" or type(dst) ~= "table" then return end

    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

SafeTrim = function(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function InitDB()
    CopyDefaults(defaults, MyNotesDB)
    CopyDefaults(defaults, MyNotesCharDB)
end

-- ============================================================================
-- DATABASE HELPERS
-- ============================================================================

local function GetDB(scope)
    return scope == "character" and MyNotesCharDB or MyNotesDB
end

local function GetNotes(scope)
    return GetDB(scope).notes
end

local function NormalizeNote(note)
    if not note then return end

    if note.visible == nil then note.visible = false end
    if note.locked == nil then note.locked = false end
    if note.width == nil then note.width = 280 end
    if note.height == nil then note.height = 200 end
    if note.point == nil then note.point = "CENTER" end
    if note.relativePoint == nil then note.relativePoint = "CENTER" end
    if note.x == nil then note.x = 0 end
    if note.y == nil then note.y = 0 end
    if note.fontSize == nil then note.fontSize = 14 end
    if note.pinned == nil then note.pinned = false end
    if note.bgAlpha == nil then
        note.bgAlpha = 100
    elseif note.bgAlpha <= 1.01 then
        note.bgAlpha = math.floor((note.bgAlpha * 100) + 0.5)
    end
end

-- ============================================================================
-- MIGRATIONS
--
-- Bumped whenever stored note data needs a one-time fix-up. Each note DB
-- records the version it was last migrated to, so a migration runs once and
-- never again, and a fresh install skips them entirely.
-- ============================================================================

local DB_VERSION = 8

local function MigrateNote(note, fromVersion)
    -- v8: the per-note text shadow setting was removed. Every note now draws
    -- the soft shadow that was always the default, and the outline setting is
    -- the control for text that needs more help than that. A stored value is
    -- dead weight, and leaving it would have an exported note carry a field
    -- the importing side no longer understands.
    if fromVersion < 8 then
        note.shadow = nil
    end

    -- v7: the single `style` field split into independent `background` and
    -- `edge` axes. The mapping is exact in both directions, so every note keeps
    -- the appearance it had - "rail" was only ever an edge, "shade" and "card"
    -- only ever fills.
    if fromVersion < 7 then
        local style = note.style

        if style == "rail" then
            note.edge = "rail"
        elseif style == "shade" or style == "card" then
            note.background = style
        end

        note.style = nil
    end

    -- v6: automatic checklist clearing was removed. Checkboxes themselves stay
    -- - only the daily/weekly auto-untick is gone, so boxes are cleared by
    -- clicking them like everything else. Both fields are now dead weight.
    if fromVersion < 6 then
        note.checkReset = nil
        note.checkResetAt = nil
    end

    -- v5: reminder mode and the "After login" rule were both removed.
    --
    -- The dismissal flag is the one that matters. It used to suppress a note
    -- that was otherwise showing, and nothing reads it any more - so a note
    -- left dismissed would simply never come back, with no switch anywhere to
    -- explain why. Clearing it hands the note back to its own visible switch.
    if fromVersion < 5 then
        note.reminder = nil
        note.dismissed = nil

        local conditions = note.conditions
        if conditions then
            for index = #conditions, 1, -1 do
                if conditions[index].type == "login" then
                    table.remove(conditions, index)
                end
            end
        end
    end

    -- v4: the Mythic+ affix rule was removed. An unknown rule type is ignored
    -- by the evaluator, so a note carrying one would still display - but the
    -- rules window would list a row naming a condition that no longer exists,
    -- which reads as damage rather than as a removal. Dropping them leaves the
    -- note behaving exactly as before, since an ignored rule was already no
    -- filter at all.
    if fromVersion < 4 then
        local conditions = note.conditions
        if conditions then
            for index = #conditions, 1, -1 do
                if conditions[index].type == "affix" then
                    table.remove(conditions, index)
                end
            end
        end
    end

    -- v3: an encounter rule's timing became a list of windows so one rule can
    -- show a note at several points in a fight. The reader tolerates the old
    -- single pair, but export only carries declared fields - so a rule left
    -- unmigrated would silently lose its timing when shared.
    if fromVersion < 3 then
        for _, cfg in ipairs(note.conditions or {}) do
            if cfg.type == "encounter" and not cfg.windows
                and (cfg.fromSeconds or cfg.toSeconds) then

                cfg.windows = { { from = cfg.fromSeconds, to = cfg.toSeconds } }
                cfg.fromSeconds = nil
                cfg.toSeconds = nil
            end
        end
    end

    -- v2: display titles, per-note click-through and minimising were all
    -- removed. Their fields are now dead weight in saved data.
    if fromVersion < 2 then
        note.showTitle = nil
        note.clickThrough = nil
        note.minimized = nil

        -- Opacity used to be clamped up to a floor of 0.75 when drawing, so any
        -- value below 75 rendered identically to 75 and the stored number was
        -- effectively ignored. Now the slider is honoured literally, which would
        -- silently make those notes far fainter than the user ever saw them.
        -- Raising them to 75 preserves exactly how they already looked.
        if (note.bgAlpha or 100) < 75 then
            note.bgAlpha = 75
        end
    end
end

local function MigrateDB(db)
    if type(db) ~= "table" or type(db.notes) ~= "table" then return end

    local fromVersion = db.dbVersion or 1
    if fromVersion >= DB_VERSION then
        db.dbVersion = DB_VERSION
        return
    end

    for _, note in ipairs(db.notes) do
        MigrateNote(note, fromVersion)
    end

    -- v8: the side panels dock to the manager instead of floating, so the
    -- positions each of them used to save are dead weight. Left in place they
    -- would be restored by nothing and simply sit in SavedVariables forever.
    if fromVersion < 8 and type(db.settings) == "table" then
        db.settings.helpPanel = nil
        db.settings.rulesWindow = nil
        db.settings.settingsWindow = nil
        db.settings.shareWindow = nil
    end

    db.dbVersion = DB_VERSION
end

local function MigrateAll()
    MigrateDB(MyNotesDB)
    MigrateDB(MyNotesCharDB)
end

local function NormalizeAllNotes()
    for _, note in ipairs(MyNotesDB.notes) do
        NormalizeNote(note)
    end
    for _, note in ipairs(MyNotesCharDB.notes) do
        NormalizeNote(note)
    end
end

local function CreateNewNote(scope)
    local db = GetDB(scope)
    local id = db.settings.nextID

    local note = {
        id = id,
        title = "",
        body = "",
        visible = false,
        locked = false,
        width = 280,
        height = 200,
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        fontSize = 14,
        pinned = false,
        bgAlpha = 100,
        -- nil on each axis means the untouched default. Seeded from the global
        -- settings so the choice is made once rather than per note.
        background = (db.settings.defaultNoteBackground ~= "none")
            and db.settings.defaultNoteBackground or nil,
        edge = (db.settings.defaultNoteEdge ~= "none")
            and db.settings.defaultNoteEdge or nil,
    }

    table.insert(db.notes, note)
    db.settings.nextID = id + 1

    return note
end

local function DuplicateNote(scope, sourceNote)
    if not sourceNote then return nil end

    local db = GetDB(scope)
    local id = db.settings.nextID

    local baseTitle = SafeTrim(sourceNote.title or "")
    if baseTitle == "" then
        baseTitle = "(untitled)"
    end

    local newNote = {
        id = id,
        title = baseTitle .. " (Copy)",
        body = sourceNote.body or "",
        visible = false,
        locked = sourceNote.locked and true or false,
        width = sourceNote.width or 280,
        height = sourceNote.height or 200,
        point = "CENTER",
        relativePoint = "CENTER",
        x = (sourceNote.x or 0) + 30,
        y = (sourceNote.y or 0) - 30,
        fontSize = sourceNote.fontSize or 14,
        pinned = sourceNote.pinned and true or false,
        bgAlpha = sourceNote.bgAlpha or 100,
    }

    table.insert(db.notes, newNote)
    db.settings.nextID = id + 1

    return newNote
end

local function DeleteNote(scope, noteID)
    local notes = GetNotes(scope)

    for i = #notes, 1, -1 do
        if notes[i].id == noteID then
            table.remove(notes, i)
            return true
        end
    end

    return false
end

local function GetAllNotesForList()
    local combined = {}

    for _, note in ipairs(MyNotesDB.notes) do
        table.insert(combined, { scope = "account", note = note })
    end

    for _, note in ipairs(MyNotesCharDB.notes) do
        table.insert(combined, { scope = "character", note = note })
    end

    table.sort(combined, function(a, b)
        if (a.note.pinned and true or false) ~= (b.note.pinned and true or false) then
            return a.note.pinned and true or false
        end

        local aTitle = (a.note.title or ""):lower()
        local bTitle = (b.note.title or ""):lower()
        if aTitle == bTitle then
            return a.note.id < b.note.id
        end
        return aTitle < bTitle
    end)

    return combined
end

-- ============================================================================
-- FLOATING NOTE HELPERS
-- ============================================================================

local function MakeFloatingKey(scope, note)
    return scope .. ":" .. tostring(note.id)
end

local function SaveFloatingFramePosition(frame, note)
    if not frame or not note then return end

    local point, _, relativePoint, x, y = frame:GetPoint()
    note.point = point
    note.relativePoint = relativePoint
    note.x = x
    note.y = y

    note.width = math.max(180, math.floor(frame:GetWidth() + 0.5))
    note.height = math.max(120, math.floor(frame:GetHeight() + 0.5))
end

-- Displayed notes are body text only. A note's title exists purely to organise
-- and find it in the manager, and is never drawn on screen.

local function EstimateEditBoxContentHeight(editBox)
    if not editBox then return 0 end

    local text = editBox:GetText() or ""
    local _, fontHeight = editBox:GetFont()
    fontHeight = tonumber(fontHeight) or 14

    local lineCount = 1
    for _ in text:gmatch("\n") do
        lineCount = lineCount + 1
    end

    local minHeight = fontHeight + 8
    return math.max(minHeight, (lineCount * (fontHeight + 2)) + 8)
end

local function UpdateFloatingBodyLayout(frame, note)
    if not frame or not note then return end

    local width = math.max(180, frame:GetWidth() or 180)
    local height = math.max(120, frame:GetHeight() or 120)
    -- No title bar to leave room for, so the body starts at the top inset.
    local bodyTop = -10
    local bodyBottom = 10
    local textWidth = width - 20
    local availableHeight = math.max(24, height + bodyTop - bodyBottom)

    local targetScroll = frame.isEditing and frame.editScroll or frame.bodyScroll
    if targetScroll then
        targetScroll:ClearAllPoints()
        targetScroll:SetPoint("TOPLEFT", 10, bodyTop)
        targetScroll:SetPoint("BOTTOMRIGHT", -10, bodyBottom)
    end

    frame.body:SetWidth(math.max(120, textWidth))
    frame.bodyContainer:SetWidth(math.max(120, textWidth))

    -- Asserted here as well as in ApplyTheme. Alignment is a function of the
    -- width set immediately above, and the live-text pass re-runs this layout
    -- without going through ApplyTheme at all.
    frame.body:SetJustifyH(note.align or "LEFT")

    local textHeight = frame.body:GetStringHeight() or 0
    frame.bodyContainer:SetHeight(math.max(textHeight + 8, availableHeight))
    frame.bodyScroll:SetVerticalScroll(0)

    if frame.bodyEdit then
        frame.bodyEdit:SetWidth(math.max(120, textWidth))
        local editHeight = EstimateEditBoxContentHeight(frame.bodyEdit)
        frame.editContainer:SetWidth(math.max(120, textWidth))
        frame.editContainer:SetHeight(math.max(editHeight + 12, availableHeight))
        frame.editScroll:SetVerticalScroll(0)
    end
end

-- ---------------------------------------------------------------------------
-- Note styles
--
-- Plain is the default and is exactly what it always was: text on the screen,
-- nothing behind it. That is the addon's whole character and none of this
-- changes it - a note with no style set renders byte-for-byte as before.
--
-- The other three exist because bare text loses over snow, lava and a white
-- boss room. Rail and Shade add legibility without reintroducing a box; Card
-- is there for when a box is genuinely wanted.
-- ---------------------------------------------------------------------------

-- Two independent axes rather than one list of styles.
--
-- Background and Edge are unrelated decisions - a card may or may not want an
-- accent border, a rail is just as useful over bare terrain as over a shade.
-- As a single list they multiply: every new fill would need a variant against
-- every existing edge. Split, nine combinations come from two controls, and
-- adding a fourth edge later costs one entry rather than three.
NS.NOTE_BACKGROUNDS = { "none", "shade", "card" }

NS.NOTE_BACKGROUND_LABELS = {
    none  = "None",
    shade = "Shade",
    card  = "Card",
}

NS.NOTE_EDGES = { "none", "rail", "border" }

NS.NOTE_EDGE_LABELS = {
    none   = "None",
    rail   = "Accent rail",
    border = "Accent border",
}

NS.NOTE_OUTLINES = { "none", "OUTLINE", "THICKOUTLINE" }

NS.NOTE_OUTLINE_LABELS = {
    none          = "None",
    OUTLINE       = "Outline",
    THICKOUTLINE  = "Thick outline",
}

-- Held down, this hands a locked click-through note back to the mouse so it can
-- be moved, resized or opened for editing without unlocking it first.
NS.NOTE_UNLOCK_MODIFIERS = { "ALT", "CTRL", "SHIFT" }

NS.NOTE_UNLOCK_MODIFIER_LABELS = {
    ALT   = "Alt",
    CTRL  = "Ctrl",
    SHIFT = "Shift",
}

function NS.IsUnlockModifierDown()
    local settings = MyNotesDB and MyNotesDB.settings
    local key = (settings and settings.unlockModifier) or "ALT"

    if key == "CTRL" then return IsControlKeyDown() and true or false end
    if key == "SHIFT" then return IsShiftKeyDown() and true or false end

    return IsAltKeyDown() and true or false
end

-- Whether a note will take interaction right now.
--
-- This is spelled once because it was previously spelled five different ways -
-- in the drag handler, the resize handle, the lock pass, the edit button and
-- EnterEditMode - and adding the modifier caught only three of them, leaving a
-- note that handed back the mouse and then refused to open for editing.
local function IsNoteInteractive(note)
    if not note then return false end
    return (not note.locked) or NS.IsUnlockModifierDown()
end

NS.IsNoteInteractive = IsNoteInteractive

NS.NOTE_ALIGNMENTS = { "LEFT", "CENTER", "RIGHT" }

NS.NOTE_ALIGNMENT_LABELS = {
    LEFT   = "Left",
    CENTER = "Centre",
    RIGHT  = "Right",
}

-- Which side of the note the Rail edge runs along. A rail is a reading cue as
-- much as decoration, so where it sits depends on where the note sits: one
-- parked against the right of the screen reads better railed on its right.
NS.NOTE_RAIL_SIDES = { "LEFT", "RIGHT", "TOP", "BOTTOM" }

NS.NOTE_RAIL_SIDE_LABELS = {
    LEFT   = "Left",
    RIGHT  = "Right",
    TOP    = "Top",
    BOTTOM = "Bottom",
}

-- The note's base text colour. "class" is resolved live so it follows whoever
-- is logged in rather than being baked in when the note was written.
local CLASS_TEXT_COLOR = "class"
NS.NOTE_TEXT_CLASS_COLOR = CLASS_TEXT_COLOR

local function ResolvePlayerClassColor()
    local _, class = UnitClass("player")
    if not class then return nil end

    local color = (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class))
        or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])

    if color and color.r then
        return color.r, color.g, color.b
    end

    return nil
end

-- White unless the note says otherwise, which is what every note rendered as
-- before this existed.
local function ResolveNoteTextColor(note)
    local choice = note.textColor
    if not choice then return 1, 1, 1 end

    if choice == CLASS_TEXT_COLOR then
        local r, g, b = ResolvePlayerClassColor()
        if r then return r, g, b end
        return 1, 1, 1
    end

    local hex = NS.MARKUP_COLOR_NAMES and NS.MARKUP_COLOR_NAMES[choice]
    if not hex then return 1, 1, 1 end

    return tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255,
           tonumber(hex:sub(7, 8), 16) / 255
end

NS.ResolveNoteTextColor = ResolveNoteTextColor

-- A note's accent: one of the markup colour names if it has one, otherwise the
-- theme's own. Names rather than raw hex, so the picker is a short list and
-- there is still only one place colours are defined.
local function ResolveNoteAccent(note, theme)
    local names = NS.MARKUP_COLOR_NAMES
    local hex = note.accent and names and names[note.accent]

    if hex then
        return tonumber(hex:sub(3, 4), 16) / 255,
               tonumber(hex:sub(5, 6), 16) / 255,
               tonumber(hex:sub(7, 8), 16) / 255
    end

    if theme and theme.accent then
        return theme.accent[1], theme.accent[2], theme.accent[3]
    end

    return 1, 1, 1
end

NS.ResolveNoteAccent = ResolveNoteAccent

-- Note that this takes no alpha.
--
-- Opacity used to scale the background and edge along with the text, on the
-- reasoning that a faded note should fade whole. In practice the control is
-- labelled Text Opacity and people reach for it to dim wordy notes without
-- losing the frame that makes them readable - so it now does exactly what it
-- says, and the surfaces keep their own fixed strength.
local function ApplyNoteStyle(frame, note, theme)
    if not frame.styleShade then return end

    local background = note.background or "none"
    local edge = note.edge or "none"

    -- Edit mode paints its own surface so the caret is visible; anything else
    -- drawn underneath would just fight it.
    if frame.isEditing then
        background, edge = "none", "none"
    end

    frame.styleShade:Hide()
    frame.styleRail:Hide()
    frame.styleLip:Hide()

    for _, edgeTexture in pairs(frame.styleBorder or {}) do
        edgeTexture:Hide()
    end

    if frame.SetBackdropColor then
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end

    -- ---- background ----------------------------------------------------
    if background == "card" then
        local bg = (theme and theme.panelBg) or { 0.065, 0.075, 0.100 }
        frame:SetBackdropColor(bg[1], bg[2], bg[3], 0.88)

        -- The 1px lip along the top edge. It does more to lift the card off the
        -- world behind it than a heavier border would.
        frame.styleLip:SetColorTexture(1, 1, 1, 0.05)
        frame.styleLip:Show()

    elseif background == "shade" then
        -- Dark behind the first lines, gone by the bottom, so the note still
        -- reads as text lying on the world rather than as a panel sitting on
        -- top of it.
        frame.styleShade:SetColorTexture(1, 1, 1, 1)

        if frame.styleShade.SetGradient and CreateColor then
            frame.styleShade:SetGradient("VERTICAL",
                CreateColor(0, 0, 0, 0),
                CreateColor(0, 0, 0, 0.60))
        else
            -- SetGradient's signature changed in 10.0. If this client does not
            -- have it, a flat wash is a worse Shade but still a working one.
            frame.styleShade:SetColorTexture(0, 0, 0, 0.40)
        end

        frame.styleShade:Show()
    end

    -- ---- edge ----------------------------------------------------------
    --
    -- Applied after the background and independently of it: the border colours
    -- the same backdrop edge a Card would otherwise leave neutral, so Card with
    -- an accent border is one combination rather than a fourth style.
    if edge == "rail" then
        local r, g, b = ResolveNoteAccent(note, theme)
        local thickness = Clamp(note.borderSize or 2, 1, 8)
        local side = note.railSide or "LEFT"

        frame.styleRail:SetColorTexture(r, g, b, 0.90)
        frame.styleRail:ClearAllPoints()

        -- Anchored to two corners rather than given a length, so the rail keeps
        -- spanning the note as it is resized or as its text reflows.
        if side == "RIGHT" then
            frame.styleRail:SetPoint("TOPRIGHT", 0, 0)
            frame.styleRail:SetPoint("BOTTOMRIGHT", 0, 0)
            frame.styleRail:SetWidth(thickness)
        elseif side == "TOP" then
            frame.styleRail:SetPoint("TOPLEFT", 0, 0)
            frame.styleRail:SetPoint("TOPRIGHT", 0, 0)
            frame.styleRail:SetHeight(thickness)
        elseif side == "BOTTOM" then
            frame.styleRail:SetPoint("BOTTOMLEFT", 0, 0)
            frame.styleRail:SetPoint("BOTTOMRIGHT", 0, 0)
            frame.styleRail:SetHeight(thickness)
        else
            frame.styleRail:SetPoint("TOPLEFT", 0, 0)
            frame.styleRail:SetPoint("BOTTOMLEFT", 0, 0)
            frame.styleRail:SetWidth(thickness)
        end

        frame.styleRail:Show()

    elseif edge == "border" then
        local r, g, b = ResolveNoteAccent(note, theme)
        local thickness = Clamp(note.borderSize or 1, 1, 8)

        for side, edgeTexture in pairs(frame.styleBorder) do
            edgeTexture:SetColorTexture(r, g, b, 0.85)

            if side == "TOP" or side == "BOTTOM" then
                edgeTexture:SetHeight(thickness)
            else
                edgeTexture:SetWidth(thickness)
            end

            edgeTexture:Show()
        end

    elseif background == "card" then
        -- A card with no accent edge still needs its own quiet border, or it
        -- has no boundary against a dark background.
        local border = (theme and theme.panelBorder) or { 0.160, 0.190, 0.250 }
        frame:SetBackdropBorderColor(border[1], border[2], border[3], 0.90)
    end
end

local function ApplyTheme(frame, note)
    -- Opacity drives the text itself across the full range: at 0 the note is
    -- genuinely invisible. There is no floor - the note has no background, so
    -- text alpha is the only thing opacity can mean.
    local alpha = Clamp(note.bgAlpha or 100, 0, 100) / 100

    -- The frame stays fully transparent; only edit mode paints a surface
    -- (see UpdateFloatingEditSurface), since a caret on bare terrain is
    -- impossible to see.
    if frame.SetBackdropColor then
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end

    local tr, tg, tb = ResolveNoteTextColor(note)
    frame.body:SetTextColor(tr, tg, tb, alpha)

    -- Centre is what most raid callouts want - "SPREAD" reads better centred
    -- than pinned to whichever edge the note happens to sit against.
    frame.body:SetJustifyH(note.align or "LEFT")
    -- Resolved per note: an override if it has one, otherwise the global note
    -- font. Applied through ApplyFont because the path may come from another
    -- addon via LibSharedMedia - if it fails to load, SetFont would leave the
    -- body with no font and every later SetText on it would error.
    --
    -- The outline is a font flag, not a background. It is usually the better
    -- answer to "I cannot read this over snow": it costs no screen space and
    -- keeps the note reading as text on the world.
    local outline = note.outline
    if outline == "none" then outline = nil end

    NS.ApplyFont(frame.body, NS.GetNoteFontPath(note), note.fontSize or 14, outline)

    -- The shadow is what keeps unbacked text legible over bright terrain, so
    -- it tracks the text's own alpha rather than staying at a fixed strength.
    -- It used to be a per-note choice, but nobody ever turned it off and the
    -- two alternatives to "soft" were an outline done worse. The outline
    -- setting above is the real control for "I cannot read this over snow".
    frame.body:SetShadowOffset(1, -1)
    frame.body:SetShadowColor(0, 0, 0, alpha * 0.9)

    -- The note's own chrome follows the palette too. It is fetched at call time
    -- rather than captured up top because Core.lua loads before Theme.lua.
    -- Without this the edit surface and hover bar stayed a fixed blue-black
    -- while the rest of the addon changed colour.
    local theme = NS.GetTheme and NS.GetTheme()
    if theme then
        local Unpack = NS.Unpack
        if frame.editSurface then
            frame.editSurface:SetColorTexture(Unpack(theme.windowBg, 0.94))
        end
        if frame.controlsBg then
            frame.controlsBg:SetColorTexture(Unpack(theme.windowBg, 0.88))
        end
    end

    -- Last, so it can paint over the transparent backdrop this function just
    -- reset. Opacity is passed through: a note faded to 40% fades its
    -- background with it, rather than sitting behind ghost-faint text.
    ApplyNoteStyle(frame, note, theme)
end

local function UpdateFloatingFramePin(frame, note)
    if not frame or not note then return end

    if note.pinned then
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(false)
    end
end

local function UpdateFloatingFrameClickThrough(frame, note)
    if not frame or not note then return end

    -- Locking a note is what makes it click-through. There was previously a
    -- separate opt-in for this, but it only ever took effect on a locked note,
    -- and a locked note you can't interact with has no reason to keep swallowing
    -- clicks meant for the world behind it.
    --
    -- Holding the unlock modifier hands the note back for as long as the key is
    -- down. Click-through is all or nothing in the widget API - a frame either
    -- takes the mouse or it does not - so "click through, but still editable"
    -- has to be a moment you ask for rather than a state the note is in.
    local clickThroughActive = not frame.isEditing and not IsNoteInteractive(note)

    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(not clickThroughActive)
    end
    frame:EnableMouse(not clickThroughActive)

    -- Click-through means the note must not intercept anything at all, so the
    -- hover chrome is taken out of play entirely rather than just faded.
    if frame.chrome then
        frame.chromeSuppressed = clickThroughActive and true or false
        if clickThroughActive then
            -- Guarded because this runs on every refresh, including the first
            -- one, where the fade groups may not have been built yet.
            if frame.ResetChrome then
                frame:ResetChrome()
            else
                frame.chrome:SetAlpha(0)
                frame.chrome:Hide()
            end
        end
    end

    if frame.bodyScroll then
        if frame.bodyScroll.SetMouseClickEnabled then
            frame.bodyScroll:SetMouseClickEnabled(not clickThroughActive)
        end
        frame.bodyScroll:EnableMouse(not clickThroughActive)
    end

    if frame.editScroll then
        if frame.editScroll.SetMouseClickEnabled then
            frame.editScroll:SetMouseClickEnabled(not clickThroughActive)
        end
        frame.editScroll:EnableMouse(not clickThroughActive)
    end

    if frame.resizeHandle then
        if frame.resizeHandle.SetMouseClickEnabled then
            frame.resizeHandle:SetMouseClickEnabled(not clickThroughActive)
        end
        frame.resizeHandle:EnableMouse(not clickThroughActive)
    end
end

-- Edit mode is the one time a note gets a surface behind it: a caret and a
-- selection highlight are unreadable against bare terrain.
local function UpdateFloatingEditSurface(frame)
    if not frame or not frame.editSurface then return end

    if frame.isEditing then
        frame.editSurface:Show()
    else
        frame.editSurface:Hide()
    end
end

local function UpdateFloatingFrameLock(frame, note)
    if not frame or not note then return end

    -- Held, the unlock modifier makes a locked note behave as an unlocked one
    -- for as long as the key is down: movable, resizable, and editable. Without
    -- this the note would pass clicks through but still refuse to be edited,
    -- which is only half of what click-through-with-edit means.
    if not IsNoteInteractive(note) then
        frame:SetMovable(false)
        frame.resizeHandle:Hide()

        -- Left enabled while editing, or releasing the modifier would disable
        -- the Save button on an editor that is still open.
        if frame.editButton and not frame.isEditing then
            frame.editButton:Disable()
        end

        -- Locking a note that is open for editing saves and closes it. An edit
        -- session that was started by holding the modifier is exempt: it is
        -- locked by definition, and releasing the key mid-sentence would
        -- otherwise close the editor out from under whoever is typing.
        if frame.isEditing and not frame.editUnlocked then
            frame:ExitEditMode(true)
        end
    else
        frame:SetMovable(true)
        if not frame.isEditing then
            frame.resizeHandle:Show()
        end
        if frame.editButton then
            frame.editButton:Enable()
        end
    end

    if frame.editButton then
        frame.editButton:SetText(frame.isEditing and "Save" or "Edit")
    end
end

local function UpdateFloatingFrame(frame, note)
    if not frame or not note then return end

    -- While stacking, position is decided by the layout pass rather than by
    -- the note's own saved point. That point is deliberately left untouched so
    -- turning stacking off restores it.
    if not (NS.IsStacking and NS.IsStacking()) then
        frame:ClearAllPoints()
        frame:SetPoint(
            note.point or "CENTER",
            UIParent,
            note.relativePoint or "CENTER",
            note.x or 0,
            note.y or 0
        )
    end

    -- Cached so the live-text pass can tell whether a re-render actually
    -- changed anything before touching the FontString.
    local renderedBody = RenderDisplayText(note.body or "")
    frame.lastRenderedBody = renderedBody
    frame.body:SetText(renderedBody)

    if frame.bodyEdit then
        frame.bodyEdit:SetText(note.body or "")
        -- The editor shows raw markup at a fixed, readable size rather than at
        -- the note's display size, which may be 36pt or nearly transparent.
        frame.bodyEdit:SetFont(DEFAULT_FONT_PATH, 14, "")
    end

    frame:SetSize(note.width or 280, note.height or 200)

    if frame.isEditing then
        frame.bodyScroll:Hide()
        if frame.editScroll then frame.editScroll:Show() end
    else
        frame.bodyScroll:Show()
        if frame.editScroll then frame.editScroll:Hide() end
    end

    if IsNoteInteractive(note) and not frame.isEditing then
        frame.resizeHandle:Show()
    end

    UpdateFloatingEditSurface(frame)

    UpdateFloatingBodyLayout(frame, note)
    ApplyTheme(frame, note)
    UpdateFloatingFramePin(frame, note)
    UpdateFloatingFrameLock(frame, note)
    UpdateFloatingFrameClickThrough(frame, note)
end

local function HideFloatingNote(scope, note)
    if not note then return end

    local key = MakeFloatingKey(scope, note)
    local frame = visibleNoteFrames[key]
    if frame then
        frame:Hide()
    end

    note.visible = false
end

local function RefreshManagerIfShown()
    if NS.managerFrame and NS.managerFrame:IsShown() and NS.managerFrame.RefreshNoteList then
        NS.managerFrame:RefreshNoteList()
    end
end

local function CreateFloatingNoteFrame(scope, note)
    local key = MakeFloatingKey(scope, note)
    if visibleNoteFrames[key] then
        return visibleNoteFrames[key]
    end

    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    -- Kept on the frame so passes that iterate visibleNoteFrames can reach the
    -- note without having to rebuild the mapping.
    frame.note = note
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(180, 120)
    frame:EnableMouse(true)
    frame:SetFrameStrata("MEDIUM")
    frame.isEditing = false
    -- Real texture files rather than nil, so the Card style has something to
    -- paint. Both colours start fully transparent, which is byte-for-byte the
    -- old behaviour: a plain note still has nothing behind it.
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false,
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)

    -- Style layers, created once and shown per style. All hidden for Plain.
    frame.styleShade = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    frame.styleShade:SetAllPoints()
    frame.styleShade:Hide()

    frame.styleRail = frame:CreateTexture(nil, "ARTWORK")
    frame.styleRail:SetPoint("TOPLEFT", 0, 0)
    frame.styleRail:SetPoint("BOTTOMLEFT", 0, 0)
    frame.styleRail:SetWidth(2)
    frame.styleRail:Hide()

    frame.styleLip = frame:CreateTexture(nil, "ARTWORK")
    frame.styleLip:SetPoint("TOPLEFT", 1, -1)
    frame.styleLip:SetPoint("TOPRIGHT", -1, -1)
    frame.styleLip:SetHeight(1)
    frame.styleLip:Hide()

    -- The accent border is four textures rather than the backdrop's own edge.
    -- edgeSize is baked into the backdrop table, so a thickness slider driving
    -- it would mean rebuilding and re-applying the whole backdrop on every
    -- refresh. Four edges give any thickness for a SetWidth call.
    frame.styleBorder = {}

    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = frame:CreateTexture(nil, "OVERLAY")
        edge:Hide()
        frame.styleBorder[side] = edge
    end

    frame.styleBorder.TOP:SetPoint("TOPLEFT")
    frame.styleBorder.TOP:SetPoint("TOPRIGHT")
    frame.styleBorder.BOTTOM:SetPoint("BOTTOMLEFT")
    frame.styleBorder.BOTTOM:SetPoint("BOTTOMRIGHT")
    frame.styleBorder.LEFT:SetPoint("TOPLEFT")
    frame.styleBorder.LEFT:SetPoint("BOTTOMLEFT")
    frame.styleBorder.RIGHT:SetPoint("TOPRIGHT")
    frame.styleBorder.RIGHT:SetPoint("BOTTOMRIGHT")

    -- Edit-mode surface. Hidden while the note is merely being read, so a
    -- displayed note is nothing but text on screen; shown while editing,
    -- because a caret and selection highlight are invisible over bare terrain.
    frame.editSurface = frame:CreateTexture(nil, "BACKGROUND")
    frame.editSurface:SetAllPoints()
    frame.editSurface:SetColorTexture(0.03, 0.035, 0.045, 0.92)
    frame.editSurface:Hide()

    -- With no title bar, the whole note is the drag handle. The scroll frames
    -- sit on top and would otherwise swallow the drag, so they forward it too.
    local function AttachDrag(widget)
        widget:RegisterForDrag("LeftButton")
        widget:SetScript("OnDragStart", function()
            if not IsNoteInteractive(note) or frame.isEditing then return end
            frame:StartMoving()
        end)
        widget:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()

            -- Stacked notes have no individual position to save; dragging one
            -- repositions the whole column instead.
            if NS.IsStacking and NS.IsStacking() then
                NS.SaveStackAnchorFromFrame(frame)
            else
                SaveFloatingFramePosition(frame, note)
            end
        end)
    end
    frame.AttachDrag = AttachDrag
    AttachDrag(frame)

    -- All of the note's chrome lives in one container so it can be faded and
    -- hidden as a unit. The container deliberately never enables the mouse
    -- itself - it spans the whole note, so taking the mouse would swallow the
    -- drags and wheel scrolling meant for the body underneath. Only its child
    -- buttons are interactive, and hiding the container is what stops them
    -- catching clicks while they're invisible.
    frame.chrome = CreateFrame("Frame", nil, frame)
    frame.chrome:SetAllPoints()
    frame.chrome:SetFrameLevel(frame:GetFrameLevel() + 10)
    frame.chrome:SetAlpha(0)
    frame.chrome:Hide()

    -- Kept inside the note's own bounds rather than floating above it: the
    -- hover test is "is the pointer over the note", so controls outside that
    -- rect would create a dead zone that fades them out as you reach for them.
    frame.controls = CreateFrame("Frame", nil, frame.chrome)
    frame.controls:SetPoint("TOPRIGHT", -2, -2)
    frame.controls:SetSize(70, 20)

    frame.controlsBg = frame.controls:CreateTexture(nil, "BACKGROUND")
    frame.controlsBg:SetAllPoints()
    frame.controlsBg:SetColorTexture(0.03, 0.035, 0.045, 0.85)

    frame.editButton = CreateFrame("Button", nil, frame.controls, "UIPanelButtonTemplate")
    frame.editButton:SetSize(44, 18)
    frame.editButton:SetPoint("LEFT", 1, 0)
    frame.editButton:SetText("Edit")

    frame.closeButton = CreateFrame("Button", nil, frame.controls, "UIPanelCloseButton")
    frame.closeButton:SetSize(20, 20)
    frame.closeButton:SetPoint("RIGHT", 0, 0)
    frame.closeButton:SetScript("OnClick", function()
        if frame.isEditing then
            frame:ExitEditMode(true)
        end

        HideFloatingNote(scope, note)

        RefreshManagerIfShown()
    end)

    -- Fade the chrome in while the pointer is over the note, and hold it open
    -- while editing so Save stays reachable.
    --
    -- The hover test is still polled rather than driven by OnEnter/OnLeave: the
    -- body scroll frame covers the whole note, so a leave fires the moment the
    -- pointer crosses onto it. What the poll no longer does is the fade itself.
    -- It only notices the state change and hands over to an animation group,
    -- which the client drives, which eases, and which costs nothing once it has
    -- finished - where the old lerp did arithmetic and a SetAlpha on every
    -- frame for as long as the note existed.
    local CHROME_FADE = 0.16

    frame.chromeShown = false

    frame.chromeFadeIn = frame.chrome:CreateAnimationGroup()
    local fadeInAnim = frame.chromeFadeIn:CreateAnimation("Alpha")
    fadeInAnim:SetDuration(CHROME_FADE)
    fadeInAnim:SetFromAlpha(0)
    fadeInAnim:SetToAlpha(1)
    -- Arriving decelerates, leaving accelerates. Linear reads as mechanical.
    fadeInAnim:SetSmoothing("OUT")

    frame.chromeFadeOut = frame.chrome:CreateAnimationGroup()
    local fadeOutAnim = frame.chromeFadeOut:CreateAnimation("Alpha")
    fadeOutAnim:SetDuration(CHROME_FADE)
    fadeOutAnim:SetFromAlpha(1)
    fadeOutAnim:SetToAlpha(0)
    fadeOutAnim:SetSmoothing("IN")

    -- An Alpha animation reverts to the alpha it began from once the group
    -- ends, so the final value has to be committed by hand. Without this the
    -- chrome fades in and then snaps straight back out.
    frame.chromeFadeIn:SetScript("OnFinished", function()
        frame.chrome:SetAlpha(1)
    end)

    frame.chromeFadeOut:SetScript("OnFinished", function()
        frame.chrome:SetAlpha(0)
        -- Visibility, not alpha, is what governs whether the buttons can be
        -- clicked - a fully transparent button still takes the mouse.
        frame.chrome:Hide()
    end)

    local function SetChromeShown(shown)
        if shown == frame.chromeShown then return end
        frame.chromeShown = shown

        -- Read before stopping. Stop() restores the alpha its group started
        -- from, so asking afterwards gives the wrong number and reversing
        -- mid-fade would jump instead of turning around.
        local current = frame.chrome:GetAlpha()
        frame.chromeFadeIn:Stop()
        frame.chromeFadeOut:Stop()
        frame.chrome:SetAlpha(current)

        local target = shown and 1 or 0
        -- Scaled to the distance left, so turning around halfway takes half the
        -- time rather than the full duration from wherever it happens to be.
        local duration = math.max(0.04, CHROME_FADE * math.abs(target - current))

        if shown then
            frame.chrome:Show()
            fadeInAnim:SetFromAlpha(current)
            fadeInAnim:SetDuration(duration)
            frame.chromeFadeIn:Play()
        else
            fadeOutAnim:SetFromAlpha(current)
            fadeOutAnim:SetDuration(duration)
            frame.chromeFadeOut:Play()
        end
    end

    -- Entrance. A short rise and fade when a note comes into view, so a rule
    -- firing mid-pull reads as something arriving rather than as a pop.
    --
    -- Translation moves the frame without touching its anchors, which is
    -- exactly right here: the note is already where it belongs, and the
    -- animation only covers the last few pixels of getting there.
    frame.entrance = frame:CreateAnimationGroup()

    local rise = frame.entrance:CreateAnimation("Translation")
    rise:SetDuration(0.20)
    rise:SetOffset(0, -10)
    rise:SetSmoothing("OUT")
    rise:SetOrder(1)

    local appear = frame.entrance:CreateAnimation("Alpha")
    appear:SetDuration(0.20)
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetSmoothing("OUT")
    appear:SetOrder(1)

    frame.entrance:SetScript("OnFinished", function()
        -- Alpha animations revert to the value they began from, so the final
        -- one is committed by hand or the note fades in and vanishes again.
        frame:SetAlpha(1)
    end)

    function frame:PlayEntrance()
        if not MyNotesDB.settings or MyNotesDB.settings.noteEntrance == false then
            return
        end
        -- Never while editing: the caret jumping around mid-keystroke would be
        -- worse than no animation at all.
        if self.isEditing then return end

        self.entrance:Stop()
        self:SetAlpha(1)
        self.entrance:Play()
    end

    -- Exposed so the click-through path can put the chrome down without
    -- animating it.
    function frame:ResetChrome()
        self.chromeShown = false
        self.chromeFadeIn:Stop()
        self.chromeFadeOut:Stop()
        self.chrome:SetAlpha(0)
        self.chrome:Hide()
    end

    frame:SetScript("OnUpdate", function(self)
        -- Click-through notes suppress the chrome entirely; nothing to do.
        if self.chromeSuppressed then return end

        SetChromeShown((self.isEditing or self:IsMouseOver()) and true or false)
    end)

    frame.bodyScroll = CreateFrame("ScrollFrame", nil, frame)
    frame.bodyScroll:EnableMouse(true)
    frame.bodyScroll:EnableMouseWheel(true)
    frame.bodyScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        local maxScroll = math.max(0, (self:GetVerticalScrollRange() or 0))
        local nextScroll = current - (delta * 24)
        if nextScroll < 0 then
            nextScroll = 0
        elseif nextScroll > maxScroll then
            nextScroll = maxScroll
        end
        self:SetVerticalScroll(nextScroll)
    end)
    -- The body covers the whole note, so it has to pass drags through or the
    -- note could only be moved by its edges.
    AttachDrag(frame.bodyScroll)

    frame.bodyContainer = CreateFrame("Frame", nil, frame.bodyScroll)
    frame.bodyContainer:SetSize(1, 1)
    frame.bodyScroll:SetScrollChild(frame.bodyContainer)

    -- Hyperlinks are the only clickable region WoW offers inside a FontString,
    -- and both checkboxes and pasted game links ride on them. The scripts go on
    -- the containing frame rather than the FontString, which has no scripts of
    -- its own.
    --
    -- A locked note is click-through, so its links stop responding. That is the
    -- correct trade rather than a bug - a note you have deliberately made
    -- transparent to the mouse cannot also catch clicks - but it does mean a
    -- checklist wants to stay unlocked.
    if frame.bodyContainer.SetHyperlinksEnabled then
        frame.bodyContainer:SetHyperlinksEnabled(true)
    end

    frame.bodyContainer:SetScript("OnHyperlinkEnter", function(self, link)
        -- Our own links have nothing to show; the game's do.
        if link:sub(1, 8) == "mynotes:" then return end

        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        -- Guarded: a malformed link pasted from outside would otherwise throw
        -- from inside the tooltip rather than simply showing nothing.
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:Show()
    end)

    frame.bodyContainer:SetScript("OnHyperlinkLeave", function()
        GameTooltip:Hide()
    end)

    frame.bodyContainer:SetScript("OnHyperlinkClick", function(self, link, linkText, button)
        local index = link:match("^mynotes:check:(%d+)$")

        if index then
            NS.ToggleNoteCheckbox(scope, note, tonumber(index))
            return
        end

        -- Everything else is a real game link, so it gets the game's own
        -- behaviour: tooltip window, shift-click to chat, ctrl-click to dress
        -- up, and so on. Reimplementing any of that would only get it wrong.
        if SetItemRef then
            SetItemRef(link, linkText, button, self)
        end
    end)

    frame.body = frame.bodyContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.body:SetPoint("TOPLEFT", 0, 0)
    frame.body:SetWidth(220)
    frame.body:SetJustifyH("LEFT")
    frame.body:SetJustifyV("TOP")
    frame.body:SetSpacing(2)
    frame.body:SetFont(DEFAULT_FONT_PATH, note.fontSize or 14, "")
    frame.body:SetShadowOffset(1, -1)
    frame.body:SetShadowColor(0, 0, 0, 0.8)
    if frame.body.SetNonSpaceWrap then
        frame.body:SetNonSpaceWrap(true)
    end

    frame.bodyContainer:SetScript("OnSizeChanged", function(self, width)
        frame.body:SetWidth(math.max(120, width))
    end)

    frame.editScroll = CreateFrame("ScrollFrame", nil, frame)
    frame.editScroll:EnableMouseWheel(true)
    frame.editScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        local maxScroll = math.max(0, (self:GetVerticalScrollRange() or 0))
        local nextScroll = current - (delta * 24)
        if nextScroll < 0 then
            nextScroll = 0
        elseif nextScroll > maxScroll then
            nextScroll = maxScroll
        end
        self:SetVerticalScroll(nextScroll)
    end)
    frame.editScroll:Hide()

    frame.editContainer = CreateFrame("Frame", nil, frame.editScroll)
    frame.editContainer:SetSize(1, 1)
    frame.editScroll:SetScrollChild(frame.editContainer)

    frame.bodyEdit = CreateFrame("EditBox", nil, frame.editContainer)
    frame.bodyEdit:SetMultiLine(true)
    frame.bodyEdit:SetAutoFocus(false)
    frame.bodyEdit:SetFont(DEFAULT_FONT_PATH, 14, "")
    frame.bodyEdit:SetPoint("TOPLEFT", 0, 0)
    frame.bodyEdit:SetWidth(220)
    frame.bodyEdit:SetJustifyH("LEFT")
    frame.bodyEdit:SetJustifyV("TOP")
    frame.bodyEdit:SetScript("OnTextChanged", function(self)
        local width = self:GetWidth() or 220
        local height = EstimateEditBoxContentHeight(self)
        frame.editContainer:SetHeight(math.max(height + 12, frame:GetHeight() - 52))
        frame.editContainer:SetWidth(width)
        if frame.editScroll.UpdateScrollChildRect then
            frame.editScroll:UpdateScrollChildRect()
        end
    end)
    frame.bodyEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        frame:ExitEditMode(false)
    end)

    -- Parented to the chrome container so the grabber fades with the rest of
    -- the controls instead of sitting permanently in the corner of the note.
    frame.resizeHandle = CreateFrame("Button", nil, frame.chrome)
    frame.resizeHandle:SetSize(16, 16)
    frame.resizeHandle:SetPoint("BOTTOMRIGHT", -2, 2)
    frame.resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    frame.resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    frame.resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    frame.resizeHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsNoteInteractive(note) and not frame.isEditing then
            -- Notes are CENTER-anchored by default, which makes the dragged
            -- corner fight the cursor. Pin the top-left before sizing.
            if NS.AnchorForResize then
                NS.AnchorForResize(frame)
            end
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    frame.resizeHandle:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SaveFloatingFramePosition(frame, note)
        UpdateFloatingFrame(frame, note)
        RefreshManagerIfShown()
    end)

    -- In-place editing covers the body only. A note's title is manager-side
    -- organisation and is deliberately not reachable from the screen.
    function frame:ExitEditMode(shouldSave)
        if not self.isEditing then return end

        if shouldSave then
            note.body = self.bodyEdit:GetText() or ""
        end

        self.isEditing = false
        self.editUnlocked = nil
        self.bodyEdit:ClearFocus()
        UpdateFloatingFrame(self, note)

        if NS.selectedNote and NS.selectedNote.id == note.id and NS.selectedScope == scope and NS.managerFrame then
            if NS.managerFrame.bodyEdit then
                NS.managerFrame.bodyEdit:SetText(note.body or "")
            end
            if NS.managerFrame.RefreshNoteList then
                NS.managerFrame:RefreshNoteList()
            end
        else
            RefreshManagerIfShown()
        end
    end

    function frame:EnterEditMode()
        if not IsNoteInteractive(note) then return end

        self.isEditing = true

        -- Remembered rather than re-checked, because by the time it matters the
        -- key will have been released. See UpdateFloatingFrameLock.
        self.editUnlocked = note.locked and true or nil
        self.bodyEdit:SetText(note.body or "")
        UpdateFloatingFrame(self, note)
        self.bodyEdit:SetFocus()
        self.bodyEdit:SetCursorPosition(#(note.body or ""))
    end

    frame.editButton:SetScript("OnClick", function()
        -- Saving an open editor is always allowed: the modifier may well have
        -- been released since it was opened.
        if not frame.isEditing and not IsNoteInteractive(note) then return end
        if frame.isEditing then
            frame:ExitEditMode(true)
        else
            frame:EnterEditMode()
        end
    end)

    frame:SetScript("OnSizeChanged", function()
        UpdateFloatingBodyLayout(frame, note)
    end)

    visibleNoteFrames[key] = frame
    return frame
end


local function ShowFloatingNote(scope, note)
    if not note then return end

    local frame = CreateFloatingNoteFrame(scope, note)
    note.visible = true
    UpdateFloatingFrame(frame, note)
    frame:Show()
    if note.pinned then
        frame:Raise()
    end
end

-- Whether a note should currently be on screen.
--
-- `note.visible` is the user's master switch and is never written by the
-- condition engine; the rules are a second gate on top of it. A note with no
-- rules is governed entirely by the switch, which is how every note behaved
-- before conditions existed.
local function ShouldNoteBeShown(note)
    if not note or not note.visible then return false end

    -- A single global suppress, used by the "hide all notes" keybind. Kept
    -- separate from each note's own switch so clearing it restores exactly
    -- what was on screen before, without having to remember a list.
    if MyNotesDB.settings and MyNotesDB.settings.notesSuppressed then
        return false
    end

    if not NS.EvaluateConditions then return true end
    return NS.EvaluateConditions(note)
end

NS.ShouldNoteBeShown = ShouldNoteBeShown

local function RefreshFloatingNote(scope, note)
    if not note then return end

    local key = MakeFloatingKey(scope, note)
    local frame = visibleNoteFrames[key]

    if ShouldNoteBeShown(note) then
        local wasShown = frame and frame:IsShown()

        if not frame then
            frame = CreateFloatingNoteFrame(scope, note)
        end
        UpdateFloatingFrame(frame, note)
        frame:Show()

        -- Only on the transition into view, not on every refresh - a note that
        -- re-animated each time its text updated would be unusable. An
        -- encounter-timed note arriving with a small movement reads as
        -- deliberate where a hard pop reads as a glitch.
        if not wasShown and frame.PlayEntrance then
            frame:PlayEntrance()
        end

        if note.pinned then
            frame:Raise()
        end
    elseif frame then
        -- Only the frame is hidden. Touching note.visible here would turn a
        -- rule that happens not to match into a permanent switch-off.
        frame:Hide()
    end

    -- A note appearing or disappearing changes the column, so the rest of the
    -- stack closes up or makes room.
    if NS.ApplyStackLayout then
        NS.ApplyStackLayout()
    end
end

local function RestoreVisibleNotes()
    for _, note in ipairs(MyNotesDB.notes) do
        if ShouldNoteBeShown(note) then
            ShowFloatingNote("account", note)
        end
    end

    for _, note in ipairs(MyNotesCharDB.notes) do
        if ShouldNoteBeShown(note) then
            ShowFloatingNote("character", note)
        end
    end
end

-- Re-render every shown note.
--
-- Notes are first drawn at ADDON_LOADED, which is the coldest possible moment
-- for the client's spell and item caches. A "{spell:...}" or "{item:...}" tag
-- that couldn't resolve then would otherwise sit on screen as raw text until
-- something else happened to redraw the note.
local function RefreshVisibleNotes()
    for _, note in ipairs(MyNotesDB.notes) do
        if note.visible then
            RefreshFloatingNote("account", note)
        end
    end

    for _, note in ipairs(MyNotesCharDB.notes) do
        if note.visible then
            RefreshFloatingNote("character", note)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Folders
--
-- A folder is a name on a note and an entry in one list. Notes stay in the flat
-- store they have always been in - folders are a view over them, not a place
-- they live - so nothing about saving, loading or migration changes.
--
-- The list is account-wide rather than per-scope. A folder is how you think
-- about your notes, and "Raid" meaning one thing for account notes and another
-- for character notes would be a distinction nobody asked for.
-- ---------------------------------------------------------------------------

local UNFILED = "Unfiled"
NS.UNFILED_FOLDER = UNFILED

local function FolderSettings()
    local settings = MyNotesDB and MyNotesDB.settings
    if not settings then return nil end

    settings.folders = settings.folders or {}
    settings.collapsedFolders = settings.collapsedFolders or {}
    return settings
end

-- The stored list, plus any folder a note refers to that is missing from it.
-- Self-healing rather than trusting the list: an imported or hand-edited note
-- naming an unknown folder should appear somewhere sensible instead of
-- vanishing from a list that never mentions its folder.
function NS.GetFolders()
    local settings = FolderSettings()
    if not settings then return {} end

    local names, seen = {}, {}

    for _, name in ipairs(settings.folders) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    for _, scope in ipairs({ "account", "character" }) do
        local db = GetDB(scope)
        for _, note in ipairs((db and db.notes) or {}) do
            if note.folder and not seen[note.folder] then
                seen[note.folder] = true
                table.insert(names, note.folder)
                table.insert(settings.folders, note.folder)
            end
        end
    end

    return names
end

function NS.AddFolder(name)
    local settings = FolderSettings()
    if not settings then return nil end

    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == UNFILED then return nil end

    for _, existing in ipairs(settings.folders) do
        if existing == name then return name end
    end

    table.insert(settings.folders, name)
    return name
end

-- Removing a folder never removes notes. Anything inside it becomes unfiled,
-- which is recoverable; deleting the notes with it would not be.
function NS.DeleteFolder(name)
    local settings = FolderSettings()
    if not settings or not name then return end

    for index = #settings.folders, 1, -1 do
        if settings.folders[index] == name then
            table.remove(settings.folders, index)
        end
    end

    settings.collapsedFolders[name] = nil

    for _, scope in ipairs({ "account", "character" }) do
        local db = GetDB(scope)
        for _, note in ipairs((db and db.notes) or {}) do
            if note.folder == name then
                note.folder = nil
            end
        end
    end
end

function NS.IsFolderCollapsed(name)
    local settings = FolderSettings()
    return (settings and settings.collapsedFolders[name]) and true or false
end

function NS.ToggleFolderCollapsed(name)
    local settings = FolderSettings()
    if not settings or not name then return end

    settings.collapsedFolders[name] = (not settings.collapsedFolders[name]) or nil
end

-- ---------------------------------------------------------------------------
-- Checklists
--
-- Ticking edits the note's own text, so there is no separate state to keep in
-- step and an exported checklist carries its progress with it.
-- ---------------------------------------------------------------------------

function NS.ToggleNoteCheckbox(scope, note, index)
    if not note or not index or not NS.ToggleCheckboxInText then return end

    local updated = NS.ToggleCheckboxInText(note.body, index)
    -- nil means that box no longer exists, which happens if the note was
    -- edited between drawing and clicking. Doing nothing beats ticking a
    -- different line than the one under the cursor.
    if not updated then return end

    note.body = updated

    RefreshFloatingNote(scope, note)

    -- The manager may be showing this same note in its editor.
    local manager = NS.managerFrame
    if manager and manager:IsShown() then
        if NS.selectedNote == note and manager.bodyEdit then
            manager.bodyEdit:SetText(note.body)
            if manager.UpdatePreview then manager.UpdatePreview() end
        end
        if manager.RefreshNoteList then manager:RefreshNoteList() end
    end
end

-- Hide or reveal every note at once, without touching their individual
-- switches, so clearing the suppress restores exactly what was on screen.
-- Defined here rather than beside ShouldNoteBeShown because it calls
-- RefreshFloatingNote, which is declared further down.
local function ToggleAllNotes()
    local settings = MyNotesDB.settings
    if not settings then return end

    settings.notesSuppressed = not settings.notesSuppressed

    for _, note in ipairs(MyNotesDB.notes) do
        RefreshFloatingNote("account", note)
    end
    for _, note in ipairs(MyNotesCharDB.notes) do
        RefreshFloatingNote("character", note)
    end

    RefreshManagerIfShown()

    if settings.notesSuppressed then
        print("|cff00ff88MyNotes|r All notes hidden.")
    else
        print("|cff00ff88MyNotes|r Notes restored.")
    end
end

NS.ToggleAllNotes = ToggleAllNotes

-- ============================================================================
-- AUTO-STACK
--
-- With display rules, several notes can appear at once and land on top of each
-- other. Stacking lays every shown note out in a column from one anchor, so a
-- rule firing can't bury an existing note.
--
-- Each note's own saved position is left untouched while stacked, so turning
-- stacking off puts everything back where it was.
-- ============================================================================

local STACK_SPACING = 8

local function GetStackAnchor()
    local settings = MyNotesDB.settings
    local stack = settings and settings.stack

    if stack and stack.x and stack.y then
        return stack.x, stack.y
    end

    -- Default: upper-left-ish, in screen coordinates.
    local width = UIParent:GetWidth() or 1024
    local height = UIParent:GetHeight() or 768
    return width * 0.05, height * 0.75
end

local function IsStacking()
    local settings = MyNotesDB.settings
    return settings and settings.autoStack and true or false
end

NS.IsStacking = IsStacking

-- Ordered so the column is stable between refreshes. Pinned notes rise to the
-- top, matching the manager list, rather than the column reshuffling itself
-- every time a rule fires.
local function CollectStackedFrames()
    local ordered = {}

    for _, entry in ipairs(GetAllNotesForList()) do
        local key = MakeFloatingKey(entry.scope, entry.note)
        local frame = visibleNoteFrames[key]

        if frame and frame:IsShown() then
            table.insert(ordered, frame)
        end
    end

    return ordered
end

local function ApplyStackLayout()
    if not IsStacking() then return end

    local anchorX, anchorY = GetStackAnchor()
    local offset = 0

    for _, frame in ipairs(CollectStackedFrames()) do
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", anchorX, anchorY - offset)
        offset = offset + (frame:GetHeight() or 0) + STACK_SPACING
    end
end

NS.ApplyStackLayout = ApplyStackLayout

-- Dragging any note while stacked moves the whole column. The anchor is
-- derived by subtracting the dragged note's own offset within the stack, so
-- the column lands where you dropped that note rather than jumping.
local function SaveStackAnchorFromFrame(draggedFrame)
    local settings = MyNotesDB.settings
    if not settings then return end

    local offset = 0
    for _, frame in ipairs(CollectStackedFrames()) do
        if frame == draggedFrame then break end
        offset = offset + (frame:GetHeight() or 0) + STACK_SPACING
    end

    local left, top = draggedFrame:GetLeft(), draggedFrame:GetTop()
    if not left or not top then return end

    settings.stack = settings.stack or {}
    settings.stack.x = left
    settings.stack.y = top + offset

    ApplyStackLayout()
end

NS.SaveStackAnchorFromFrame = SaveStackAnchorFromFrame

function NS.SetStacking(enabled)
    local settings = MyNotesDB.settings
    if not settings then return end

    settings.autoStack = enabled and true or false

    if enabled then
        ApplyStackLayout()
    else
        -- Put every note back on its own remembered position.
        for _, note in ipairs(MyNotesDB.notes) do
            RefreshFloatingNote("account", note)
        end
        for _, note in ipairs(MyNotesCharDB.notes) do
            RefreshFloatingNote("character", note)
        end
    end
end

-- ============================================================================
-- LIVE TEXT
--
-- Notes containing tags like {target} or {group:2} have to be redrawn as the
-- world changes. Only notes that actually use such a tag are considered, and
-- the redraw is skipped unless the rendered text differs from what is already
-- on screen - so this costs nothing for an ordinary note and almost nothing
-- for a dynamic one that happens not to have changed.
-- ============================================================================

local dynamicWatcher = nil

local function RefreshDynamicNotes()
    for _, frame in pairs(visibleNoteFrames) do
        local note = frame.note

        if frame:IsShown() and note and NS.HasDynamicMarkup(note.body) then
            local rendered = RenderDisplayText(note.body or "")

            if rendered ~= frame.lastRenderedBody then
                frame.lastRenderedBody = rendered
                frame.body:SetText(rendered)
                UpdateFloatingBodyLayout(frame, note)
            end
        end
    end
end

-- Flips every locked note between click-through and interactive as the unlock
-- modifier goes down and up.
--
-- Event-driven rather than polled: MODIFIER_STATE_CHANGED fires exactly twice
-- per press, where an OnUpdate check would run forever to catch two moments.
local modifierWatcher = nil

function NS.StartUnlockModifierWatcher()
    if modifierWatcher then return end

    modifierWatcher = CreateFrame("Frame")
    modifierWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")

    modifierWatcher:SetScript("OnEvent", function()
        for _, frame in pairs(visibleNoteFrames) do
            -- A note already open for editing is left alone. Releasing the key
            -- would otherwise run the lock pass, which saves and closes the
            -- editor - losing whatever was being typed at that moment.
            if frame.note and frame.note.locked and not frame.isEditing then
                UpdateFloatingFrameLock(frame, frame.note)
                UpdateFloatingFrameClickThrough(frame, frame.note)
            end
        end
    end)
end

function NS.StartDynamicTextWatcher()
    if dynamicWatcher then return end

    dynamicWatcher = CreateFrame("Frame")

    -- The events cover the common cases immediately; the ticker catches
    -- everything else (a clock, a group member zoning) without needing to
    -- enumerate every event that could possibly matter.
    for _, event in ipairs({
        "PLAYER_TARGET_CHANGED",
        "PLAYER_FOCUS_CHANGED",
        "GROUP_ROSTER_UPDATE",
        "ZONE_CHANGED",
        "ZONE_CHANGED_NEW_AREA",
        "PLAYER_SPECIALIZATION_CHANGED",
        "PLAYER_ROLES_ASSIGNED",
        "PLAYER_ENTERING_WORLD",
    }) do
        dynamicWatcher:RegisterEvent(event)
    end

    dynamicWatcher:SetScript("OnEvent", RefreshDynamicNotes)

    local accumulated = 0
    dynamicWatcher:SetScript("OnUpdate", function(_, elapsed)
        accumulated = accumulated + elapsed
        if accumulated < 1 then return end
        accumulated = 0
        RefreshDynamicNotes()
    end)
end

NS.Clamp = Clamp
NS.SafeTrim = SafeTrim
NS.InitDB = InitDB
NS.MigrateAll = MigrateAll
NS.NormalizeAllNotes = NormalizeAllNotes
NS.CreateNewNote = CreateNewNote
NS.NormalizeNote = NormalizeNote
NS.DuplicateNote = DuplicateNote
NS.DeleteNote = DeleteNote
NS.GetAllNotesForList = GetAllNotesForList
NS.ShowFloatingNote = ShowFloatingNote
NS.HideFloatingNote = HideFloatingNote
NS.RefreshFloatingNote = RefreshFloatingNote
NS.RefreshManagerIfShown = RefreshManagerIfShown
NS.RestoreVisibleNotes = RestoreVisibleNotes
NS.RefreshVisibleNotes = RefreshVisibleNotes
