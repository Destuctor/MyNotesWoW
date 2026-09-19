local addonName = ...
local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

local DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"
local Clamp = NS.Clamp
local SafeTrim = NS.SafeTrim
local CreateNewNote = NS.CreateNewNote
local DuplicateNote = NS.DuplicateNote
local DeleteNote = NS.DeleteNote
local GetAllNotesForList = NS.GetAllNotesForList
local ShowFloatingNote = NS.ShowFloatingNote
local HideFloatingNote = NS.HideFloatingNote
local RefreshFloatingNote = NS.RefreshFloatingNote

-- Theme access. Colours come from the active palette (see Theme.lua) rather
-- than being written inline, so a palette switch re-skins everything.
local RegisterThemed = NS.RegisterThemed
local RegisterThemeCallback = NS.RegisterThemeCallback
local Unpack = NS.Unpack

-- Shared widget kit (Widgets.lua). These used to be locals in this file, which
-- is why the settings window couldn't reuse any of them.
local FLAT_BACKDROP = NS.FLAT_BACKDROP
local StylePanel = NS.StylePanel
local StyleDialog = NS.StyleDialog
local StyleActionButton = NS.StyleActionButton
local StyleEditBox = NS.StyleEditBox
local StyleFilterTab = NS.StyleFilterTab
local CreateSectionLabel = NS.CreateSectionLabel
local CreateFieldLabel = NS.CreateFieldLabel
local CreateToggleRow = NS.CreateToggleRow
local CreateFlatSlider = NS.CreateFlatSlider
local CreateFilterTab = NS.CreateFilterTab
local AttachTooltip = NS.AttachTooltip

-- Manager window sizing. The window is freely resizable between the minimum
-- and whatever fits on screen; the chosen size is remembered in MyNotesDB.
-- The minimum height is set by the settings column, which is the tallest
-- fixed-content panel. Moving the theme picker and minimap toggle out to the
-- settings window freed enough room to bring this back down.
-- Minimum grew with the markup toolbar and preview strip: at the old 620 the
-- body editor was squeezed to about seven lines, which is less room than the
-- thing those two features exist to help you write.
local MANAGER_MIN_WIDTH, MANAGER_MIN_HEIGHT = 880, 680
local MANAGER_DEFAULT_WIDTH, MANAGER_DEFAULT_HEIGHT = 1120, 700

-- Displayed-note font size range.
local NOTE_FONT_MIN, NOTE_FONT_MAX = 10, 36

-- Height of the per-note settings column. It holds fixed content, so it is
-- sized to fit rather than stretched: title, scope button, two toggles, a font
-- dropdown and two labelled sliders, plus padding.
-- Fallback height for the settings panel's scroll content, used only until the
-- first layout pass measures the real one. See UpdateSettingsContentHeight.
-- Ornament bars top and bottom. BAR_INSET is the gap to the window edge;
-- BAR_CAP_WIDTH is the fixed decorated end, which never stretches.
local BAR_HEIGHT = 56
local BAR_INSET = 14
local BAR_CAP_WIDTH = 64

local SETTINGS_CONTENT_HEIGHT = 560

-- Height of the live preview strip under the body editor. Fixed rather than
-- proportional: the preview draws at the note's real font size, so a size-36
-- note needs roughly this much to show two lines, and giving it a share of the
-- panel would shrink the editor itself on short windows.
local PREVIEW_HEIGHT = 84

-- The preview draws at the note's own size up to this cap. Beyond it the point
-- of the strip changes from "how big is this" to "can I read it at all", and
-- the note itself is the honest answer to the first question anyway.
local PREVIEW_MAX_FONT = 13

StaticPopupDialogs["MYNOTES_CONFIRM_DELETE"] = {
    text = "Delete note \"%s\"?\nThis cannot be undone.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if not data or not data.note then return end
        HideFloatingNote(data.scope, data.note)
        DeleteNote(data.scope, data.note.id)
        if data.onDeleted then
            data.onDeleted()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Deleting a folder never deletes notes. The wording says so explicitly rather
-- than asking "are you sure": the thing people want to know at this prompt is
-- what happens to what is inside, not whether they meant to click.
StaticPopupDialogs["MYNOTES_DELETE_FOLDER"] = {
    text = "Delete the folder \"%s\"?\n\nNotes inside it are kept and become Unfiled.",
    button1 = "Delete folder",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if not data or not data.folder or not NS.DeleteFolder then return end

        NS.DeleteFolder(data.folder)

        local manager = NS.managerFrame
        if manager then
            if manager.RefreshNoteList then manager:RefreshNoteList() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Creates a folder and files the selected note into it in one step. Asking for
-- the name and then making you pick it from a list would be two actions for
-- something that is obviously one.
StaticPopupDialogs["MYNOTES_NEW_FOLDER"] = {
    text = "Name the new folder:",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 40,
    OnShow = function(self)
        local box = self.editBox or (self.GetEditBox and self:GetEditBox())
        if box then
            box:SetText("")
            box:SetFocus()
        end
    end,
    OnCancel = function()
        -- Cleared so a cancelled create does not file the next note made
        -- through the New Folder button.
        if NS.managerFrame then NS.managerFrame.pendingFolderNote = nil end
    end,
    OnAccept = function(self)
        local box = self.editBox or (self.GetEditBox and self:GetEditBox())
        local name = box and box:GetText() or ""

        if not NS.AddFolder then return end

        local created = NS.AddFolder(name)
        if not created then return end

        local manager = NS.managerFrame

        -- A note set aside by the right-click menu is filed into the folder it
        -- just created. Reached from the New Folder button instead, there is no
        -- note in hand and the folder is simply created empty.
        if manager and manager.pendingFolderNote then
            manager.pendingFolderNote.folder = created
            manager.pendingFolderNote = nil
        end

        if manager and manager.RefreshNoteList then
            manager:RefreshNoteList()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["MYNOTES_NEW_FOLDER"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- A group heading inside a panel: an accent label with a hairline under it.
--
-- The note panel had grown to a dozen controls in one undifferentiated column,
-- where the only thing saying Font and Font Size belonged together was that
-- they happened to be adjacent. Same treatment the settings window gives its
-- own sections, so the two read alike.
local function CreateGroupHeading(panel, text, anchorTo, yOffset)
    local label = CreateSectionLabel(panel, text,
        "TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)

    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -5)
    rule:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    rule:SetHeight(1)

    RegisterThemed(rule, function(self, t)
        self:SetColorTexture(Unpack(t.accent, 0.25))
    end)

    label.rule = rule
    return label
end

local function CreateManagerFrame()
    local frame = CreateFrame("Frame", "MyNotesManagerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(
        math.max(MyNotesDB.settings.manager.width or MANAGER_DEFAULT_WIDTH, MANAGER_MIN_WIDTH),
        math.max(MyNotesDB.settings.manager.height or MANAGER_DEFAULT_HEIGHT, MANAGER_MIN_HEIGHT)
    )
    frame:SetPoint(
        MyNotesDB.settings.manager.point or "CENTER",
        UIParent,
        MyNotesDB.settings.manager.relativePoint or "CENTER",
        MyNotesDB.settings.manager.x or 0,
        MyNotesDB.settings.manager.y or 0
    )
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(MANAGER_MIN_WIDTH, MANAGER_MIN_HEIGHT)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    -- Escape closes the manager.
    tinsert(UISpecialFrames, "MyNotesManagerFrame")

    frame:SetBackdrop({
        bgFile = nil,
        edgeFile = nil,
        tile = false,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    RegisterThemed(frame, function(self, t)
        self:SetBackdropColor(Unpack(t.windowBg))
        self:SetBackdropBorderColor(Unpack(t.windowBorder))
    end)

    frame.bgGradient = frame:CreateTexture(nil, "BACKGROUND")
    frame.bgGradient:SetAllPoints()
    RegisterThemed(frame.bgGradient, function(self, t)
        self:SetColorTexture(Unpack(t.windowBg))
    end)

    frame.topBand = frame:CreateTexture(nil, "BORDER")
    frame.topBand:SetPoint("TOPLEFT", 1, -1)
    frame.topBand:SetPoint("TOPRIGHT", -1, -1)
    frame.topBand:SetHeight(72)
    RegisterThemed(frame.topBand, function(self, t)
        self:SetColorTexture(Unpack(t.headerBg))
    end)

    -- Ornamented bars top and bottom. Both stretch with the window: only the
    -- middle panel grows, so the end caps keep their proportions at any width.
    frame.topBar = NS.CreateOrnamentBar(frame, BAR_HEIGHT, BAR_CAP_WIDTH)
    frame.topBar:SetPoint("TOPLEFT", BAR_INSET, -BAR_INSET)
    frame.topBar:SetPoint("TOPRIGHT", -BAR_INSET, -BAR_INSET)

    frame.bottomBar = NS.CreateOrnamentBar(frame, BAR_HEIGHT, BAR_CAP_WIDTH)
    frame.bottomBar:SetPoint("BOTTOMLEFT", BAR_INSET, BAR_INSET)
    frame.bottomBar:SetPoint("BOTTOMRIGHT", -BAR_INSET, BAR_INSET)
    -- Mirrored, so the ornament points outward at both ends of the window
    -- rather than both bars pointing the same way.
    frame.bottomBar:SetFlipped(true)

    -- Header: the addon's own icon art next to a wordmark, rather than the
    -- text-in-a-coloured-pill placeholder this used to be.
    frame.headerIcon = frame.topBar:CreateTexture(nil, "OVERLAY")
    frame.headerIcon:SetSize(34, 34)
    frame.headerIcon:SetPoint("LEFT", frame.topBar, "LEFT", BAR_CAP_WIDTH - 6, 0)
    frame.headerIcon:SetTexture("Interface\\AddOns\\MyNotes\\Media\\icon.tga")

    -- Two-tone: the accent half is set with an inline colour escape, so both
    -- halves live in one FontString and the split follows the active palette.
    frame.wordmark = frame.topBar:CreateFontString(nil, "OVERLAY")
    frame.wordmark:SetFont(DEFAULT_FONT_PATH, 20, "")
    frame.wordmark:SetPoint("BOTTOMLEFT", frame.headerIcon, "RIGHT", 11, 1)
    RegisterThemed(frame.wordmark, function(self, t)
        self:SetTextColor(Unpack(t.textBright))
        self:SetText("My|c" .. NS.ColorToHex(t.accent) .. "Notes|r")
    end)

    local function SaveManagerRect(self)
        local point, _, relativePoint, x, y = self:GetPoint()
        MyNotesDB.settings.manager.point = point
        MyNotesDB.settings.manager.relativePoint = relativePoint
        MyNotesDB.settings.manager.x = x
        MyNotesDB.settings.manager.y = y
        MyNotesDB.settings.manager.width = math.floor(self:GetWidth() + 0.5)
        MyNotesDB.settings.manager.height = math.floor(self:GetHeight() + 0.5)
    end

    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveManagerRect(self)
    end)

    -- Exposed so a docked side panel can move the manager by its own title bar
    -- and still have the position stick. See NS.DockDialog.
    frame.SaveRect = SaveManagerRect

    frame.resizeGrip = CreateFrame("Button", nil, frame)
    frame.resizeGrip:SetSize(16, 16)
    -- Sat flush in the corner rather than inset. StartSizing snaps the corner
    -- to the cursor, so any gap between the grip and the true corner shows up
    -- as a jump the moment you press.
    frame.resizeGrip:SetPoint("BOTTOMRIGHT", -1, 1)
    -- Raised above the bars. The grip belongs to the window rather than to a
    -- bar, and a child frame's contents draw over its parent's whatever their
    -- layer - so without this the bottom bar sits on the grip and eats the drag.
    frame.resizeGrip:SetFrameLevel(frame.bottomBar:GetFrameLevel() + 5)
    frame.resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    frame.resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    frame.resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    frame.resizeGrip:SetAlpha(0.5)
    frame.resizeGrip:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
    frame.resizeGrip:SetScript("OnLeave", function(self) self:SetAlpha(0.5) end)
    frame.resizeGrip:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            NS.AnchorForResize(frame)
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    frame.resizeGrip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SaveManagerRect(frame)
    end)

    frame:Hide()

    local function CreateFooterButton(parent, text, width)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(width, 30)
        button:SetText(text)
        return button
    end

    frame.subtitle = frame.topBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", frame.wordmark, "BOTTOMLEFT", 1, -4)
    frame.subtitle:SetText("0 notes")
    RegisterThemed(frame.subtitle, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)

    local closeButton = CreateFrame("Button", nil, frame.topBar, "UIPanelCloseButton")
    closeButton:SetSize(24, 24)
    closeButton:SetPoint("RIGHT", frame.topBar, "RIGHT", -(BAR_CAP_WIDTH - 6), 0)
    NS.SoftenCloseButton(closeButton)

    -- Explicit, because UIPanelCloseButton's default action hides its PARENT.
    -- That was the window until this button moved into the bar; afterwards
    -- clicking it hid the bar instead, taking the header buttons with it and
    -- leaving the window open with no chrome.
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Read from the .toc so it can never disagree with the packaged version.
    frame.versionText = frame.bottomBar:CreateFontString(nil, "OVERLAY")
    frame.versionText:SetFont(DEFAULT_FONT_PATH, 11, "")
    RegisterThemed(frame.versionText, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    do
        local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local version = getMetadata and getMetadata(addonName, "Version")
        frame.versionText:SetText(version and ("v" .. version) or "")
    end

    frame.leftPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.leftPanel:SetPoint("TOPLEFT", frame.topBar, "BOTTOMLEFT", 10, -10)
    frame.leftPanel:SetPoint("BOTTOMLEFT", frame.bottomBar, "TOPLEFT", 10, 10)
    frame.leftPanel:SetWidth(292)
    StylePanel(frame.leftPanel, 0.94)

    frame.scopeFilter = "all"

    frame.searchBox = CreateFrame("EditBox", nil, frame.leftPanel, "InputBoxTemplate")
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetSize(260, 26)
    frame.searchBox:SetPoint("TOPLEFT", 16, -14)
    frame.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    StyleEditBox(frame.searchBox, 26)

    frame.searchPlaceholder = frame.leftPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.searchPlaceholder:SetPoint("LEFT", frame.searchBox, "LEFT", 2, 0)
    frame.searchPlaceholder:SetText("Search notes...")
    RegisterThemed(frame.searchPlaceholder, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    local function UpdateSearchPlaceholder()
        local hasText = (frame.searchBox:GetText() or "") ~= ""
        if hasText or frame.searchBox:HasFocus() then
            frame.searchPlaceholder:Hide()
        else
            frame.searchPlaceholder:Show()
        end
    end

    frame.searchBox:SetScript("OnTextChanged", function(self)
        MyNotesDB.settings.searchText = self:GetText() or ""
        UpdateSearchPlaceholder()
        frame:RefreshNoteList()
    end)
    frame.searchBox:SetScript("OnEditFocusGained", UpdateSearchPlaceholder)
    frame.searchBox:SetScript("OnEditFocusLost", UpdateSearchPlaceholder)

    frame.filterTabAll = CreateFilterTab(frame.leftPanel, "All", 84)
    frame.filterTabAll:SetPoint("TOPLEFT", 16, -52)

    frame.filterTabAccount = CreateFilterTab(frame.leftPanel, "Account", 84)
    frame.filterTabAccount:SetPoint("LEFT", frame.filterTabAll, "RIGHT", 4, 0)

    frame.filterTabCharacter = CreateFilterTab(frame.leftPanel, "Character", 84)
    frame.filterTabCharacter:SetPoint("LEFT", frame.filterTabAccount, "RIGHT", 4, 0)

    local function UpdateFilterTabs()
        StyleFilterTab(frame.filterTabAll, frame.scopeFilter == "all")
        StyleFilterTab(frame.filterTabAccount, frame.scopeFilter == "account")
        StyleFilterTab(frame.filterTabCharacter, frame.scopeFilter == "character")
    end

    frame.filterTabAll:SetScript("OnClick", function()
        frame.scopeFilter = "all"
        UpdateFilterTabs()
        frame:RefreshNoteList()
    end)
    frame.filterTabAccount:SetScript("OnClick", function()
        frame.scopeFilter = "account"
        UpdateFilterTabs()
        frame:RefreshNoteList()
    end)
    frame.filterTabCharacter:SetScript("OnClick", function()
        frame.scopeFilter = "character"
        UpdateFilterTabs()
        frame:RefreshNoteList()
    end)

    frame.UpdateFilterTabs = UpdateFilterTabs
    UpdateFilterTabs()


    -- Creating a folder is its own action, not a hidden entry at the bottom of
    -- a picker. Filing a note is done by dragging it onto a folder or by
    -- right-clicking it, so there is no folder dropdown here any more.
    frame.newFolderButton = CreateFrame("Button", nil, frame.leftPanel, "UIPanelButtonTemplate")
    frame.newFolderButton:SetText("+  New Folder")
    StyleActionButton(frame.newFolderButton, 260, 24, false)
    frame.newFolderButton:SetPoint("TOPLEFT", frame.filterTabAll, "BOTTOMLEFT", 0, -8)
    frame.newFolderButton:SetScript("OnClick", function()
        StaticPopup_Show("MYNOTES_NEW_FOLDER")
    end)

    AttachTooltip(frame.newFolderButton, "New Folder",
        "Creates an empty folder. Drag notes onto it, or right-click a note to file it.")

    frame.listDivider = frame.leftPanel:CreateTexture(nil, "ARTWORK")
    frame.listDivider:SetPoint("TOPLEFT", frame.newFolderButton, "BOTTOMLEFT", 0, -10)
    frame.listDivider:SetPoint("TOPRIGHT", frame.filterTabCharacter, "BOTTOMRIGHT", 0, -48)
    frame.listDivider:SetHeight(1)
    RegisterThemed(frame.listDivider, function(self, t)
        self:SetColorTexture(Unpack(t.divider))
    end)

    frame.listCountText = frame.leftPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.listCountText:SetPoint("TOPLEFT", frame.listDivider, "BOTTOMLEFT", 0, -8)
    frame.listCountText:SetText("")
    RegisterThemed(frame.listCountText, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)

    frame.emptyStateText = frame.leftPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.emptyStateText:SetPoint("TOPLEFT", frame.listCountText, "BOTTOMLEFT", 4, -60)
    frame.emptyStateText:SetPoint("RIGHT", frame.leftPanel, "RIGHT", -16, 0)
    frame.emptyStateText:SetJustifyH("CENTER")
    frame.emptyStateText:SetText("No notes yet.\nClick New below to create one.")
    RegisterThemed(frame.emptyStateText, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)
    frame.emptyStateText:Hide()

    frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame.leftPanel, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.listCountText, "BOTTOMLEFT", -4, -8)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)

    frame.scrollChild = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollChild:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollChild)
    NS.AutoHideScrollBar(frame.scrollFrame)
    NS.StyleScrollBar(frame.scrollFrame)

    frame.noteButtons = {}
    frame.folderHeaders = {}

    frame.editorPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.editorPanel:SetPoint("TOPLEFT", frame.leftPanel, "TOPRIGHT", 18, 0)
    frame.editorPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -294, BAR_INSET + BAR_HEIGHT + 10)
    StylePanel(frame.editorPanel, 0.92)

    frame.editorTitle = CreateSectionLabel(frame.editorPanel, "Editor", "TOPLEFT", frame.editorPanel, "TOPLEFT", 16, -14)

    frame.unsavedIndicator = frame.editorPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.unsavedIndicator:SetPoint("LEFT", frame.editorTitle, "RIGHT", 10, 0)
    frame.unsavedIndicator:SetText("Unsaved changes")
    RegisterThemed(frame.unsavedIndicator, function(self, t)
        self:SetTextColor(Unpack(t.warning))
    end)
    frame.unsavedIndicator:Hide()

    frame.titleLabel = CreateFieldLabel(frame.editorPanel, "Title")
    frame.titleLabel:SetPoint("TOPLEFT", 16, -44)

    frame.titleEdit = CreateFrame("EditBox", nil, frame.editorPanel, "InputBoxTemplate")
    frame.titleEdit:SetAutoFocus(false)
    frame.titleEdit:SetHeight(30)
    frame.titleEdit:SetPoint("TOPLEFT", frame.titleLabel, "BOTTOMLEFT", 0, -10)
    frame.titleEdit:SetPoint("TOPRIGHT", frame.editorPanel, "TOPRIGHT", -16, -68)
    StyleEditBox(frame.titleEdit, 30)

    frame.selectedInfo = frame.editorPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.selectedInfo:SetPoint("TOPLEFT", frame.titleEdit, "BOTTOMLEFT", 0, -12)
    frame.selectedInfo:SetPoint("RIGHT", -16, 0)
    frame.selectedInfo:SetJustifyH("LEFT")
    frame.selectedInfo:SetText("No note selected")
    RegisterThemed(frame.selectedInfo, function(self, t)
        self:SetTextColor(Unpack(t.textMuted))
    end)

    frame.bodyLabel = CreateFieldLabel(frame.editorPanel, "Body")
    frame.bodyLabel:SetPoint("TOPLEFT", frame.selectedInfo, "BOTTOMLEFT", 0, -16)

    -- ------------------------------------------------------------------
    -- Markup toolbar
    --
    -- The tag language is only as good as your memory of it, which is a poor
    -- thing to build a feature on. These are the sixteen tags worth a
    -- permanent button - eight colours and the eight raid markers. Everything
    -- else is one click away in the help window, whose rows now insert too.
    --
    -- The bar reflows instead of sitting in a fixed row: the editor panel is
    -- only about 250px wide at the manager's minimum size, and a fixed row
    -- would clip exactly the way the rules window's Remove button once did.
    -- ------------------------------------------------------------------

    local BAR_BUTTON_SIZE = 20
    local BAR_GAP = 3

    frame.markupBar = CreateFrame("Frame", nil, frame.editorPanel)
    frame.markupBar:SetPoint("TOPLEFT", frame.bodyLabel, "BOTTOMLEFT", 0, -8)
    frame.markupBar:SetHeight(BAR_BUTTON_SIZE)
    frame.markupButtons = {}

    frame.bodyBackdrop = CreateFrame("Frame", nil, frame.editorPanel, "BackdropTemplate")
    frame.bodyBackdrop:SetPoint("TOPLEFT", frame.markupBar, "BOTTOMLEFT", 0, -8)
    frame.bodyBackdrop:SetPoint("BOTTOMRIGHT", frame.editorPanel, "BOTTOMRIGHT", -16, PREVIEW_HEIGHT + 44)
    frame.bodyBackdrop:SetBackdrop(NS.INPUT_BACKDROP)
    RegisterThemed(frame.bodyBackdrop, function(self, t)
        self:SetBackdropColor(Unpack(t.inputBg))
        self:SetBackdropBorderColor(Unpack(t.inputBorder))
    end)

    frame.bodyScroll = CreateFrame("ScrollFrame", nil, frame.bodyBackdrop, "UIPanelScrollFrameTemplate")
    frame.bodyScroll:SetPoint("TOPLEFT", 10, -10)
    frame.bodyScroll:SetPoint("BOTTOMRIGHT", -30, 10)

    frame.bodyEdit = CreateFrame("EditBox", nil, frame.bodyScroll)
    frame.bodyEdit:SetMultiLine(true)
    frame.bodyEdit:SetFont(DEFAULT_FONT_PATH, 14, "")
    frame.bodyEdit:SetAutoFocus(false)
    frame.bodyEdit:SetWidth(520)
    frame.bodyEdit:SetJustifyH("LEFT")
    frame.bodyEdit:SetJustifyV("TOP")
    frame.bodyEdit:SetScript("OnTextChanged", function(self)
        self:GetParent():UpdateScrollChildRect()
    end)
    frame.bodyEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- Where the cursor was when focus went elsewhere. Clicking a toolbar button
    -- can take focus off the edit box, and without this the insert would land
    -- wherever refocusing happens to leave the cursor rather than where you
    -- were typing.
    frame.bodyEdit:HookScript("OnEditFocusLost", function(self)
        frame.bodyCursor = self:GetCursorPosition()
    end)
    frame.bodyScroll:SetScrollChild(frame.bodyEdit)
    NS.AutoHideScrollBar(frame.bodyScroll)
    NS.StyleScrollBar(frame.bodyScroll)

    -- Keep the edit box as wide as its scroll frame so the text reflows when
    -- the manager is resized, instead of sitting at a fixed width.
    frame.bodyScroll:SetScript("OnSizeChanged", function(self, width)
        frame.bodyEdit:SetWidth(math.max(200, width or 200))
    end)

    -- Forward declaration: the toolbar below has to flag unsaved changes, but
    -- MarkDirty is defined further down alongside the rest of the dirty
    -- tracking. A local referenced before its `local function` line compiles
    -- as a global lookup and is nil at runtime.
    local MarkDirty

    -- ------------------------------------------------------------------
    -- Live preview
    --
    -- An EditBox has exactly one string: what it shows is what it stores.
    -- Rendering markup inside it would mean replacing "[red]" with the raw
    -- colour escape, which destroys the source the player still has to edit,
    -- and every keystroke would need a SetText that resets the cursor. So the
    -- rendered result lives beside the source instead, drawn with the note's
    -- own font and size so it matches what will actually appear on screen.
    -- ------------------------------------------------------------------

    frame.previewLabel = CreateFieldLabel(frame.editorPanel, "Preview")
    frame.previewLabel:SetPoint("BOTTOMLEFT", frame.editorPanel, "BOTTOMLEFT", 16, PREVIEW_HEIGHT + 22)

    frame.previewBackdrop = CreateFrame("Frame", nil, frame.editorPanel, "BackdropTemplate")
    frame.previewBackdrop:SetPoint("BOTTOMLEFT", frame.editorPanel, "BOTTOMLEFT", 16, 16)
    frame.previewBackdrop:SetPoint("BOTTOMRIGHT", frame.editorPanel, "BOTTOMRIGHT", -16, 16)
    frame.previewBackdrop:SetHeight(PREVIEW_HEIGHT)
    frame.previewBackdrop:SetBackdrop(NS.INPUT_BACKDROP)
    RegisterThemed(frame.previewBackdrop, function(self, t)
        -- Dimmer than the editor's own box, so the eye reads this as a result
        -- rather than as a second thing to type into.
        local r, g, b = Unpack(t.inputBg)
        self:SetBackdropColor(r, g, b, 0.45)
        self:SetBackdropBorderColor(Unpack(t.panelBorder or t.inputBorder))
    end)

    -- Scrolled rather than clipped, so a long note can be read all the way
    -- through in a strip only a few lines tall. The FontString has to sit on a
    -- child frame rather than being the scroll child itself: a ScrollFrame
    -- scrolls frames, and the child's height is what gives it a scroll range.
    frame.previewScroll = CreateFrame("ScrollFrame", nil, frame.previewBackdrop, "UIPanelScrollFrameTemplate")
    frame.previewScroll:SetPoint("TOPLEFT", 10, -8)
    frame.previewScroll:SetPoint("BOTTOMRIGHT", -26, 8)

    frame.previewContent = CreateFrame("Frame", nil, frame.previewScroll)
    frame.previewContent:SetSize(1, 1)
    frame.previewScroll:SetScrollChild(frame.previewContent)

    frame.previewText = frame.previewContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.previewText:SetPoint("TOPLEFT", 0, 0)
    frame.previewText:SetJustifyH("LEFT")
    frame.previewText:SetJustifyV("TOP")
    frame.previewText:SetWordWrap(true)

    NS.AutoHideScrollBar(frame.previewScroll)
    NS.StyleScrollBar(frame.previewScroll)

    local function UpdatePreview()
        local body = frame.bodyEdit:GetText() or ""
        local note = NS.selectedNote

        -- Capped rather than mirrored. Showing a size-36 note at its true size
        -- fits about a line and a half, which tells you less about the note
        -- than three readable lines do. Font face, colours, icons and where
        -- the text wraps are all still exactly what you will get - only the
        -- scale is normalised.
        local size = math.min((note and note.fontSize) or 14, PREVIEW_MAX_FONT)

        NS.ApplyFont(frame.previewText,
            note and NS.GetNoteFontPath and NS.GetNoteFontPath(note) or nil,
            size)

        frame.previewText:SetText(body ~= "" and NS.RenderMarkup(body) or "")

        -- The child frame is sized to the wrapped text so the scroll range is
        -- right; without this the bar never appears no matter how long the note.
        frame.previewContent:SetHeight(math.max(1, frame.previewText:GetStringHeight() + 2))
        frame.previewScroll:UpdateScrollChildRect()
    end

    -- Keep the text wrapping to the visible width instead of a fixed one, the
    -- same way the body editor does when the manager is resized.
    frame.previewScroll:SetScript("OnSizeChanged", function(self, width)
        local usable = math.max(50, width or 50)
        frame.previewContent:SetWidth(usable)
        frame.previewText:SetWidth(usable)
        UpdatePreview()
    end)

    frame.UpdatePreview = UpdatePreview

    -- Hooked rather than set, so the existing handler keeping the scroll rect
    -- in step survives. Fires for SetText too, which keeps the preview honest
    -- when a note is loaded or a toolbar button rewrites the body.
    frame.bodyEdit:HookScript("OnTextChanged", UpdatePreview)

    -- ------------------------------------------------------------------
    -- Inserting markup at the cursor
    --
    -- WoW exposes no way to read an EditBox's selection. Insert() does
    -- replace it though, so the highlighted text can be recovered by diffing:
    -- drop a sentinel in, compare against what was there a moment before, and
    -- the difference is what was selected. Without this, "select a word and
    -- click red" could not work at all - only "insert an empty tag pair".
    -- ------------------------------------------------------------------

    local SELECTION_SENTINEL = "\1"

    local function WrapSelection(openTag, closeTag)
        local editBox = frame.bodyEdit
        local original = editBox:GetText() or ""

        -- Focus is restored only if it was actually lost, and the cursor is put
        -- back where it was first. SetFocus on a multi-line EditBox moves the
        -- cursor to the end, so calling it before Insert sent every insert to
        -- the bottom of the note. That went unnoticed while the toolbar only
        -- held colours: those replace a selection, which Insert does wherever
        -- the cursor happens to be. The checkbox, having nothing to replace,
        -- landed at the end every time.
        if not editBox:HasFocus() then
            editBox:SetFocus()
            if frame.bodyCursor then
                editBox:SetCursorPosition(frame.bodyCursor)
            end
        end

        editBox:Insert(SELECTION_SENTINEL)
        local marked = editBox:GetText() or ""

        -- Longest common prefix, then longest common suffix. Whatever sits
        -- between them in the original is what the sentinel displaced.
        local prefix = 0
        while prefix < #original and prefix < #marked
            and original:byte(prefix + 1) == marked:byte(prefix + 1) do
            prefix = prefix + 1
        end

        local suffix = 0
        while suffix < (#original - prefix) and suffix < (#marked - prefix)
            and original:byte(#original - suffix) == marked:byte(#marked - suffix) do
            suffix = suffix + 1
        end

        local selected = original:sub(prefix + 1, #original - suffix)
        local head = marked:sub(1, prefix)
        local tail = marked:sub(#marked - suffix + 1)

        editBox:SetText(head .. openTag .. selected .. closeTag .. tail)

        -- With text selected the cursor lands after it; with nothing selected
        -- it lands between the tags, ready to type into.
        editBox:SetCursorPosition(#head + #openTag + #selected)
        editBox:SetFocus()

        -- SetText fires OnTextChanged with isUserInput false, so the dirty
        -- flag has to be set by hand or the change looks already-saved.
        MarkDirty()
        UpdatePreview()
    end

    frame.WrapSelection = WrapSelection

    -- ------------------------------------------------------------------
    -- Toolbar buttons
    -- ------------------------------------------------------------------

    local function HexToRGB(hex)
        return tonumber(hex:sub(3, 4), 16) / 255,
               tonumber(hex:sub(5, 6), 16) / 255,
               tonumber(hex:sub(7, 8), 16) / 255
    end

    -- Order is by how often a raid note actually needs them, not alphabetical.
    local SWATCH_ORDER = { "red", "gold", "green", "blue", "cyan", "orange", "purple", "white" }

    local function CreateBarButton(width)
        local button = CreateFrame("Button", nil, frame.markupBar)
        button:SetSize(width or BAR_BUTTON_SIZE, BAR_BUTTON_SIZE)

        button.border = button:CreateTexture(nil, "BACKGROUND")
        button.border:SetAllPoints()

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints()
        button.highlight:SetColorTexture(1, 1, 1, 0.18)

        table.insert(frame.markupButtons, button)
        return button
    end

    for _, name in ipairs(SWATCH_ORDER) do
        local hex = NS.MARKUP_COLOR_NAMES and NS.MARKUP_COLOR_NAMES[name]
        if hex then
            local button = CreateBarButton()
            local r, g, b = HexToRGB(hex)

            button.border:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, 1)

            button.swatch = button:CreateTexture(nil, "ARTWORK")
            button.swatch:SetPoint("TOPLEFT", 2, -2)
            button.swatch:SetPoint("BOTTOMRIGHT", -2, 2)
            button.swatch:SetColorTexture(r, g, b, 1)

            button:SetScript("OnClick", function()
                WrapSelection("[" .. name .. "]", "[/]")
            end)

            AttachTooltip(button, name:gsub("^%l", string.upper),
                "Colours the selected text, or starts a coloured span at the cursor.\n\n[" .. name .. "]text[/]")
        end
    end

    for index = 1, 8 do
        local button = CreateBarButton()
        button.border:SetColorTexture(0, 0, 0, 0)

        button.marker = button:CreateTexture(nil, "ARTWORK")
        button.marker:SetPoint("TOPLEFT", 1, -1)
        button.marker:SetPoint("BOTTOMRIGHT", -1, 1)
        button.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. index)

        button:SetScript("OnClick", function()
            -- Markers stand alone rather than wrapping anything, so both tags
            -- go in on the left and the cursor ends up after them.
            WrapSelection("[rt" .. index .. "]", "")
        end)

        AttachTooltip(button, "Raid marker " .. index, "Inserts [rt" .. index .. "]")
    end

    -- Checkbox. Last on the bar, since it makes a line interactive rather than
    -- decorating one.
    do
        local button = CreateBarButton()
        button.border:SetColorTexture(0, 0, 0, 0)

        button.box = button:CreateTexture(nil, "ARTWORK")
        button.box:SetPoint("TOPLEFT", 1, -1)
        button.box:SetPoint("BOTTOMRIGHT", -1, 1)
        button.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")

        button:SetScript("OnClick", function()
            -- The trailing space is deliberate: a box is always followed by the
            -- thing it is about, and typing that space every time is friction
            -- for nothing.
            WrapSelection("[ ] ", "")
        end)

        AttachTooltip(button, "Checkbox",
            "Inserts [ ], a box you can tick on the note itself. How often it clears is set by the note's Clear checkboxes option.")
    end

    local function LayoutMarkupBar()
        local available = math.floor(frame.editorPanel:GetWidth() - 32)
        if available <= BAR_BUTTON_SIZE then return end

        frame.markupBar:SetWidth(available)

        local x, y, rows = 0, 0, 1

        for _, button in ipairs(frame.markupButtons) do
            local width = button:GetWidth()

            if x > 0 and (x + width) > available then
                x = 0
                y = y - (BAR_BUTTON_SIZE + BAR_GAP)
                rows = rows + 1
            end

            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", frame.markupBar, "TOPLEFT", x, y)
            x = x + width + BAR_GAP
        end

        frame.markupBar:SetHeight(rows * BAR_BUTTON_SIZE + (rows - 1) * BAR_GAP)
    end

    frame.LayoutMarkupBar = LayoutMarkupBar
    frame.editorPanel:SetScript("OnSizeChanged", LayoutMarkupBar)
    LayoutMarkupBar()

    frame.isDirty = false
    frame.suppressDirtyTracking = false

    local function UpdateUnsavedIndicator()
        if frame.isDirty then
            frame.unsavedIndicator:Show()
        else
            frame.unsavedIndicator:Hide()
        end
    end
    frame.UpdateUnsavedIndicator = UpdateUnsavedIndicator

    function MarkDirty()
        if frame.suppressDirtyTracking then return end
        if not frame.isDirty then
            frame.isDirty = true
            UpdateUnsavedIndicator()
        end
    end

    frame.titleEdit:SetScript("OnTextChanged", function(self, isUserInput)
        if isUserInput then
            MarkDirty()
        end
    end)

    frame.bodyEdit:HookScript("OnTextChanged", function(self, isUserInput)
        if isUserInput then
            MarkDirty()
        end
    end)

    -- Sized to its content rather than stretched to the window's full height.
    -- Once the theme picker and minimap toggle moved to the settings window,
    -- a full-height panel left a large void under the last slider, which reads
    -- as unfinished rather than as breathing room.
    frame.settingsPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    -- Bounded by the window on all four sides rather than given a fixed height.
    --
    -- It used to be a fixed height, which meant the window's
    -- height never constrained it: shrink the window and the panel carried on
    -- past the bottom edge, straight through the footer buttons. That height
    -- moved six times as controls were added, and would have needed moving
    -- again on the next one.
    frame.settingsPanel:SetPoint("TOPLEFT", frame.editorPanel, "TOPRIGHT", 18, 0)
    frame.settingsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, BAR_INSET + BAR_HEIGHT + 10)
    StylePanel(frame.settingsPanel, 0.94)

    -- The title stays put while the controls scroll under it, so the panel
    -- always says what it is.
    frame.settingsTitle = CreateSectionLabel(frame.settingsPanel, "Note", "TOPLEFT", frame.settingsPanel, "TOPLEFT", 16, -14)

    frame.settingsScroll = CreateFrame("ScrollFrame", nil, frame.settingsPanel, "UIPanelScrollFrameTemplate")
    frame.settingsScroll:SetPoint("TOPLEFT", frame.settingsTitle, "BOTTOMLEFT", -16, -8)
    frame.settingsScroll:SetPoint("BOTTOMRIGHT", frame.settingsPanel, "BOTTOMRIGHT", -22, 8)

    frame.settingsContent = CreateFrame("Frame", nil, frame.settingsScroll)
    frame.settingsContent:SetSize(1, SETTINGS_CONTENT_HEIGHT)
    frame.settingsScroll:SetScrollChild(frame.settingsContent)
    NS.AutoHideScrollBar(frame.settingsScroll)
    NS.StyleScrollBar(frame.settingsScroll)

    -- The content frame has no width of its own, so group-heading rules and
    -- anything anchored to its right edge need one handed to them.
    frame.settingsScroll:SetScript("OnSizeChanged", function(self, width)
        frame.settingsContent:SetWidth(math.max(120, width or 120))
        if frame.UpdateSettingsContentHeight then
            frame:UpdateSettingsContentHeight()
        end
    end)

    -- Measured from the last control rather than declared as a constant.
    --
    -- A constant is what caused the bug this replaces: it was bumped by hand
    -- six times as controls were added, and was wrong again by the seventh.
    -- Measuring means adding a control needs no number updated anywhere, and
    -- the scroll range is right by construction.
    function frame:UpdateSettingsContentHeight()
        local top = self.settingsContent:GetTop()
        local bottom = self.alignChoice and self.alignChoice:GetBottom()

        -- Both are nil until the frame has been laid out at least once, which
        -- is what the fallback constant covers.
        if not top or not bottom then return end

        self.settingsContent:SetHeight(math.max(1, (top - bottom) + 16))
    end

    -- Shown in place of the editor and note panels when nothing is selected.
    -- Spans the whole region those two occupy.
    frame.noSelectionHint = frame:CreateFontString(nil, "OVERLAY")
    frame.noSelectionHint:SetFont(DEFAULT_FONT_PATH, 14, "")
    frame.noSelectionHint:SetPoint("TOPLEFT", frame.leftPanel, "TOPRIGHT", 18, 0)
    frame.noSelectionHint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 72)
    frame.noSelectionHint:SetJustifyH("CENTER")
    frame.noSelectionHint:SetJustifyV("MIDDLE")
    frame.noSelectionHint:SetSpacing(6)
    frame.noSelectionHint:SetText("Select a note to edit it.\nClick it again to deselect.")
    RegisterThemed(frame.noSelectionHint, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)
    frame.noSelectionHint:Hide()

    frame.moveScopeButton = CreateFrame("Button", nil, frame.settingsContent, "UIPanelButtonTemplate")
    frame.moveScopeButton:SetSize(188, 26)
    frame.moveScopeButton:SetPoint("TOPLEFT", 16, -2)
    frame.moveScopeButton:SetText("Move Scope")
    StyleActionButton(frame.moveScopeButton, 188, 26, false)

    frame.rulesButton = CreateFrame("Button", nil, frame.settingsContent, "UIPanelButtonTemplate")
    frame.rulesButton:SetPoint("TOPLEFT", frame.moveScopeButton, "BOTTOMLEFT", 0, -8)
    frame.rulesButton:SetText("Display Rules")
    StyleActionButton(frame.rulesButton, 188, 26, false)
    AttachTooltip(frame.rulesButton, "Display Rules",
        "Choose when this note appears on screen - in combat, during a specific encounter, in a particular instance.")

    frame.rulesButton:SetScript("OnClick", function()
        if NS.ToggleRules then
            NS.ToggleRules()
        end
    end)

    frame.shareButton = CreateFrame("Button", nil, frame.settingsContent, "UIPanelButtonTemplate")
    frame.shareButton:SetPoint("TOPLEFT", frame.rulesButton, "BOTTOMLEFT", 0, -8)
    frame.shareButton:SetText("Share / Import")
    StyleActionButton(frame.shareButton, 188, 26, false)
    AttachTooltip(frame.shareButton, "Share / Import",
        "Copy this note as a string to paste anywhere, or paste one in to import it.")

    frame.shareButton:SetScript("OnClick", function()
        if NS.ToggleShare then
            NS.ToggleShare()
        end
    end)

    -- ------------------------------------------------------------------
    -- Behaviour: what the note does, rather than how it looks.
    -- ------------------------------------------------------------------

    frame.togglesLabel = CreateGroupHeading(frame.settingsContent, "Behaviour",
        frame.shareButton, -18)

    frame.pinToggle = CreateToggleRow(frame.settingsContent, 188, "Pin note",
        "Pin Note", "Keeps the note above other windows and raised when shown.")
    frame.pinToggle:SetPoint("TOPLEFT", frame.togglesLabel, "BOTTOMLEFT", 0, -10)

    frame.lockToggle = CreateToggleRow(frame.settingsContent, 188, "Lock note",
        "Lock Note", "Fixes the note in place and makes it click-through, so mouse clicks pass straight to the game world. Hold the unlock key - Alt unless you have changed it in Settings - to move, resize or edit it without unlocking.")
    frame.lockToggle:SetPoint("TOPLEFT", frame.pinToggle, "BOTTOMLEFT", 0, -4)

    -- ------------------------------------------------------------------
    -- Display: how the note is drawn on screen.
    -- ------------------------------------------------------------------

    frame.displayHeading = CreateGroupHeading(frame.settingsContent, "Display",
        frame.lockToggle, -20)

    -- Background and Edge are separate controls because they are separate
    -- decisions. Both at "None" is the addon's original look - text on the
    -- screen with nothing behind it, and no field stored on the note at all.
    --
    -- Both are segmented rows rather than dropdowns: three options each, all
    -- worth seeing at once, and nothing left hanging open over the panel.
    frame.backgroundLabel = CreateFieldLabel(frame.settingsContent, "Background")
    frame.backgroundLabel:SetPoint("TOPLEFT", frame.displayHeading, "BOTTOMLEFT", 0, -6)

    frame.backgroundChoice = NS.CreateChoiceRow(frame.settingsContent, 188, {
        getOptions = function() return NS.NOTE_BACKGROUNDS end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.background) or "none"
        end,
        labelFor = function(value)
            return (NS.NOTE_BACKGROUND_LABELS and NS.NOTE_BACKGROUND_LABELS[value]) or value
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            -- "none" is stored as absent, so an untouched note carries no field
            -- and reads exactly as it did before styles existed.
            NS.selectedNote.background = (value ~= "none") and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.backgroundChoice:SetPoint("TOPLEFT", frame.backgroundLabel, "BOTTOMLEFT", 0, -4)

    frame.backgroundChoice:SetTooltip("Background",
        "None leaves the note as text on the screen. Shade fades a little darkness behind the first lines without becoming a box. Card is a full panel.")

    frame.edgeLabel = CreateFieldLabel(frame.settingsContent, "Edge")
    frame.edgeLabel:SetPoint("TOPLEFT", frame.backgroundChoice, "BOTTOMLEFT", 0, -10)

    frame.edgeChoice = NS.CreateChoiceRow(frame.settingsContent, 188, {
        getOptions = function() return NS.NOTE_EDGES end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.edge) or "none"
        end,
        labelFor = function(value)
            return (NS.NOTE_EDGE_LABELS and NS.NOTE_EDGE_LABELS[value]) or value
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.edge = (value ~= "none") and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
            -- Rail and Border have different default thicknesses, so the
            -- slider has to be re-read rather than just shown.
            frame:RefreshNoteControls()
        end,
    })
    frame.edgeChoice:SetPoint("TOPLEFT", frame.edgeLabel, "BOTTOMLEFT", 0, -4)

    frame.edgeChoice:SetTooltip("Edge",
        "Accent rail marks the note along one side without covering anything behind it. Accent border outlines the whole note. Either works with any background.")

    -- Which side the rail runs along. Meaningless for the other two edges, so
    -- it only appears with Rail selected.
    frame.railSideLabel = CreateFieldLabel(frame.settingsContent, "Rail Side")
    frame.railSideLabel:SetPoint("TOPLEFT", frame.edgeChoice, "BOTTOMLEFT", 0, -10)

    frame.railSideChoice = NS.CreateChoiceRow(frame.settingsContent, 188, {
        getOptions = function() return NS.NOTE_RAIL_SIDES end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.railSide) or "LEFT"
        end,
        labelFor = function(value)
            return (NS.NOTE_RAIL_SIDE_LABELS and NS.NOTE_RAIL_SIDE_LABELS[value]) or value
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.railSide = (value ~= "LEFT") and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.railSideChoice:SetPoint("TOPLEFT", frame.railSideLabel, "BOTTOMLEFT", 0, -4)

    frame.railSideChoice:SetTooltip("Rail Side",
        "Which edge of the note the accent rail runs along. A note parked against the right of the screen usually reads better railed on its right.")

    -- Thickness applies to both accent edges, so it follows whichever is set
    -- rather than belonging to Border alone. Hidden with edge at None.
    frame.borderSizeLabel = CreateFieldLabel(frame.settingsContent, "Accent Thickness")
    frame.borderSizeLabel:SetPoint("TOPLEFT", frame.edgeChoice, "BOTTOMLEFT", 0, -10)

    frame.borderSizeSlider = CreateFlatSlider(frame.settingsContent, 188, 1, 8, 1)
    frame.borderSizeSlider:SetPoint("TOPLEFT", frame.borderSizeLabel, "BOTTOMLEFT", 2, -10)

    frame.borderSizeValue = frame.settingsContent:CreateFontString(nil, "OVERLAY")
    frame.borderSizeValue:SetFont(DEFAULT_FONT_PATH, 12, "")
    frame.borderSizeValue:SetPoint("BOTTOMRIGHT", frame.borderSizeSlider, "TOPRIGHT", 0, 6)
    frame.borderSizeValue:SetText("1px")
    RegisterThemed(frame.borderSizeValue, function(self, t)
        self:SetTextColor(Unpack(t.textNormal))
    end)

    -- A rail was 2px before it was adjustable, and a border 1px. Keeping the
    -- defaults apart means neither existing look changes, and the default is
    -- still stored as absent either way.
    local function DefaultThickness(note)
        return (note and note.edge == "rail") and 2 or 1
    end

    frame.borderSizeSlider.OnValueChangedCallback = function(value)
        if not NS.selectedNote then return end

        local size = Clamp(math.floor(value + 0.5), 1, 8)
        local default = DefaultThickness(NS.selectedNote)
        NS.selectedNote.borderSize = (size ~= default) and size or nil

        frame.borderSizeValue:SetText(size .. "px")
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
    end

    frame.DefaultNoteThickness = DefaultThickness

    -- Shows only the edge controls the current edge actually uses, and closes
    -- the gap left by the ones it does not. Everything below anchors to the
    -- last visible control, so the panel has no holes in it.
    function frame:UpdateEdgeControls()
        local edge = NS.selectedNote and NS.selectedNote.edge
        local showRailSide = (edge == "rail")
        local showThickness = (edge == "rail" or edge == "border")
        local showAccent = (edge ~= nil)

        self.railSideLabel:SetShown(showRailSide)
        self.railSideChoice:SetShown(showRailSide)
        self.borderSizeLabel:SetShown(showThickness)
        self.borderSizeValue:SetShown(showThickness)
        self.borderSizeSlider:SetShown(showThickness)
        self.accentLabel:SetShown(showAccent)
        self.accentDropdown:SetShown(showAccent)

        self.borderSizeLabel:ClearAllPoints()
        self.borderSizeLabel:SetPoint("TOPLEFT",
            showRailSide and self.railSideChoice or self.edgeChoice,
            "BOTTOMLEFT", 0, -10)

        self.accentLabel:ClearAllPoints()
        self.accentLabel:SetPoint("TOPLEFT",
            showThickness and self.borderSizeSlider or self.edgeChoice,
            "BOTTOMLEFT", showThickness and -2 or 0, -14)

        self.textHeading:ClearAllPoints()
        self.textHeading:SetPoint("TOPLEFT",
            showAccent and self.accentDropdown or self.edgeChoice,
            "BOTTOMLEFT", 0, -16)

        if self.UpdateSettingsContentHeight then
            self:UpdateSettingsContentHeight()
        end
    end

    -- Accent colour, drawn from the markup palette so there is one list of
    -- colours in the addon rather than two.
    local THEME_ACCENT = "\1theme"

    frame.accentLabel = CreateFieldLabel(frame.settingsContent, "Accent")
    frame.accentLabel:SetPoint("TOPLEFT", frame.edgeChoice, "BOTTOMLEFT", 0, -14)

    frame.accentDropdown = NS.CreateDropdown(frame.settingsContent, 188, {
        getOptions = function()
            local options = { THEME_ACCENT }
            for _, name in ipairs(NS.MARKUP_COLOR_ORDER or {}) do
                table.insert(options, name)
            end
            return options
        end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.accent) or THEME_ACCENT
        end,
        labelFor = function(value)
            if value == THEME_ACCENT then return "Theme accent" end

            -- Shown in the colour it names, so the list is its own swatch.
            local hex = NS.MARKUP_COLOR_NAMES and NS.MARKUP_COLOR_NAMES[value]
            local label = value:gsub("^%l", string.upper)
            return hex and ("|c" .. hex .. label .. "|r") or label
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.accent = (value ~= THEME_ACCENT) and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.accentDropdown:SetPoint("TOPLEFT", frame.accentLabel, "BOTTOMLEFT", 0, -6)

    AttachTooltip(frame.accentDropdown, "Accent Colour",
        "Colours the Accent rail style. Useful for telling raid callouts apart from personal reminders at a glance.")

    -- ------------------------------------------------------------------
    -- Text: the type itself - face, size, outline and opacity.
    -- ------------------------------------------------------------------

    frame.textHeading = CreateGroupHeading(frame.settingsContent, "Text",
        frame.accentDropdown, -16)

    -- Per-note font override. "Default" means follow the global note font from
    -- the settings window, which is stored as nil rather than as a font name so
    -- the note keeps tracking the global if that later changes.
    frame.fontLabel = CreateFieldLabel(frame.settingsContent, "Font")
    frame.fontLabel:SetPoint("TOPLEFT", frame.textHeading, "BOTTOMLEFT", 0, -6)

    local USE_GLOBAL_FONT = "|cff808080Use global font|r"

    frame.fontDropdown = NS.CreateDropdown(frame.settingsContent, 188, {
        getOptions = function()
            local options = { USE_GLOBAL_FONT }
            for _, name in ipairs(NS.GetFontList()) do
                table.insert(options, name)
            end
            return options
        end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.font) or USE_GLOBAL_FONT
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.font = (value ~= USE_GLOBAL_FONT) and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
            frame.UpdatePreview()
        end,
        fontFor = function(value)
            if value == USE_GLOBAL_FONT then return nil end
            return NS.GetFontPath(value)
        end,
    })
    frame.fontDropdown:SetPoint("TOPLEFT", frame.fontLabel, "BOTTOMLEFT", 0, -4)

    -- The two sliders sit together directly under the font, since size and
    -- opacity are the two things people reach for after picking a face.
    frame.fontSizeLabel = CreateFieldLabel(frame.settingsContent, "Font Size")
    frame.fontSizeLabel:SetPoint("TOPLEFT", frame.fontDropdown, "BOTTOMLEFT", 0, -10)

    frame.fontSizeSlider = CreateFlatSlider(frame.settingsContent, 188, NOTE_FONT_MIN, NOTE_FONT_MAX, 1)
    frame.fontSizeSlider:SetPoint("TOPLEFT", frame.fontSizeLabel, "BOTTOMLEFT", 2, -10)

    frame.fontSizeValue = frame.settingsContent:CreateFontString(nil, "OVERLAY")
    frame.fontSizeValue:SetFont(DEFAULT_FONT_PATH, 12, "")
    frame.fontSizeValue:SetPoint("BOTTOMRIGHT", frame.fontSizeSlider, "TOPRIGHT", 0, 6)
    frame.fontSizeValue:SetText("14px")
    RegisterThemed(frame.fontSizeValue, function(self, t)
        self:SetTextColor(Unpack(t.textNormal))
    end)

    frame.opacityLabel = CreateFieldLabel(frame.settingsContent, "Text Opacity")
    frame.opacityLabel:SetPoint("TOPLEFT", frame.fontSizeSlider, "BOTTOMLEFT", -2, -14)

    frame.opacitySlider = CreateFlatSlider(frame.settingsContent, 188, 0, 100, 1)
    frame.opacitySlider:SetPoint("TOPLEFT", frame.opacityLabel, "BOTTOMLEFT", 2, -10)

    frame.opacityValue = frame.settingsContent:CreateFontString(nil, "OVERLAY")
    frame.opacityValue:SetFont(DEFAULT_FONT_PATH, 12, "")
    frame.opacityValue:SetPoint("BOTTOMRIGHT", frame.opacitySlider, "TOPRIGHT", 0, 6)
    frame.opacityValue:SetText("100%")
    RegisterThemed(frame.opacityValue, function(self, t)
        self:SetTextColor(Unpack(t.textNormal))
    end)

    -- Base text colour. Markup already colours individual spans; this is what
    -- everything else in the note renders as.
    local WHITE_TEXT = "\1white"

    frame.textColorLabel = CreateFieldLabel(frame.settingsContent, "Text Colour")
    frame.textColorLabel:SetPoint("TOPLEFT", frame.opacitySlider, "BOTTOMLEFT", -2, -14)

    frame.textColorDropdown = NS.CreateDropdown(frame.settingsContent, 188, {
        getOptions = function()
            local options = { WHITE_TEXT, NS.NOTE_TEXT_CLASS_COLOR }
            for _, name in ipairs(NS.MARKUP_COLOR_ORDER or {}) do
                table.insert(options, name)
            end
            return options
        end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.textColor) or WHITE_TEXT
        end,
        labelFor = function(value)
            if value == WHITE_TEXT then return "Default (white)" end
            if value == NS.NOTE_TEXT_CLASS_COLOR then return "Your class colour" end

            local hex = NS.MARKUP_COLOR_NAMES and NS.MARKUP_COLOR_NAMES[value]
            local label = value:gsub("^%l", string.upper)
            return hex and ("|c" .. hex .. label .. "|r") or label
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.textColor = (value ~= WHITE_TEXT) and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.textColorDropdown:SetPoint("TOPLEFT", frame.textColorLabel, "BOTTOMLEFT", 2, -4)

    AttachTooltip(frame.textColorDropdown, "Text Colour",
        "The note's base colour. Colour tags inside the note still override it span by span. Class colour is resolved live, so a shared note follows whoever is reading it.")

    -- Outline and Alignment are three options each, so they are segmented rows
    -- for the same reason Background and Edge are.
    frame.outlineLabel = CreateFieldLabel(frame.settingsContent, "Text outline")
    frame.outlineLabel:SetPoint("TOPLEFT", frame.textColorDropdown, "BOTTOMLEFT", -2, -10)

    frame.outlineChoice = NS.CreateChoiceRow(frame.settingsContent, 188, {
        getOptions = function() return NS.NOTE_OUTLINES end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.outline) or "none"
        end,
        labelFor = function(value)
            return (NS.NOTE_OUTLINE_LABELS and NS.NOTE_OUTLINE_LABELS[value]) or value
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.outline = (value ~= "none") and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.outlineChoice:SetPoint("TOPLEFT", frame.outlineLabel, "BOTTOMLEFT", 0, -4)

    frame.outlineChoice:SetTooltip("Text Outline",
        "Outlines the letters themselves. Usually the better answer to text you cannot read over snow or lava, since it costs no screen space and keeps the note looking like text rather than a window.")

    -- Alignment. Centre is what most raid callouts want: "SPREAD" reads better
    -- centred than pinned to whichever edge the note sits against.
    frame.alignLabel = CreateFieldLabel(frame.settingsContent, "Alignment")
    frame.alignLabel:SetPoint("TOPLEFT", frame.outlineChoice, "BOTTOMLEFT", 0, -10)

    frame.alignChoice = NS.CreateChoiceRow(frame.settingsContent, 188, {
        getOptions = function() return NS.NOTE_ALIGNMENTS end,
        getCurrent = function()
            return (NS.selectedNote and NS.selectedNote.align) or "LEFT"
        end,
        labelFor = function(value)
            return (NS.NOTE_ALIGNMENT_LABELS and NS.NOTE_ALIGNMENT_LABELS[value]) or value
        end,
        onSelect = function(value)
            if not NS.selectedNote then return end
            NS.selectedNote.align = (value ~= "LEFT") and value or nil
            RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        end,
    })
    frame.alignChoice:SetPoint("TOPLEFT", frame.alignLabel, "BOTTOMLEFT", 0, -4)

    frame.alignChoice:SetTooltip("Alignment",
        "How the note's text sits within its own width. Centre suits short raid callouts; left suits anything you actually read.")

    -- Pulls every control in the note panel back into line with whatever is
    -- selected - or with the defaults when nothing is.
    --
    -- This used to be two near-identical lists at the call site, one for the
    -- selected case and one for the empty one. They drifted every time a
    -- control was added or removed, so the panel would show a stale value for
    -- exactly one of the two paths. One list, called from both.
    function frame:RefreshNoteControls()
        local note = NS.selectedNote

        self.pinToggle:SetActive(note and note.pinned == true or false)
        self.lockToggle:SetActive(note and note.locked == true or false)

        self.backgroundChoice:Repaint()
        self.edgeChoice:Repaint()
        self.railSideChoice:Repaint()
        self.outlineChoice:Repaint()
        self.alignChoice:Repaint()

        self.accentDropdown:RefreshLabel()
        self.textColorDropdown:RefreshLabel()
        self.fontDropdown:RefreshLabel()

        local thickness = (note and note.borderSize) or self.DefaultNoteThickness(note)
        self.borderSizeValue:SetText(thickness .. "px")
        self.borderSizeSlider:SetValueSilent(thickness)

        local fontSize = (note and note.fontSize) or 14
        self.fontSizeValue:SetText(fontSize .. "px")
        self.fontSizeSlider:SetValueSilent(fontSize)

        local opacity = math.floor((note and note.bgAlpha) or 100)
        self.opacityValue:SetText(opacity .. "%")
        self.opacitySlider:SetValueSilent(opacity)

        self:UpdateEdgeControls()
    end
    -- Window-level actions live in the header, not in the note panel: settings
    -- and help apply to the addon, not to whichever note happens to be selected.
    -- Both are square icon buttons so they read as a matched pair; the tooltips
    -- carry the labels.
    frame.settingsButton = CreateFrame("Button", nil, frame.topBar, "UIPanelButtonTemplate")
    frame.settingsButton:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
    frame.settingsButton:SetText("")
    StyleActionButton(frame.settingsButton, 24, 22, false)
    AttachTooltip(frame.settingsButton, "Settings", "Theme, minimap button and other addon-wide options.")

    frame.settingsButton.icon = frame.settingsButton:CreateTexture(nil, "OVERLAY")
    frame.settingsButton.icon:SetSize(13, 13)
    frame.settingsButton.icon:SetPoint("CENTER", 0, 0)
    frame.settingsButton.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    RegisterThemed(frame.settingsButton.icon, function(self, t)
        self:SetVertexColor(Unpack(t.textNormal))
    end)

    frame.settingsButton:SetScript("OnClick", function()
        if NS.ToggleSettings then
            NS.ToggleSettings()
        end
    end)

    -- A "?" glyph rather than a texture: no art dependency, and it is the
    -- universally understood mark for help.
    frame.helpButton = CreateFrame("Button", nil, frame.topBar, "UIPanelButtonTemplate")
    frame.helpButton:SetPoint("RIGHT", frame.settingsButton, "LEFT", -4, 0)
    frame.helpButton:SetText("?")
    StyleActionButton(frame.helpButton, 24, 22, false)
    AttachTooltip(frame.helpButton, "Markup Help", "Every tag you can use in a note, shown rendered next to its source.")

    -- The theme picker and minimap toggle used to sit here behind a divider,
    -- inside a panel titled "Selected Note Settings". They are addon-wide, not
    -- per-note, and now live in the settings window (SettingsUI.lua).

    -- Note list rows are drawn on demand rather than through the theme
    -- registry, and filter tabs repaint themselves, so both need an explicit
    -- nudge when the palette changes.
    RegisterThemeCallback(function()
        if frame.UpdateFilterTabs then
            frame.UpdateFilterTabs()
        end
        if frame:IsShown() then
            frame:RefreshNoteList()
        end
    end)

    -- ------------------------------------------------------------------
    -- Markup help
    --
    -- Each entry is shown twice: the source on the left, and that same
    -- source actually put through the renderer on the right. Reading the
    -- syntax never told you what it would look like, which was the main
    -- thing wrong with the old help text.
    -- ------------------------------------------------------------------

    -- `source` is what the row shows and renders. Clicking a row inserts into
    -- the editor: `open`/`close` wrap whatever is selected, `insert` drops in a
    -- fixed string. A row with neither is illustrative only and stays inert -
    -- better an unclickable row than one that pastes example prose into a note.
    local MARKUP_EXAMPLES = {
        { heading = "Colours" },
        { source = "[red]Move out[/]",    open = "[red]",    close = "[/]" },
        { source = "[gold]Cooldowns[/]",  open = "[gold]",   close = "[/]" },
        { source = "[green]Safe[/]  [blue]Soak[/]", open = "[green]", close = "[/]" },
        { source = "[col:ff8800]Custom hex[/]", open = "[col:ff8800]", close = "[/]" },
        { source = "[class:mage]Mage[/] [class:priest]Priest[/]", open = "[class:mage]", close = "[/]" },

        { heading = "Icons" },
        { source = "[spell:116] Frostbolt",   insert = "[spell:]" },
        { source = "[item:19019] Thunderfury", insert = "[item:]" },

        { heading = "Checklists" },
        { source = "[ ] Great Vault",  insert = "[ ] " },
        { source = "[x] Run Mythic+" },

        { heading = "Raid markers" },
        { source = "[rt1][rt2][rt3][rt4][rt5][rt6][rt7][rt8]" },
        { source = "[rt1] Tank  [rt8] Kill first" },

        { heading = "Live values" },
        { source = "[player] soaks with [group:2]", insert = "[player]" },
        { source = "[zone] - [spec]",               insert = "[zone]" },

        { heading = "Nesting and escaping" },
        { source = "[red]Pull at [gold]3[/] stacks[/]" },
        { source = "[[red]] shows the tag itself" },

        -- Curly braces predate square ones and still work, so a player who
        -- learned the old syntax - or who copied a note written in it - is not
        -- left wondering why their note renders as literal text.
        { heading = "Curly braces still work" },
        { source = "{red}Old notes are fine{/}" },
    }

    frame.helpPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.helpPanel:SetSize(430, 656)
    frame.helpPanel:SetFrameStrata("DIALOG")
    frame.helpPanel:SetBackdrop(FLAT_BACKDROP)
    frame.helpPanel:Hide()

    -- Docked to the manager's left, opposite the settings panels. Markup help
    -- is read while typing into the body editor, so it belongs on the side the
    -- editor is not pushed against.
    NS.DockDialog(frame.helpPanel, "LEFT")

    -- Escape closes this window first and leaves the manager open; a second
    -- Escape then closes the manager. See Widgets.lua for why this can't just
    -- be a UISpecialFrames registration.
    NS.MakeEscapeClosable(frame.helpPanel)

    frame.helpTitle = frame.helpPanel:CreateFontString(nil, "OVERLAY")
    frame.helpTitle:SetFont(DEFAULT_FONT_PATH, 18, "")
    frame.helpTitle:SetPoint("TOPLEFT", 20, -16)
    frame.helpTitle:SetText("Markup Help")

    frame.helpHint = frame.helpPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.helpHint:SetPoint("TOPLEFT", frame.helpTitle, "BOTTOMLEFT", 0, -3)
    frame.helpHint:SetText("Drag to move, Escape to close. Position is remembered.")
    RegisterThemed(frame.helpHint, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    frame.helpHeaderLine = frame.helpPanel:CreateTexture(nil, "ARTWORK")
    frame.helpHeaderLine:SetPoint("TOPLEFT", 20, -58)
    frame.helpHeaderLine:SetPoint("TOPRIGHT", -20, -58)
    frame.helpHeaderLine:SetHeight(1)
    StyleDialog(frame.helpPanel, frame.helpTitle, frame.helpHeaderLine)

    frame.helpCloseButton = CreateFrame("Button", nil, frame.helpPanel, "UIPanelCloseButton")
    frame.helpCloseButton:SetPoint("TOPRIGHT", -6, -6)
    frame.helpCloseButton:SetScript("OnClick", function()
        frame.helpPanel:Hide()
    end)

    -- Column headers for the source/result pairing.
    frame.helpColSource = frame.helpPanel:CreateFontString(nil, "OVERLAY")
    frame.helpColSource:SetFont(DEFAULT_FONT_PATH, 11, "")
    frame.helpColSource:SetPoint("TOPLEFT", 20, -68)
    frame.helpColSource:SetText("YOU TYPE")

    frame.helpColResult = frame.helpPanel:CreateFontString(nil, "OVERLAY")
    frame.helpColResult:SetFont(DEFAULT_FONT_PATH, 11, "")
    frame.helpColResult:SetPoint("TOPLEFT", 232, -68)
    frame.helpColResult:SetText("YOU GET")

    RegisterThemed(frame.helpColSource, function(self, t) self:SetTextColor(Unpack(t.textDim)) end)
    RegisterThemed(frame.helpColResult, function(self, t) self:SetTextColor(Unpack(t.textDim)) end)

    local helpY = -86
    frame.helpRows = {}
    frame.helpExamples = {}

    for _, example in ipairs(MARKUP_EXAMPLES) do
        if example.heading then
            local heading = frame.helpPanel:CreateFontString(nil, "OVERLAY")
            heading:SetFont(DEFAULT_FONT_PATH, 12, "")
            heading:SetPoint("TOPLEFT", 20, helpY - 4)
            heading:SetText(example.heading)
            RegisterThemed(heading, function(self, t)
                self:SetTextColor(Unpack(t.accentBright))
            end)
            table.insert(frame.helpRows, heading)
            helpY = helpY - 22
        else
            local source = frame.helpPanel:CreateFontString(nil, "OVERLAY")
            source:SetFont(DEFAULT_FONT_PATH, 12, "")
            source:SetPoint("TOPLEFT", 24, helpY)
            source:SetWidth(200)
            source:SetJustifyH("LEFT")
            source:SetText(example.source)
            RegisterThemed(source, function(self, t)
                self:SetTextColor(Unpack(t.textMuted))
            end)

            -- The same string, actually rendered.
            local result = frame.helpPanel:CreateFontString(nil, "OVERLAY")
            result:SetFont(DEFAULT_FONT_PATH, 13, "")
            result:SetPoint("TOPLEFT", 232, helpY)
            result:SetWidth(178)
            result:SetJustifyH("LEFT")
            result:SetTextColor(1, 1, 1)
            result.markupSource = example.source

            -- FontStrings cannot take clicks, so a transparent button covers
            -- the row. This is what turns the help window from something you
            -- read and then retype into an insert palette.
            if example.open or example.insert then
                local clicker = CreateFrame("Button", nil, frame.helpPanel)
                clicker:SetPoint("TOPLEFT", 20, helpY + 3)
                clicker:SetPoint("TOPRIGHT", frame.helpPanel, "TOPRIGHT", -20, helpY + 3)
                clicker:SetHeight(19)

                clicker.highlight = clicker:CreateTexture(nil, "HIGHLIGHT")
                clicker.highlight:SetAllPoints()
                clicker.highlight:SetColorTexture(1, 1, 1, 0.07)

                clicker:SetScript("OnClick", function()
                    frame.WrapSelection(example.open or example.insert, example.close or "")
                end)

                AttachTooltip(clicker, "Click to insert",
                    example.open
                        and ("Wraps the selected text in " .. example.open .. " ... " .. example.close)
                        or ("Inserts " .. example.insert .. " at the cursor"))

                table.insert(frame.helpRows, clicker)
            end

            table.insert(frame.helpRows, source)
            table.insert(frame.helpRows, result)
            table.insert(frame.helpExamples, result)
            helpY = helpY - 20
        end
    end

    frame.helpFooter = frame.helpPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.helpFooter:SetPoint("TOPLEFT", 20, helpY - 10)
    frame.helpFooter:SetPoint("RIGHT", frame.helpPanel, "RIGHT", -20, 0)
    frame.helpFooter:SetJustifyH("LEFT")
    frame.helpFooter:SetSpacing(3)
    frame.helpFooter:SetText(
        "Colours: " .. table.concat({ "red", "green", "blue", "cyan", "yellow", "orange", "gold", "purple", "pink", "white", "grey" }, ", ") ..
        "\nClose any colour with [/]. Spell and item tags take an ID."
    )
    RegisterThemed(frame.helpFooter, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    -- Rendered on show rather than once at load: spell and especially item
    -- icons come from caches that may still be cold right after login, and a
    -- failed lookup would otherwise leave the raw tag on display forever.
    local function RefreshHelpExamples()
        for _, result in ipairs(frame.helpExamples) do
            result:SetText(NS.RenderMarkup(result.markupSource))
        end
    end

    frame.helpButton:SetScript("OnClick", function()
        if frame.helpPanel:IsShown() then
            frame.helpPanel:Hide()
        else
            frame.helpPanel:Dock()
            RefreshHelpExamples()
            frame.helpPanel:Show()
        end
    end)

    -- Forward declaration: CreateNoteWithScope (below) calls LoadNoteIntoEditor,
    -- but the real definition lives further down. Without this the call would
    -- compile as a lookup of a global that never exists, and error at runtime.
    local LoadNoteIntoEditor

    frame.newNotePopup = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.newNotePopup:SetSize(320, 190)
    frame.newNotePopup:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.newNotePopup:SetFrameStrata("DIALOG")
    frame.newNotePopup:SetBackdrop(FLAT_BACKDROP)
    frame.newNotePopup:Hide()

    frame.newNotePopupTitle = frame.newNotePopup:CreateFontString(nil, "OVERLAY")
    frame.newNotePopupTitle:SetFont(DEFAULT_FONT_PATH, 18, "")
    frame.newNotePopupTitle:SetPoint("TOPLEFT", 18, -14)
    frame.newNotePopupTitle:SetText("New Note")

    frame.newNotePopupHeaderLine = frame.newNotePopup:CreateTexture(nil, "ARTWORK")
    frame.newNotePopupHeaderLine:SetPoint("TOPLEFT", 18, -40)
    frame.newNotePopupHeaderLine:SetPoint("TOPRIGHT", -18, -40)
    frame.newNotePopupHeaderLine:SetHeight(1)
    StyleDialog(frame.newNotePopup, frame.newNotePopupTitle, frame.newNotePopupHeaderLine)

    frame.newNotePopupClose = CreateFrame("Button", nil, frame.newNotePopup, "UIPanelCloseButton")
    frame.newNotePopupClose:SetPoint("TOPRIGHT", -6, -6)
    frame.newNotePopupClose:SetScript("OnClick", function()
        frame.newNotePopup:Hide()
    end)

    frame.newNotePopupInfo = frame.newNotePopup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.newNotePopupInfo:SetPoint("TOPLEFT", 18, -52)
    frame.newNotePopupInfo:SetPoint("TOPRIGHT", -18, -52)
    frame.newNotePopupInfo:SetJustifyH("LEFT")
    RegisterThemed(frame.newNotePopupInfo, function(self, th) self:SetTextColor(Unpack(th.textNormal)) end)
    frame.newNotePopupInfo:SetText("Where should this note be saved?")

    frame.newNoteAccountButton = CreateFrame("Button", nil, frame.newNotePopup, "UIPanelButtonTemplate")
    frame.newNoteAccountButton:SetSize(130, 58)
    frame.newNoteAccountButton:SetPoint("TOPLEFT", 18, -84)
    frame.newNoteAccountButton:SetText("Account")
    StyleActionButton(frame.newNoteAccountButton, 130, 58, true)

    frame.newNoteAccountCaption = frame.newNotePopup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.newNoteAccountCaption:SetPoint("TOP", frame.newNoteAccountButton, "BOTTOM", 0, -6)
    frame.newNoteAccountCaption:SetText("All characters")
    RegisterThemed(frame.newNoteAccountCaption, function(self, th) self:SetTextColor(Unpack(th.textMuted)) end)

    frame.newNoteCharacterButton = CreateFrame("Button", nil, frame.newNotePopup, "UIPanelButtonTemplate")
    frame.newNoteCharacterButton:SetSize(130, 58)
    frame.newNoteCharacterButton:SetPoint("LEFT", frame.newNoteAccountButton, "RIGHT", 8, 0)
    frame.newNoteCharacterButton:SetText("Character")
    StyleActionButton(frame.newNoteCharacterButton, 130, 58, true)

    frame.newNoteCharacterCaption = frame.newNotePopup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.newNoteCharacterCaption:SetPoint("TOP", frame.newNoteCharacterButton, "BOTTOM", 0, -6)
    frame.newNoteCharacterCaption:SetText("This character only")
    RegisterThemed(frame.newNoteCharacterCaption, function(self, th) self:SetTextColor(Unpack(th.textMuted)) end)

    local function CreateNoteWithScope(scope)
        MyNotesDB.settings.newNoteScope = scope
        local note = CreateNewNote(scope)
        LoadNoteIntoEditor(scope, note)
        frame:RefreshNoteList()
        frame.newNotePopup:Hide()
    end

    frame.newNoteAccountButton:SetScript("OnClick", function()
        CreateNoteWithScope("account")
    end)
    frame.newNoteCharacterButton:SetScript("OnClick", function()
        CreateNoteWithScope("character")
    end)

    frame.unsavedPopup = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.unsavedPopup:SetSize(340, 190)
    frame.unsavedPopup:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.unsavedPopup:SetFrameStrata("DIALOG")
    frame.unsavedPopup:SetBackdrop(FLAT_BACKDROP)
    frame.unsavedPopup:Hide()

    frame.unsavedPopupTitle = frame.unsavedPopup:CreateFontString(nil, "OVERLAY")
    frame.unsavedPopupTitle:SetFont(DEFAULT_FONT_PATH, 18, "")
    frame.unsavedPopupTitle:SetPoint("TOPLEFT", 18, -14)
    frame.unsavedPopupTitle:SetText("Unsaved Changes")

    frame.unsavedPopupHeaderLine = frame.unsavedPopup:CreateTexture(nil, "ARTWORK")
    frame.unsavedPopupHeaderLine:SetPoint("TOPLEFT", 18, -40)
    frame.unsavedPopupHeaderLine:SetPoint("TOPRIGHT", -18, -40)
    frame.unsavedPopupHeaderLine:SetHeight(1)
    StyleDialog(frame.unsavedPopup, frame.unsavedPopupTitle, frame.unsavedPopupHeaderLine)

    frame.unsavedPopupInfo = frame.unsavedPopup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.unsavedPopupInfo:SetPoint("TOPLEFT", 18, -52)
    frame.unsavedPopupInfo:SetPoint("TOPRIGHT", -18, -52)
    frame.unsavedPopupInfo:SetJustifyH("LEFT")
    RegisterThemed(frame.unsavedPopupInfo, function(self, th) self:SetTextColor(Unpack(th.textNormal)) end)
    frame.unsavedPopupInfo:SetText("This note has changes that haven't been saved yet. What would you like to do?")

    frame.unsavedSaveButton = CreateFrame("Button", nil, frame.unsavedPopup, "UIPanelButtonTemplate")
    frame.unsavedSaveButton:SetSize(146, 30)
    frame.unsavedSaveButton:SetPoint("TOPLEFT", 18, -96)
    frame.unsavedSaveButton:SetText("Save Changes")
    StyleActionButton(frame.unsavedSaveButton, 146, 30, true)

    frame.unsavedDiscardButton = CreateFrame("Button", nil, frame.unsavedPopup, "UIPanelButtonTemplate")
    frame.unsavedDiscardButton:SetSize(146, 30)
    frame.unsavedDiscardButton:SetPoint("LEFT", frame.unsavedSaveButton, "RIGHT", 8, 0)
    frame.unsavedDiscardButton:SetText("Discard")
    StyleActionButton(frame.unsavedDiscardButton, 146, 30, "danger")

    frame.unsavedCancelButton = CreateFrame("Button", nil, frame.unsavedPopup, "UIPanelButtonTemplate")
    frame.unsavedCancelButton:SetSize(300, 26)
    frame.unsavedCancelButton:SetPoint("TOPLEFT", frame.unsavedSaveButton, "BOTTOMLEFT", 0, -10)
    frame.unsavedCancelButton:SetText("Cancel")
    StyleActionButton(frame.unsavedCancelButton, 300, 26, false)

    frame.newButton = CreateFooterButton(frame.bottomBar, "New", 96)
    frame.newButton:SetPoint("LEFT", frame.bottomBar, "LEFT", BAR_CAP_WIDTH - 6, 0)

    frame.saveButton = CreateFooterButton(frame.bottomBar, "Save", 96)
    frame.saveButton:SetPoint("LEFT", frame.newButton, "RIGHT", 8, 0)

    frame.duplicateButton = CreateFooterButton(frame.bottomBar, "Duplicate", 106)
    frame.duplicateButton:SetPoint("LEFT", frame.saveButton, "RIGHT", 20, 0)

    frame.toggleVisibleButton = CreateFooterButton(frame.bottomBar, "Show / Hide Note", 148)
    frame.toggleVisibleButton:SetPoint("LEFT", frame.duplicateButton, "RIGHT", 8, 0)

    frame.footerDivider = frame.bottomBar:CreateTexture(nil, "ARTWORK")
    frame.footerDivider:SetPoint("LEFT", frame.saveButton, "RIGHT", 10, 0)
    frame.footerDivider:SetPoint("TOP", frame.saveButton, "TOP", 0, -2)
    frame.footerDivider:SetPoint("BOTTOM", frame.saveButton, "BOTTOM", 0, 2)
    frame.footerDivider:SetWidth(1)
    frame.footerDivider:SetColorTexture(1, 1, 1, 0.08)

    -- Clear of the right-hand cap, the way New clears the left one. The old
    -- -24 was measured from the window edge, which put it under the ornament
    -- as soon as the bar arrived.
    frame.deleteButton = CreateFooterButton(frame.bottomBar, "Delete", 96)
    frame.deleteButton:SetPoint("RIGHT", frame.bottomBar, "RIGHT", -(BAR_CAP_WIDTH - 6), 0)

    -- Anchored here rather than where it is created: it sits left of Delete,
    -- which does not exist yet at that point.
    frame.versionText:SetPoint("RIGHT", frame.deleteButton, "LEFT", -14, 0)

    StyleActionButton(frame.newButton, 100, 30, true)
    StyleActionButton(frame.saveButton, 100, 30, false)
    StyleActionButton(frame.duplicateButton, 112, 30, false)
    StyleActionButton(frame.toggleVisibleButton, 154, 30, false)
    StyleActionButton(frame.deleteButton, 100, 30, "danger")

    -- Anything that acts on the selected note is disabled when there isn't one.
    -- These handlers all began with "if not NS.selectedNote then return end",
    -- so the buttons looked live and silently did nothing.
    --
    -- Save is excluded on purpose: with no selection it creates a note, so it
    -- is genuinely useful in that state.
    local function UpdateActionAvailability(note)
        local hasNote = note ~= nil

        frame.duplicateButton:SetEnabledState(hasNote)
        frame.toggleVisibleButton:SetEnabledState(hasNote)
        frame.deleteButton:SetEnabledState(hasNote)
        frame.moveScopeButton:SetEnabledState(hasNote)

        -- Save used to stay live with nothing selected, because it would create
        -- a note from whatever was typed. With the editor hidden in that state
        -- there is nothing to type, so it would only ever make an empty note.
        frame.saveButton:SetEnabledState(hasNote)

        -- Both right-hand panels exist to act on a selected note, so neither
        -- has anything to show without one. A hint takes their place rather
        -- than leaving two-thirds of the window blank.
        if hasNote then
            frame.editorPanel:Show()
            frame.settingsPanel:Show()
            frame.noSelectionHint:Hide()
        else
            frame.editorPanel:Hide()
            frame.settingsPanel:Hide()
            frame.noSelectionHint:Show()
        end
    end

    local function UpdateSelectedInfo(scope, note)
        UpdateActionAvailability(note)

        -- Keep an open rules window pointed at whatever is selected now, rather
        -- than leaving it editing a note you have navigated away from.
        if NS.RefreshRulesWindow then
            NS.RefreshRulesWindow()
        end

        if not note then
            frame.selectedInfo:SetText("No note selected")
            frame.moveScopeButton:SetText("Move Scope")
            frame:RefreshNoteControls()
            return
        end

        local scopeLabel = scope == "character" and "Character" or "Account"
        local stateLabel = note.visible and "Visible" or "Hidden"
        local lockLabel = note.locked and "Locked" or "Unlocked"
        frame.selectedInfo:SetText("Selected: " .. scopeLabel .. " | " .. stateLabel .. " | " .. lockLabel)
        frame.moveScopeButton:SetText(scope == "account" and "Move to Character" or "Move to Account")

        frame:RefreshNoteControls()
    end

    local function ClearEditor()
        NS.selectedNote = nil
        NS.selectedScope = "account"
        frame.suppressDirtyTracking = true
        frame.titleEdit:SetText("")
        frame.bodyEdit:SetText("")
        frame.suppressDirtyTracking = false
        frame.isDirty = false
        frame.UpdateUnsavedIndicator()
        UpdateSelectedInfo(nil, nil)
    end

    function LoadNoteIntoEditor(scope, note)
        if not note then
            ClearEditor()
            return
        end

        NS.selectedNote = note
        NS.selectedScope = scope

        frame.suppressDirtyTracking = true
        frame.titleEdit:SetText(note.title or "")
        frame.bodyEdit:SetText(note.body or "")
        frame.suppressDirtyTracking = false
        frame.isDirty = false
        frame.UpdateUnsavedIndicator()
        UpdateSelectedInfo(scope, note)

        -- A different note starts at the top; carrying the last one's scroll
        -- offset over would show the new note from the middle.
        frame.previewScroll:SetVerticalScroll(0)
    end

    local function SaveCurrentEditor()
        local titleText = SafeTrim(frame.titleEdit:GetText() or "")
        local bodyText = frame.bodyEdit:GetText() or ""

        if not NS.selectedNote then
            local scope = MyNotesDB.settings.newNoteScope or "account"
            NS.selectedNote = CreateNewNote(scope)
            NS.selectedScope = scope
        end

        NS.selectedNote.title = titleText
        NS.selectedNote.body = bodyText

        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        LoadNoteIntoEditor(NS.selectedScope, NS.selectedNote)
        frame:RefreshNoteList()
    end

    local function IsEditorDirty()
        return frame.isDirty
    end

    frame.pendingGuardedAction = nil

    local function RunPendingGuardedAction()
        local action = frame.pendingGuardedAction
        frame.pendingGuardedAction = nil
        if action then
            action()
        end
    end

    local function GuardUnsavedChanges(action)
        if IsEditorDirty() then
            frame.pendingGuardedAction = action
            frame.unsavedPopup:Show()
        else
            action()
        end
    end
    frame.GuardUnsavedChanges = GuardUnsavedChanges
    frame.LoadNoteIntoEditor = LoadNoteIntoEditor

    frame.unsavedSaveButton:SetScript("OnClick", function()
        SaveCurrentEditor()
        frame.unsavedPopup:Hide()
        RunPendingGuardedAction()
    end)

    frame.unsavedDiscardButton:SetScript("OnClick", function()
        frame.unsavedPopup:Hide()
        RunPendingGuardedAction()
    end)

    frame.unsavedCancelButton:SetScript("OnClick", function()
        frame.pendingGuardedAction = nil
        frame.unsavedPopup:Hide()
    end)

    -- Paints one list row for its current state. Split out of RefreshNoteList
    -- so the hover handlers can repaint a single row without rebuilding the
    -- whole list.
    local function ApplyRowVisual(btn)
        local t = NS.GetTheme()

        if btn.isSelected then
            btn:SetBackdropColor(Unpack(t.rowSelBg))
            btn:SetBackdropBorderColor(Unpack(t.rowSelBorder))
            btn.title:SetTextColor(Unpack(t.textBright))
            btn.preview:SetTextColor(Unpack(t.textNormal))
        elseif btn.isHovered then
            btn:SetBackdropColor(Unpack(t.rowHoverBg))
            btn:SetBackdropBorderColor(Unpack(t.rowBorder))
            btn.title:SetTextColor(Unpack(t.textPrimary))
            btn.preview:SetTextColor(Unpack(t.textMuted))
        else
            btn:SetBackdropColor(Unpack(t.rowBg))
            btn:SetBackdropBorderColor(Unpack(t.rowBorder))
            btn.title:SetTextColor(Unpack(t.textNormal))
            btn.preview:SetTextColor(Unpack(t.textDim))
        end

        local scopeColor = (btn.scope == "character") and t.scopeCharacter or t.scopeAccount
        btn.accentBar:SetColorTexture(Unpack(scopeColor, btn.isSelected and 1 or 0.65))

        -- Badge and left bar share one colour, so the row reads as belonging to
        -- a scope rather than carrying two unrelated marks.
        btn.tagBg:SetColorTexture(Unpack(scopeColor, 0.22))
        btn.tag:SetTextColor(Unpack(NS.ColorLighten(scopeColor, 0.45)))
        btn.tagBg:SetWidth(math.max(34, (btn.tag:GetStringWidth() or 28) + 12))

        if btn.isPinned then
            btn.pinMark:Show()
            btn.pinMark:SetTextColor(Unpack(t.warning))
        else
            btn.pinMark:Hide()
        end

        -- A third state between shown and hidden: turned on, but held back by
        -- its display rules. Without this the list would report a note as on
        -- while nothing is on screen.
        if btn.isGated then
            btn.gateMark:Show()
        else
            btn.gateMark:Hide()
        end

        -- Revealed on hover only: a delete control on every row would be both
        -- permanent clutter and permanently one misclick from a lost note.
        if btn.isHovered then
            btn.deleteButton:Show()

            -- Alpha carries the hover feedback on its own, so this still reads
            -- correctly even if the template's own scripts overwrite the tint.
            btn.deleteButton:SetAlpha(btn.deleteHovered and 1 or 0.45)

            local tex = btn.deleteButton:GetNormalTexture()
            if tex then
                if btn.deleteHovered then
                    tex:SetVertexColor(1, 0.40, 0.40)
                else
                    tex:SetVertexColor(1, 1, 1)
                end
            end
        else
            btn.deleteButton:Hide()
        end
    end

    local function BuildPreviewText(note)
        local body = SafeTrim(NS.StripMarkup(note.body or ""))
        if body == "" then
            return "No content"
        end
        local firstLine = body:match("^[^\n]*") or body
        if #firstLine > 62 then
            firstLine = firstLine:sub(1, 62) .. "..."
        end
        return firstLine
    end

    local ROW_HEIGHT = 50
    local FOLDER_HEADER_HEIGHT = 30
    local UNFILED_FOLDER = NS.UNFILED_FOLDER or "Unfiled"

    -- ------------------------------------------------------------------
    -- Drag feedback
    --
    -- WoW gives a dragged frame no visual of its own, so without this the note
    -- stays where it is and the drag is invisible - you find out whether it
    -- worked by letting go. A label under the cursor says what is moving, and
    -- the folder under it lights up to say where it will land.
    -- ------------------------------------------------------------------

    frame.dragGhost = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame.dragGhost:SetFrameStrata("TOOLTIP")
    frame.dragGhost:SetSize(190, 24)
    frame.dragGhost:SetBackdrop(FLAT_BACKDROP)
    frame.dragGhost:Hide()

    frame.dragGhost.label = frame.dragGhost:CreateFontString(nil, "OVERLAY")
    frame.dragGhost.label:SetFont(DEFAULT_FONT_PATH, 12, "")
    frame.dragGhost.label:SetPoint("LEFT", 8, 0)
    frame.dragGhost.label:SetPoint("RIGHT", -8, 0)
    frame.dragGhost.label:SetJustifyH("LEFT")

    RegisterThemed(frame.dragGhost, function(self, t)
        self:SetBackdropColor(Unpack(t.windowBg, 0.95))
        self:SetBackdropBorderColor(Unpack(t.accent, 0.9))
    end)
    RegisterThemed(frame.dragGhost.label, function(self, t)
        self:SetTextColor(Unpack(t.textPrimary))
    end)

    frame.dragGhost:SetScript("OnUpdate", function(self)
        local scale = UIParent:GetEffectiveScale()
        local x, y = GetCursorPosition()
        self:ClearAllPoints()
        -- Offset down and right so the label never sits under the cursor.
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x / scale) + 12, (y / scale) - 6)
    end)

    function frame:BeginNoteDrag(note)
        self.draggingNote = note

        local title = SafeTrim(note.title or "")
        self.dragGhost.label:SetText(title ~= "" and title or "(untitled)")
        self.dragGhost:Show()
    end

    function frame:EndNoteDrag()
        self.draggingNote = nil
        self.dragGhost:Hide()
    end

    -- Right-click menu for filing one note. Acts on the note that was clicked
    -- rather than on the selection, so filing does not disturb whatever is
    -- currently open in the editor.
    local function ShowFolderMenu(note)
        if not note then return end

        local items = { { text = "Move to folder", isTitle = true } }

        table.insert(items, {
            text = UNFILED_FOLDER,
            isChecked = note.folder == nil,
            onClick = function()
                note.folder = nil
                frame:RefreshNoteList()
            end,
        })

        for _, name in ipairs((NS.GetFolders and NS.GetFolders()) or {}) do
            table.insert(items, {
                text = name,
                isChecked = note.folder == name,
                onClick = function()
                    note.folder = name
                    frame:RefreshNoteList()
                end,
            })
        end

        table.insert(items, {
            text = "|cff66aaffNew folder...|r",
            onClick = function()
                -- Remembered so the popup can file this note rather than
                -- whichever one happens to be selected.
                frame.pendingFolderNote = note
                StaticPopup_Show("MYNOTES_NEW_FOLDER")
            end,
        })

        NS.ShowContextMenu(nil, items)
    end

    -- Iterated in place of a collapsed folder's contents. A shared constant
    -- rather than a fresh {} each pass, since this runs on every keystroke in
    -- the search box.
    local EMPTY_BUCKET = {}

    -- A folder's header: a disclosure arrow, its name, and how many notes are
    -- under it. Clicking anywhere on it collapses or expands the folder.
    local function CreateFolderHeader(parent)
        local header = CreateFrame("Button", nil, parent)
        header:SetSize(250, FOLDER_HEADER_HEIGHT)

        -- A faint accent wash across the bar. At the old height a hairline was
        -- enough, but taller the empty space read as a gap in the list rather
        -- than as a heading for what follows - the fill gives the height
        -- something to be.
        header.bg = header:CreateTexture(nil, "BACKGROUND", nil, -2)
        header.bg:SetAllPoints()

        RegisterThemed(header.bg, function(self, t)
            self:SetColorTexture(Unpack(t.accent, 0.10))
        end)

        -- Blizzard's own expand/collapse art rather than a "+" or "-" drawn as
        -- text. A 10px glyph was barely a target and read as punctuation; these
        -- are the boxes every tree in the game uses, so they need no learning.
        header.toggle = header:CreateTexture(nil, "ARTWORK")
        header.toggle:SetPoint("LEFT", 7, 0)
        header.toggle:SetSize(16, 16)

        header.label = header:CreateFontString(nil, "OVERLAY")
        header.label:SetFont(DEFAULT_FONT_PATH, 13, "")
        header.label:SetPoint("LEFT", header.toggle, "RIGHT", 7, 0)
        header.label:SetJustifyH("LEFT")

        -- The count sits in a pill so it reads as a badge on the folder rather
        -- than as a stray number, and it now stays on screen instead of being
        -- swapped out for the delete button: with a folder shut, how many notes
        -- are inside is the one thing the bar still has to answer.
        header.countPill = header:CreateTexture(nil, "ARTWORK")
        header.countPill:SetPoint("RIGHT", -28, 0)
        header.countPill:SetSize(28, 17)

        RegisterThemed(header.countPill, function(self, t)
            self:SetColorTexture(Unpack(t.accent, 0.22))
        end)

        header.count = header:CreateFontString(nil, "OVERLAY")
        header.count:SetFont(DEFAULT_FONT_PATH, 12, "")
        header.count:SetPoint("CENTER", header.countPill, "CENTER", 0, 0)
        header.count:SetJustifyH("CENTER")

        -- A line along the bottom edge, full width now that the bar has a fill
        -- of its own to sit inside.
        header.rule = header:CreateTexture(nil, "ARTWORK")
        header.rule:SetPoint("BOTTOMLEFT", 0, 0)
        header.rule:SetPoint("BOTTOMRIGHT", 0, 0)
        header.rule:SetHeight(2)

        header.highlight = header:CreateTexture(nil, "HIGHLIGHT")
        header.highlight:SetAllPoints()
        header.highlight:SetColorTexture(1, 1, 1, 0.05)

        -- Shown only while a note is being dragged over this folder. A
        -- separate layer from the hover highlight, so "you are pointing at
        -- this" and "letting go files it here" do not look the same.
        header.dropGlow = header:CreateTexture(nil, "BACKGROUND")
        header.dropGlow:SetAllPoints()
        header.dropGlow:Hide()

        RegisterThemed(header.dropGlow, function(self, t)
            self:SetColorTexture(Unpack(t.accent, 0.28))
        end)

        RegisterThemed(header.label, function(self, t) self:SetTextColor(Unpack(t.accent)) end)
        RegisterThemed(header.count, function(self, t) self:SetTextColor(Unpack(t.textPrimary)) end)
        RegisterThemed(header.rule,  function(self, t) self:SetColorTexture(Unpack(t.accent, 0.45)) end)

        -- Hover-revealed so a row of delete buttons is not the first thing the
        -- eye lands on, but present the moment the pointer is on the folder.
        header.deleteButton = CreateFrame("Button", nil, header, "UIPanelCloseButton")
        header.deleteButton:SetSize(20, 20)
        header.deleteButton:SetPoint("RIGHT", -4, 0)
        NS.SoftenCloseButton(header.deleteButton)
        NS.AttachTooltip(header.deleteButton, "Delete folder",
            "Removes the folder. Notes inside it are kept and become Unfiled.")
        header.deleteButton:Hide()

        -- IsMouseOver rather than OnEnter/OnLeave. A child frame takes the
        -- mouse from its parent, so moving onto the delete button fired the
        -- header's OnLeave, which hid the button, which fired OnEnter again -
        -- the flicker, and the reason a click never landed on anything.
        -- IsMouseOver covers the header's whole rect, children included.
        header:SetScript("OnUpdate", function(self)
            local mouseOver = self:IsMouseOver()

            -- While dragging, every folder is a target and none of them should
            -- be offering a delete button under the cursor.
            local dragging = frame.draggingNote ~= nil
            local isDropTarget = dragging and mouseOver

            if isDropTarget ~= self.dropShown then
                self.dropShown = isDropTarget
                self.dropGlow:SetShown(isDropTarget)
                self.label:SetTextColor(Unpack(NS.GetTheme()[
                    isDropTarget and "accentBright" or "accent"]))
            end

            -- Unfiled is the absence of a folder, so it has nothing to delete.
            local showDelete = mouseOver and not dragging
                and self.folderName ~= UNFILED_FOLDER

            if showDelete ~= self.deleteShown then
                self.deleteShown = showDelete
                self.deleteButton:SetShown(showDelete)
            end
        end)

        header.deleteButton:SetScript("OnClick", function(self)
            local name = self:GetParent().folderName
            if not name then return end

            StaticPopup_Show("MYNOTES_DELETE_FOLDER", name, nil, { folder = name })
        end)

        function header:SetFolder(name, count, collapsed)
            self.folderName = name
            self.toggle:SetTexture(collapsed
                and "Interface\\Buttons\\UI-PlusButton-Up"
                or "Interface\\Buttons\\UI-MinusButton-Up")
            self.label:SetText(name)
            self.count:SetText(tostring(count))

            -- Reset per refresh: a header frame is reused for whichever folder
            -- lands at its position, and one recycled from a hovered or
            -- hovered-while-dragging row would keep that state.
            self.deleteShown = false
            self.dropShown = false
            self.deleteButton:Hide()
            self.dropGlow:Hide()
            self.label:SetTextColor(Unpack(NS.GetTheme().accent))
        end

        header:SetScript("OnClick", function(self)
            if NS.ToggleFolderCollapsed and self.folderName then
                NS.ToggleFolderCollapsed(self.folderName)
                frame:RefreshNoteList()
            end
        end)

        return header
    end
    local ROW_SPACING = 6

    function frame:RefreshNoteList()
        local allNotes = GetAllNotesForList()
        local filter = SafeTrim(frame.searchBox:GetText() or ""):lower()
        local scopeFilter = frame.scopeFilter or "all"

        for i, btn in ipairs(self.noteButtons) do
            btn:Hide()
        end

        for _, header in ipairs(self.folderHeaders) do
            header:Hide()
        end

        local yOffset = -6
        local visibleIndex = 0
        local totalCount = #allNotes

        -- Counted apart from visibleIndex, which only rises for rows actually
        -- drawn. Collapsing a folder drew fewer rows, so the count fell with
        -- them and read as though the notes had gone somewhere - a collapsed
        -- folder hides its notes, it does not remove them.
        local matchedCount = 0

        -- Filter first, then group. In this order a folder's count reflects
        -- what the search actually left in it, and a folder with no matches
        -- drops out of the list rather than sitting there as an empty header.
        local buckets = {}

        for _, entry in ipairs(allNotes) do
            local matchesScope = (scopeFilter == "all") or (entry.scope == scopeFilter)
            -- Search the rendered-out text, so "{gold}Bloodlust{/}" still
            -- matches a search for "bloodlust" rather than being hidden by tags.
            local haystack = ((entry.note.title or "") .. " " .. NS.StripMarkup(entry.note.body or "")):lower()
            local matchesSearch = filter == "" or haystack:find(filter, 1, true)

            if matchesScope and matchesSearch then
                matchedCount = matchedCount + 1
                local folder = entry.note.folder or UNFILED_FOLDER
                buckets[folder] = buckets[folder] or {}
                table.insert(buckets[folder], entry)
            end
        end

        -- Named folders in their stored order, then Unfiled last: it is the
        -- fallback rather than a category, so it belongs at the bottom.
        --
        -- With no search running, every folder is listed even when empty - a
        -- folder you just made has to be visible or there is nothing to file
        -- into and nothing to delete. Under a search, empty ones drop out:
        -- there the count means "matches", and a row of zeroes is noise.
        local searching = filter ~= ""
        local folderOrder = {}

        for _, name in ipairs((NS.GetFolders and NS.GetFolders()) or {}) do
            if buckets[name] then
                table.insert(folderOrder, name)
            elseif not searching then
                buckets[name] = EMPTY_BUCKET
                table.insert(folderOrder, name)
            end
        end
        if buckets[UNFILED_FOLDER] then
            table.insert(folderOrder, UNFILED_FOLDER)
        end

        -- With everything in one folder there is nothing for headers to
        -- separate, so they are left out entirely and the list reads exactly as
        -- it did before folders existed.
        local showHeaders = #folderOrder > 1
        local headerIndex = 0

        for _, folderName in ipairs(folderOrder) do
          local bucket = buckets[folderName]
          local collapsed = showHeaders and NS.IsFolderCollapsed
              and NS.IsFolderCollapsed(folderName) or false

          if showHeaders then
              headerIndex = headerIndex + 1
              local header = self.folderHeaders[headerIndex]

              if not header then
                  header = CreateFolderHeader(self.scrollChild)
                  self.folderHeaders[headerIndex] = header
              end

              header:SetFolder(folderName, #bucket, collapsed)
              header:ClearAllPoints()
              header:SetPoint("TOPLEFT", 4, yOffset)
              header:Show()

              yOffset = yOffset - (FOLDER_HEADER_HEIGHT + 5)
          end

          for _, entry in ipairs(collapsed and EMPTY_BUCKET or bucket) do
            do
                visibleIndex = visibleIndex + 1
                local btn = self.noteButtons[visibleIndex]

                if not btn then
                    btn = CreateFrame("Button", nil, self.scrollChild, "BackdropTemplate")
                    btn:SetSize(250, ROW_HEIGHT)
                    btn:SetBackdrop(FLAT_BACKDROP)

                    btn.accentBar = btn:CreateTexture(nil, "ARTWORK")
                    btn.accentBar:SetPoint("TOPLEFT", 0, 0)
                    btn.accentBar:SetPoint("BOTTOMLEFT", 0, 0)
                    btn.accentBar:SetWidth(3)

                    btn.title = btn:CreateFontString(nil, "OVERLAY")
                    btn.title:SetFont(DEFAULT_FONT_PATH, 13, "")
                    btn.title:SetPoint("TOPLEFT", 14, -8)
                    btn.title:SetPoint("TOPRIGHT", -46, -8)
                    btn.title:SetJustifyH("LEFT")
                    btn.title:SetWordWrap(false)

                    -- Right inset leaves room for the hover delete button.
                    btn.preview = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    btn.preview:SetPoint("TOPLEFT", 14, -26)
                    btn.preview:SetPoint("BOTTOMRIGHT", -30, 7)
                    btn.preview:SetJustifyH("LEFT")
                    btn.preview:SetJustifyV("TOP")

                    -- Scope badge: a filled pill in the scope's own colour,
                    -- matching the bar down the row's left edge. Grey text in
                    -- the corner didn't tie the two signals together.
                    btn.tagBg = btn:CreateTexture(nil, "ARTWORK")
                    btn.tagBg:SetPoint("TOPRIGHT", -8, -7)
                    btn.tagBg:SetHeight(14)

                    btn.tag = btn:CreateFontString(nil, "OVERLAY")
                    btn.tag:SetFont(DEFAULT_FONT_PATH, 10, "")
                    btn.tag:SetPoint("CENTER", btn.tagBg, "CENTER", 0, 0)

                    -- Pinned is its own signal now. It used to share the tag's
                    -- colour, which meant scope and pinned state competed for
                    -- the same pixel.
                    btn.pinMark = btn:CreateFontString(nil, "OVERLAY")
                    btn.pinMark:SetFont(DEFAULT_FONT_PATH, 13, "")
                    btn.pinMark:SetPoint("RIGHT", btn.tagBg, "LEFT", -5, 0)
                    btn.pinMark:SetText("*")

                    btn.gateMark = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    btn.gateMark:SetPoint("BOTTOMRIGHT", -28, 6)
                    btn.gateMark:SetText("rules")
                    btn.gateMark:Hide()

                    -- UIPanelCloseButton rather than a font glyph: the "x"
                    -- character this first used didn't render in the addon's
                    -- font, and this template is already drawing correctly as
                    -- the window's own close button.
                    btn.deleteButton = CreateFrame("Button", nil, btn, "UIPanelCloseButton")
                    btn.deleteButton:SetSize(20, 20)
                    btn.deleteButton:SetPoint("BOTTOMRIGHT", -3, 2)
                    btn.deleteButton:Hide()

                    btn:SetScript("OnEnter", function(self)
                        self.isHovered = true
                        ApplyRowVisual(self)
                    end)
                    btn:SetScript("OnLeave", function(self)
                        self.isHovered = false
                        ApplyRowVisual(self)
                    end)

                    -- The row stays hovered while the pointer is on its delete
                    -- button, so the button doesn't vanish as you reach for it.
                    btn.deleteButton:SetScript("OnEnter", function(self)
                        local row = self:GetParent()
                        row.isHovered = true
                        row.deleteHovered = true
                        ApplyRowVisual(row)
                    end)
                    btn.deleteButton:SetScript("OnLeave", function(self)
                        local row = self:GetParent()
                        row.deleteHovered = false
                        ApplyRowVisual(row)
                    end)

                    self.noteButtons[visibleIndex] = btn
                end

                local displayTitle = SafeTrim(entry.note.title or "")
                if displayTitle == "" then
                    displayTitle = "(untitled)"
                end
                btn.title:SetText(displayTitle)
                btn.preview:SetText(BuildPreviewText(entry.note))

                btn.tag:SetText(entry.scope == "character" and "CHAR" or "ACCT")

                btn.scope = entry.scope
                btn.isPinned = entry.note.pinned and true or false
                btn.isGated = NS.IsNoteGated and NS.IsNoteGated(entry.note) or false
                btn.isSelected = (NS.selectedNote
                    and NS.selectedNote.id == entry.note.id
                    and NS.selectedScope == entry.scope) and true or false
                ApplyRowVisual(btn)

                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", 4, yOffset)
                btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                btn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        ShowFolderMenu(entry.note)
                        return
                    end

                    GuardUnsavedChanges(function()
                        -- Clicking the selected note again clears the selection.
                        if self.isSelected then
                            ClearEditor()
                        else
                            LoadNoteIntoEditor(entry.scope, entry.note)
                        end
                        frame:RefreshNoteList()
                    end)
                end)

                -- Dragging a note onto a folder header files it there. The
                -- header under the cursor is looked up on drop, since WoW has
                -- no notion of a drop target a frame can register as.
                btn:RegisterForDrag("LeftButton")
                btn:SetScript("OnDragStart", function(self)
                    frame:BeginNoteDrag(entry.note)
                    -- The row fades rather than moving: it is still the note's
                    -- place in the list, and the ghost under the cursor is what
                    -- represents the thing being carried.
                    self:SetAlpha(0.4)
                end)
                btn:SetScript("OnDragStop", function(self)
                    self:SetAlpha(1)

                    local note = frame.draggingNote
                    frame:EndNoteDrag()
                    if not note then return end

                    for _, header in ipairs(frame.folderHeaders) do
                        if header:IsShown() and header:IsMouseOver() then
                            local target = header.folderName
                            note.folder = (target ~= UNFILED_FOLDER) and target or nil
                            break
                        end
                    end

                    -- Dropped anywhere that is not a folder leaves the note
                    -- where it was, rather than guessing at an intent.
                    frame:RefreshNoteList()
                end)

                btn.deleteButton:SetScript("OnClick", function()
                    local noteTitle = SafeTrim(entry.note.title or "")
                    if noteTitle == "" then
                        noteTitle = "(untitled)"
                    end

                    StaticPopup_Show("MYNOTES_CONFIRM_DELETE", noteTitle, nil, {
                        scope = entry.scope,
                        note = entry.note,
                        onDeleted = function()
                            -- Only wipe the editor if the note just deleted was
                            -- the one loaded into it.
                            if NS.selectedNote == entry.note then
                                ClearEditor()
                            end
                            frame:RefreshNoteList()
                        end,
                    })
                end)
                btn:Show()

                yOffset = yOffset - (ROW_HEIGHT + ROW_SPACING)
            end
          end
        end

        -- Headers left over from a previous refresh, when there were more
        -- folders on screen than there are now.
        for index = headerIndex + 1, #self.folderHeaders do
            self.folderHeaders[index]:Hide()
        end

        self.scrollChild:SetHeight(math.max(1, math.abs(yOffset) + 10))

        if matchedCount == 0 then
            if totalCount == 0 then
                frame.emptyStateText:SetText("No notes yet.\nClick New below to create one.")
            else
                frame.emptyStateText:SetText("No notes match your search.")
            end
            frame.emptyStateText:Show()
        else
            frame.emptyStateText:Hide()
        end

        frame.listCountText:SetText(matchedCount .. " of " .. totalCount .. " notes")
        frame.subtitle:SetText(totalCount == 1 and "1 note" or (totalCount .. " notes"))
    end

    frame.newButton:SetScript("OnClick", function()
        GuardUnsavedChanges(function()
            frame.newNotePopup:Show()
        end)
    end)

    frame.saveButton:SetScript("OnClick", function()
        SaveCurrentEditor()
    end)

    frame.deleteButton:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        local noteTitle = SafeTrim(NS.selectedNote.title or "")
        if noteTitle == "" then
            noteTitle = "(untitled)"
        end

        StaticPopup_Show("MYNOTES_CONFIRM_DELETE", noteTitle, nil, {
            scope = NS.selectedScope,
            note = NS.selectedNote,
            onDeleted = function()
                ClearEditor()
                frame:RefreshNoteList()
            end,
        })
    end)

    frame.duplicateButton:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        GuardUnsavedChanges(function()
            local copy = DuplicateNote(NS.selectedScope, NS.selectedNote)
            if copy then
                LoadNoteIntoEditor(NS.selectedScope, copy)
                frame:RefreshNoteList()
            end
        end)
    end)

    frame.toggleVisibleButton:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        NS.selectedNote.visible = not NS.selectedNote.visible
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        LoadNoteIntoEditor(NS.selectedScope, NS.selectedNote)
        frame:RefreshNoteList()
    end)

    frame.lockToggle:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        NS.selectedNote.locked = not NS.selectedNote.locked
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        LoadNoteIntoEditor(NS.selectedScope, NS.selectedNote)
        frame:RefreshNoteList()
    end)

    frame.moveScopeButton:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        GuardUnsavedChanges(function()
            local oldScope = NS.selectedScope
            local newScope = oldScope == "account" and "character" or "account"
            local movedNote = DuplicateNote(newScope, NS.selectedNote)
            if not movedNote then return end

            movedNote.title = NS.selectedNote.title
            movedNote.body = NS.selectedNote.body
            movedNote.visible = NS.selectedNote.visible
            movedNote.locked = NS.selectedNote.locked
            movedNote.width = NS.selectedNote.width
            movedNote.height = NS.selectedNote.height
            movedNote.point = NS.selectedNote.point
            movedNote.relativePoint = NS.selectedNote.relativePoint
            movedNote.x = NS.selectedNote.x
            movedNote.y = NS.selectedNote.y
            movedNote.fontSize = NS.selectedNote.fontSize
            movedNote.pinned = NS.selectedNote.pinned
            movedNote.bgAlpha = NS.selectedNote.bgAlpha

            HideFloatingNote(oldScope, NS.selectedNote)
            DeleteNote(oldScope, NS.selectedNote.id)

            NS.selectedNote = movedNote
            NS.selectedScope = newScope

            if movedNote.visible then
                ShowFloatingNote(newScope, movedNote)
            end

            LoadNoteIntoEditor(newScope, movedNote)
            frame:RefreshNoteList()
        end)
    end)

    frame.pinToggle:SetScript("OnClick", function()
        if not NS.selectedNote then return end

        NS.selectedNote.pinned = not (NS.selectedNote.pinned == true)
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        LoadNoteIntoEditor(NS.selectedScope, NS.selectedNote)
        frame:RefreshNoteList()
    end)

    frame.fontSizeSlider.OnValueChangedCallback = function(value)
        if not NS.selectedNote then return end
        NS.selectedNote.fontSize = Clamp(math.floor(value + 0.5), NOTE_FONT_MIN, NOTE_FONT_MAX)
        frame.fontSizeValue:SetText(NS.selectedNote.fontSize .. "px")
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
        frame.UpdatePreview()
    end

    frame.opacitySlider.OnValueChangedCallback = function(value)
        if not NS.selectedNote then return end
        NS.selectedNote.bgAlpha = Clamp(math.floor(value + 0.5), 0, 100)
        frame.opacityValue:SetText(NS.selectedNote.bgAlpha .. "%")
        RefreshFloatingNote(NS.selectedScope, NS.selectedNote)
    end

    frame:SetScript("OnShow", function(self)
        -- Measured here because a frame that has never been shown has no
        -- resolved geometry to measure.
        if frame.UpdateSettingsContentHeight then
            frame:UpdateSettingsContentHeight()
        end
        -- Re-run in case the panel had no resolved width when the toolbar was
        -- first built; buttons never positioned would otherwise stack at zero.
        if frame.LayoutMarkupBar then frame.LayoutMarkupBar() end
        frame.searchBox:SetText(MyNotesDB.settings.searchText or "")
        if frame.searchPlaceholder and (frame.searchBox:GetText() or "") ~= "" then
            frame.searchPlaceholder:Hide()
        end
        if frame.UpdateFilterTabs then
            frame.UpdateFilterTabs()
        end
        self:RefreshNoteList()
        UpdateSelectedInfo(NS.selectedScope, NS.selectedNote)
    end)

    return frame
end

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

local function ToggleManager()
    if not NS.managerFrame then return end

    if NS.managerFrame:IsShown() then
        NS.managerFrame:Hide()
    else
        NS.managerFrame:Show()
    end
end

-- Deliberately a single command with no subcommands: everything the addon can
-- do is reachable from the manager window, so there is nothing a subcommand
-- would be the only way to get at.
SLASH_MYNOTES1 = "/mn"
SLASH_MYNOTES2 = "/mynotes"
SlashCmdList["MYNOTES"] = function()
    ToggleManager()
end

NS.CreateManagerFrame = CreateManagerFrame
NS.ToggleManager = ToggleManager
