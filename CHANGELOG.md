# Changelog

## 1.12.0

Everything from 1.11.0 carries across untouched — your notes, folders,
positions, fonts and display rules all survive the upgrade. Two settings are
retired and are cleaned out of your saved data automatically; both are noted
below.

### Organising

- **Folders.** Group notes however you think about them. Drag a note onto a
  folder, or right-click it to file it. Folders collapse, carry a count, and
  are deleted from the header without touching the notes inside — those go
  back to Unfiled.
- **Checklists.** Write `[ ]` or `[x]` and the note draws a real checkbox you
  can click on screen. Useful for a weekly reset list you tick off as you go.
- **Clickable links.** `[spell:116]` and `[item:19019]` render as the real
  spell or item, with the game's own tooltip on hover and a working link on
  click.

### Appearance

Displayed notes stay plain by default — text on the screen with nothing behind
it, exactly as they have always been. Everything here is opt-in, per note.

- **Background and Edge** are separate choices. Background is None, Shade or
  Card; Edge is None, Accent rail or Accent border. Nine combinations from two
  controls.
- **Accent colour and thickness.** Colour the rail or border from the markup
  palette, 1–8px, so raid callouts and personal reminders are told apart at a
  glance.
- **Rail side.** The accent rail runs along whichever edge you choose. A note
  parked against the right of the screen reads better railed on its right.
- **Text colour, alignment and outline**, plus a text opacity slider that now
  affects only the text — the background and edge keep their own strength,
  which is what makes a faded note still readable.

### The window

- **Ornament bars** across the header and footer, with the accent lines and
  end pieces following your colour theme.
- **Side panels dock to the main window.** Markup help attaches on the left,
  settings, display rules and sharing on the right. They follow the window as
  it moves and resizes, and dragging one moves the whole cluster.
- **One menu open at a time.** Opening a dropdown, a right-click menu or a
  side panel closes whatever was already open instead of stacking over it.
- **Segmented buttons** replace the dropdowns for short settings, so the
  options are visible without a click and the panel is shorter.
- The note settings panel scrolls, so it no longer bunches up when the window
  is made small.

### Display rules

- **A status band** explaining, rule by rule, exactly what a hidden note is
  waiting on rather than just reporting that it is hidden.
- **Timing reads "show at 90s for 60s"** instead of "90s to 150s", which is
  how people actually describe a callout.
- The window was rebuilt: no empty box before the first rule is added, a
  usable scrollbar, and the close button no longer overlaps the dropdown.

### Locked notes

A locked note is click-through, so clicks reach the game world behind it.
**Hold Alt** — or Ctrl or Shift, set it in Settings — to hand the note back to
the mouse for as long as the key is down, so it can be moved, resized or
edited without unlocking it first.

### Removed

- **Reminders and the "After login" rule.** Neither earned its place.
- **The per-note text shadow setting.** Every note now draws the soft shadow
  that was always the default; the outline setting is the better answer for
  text you cannot read over bright terrain.
- **Automatic checklist clearing.** Checkboxes are cleared by clicking them.
- **The Mythic+ affix rule.**

### Fixed

- Inserting a checkbox or a colour from the toolbar put it at the end of the
  note instead of at the cursor.
- Selecting "Out of combat" on a combat rule did nothing and would not stay
  selected.
- An imported note with a raid encounter rule never matched, because the
  encounter was compared as text against a number.
- The display rules status band threw a Lua error on some colour updates and
  did not refresh when a rule was added.
- The manager jumped in size the moment the resize corner was pressed.
- The "x of y notes" count was wrong while folders were collapsed.


## 1.11.0

Built and tested against patch 12.1. Everything from 1.10.0 keeps working —
your notes, their positions, fonts and opacity all carry across untouched.

### Display Rules

Notes can now decide for themselves when to appear. A note with no rules
behaves exactly as it always has.

- **Raid encounter.** Pick the raid, then the boss, then the difficulty, from
  lists read out of the game's own Encounter Journal — no IDs to look up. The
  lists come from whatever season your client is on, so they stay right after
  a patch adds a raid.
- **Timing windows.** Show a note between, say, 90 and 150 seconds into a
  pull. One rule can hold several windows, so a note that pops three times in
  a fight is one rule, not three. A timeline under the fields draws the whole
  pattern against the length of the fight.
- **Fight lengths are learned.** MyNotes records how long your pulls actually
  run and scales the timeline to that, so the axis is right for your group
  rather than for an average one. The first pull of a new boss has nothing to
  go on yet.
- **Other rules.** In or out of combat, your role, your specialisation,
  keystone level, active affix, instance type, and zone.

A note about what is *not* here: rules cannot key off boss health or boss
casts. Under 12.0's Secret Values those are not readable by addons, and the
combat log is gone from group content. Time since pull is the honest
stand-in, and it is what the timing windows use.

### Writing notes

- **Square brackets.** Tags can now be written `[red]like this[/]`, which
  needs no Shift key. Curly braces still work everywhere and always will —
  old notes and old export strings are unaffected, and you can mix the two.
- **A toolbar** above the editor: eight colour swatches and the eight raid
  markers. Select a word and click a swatch to wrap it; click with nothing
  selected to start a span at the cursor.
- **A live preview** under the editor showing the note as it will actually
  look — right font, right colours, right icons — updating as you type. It
  scrolls, so a long note can be read all the way through.
- **The markup help window inserts.** Click any row to drop that tag into the
  note instead of retyping it.
- **Live values.** `[player]`, `[target]`, `[focus]`, `[zone]`, `[subzone]`,
  `[spec]`, `[role]`, `[keylevel]`, `[time]` and `[group:2]` resolve when the
  note is drawn, so one note covers every character and every group.
- **Fonts.** Any font MyNotes can see, per note or for all of them.
  LibSharedMedia fonts are picked up if another addon provides it.

### Sharing

- **Export and import strings.** A note becomes a single share code you can
  paste into Discord or a guild site, conditions and timing windows included.
  Imported notes always arrive switched off and centred rather than appearing
  on screen wherever they sat on someone else's monitor.

Note sharing over addon channels is still gone and is not coming back — 12.0
blocks addon communication inside instances, which is exactly where it would
have mattered.

### Elsewhere

- **Keybindings** for opening the manager and for showing or hiding every
  note at once.
- **A settings window**, reached by the gear icon, holding the minimap toggle
  and the colour theme.
- **Auto-stacking** to tidy visible notes into a column.
- Notes can be deleted straight from the list, and clicking a selected note
  again deselects it.

### Fixed

- Dragging a note or the manager by its corner no longer jumps before it
  resizes.
- `{{red}}` in the markup help showed as `{red}}`. Escaping now works at both
  ends of a tag.
- A stray `[` or `{` in ordinary prose could swallow every tag after it on
  following lines. Tags are now bounded to a single line.
- Export strings were not stable: the same note produced a different string
  after each client restart. They are now identical every time.
- Export strings contained `|` sequences that WoW's own text rendering treats
  as escape codes, so they could break when passed through parts of the game.
  Codes are now encoded and safe to paste anywhere. Strings exported by older
  versions still import.
- Scrollbars no longer appear when there is nothing to scroll.


## 1.10.0

### Please read before updating

Three changes affect setups you already have.

**Note sharing has been removed.** MyNotes no longer sends notes to party, raid
or a target, and no longer uses addon communication channels at all. If you
installed MyNotes in order to share notes with your group, this version does
not do that.

**Displayed notes no longer show their title.** A note's title is now only used
to find it in the manager list. Any note that previously showed a title on
screen will now show just its body text.

**The extra slash commands are gone.** `showall`, `hideall`, `lockall`,
`unlockall`, `theme` and `minimap` no longer exist — *if you use any of them in
a macro, that macro will stop working.* `/mn` and `/mynotes` still open the
manager, and the minimap button toggle has moved into the manager's settings
column.

Your notes are updated automatically the first time you log in. Notes saved
below 75% opacity are raised to 75%, which is exactly how they were already
being drawn.

### New

- **Colour themes.** Five palettes, including one that follows your class
  colour. Switch using the swatches in the manager's settings column.
- **More markup.** Raid target markers `{rt1}`–`{rt8}`, class colours
  `{class:mage}`, item icons `{item:19019}`, and arbitrary textures
  `{tex:path}`.
- **Colours nest properly.** `{red}Pull at {gold}3{/} stacks{/}` now does what
  it looks like. Write `{{` if you want a literal brace.
- **Markup Help rebuilt.** Every example is shown rendered next to the text
  that produced it, so you can see what a tag actually looks like instead of
  guessing from the syntax. The window can be moved and remembers where you put
  it.
- **The manager window is resizable** and remembers its size.
- Escape closes the Markup Help window first, then the manager.
- Note list rows show a preview of the body, highlight on hover, and mark
  pinned notes.

### Changed

- **Note controls fade in on hover.** Edit, close and resize no longer sit
  permanently on a note — until you reach for it, a displayed note is nothing
  but text on screen.
- **Locking a note now makes it click-through**, so clicks pass straight to the
  game world. The separate click-through option is gone; it only ever did
  anything on a locked note.
- **Opacity works across its whole range.** It previously had no visible effect
  below about 75%. At 0% a note is now genuinely invisible.
- Maximum note font size raised from 24 to 36.
- The manager has had a visual pass: clearer section headings, note options
  spelled out instead of abbreviated, and consistent typography throughout.

### Fixed

- **Creating a note with the New button failed with an error** instead of
  creating the note.
- **The minimap button never displayed properly** — it used a `.png`, which the
  game cannot load.
- Sending a note to a target threw an error after the note had already been
  sent. (Sharing has since been removed entirely.)
- The class-colour theme fell back to the default blue on a fresh login.
- Spell and item icons that could not be resolved as you logged in stayed on
  screen as raw text for the rest of the session.
- Unknown markup tags are now left visible instead of being silently deleted,
  so a mistyped tag is something you can see.
- The manager's saved window size was recorded but never actually applied.
- The note body in the editor now reflows when the window is resized.

### Removed

- Note sharing (party, raid and whisper).
- The per-note "show title", "click-through" and minimise options.
- All slash subcommands.
