# Tiger Table Export Design

## Goal

Add an in-Rime command that exports the complete effective table for the
currently active `tiger` or `tigress` schema as one portable UTF-8 text file.
The export includes static characters and words, hand-maintained user entries,
symbol commands, and the active schema's runtime user additions, removals, and
candidate ordering.

## User Interaction

The command is `\\dcck`, with the visible description `导出词库`. It is also
listed by the existing backslash command hint translator.

Selecting the command opens a two-candidate confirmation menu:

1. `确认导出当前方案`
2. `取消`

The exporter reads `env.engine.schema.schema_id` at invocation time. It exports
`tiger` when the active schema is `tiger`, and `tigress` when it is `tigress`.
Any other schema produces an `仅支持 tiger / tigress` notice without creating
or replacing a file.

Export runs synchronously only after confirmation. Normal typing performs only
a cheap command-input check and does not scan dictionaries. No live progress
bar is shown because librime-lua cannot reliably repaint the candidate window
while synchronous export work is running. After completion, the menu reports
the exported row count and full path. Failure reports a concise reason and
leaves any previous successful export untouched.

## Output Contract

The exporter writes to the Rime user data directory using a stable,
schema-specific ASCII filename:

- `tiger_export.txt`
- `tigress_export.txt`

The file is UTF-8 without a BOM, uses LF line endings, and contains no header,
comments, blank lines, or weights. Each row has exactly two tab-separated
fields:

```text
的\tu
的\tuni
我们\ttuja
```

Rows are ordered by ASCII code order. Entries sharing a code follow the
effective Rime candidate order: runtime user weights first, then static weights
descending, with stable source order as the tie-breaker. Exact duplicate
`text + code` pairs are removed, while one text with multiple distinct codes is
preserved.

Text or code containing tab, LF, CR, or NUL cannot be represented safely in
this TSV contract and is skipped. This intentionally excludes the `\\tab`
symbol whose output is a literal tab. The completion notice includes the
number of skipped unsafe rows.

## Static Dictionary Collection

Collection starts from the active schema's actual `translator/dictionary`
configuration and validates that it resolves to the supported entry:

- `tiger` uses `tiger.extended`, whose direct source set is `tiger` and
  `tiger.user`;
- `tigress` uses `tigress.extended`, whose direct source set is `tigress`,
  `tigress_ci`, `tigress_simp_ci`, and `tigress.user`.

The parser reads each dictionary's YAML header only far enough to obtain
`name`, `sort`, `import_tables`, and `columns`, then reads TSV rows after the
`...` marker. Every imported file is interpreted using its own `columns`
mapping because Tiger and Tigress source files use different column orders.
Rime's direct-import behavior is preserved; imports of imported files are not
expanded recursively.

The current supported source sets have explicit codes, disable preset
vocabulary, and contain no blank-code entries. Encountering an unsupported
blank-code row is treated as a skipped row and reported instead of attempting
to reproduce Rime's phrase encoder.

## Symbols

Static quick symbols already present in `tiger.user.dict.yaml` or
`tigress.user.dict.yaml` flow through normal dictionary collection.

The exporter additionally reads `punctuator/symbols` from the active compiled
schema configuration. Each `code -> candidate or candidate list` mapping is
inverted into normal `text<Tab>code` rows while retaining the configured
candidate order.

Mode-dependent `punctuator/full_shape` and `punctuator/half_shape` mappings are
not exported because they describe direct key behavior rather than table
codes. OpenCC transformations, generated emoji, calculator results, dates,
and other Lua translator output are also outside the table.

## Runtime User Overlay

The existing `tiger_user_words` module remains the owner of the custom LevelDB
record format. It exposes a read-only export snapshot for the active supported
schema instead of duplicating LevelDB parsing in the exporter.

The snapshot contains every stored `code + text` record with its `added`,
`hidden`, and `weight` fields. The exporter applies it after static collection:

- `hidden` removes the matching static or added pair;
- `added` inserts a missing pair;
- a non-zero runtime `weight` determines same-code candidate order;
- unchanged static pairs keep their static weight and stable source order.

This yields the table the current user actually sees, including shortcut-added
words, blocked candidates, and manual candidate reordering. Data remains
isolated between the `tiger_user_words_tiger` and
`tiger_user_words_tigress` databases.

## Components

### Pure Export Core

A focused Lua module handles dictionary-header parsing, TSV row parsing,
deduplication, runtime overlay application, symbol-row normalization, sorting,
unsafe-field filtering, and UTF-8/LF rendering. It accepts injected file and
symbol data so its behavior can be unit tested without a live Rime engine.

### Rime Command Adapter

A small translator and processor pair owns the `\\dcck` confirmation and
result states. It detects the current schema, obtains the runtime snapshot from
`tiger_user_words`, reads compiled symbol configuration, calls the pure core,
and writes the result atomically.

The command adapter is registered in `rime.lua`, placed in the shared Tiger
processor and translator lists, and added to `symbol_hint.lua` with the label
`导出词库`.

### Atomic Writer

Output is first written to a sibling temporary file. The adapter closes the
file successfully before replacing the stable destination. Replacement uses
the repository's existing cross-platform rename/remove pattern so a parsing,
write, or replacement failure cannot truncate a previous export.

## Error Handling

Export is rejected before writing when the active schema is unsupported, the
configured dictionary does not match the supported schema, a required source
file cannot be opened, its header lacks the `...` marker, or required columns
are absent. Individual comments, blank rows, malformed optional rows, duplicate
pairs, and unsafe control-character rows are skipped and counted.

Temporary files are cleaned up after failures when possible. LevelDB access is
read-only during export. The export never mutates source dictionaries, symbol
configuration, or user records.

## Testing

Pure Lua unit tests cover:

- `tiger` and `tigress` column layouts and direct imports;
- words, characters, quick symbols, and `punctuator/symbols` inversion;
- exact-pair deduplication and preservation of alternate codes;
- runtime additions, hidden rows, and reordered candidates;
- code ordering and stable same-code ordering;
- UTF-8 output, LF endings, and omission of BOM, header, and weights;
- rejection of tab/newline/control-character fields including `\\tab`;
- missing files, invalid headers, unsupported schemas, and atomic-write
  failure behavior.

Command integration tests cover confirmation, cancellation, active-schema
detection, success and failure notices, and no work outside `\\dcck`. Static
configuration tests verify module registration, processor/translator wiring,
and the command hint. The full existing Lua, Python, and JavaScript test suites
must remain green.

## Out Of Scope

- Exporting `PY_c`, `stroke`, `easy_english`, or arbitrary third-party schemas;
- exporting standard Rime user databases not owned by `tiger_user_words`;
- a live progress bar or background worker;
- exporting mode-dependent punctuation behavior or generated translator and
  OpenCC results;
- reproducing Rime's automatic phrase encoder or preset vocabulary compiler;
- changing, importing, or restoring user dictionaries.
