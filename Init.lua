local addonName = ...
local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS
local InitDB = NS.InitDB
local MigrateAll = NS.MigrateAll
local NormalizeAllNotes = NS.NormalizeAllNotes
local RestoreVisibleNotes = NS.RestoreVisibleNotes
local RefreshVisibleNotes = NS.RefreshVisibleNotes
local CreateManagerFrame = NS.CreateManagerFrame
local CreateMinimapLauncher = NS.CreateMinimapLauncher

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        InitDB()
        -- Migrations run before normalisation: they clear fields that older
        -- versions stored, and normalisation then fills in anything missing.
        MigrateAll()
        NormalizeAllNotes()
        NS.managerFrame = CreateManagerFrame()
        RestoreVisibleNotes()

        if CreateMinimapLauncher then
            CreateMinimapLauncher()
        end

        -- Offer our bundled fonts to any other addon using LibSharedMedia.
        if NS.RegisterFontsWithSharedMedia then
            NS.RegisterFontsWithSharedMedia()
        end

        -- A signpost in Options -> AddOns pointing at the addon's own settings
        -- window, since that's where people look first.
        if NS.RegisterBlizzardSettings then
            NS.RegisterBlizzardSettings()
        end

        -- Displayed notes aren't in the theme registry (they're created and
        -- destroyed as notes are shown and hidden), so a palette change has to
        -- redraw them explicitly or their chrome keeps the old colours.
        if NS.RegisterThemeCallback and RefreshVisibleNotes then
            NS.RegisterThemeCallback(RefreshVisibleNotes)
        end

        print("|cff00ff88MyNotes|r loaded. Type |cffffff00/mynotes|r to open.")

    elseif event == "PLAYER_LOGIN" then
        -- Everything above ran at ADDON_LOADED, which is before player data and
        -- the spell/item caches can be relied on. On a /reload they happen to be
        -- warm already, so problems here only ever show up on a cold login.
        --
        -- Two things therefore get a second pass now: the theme, because the
        -- class palette needs UnitClass("player"), and any visible note, because
        -- its icon tags may not have resolved the first time.
        if NS.RefreshTheme then
            NS.RefreshTheme()
        end

        if RefreshVisibleNotes then
            RefreshVisibleNotes()
        end

        -- Started at PLAYER_LOGIN rather than ADDON_LOADED: conditions query
        -- zone, instance and combat state, none of which are settled earlier.
        if NS.StartConditionWatcher then
            NS.StartConditionWatcher()
        end

        if NS.StartDynamicTextWatcher then
            NS.StartDynamicTextWatcher()
        end

        if NS.StartUnlockModifierWatcher then
            NS.StartUnlockModifierWatcher()
        end

        if NS.ApplyStackLayout then
            NS.ApplyStackLayout()
        end
    end
end)
