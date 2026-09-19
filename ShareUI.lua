local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- SHARE WINDOW
--
-- One box serving both directions: it shows the selected note's string ready
-- to copy, and accepts a pasted one to import. Two separate windows for what
-- is the same box of text would be ceremony for its own sake.
-- ============================================================================

local DEFAULT_FONT_PATH = NS.DEFAULT_FONT_PATH or "Fonts\\ARIALN.TTF"
local Unpack = NS.Unpack
local RegisterThemed = NS.RegisterThemed

local PANEL_WIDTH = 460
local shareFrame = nil

local function CreateShareFrame()
    if shareFrame then return shareFrame end

    local panel = CreateFrame("Frame", "MyNotesShareFrame", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 340)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop(NS.FLAT_BACKDROP)
    panel:Hide()

    panel.title = panel:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.title, DEFAULT_FONT_PATH, 18)
    panel.title:SetPoint("TOPLEFT", 20, -16)
    panel.title:SetText("Share Note")

    panel.hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.hint:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    panel.hint:SetText("Select all, then Ctrl-C. Paste a string here and press Import.")
    RegisterThemed(panel.hint, function(self, t)
        self:SetTextColor(Unpack(t.textDim))
    end)

    panel.headerLine = panel:CreateTexture(nil, "ARTWORK")
    panel.headerLine:SetPoint("TOPLEFT", 20, -58)
    panel.headerLine:SetPoint("TOPRIGHT", -20, -58)
    NS.StyleDialog(panel, panel.title, panel.headerLine)

    panel.closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    panel.closeButton:SetPoint("TOPRIGHT", -6, -6)
    NS.SoftenCloseButton(panel.closeButton)
    panel.closeButton:SetScript("OnClick", function() panel:Hide() end)

    -- Text box
    panel.boxBackdrop = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    panel.boxBackdrop:SetPoint("TOPLEFT", 20, -76)
    panel.boxBackdrop:SetPoint("BOTTOMRIGHT", -20, 78)
    panel.boxBackdrop:SetBackdrop(NS.FLAT_BACKDROP)
    RegisterThemed(panel.boxBackdrop, function(self, t)
        self:SetBackdropColor(Unpack(t.inputBg))
        self:SetBackdropBorderColor(Unpack(t.inputBorder))
    end)

    panel.scroll = CreateFrame("ScrollFrame", nil, panel.boxBackdrop, "UIPanelScrollFrameTemplate")
    panel.scroll:SetPoint("TOPLEFT", 8, -8)
    panel.scroll:SetPoint("BOTTOMRIGHT", -28, 8)

    panel.edit = CreateFrame("EditBox", nil, panel.scroll)
    panel.edit:SetMultiLine(true)
    panel.edit:SetAutoFocus(false)
    NS.ApplyFont(panel.edit, DEFAULT_FONT_PATH, 12)
    panel.edit:SetWidth(PANEL_WIDTH - 76)
    panel.edit:SetJustifyH("LEFT")
    panel.edit:SetJustifyV("TOP")
    panel.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.edit:SetScript("OnTextChanged", function(self)
        self:GetParent():UpdateScrollChildRect()
    end)
    panel.scroll:SetScrollChild(panel.edit)
    NS.AutoHideScrollBar(panel.scroll)
    NS.StyleScrollBar(panel.scroll)

    RegisterThemed(panel.edit, function(self, t)
        self:SetTextColor(Unpack(t.textNormal))
    end)

    -- Status
    panel.status = panel:CreateFontString(nil, "OVERLAY")
    NS.ApplyFont(panel.status, DEFAULT_FONT_PATH, 12)
    panel.status:SetPoint("BOTTOMLEFT", 20, 52)
    panel.status:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
    panel.status:SetJustifyH("LEFT")

    function panel:SetStatus(text, kind)
        local t = NS.GetTheme()
        self.status:SetText(text or "")

        if kind == "error" then
            self.status:SetTextColor(0.98, 0.45, 0.42)
        elseif kind == "success" then
            self.status:SetTextColor(0.45, 0.92, 0.60)
        else
            self.status:SetTextColor(Unpack(t.textDim))
        end
    end

    -- Buttons
    panel.selectButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.selectButton:SetPoint("BOTTOMLEFT", 20, 18)
    panel.selectButton:SetText("Select all")
    NS.StyleActionButton(panel.selectButton, 110, 26, false)
    panel.selectButton:SetScript("OnClick", function()
        panel.edit:SetFocus()
        panel.edit:HighlightText()
    end)

    panel.importButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.importButton:SetPoint("LEFT", panel.selectButton, "RIGHT", 8, 0)
    panel.importButton:SetText("Import")
    NS.StyleActionButton(panel.importButton, 110, 26, true)

    panel.importButton:SetScript("OnClick", function()
        local data, reason = NS.ParseNoteString(panel.edit:GetText())

        if not data then
            panel:SetStatus(reason or "Could not read that string.", "error")
            return
        end

        local scope = MyNotesDB.settings.newNoteScope or "account"
        local note = NS.ImportNote(data, scope)

        if not note then
            panel:SetStatus("Import failed.", "error")
            return
        end

        local title = NS.SafeTrim(note.title or "")
        panel:SetStatus(
            ("Imported \"%s\". It is turned off - use Show / Hide Note when you want it.")
                :format(title ~= "" and title or "(untitled)"),
            "success")

        local manager = NS.managerFrame
        if manager then
            if manager.LoadNoteIntoEditor then
                manager.LoadNoteIntoEditor(scope, note)
            end
            if manager.RefreshNoteList then
                manager:RefreshNoteList()
            end
        end
    end)

    NS.DockDialog(panel, "RIGHT")

    NS.MakeEscapeClosable(panel)

    shareFrame = panel
    return panel
end

function NS.ToggleShare()
    local panel = CreateShareFrame()

    if panel:IsShown() then
        panel:Hide()
        return
    end

    local note = NS.selectedNote

    if note and NS.ExportNote then
        panel.edit:SetText(NS.ExportNote(note) or "")
        panel:SetStatus("This note as a share code. Copy it, or paste another over it and press Import.")
    else
        panel.edit:SetText("")
        panel:SetStatus("Paste a MyNotes string here and press Import.")
    end

    panel:Dock()
    panel:Show()
end
