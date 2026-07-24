# Tigress Backslash Add Trigger Design

## Goal

Keep `Ctrl+;` as the primary add-word shortcut and add a keyboard-layout-friendly fallback:

```text
target code + \\ + Space
```

The fallback applies only to the `tigress` schema. Existing commands whose input starts with a single backslash, such as `\djs` and `\tj`, must keep their current behavior.

## Approaches Considered

### Extend the speller alphabet

Adding backslash to `speller/alphabet` would let Rime build the suffix normally, but it interacts with the four-character code limit and changes parsing for every Tigress input. This has the widest regression surface and is rejected.

### Track two key presses only in Lua

A processor could consume the first backslash and wait for the second. However, cancelling the sequence cannot faithfully replay the consumed first key, so ordinary punctuation behavior could change. This is rejected.

### Append and recognize the suffix in the user-word processor

The Tigress user-word processor will run before the generic space and symbol processors. For a plain backslash after a non-empty normal code, it will append the literal character to `context.input`. When the input ends in two literal backslashes, a plain Space will remove the suffix and enter the existing add-word capture flow with the preceding code.

This approach is selected because it keeps the trigger visible and editable, bypasses the speller length limit without changing global spelling rules, and can distinguish normal codes from the leading-backslash command namespace.

## Behavior

- `Ctrl+;` continues to enter add-word capture without behavior changes.
- For a normal non-empty code, two consecutive plain backslashes are accepted as a suffix.
- Pressing Space when the input is exactly `target-code + \\` enters add-word capture for `target-code`.
- A leading backslash is never intercepted by this feature. `\djs`, `\tj`, symbol codes, and other existing commands continue through their current processors.
- One backslash is not enough to trigger add-word capture.
- Modified backslashes, key-release events, and inputs containing an earlier backslash are not treated as the fallback trigger.
- Backspace and Escape continue to use Rime's normal editing behavior before the final Space is pressed.

## Implementation Boundaries

- Move `tigress_user_words` before `space_proc3` and `symbol_proc` in the `tigress` processor chain so it can recognize the fallback before generic punctuation handling.
- Keep trigger parsing inside `lua/tigress_user_words.lua`; do not alter the shared `tiger_base` speller or recognizer.
- Represent two literal backslashes as `"\\\\"` in Lua source. Trigger matching must use plain string operations rather than a regular expression, avoiding another escaping layer.
- Reuse the existing `enter_capture` and capture/filter flow after extracting the target code.
- Show a short status candidate when the complete suffix is present so users know that Space will enter add-word mode.
- Update the README and configuration guide with both supported entry methods.

## Tests

Automated tests must cover:

- extracting a target code from a valid two-backslash suffix;
- rejecting empty codes, one backslash, leading-backslash commands, and extra embedded backslashes;
- preserving `Ctrl+;` handling;
- processor ordering before `space_proc3` and `symbol_proc`;
- documentation listing both entry methods;
- Lua syntax and the repository's full existing test suite.

No generated Rime build artifacts or user dictionary data will be committed.
