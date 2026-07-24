# Tiger User Word Management Design

## Goal

Enable complete user word management in both Tiger schemas while keeping their persisted data independent.

Both `tiger` and `tigress` will support:

- `Ctrl+;` to enter add-word capture;
- `target code + \\ + Space` as a fallback add-word entry method;
- `Ctrl+'` to disable the selected candidate;
- `Ctrl+Arrow` and the existing platform variants to reorder candidates.

## Data Isolation

The active `schema_id` selects a fixed profile:

| Schema | User dictionary | Source dictionaries |
| --- | --- | --- |
| `tiger` | `tiger.user.dict.yaml` | Tiger user, extended, common, and main dictionaries |
| `tigress` | `tigress.user.dict.yaml` | Tigress user, extended, common, CI, simplified CI, and main dictionaries |

Added entries, disabled markers, generated weights, and in-memory state are scoped to that profile. Switching schemas in the same Rime process must not reuse the other schema's cached state.

The existing Tigress legacy migration from `tigress.extended.dict.yaml` remains supported. Tiger uses its own existing user layer and never imports Tigress records.

## Approaches Considered

### Duplicate the Lua implementation

Separate Tiger and Tigress copies would make file selection explicit, but fixes would need to be duplicated and could drift. This approach is rejected.

### Read every path from schema YAML

A fully YAML-driven module would be reusable outside this repository, but it adds list parsing and configuration failure modes for only two known schemas. This approach is rejected for now.

### Shared implementation with schema profiles

One implementation selects a validated built-in profile from `env.engine.schema.schema_id`. This keeps behavior consistent while making persistence boundaries explicit. This approach is selected.

## Module Structure

- `lua/tiger_user_words.lua` contains the shared processor, filter, profile selection, persistence, and per-profile state cache.
- `lua/tigress_user_words.lua` becomes a compatibility wrapper returning `require("tiger_user_words")`, so older custom schemas do not fail immediately.
- `lua/tiger_add_trigger.lua` contains pure helpers for validating and extracting the two-backslash suffix.

Unknown schema IDs are rejected with a logged error and a no-op component. They must never fall back to either user dictionary, because doing so could write data into the wrong schema.

## Schema Integration

The shared processor and filter move into `tiger_base.schema.yaml`, which is inherited by both public schemas.

Processor order:

1. existing option and command processors;
2. `tiger_user_words`;
3. `space_proc3` and `symbol_proc`;
4. standard Rime processors.

This order lets the fallback capture its backslashes and Space before generic punctuation handling.

Filter order places `tiger_user_words` before `core2022_filter`, preserving immediate user-word display before character-set filtering.

The duplicated `engine` override in `tigress.schema.yaml` is removed after the common behavior is present in the base schema.

## Backslash Trigger

The fallback sequence is:

```text
target code + \\ + Space
```

Rules:

- only a normal non-empty Tiger code may precede the suffix;
- two consecutive plain backslashes are required;
- the complete suffix is visible and editable before Space;
- a status candidate explains that Space enters add-word capture;
- leading-backslash inputs are never intercepted;
- `\djs`, `\tj`, symbol codes, and other existing commands retain their behavior;
- modified backslashes and key-release events are ignored by this trigger.

Lua represents the two literal backslashes as `"\\\\"`. Matching uses plain string operations rather than regular expressions to avoid another escaping layer.

## Existing Operations

After either add-word entry method, the existing capture flow is reused. Add, disable, and reorder persistence functions receive the active profile through the environment/state rather than reading a global Tigress configuration.

Candidate types and log labels use neutral Tiger-family names. Existing generated markers remain readable so current Tigress user data is not lost.

## Documentation

Update all user-facing and example documentation:

- README describes complete support in both schemas and both add-word entry methods.
- Configuration guide removes `tigress`-only and "do not enable in tiger" statements.
- Example schema shows the shared processor/filter placement before punctuation and character-set filters.
- Data-path documentation explicitly states that Tiger and Tigress write separate user dictionaries.

## Tests

Automated tests cover:

- profile resolution for `tiger`, `tigress`, and unknown schemas;
- separate user dictionary paths and independent state caches;
- valid and invalid two-backslash suffix parsing;
- processor behavior for two backslashes followed by Space;
- preservation of `Ctrl+;`, `Ctrl+'`, and reorder shortcuts in both profiles;
- leading-backslash command pass-through;
- shared processor/filter order inherited by both schemas;
- compatibility loading through `tigress_user_words.lua`;
- documentation listing both schemas, both entry methods, and separate storage;
- Lua syntax and the repository's full existing test suite.

Tests use temporary fixture dictionaries or mocked Rime contexts and must not modify real user dictionary files. Generated Rime build artifacts and user data are not committed.
