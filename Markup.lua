local NS = _G.MyNotesPrivate or {}
_G.MyNotesPrivate = NS

-- ============================================================================
-- MARKUP
--
-- Notes are written in a small tag language and rendered into WoW's own escape
-- sequences (|cAARRGGBB ... |r for colour, |T...|t for icons).
--
-- This is a single left-to-right tokenizer rather than a series of gsub
-- passes. That matters for three reasons:
--
--   * Nesting works. gsub's non-greedy capture stops at the first closing tag,
--     so "[red]a [gold]b[/] c[/]" used to close the red span early. Here an
--     open colour is pushed on a stack, and closing one re-emits the colour
--     underneath it (WoW's |r resets to default rather than to the enclosing
--     colour, so it has to be restated explicitly).
--   * "[[" escapes a literal "[", so a note can talk about the syntax itself.
--   * An unrecognised tag is left on screen verbatim instead of being silently
--     eaten, which makes a typo visible rather than mysterious.
--
-- Square and curly delimiters are interchangeable. Square is what the UI now
-- writes and teaches, because "[" and "]" are unshifted where "{" and "}" are
-- not, and notes get long. Curly stays valid permanently: it is what every
-- note written before this change uses, what every export string already
-- pasted into Discord uses, and what Blizzard's own chat syntax uses for
-- "{rt1}" and "{skull}". Accepting both costs one lookup table and spares a
-- destructive rewrite of user note bodies.
-- ============================================================================

local COLOR_NAMES = {
    red    = "ffff4040",
    green  = "ff40ff40",
    blue   = "ff66aaff",
    cyan   = "ff40e0e0",
    yellow = "ffffff40",
    orange = "ffffa040",
    gold   = "ffffcc33",
    purple = "ffb080ff",
    pink   = "ffff8cc6",
    white  = "ffffffff",
    grey   = "ffb0b0b0",
    gray   = "ffb0b0b0",
}

-- Accepts "mage", "Death Knight", "DEATHKNIGHT", "demon hunter", ...
local function NormalizeClassToken(token)
    return (token or ""):upper():gsub("[%s%-_]", "")
end

local function NormalizeColorHex(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", ""):gsub("%s", ""):lower()

    if hex:match("^%x%x%x%x%x%x$") then
        return "ff" .. hex
    elseif hex:match("^%x%x%x%x%x%x%x%x$") then
        return hex
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Scanner
--
-- One walk over the text, shared by rendering, stripping and the dynamic-tag
-- test. Those three used to carry their own near-identical copies of this
-- loop, which meant a change to what counts as a tag had to be made three
-- times or the preview would quietly disagree with the render.
--
-- Declared here, above its callers, because a local referenced before its
-- `local function` line compiles as a global lookup and is nil at runtime.
-- ---------------------------------------------------------------------------

local TAG_CLOSERS = {
    ["{"] = "}",
    ["["] = "]",
}

-- onText(chunk)                 literal text, including any unescaped delimiter
-- onTag(body, verbatim, at)     a complete tag: its inside, its source as typed,
--                               and the byte offset of its opening delimiter
local function ScanMarkup(text, onText, onTag)
    local index = 1
    local length = #text

    while index <= length do
        local pos = text:find("[{}%[%]]", index)

        if not pos then
            onText(text:sub(index))
            return
        end

        if pos > index then
            onText(text:sub(index, pos - 1))
        end

        local char = text:sub(pos, pos)
        local closer = TAG_CLOSERS[char]

        if text:sub(pos + 1, pos + 1) == char then
            -- Any doubled delimiter is that character literally, closers
            -- included. Only openers used to be escapable, which meant the
            -- help window's own "{{red}}" example rendered as "{red}}" - the
            -- trailing brace had nothing to pair with and fell through as
            -- ordinary text. Escaping both ends makes quoting the syntax work.
            onText(char)
            index = pos + 2

        elseif not closer then
            -- A lone closer is ordinary punctuation, not the start of anything.
            onText(char)
            index = pos + 1

        else
            local closePos = text:find(closer, pos + 1, true)
            local lineEnd = text:find("\n", pos + 1, true)

            -- A tag never spans a line. Without this bound, a stray "[" in
            -- ordinary prose would pair with a "]" further down the note and
            -- swallow every real tag in between - a far likelier accident with
            -- square brackets than it ever was with curly ones.
            if closePos and lineEnd and lineEnd < closePos then
                closePos = nil
            end

            if closePos then
                onTag(text:sub(pos + 1, closePos - 1), text:sub(pos, closePos), pos)
                index = closePos + 1
            else
                -- Unmatched: emit the delimiter and carry on, so tags after it
                -- still render.
                onText(char)
                index = pos + 1
            end
        end
    end
end

local function ClassColorHex(token)
    local class = NormalizeClassToken(token)
    if class == "" then return nil end

    local color = (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class))
        or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])

    if not color or not color.r then return nil end

    if color.GenerateHexColor then
        return color:GenerateHexColor()
    end

    return string.format("ff%02x%02x%02x",
        math.floor(color.r * 255 + 0.5),
        math.floor(color.g * 255 + 0.5),
        math.floor(color.b * 255 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Icon resolution
--
-- Icon lookups hit the game's spell/item caches, and a note re-renders on every
-- edit, resize and font change, so successful results are memoised.
--
-- Misses are deliberately NOT cached. Notes are first drawn at ADDON_LOADED,
-- when those caches can still be cold, and caching a failure there would leave
-- the raw "{item:19019}" text on screen for the rest of the session. Renders
-- are occasional rather than per-frame, so retrying a miss costs little.
-- ---------------------------------------------------------------------------

local spellIconCache = {}
local itemIconCache = {}

local function ResolveSpellIcon(token)
    if spellIconCache[token] then
        return spellIconCache[token]
    end

    local spellID = tonumber(token)
    local texture

    if spellID then
        if C_Spell and C_Spell.GetSpellTexture then
            texture = C_Spell.GetSpellTexture(spellID)
        end
        if not texture and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellID)
            texture = info and info.iconID
        end
    else
        -- Looking a spell up by name only works when the client already has it
        -- cached, so an ID is always the reliable form. Try anyway.
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(token)
            texture = info and info.iconID
        end
    end

    if texture then
        spellIconCache[token] = texture
    end
    return texture
end

local function ResolveItemIcon(token)
    if itemIconCache[token] then
        return itemIconCache[token]
    end

    local texture
    if C_Item and C_Item.GetItemIconByID then
        texture = C_Item.GetItemIconByID(tonumber(token) or token)
    end
    if not texture and GetItemIcon then
        texture = GetItemIcon(tonumber(token) or token)
    end

    if texture then
        itemIconCache[token] = texture
    end
    return texture
end

-- ":0" sizes the icon to the surrounding font height, so icons scale with the
-- note's font size instead of being pinned to a pixel size.
local function TextureEscape(texture)
    return "|T" .. tostring(texture) .. ":0|t"
end

-- ---------------------------------------------------------------------------
-- Live values
--
-- Tags that resolve to game state when the note is drawn, so one note adapts
-- instead of being rewritten per character, per key or per group.
--
-- Everything here reads plain APIs. Note that NPC names are secret inside
-- instances under 12.0, so {target} resolves on a player but will not on a
-- boss - it falls back to the tag text rather than erroring.
-- ---------------------------------------------------------------------------

local function SafeName(unit)
    if not UnitExists or not UnitExists(unit) then return nil end

    local name = UnitName(unit)

    -- The secret test comes first and on its own. NPC names are secret inside
    -- instances, and comparing a secret value - even to nil - is one of the
    -- operations addon code is not allowed to perform. issecretvalue is safe
    -- on any value, including nil, so it is the only thing that can go first.
    if issecretvalue and issecretvalue(name) then return nil end

    if type(name) ~= "string" or name == "" then return nil end

    return name
end

local function GetGroupMemberName(indexToken)
    local index = tonumber(indexToken)
    if not index or index < 1 then return nil end

    if IsInRaid and IsInRaid() then
        return SafeName("raid" .. index)
    end

    -- In a party, position 1 is you and 2-5 are the others, which is the order
    -- people naturally count a group in.
    if index == 1 then return SafeName("player") end
    return SafeName("party" .. (index - 1))
end

local function GetSpecName()
    if not GetSpecialization or not GetSpecializationInfo then return nil end
    local index = GetSpecialization()
    if not index then return nil end
    local _, name = GetSpecializationInfo(index)
    return name
end

local function GetRoleName()
    if not UnitGroupRolesAssigned then return nil end
    local role = UnitGroupRolesAssigned("player")
    if role == "TANK" then return "Tank" end
    if role == "HEALER" then return "Healer" end
    if role == "DAMAGER" then return "Damage" end
    return nil
end

local function GetKeystoneLevel()
    if not C_ChallengeMode or not C_ChallengeMode.GetActiveKeystoneInfo then return nil end
    local level = C_ChallengeMode.GetActiveKeystoneInfo()
    if not level or level == 0 then return nil end
    return tostring(level)
end

-- Tags taking no argument.
local SIMPLE_VALUES = {
    player   = function() return SafeName("player") end,
    target   = function() return SafeName("target") end,
    focus    = function() return SafeName("focus") end,
    zone     = function() return GetZoneText and GetZoneText() end,
    subzone  = function() return GetSubZoneText and GetSubZoneText() end,
    spec     = GetSpecName,
    role     = GetRoleName,
    keylevel = GetKeystoneLevel,
    time     = function() return date and date("%H:%M") end,
}

-- Tags taking an argument, as {key:value}.
local ARGUMENT_VALUES = {
    group = GetGroupMemberName,
}

-- Cheap test for whether a note needs re-rendering as the world changes. Notes
-- without any of these are rendered once and left alone.
function NS.HasDynamicMarkup(text)
    if type(text) ~= "string" or text == "" then return false end

    local found = false

    ScanMarkup(text,
        function() end,
        function(tag)
            if found then return end
            local key = (tag:match("^(%a+)") or ""):lower()
            if SIMPLE_VALUES[key] or ARGUMENT_VALUES[key] then
                found = true
            end
        end)

    return found
end

-- ---------------------------------------------------------------------------
-- Tag handling
-- ---------------------------------------------------------------------------

-- Returns: handled (boolean), text to emit (string or nil)
local function HandleTag(tag, colorStack)
    if tag == "" then
        return false
    end

    -- Closing tag. "{/}" is the canonical form; "{/col}", "{/color}", "{/red}"
    -- and friends are accepted so older notes keep working.
    if tag:sub(1, 1) == "/" then
        if #colorStack == 0 then
            return true, nil
        end

        table.remove(colorStack)

        -- Restate the enclosing colour, since |r drops back to the default
        -- rather than to the colour this span was nested inside.
        local enclosing = colorStack[#colorStack]
        if enclosing then
            return true, "|r" .. enclosing
        end
        return true, "|r"
    end

    local lower = tag:lower()

    -- Raid target markers: {rt1} .. {rt8}
    local markerIndex = lower:match("^rt([1-8])$")
    if markerIndex then
        return true, TextureEscape("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. markerIndex)
    end

    -- Bare colour name: {red} ... {/}
    local named = COLOR_NAMES[lower]
    if named then
        local code = "|c" .. named
        table.insert(colorStack, code)
        return true, code
    end

    -- Live value with no argument: {player}, {zone}, {keylevel}
    local simple = SIMPLE_VALUES[lower]
    if simple then
        local resolved = simple()
        -- Unresolvable is left as written rather than blanked, so a note that
        -- says "{target}" outside combat still reads as a placeholder instead
        -- of a gap you can't account for.
        if type(resolved) == "string" and resolved ~= "" then
            return true, resolved
        end
        return false
    end

    local key, value = tag:match("^(%a+):(.*)$")
    if not key then
        return false
    end

    key = key:lower()
    value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if key == "col" or key == "color" then
        local hex = NormalizeColorHex(value)
        if not hex then return false end
        local code = "|c" .. hex
        table.insert(colorStack, code)
        return true, code
    end

    if key == "class" then
        local hex = ClassColorHex(value)
        if not hex then return false end
        local code = "|c" .. hex
        table.insert(colorStack, code)
        return true, code
    end

    if key == "spell" then
        local texture = ResolveSpellIcon(value)
        if not texture then return false end
        return true, TextureEscape(texture)
    end

    if key == "item" then
        local texture = ResolveItemIcon(value)
        if not texture then return false end
        return true, TextureEscape(texture)
    end

    if key == "tex" or key == "icon" then
        if value == "" then return false end
        return true, TextureEscape(value)
    end

    -- Live value taking an argument: {group:2}
    local argued = ARGUMENT_VALUES[key]
    if argued then
        local resolved = argued(value)
        if type(resolved) == "string" and resolved ~= "" then
            return true, resolved
        end
        return false
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Checklists
--
-- "[ ]" and "[x]" become tickable boxes. The delimiters are the ones the
-- tokenizer already uses, so this needs no new syntax - "[ ]" is simply a tag
-- whose body is a space.
--
-- The tick lives in the note's own text rather than in a side table keyed by
-- line. Keying by line means inserting a line above shifts every tick below
-- it; keying by text means renaming an item loses its tick. Storing the state
-- inline has neither problem, and it means an exported checklist carries its
-- progress with it for free.
--
-- Boxes are drawn as textures inside a hyperlink rather than as a character. A
-- FontString cannot hold a real widget, and a hyperlink is the only clickable
-- region WoW offers inside one - the same mechanism that makes item links in a
-- note work. Textures rather than glyphs because a non-ASCII character is a
-- gamble on this client: the multiplication sign silently failed to render.
-- ---------------------------------------------------------------------------

local CHECKBOX_TAGS = {
    [" "] = false,
    ["x"] = true,
    ["X"] = true,
}

local CHECKBOX_TEXTURES = {
    [false] = "Interface\\Buttons\\UI-CheckBox-Up",
    [true]  = "Interface\\Buttons\\UI-CheckBox-Check",
}

local function CheckboxEscape(index, checked)
    -- ":0" sizes the box to the surrounding font, so it scales with the note.
    return "|Hmynotes:check:" .. index .. "|h|T"
        .. CHECKBOX_TEXTURES[checked] .. ":0|t|h"
end

-- Every one of these walks the text with ScanMarkup rather than with a gsub
-- pattern, so they count boxes exactly the way the renderer numbers them.
--
-- A pattern cannot: "[[ ]]" is an escaped literal, not a box, and the renderer
-- knows that while a pattern does not. With the two disagreeing, a note holding
-- both an escaped bracket and real boxes would tick a different line than the
-- one under the cursor.
local function FindCheckboxes(text)
    local found = {}

    ScanMarkup(text,
        function() end,
        function(tag, verbatim, at)
            local checked = CHECKBOX_TAGS[tag]
            if checked == nil then return end

            table.insert(found, {
                at = at,
                length = #verbatim,
                checked = checked,
            })
        end)

    return found
end

-- Rewrites the box at `box` to `mark`, by splicing rather than by rebuilding
-- the string. Rebuilding from the scanner's output would lose escapes, since
-- "[[" reaches the text callback as a single "[".
local function ReplaceMark(text, box, mark)
    return text:sub(1, box.at) .. mark .. text:sub(box.at + box.length - 1)
end

-- Flips the index-th box, returning the new text. Returns nil when there is no
-- such box: the note may have been edited between being drawn and being
-- clicked, and doing nothing beats ticking the wrong line.
function NS.ToggleCheckboxInText(text, index)
    if type(text) ~= "string" then return nil end

    local box = FindCheckboxes(text)[index or 0]
    if not box then return nil end

    return ReplaceMark(text, box, box.checked and " " or "x")
end

-- Clears every tick, for the weekly or daily reset.
function NS.ClearCheckboxesInText(text)
    if type(text) ~= "string" then return text end

    local boxes = FindCheckboxes(text)

    -- Back to front, so each splice leaves the offsets before it still valid.
    for index = #boxes, 1, -1 do
        local box = boxes[index]
        if box.checked then
            text = ReplaceMark(text, box, " ")
        end
    end

    return text
end

function NS.HasCheckboxes(text)
    if type(text) ~= "string" then return false end
    return #FindCheckboxes(text) > 0
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function NS.RenderMarkup(text)
    if type(text) ~= "string" or text == "" then
        return text or ""
    end

    local out = {}
    local colorStack = {}

    -- Checkboxes are numbered in the order they appear, and that number is what
    -- a click sends back. Handled here rather than in HandleTag because it is
    -- the only tag whose output depends on how many came before it.
    local checkIndex = 0

    ScanMarkup(text,
        function(chunk)
            out[#out + 1] = chunk
        end,
        function(tag, verbatim)
            local checked = CHECKBOX_TAGS[tag]
            if checked ~= nil then
                checkIndex = checkIndex + 1
                out[#out + 1] = CheckboxEscape(checkIndex, checked)
                return
            end

            local handled, emit = HandleTag(tag, colorStack)

            if handled then
                if emit then
                    out[#out + 1] = emit
                end
            else
                out[#out + 1] = verbatim
            end
        end)

    -- Balance anything left open so colour can't bleed past the note.
    for _ = 1, #colorStack do
        out[#out + 1] = "|r"
    end

    return table.concat(out)
end

-- Plain-text version, for list previews and searching. Drops every tag and
-- unescapes "[[" / "{{" rather than rendering anything.
function NS.StripMarkup(text)
    if type(text) ~= "string" or text == "" then
        return text or ""
    end

    local out = {}

    ScanMarkup(text,
        function(chunk)
            out[#out + 1] = chunk
        end,
        function() end)

    return table.concat(out)
end

-- Exposed so the help window can list what's available without duplicating it.
NS.MARKUP_COLOR_NAMES = COLOR_NAMES

-- The same colours in a fixed order, for anything that has to present them as
-- a list. COLOR_NAMES is a hash, so iterating it directly would shuffle the
-- picker between sessions. Ordered by how often a raid note reaches for them,
-- and the grey/gray duplicate is left out.
NS.MARKUP_COLOR_ORDER = {
    "red", "gold", "green", "blue", "cyan",
    "orange", "purple", "pink", "yellow", "white", "grey",
}
