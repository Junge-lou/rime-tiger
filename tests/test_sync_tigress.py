from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "sync_tigress.py"
SPEC = importlib.util.spec_from_file_location("sync_tigress", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
sync = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sync
SPEC.loader.exec_module(sync)


class UpstreamParserTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def write_bytes(self, content: bytes) -> Path:
        path = self.root / "tiger.txt"
        path.write_bytes(content)
        return path

    def write(self, content: str) -> Path:
        return self.write_bytes(content.encode("utf-8"))

    def test_parses_and_classifies_fcitx_data(self) -> None:
        path = self.write(
            "KeyCode=abcdefghijklmnopqrstuvwxyz\n"
            "[Data]\n"
            "u\t的\n"
            "tu\t我们\n"
            "tuja\t我们\n"
        )

        table = sync.parse_upstream(path)

        self.assertEqual(
            [entry.kind for entry in table.entries],
            ["char", "short_word", "full_word"],
        )
        self.assertEqual(table.entries[0].pair, ("的", "u"))
        self.assertEqual(table.raw, path.read_bytes())

    def test_treats_supplementary_codepoint_as_one_character(self) -> None:
        table = sync.parse_upstream(self.write("[Data]\nfgf\t𠀀\n"))

        self.assertEqual(table.entries[0].kind, "char")

    def test_accepts_crlf_without_changing_raw_bytes(self) -> None:
        raw = b"KeyCode=abcdefghijklmnopqrstuvwxyz\r\n[Data]\r\nu\t\xe7\x9a\x84\r\n"

        table = sync.parse_upstream(self.write_bytes(raw))

        self.assertEqual(table.entries[0].pair, ("的", "u"))
        self.assertEqual(table.raw, raw)

    def test_rejects_duplicate_pairs(self) -> None:
        path = self.write("[Data]\nu\t的\nu\t的\n")

        with self.assertRaisesRegex(sync.SyncError, "duplicate"):
            sync.parse_upstream(path)

    def test_rejects_missing_or_repeated_data_marker(self) -> None:
        for content in ("u\t的\n", "[Data]\n[Data]\nu\t的\n"):
            with self.subTest(content=content):
                with self.assertRaisesRegex(sync.SyncError, "exactly one"):
                    sync.parse_upstream(self.write(content))

    def test_rejects_invalid_rows(self) -> None:
        rows = ("A\t的", "abcde\t词", "a\t词\textra", "a\t")
        for row in rows:
            with self.subTest(row=row):
                with self.assertRaises(sync.SyncError):
                    sync.parse_upstream(self.write(f"[Data]\n{row}\n"))

    def test_rejects_invalid_utf8(self) -> None:
        with self.assertRaisesRegex(sync.SyncError, "UTF-8"):
            sync.parse_upstream(self.write_bytes(b"[Data]\na\t\xff\n"))


if __name__ == "__main__":
    unittest.main()
