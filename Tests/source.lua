-- Source-level guards for mistakes that have actually shipped here, and which
-- no amount of runtime testing catches because they only fire on one UI path.
-- Run with: lua-language-server.exe -E Tests/source.lua
local ADDON = "J:/World of Warcraft/_retail_/Interface/AddOns/MyNotes/"

local FILES = {
    "Core.lua", "Markup.lua", "Fonts.lua", "Conditions.lua", "ConditionTypes.lua",
    "EncounterData.lua", "Theme.lua", "Widgets.lua", "Share.lua",
    "ManagerUI.lua", "RulesUI.lua", "ShareUI.lua", "SettingsUI.lua",
    "Minimap.lua", "Bindings.lua", "Init.lua",
}

local pass, fail = 0, 0
local function check(label, ok, detail)
    if ok then pass = pass + 1 else
        fail = fail + 1
        print("FAIL " .. label .. (detail and ("\n  " .. detail) or ""))
    end
end

local function eachLine(fn)
    for _, name in ipairs(FILES) do
        local handle = io.open(ADDON .. name, "r")
        if handle then
            local number = 0
            for line in handle:lines() do
                number = number + 1
                fn(name, number, line)
            end
            handle:close()
        end
    end
end

-- ---- multiple-return truncation ------------------------------------------
-- Lua keeps only the first value of a multi-return call unless it is the last
-- argument. NS.Unpack returns four (r, g, b, a), so "Unpack(c), 1" collapses to
-- a single number and the call fails with a useless arity error at runtime.
--
-- This has shipped twice: once as "isRecorded and Unpack(a) or Unpack(b)", and
-- again as "SetColorTexture(Unpack(UNMET_COLOR), 1)", which threw 113 times
-- before it was noticed.
local truncations = {}

eachLine(function(name, number, line)
    -- An Unpack(...) call with anything following its closing bracket before
    -- the end of the argument list.
    if line:find("Unpack%b()%s*,") then
        table.insert(truncations, name .. ":" .. number .. "  " .. line:gsub("^%s+", ""))
    end
end)

check("no Unpack() in a non-final argument position",
      #truncations == 0, table.concat(truncations, "\n  "))

-- ---- literal backslashes in texture paths --------------------------------
-- A WoW texture path needs its backslashes doubled in Lua source. A single one
-- is an invalid escape, and it has twice slipped in when a path was written
-- through a shell heredoc or a perl replacement that ate the doubling.
--
-- The backslash is built with string.char rather than written, because writing
-- it is the very thing that keeps going wrong.
local BACKSLASH = string.char(92)
local SINGLE_SLASH_PATH = '"Interface' .. BACKSLASH .. "[^" .. BACKSLASH .. "]"

local badPaths = {}

eachLine(function(name, number, line)
    if line:find(SINGLE_SLASH_PATH) then
        table.insert(badPaths, name .. ":" .. number .. "  " .. line:gsub("^%s+", ""))
    end
end)

check("texture paths use escaped backslashes",
      #badPaths == 0, table.concat(badPaths, "\n  "))

-- ---- the dbVersion trap --------------------------------------------------
-- dbVersion must never appear in the defaults table: CopyDefaults would stamp
-- the current version onto an existing database and every pending migration
-- would be skipped.
local defaultsHasVersion = false
local inDefaults = false

for line in io.lines(ADDON .. "Core.lua") do
    if line:find("^local defaults = {") then inDefaults = true
    elseif inDefaults and line:find("^}") then inDefaults = false
    elseif inDefaults and line:find("dbVersion") then defaultsHasVersion = true end
end

check("dbVersion is not in the defaults table", not defaultsHasVersion,
      "CopyDefaults would stamp it on existing users and skip their migrations")

-- ---- lock guards go through one helper -----------------------------------
-- A locked note is click-through, and holding the unlock modifier hands it
-- back. That rule was spelled out inline in five places; adding the modifier
-- updated three of them, and the two that were missed left a note that took
-- the mouse and then refused to open for editing.
--
-- Anything branching on note.locked must ask IsNoteInteractive instead. The
-- exceptions are the field's own defaulting and the places that copy or read
-- it as data rather than as a permission.
local ALLOWED_LOCKED_LINES = {
    ["if note.locked == nil then note.locked = false end"] = true,
    ["locked = sourceNote.locked and true or false,"] = true,
    ["self.editUnlocked = note.locked and true or nil"] = true,
    -- The helper itself.
    ["return (not note.locked) or NS.IsUnlockModifierDown()"] = true,
    -- A filter, not a guard: an unlocked note has nothing to re-apply when the
    -- modifier moves, so the watcher skips it.
    ["if frame.note and frame.note.locked and not frame.isEditing then"] = true,
}

local rawLockGuards = {}

for line in io.lines(ADDON .. "Core.lua") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

    if trimmed:find("note%.locked") and not ALLOWED_LOCKED_LINES[trimmed] then
        table.insert(rawLockGuards, trimmed)
    end
end

check("lock guards go through IsNoteInteractive", #rawLockGuards == 0,
      table.concat(rawLockGuards, "\n  "))

print(string.format("%d passed, %d failed", pass, fail))
