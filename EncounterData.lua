local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- ENCOUNTER DATA
--
-- Instance and boss lists, read from the game's own Encounter Journal rather
-- than hardcoded.
--
-- The alternative - shipping a table of this season's bosses and their IDs -
-- goes stale the moment a patch adds a raid, and a wrong ID fails silently:
-- the rule simply never matches, with nothing on screen to say why. Reading
-- the journal means the list is correct for whatever season the client is on,
-- including ones that did not exist when this was written.
--
-- The ID that matters is `dungeonEncounterID`, the seventh return of
-- EJ_GetEncounterInfoByIndex. That is the value ENCOUNTER_START fires with.
-- The journal's own `journalEncounterID` is a different number and will never
-- match a live encounter.
-- ============================================================================

local cache = nil

local function EnsureJournalLoaded()
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if loader then
        pcall(loader, "Blizzard_EncounterJournal")
    end
end

-- The journal lists world bosses under the raid tab as a pseudo-instance named
-- after the expansion itself. Comparing against the tier's own name identifies
-- it without hardcoding anything, and keeps working next expansion.
--
-- An earlier attempt filtered on EJ_GetInstanceInfo's map ID instead. That
-- relied on a guess about which position the map ID occupies in that
-- function's return list, the guess was wrong, and it silently removed every
-- raid. Comparing names fails safe: the worst case is an extra entry, not an
-- empty list.
local function GetTierName()
    if not EJ_GetTierInfo or not EJ_GetCurrentTier then return nil end

    local ok, name = pcall(EJ_GetTierInfo, EJ_GetCurrentTier())
    if ok and type(name) == "string" and name ~= "" then
        return name
    end

    return nil
end

local function CollectInstances(isRaid, instances, encounterToInstance, excludeName)
    local index = 1

    while true do
        local instanceID, instanceName = EJ_GetInstanceByIndex(index, isRaid)
        if not instanceID then break end

        EJ_SelectInstance(instanceID)

        local encounters = {}
        local encounterIndex = 1

        while true do
            local name, _, _, _, _, _, dungeonEncounterID =
                EJ_GetEncounterInfoByIndex(encounterIndex, instanceID)

            if not name then break end

            -- Some journal entries carry no live encounter ID (lore entries and
            -- the like). They can never match ENCOUNTER_START, so leaving them
            -- out keeps the list to things that can actually fire.
            if dungeonEncounterID and dungeonEncounterID > 0 then
                table.insert(encounters, {
                    name = name,
                    encounterID = dungeonEncounterID,
                })
                encounterToInstance[dungeonEncounterID] = instanceID
            end

            encounterIndex = encounterIndex + 1
        end

        local excluded = excludeName and instanceName == excludeName

        if #encounters > 0 and not excluded then
            table.insert(instances, {
                instanceID = instanceID,
                name = instanceName,
                isRaid = isRaid,
                encounters = encounters,
            })
        end

        index = index + 1
    end
end

local function BuildCache()
    if not EJ_GetInstanceByIndex or not EJ_GetEncounterInfoByIndex then
        return { instances = {}, encounterToInstance = {} }
    end

    EnsureJournalLoaded()

    local instances = {}
    local encounterToInstance = {}

    -- Selecting a tier and instance mutates shared Encounter Journal state, so
    -- whatever the player had open is restored afterwards.
    local previousTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    local ok = pcall(function()
        if EJ_SelectTier and EJ_GetCurrentTier then
            EJ_SelectTier(EJ_GetCurrentTier())
        end

        -- Raids only. Dungeon bosses fire ENCOUNTER_START too, but a note
        -- addon aimed at raid callouts doesn't need forty extra entries in the
        -- list, and the custom-ID field still reaches them.
        CollectInstances(true, instances, encounterToInstance, GetTierName())

        -- If filtering left nothing, the filter was wrong - not the journal.
        -- An extra entry is a cosmetic annoyance; an empty dropdown makes the
        -- feature unusable, so fall back to the unfiltered list.
        if #instances == 0 then
            wipe(encounterToInstance)
            CollectInstances(true, instances, encounterToInstance, nil)
        end
    end)

    if previousTier and EJ_SelectTier then
        pcall(EJ_SelectTier, previousTier)
    end

    if not ok then
        return { instances = {}, encounterToInstance = {} }
    end

    return { instances = instances, encounterToInstance = encounterToInstance }
end

-- Built on first use, not at load: the journal may not be ready during
-- start-up, and most sessions never open the rules window at all.
local function GetCache()
    if not cache then
        cache = BuildCache()
    end
    return cache
end

function NS.GetEncounterInstances()
    return GetCache().instances
end

function NS.GetInstanceForEncounter(encounterID)
    return GetCache().encounterToInstance[encounterID]
end

-- Options for the raid dropdown, in journal order (roughly release order).
function NS.GetInstanceOptions()
    local options = { { value = false, label = "Any raid" } }

    for _, instance in ipairs(NS.GetEncounterInstances()) do
        table.insert(options, { value = instance.instanceID, label = instance.name })
    end

    return options
end

-- Options for the boss dropdown, narrowed to the chosen instance. With no
-- instance chosen this stays a single "any boss" entry rather than listing
-- every boss in the game, which would be unusable.
function NS.GetEncounterOptions(instanceID)
    local options = { { value = false, label = "Any boss" } }

    if not instanceID then
        return options
    end

    for _, instance in ipairs(NS.GetEncounterInstances()) do
        if instance.instanceID == instanceID then
            for _, encounter in ipairs(instance.encounters) do
                table.insert(options, {
                    value = encounter.encounterID,
                    label = encounter.name,
                })
            end
            break
        end
    end

    return options
end

function NS.GetInstanceName(instanceID)
    if not instanceID then return nil end

    for _, instance in ipairs(NS.GetEncounterInstances()) do
        if instance.instanceID == instanceID then
            return instance.name
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Recorded fight lengths
--
-- Used to scale the rules window's timeline to the actual length of a fight.
--
-- There is no API for "how long is this encounter". Addons that draw real boss
-- timelines ship hand-authored data - a maintained Lua file per boss carrying
-- a literal span - which is not something a note addon can keep current.
--
-- Recording your own pulls instead means the axis is right for your group
-- rather than for an average one, and it needs no maintenance. The cost is
-- that the first pull of a new boss has nothing to go on.
-- ---------------------------------------------------------------------------

local MIN_PLAUSIBLE_DURATION = 10
local MAX_PLAUSIBLE_DURATION = 30 * 60

local function DurationKey(encounterID, difficultyID)
    return tostring(encounterID) .. ":" .. tostring(difficultyID or 0)
end

function NS.RecordEncounterDuration(encounterID, difficultyID, seconds)
    if not encounterID or type(seconds) ~= "number" then return end

    -- Guards against a pull that ended a second after it started (a reset, a
    -- zone-out) and against a stale timer producing an absurd figure.
    if seconds < MIN_PLAUSIBLE_DURATION or seconds > MAX_PLAUSIBLE_DURATION then
        return
    end

    local settings = MyNotesDB and MyNotesDB.settings
    if not settings then return end

    settings.encounterDurations = settings.encounterDurations or {}

    local key = DurationKey(encounterID, difficultyID)
    local existing = settings.encounterDurations[key]

    -- The longest seen, not the most recent: the axis needs to cover the worst
    -- case, or a rule window sitting late in the fight would fall off the end
    -- of the timeline after one quick kill.
    if not existing or seconds > existing then
        settings.encounterDurations[key] = math.floor(seconds + 0.5)
    end
end

-- Exact difficulty first, then the longest recorded at any difficulty: a
-- Heroic length is a far better guess for Mythic than no length at all.
function NS.GetEncounterDuration(encounterID, difficultyID)
    local settings = MyNotesDB and MyNotesDB.settings
    local durations = settings and settings.encounterDurations
    if not durations or not encounterID then return nil end

    local exact = durations[DurationKey(encounterID, difficultyID)]
    if exact then return exact, true end

    local prefix = tostring(encounterID) .. ":"
    local best = nil

    for key, value in pairs(durations) do
        if key:sub(1, #prefix) == prefix then
            best = math.max(best or 0, value)
        end
    end

    -- Second return: whether this was an exact difficulty match.
    return best, false
end

-- Human-readable name for an encounter ID, for the status line and rule labels.
function NS.GetEncounterName(encounterID)
    if not encounterID then return nil end

    for _, instance in ipairs(NS.GetEncounterInstances()) do
        for _, encounter in ipairs(instance.encounters) do
            if encounter.encounterID == encounterID then
                return encounter.name
            end
        end
    end

    return nil
end
