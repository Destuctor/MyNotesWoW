local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- EXPORT / IMPORT
--
-- Encodes a note as a plain-text string that can be pasted anywhere - Discord,
-- a forum, a guild site - and read back in. This is how sharing works now that
-- addon comms are blocked inside instances.
--
-- The format is parsed by hand rather than run through loadstring. An import
-- string arrives from outside and must never be executed, only read.
--
-- Types are recovered from schema rather than encoded inline: note fields have
-- a fixed schema below, and condition fields describe their own types in the
-- `fields` descriptor each condition already declares for the rules UI.
-- ============================================================================

local PREFIX = "MyNotes1"
local FIELD_SEPARATOR = "|"
local PAIR_SEPARATOR = ";"
local CONDITION_MARKER = "@"

-- The payload described above is wrapped in Base64 before it leaves the addon,
-- and the result carries this marker so the parser knows which form it has.
--
-- Three reasons the raw payload is not fit to hand to someone:
--
--   * "|" is WoW's own escape character, and the payload uses it as the field
--     separator. "|title=" contains "|t", the texture terminator; "|c", "|b"
--     and "|f" show up the same way. The string breaks the moment it passes
--     through anything that renders text.
--   * It contains spaces, so it is not a single token: it cannot be
--     double-clicked to select, and anything splitting on whitespace mangles
--     it.
--   * Base64's alphabet is letters, digits, "+", "/" and "=", none of which
--     any of those layers treat as special.
--
-- Deliberately not compressed. LibDeflate is what the ecosystem reaches for,
-- but deflate's header costs bytes a short string never earns back, and a note
-- is typically a few hundred characters. That would mean shipping a very large
-- library to save perhaps a fifth of a string that already pastes fine.
-- Worth revisiting only if notes get much longer.
local ENCODED_PREFIX = "!MN:1!"

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local BASE64_INDEX = {}
for position = 1, #BASE64 do
    BASE64_INDEX[BASE64:sub(position, position)] = position - 1
end

-- Arithmetic rather than bitwise: the `bit` library exists in the WoW client
-- but not in a plain Lua interpreter, and keeping this portable is what lets
-- the round trip be tested outside the game.
local function Base64Encode(data)
    local out = {}

    for index = 1, #data, 3 do
        local a = data:byte(index)
        local b = data:byte(index + 1)
        local c = data:byte(index + 2)

        local triple = a * 65536 + (b or 0) * 256 + (c or 0)

        local c1 = math.floor(triple / 262144) % 64
        local c2 = math.floor(triple / 4096) % 64
        local c3 = math.floor(triple / 64) % 64
        local c4 = triple % 64

        out[#out + 1] = BASE64:sub(c1 + 1, c1 + 1)
        out[#out + 1] = BASE64:sub(c2 + 1, c2 + 1)
        out[#out + 1] = b and BASE64:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = c and BASE64:sub(c4 + 1, c4 + 1) or "="
    end

    return table.concat(out)
end

-- Returns nil on any character outside the alphabet, so a truncated or
-- corrupted paste fails loudly here instead of producing a half-formed note.
local function Base64Decode(text)
    -- Whitespace is stripped first: a long string pasted from Discord or a
    -- forum often arrives with line breaks in it.
    text = tostring(text or ""):gsub("%s", ""):gsub("=+$", "")

    local out = {}
    local accumulator, bits = 0, 0

    for index = 1, #text do
        local value = BASE64_INDEX[text:sub(index, index)]
        if not value then return nil end

        accumulator = accumulator * 64 + value
        bits = bits + 6

        if bits >= 8 then
            bits = bits - 8
            local divisor = 2 ^ bits
            out[#out + 1] = string.char(math.floor(accumulator / divisor) % 256)
            accumulator = accumulator % divisor
        end
    end

    return table.concat(out)
end

-- Escaped so no value can contain a character the parser uses as structure.
local function Escape(value)
    value = tostring(value or "")
    value = value:gsub("%%", "%%25")
    value = value:gsub("|", "%%7C")
    value = value:gsub(";", "%%3B")
    value = value:gsub("=", "%%3D")
    value = value:gsub("@", "%%40")
    value = value:gsub("\n", "%%0A")
    value = value:gsub("\r", "")
    return value
end

local function Unescape(value)
    value = tostring(value or "")
    value = value:gsub("%%0A", "\n")
    value = value:gsub("%%40", "@")
    value = value:gsub("%%3D", "=")
    value = value:gsub("%%3B", ";")
    value = value:gsub("%%7C", "|")
    value = value:gsub("%%25", "%%")
    return value
end

-- Note fields that travel with an exported note. Position and visibility are
-- deliberately excluded: where a note sat on your screen is not meaningful on
-- someone else's, and an import should never switch itself on unannounced.
local NOTE_SCHEMA = {
    title         = "string",
    body          = "string",
    fontSize      = "number",
    bgAlpha       = "number",
    font          = "string",
    pinned        = "boolean",
    locked        = "boolean",
    background    = "string",
    edge          = "string",
    outline       = "string",
    accent        = "string",
    borderSize    = "number",
    railSide      = "string",
    align         = "string",
    textColor     = "string",
    width         = "number",
    height        = "number",
    conditionMode = "string",
}

-- Export walks this list rather than the table above. `pairs` returns hash
-- order, which is stable within a session but not between them, so the same
-- note used to produce a different string each time the client restarted -
-- impossible to diff, and it looks to a user like the note changed when it
-- did not. Import still reads NOTE_SCHEMA by key, so order does not matter
-- coming back in - and a key that has since been retired, such as the old
-- per-note `shadow`, is simply ignored rather than breaking the string.
local NOTE_FIELD_ORDER = {
    "title", "body", "font", "fontSize", "bgAlpha",
    "pinned", "locked", "background", "edge", "accent", "borderSize",
    "railSide", "outline", "align", "textColor",
    "width", "height", "conditionMode",
}

-- Timing windows are a list of tables, so they get their own compact encoding
-- rather than being flattened into the scalar key=value form: "90-150,300-360",
-- with a blank on either side of a dash meaning unbounded there.
local function EncodeWindows(windows)
    local parts = {}

    for _, window in ipairs(windows or {}) do
        table.insert(parts,
            tostring(window.from or "") .. "-" .. tostring(window.to or ""))
    end

    return table.concat(parts, ",")
end

local function DecodeWindows(text)
    local windows = {}

    for chunk in (tostring(text or "") .. ","):gmatch("(.-),") do
        if chunk ~= "" then
            local from, to = chunk:match("^(%d*)%-(%d*)$")
            -- A malformed entry is dropped rather than stored as something the
            -- evaluator would silently never match.
            if from then
                table.insert(windows, {
                    from = tonumber(from),
                    to = tonumber(to),
                })
            end
        end
    end

    return windows
end

-- A "choice" field's value can be a number (an encounter ID), a boolean (in or
-- out of combat) or a string (an instance type), and the field descriptor says
-- only "choice" - it does not say which. Everything used to go out through
-- tostring and come back a string, so an imported encounter rule compared
-- "2902" against 2902, never matched, and the note simply never appeared. A
-- one-letter tag carries the type across.
local function EncodeChoice(value)
    local kind = type(value)

    if kind == "boolean" then
        return "b:" .. (value and "1" or "0")
    elseif kind == "number" then
        return "n:" .. tostring(value)
    end

    return "s:" .. tostring(value)
end

local function DecodeChoice(text)
    local tag, rest = tostring(text or ""):match("^(%a):(.*)$")

    -- Untagged means a string written before tagging existed. Returning it
    -- as-is keeps that import no worse than it already was.
    if not tag then return text end

    if tag == "b" then return rest == "1" end
    if tag == "n" then return tonumber(rest) end
    return rest
end

local function Coerce(value, valueType)
    if valueType == "number" then
        return tonumber(value)
    elseif valueType == "boolean" then
        return value == "1"
    elseif valueType == "timewindows" then
        return DecodeWindows(value)
    elseif valueType == "choice" then
        return DecodeChoice(value)
    end
    return value
end

local function Encode(value, valueType)
    if valueType == "boolean" then
        return value and "1" or "0"
    elseif valueType == "timewindows" then
        return Escape(EncodeWindows(value))
    elseif valueType == "choice" then
        return Escape(EncodeChoice(value))
    end
    return Escape(value)
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

function NS.ExportNote(note)
    if not note then return nil end

    local parts = { PREFIX }

    for _, key in ipairs(NOTE_FIELD_ORDER) do
        local value = note[key]
        if value ~= nil then
            table.insert(parts, key .. "=" .. Encode(value, NOTE_SCHEMA[key]))
        end
    end

    for _, cfg in ipairs(note.conditions or {}) do
        local definition = NS.GetConditionDefinition and NS.GetConditionDefinition(cfg.type)
        local pairsOut = { "type=" .. Escape(cfg.type) }

        for _, field in ipairs(definition and definition.fields or {}) do
            local value = cfg[field.key]
            if value ~= nil then
                table.insert(pairsOut, field.key .. "=" .. Encode(value, field.type))
            end
        end

        table.insert(parts, CONDITION_MARKER .. table.concat(pairsOut, PAIR_SEPARATOR))
    end

    return ENCODED_PREFIX .. Base64Encode(table.concat(parts, FIELD_SEPARATOR))
end

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

-- Returns a plain table of note data, or nil plus a reason. The caller decides
-- what to do with it; nothing here writes to the database.
function NS.ParseNoteString(text)
    if type(text) ~= "string" then
        return nil, "Nothing to import."
    end

    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil, "Nothing to import."
    end

    -- Encoded strings are unwrapped here. Strings exported before encoding
    -- existed are still plain payloads and are read as-is: someone may well
    -- have one sitting in a Discord channel, and refusing it would break a
    -- share that used to work for no reason the person pasting could see.
    if text:sub(1, #ENCODED_PREFIX) == ENCODED_PREFIX then
        local decoded = Base64Decode(text:sub(#ENCODED_PREFIX + 1))

        if not decoded or decoded == "" then
            return nil, "That string looks damaged - it may have been cut short."
        end

        text = decoded
    end

    local segments = {}
    for segment in (text .. FIELD_SEPARATOR):gmatch("(.-)%" .. FIELD_SEPARATOR) do
        table.insert(segments, segment)
    end

    if segments[1] ~= PREFIX then
        return nil, "That doesn't look like a MyNotes string."
    end

    local data = { conditions = {} }

    for index = 2, #segments do
        local segment = segments[index]

        if segment:sub(1, 1) == CONDITION_MARKER then
            local cfg = {}
            local raw = {}

            for pair in (segment:sub(2) .. PAIR_SEPARATOR):gmatch("(.-)" .. PAIR_SEPARATOR) do
                local key, value = pair:match("^([%w_]+)=(.*)$")
                if key then raw[key] = value end
            end

            if raw.type then
                cfg.type = Unescape(raw.type)

                -- Field types come from the condition's own descriptor, so a
                -- condition added later imports correctly with no change here.
                local definition = NS.GetConditionDefinition and NS.GetConditionDefinition(cfg.type)
                for _, field in ipairs(definition and definition.fields or {}) do
                    local value = raw[field.key]
                    if value ~= nil then
                        cfg[field.key] = Coerce(Unescape(value), field.type)
                    end
                end

                table.insert(data.conditions, cfg)
            end
        else
            local key, value = segment:match("^([%w_]+)=(.*)$")
            local valueType = key and NOTE_SCHEMA[key]

            if valueType then
                data[key] = Coerce(Unescape(value), valueType)
            end
        end
    end

    if data.body == nil and data.title == nil then
        return nil, "That string carried no note content."
    end

    return data
end

-- Creates a note from parsed data. Imported notes always arrive hidden and
-- centred: an import appearing on screen the instant it's pasted, in whatever
-- corner it occupied on someone else's monitor, is not what anyone wants.
function NS.ImportNote(data, scope)
    if not data or not NS.CreateNewNote then return nil end

    scope = scope or "account"
    local note = NS.CreateNewNote(scope)

    for key in pairs(NOTE_SCHEMA) do
        if data[key] ~= nil then
            note[key] = data[key]
        end
    end

    note.conditions = data.conditions or {}
    note.visible = false

    if NS.NormalizeNote then
        NS.NormalizeNote(note)
    end

    return note
end
