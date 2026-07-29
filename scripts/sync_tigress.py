#!/usr/bin/env python3
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


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
