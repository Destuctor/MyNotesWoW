-- Note appearance: the two style axes, plus text colour, alignment and rails.
--
-- The guarantee that matters most is the first one: a note with nothing set
-- must be indistinguishable from one written before any of this existed.
-- Plain-text-on-screen is the addon's whole character.
-- Run with: lua-language-server.exe -E Tests/styles.lua
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"

GetTime = function() return 0 end
time = os.time
CreateFrame = function() return setmetatable({}, {__index = function() return function() end end}) end
UIParent = {}
C_Timer = { After = function() end }
C_DateAndTime = {}
issecretvalue = function() return false end
UnitExists = function() return false end
UnitClass = function() return "Mage", "MAGE" end
RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }

_G.MyNotesPrivate = {}
dofile(ADDON .. "Markup.lua")
dofile(ADDON .. "Core.lua")
dofile(ADDON .. "Share.lua")
local NS = _G.MyNotesPrivate

MyNotesDB = { notes = {}, settings = { nextID = 1, folders = {}, collapsedFolders = {},
    defaultNoteBackground = "none", defaultNoteEdge = "none" } }
MyNotesCharDB = { notes = {}, settings = { nextID = 1, folders = {}, collapsedFolders = {},
    defaultNoteBackground = "none", defaultNoteEdge = "none" } }

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
    end
end

-- ---- untouched notes carry nothing --------------------------------------
-- Every default is stored as absent rather than as its name, so an untouched
-- note gains no fields at all on save.
local note = NS.CreateNewNote("account")
for _, field in ipairs({ "background", "edge", "outline", "accent", "align", "textColor", "railSide" }) do
    check("new note has no " .. field, note[field], nil)
end

-- ---- the axes are independent -------------------------------------------
MyNotesDB.settings.defaultNoteBackground = "card"
MyNotesDB.settings.defaultNoteEdge = "border"
local both = NS.CreateNewNote("account")
check("background seeded", both.background, "card")
check("edge seeded", both.edge, "border")

MyNotesDB.settings.defaultNoteBackground = "none"
local edgeOnly = NS.CreateNewNote("account")
-- The combination the old single-style list could not express at all.
check("edge without background", edgeOnly.edge, "border")
check("no background with an edge", edgeOnly.background, nil)

MyNotesDB.settings.defaultNoteEdge = "none"

-- ---- v7 migration maps the old field exactly ----------------------------
local function migrated(style)
    MyNotesDB.dbVersion = 6
    MyNotesDB.notes = { { id = 1, style = style } }
    NS.MigrateAll()
    return MyNotesDB.notes[1]
end

local m = migrated("rail")
check("rail becomes an edge", m.edge, "rail")
check("rail sets no background", m.background, nil)

m = migrated("shade")
check("shade becomes a background", m.background, "shade")
check("shade sets no edge", m.edge, nil)

m = migrated("card")
check("card becomes a background", m.background, "card")

m = migrated(nil)
check("plain migrates to nothing", m.background, nil)
check("plain gains no edge", m.edge, nil)

-- The old field must not linger; nothing reads it any more.
check("old style field cleared", m.style, nil)
check("db version advanced", MyNotesDB.dbVersion, 8)

-- ---- v8 migration drops the retired shadow field -------------------------
MyNotesDB.dbVersion = 7
MyNotesDB.notes = { { id = 1, shadow = "strong", edge = "rail" } }
NS.MigrateAll()
check("shadow cleared", MyNotesDB.notes[1].shadow, nil)
check("the rest of the note survives", MyNotesDB.notes[1].edge, "rail")

-- ---- text colour ---------------------------------------------------------
local function rgb(n) return ("%d"):format(math.floor(n * 255 + 0.5)) end

local r, g, b = NS.ResolveNoteTextColor({})
check("no colour is white", rgb(r) .. "," .. rgb(g) .. "," .. rgb(b), "255,255,255")

r, g, b = NS.ResolveNoteTextColor({ textColor = "red" })
check("named colour resolves", rgb(r) .. "," .. rgb(g) .. "," .. rgb(b), "255,64,64")

r, g, b = NS.ResolveNoteTextColor({ textColor = NS.NOTE_TEXT_CLASS_COLOR })
check("class colour resolves live", rgb(r) .. "," .. rgb(g) .. "," .. rgb(b), "64,199,235")

-- An unknown name must fall back to white rather than to black, which would
-- read as a deliberate choice and be invisible on a dark background.
r, g, b = NS.ResolveNoteTextColor({ textColor = "chartreuse" })
check("unknown colour falls back to white", rgb(r) .. "," .. rgb(g) .. "," .. rgb(b), "255,255,255")

-- ---- every option has a label -------------------------------------------
local sets = {
    { NS.NOTE_BACKGROUNDS, NS.NOTE_BACKGROUND_LABELS, "background" },
    { NS.NOTE_EDGES,       NS.NOTE_EDGE_LABELS,       "edge" },
    { NS.NOTE_OUTLINES,    NS.NOTE_OUTLINE_LABELS,    "outline" },
    { NS.NOTE_ALIGNMENTS,  NS.NOTE_ALIGNMENT_LABELS,  "alignment" },
    { NS.NOTE_RAIL_SIDES,  NS.NOTE_RAIL_SIDE_LABELS,  "rail side" },
}

for _, set in ipairs(sets) do
    for _, value in ipairs(set[1]) do
        check(set[3] .. " '" .. value .. "' has a label", type(set[2][value]), "string")
    end
end

for _, name in ipairs(NS.MARKUP_COLOR_ORDER) do
    check("palette colour '" .. name .. "' exists",
          type(NS.MARKUP_COLOR_NAMES[name]), "string")
end

-- ---- everything travels with an export -----------------------------------
NS.GetConditionDefinition = function() end
local back = NS.ParseNoteString(NS.ExportNote({
    title = "t", body = "b",
    background = "card", edge = "border", accent = "gold",
    outline = "OUTLINE", align = "CENTER", textColor = "red", railSide = "BOTTOM",
}))

for field, want in pairs({
    background = "card", edge = "border", accent = "gold",
    outline = "OUTLINE", align = "CENTER", textColor = "red", railSide = "BOTTOM",
}) do
    check(field .. " exports", back[field], want)
end

-- A note with none of it set must not gain any of it by round tripping.
local plainBack = NS.ParseNoteString(NS.ExportNote({ title = "t", body = "b" }))
for _, field in ipairs({ "background", "edge", "align", "textColor", "railSide" }) do
    check("plain round trips without " .. field, plainBack[field], nil)
end


-- ---- border thickness ----------------------------------------------------
-- 1px is the default and stored as absent, matching every other default here.
local sized = NS.ParseNoteString(NS.ExportNote({
    title = "t", body = "b", edge = "border", borderSize = 4,
}))
check("border thickness exports", sized.borderSize, 4)
check("border thickness is a number", type(sized.borderSize), "number")

local thin = NS.ParseNoteString(NS.ExportNote({ title = "t", body = "b", edge = "border" }))
check("default thickness stores nothing", thin.borderSize, nil)

print(string.format("%d passed, %d failed", pass, fail))
