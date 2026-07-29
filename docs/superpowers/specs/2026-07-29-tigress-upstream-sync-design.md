# Tigress Upstream Sync Design

## Goal

Automatically monitor the official Tiger word-and-character table at
`lvyww/tiger-code`, merge its changes into this repository's `tigress` Rime
dictionaries, and push verified updates directly to `main`.

The synchronization must preserve this repository's additional full-Unicode
character coverage. It must not modify the single-character `tiger` scheme,
user dictionaries, schemas, or Lua behavior.

## Scope

The sync manages these generated dictionaries:

- `tigress.dict.yaml`
- `tigress.common.dict.yaml`
- `tigress_ci.dict.yaml`
- `tigress_ci.common.dict.yaml`
- `tigress_simp_ci.dict.yaml`
- `tigress_simp_ci.common.dict.yaml`

It also manages an exact copy of the last successfully synchronized upstream
table and its source revision:

- `vendor/tiger-code/tables/tiger.txt`
- `vendor/tiger-code/REVISION`

It does not modify:

- any `tiger*` dictionary or schema;
- `tiger.user.dict.yaml` or `tigress.user.dict.yaml`;
- schema configuration, Lua modules, or unrelated data files.

## Upstream Characteristics

The official `tables/tiger.txt` is an Fcitx5 table with two columns in its
`[Data]` section: code followed by text. It contains the complete word table,
the complete BMP Unified Ideographs and Extension A character sets, and a
selected set of characters from later extensions.

The Rime dictionaries in this repository contain substantially more
Extension B-I and compatibility characters. Those local-only character rows
are intentional and must survive synchronization.

The upstream format contains ordering but no numeric frequency or Rime stem.
Existing local metadata is therefore authoritative for matching entries.

## Approaches Considered

### Additive sync with only a revision marker

This can add missing upstream entries but cannot distinguish a removed
upstream entry from a repository-specific extension. It cannot reliably
process deletions or code changes and is rejected.

### Rebuild from upstream and append local characters

This produces tidy files but loses provenance for local words and risks broad
frequency and candidate-order changes. It is rejected.

### Tracked snapshot with three-way merge

The repository stores the previous official table. The synchronizer compares
the previous official set, the new official set, and the current local
dictionaries. This precisely manages upstream additions, deletions, and code
changes while preserving records that were never in the previous snapshot.
This approach is selected.

## Components

### Synchronization script

`scripts/sync_tigress.py` owns parsing, validation, classification, merging,
common-dictionary derivation, and deterministic file output. It accepts an
upstream checkout or table path and revision explicitly so tests do not need
network access.

The script parses complete files before writing. It writes results through
temporary files followed by atomic replacement so a parsing or validation
failure cannot leave partially updated dictionaries.

### Upstream snapshot

`vendor/tiger-code/tables/tiger.txt` is kept byte-for-byte from the last
successful synchronization. `vendor/tiger-code/REVISION` contains the full
40-character Git commit SHA followed by a newline.

The first synchronization treats all current upstream rows as managed rows,
adds any that are absent locally, and establishes the baseline. Future runs
use the tracked snapshot to recognize upstream removals.

### GitHub Actions workflow

`.github/workflows/sync-tigress.yml` runs daily at `22:00 UTC`, which is
`06:00 Asia/Shanghai`, and exposes `workflow_dispatch` for manual runs.

The workflow checks out `main`, clones the upstream default branch to a
temporary directory, captures its exact HEAD revision, runs the synchronizer,
runs all relevant tests, and inspects the changed-path allowlist. If there is
no change it exits successfully. Otherwise it commits as
`github-actions[bot]` and pushes `HEAD:main`.

The workflow has a concurrency group with cancellation disabled. A push race,
branch protection rejection, network error, validation failure, or test
failure leaves `main` unchanged and is visible as a failed Actions run.

## Data Classification

Each upstream data row is classified by Unicode text length and code length:

- one Unicode scalar value: `tigress.dict.yaml`;
- more than one scalar value and a four-letter code:
  `tigress_ci.dict.yaml`;
- more than one scalar value and a one-to-three-letter code:
  `tigress_simp_ci.dict.yaml`.

Codes must contain only lowercase ASCII letters and have length 1-4. Text must
be non-empty. Exact `(text, code)` pairs must be unique.

## Three-Way Merge

For each full dictionary, the synchronizer builds the old-upstream and
new-upstream pair sets for that dictionary class.

- A pair in the new upstream is present in the result.
- A pair in the old upstream but not the new upstream is removed.
- A local pair that was not in the old upstream is retained.
- A matching local row retains its existing weight and optional stem.
- A newly added pair receives a weight inferred from the nearest retained
  upstream neighbors in source order. Equal surrounding weights are reused;
  otherwise the nearest preceding weight is preferred, followed by the next
  weight and finally a conservative per-dictionary minimum.
- New rows are placed according to upstream-relative order without reordering
  unrelated local-only rows.

Because upstream does not publish numeric frequencies, upstream reordering
alone does not rewrite existing weights. This deliberately protects current
Rime candidate behavior while still synchronizing membership and codes.

The dictionary `version` value is updated to the upstream commit date only
when the table content changes.

## Common Dictionaries

Common dictionaries are derived from the merged full dictionaries rather
than merged independently.

The set of common characters is read from `core2022.dict.yaml`:

- `tigress.common.dict.yaml` contains exactly the full character rows whose
  text exists in the core set;
- word rows are excluded from `tigress_ci.common.dict.yaml` and
  `tigress_simp_ci.common.dict.yaml` only when they contain a CJK-range
  character absent from the core set;
- punctuation and non-CJK characters do not make a phrase non-common.

Headers, encoder rules, and imports remain the existing target file's own
metadata. Only its `version` and data section are generated.

## Validation And Failure Handling

Before writing, the script requires:

- valid UTF-8 input with exactly one `[Data]` marker;
- two tab-separated fields in every upstream data row;
- valid, unique codes and non-empty text;
- conservative minimum counts for characters, full-code words, and short-code
  words;
- no source category increasing or decreasing by more than 20 percent from
  the tracked snapshot.

After generation it verifies:

- every new upstream pair is present in its target;
- every removed managed pair is absent;
- every previous local-only pair is retained;
- all target pairs are unique;
- common dictionaries exactly match the core filtering rules;
- a second identical run produces no file changes.

The workflow additionally rejects any changed path outside the six managed
dictionaries and the two upstream snapshot files. All validation occurs
before commit and push.

## Tests

Python unit tests use small temporary fixtures and cover:

- valid and malformed Fcitx5 parsing;
- Unicode-scalar and code-length classification;
- additions, deletions, and code changes;
- preservation of local-only extension characters and words;
- retention of existing weights and stems;
- inferred weights for new entries;
- exact common-character and common-phrase filtering;
- source size guardrails;
- atomic, deterministic, idempotent output.

An integration test runs the synchronizer against the tracked real upstream
snapshot and copies of the repository dictionaries. Repository verification
also runs every existing Lua and Node test plus Python discovery.

## Operational Result

A normal no-change run creates no commit. A valid upstream table change
creates one direct commit on `main` named
`chore: sync tigress dictionaries from tiger-code <short-sha>`. Any abnormal
condition stops before a commit and relies on the standard GitHub Actions
failure log and notification.
