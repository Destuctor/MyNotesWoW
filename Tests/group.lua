-- Group rule, plus checks that reminder mode and the "After login" rule are
-- fully removed. Run with:
--   lua-language-server.exe -E Tests/group.lua
-- removed in 1.12.0-dev.8; what remains is the Group rule, plus checks that
-- both removals are complete.
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"
_G.MyNotesPrivate = {}

local fakeInRaid, fakeInGroup = false, false
IsInRaid  = function() return fakeInRaid end
IsInGroup = function() return fakeInGroup end
UnitAffectingCombat = function() return false end
GetSpecialization = function() return nil end
C_ChallengeMode = { GetActiveKeystoneInfo = function() return nil end }
IsInInstance = function() return false, "none" end
GetZoneText = function() return "" end
UnitGroupRolesAssigned = function() return "NONE" end
C_Timer = { After = function() end }
CreateFrame = function() return { RegisterEvent=function() end, SetScript=function() end } end

dofile(ADDON .. "Conditions.lua")
dofile(ADDON .. "EncounterData.lua")
dofile(ADDON .. "ConditionTypes.lua")
dofile(ADDON .. "Share.lua")
local NS = _G.MyNotesPrivate

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
    end
end

-- ---- group rule (kept) ---------------------------------------------------
local group = NS.GetConditionDefinition("group")
check("group rule still exists", group ~= nil, true)

local function groupIs(state) return group.evaluate({ state = state }) end

fakeInGroup, fakeInRaid = false, false
check("solo: alone matches",     groupIs("solo"),  true)
check("solo: group does not",    groupIs("group"), false)
check("solo: raid does not",     groupIs("raid"),  false)

fakeInGroup, fakeInRaid = true, false
check("party: group matches",    groupIs("group"), true)
check("party: party matches",    groupIs("party"), true)
check("party: raid does not",    groupIs("raid"),  false)
check("party: solo does not",    groupIs("solo"),  false)

fakeInGroup, fakeInRaid = true, true
check("raid: raid matches",      groupIs("raid"),  true)
check("raid: group matches",     groupIs("group"), true)
-- A raid is not a party, or party rules would fire for a 20-man.
check("raid: party does NOT",    groupIs("party"), false)

-- ---- removals ------------------------------------------------------------
check("login rule is unregistered", NS.GetConditionDefinition("login"), nil)
check("affix rule is still gone",   NS.GetConditionDefinition("affix"), nil)

-- The reminder flag must no longer travel in an export. Left in the schema it
-- would keep resurrecting a field nothing reads.
local back = NS.ParseNoteString(NS.ExportNote({
    title = "t", body = "b", reminder = true, dismissed = true,
    conditions = { { type = "group", state = "raid" } },
}))
check("reminder does not export",  back.reminder, nil)
check("dismissal does not export", back.dismissed, nil)
check("group rule still exports",  back.conditions[1].state, "raid")

print(string.format("%d passed, %d failed", pass, fail))
