local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- THEME / PALETTE SYSTEM
--
-- Every colour the manager UI draws comes from a named token in a palette
-- table, rather than being written inline at the call site. That means adding
-- a new look (class colours, a lighter theme, a seasonal one) is a matter of
-- describing a palette here - no widget code has to change.
--
-- Widgets opt in by calling NS.RegisterThemed(widget, applyFn). The apply
-- function is run once immediately, and again for every widget whenever the
-- active palette changes, so a theme switch re-skins the open window live
-- without a /reload.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Colour helpers. Colours are {r, g, b} or {r, g, b, a} with 0-1 components.
-- ---------------------------------------------------------------------------

local function Mix(a, b, t)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
        a[4] or 1,
    }
end

local function Lighten(color, t)
    return Mix(color, { 1, 1, 1, color[4] or 1 }, t)
end

local function Darken(color, t)
    return Mix(color, { 0, 0, 0, color[4] or 1 }, t)
end

local function WithAlpha(color, alpha)
    return { color[1], color[2], color[3], alpha }
end

NS.ColorMix = Mix
NS.ColorLighten = Lighten
NS.ColorDarken = Darken
NS.ColorWithAlpha = WithAlpha

-- Unpack a token into the r, g, b, a argument list the WoW API wants.
-- `alphaOverride` lets a call site reuse a token at a different opacity.
function NS.Unpack(color, alphaOverride)
    if not color then return 1, 1, 1, 1 end
    return color[1], color[2], color[3], alphaOverride or color[4] or 1
end

-- "ffRRGGBB", for building |c escape sequences inside a single string - used
-- where one FontString needs more than one colour.
function NS.ColorToHex(color)
    if not color then return "ffffffff" end
    return string.format("ff%02x%02x%02x",
        math.floor(math.min(1, math.max(0, color[1])) * 255 + 0.5),
        math.floor(math.min(1, math.max(0, color[2])) * 255 + 0.5),
        math.floor(math.min(1, math.max(0, color[3])) * 255 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Neutral (non-accent) tokens shared by the dark palettes. Splitting these out
-- means a new accent-based palette only has to describe its accent.
-- ---------------------------------------------------------------------------

local function DarkNeutrals()
    return {
        windowBg     = { 0.030, 0.035, 0.045, 0.980 },
        windowBorder = { 0.170, 0.190, 0.240, 1.000 },
        headerBg     = { 0.075, 0.090, 0.130, 0.950 },

        -- Three elevation steps: the window floor, the panels sitting on it,
        -- and the rows/controls sitting on the panels. Keeping these distinct
        -- is what gives the layout its sense of depth.
        panelBg      = { 0.065, 0.075, 0.100, 0.940 },
        panelTop     = { 0.100, 0.120, 0.170, 0.550 },
        panelBorder  = { 0.160, 0.190, 0.250, 0.900 },

        rowBg        = { 0.075, 0.085, 0.110, 0.900 },
        rowBorder    = { 0.150, 0.170, 0.230, 0.850 },
        rowHoverBg   = { 0.105, 0.120, 0.155, 0.950 },

        inputBg      = { 0.035, 0.040, 0.055, 0.960 },
        inputBorder  = { 0.180, 0.210, 0.280, 0.950 },

        btnBg        = { 0.120, 0.140, 0.190, 0.950 },
        btnDangerBg  = { 0.550, 0.160, 0.180, 0.950 },

        toggleOffBg     = { 0.090, 0.100, 0.140, 0.880 },
        toggleOffBorder = { 0.170, 0.200, 0.260, 0.850 },

        sliderTrack  = { 0.140, 0.160, 0.210, 0.950 },
        sliderThumb  = { 0.940, 0.970, 1.000, 1.000 },

        textBright   = { 0.960, 0.980, 1.000 },
        textPrimary  = { 0.920, 0.960, 1.000 },
        textNormal   = { 0.850, 0.890, 0.950 },
        textMuted    = { 0.500, 0.560, 0.650 },
        textDim      = { 0.450, 0.500, 0.580 },

        warning      = { 0.950, 0.750, 0.350 },
        divider      = { 1.000, 1.000, 1.000, 0.060 },

        scopeAccount   = { 0.350, 0.600, 0.950 },
        scopeCharacter = { 0.680, 0.500, 0.920 },
    }
end

-- Derive every accent-tinted token from a single base accent colour, so a
-- palette can be defined by its accent alone.
--
-- These darkness levels carry the window's visual hierarchy, so the spread
-- between them matters as much as the values. Only the primary button gets a
-- full-strength fill; it should be the one loud accent moment on screen.
-- Everything that merely reports *state* - which row is selected, which tab is
-- active, which toggle is on - sits far darker and lets a small bright element
-- (an accent bar, an underline, an indicator dot) carry the signal instead.
-- They were previously spread over 32%-47%, too narrow to read as a hierarchy:
-- four different meanings all shouted at the same volume.
local function ApplyAccent(palette, accent)
    palette.accent       = { accent[1], accent[2], accent[3], 1 }
    palette.accentBright = Lighten(accent, 0.35)
    palette.accentDeep   = Darken(accent, 0.38)

    -- The one full-strength fill.
    palette.btnPrimaryBg   = WithAlpha(Darken(accent, 0.28), 0.960)

    -- State indicators: dark tints, paired with a bright accent detail. Dark
    -- enough that near-white text on them is comfortably legible.
    palette.rowSelBg       = WithAlpha(Darken(accent, 0.74), 0.960)
    palette.rowSelBorder   = WithAlpha(Lighten(accent, 0.10), 0.850)
    palette.toggleOnBg     = WithAlpha(Darken(accent, 0.72), 0.920)
    palette.toggleOnBorder = WithAlpha(Lighten(accent, 0.30), 0.900)
    palette.tabActiveBg    = WithAlpha(Darken(accent, 0.78), 0.850)

    palette.sliderFill     = WithAlpha(accent, 0.900)

    -- Text that sits on top of an accent-filled surface.
    palette.textOnAccent = Lighten(accent, 0.85)

    return palette
end

local function BuildPalette(name, accent, overrides)
    local palette = DarkNeutrals()
    palette.name = name
    ApplyAccent(palette, accent)

    if overrides then
        for k, v in pairs(overrides) do
            palette[k] = v
        end
    end

    return palette
end

-- ---------------------------------------------------------------------------
-- Palette definitions
-- ---------------------------------------------------------------------------

local PALETTES = {}
local PALETTE_ORDER = {}

local function DefinePalette(key, name, accentOrBuilder, overrides)
    PALETTES[key] = { name = name, accent = accentOrBuilder, overrides = overrides }
    table.insert(PALETTE_ORDER, key)
end

DefinePalette("midnight", "Midnight",  { 0.35, 0.60, 0.95 })
DefinePalette("ember",    "Ember",     { 0.95, 0.48, 0.22 })
DefinePalette("verdant",  "Verdant",   { 0.36, 0.78, 0.48 })
DefinePalette("amethyst", "Amethyst",  { 0.68, 0.50, 0.92 })

-- "class" resolves against whoever is logged in, so it is a function rather
-- than a fixed colour and is evaluated lazily (see ResolvePalette).
DefinePalette("class", "Class Colour", function()
    local _, class = UnitClass("player")
    local colors = (C_ClassColor and C_ClassColor.GetClassColor and class)
        and C_ClassColor.GetClassColor(class)
        or (RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class])

    if colors and colors.r then
        return { colors.r, colors.g, colors.b }
    end

    return { 0.35, 0.60, 0.95 }
end)

NS.PALETTE_ORDER = PALETTE_ORDER

function NS.GetPaletteList()
    local list = {}
    for _, key in ipairs(PALETTE_ORDER) do
        table.insert(list, { key = key, name = PALETTES[key].name })
    end
    return list
end

-- The accent a palette resolves to, for drawing preview swatches.
function NS.GetPaletteAccent(key)
    local def = PALETTES[key]
    if not def then return { 0.35, 0.60, 0.95 } end

    local accent = def.accent
    if type(accent) == "function" then
        accent = accent()
    end
    return accent
end

-- ---------------------------------------------------------------------------
-- Active theme + live re-skinning
-- ---------------------------------------------------------------------------

local activePalette = nil
local activeKey = nil
local registry = {}

local function ResolvePalette(key)
    local def = PALETTES[key] or PALETTES.midnight
    local accent = def.accent
    if type(accent) == "function" then
        accent = accent()
    end
    return BuildPalette(def.name, accent, def.overrides)
end

function NS.GetThemeKey()
    if activeKey then return activeKey end
    local saved = MyNotesDB and MyNotesDB.settings and MyNotesDB.settings.theme
    if saved and PALETTES[saved] then
        return saved
    end
    return "midnight"
end

function NS.GetTheme()
    if not activePalette then
        activeKey = NS.GetThemeKey()
        activePalette = ResolvePalette(activeKey)
    end
    return activePalette
end

-- Register a widget to be skinned now and re-skinned on every theme change.
function NS.RegisterThemed(widget, applyFn)
    if not widget or type(applyFn) ~= "function" then return end
    table.insert(registry, { widget = widget, apply = applyFn })
    applyFn(widget, NS.GetTheme())
end

-- Register work that isn't tied to one widget (e.g. redrawing a dynamic list).
function NS.RegisterThemeCallback(callback)
    if type(callback) ~= "function" then return end
    table.insert(registry, { callback = callback })
end

-- Re-resolve the active palette and re-apply it everywhere.
--
-- The "class" palette reads UnitClass("player"), which is not reliably
-- populated at ADDON_LOADED - and GetTheme caches the resolved palette, so a
-- failed lookup there would stick for the whole session. PLAYER_LOGIN is the
-- first point player data can be trusted, so the theme is resolved again then.
-- Harmless for the static palettes; they simply re-apply identical colours.
function NS.RefreshTheme()
    return NS.SetTheme(NS.GetThemeKey())
end

function NS.SetTheme(key)
    if not PALETTES[key] then
        return false
    end

    activeKey = key
    activePalette = ResolvePalette(key)

    if MyNotesDB and MyNotesDB.settings then
        MyNotesDB.settings.theme = key
    end

    for _, entry in ipairs(registry) do
        if entry.callback then
            entry.callback(activePalette)
        elseif entry.widget then
            entry.apply(entry.widget, activePalette)
        end
    end

    return true
end
