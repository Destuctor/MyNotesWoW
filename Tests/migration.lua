-- Migration tests. Run with:
--   lua-language-server.exe -E Tests/migration.lua
--
-- Core.lua's migration functions are file-locals, so this drives them the way
-- the addon does: set up saved variables as an older version left them, call
-- the same entry point Init.lua calls, and check what came out.
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"

GetTime = function() return 0 end
time = os.time
CreateFrame = function() return setmetatable({}, {__index = function() return function() end end}) end
UIParent = {}
C_Timer = { After = function() end }
C_DateAndTime = {
    GetSecondsUntilWeeklyReset = function() return 3600 end,
    GetSecondsUntilDailyReset = function() return 600 end,
}
issecretvalue = function() return false end
UnitExists = function() return false end

_G.MyNotesPrivate = {}
dofile(ADDON .. "Markup.lua")
dofile(ADDON .. "Core.lua")
local NS = _G.MyNotesPrivate

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
    end
end

-- A database as 1.12.0-dev.7 would have left it: reminder flags, a standing
-- dismissal, and an "After login" rule.
MyNotesDB = {
    dbVersion = 4,
    notes = {
        {
            id = 1, visible = true, reminder = true, dismissed = true,
            conditions = {
                { type = "login", withinMinutes = 5 },
                { type = "group", state = "raid" },
            },
        },
        { id = 2, visible = true, reminder = false, conditions = { { type = "combat" } } },
    },
    settings = { folders = {}, collapsedFolders = {} },
}
MyNotesCharDB = { dbVersion = 4, notes = {}, settings = { folders = {}, collapsedFolders = {} } }

NS.MigrateAll()
NS.NormalizeAllNotes()

local note = MyNotesDB.notes[1]

check("db version advanced", MyNotesDB.dbVersion, 8)
check("reminder flag cleared", note.reminder, nil)

-- The important one. Dismissal used to suppress a note that was otherwise
-- showing; nothing reads it now, so a note left dismissed would simply never
-- return with no switch anywhere to explain why.
check("dismissal cleared", note.dismissed, nil)

check("login rule removed", #note.conditions, 1)
check("the rule left is the group one", note.conditions[1].type, "group")
check("its settings survived", note.conditions[1].state, "raid")

-- Untouched notes must come through unchanged.
check("other note keeps its rule", MyNotesDB.notes[2].conditions[1].type, "combat")
check("other note's reminder cleared too", MyNotesDB.notes[2].reminder, nil)

-- Normalisation must not put the field back.
check("normalise does not re-add reminder", note.reminder, nil)

-- Re-running must be a no-op rather than an error.
NS.MigrateAll()
-- v6 removed automatic checklist clearing. The fields are dead, and leaving
-- them would be a setting nothing reads.
MyNotesDB.dbVersion = 5
MyNotesDB.notes[1].checkReset = "weekly"
MyNotesDB.notes[1].checkResetAt = 999
NS.MigrateAll()
check("checkReset cleared", MyNotesDB.notes[1].checkReset, nil)
check("checkResetAt cleared", MyNotesDB.notes[1].checkResetAt, nil)
-- The checkboxes themselves must survive: only the auto-clear was removed.
check("body untouched by v6", MyNotesDB.notes[1].body, nil)

check("second run is idempotent", MyNotesDB.dbVersion, 8)
check("conditions untouched on rerun", #note.conditions, 1)

print(string.format("%d passed, %d failed", pass, fail))
