# Tigress Upstream Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Monitor `lvyww/tiger-code` daily and merge verified official table changes into only the `tigress` dictionaries while preserving repository-specific full-Unicode entries.

**Architecture:** A Python standard-library synchronizer parses the Fcitx5 source and Rime dictionaries, performs a snapshot-backed three-way merge, derives common dictionaries from `core2022`, and atomically writes deterministic output. A scheduled GitHub Actions workflow fetches an immutable upstream revision, verifies the result, and pushes a bot commit directly to `main`.

**Tech Stack:** Python 3.12 standard library and `unittest`, Rime YAML-style dictionaries, GitHub Actions, existing Lua and Node test scripts.

---

## File Map

- Create `scripts/sync_tigress.py`: parsing, classification, merge, validation, common filtering, atomic output, and CLI.
- Create `tests/test_sync_tigress.py`: unit and repository integration tests.
- Create `vendor/tiger-code/tables/tiger.txt`: exact last-synchronized official source.
- Create `vendor/tiger-code/REVISION`: last synchronized full Git SHA.
- Create `.github/workflows/sync-tigress.yml`: scheduled/manual sync and direct verified push.
- Modify `README.md`: document automatic synchronization, managed scope, schedule, and failure behavior.
- Modify six `tigress*.dict.yaml` files only through the synchronizer's initial reconciliation.

### Task 1: Parse And Classify Dictionary Data

**Files:**
- Create: `tests/test_sync_tigress.py`
- Create: `scripts/sync_tigress.py`

- [ ] **Step 1: Write failing parser and classifier tests**

Create tests that load the script as a module and assert the public parsing API:

```python
class UpstreamParserTest(unittest.TestCase):
    def test_parses_and_classifies_fcitx_data(self):
        path = self.write("KeyCode=abcdefghijklmnopqrstuvwxyz\n[Data]\nu\t的\ntu\t我们\ntuja\t我们\n")
        table = sync.parse_upstream(path)
        self.assertEqual([entry.kind for entry in table.entries], ["char", "short_word", "full_word"])
        self.assertEqual(table.entries[0].pair, ("的", "u"))

    def test_rejects_duplicate_pairs(self):
        path = self.write("[Data]\nu\t的\nu\t的\n")
        with self.assertRaisesRegex(sync.SyncError, "duplicate"):
            sync.parse_upstream(path)

    def test_rejects_invalid_code_and_columns(self):
        for row in ("A\t的", "abcde\t词", "a\t词\textra"):
            with self.subTest(row=row):
                path = self.write(f"[Data]\n{row}\n")
                with self.assertRaises(sync.SyncError):
                    sync.parse_upstream(path)
```

Also test missing or repeated `[Data]`, empty text, CRLF input, and a supplementary-plane character being classified as one character.

- [ ] **Step 2: Run the parser tests and verify RED**

Run: `python3 -m unittest tests.test_sync_tigress.UpstreamParserTest -v`

Expected: import failure because `scripts/sync_tigress.py` does not exist.

- [ ] **Step 3: Implement the parser and data types**

Define:

```python
class SyncError(RuntimeError):
    pass

@dataclass(frozen=True)
class UpstreamEntry:
    code: str
    text: str
    kind: Literal["char", "full_word", "short_word"]

    @property
    def pair(self) -> tuple[str, str]:
        return self.text, self.code

@dataclass(frozen=True)
class UpstreamTable:
    raw: bytes
    entries: tuple[UpstreamEntry, ...]

def classify(text: str, code: str) -> str:
    if len(text) == 1:
        return "char"
    return "full_word" if len(code) == 4 else "short_word"

def parse_upstream(path: Path) -> UpstreamTable:
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    lines = text.splitlines()
    markers = [index for index, line in enumerate(lines) if line == "[Data]"]
    if len(markers) != 1:
        raise SyncError("expected exactly one [Data] marker")
    seen = set()
    entries = []
    for line_number, line in enumerate(lines[markers[0] + 1 :], markers[0] + 2):
        fields = line.split("\t")
        if len(fields) != 2:
            raise SyncError(f"line {line_number}: expected two columns")
        code, value = fields
        if not value or re.fullmatch(r"[a-z]{1,4}", code) is None:
            raise SyncError(f"line {line_number}: invalid entry")
        pair = (value, code)
        if pair in seen:
            raise SyncError(f"line {line_number}: duplicate pair")
        seen.add(pair)
        entries.append(UpstreamEntry(code, value, classify(value, code)))
    return UpstreamTable(raw, tuple(entries))
```

Decode strictly as UTF-8, normalize only for parsing, require one `[Data]`, require exactly two tab-separated fields after it, validate `re.fullmatch(r"[a-z]{1,4}", code)`, and reject duplicate pairs.

- [ ] **Step 4: Verify GREEN**

Run: `python3 -m unittest tests.test_sync_tigress.UpstreamParserTest -v`

Expected: all parser tests pass.

- [ ] **Step 5: Commit parser behavior**

```bash
git add scripts/sync_tigress.py
git add -f tests/test_sync_tigress.py
git commit -m "feat: parse official tiger table"
```

### Task 2: Three-Way Merge And Common Derivation

**Files:**
- Modify: `scripts/sync_tigress.py`
- Modify: `tests/test_sync_tigress.py`

- [ ] **Step 1: Write failing Rime parser and merge tests**

Add fixtures with headers ending at `...`, tab-separated data rows, weights, and optional stems. Test this exact merge shape:

```python
old = entries(("旧词", "abcd", "full_word"), ("保留字", "a", "char"))
new = entries(("新词", "abcd", "full_word"), ("保留字", "a", "char"))
local = rime_rows(
    ("旧词", "50", "abcd"),
    ("本地词", "40", "wxyz"),
    ("保留字", "100", "a", "stem"),
)

merged = sync.merge_rows(local, old, new, default_weight=10)

self.assertNotIn(("旧词", "abcd"), merged.by_pair)
self.assertIn(("新词", "abcd"), merged.by_pair)
self.assertIn(("本地词", "wxyz"), merged.by_pair)
self.assertEqual(merged.by_pair[("保留字", "a")].fields, ("保留字", "100", "a", "stem"))
```

Add separate cases for a code change, preservation of a local Extension B character, duplicate local pairs, inferred preceding/next/default weights, and deterministic ordering.

- [ ] **Step 2: Run merge tests and verify RED**

Run: `python3 -m unittest tests.test_sync_tigress.RimeMergeTest -v`

Expected: failure because the Rime document and merge APIs are absent.

- [ ] **Step 3: Implement Rime document parsing and merge**

Define focused `RimeRow` and `RimeDocument` types:

```python
@dataclass(frozen=True)
class RimeRow:
    text: str
    weight: int
    code: str
    stem: str | None = None

@dataclass(frozen=True)
class RimeDocument:
    header: tuple[str, ...]
    rows: tuple[RimeRow, ...]
```

Implement `parse_rime(path)`, `merge_rows(local, old_entries, new_entries,
default_weight)`, and `render_rime(document, version)`. Split the Rime file at
the single `...` marker and parse each nonblank data row according to
`text, weight, code, optional stem`. Build the result by retaining all
local-only pairs, dropping old-managed pairs absent from new, reusing matching
local rows, and creating missing new rows. Infer a new row's weight from the
closest preceding retained upstream row, then the next retained row, then the
supplied default. Preserve optional stems and reject duplicate local pairs.
Rendering replaces only the first `version:` header and emits UTF-8 with LF
line endings and one final newline.

- [ ] **Step 4: Verify merge GREEN**

Run: `python3 -m unittest tests.test_sync_tigress.RimeMergeTest -v`

Expected: all merge tests pass.

- [ ] **Step 5: Write failing common-filter tests**

Test both character and phrase behavior:

```python
core = {"常", "用", "词"}
self.assertTrue(sync.is_common_text("常用词，OK", core))
self.assertFalse(sync.is_common_text("常𠀀词", core))
self.assertEqual(
    [row.text for row in sync.derive_common(char_rows, core, characters_only=True).rows],
    ["常", "用"],
)
```

Include Extension A-I, compatibility ideographs, CJK strokes/radicals, punctuation, Latin text, and an exact comparison against the current repository's 26 full-word exclusions.

- [ ] **Step 6: Run common-filter tests and verify RED**

Run: `python3 -m unittest tests.test_sync_tigress.CommonFilterTest -v`

Expected: failure because common filtering is absent.

- [ ] **Step 7: Implement core parsing and common derivation**

Mirror the CJK ranges used by `lua/core2022_filter.lua`, parse the core character set from `core2022.dict.yaml`, and implement:

```python
def is_common_text(text: str, core_chars: AbstractSet[str]) -> bool:
    return not any(is_cjk(char) and char not in core_chars for char in text)

def derive_common(
    source: RimeDocument,
    core_chars: AbstractSet[str],
    *,
    characters_only: bool,
) -> RimeDocument:
    if characters_only:
        rows = tuple(row for row in source.rows if row.text in core_chars)
    else:
        rows = tuple(row for row in source.rows if is_common_text(row.text, core_chars))
    return RimeDocument(source.header, rows)
```

Character dictionaries require direct core membership. Word dictionaries use `is_common_text` so punctuation is ignored.

- [ ] **Step 8: Verify all merge tests and commit**

Run: `python3 -m unittest tests.test_sync_tigress -v`

Expected: parser, merge, and common tests all pass.

```bash
git add scripts/sync_tigress.py
git add -f tests/test_sync_tigress.py
git commit -m "feat: merge upstream tigress entries"
```

### Task 3: Repository Synchronization And Official Baseline

**Files:**
- Modify: `scripts/sync_tigress.py`
- Modify: `tests/test_sync_tigress.py`
- Create: `vendor/tiger-code/tables/tiger.txt`
- Create: `vendor/tiger-code/REVISION`
- Modify: `tigress.dict.yaml`
- Modify: `tigress.common.dict.yaml`
- Modify: `tigress_ci.dict.yaml`
- Modify: `tigress_ci.common.dict.yaml`
- Modify: `tigress_simp_ci.dict.yaml`
- Modify: `tigress_simp_ci.common.dict.yaml`

- [ ] **Step 1: Write failing repository-level tests**

Create temporary miniature repositories with all six dictionaries, a core
dictionary, and optional old snapshot. Assert:

```python
result = sync.synchronize(
    repo_root,
    upstream_table,
    revision="a" * 40,
    version="2026.07.29",
    limits=sync.SafetyLimits(chars=1, full_words=1, short_words=1, max_delta=0.20),
)
self.assertTrue(result.changed)
self.assertEqual((repo_root / "vendor/tiger-code/REVISION").read_text(), "a" * 40 + "\n")
self.assertFalse(sync.synchronize(
    repo_root,
    upstream_table,
    revision="a" * 40,
    version="2026.07.29",
    limits=sync.SafetyLimits(chars=1, full_words=1, short_words=1, max_delta=0.20),
).changed)
```

Test a malformed revision, minimum-count failure, category delta over 20%, no writes after validation failure, all six dictionary outputs, snapshot byte preservation, and an output path allowlist.

- [ ] **Step 2: Run repository tests and verify RED**

Run: `python3 -m unittest tests.test_sync_tigress.RepositorySyncTest -v`

Expected: failure because `synchronize` and safety limits are absent.

- [ ] **Step 3: Implement orchestration and CLI**

Define:

```python
@dataclass(frozen=True)
class SafetyLimits:
    chars: int = 20_000
    full_words: int = 100_000
    short_words: int = 2_000
    max_delta: float = 0.20

@dataclass(frozen=True)
class SyncResult:
    changed: bool
    changed_paths: tuple[Path, ...]

```

Implement `synchronize(repo_root, upstream_path, revision, version,
limits=SafetyLimits()) -> SyncResult`. Validate the revision with
`re.fullmatch(r"[0-9a-f]{40}", revision)` and the version with
`re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", version)`. Validate category counts
against the absolute limits and, when an old snapshot exists, reject a
relative delta greater than `max_delta`. Parse all six targets and the core
dictionary, merge the three full targets, derive all common targets, and
verify official coverage and local-only preservation. Build every output byte
string before calling an
`atomic_write(path, content)` helper. The CLI requires
`--repo-root`, `--upstream-table`, `--revision`, and `--version`, prints a
compact count summary, and exits nonzero on `SyncError`.

- [ ] **Step 4: Verify repository GREEN**

Run: `python3 -m unittest tests.test_sync_tigress -v`

Expected: all unit tests pass.

- [ ] **Step 5: Add the official snapshot and run initial reconciliation**

Copy the exact upstream `tables/tiger.txt` at revision
`3e1bff2f757806152ef5b701c709c24f54cf800f` into
`vendor/tiger-code/tables/tiger.txt`, write that SHA to `REVISION`, then run:

```bash
python3 scripts/sync_tigress.py \
  --repo-root . \
  --upstream-table vendor/tiger-code/tables/tiger.txt \
  --revision 3e1bff2f757806152ef5b701c709c24f54cf800f \
  --version 2026.06.29
```

Expected: the 23 current official-only records are added, repository-only
full-Unicode rows and two local-only words remain, and the snapshot is
recorded.

- [ ] **Step 6: Add and run the real-data integration test**

The integration test copies the six dictionaries, core table, and snapshot
to a temporary directory, calls `synchronize` using the tracked snapshot as
both old and new input, asserts all 171,074 official pairs are represented,
and asserts a second run is unchanged.

Run: `python3 -m unittest tests.test_sync_tigress.RepositoryIntegrationTest -v`

Expected: PASS.

- [ ] **Step 7: Verify generated diff and commit**

Run:

```bash
git diff --check
git diff --stat
python3 -m unittest tests.test_sync_tigress -v
```

Expected: only the six managed dictionaries, script, test, and vendor files
are changed; tests pass.

```bash
git add scripts/sync_tigress.py vendor/tiger-code tigress*.dict.yaml
git add -f tests/test_sync_tigress.py
git commit -m "feat: synchronize tigress with official table"
```

### Task 4: Scheduled Direct-Commit Workflow And Documentation

**Files:**
- Create: `.github/workflows/sync-tigress.yml`
- Modify: `README.md`
- Modify: `tests/test_sync_tigress.py`

- [ ] **Step 1: Write failing workflow static tests**

Read the workflow text and assert it contains:

```python
self.assertIn("cron: '0 22 * * *'", workflow)
self.assertIn("workflow_dispatch:", workflow)
self.assertIn("contents: write", workflow)
self.assertIn("cancel-in-progress: false", workflow)
self.assertIn("python3 scripts/sync_tigress.py", workflow)
self.assertIn("git push origin HEAD:main", workflow)
```

Also assert the workflow runs Python, every `tests/*_test.lua`, every
`tests/*_test.js`, checks changed paths against the eight-file allowlist, and
does not trigger on `push`.

- [ ] **Step 2: Run workflow tests and verify RED**

Run: `python3 -m unittest tests.test_sync_tigress.WorkflowTest -v`

Expected: failure because the workflow does not exist.

- [ ] **Step 3: Create the GitHub Actions workflow**

Use this job shape:

```yaml
name: Sync official Tigress dictionaries

on:
  schedule:
    - cron: '0 22 * * *'
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: sync-official-tigress
  cancel-in-progress: false
```

Checkout `main`, clone `https://github.com/lvyww/tiger-code.git` at depth 1,
derive `revision` and `%cs` version, run the synchronizer, install Lua 5.4,
run Python/Lua/Node tests, reject unexpected changed paths, exit cleanly on no
diff, configure the bot author, commit with the short SHA, and push
`HEAD:main`.

- [ ] **Step 4: Verify workflow GREEN**

Run: `python3 -m unittest tests.test_sync_tigress.WorkflowTest -v`

Expected: all workflow assertions pass.

- [ ] **Step 5: Document operations**

Add a concise README section named `官方码表自动同步` documenting the upstream
URL, `tigress`-only scope, preservation of full-Unicode local records, daily
06:00 Asia/Shanghai schedule, manual dispatch, direct verified bot commit,
and the requirement that repository Actions settings and branch protection
allow `GITHUB_TOKEN` writes to `main`.

- [ ] **Step 6: Run complete verification**

Run:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
for test_file in tests/*_test.lua; do lua "$test_file"; done
for test_file in tests/*_test.js; do node "$test_file"; done
python3 scripts/sync_tigress.py \
  --repo-root . \
  --upstream-table vendor/tiger-code/tables/tiger.txt \
  --revision "$(tr -d '\n' < vendor/tiger-code/REVISION)" \
  --version 2026.06.29
git diff --check
git status --short
```

Expected: every test exits 0, the repeated sync reports no changes, diff
checking is clean, and status contains only Task 4 files before commit.

- [ ] **Step 7: Commit workflow and documentation**

```bash
git add .github/workflows/sync-tigress.yml README.md
git add -f tests/test_sync_tigress.py
git commit -m "ci: monitor official tigress table"
```

### Task 5: Final Requirement Audit

**Files:**
- Verify all files from Tasks 1-4.

- [ ] **Step 1: Audit the committed path set**

Run: `git diff --name-only d75d6f3..HEAD`

Expected: no `tiger.dict.yaml`, `tiger.common.dict.yaml`, `*.user.dict.yaml`,
schema, or Lua file appears.

- [ ] **Step 2: Verify upstream and local coverage counts**

Run a read-only Python assertion using `parse_upstream` and `parse_rime` that
checks all official pairs are present in their target and records the count of
retained local-only character pairs.

Expected: zero missing official pairs and more than 70,000 retained local-only
character pairs.

- [ ] **Step 3: Run final fresh verification**

Run the complete command set from Task 4 Step 6 again after all commits.

Expected: all commands exit 0 and `git status --short` is empty.
