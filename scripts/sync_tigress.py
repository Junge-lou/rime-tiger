#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import AbstractSet, Literal, Sequence


EntryKind = Literal["char", "full_word", "short_word"]


class SyncError(RuntimeError):
    pass


@dataclass(frozen=True)
class UpstreamEntry:
    code: str
    text: str
    kind: EntryKind

    @property
    def pair(self) -> tuple[str, str]:
        return self.text, self.code


@dataclass(frozen=True)
class UpstreamTable:
    raw: bytes
    entries: tuple[UpstreamEntry, ...]


@dataclass(frozen=True)
class RimeRow:
    text: str
    weight: int
    code: str
    stem: str | None = None

    @property
    def pair(self) -> tuple[str, str]:
        return self.text, self.code

    @property
    def fields(self) -> tuple[str, ...]:
        values = (self.text, str(self.weight), self.code)
        if self.stem is not None:
            return (*values, self.stem)
        return values


@dataclass(frozen=True)
class RimeDocument:
    header: tuple[str, ...]
    rows: tuple[RimeRow, ...]

    @property
    def by_pair(self) -> dict[tuple[str, str], RimeRow]:
        return {row.pair: row for row in self.rows}


CJK_RANGES = (
    (0x4E00, 0x9FFF),
    (0x3400, 0x4DBF),
    (0x20000, 0x2A6DF),
    (0x2A700, 0x2B73F),
    (0x2B740, 0x2B81F),
    (0x2B820, 0x2CEAF),
    (0x2CEB0, 0x2EBEF),
    (0x30000, 0x3134F),
    (0x31350, 0x323AF),
    (0x2EBF0, 0x2EE5D),
    (0x31C0, 0x31EF),
    (0x2E80, 0x2EFF),
    (0x2F00, 0x2FDF),
    (0xF900, 0xFADF),
    (0x2F800, 0x2FA1F),
    (0x2FF0, 0x2FFF),
    (0x3100, 0x312F),
    (0x31A0, 0x31BF),
    (0xE000, 0xF8FF),
    (0xF0000, 0xFFFFD),
    (0x100000, 0x10FFFD),
)

FULL_TARGETS: dict[EntryKind, tuple[str, int]] = {
    "char": ("tigress.dict.yaml", 0),
    "full_word": ("tigress_ci.dict.yaml", 10),
    "short_word": ("tigress_simp_ci.dict.yaml", 81),
}

COMMON_TARGETS: dict[EntryKind, str] = {
    "char": "tigress.common.dict.yaml",
    "full_word": "tigress_ci.common.dict.yaml",
    "short_word": "tigress_simp_ci.common.dict.yaml",
}

SNAPSHOT_PATH = "vendor/tiger-code/tables/tiger.txt"
REVISION_PATH = "vendor/tiger-code/REVISION"
MANAGED_PATHS = (
    "tigress.dict.yaml",
    "tigress.common.dict.yaml",
    "tigress_ci.dict.yaml",
    "tigress_ci.common.dict.yaml",
    "tigress_simp_ci.dict.yaml",
    "tigress_simp_ci.common.dict.yaml",
    SNAPSHOT_PATH,
    REVISION_PATH,
)


@dataclass(frozen=True)
class SafetyLimits:
    chars: int = 20_000
    full_words: int = 100_000
    short_words: int = 2_000
    max_delta: float = 0.20
    max_pair_churn: float = 0.20
    max_source_bytes: int = 8 * 1024 * 1024
    max_text_length: int = 128

    def minimum_for(self, kind: EntryKind) -> int:
        return {
            "char": self.chars,
            "full_word": self.full_words,
            "short_word": self.short_words,
        }[kind]


@dataclass(frozen=True)
class SyncResult:
    changed: bool
    changed_paths: tuple[Path, ...]
    counts: dict[EntryKind, int]


def classify(text: str, code: str) -> EntryKind:
    if len(text) == 1:
        return "char"
    if len(code) == 4:
        return "full_word"
    return "short_word"


def parse_upstream(
    path: Path, *, limits: SafetyLimits = SafetyLimits()
) -> UpstreamTable:
    source_size = path.stat().st_size
    if source_size > limits.max_source_bytes:
        raise SyncError(
            f"{path}: source exceeds byte limit "
            f"({source_size} > {limits.max_source_bytes})"
        )
    raw = path.read_bytes()
    try:
        content = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SyncError(f"{path}: source is not valid UTF-8") from error

    lines = content.splitlines()
    markers = [index for index, line in enumerate(lines) if line == "[Data]"]
    if len(markers) != 1:
        raise SyncError(f"{path}: expected exactly one [Data] marker")

    entries: list[UpstreamEntry] = []
    seen: set[tuple[str, str]] = set()
    first_data_line = markers[0] + 1
    for line_number, line in enumerate(lines[first_data_line:], first_data_line + 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise SyncError(f"{path}:{line_number}: expected two tab-separated columns")
        code, text = fields
        if not text:
            raise SyncError(f"{path}:{line_number}: text must not be empty")
        if text.startswith("#"):
            raise SyncError(f"{path}:{line_number}: text must not start with #")
        if len(text) > limits.max_text_length:
            raise SyncError(
                f"{path}:{line_number}: text length exceeds safety limit "
                f"({len(text)} > {limits.max_text_length})"
            )
        if re.fullmatch(r"[a-z]{1,4}", code) is None:
            raise SyncError(f"{path}:{line_number}: invalid code {code!r}")
        pair = (text, code)
        if pair in seen:
            raise SyncError(f"{path}:{line_number}: duplicate pair {pair!r}")
        seen.add(pair)
        entries.append(UpstreamEntry(code=code, text=text, kind=classify(text, code)))

    return UpstreamTable(raw=raw, entries=tuple(entries))


def parse_rime_bytes(raw: bytes, source: str | Path) -> RimeDocument:
    try:
        content = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SyncError(f"{source}: dictionary is not valid UTF-8") from error

    lines = content.splitlines()
    markers = [index for index, line in enumerate(lines) if line == "..."]
    if len(markers) != 1:
        raise SyncError(f"{source}: expected exactly one ... marker")
    marker = markers[0]
    header = tuple(lines[: marker + 1])
    rows: list[RimeRow] = []
    seen: set[tuple[str, str]] = set()
    for line_number, line in enumerate(lines[marker + 1 :], marker + 2):
        if not line:
            continue
        if line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) not in (3, 4):
            raise SyncError(f"{source}:{line_number}: expected three or four columns")
        text, weight_text, code = fields[:3]
        if not text or not code:
            raise SyncError(f"{source}:{line_number}: text and code must not be empty")
        try:
            weight = int(weight_text)
        except ValueError as error:
            raise SyncError(
                f"{source}:{line_number}: invalid weight {weight_text!r}"
            ) from error
        stem = fields[3] if len(fields) == 4 else None
        row = RimeRow(text=text, weight=weight, code=code, stem=stem)
        if row.pair in seen:
            raise SyncError(f"{source}:{line_number}: duplicate pair {row.pair!r}")
        seen.add(row.pair)
        rows.append(row)
    return RimeDocument(header=header, rows=tuple(rows))


def parse_rime(path: Path) -> RimeDocument:
    return parse_rime_bytes(path.read_bytes(), path)


def render_rime(document: RimeDocument, version: str) -> bytes:
    header = list(document.header)
    version_indexes = [
        index for index, line in enumerate(header) if re.match(r"^version\s*:", line)
    ]
    if len(version_indexes) != 1:
        raise SyncError("dictionary header must contain exactly one version")
    header[version_indexes[0]] = f'version: "{version}"'
    lines = header + ["\t".join(row.fields) for row in document.rows]
    return ("\n".join(lines) + "\n").encode("utf-8")


def _neighbor_weight(
    entries: Sequence[UpstreamEntry],
    index: int,
    rows_by_pair: dict[tuple[str, str], RimeRow],
    default_weight: int,
) -> int:
    for candidate in reversed(entries[:index]):
        row = rows_by_pair.get(candidate.pair)
        if row is not None:
            return row.weight
    for candidate in entries[index + 1 :]:
        row = rows_by_pair.get(candidate.pair)
        if row is not None:
            return row.weight
    return default_weight


def merge_rows(
    local: RimeDocument,
    old_entries: Sequence[UpstreamEntry],
    new_entries: Sequence[UpstreamEntry],
    default_weight: int,
) -> RimeDocument:
    old_pairs = {entry.pair for entry in old_entries}
    new_pairs = {entry.pair for entry in new_entries}
    rows = [
        row
        for row in local.rows
        if not (row.pair in old_pairs and row.pair not in new_pairs)
    ]
    rows_by_pair = {row.pair: row for row in rows}

    for index, entry in enumerate(new_entries):
        if entry.pair in rows_by_pair:
            continue
        row = RimeRow(
            text=entry.text,
            weight=_neighbor_weight(new_entries, index, rows_by_pair, default_weight),
            code=entry.code,
        )

        insert_at: int | None = None
        for previous in reversed(new_entries[:index]):
            if previous.pair in rows_by_pair:
                insert_at = next(
                    position
                    for position, existing in enumerate(rows)
                    if existing.pair == previous.pair
                ) + 1
                break
        if insert_at is None:
            for following in new_entries[index + 1 :]:
                if following.pair in rows_by_pair:
                    insert_at = next(
                        position
                        for position, existing in enumerate(rows)
                        if existing.pair == following.pair
                    )
                    break
        if insert_at is None:
            insert_at = len(rows)
        rows.insert(insert_at, row)
        rows_by_pair[row.pair] = row

    return RimeDocument(header=local.header, rows=tuple(rows))


def parse_core_chars(path: Path) -> frozenset[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise SyncError(f"{path}: core dictionary is not valid UTF-8") from error
    markers = [index for index, line in enumerate(lines) if line == "..."]
    if len(markers) != 1:
        raise SyncError(f"{path}: expected exactly one ... marker")
    result: set[str] = set()
    for line in lines[markers[0] + 1 :]:
        if not line or line.startswith("#"):
            continue
        text = line.split("\t", 1)[0]
        if len(text) != 1:
            raise SyncError(f"{path}: core entry must be one character: {text!r}")
        result.add(text)
    return frozenset(result)


def is_cjk(char: str) -> bool:
    codepoint = ord(char)
    return any(first <= codepoint <= last for first, last in CJK_RANGES)


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
    return RimeDocument(header=source.header, rows=rows)


def _entries_of_kind(
    table: UpstreamTable | None, kind: EntryKind
) -> tuple[UpstreamEntry, ...]:
    if table is None:
        return ()
    return tuple(entry for entry in table.entries if entry.kind == kind)


def _validate_source_size(
    new_table: UpstreamTable,
    old_table: UpstreamTable | None,
    limits: SafetyLimits,
) -> dict[EntryKind, int]:
    counts = Counter(entry.kind for entry in new_table.entries)
    for kind in FULL_TARGETS:
        count = counts[kind]
        minimum = limits.minimum_for(kind)
        if count < minimum:
            raise SyncError(
                f"{kind} count {count} is below safety minimum {minimum}"
            )

    if old_table is not None:
        old_counts = Counter(entry.kind for entry in old_table.entries)
        for kind in FULL_TARGETS:
            old_count = old_counts[kind]
            if old_count == 0:
                continue
            delta = abs(counts[kind] - old_count) / old_count
            if delta > limits.max_delta:
                percent = round(limits.max_delta * 100)
                raise SyncError(
                    f"{kind} count change exceeds {percent}% safety limit: "
                    f"{old_count} -> {counts[kind]}"
                )
            old_pairs = {
                entry.pair for entry in old_table.entries if entry.kind == kind
            }
            new_pairs = {
                entry.pair for entry in new_table.entries if entry.kind == kind
            }
            removed = len(old_pairs - new_pairs)
            added = len(new_pairs - old_pairs)
            if max(removed, added) / old_count > limits.max_pair_churn:
                percent = round(limits.max_pair_churn * 100)
                raise SyncError(
                    f"{kind} pair churn exceeds {percent}% safety limit: "
                    f"removed={removed}, added={added}, baseline={old_count}"
                )
    return {kind: counts[kind] for kind in FULL_TARGETS}


def _verify_merge(
    local: RimeDocument,
    old_entries: Sequence[UpstreamEntry],
    new_entries: Sequence[UpstreamEntry],
    merged: RimeDocument,
) -> None:
    local_pairs = set(local.by_pair)
    old_pairs = {entry.pair for entry in old_entries}
    new_pairs = {entry.pair for entry in new_entries}
    merged_pairs = set(merged.by_pair)
    missing_official = new_pairs - merged_pairs
    if missing_official:
        raise SyncError(f"merged dictionary is missing {len(missing_official)} official pairs")
    stale_official = (old_pairs - new_pairs) & merged_pairs
    if stale_official:
        raise SyncError(f"merged dictionary retains {len(stale_official)} removed pairs")
    lost_local = (local_pairs - old_pairs) - merged_pairs
    if lost_local:
        raise SyncError(f"merged dictionary lost {len(lost_local)} local-only pairs")
    if len(merged.by_pair) != len(merged.rows):
        raise SyncError("merged dictionary contains duplicate pairs")


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def synchronize(
    repo_root: Path,
    upstream_path: Path,
    revision: str,
    version: str,
    limits: SafetyLimits = SafetyLimits(),
) -> SyncResult:
    repo_root = repo_root.resolve()
    upstream_path = upstream_path.resolve()
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise SyncError("revision must be a full lowercase 40-character Git SHA")
    if re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", version) is None:
        raise SyncError("version must use YYYY.MM.DD")

    snapshot_path = repo_root / SNAPSHOT_PATH
    revision_path = repo_root / REVISION_PATH
    if snapshot_path.exists() != revision_path.exists():
        raise SyncError("upstream snapshot and revision must either both exist or both be absent")

    new_table = parse_upstream(upstream_path, limits=limits)
    old_table = (
        parse_upstream(snapshot_path, limits=limits) if snapshot_path.exists() else None
    )
    old_revision: bytes | None = None
    if revision_path.exists():
        old_revision = revision_path.read_bytes()
        if re.fullmatch(rb"[0-9a-f]{40}\n", old_revision) is None:
            raise SyncError("stored upstream revision is invalid")
    counts = _validate_source_size(new_table, old_table, limits)

    local_full: dict[EntryKind, RimeDocument] = {}
    local_common: dict[EntryKind, RimeDocument] = {}
    for kind, (relative, _) in FULL_TARGETS.items():
        local_full[kind] = parse_rime(repo_root / relative)
        local_common[kind] = parse_rime(repo_root / COMMON_TARGETS[kind])
    core_chars = parse_core_chars(repo_root / "core2022.dict.yaml")

    source_changed = old_table is None or old_table.raw != new_table.raw
    outputs: dict[str, bytes] = {}
    expected_documents: dict[str, RimeDocument] = {}
    for kind, (relative, default_weight) in FULL_TARGETS.items():
        old_entries = _entries_of_kind(old_table, kind)
        new_entries = _entries_of_kind(new_table, kind)
        merged = merge_rows(
            local_full[kind], old_entries, new_entries, default_weight
        )
        _verify_merge(local_full[kind], old_entries, new_entries, merged)

        common_rows = derive_common(
            merged,
            core_chars,
            characters_only=kind == "char",
        ).rows
        common = RimeDocument(header=local_common[kind].header, rows=common_rows)
        expected_common_pairs = {row.pair for row in common_rows}
        if set(common.by_pair) != expected_common_pairs:
            raise SyncError(f"failed to derive {COMMON_TARGETS[kind]}")

        if source_changed:
            outputs[relative] = render_rime(merged, version)
            outputs[COMMON_TARGETS[kind]] = render_rime(common, version)
        else:
            outputs[relative] = render_rime(
                merged, _header_version(local_full[kind].header)
            )
            outputs[COMMON_TARGETS[kind]] = render_rime(
                common, _header_version(local_common[kind].header)
            )
        expected_documents[relative] = merged
        expected_documents[COMMON_TARGETS[kind]] = common

    outputs[SNAPSHOT_PATH] = new_table.raw
    if source_changed:
        outputs[REVISION_PATH] = (revision + "\n").encode("ascii")
    else:
        if old_revision is None:
            raise SyncError("stored upstream revision is missing")
        outputs[REVISION_PATH] = old_revision

    for relative, expected in expected_documents.items():
        rendered = parse_rime_bytes(outputs[relative], f"rendered {relative}")
        if rendered.rows != expected.rows:
            raise SyncError(f"rendered {relative} does not preserve expected rows")

    changed_paths: list[Path] = []
    for relative in MANAGED_PATHS:
        path = repo_root / relative
        content = outputs[relative]
        if not path.exists() or path.read_bytes() != content:
            changed_paths.append(Path(relative))

    for relative in changed_paths:
        atomic_write(repo_root / relative, outputs[relative.as_posix()])

    return SyncResult(
        changed=bool(changed_paths),
        changed_paths=tuple(changed_paths),
        counts=counts,
    )


def _header_version(header: Sequence[str]) -> str:
    versions = []
    for line in header:
        match = re.fullmatch(r"version\s*:\s*[\"']?([^\"']+)[\"']?", line)
        if match:
            versions.append(match.group(1))
    if len(versions) != 1:
        raise SyncError("dictionary header must contain exactly one version")
    return versions[0]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Synchronize official Tigress dictionaries")
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--upstream-table", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args(argv)
    try:
        result = synchronize(
            repo_root=arguments.repo_root,
            upstream_path=arguments.upstream_table,
            revision=arguments.revision,
            version=arguments.version,
        )
    except (OSError, SyncError) as error:
        print(f"sync failed: {error}", file=sys.stderr)
        return 1

    counts = ", ".join(f"{kind}={count}" for kind, count in result.counts.items())
    if result.changed:
        print(f"updated {len(result.changed_paths)} files ({counts})")
    else:
        print(f"already up to date ({counts})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
