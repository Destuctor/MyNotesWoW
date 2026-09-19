-- NS.DescribeConditions: the full per-rule breakdown the status band renders.
-- Run with: lua-language-server.exe -E Tests/describe.lua
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"

local inCombat, inRaid, inGroup = false, false, false
UnitAffectingCombat = function() return inCombat end
IsInRaid  = function() return inRaid end
IsInGroup = function() return inGroup end
GetSpecialization = function() return nil end
C_ChallengeMode = { GetActiveKeystoneInfo = function() return nil end }
IsInInstance = function() return false, "none" end
GetZoneText = function() return "Tazavesh" end
GetSubZoneText = function() return "" end
GetRealZoneText = function() return "Tazavesh" end
GetInstanceInfo = function() return "Tazavesh", "none" end
UnitGroupRolesAssigned = function() return "NONE" end
C_Timer = { After = function() end }
CreateFrame = function() return { RegisterEvent=function() end, SetScript=function() end } end

_G.MyNotesPrivate = {}
dofile(ADDON .. "Conditions.lua")
dofile(ADDON .. "EncounterData.lua")
dofile(ADDON .. "ConditionTypes.lua")
local NS = _G.MyNotesPrivate

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
    end
end

local function note(mode, ...)
    return { conditionMode = mode, conditions = { ... } }
end

-- ---- no rules ------------------------------------------------------------
local info = NS.DescribeConditions({})
check("no rules matches", info.matched, true)
check("no rules listed", #info.rules, 0)
check("no rules active", info.activeCount, 0)

-- ---- every rule is reported, not just the decider ------------------------
-- This is the whole point: ExplainConditions stops at the first failure, so
-- with three rules it could only ever name one.
inCombat, inRaid, inGroup = false, true, true

local three = note("all",
    { type = "combat", inCombat = true },
    { type = "group", state = "raid" },
    { type = "zone", zoneName = "Tazavesh" })

info = NS.DescribeConditions(three)
check("all three reported", #info.rules, 3)
check("overall is blocked", info.matched, false)
check("rule 1 unmet", info.rules[1].met, false)
check("rule 2 met", info.rules[2].met, true)
check("rule 3 met", info.rules[3].met, true)
check("each carries its own text", info.rules[2].text, "in a raid")

-- A later rule failing must not mask an earlier one passing, and vice versa.
inCombat = true
info = NS.DescribeConditions(three)
check("all satisfied now", info.matched, true)
check("rule 1 now met", info.rules[1].met, true)

-- ---- any mode ------------------------------------------------------------
inCombat, inRaid = false, false
local anyNote = note("any",
    { type = "combat", inCombat = true },
    { type = "group", state = "raid" })

info = NS.DescribeConditions(anyNote)
check("any: none match", info.matched, false)
inRaid, inGroup = true, true
info = NS.DescribeConditions(anyNote)
check("any: one match is enough", info.matched, true)
check("any: still reports the unmet one", info.rules[1].met, false)

-- ---- disabled rules ------------------------------------------------------
inCombat = false
local mixed = note("all",
    { type = "combat", inCombat = true, enabled = false },
    { type = "group", state = "raid" })

info = NS.DescribeConditions(mixed)
check("disabled rule still listed", #info.rules, 2)
check("disabled rule marked", info.rules[1].enabled, false)
-- A switched-off rule must not hold the note back, or switching it off would
-- do nothing.
check("disabled rule does not block", info.matched, true)
check("only one rule counted active", info.activeCount, 1)

local allOff = note("all",
    { type = "combat", inCombat = true, enabled = false },
    { type = "group", state = "raid", enabled = false })

info = NS.DescribeConditions(allOff)
check("all rules off matches", info.matched, true)
check("all rules off counts zero active", info.activeCount, 0)

-- ---- unknown rule types fail open ---------------------------------------
info = NS.DescribeConditions(note("all", { type = "nonsense" }))
check("unknown type does not block", info.matched, true)
check("unknown type is still listed", #info.rules, 1)

print(string.format("%d passed, %d failed", pass, fail))
