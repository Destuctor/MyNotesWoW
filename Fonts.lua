local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- FONTS
--
-- Font choices are stored by *name*, never by path. A path is a detail of
-- where a file happens to live; a name survives the user installing or
-- removing font packs, and is what LibSharedMedia deals in.
--
-- LibSharedMedia-3.0 is used when present but is not required. Without it the
-- four fonts shipped with the client are still offered, so the feature works
-- on a bare install.
-- ============================================================================

local DEFAULT_FONT_NAME = "Arial Narrow"
local FALLBACK_PATH = "Fonts\\ARIALN.TTF"

local BUILTIN_FONTS = {
    { name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
    { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
    { name = "Skurri",        path = "Fonts\\SKURRI.TTF" },
}

NS.DEFAULT_FONT_NAME = DEFAULT_FONT_NAME

local function GetSharedMedia()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- Publish our built-ins to LibSharedMedia so other addons can offer them too.
-- Registering the same name twice is harmless, so this can run more than once.
local function RegisterBuiltinsWithSharedMedia()
    local LSM = GetSharedMedia()
    if not LSM then return end

    for _, font in ipairs(BUILTIN_FONTS) do
        LSM:Register("font", font.name, font.path)
    end
end

NS.RegisterFontsWithSharedMedia = RegisterBuiltinsWithSharedMedia

-- Sorted list of every font name available right now.
--
-- Queried fresh each call rather than cached: LibSharedMedia gains fonts as
-- other addons load and register theirs, so a list captured at startup would
-- be missing anything registered after us.
function NS.GetFontList()
    local seen, names = {}, {}

    for _, font in ipairs(BUILTIN_FONTS) do
        if not seen[font.name] then
            seen[font.name] = true
            table.insert(names, font.name)
        end
    end

    local LSM = GetSharedMedia()
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            if not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end

    table.sort(names)
    return names
end

-- Resolve a name to a usable font path, falling back rather than erroring:
-- a note referencing a font from an addon the user has since removed should
-- still render, just in the default face.
function NS.GetFontPath(name)
    if not name then
        return FALLBACK_PATH
    end

    for _, font in ipairs(BUILTIN_FONTS) do
        if font.name == name then
            return font.path
        end
    end

    local LSM = GetSharedMedia()
    if LSM then
        local path = LSM:Fetch("font", name, true)
        if path then
            return path
        end
    end

    return FALLBACK_PATH
end

-- Apply a font to a FontString, guaranteeing it ends up with one.
--
-- A SetFont that can't load its file leaves the FontString with no font at
-- all, after which every SetText on it errors with "Font not set". Since most
-- fonts here arrive from other addons via LibSharedMedia, an unloadable path
-- is a real possibility rather than a theoretical one.
--
-- Success is checked by reading the font back, NOT from SetFont's return
-- value: that return is unreliable across client versions, and on a client
-- where it returns nothing at all, a `if not SetFont(...)` guard fires its
-- fallback every single time and silently pins everything to one font.
function NS.ApplyFont(fontString, path, size, flags)
    if not fontString then return end

    flags = flags or ""
    fontString:SetFont(path or FALLBACK_PATH, size, flags)

    if not fontString:GetFont() then
        fontString:SetFont(FALLBACK_PATH, size, flags)
    end
end

-- The font a given note should render in: its own override, else the global
-- note font, else the default.
function NS.GetNoteFontName(note)
    if note and note.font then
        return note.font
    end

    local settings = MyNotesDB and MyNotesDB.settings
    return (settings and settings.noteFont) or DEFAULT_FONT_NAME
end

function NS.GetNoteFontPath(note)
    return NS.GetFontPath(NS.GetNoteFontName(note))
end
