#!/usr/bin/env python3
from __future__ import annotations

import re
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


def classify(text: str, code: str) -> EntryKind:
    if len(text) == 1:
        return "char"
    if len(code) == 4:
        return "full_word"
    return "short_word"


def parse_upstream(path: Path) -> UpstreamTable:
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
        if re.fullmatch(r"[a-z]{1,4}", code) is None:
            raise SyncError(f"{path}:{line_number}: invalid code {code!r}")
        pair = (text, code)
        if pair in seen:
            raise SyncError(f"{path}:{line_number}: duplicate pair {pair!r}")
        seen.add(pair)
        entries.append(UpstreamEntry(code=code, text=text, kind=classify(text, code)))

    return UpstreamTable(raw=raw, entries=tuple(entries))


def parse_rime(path: Path) -> RimeDocument:
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise SyncError(f"{path}: dictionary is not valid UTF-8") from error

    lines = content.splitlines()
    markers = [index for index, line in enumerate(lines) if line == "..."]
    if len(markers) != 1:
        raise SyncError(f"{path}: expected exactly one ... marker")
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
            raise SyncError(f"{path}:{line_number}: expected three or four columns")
        text, weight_text, code = fields[:3]
        if not text or not code:
            raise SyncError(f"{path}:{line_number}: text and code must not be empty")
        try:
            weight = int(weight_text)
        except ValueError as error:
            raise SyncError(f"{path}:{line_number}: invalid weight {weight_text!r}") from error
        stem = fields[3] if len(fields) == 4 else None
        row = RimeRow(text=text, weight=weight, code=code, stem=stem)
        if row.pair in seen:
            raise SyncError(f"{path}:{line_number}: duplicate pair {row.pair!r}")
        seen.add(row.pair)
        rows.append(row)
    return RimeDocument(header=header, rows=tuple(rows))


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
