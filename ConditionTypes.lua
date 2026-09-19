local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- BUILT-IN CONDITION TYPES
--
-- Every condition here reads plain event payloads or plain query APIs. None
-- touch health, damage, auras or the combat log, all of which return secret
-- values in instances under 12.0 - and secret values cannot be compared or
-- branched on from addon code, which is exactly what a rule has to do.
--
-- That restriction is why there is no "boss phase" or "aura applied" rule:
-- health thresholds can't be compared, the combat log no longer carries usable
-- data in group content, and UNIT_AURA payloads are secret inside instances.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- In combat
-- ---------------------------------------------------------------------------

NS.RegisterCondition("combat", {
    name = "Combat",
    description = "Matches while you are in, or out of, combat.",
    events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },

    fields = {
        {
            key = "inCombat",
            type = "choice",
            label = "State",
            inline = true,
            width = 180,
            default = true,
            -- Both entries are real choices, so `false` has to be stored
            -- rather than read as "no filter picked".
            keepFalse = true,
            options = {
                { value = true,  label = "In combat" },
                { value = false, label = "Out of combat" },
            },
        },
    },

    evaluate = function(cfg)
        local inCombat = UnitAffectingCombat("player") and true or false
        local want = cfg.inCombat ~= false
        return inCombat == want
    end,

    describe = function(cfg)
        return (cfg.inCombat ~= false) and "in combat" or "out of combat"
    end,
})

-- ---------------------------------------------------------------------------
-- Boss encounter
--
-- ENCOUNTER_START / ENCOUNTER_END carry the encounter ID, name and difficulty
-- as ordinary values, which makes this the one reliable way to tie a note to a
-- specific boss under 12.0's restrictions.
-- ---------------------------------------------------------------------------

-- The timing windows for a rule, or nil for "the whole fight".
--
-- Rules written before windows were a list carry a single fromSeconds/toSeconds
-- pair. Those are read as a one-entry list rather than migrated, so an existing
-- rule keeps working untouched and only converts if it is edited.
function NS.GetEncounterWindows(cfg)
    if cfg.windows and #cfg.windows > 0 then
        return cfg.windows
    end

    if cfg.fromSeconds or cfg.toSeconds then
        return { { from = cfg.fromSeconds, to = cfg.toSeconds } }
    end

    return nil
end

NS.RegisterCondition("encounter", {
    name = "Raid encounter",
    description = "Matches while a raid boss encounter is in progress.",
    events = { "ENCOUNTER_START", "ENCOUNTER_END", "PLAYER_ENTERING_WORLD" },

    fields = {
        {
            key = "journalInstanceID",
            type = "choice",
            label = "Raid",
            inline = true,
            width = 232,
            -- A function rather than a table: the list comes from the client's
            -- Encounter Journal, so it reflects whatever content this patch has.
            options = function() return NS.GetInstanceOptions() end,
            -- Changing raid invalidates both of the choices below it.
            resets = { "encounterID", "difficultyID" },
        },
        {
            key = "encounterID",
            type = "choice",
            label = "Boss",
            inline = true,
            width = 232,
            -- Stepped as well as picked: moving one boss along the list is the
            -- common action once a raid is chosen.
            stepper = true,
            options = function(cfg) return NS.GetEncounterOptions(cfg.journalInstanceID) end,
            -- Nothing below this point means anything until a raid is chosen,
            -- so the row stays a single dropdown until then.
            visibleWhen = function(cfg) return cfg.journalInstanceID ~= nil end,
        },
        {
            key = "difficultyID",
            type = "choice",
            label = "Difficulty",
            inline = true,
            width = 232,
            -- Raid difficulties only, since the list is raids.
            options = function() return NS.GetDifficultyOptions(true) end,
            visibleWhen = function(cfg) return cfg.journalInstanceID ~= nil end,
        },
        -- Timing window within the fight.
        --
        -- This is the practical stand-in for phase detection: health can't be
        -- compared and the combat log carries nothing usable in group content,
        -- but the clock since ENCOUNTER_START is an ordinary number - and
        -- "swap at 2:30" is how most teams call phases anyway.
        --
        -- Both blank means the whole fight, which is the default.
        -- A list rather than one pair of boxes: a note is often wanted at
        -- several points in a fight, and needing a separate rule per appearance
        -- meant duplicating the raid, boss and difficulty each time.
        {
            key = "windows",
            type = "timewindows",
            label = "Show at",
            inline = true,
            labelWidth = 70,
            width = 232,
            visibleWhen = function(cfg) return cfg.journalInstanceID ~= nil end,
        },
        {
            -- Draws the window rather than editing it: two numbers say 90 and
            -- 150, but not what that looks like inside a fight. During a pull
            -- a playhead runs along it.
            key = "timeline",
            type = "timeline",
            label = "",
            inline = true,
            labelWidth = 70,
            width = 232,
            visibleWhen = function(cfg) return cfg.journalInstanceID ~= nil end,
        },
        {
            key = "customEncounterID",
            type = "number",
            label = "Encounter ID",
            inline = true,
            width = 100,
            -- Only offered when no raid is picked, which is exactly when the
            -- dropdowns can't help - older tiers and dungeons aren't listed.
            visibleWhen = function(cfg) return cfg.journalInstanceID == nil end,
        },
    },

    -- Nothing fires an event as the clock advances, so a rule carrying a timing
    -- window has to be re-checked on a timer. The engine only redraws notes
    -- whose result actually changed, so the polling costs very little.
    ticking = true,

    onEvent = function(state, event, encounterID, encounterName, difficultyID)
        if event == "ENCOUNTER_START" then
            state.encounterID = encounterID
            state.encounterName = encounterName
            state.encounterDifficulty = difficultyID
            state.encounterStart = GetTime()
        else
            -- Only ENCOUNTER_END means a fight actually finished. This handler
            -- also runs for PLAYER_ENTERING_WORLD, where the trailing arguments
            -- mean something else entirely, so the length is taken from the
            -- state we recorded at the pull rather than from the event.
            if event == "ENCOUNTER_END" and state.encounterStart and state.encounterID
                and NS.RecordEncounterDuration then
                NS.RecordEncounterDuration(
                    state.encounterID,
                    state.encounterDifficulty,
                    GetTime() - state.encounterStart)
            end

            -- Cleared on ENCOUNTER_END and on any world transition: wiping and
            -- releasing does not always deliver an ENCOUNTER_END, and a stale
            -- "encounter in progress" would leave notes stuck on screen.
            state.encounterID = nil
            state.encounterName = nil
            state.encounterDifficulty = nil
            state.encounterStart = nil
        end
    end,

    evaluate = function(cfg, state)
        if not state.encounterID then return false end

        -- Difficulty is an extra filter on top of whichever encounter matched.
        -- It comes from ENCOUNTER_START's own payload rather than from
        -- GetInstanceInfo, so it describes the pull rather than wherever the
        -- player happens to be standing when the rule is evaluated.
        if cfg.difficultyID and state.encounterDifficulty ~= cfg.difficultyID then
            return false
        end

        -- Most specific wins: an explicit ID, then a chosen boss, then any
        -- boss belonging to the chosen instance, then any encounter at all.
        -- These narrow the match rather than settling it, because the timing
        -- window below still has to be applied.
        local wanted = cfg.customEncounterID or cfg.encounterID

        if wanted then
            if state.encounterID ~= wanted then return false end
        elseif cfg.journalInstanceID then
            if NS.GetInstanceForEncounter(state.encounterID) ~= cfg.journalInstanceID then
                return false
            end
        end

        local windows = NS.GetEncounterWindows(cfg)

        if windows then
            if not state.encounterStart then return false end

            local elapsed = GetTime() - state.encounterStart

            -- Any window matching is enough: they are separate appearances of
            -- the same note, not conditions that all have to hold at once.
            for _, window in ipairs(windows) do
                local afterStart = (not window.from) or elapsed >= window.from
                local beforeEnd = (not window.to) or elapsed <= window.to

                if afterStart and beforeEnd then
                    return true
                end
            end

            return false
        end

        return true
    end,

    describe = function(cfg, state)
        local wanted = cfg.customEncounterID or cfg.encounterID
        local what

        if wanted then
            what = NS.GetEncounterName(wanted) or ("encounter " .. tostring(wanted))
        elseif cfg.journalInstanceID then
            what = "any boss in " .. (NS.GetInstanceName(cfg.journalInstanceID) or "instance")
        else
            what = state.encounterName and ("encounter: " .. state.encounterName) or "any encounter"
        end

        local difficulty = NS.GetDifficultyName(cfg.difficultyID)
        if difficulty then
            what = what .. " on " .. difficulty
        end

        -- The timing is named explicitly, because "hidden - waiting on
        -- Nymrissa" is confusing when the boss is plainly engaged and it is
        -- the clock that hasn't reached the mark yet.
        local windows = NS.GetEncounterWindows(cfg)

        if windows then
            local parts = {}

            -- Worded the way the fields now read - "at 90s for 60s" - so the
            -- status line and the boxes above it describe the same window the
            -- same way.
            for _, window in ipairs(windows) do
                if window.from and window.to then
                    table.insert(parts, string.format("at %ds for %ds",
                        window.from, window.to - window.from))
                elseif window.from then
                    table.insert(parts, string.format("from %ds", window.from))
                elseif window.to then
                    table.insert(parts, string.format("first %ds", window.to))
                end
            end

            if #parts > 0 then
                what = what .. ", " .. table.concat(parts, " / ") .. " in"
            end
        end

        return what
    end,
})

-- ---------------------------------------------------------------------------
-- Role
-- ---------------------------------------------------------------------------

NS.RegisterCondition("role", {
    name = "Your role",
    description = "Matches the role you are assigned in the group.",
    events = { "PLAYER_ROLES_ASSIGNED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" },

    fields = {
        {
            key = "role",
            type = "choice",
            label = "Role",
            inline = true,
            width = 180,
            default = "TANK",
            options = {
                { value = "TANK",    label = "Tank" },
                { value = "HEALER",  label = "Healer" },
                { value = "DAMAGER", label = "Damage" },
            },
        },
    },

    evaluate = function(cfg)
        if not cfg.role then return true end
        return UnitGroupRolesAssigned("player") == cfg.role
    end,

    describe = function(cfg)
        return "role is " .. tostring(cfg.role or "any"):lower()
    end,
})

-- ---------------------------------------------------------------------------
-- Specialisation
--
-- Options are the specs of whoever is logged in, so the list is short and
-- relevant rather than every spec in the game.
-- ---------------------------------------------------------------------------

NS.RegisterCondition("spec", {
    name = "Your specialisation",
    description = "Matches your current specialisation. Useful for a note kept account-wide across characters.",
    events = { "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_ENTERING_WORLD" },

    fields = {
        {
            key = "specID",
            type = "choice",
            label = "Spec",
            inline = true,
            width = 200,
            options = function()
                local options = { { value = false, label = "Any specialisation" } }

                if GetNumSpecializations and GetSpecializationInfo then
                    for index = 1, GetNumSpecializations() do
                        local id, name = GetSpecializationInfo(index)
                        if id and name then
                            table.insert(options, { value = id, label = name })
                        end
                    end
                end

                return options
            end,
        },
    },

    evaluate = function(cfg)
        if not cfg.specID then return true end
        if not GetSpecialization or not GetSpecializationInfo then return true end

        local index = GetSpecialization()
        if not index then return false end

        local id = GetSpecializationInfo(index)
        return id == cfg.specID
    end,

    describe = function(cfg)
        if not cfg.specID or not GetSpecializationInfoByID then
            return "specialisation"
        end
        local _, name = GetSpecializationInfoByID(cfg.specID)
        return name and ("spec is " .. name) or "specialisation"
    end,
})

-- ---------------------------------------------------------------------------
-- Group
-- ---------------------------------------------------------------------------

NS.RegisterCondition("group", {
    name = "Group",
    description = "Matches while you are in a party, in a raid, or alone.",
    events = { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" },

    fields = {
        {
            key = "state",
            type = "choice",
            label = "You are",
            inline = true,
            labelWidth = 70,
            width = 180,
            default = "group",
            options = {
                { value = "group", label = "In a group" },
                { value = "party", label = "In a party" },
                { value = "raid",  label = "In a raid" },
                { value = "solo",  label = "Alone" },
            },
        },
    },

    evaluate = function(cfg)
        local inRaid = IsInRaid and IsInRaid() and true or false
        local inGroup = IsInGroup and IsInGroup() and true or false
        local state = cfg.state or "group"

        if state == "raid" then return inRaid end
        if state == "party" then return inGroup and not inRaid end
        if state == "solo" then return not inGroup end
        return inGroup
    end,

    describe = function(cfg)
        local state = cfg.state or "group"
        if state == "raid" then return "in a raid" end
        if state == "party" then return "in a party" end
        if state == "solo" then return "alone" end
        return "in a group"
    end,
})

-- ---------------------------------------------------------------------------
-- Keystone level
-- ---------------------------------------------------------------------------

NS.RegisterCondition("keystone", {
    name = "Keystone level",
    description = "Matches the level of the Mythic Keystone dungeon in progress.",
    events = { "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET", "PLAYER_ENTERING_WORLD" },

    fields = {
        { key = "minLevel", type = "number", label = "Level", inline = true, labelWidth = 70, width = 58 },
        { key = "maxLevel", type = "number", label = "to",    inline = true, labelWidth = 16, width = 58, sameLine = true },
    },

    evaluate = function(cfg)
        if not C_ChallengeMode or not C_ChallengeMode.GetActiveKeystoneInfo then
            return false
        end

        local level = C_ChallengeMode.GetActiveKeystoneInfo()
        -- Zero, or nil, means no key is running.
        if not level or level == 0 then return false end

        if cfg.minLevel and level < cfg.minLevel then return false end
        if cfg.maxLevel and level > cfg.maxLevel then return false end

        return true
    end,

    describe = function(cfg)
        if cfg.minLevel and cfg.maxLevel then
            return string.format("keystone +%d to +%d", cfg.minLevel, cfg.maxLevel)
        elseif cfg.minLevel then
            return string.format("keystone +%d or higher", cfg.minLevel)
        elseif cfg.maxLevel then
            return string.format("keystone +%d or lower", cfg.maxLevel)
        end
        return "any keystone"
    end,
})

-- ---------------------------------------------------------------------------
-- Difficulty tables
--
-- Difficulty is no longer a rule of its own. It only ever made sense alongside
-- an encounter, and taking it from ENCOUNTER_START's payload describes the
-- pull itself rather than wherever the player happens to be standing when the
-- rule is next evaluated.
-- ---------------------------------------------------------------------------

local RAID_DIFFICULTIES = {
    { value = 17, label = "Looking For Raid" },
    { value = 14, label = "Normal" },
    { value = 15, label = "Heroic" },
    { value = 16, label = "Mythic" },
}

local DUNGEON_DIFFICULTIES = {
    { value = 1,  label = "Normal" },
    { value = 2,  label = "Heroic" },
    { value = 23, label = "Mythic" },
    { value = 8,  label = "Mythic Keystone" },
}

-- `isRaid` nil means the caller doesn't know, so both sets are offered.
function NS.GetDifficultyOptions(isRaid)
    local options = { { value = false, label = "Any difficulty" } }

    local sets = {}
    if isRaid == true then
        sets = { RAID_DIFFICULTIES }
    elseif isRaid == false then
        sets = { DUNGEON_DIFFICULTIES }
    else
        sets = { RAID_DIFFICULTIES, DUNGEON_DIFFICULTIES }
    end

    for _, set in ipairs(sets) do
        for _, entry in ipairs(set) do
            table.insert(options, { value = entry.value, label = entry.label })
        end
    end

    return options
end

function NS.GetDifficultyName(difficultyID)
    if not difficultyID then return nil end

    for _, set in ipairs({ RAID_DIFFICULTIES, DUNGEON_DIFFICULTIES }) do
        for _, entry in ipairs(set) do
            if entry.value == difficultyID then
                return entry.label
            end
        end
    end

    return tostring(difficultyID)
end
-- ---------------------------------------------------------------------------
-- Instance type
-- ---------------------------------------------------------------------------

local INSTANCE_OPTIONS = {
    { value = "raid",     label = "Raid" },
    { value = "party",    label = "Dungeon" },
    { value = "scenario", label = "Scenario" },
    { value = "arena",    label = "Arena" },
    { value = "pvp",      label = "Battleground" },
    { value = "none",     label = "Open world" },
}

NS.RegisterCondition("instance", {
    name = "Instance type",
    description = "Matches the kind of content you are in.",
    events = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" },

    fields = {
        {
            key = "instanceType",
            type = "choice",
            label = "Type",
            inline = true,
            width = 200,
            default = "raid",
            options = INSTANCE_OPTIONS,
        },
    },

    evaluate = function(cfg)
        if not cfg.instanceType then return true end
        local _, instanceType = IsInInstance()
        return (instanceType or "none") == cfg.instanceType
    end,

    describe = function(cfg)
        for _, option in ipairs(INSTANCE_OPTIONS) do
            if option.value == cfg.instanceType then
                return option.label
            end
        end
        return "instance type"
    end,
})

-- ---------------------------------------------------------------------------
-- Zone
-- ---------------------------------------------------------------------------

NS.RegisterCondition("zone", {
    name = "Zone",
    description = "Matches when the zone, subzone or instance name contains this text.",
    events = { "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS", "PLAYER_ENTERING_WORLD" },

    fields = {
        { key = "zoneName", type = "text", label = "Contains", inline = true, width = 230 },
    },

    evaluate = function(cfg)
        local needle = cfg.zoneName
        if not needle or needle == "" then return true end
        needle = needle:lower()

        -- Substring rather than exact match, and across all three names: it
        -- saves the user having to know whether a place is reported as a zone,
        -- a subzone or an instance name.
        local candidates = {
            GetZoneText(),
            GetSubZoneText(),
            GetRealZoneText(),
            (GetInstanceInfo()),
        }

        for _, candidate in ipairs(candidates) do
            if candidate and candidate ~= "" and candidate:lower():find(needle, 1, true) then
                return true
            end
        end

        return false
    end,

    describe = function(cfg)
        return "zone contains '" .. tostring(cfg.zoneName or "") .. "'"
    end,
})
