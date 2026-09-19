local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- MINIMAP BUTTON
--
-- Built on LibDataBroker-1.1 + LibDBIcon-1.0 (bundled in Libs/). The LDB
-- object below is the "data source" - it just describes what the button
-- looks like and what it does. LibDBIcon-1.0 is the library that actually
-- turns that description into a draggable icon on the minimap.
-- ============================================================================

local function CreateMinimapLauncher()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)

    if not LDB or not icon then
        -- Libraries failed to load for some reason; fail quietly rather
        -- than error, since the minimap button is a nice-to-have, not
        -- something the rest of the addon depends on.
        return
    end

    local dataObject = LDB:NewDataObject("MyNotes", {
        type = "launcher",
        text = "MyNotes",
        -- Must be .tga or .blp - the WoW client cannot load .png textures.
        icon = "Interface\\AddOns\\MyNotes\\Media\\icon.tga",

        OnClick = function(self, button)
            if button == "LeftButton" then
                NS.ToggleManager()
            end
        end,

        OnTooltipShow = function(tooltip)
            tooltip:AddLine("MyNotes")
            tooltip:AddLine(" ")
            tooltip:AddLine("|cff1eff00Left-click|r to open the note manager", 0.9, 0.9, 0.9)
            tooltip:AddLine("|cff1eff00Drag|r to move this button", 0.9, 0.9, 0.9)
        end,
    })

    icon:Register("MyNotes", dataObject, MyNotesDB.settings.minimap)

    NS.minimapIcon = icon
end

NS.CreateMinimapLauncher = CreateMinimapLauncher
