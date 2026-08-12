# Guided Word Capture Input Design

## Goal

Port the safer guided word-capture input behavior from Moran into Tiger while
keeping Tiger's existing user-word database, per-schema isolation, migration,
word removal, and candidate reordering.

The capture workflow must support both Chinese candidate composition and
lowercase literal English without introducing a Tiger-specific input mode or
mode-switch shortcut.

## User Interaction

The existing entry forms remain unchanged:

- type the target code and press `Ctrl+;`;
- type the target code followed by `\\`, then press `Space`.

While capture is active, normal Rime Chinese/English state determines how
printable input is interpreted:

- In Chinese mode, lowercase letters edit the current candidate lookup query.
- With a non-empty query, `Space`, configured number-selection keys, `;`, and
  `'` append the selected candidate's genuine text.
- With an empty query, uppercase letters, digits, spaces, printable symbols,
  and numeric-keypad characters append literal text without changing mode.
- The current punctuation options apply to one-shot punctuation entered in
  Chinese mode.
- The user's normal bare-`Shift` action toggles Rime's existing `ascii_mode`.
  After it switches Rime to English mode, printable letters, digits, spaces,
  symbols, and numeric-keypad characters append literal text directly.
- Pressing `Shift` again returns to Chinese lookup behavior through the normal
  Rime state transition.
- Unsupported printable keys are consumed during capture so they cannot leak
  to downstream processors or the active application.
- `Backspace` removes the last query character, or the last captured Unicode
  character when the query is empty.
- `Enter` saves a non-empty capture and returns to the target code.
- `Esc` cancels without writing data.

The capture status candidate and prompt display whether input is currently
`Chinese candidate selection` or `English direct input`. They do not describe
or introduce a separate Tiger mode.

## State And Processor Ordering

Each Rime engine owns at most one capture. Processor and filter instances for
the same engine resolve the capture through an engine-specific context token;
captures must not leak between windows, schema engines, or application
sessions.

A capture contains:

- immutable target `code`;
- accumulated `text`;
- current Chinese lookup `query`;
- optional transient `message`;
- the `ascii_mode` value that was active on entry.

The Tiger user-word processor moves before `ascii_composer`. Outside capture
it returns `kNoop`, preserving normal behavior. During capture it handles the
standard Shift gesture itself: pressing and releasing Shift without another
key toggles the existing `ascii_mode`, while `Shift+letter` records an
uppercase literal without toggling the mode. This is necessary because
`ascii_composer` cannot correctly distinguish a bare Shift from
`Shift+letter` after the capture processor has consumed the letter. All other
capture input is accepted before `ascii_composer` can commit it to the active
application.

Saving, cancelling, finalization, or a failed entry transition restores the
entry-time `ascii_mode`. This also ensures that returning to the target code
can display its newly added candidate.

## Components

### Capture Input Helper

Add a focused Lua helper responsible for:

- printable ASCII and numeric-keypad conversion;
- selection-key classification;
- Chinese-mode query, selection, and one-shot literal classification;
- English-mode literal classification;
- punctuation conversion using `ascii_punct` and `full_shape`.

The helper does not access Rime databases or global capture state.

### Tiger User Words

Extend `tiger_user_words.lua` to:

- manage per-engine capture sessions;
- preserve and restore `ascii_mode`;
- route capture key events through the helper;
- consume unsafe events during capture;
- show current language behavior and storage errors;
- keep the existing `persist_weight`, `persist_disable`, migration, and
  candidate-ordering paths unchanged.

### Schema And Documentation

Move the Tiger user-word processor before `ascii_composer` in the shared
schema. Update the README with examples for Chinese composition, lowercase
English, and mixed entries.

## Storage And Error Handling

Adding a word continues to call Tiger's existing `persist_weight` path. The
Moran pin database, its shared namespace, and its eight-entry limit are not
ported.

An empty save remains in capture and shows an empty-word message. A database
failure remains in capture, preserves all text, and shows a retry message.
Cancellation and processor finalization never persist incomplete text.

## Testing

Lua unit tests cover:

- Chinese candidate lookup and selection;
- lowercase English direct input while `ascii_mode` is enabled;
- uppercase, digits, spaces, symbols, and numeric-keypad input;
- punctuation behavior in Chinese and English states;
- bare-Shift toggling and `Shift+letter` without a custom capture mode;
- unsupported-key consumption and modifier safety;
- Unicode backspace;
- empty-save and database-failure recovery;
- capture isolation between engines;
- restoration of the entry-time `ascii_mode` after save and cancellation;
- unchanged add, remove, reorder, migration, and trigger behavior.

Static configuration tests assert processor ordering for both Tiger schemas.

## Out Of Scope

- Replacing Tiger's LevelDB record format with Moran pin records;
- imposing Moran's per-code pin limit;
- adding a custom text-mode toggle or overloading uppercase input as a mode
  transition;
- changing normal input behavior outside an active capture;
- modifying the sibling `rime-moran` working tree.
