local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- CONDITIONS
--
-- Rules that gate when a displayed note is actually on screen.
--
-- A note is shown when `note.visible` (the manual master switch) AND its
-- conditions evaluate true. Conditions never write `note.visible` - if they
-- did, a rule firing would permanently flip the toggle and the difference
-- between "turned off" and "waiting for its moment" would be lost.
--
-- A condition type declares the events it needs, how to evaluate itself, and
-- what parameters it takes. That last part is what keeps this extensible: the
-- rules window builds its own inputs from the `fields` descriptor, so adding a
-- condition type never means touching UI code.
--
-- Registration is deliberately not exposed globally yet. Conditions live in
-- their own file and go through the same call a third party eventually would,
-- so opening it later is a one-line change once the shape has settled.
-- ============================================================================

local registry = {}
local registrationOrder = {}

-- Shared, event-maintained state for facts that can't simply be queried.
-- Whether an encounter is in progress is the obvious one: ENCOUNTER_START
-- tells you it began, and nothing will tell you again if you ask later.
local state = {}

NS.conditionState = state

function NS.RegisterCondition(typeKey, definition)
    if type(typeKey) ~= "string" or type(definition) ~= "table" then return end
    if type(definition.evaluate) ~= "function" then return end

    definition.key = typeKey
    definition.eventLookup = {}
    for _, event in ipairs(definition.events or {}) do
        definition.eventLookup[event] = true
    end

    if not registry[typeKey] then
        table.insert(registrationOrder, typeKey)
    end
    registry[typeKey] = definition
end

function NS.GetConditionDefinition(typeKey)
    return registry[typeKey]
end

-- In registration order rather than alphabetical: the built-ins are declared
-- roughly most-useful-first, and that is a better default ordering than the
-- accident of their names.
function NS.GetConditionTypes()
    local list = {}
    for _, key in ipairs(registrationOrder) do
        table.insert(list, key)
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Evaluation
-- ---------------------------------------------------------------------------

local function EvaluateOne(cfg)
    local definition = registry[cfg.type]

    -- Unknown type: fail OPEN. A note that appears unexpectedly is clutter; a
    -- note that silently fails to appear during a pull could cost the attempt.
    -- Wrong-but-visible beats correct-but-absent for this addon.
    if not definition then
        return true, "unknown rule type '" .. tostring(cfg.type) .. "' (showing anyway)"
    end

    local matched = definition.evaluate(cfg, state) and true or false
    local label = definition.name or cfg.type

    if definition.describe then
        label = definition.describe(cfg, state) or label
    end

    return matched, label
end

-- Returns: matched (boolean), reason (string) - the reason names whichever
-- clause decided the outcome, which is what makes a failing rule debuggable.
function NS.ExplainConditions(note)
    local conditions = note and note.conditions

    if not conditions or #conditions == 0 then
        return true, "no rules"
    end

    local mode = note.conditionMode or "all"
    local activeCount = 0

    for _, cfg in ipairs(conditions) do
        -- A rule can be switched off without being deleted, so a setup can be
        -- tried both ways without losing how it was configured.
        if cfg.enabled ~= false then
            activeCount = activeCount + 1

            local matched, label = EvaluateOne(cfg)

            if mode == "all" and not matched then
                return false, "waiting on: " .. label
            elseif mode == "any" and matched then
                return true, "matched: " .. label
            end
        end
    end

    -- Every rule switched off is the same as having none: the note falls back
    -- to its own on/off switch rather than being hidden by rules that are not
    -- in play.
    if activeCount == 0 then
        return true, "all rules are switched off"
    end

    if mode == "all" then
        return true, "all rules match"
    end

    return false, "no rule matches"
end

function NS.EvaluateConditions(note)
    local matched = NS.ExplainConditions(note)
    return matched
end

-- The whole picture, rather than the first clause that decided it.
--
-- ExplainConditions short-circuits, which is right for deciding visibility but
-- poor for explaining it: with three rules it names one and says nothing about
-- the other two. This evaluates every rule and reports each, so the window can
-- show what is already satisfied next to what is still outstanding.
--
-- Returns a table:
--   mode         "all" or "any"
--   matched      whether the rules are satisfied overall
--   activeCount  how many rules are switched on
--   rules        { { text, met, enabled }, ... } in listed order
function NS.DescribeConditions(note)
    local conditions = (note and note.conditions) or {}

    local result = {
        mode = (note and note.conditionMode) or "all",
        rules = {},
        activeCount = 0,
        matched = true,
    }

    if #conditions == 0 then
        return result
    end

    local anyMatched = false

    for _, cfg in ipairs(conditions) do
        local enabled = cfg.enabled ~= false
        local matched, label = EvaluateOne(cfg)

        table.insert(result.rules, {
            text = label,
            met = matched,
            enabled = enabled,
        })

        -- A rule that is switched off is still described, but never counts for
        -- or against the outcome.
        if enabled then
            result.activeCount = result.activeCount + 1

            if matched then
                anyMatched = true
            elseif result.mode == "all" then
                result.matched = false
            end
        end
    end

    -- Every rule switched off is the same as having none.
    if result.activeCount == 0 then
        result.matched = true
    elseif result.mode == "any" then
        result.matched = anyMatched
    end

    return result
end

-- True when a note is enabled but currently held back by its rules. The note
-- list uses this for a third state between "shown" and "hidden".
function NS.IsNoteGated(note)
    if not note or not note.visible then return false end
    if not note.conditions or #note.conditions == 0 then return false end
    return not NS.EvaluateConditions(note)
end

-- ---------------------------------------------------------------------------
-- Watcher
-- ---------------------------------------------------------------------------

local watcher = nil
local needsUpdate = false
local hasTickingCondition = false

-- Last computed visibility per note, so a re-evaluation only redraws notes
-- that actually changed. This is what makes it affordable to re-check on a
-- clock rather than only on events.
local lastShownState = {}

local function RefreshNoteSet(notes, scope, changed)
    for _, note in ipairs(notes) do
        if note.conditions and #note.conditions > 0 then
            local shouldShow = NS.ShouldNoteBeShown and NS.ShouldNoteBeShown(note) or false

            if lastShownState[note] ~= shouldShow then
                lastShownState[note] = shouldShow
                if NS.RefreshFloatingNote then
                    NS.RefreshFloatingNote(scope, note)
                end
                changed[1] = true
            end
        end
    end
end

local function RefreshConditionalNotes()
    local changed = { false }

    -- Iterating the databases directly rather than through GetAllNotesForList:
    -- that builds and sorts a fresh table, which is not something to do four
    -- times a second.
    if MyNotesDB and MyNotesDB.notes then
        RefreshNoteSet(MyNotesDB.notes, "account", changed)
    end
    if MyNotesCharDB and MyNotesCharDB.notes then
        RefreshNoteSet(MyNotesCharDB.notes, "character", changed)
    end

    if changed[1] and NS.managerFrame and NS.managerFrame:IsShown()
        and NS.managerFrame.RefreshNoteList then
        NS.managerFrame:RefreshNoteList()
    end
end

NS.RefreshConditionalNotes = RefreshConditionalNotes

function NS.StartConditionWatcher()
    if watcher then return end

    watcher = CreateFrame("Frame")

    -- Every event any registered condition asked for. The set is small and
    -- these are all infrequent events, so registering the union is simpler
    -- than tracking which types are currently in use by a note.
    local registered = {}
    for _, definition in pairs(registry) do
        for _, event in ipairs(definition.events or {}) do
            if not registered[event] then
                registered[event] = true
                watcher:RegisterEvent(event)
            end
        end

        -- Some conditions depend on elapsed time rather than on anything that
        -- fires an event - a window of seconds after the pull, say - so they
        -- have to be re-checked on a clock.
        if definition.ticking then
            hasTickingCondition = true
        end
    end

    watcher:SetScript("OnEvent", function(_, event, ...)
        for _, definition in pairs(registry) do
            if definition.onEvent and definition.eventLookup[event] then
                definition.onEvent(state, event, ...)
            end
        end
        -- Coalesced to one pass per frame: several of these events can arrive
        -- together (zone change fires a cluster), and re-evaluating every note
        -- for each of them would be wasted work.
        needsUpdate = true
    end)

    local tickAccumulator = 0

    watcher:SetScript("OnUpdate", function(_, elapsed)
        if needsUpdate then
            needsUpdate = false
            RefreshConditionalNotes()
            tickAccumulator = 0
            return
        end

        if not hasTickingCondition then return end

        tickAccumulator = tickAccumulator + elapsed
        if tickAccumulator < 0.25 then return end

        tickAccumulator = 0
        RefreshConditionalNotes()
    end)

    -- Evaluate once at startup so notes are correct before anything fires.
    needsUpdate = true
end
