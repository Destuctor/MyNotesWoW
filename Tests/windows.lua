-- Timing windows are shown as "at X for Y" but stored as from/to. These check
-- the conversion both ways, and that the stored shape is unchanged - the
-- evaluator, the timeline and every export string in circulation rely on it.
-- Run with: lua-language-server.exe -E Tests/windows.lua
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
    end
end

-- The two functions RulesUI uses, lifted verbatim so the test tracks the real
-- conversion rather than a restatement of it.
local function ReadDuration(window)
    if not window or not window.to then return nil end
    return window.to - (window.from or 0)
end

local function WriteDuration(window, duration)
    window.to = duration and ((window.from or 0) + duration) or nil
end

-- ---- reading an existing window -----------------------------------------
check("90..150 reads as 60", ReadDuration({ from = 90, to = 150 }), 60)
check("0..60 reads as 60",   ReadDuration({ from = 0, to = 60 }), 60)
-- A window with no start begins at the pull, so its duration is its end.
check("nil start reads from 0", ReadDuration({ to = 45 }), 45)
-- No end means "until the fight ends", which has no duration to show.
check("nil end reads as blank", ReadDuration({ from = 90 }), nil)
check("empty window reads blank", ReadDuration({}), nil)

-- ---- writing a duration --------------------------------------------------
local w = { from = 90 }
WriteDuration(w, 60)
check("at 90 for 60 stores to=150", w.to, 150)
check("start is untouched", w.from, 90)

w = { from = 90, to = 150 }
WriteDuration(w, nil)
check("blank duration clears the end", w.to, nil)
check("blank duration keeps the start", w.from, 90)

w = {}
WriteDuration(w, 30)
check("no start means from the pull", w.to, 30)

-- ---- moving the start keeps the duration ---------------------------------
-- The behaviour that would be most annoying to get wrong: retyping the start
-- must not silently stretch or shrink the window.
w = { from = 90, to = 150 }
local held = ReadDuration(w)
w.from = 200
WriteDuration(w, held)
check("moved start keeps 60s", ReadDuration(w), 60)
check("moved start recomputes the end", w.to, 260)

-- ---- round trip ----------------------------------------------------------
for _, case in ipairs({ {0, 10}, {5, 300}, {90, 150}, {1, 2} }) do
    local window = { from = case[1], to = case[2] }
    local duration = ReadDuration(window)
    local rebuilt = { from = case[1] }
    WriteDuration(rebuilt, duration)
    check(("round trip %d..%d"):format(case[1], case[2]), rebuilt.to, case[2])
end

-- ---- the evaluator still sees from/to ------------------------------------
_G.MyNotesPrivate = {}
UnitAffectingCombat = function() return false end
IsInRaid = function() return false end
IsInGroup = function() return false end
GetSpecialization = function() return nil end
C_ChallengeMode = { GetActiveKeystoneInfo = function() return nil end }
IsInInstance = function() return false, "none" end
GetZoneText = function() return "" end
GetSubZoneText = function() return "" end
GetRealZoneText = function() return "" end
GetInstanceInfo = function() return "", "none" end
UnitGroupRolesAssigned = function() return "NONE" end
C_Timer = { After = function() end }
CreateFrame = function() return { RegisterEvent=function() end, SetScript=function() end } end

dofile(ADDON .. "Conditions.lua")
dofile(ADDON .. "EncounterData.lua")
dofile(ADDON .. "ConditionTypes.lua")
local NS = _G.MyNotesPrivate

local cfg = { type = "encounter", windows = { { from = 90, to = 150 } } }
local got = NS.GetEncounterWindows(cfg)
check("stored shape is still from/to", got[1].from .. "-" .. got[1].to, "90-150")

-- The description should read the way the fields now do.
-- describe takes the shared condition state as its second argument.
local text = NS.GetConditionDefinition("encounter").describe(cfg, {})
check("describe says 'at 90s for 60s'", text:find("at 90s for 60s", 1, true) ~= nil, true)

print(string.format("%d passed, %d failed", pass, fail))
