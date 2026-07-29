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


class RimeMergeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def write_rime(self, rows: tuple[tuple[str, ...], ...]) -> Path:
        path = self.root / "fixture.dict.yaml"
        data = "\n".join("\t".join(row) for row in rows)
        path.write_text(
            "name: fixture\nversion: \"2026.01.01\"\ncolumns:\n"
            "  - text\n  - weight\n  - code\n  - stem\n...\n"
            f"{data}\n",
            encoding="utf-8",
        )
        return path

    @staticmethod
    def entry(text: str, code: str, kind: str = "full_word"):
        return sync.UpstreamEntry(code=code, text=text, kind=kind)

    def test_parses_rows_with_optional_stem_and_renders_version(self) -> None:
        document = sync.parse_rime(
            self.write_rime((("字", "100", "a", "stem"), ("词语", "50", "abcd")))
        )

        self.assertEqual(document.rows[0].fields, ("字", "100", "a", "stem"))
        self.assertEqual(document.rows[1].fields, ("词语", "50", "abcd"))
        rendered = sync.render_rime(document, "2026.07.29").decode("utf-8")
        self.assertIn('version: "2026.07.29"', rendered)
        self.assertTrue(rendered.endswith("\n"))

    def test_rejects_duplicate_local_pairs(self) -> None:
        path = self.write_rime((("词语", "50", "abcd"), ("词语", "40", "abcd")))

        with self.assertRaisesRegex(sync.SyncError, "duplicate"):
            sync.parse_rime(path)

    def test_merges_additions_deletions_and_local_rows(self) -> None:
        local = sync.parse_rime(
            self.write_rime(
                (
                    ("前词", "50", "aaaa"),
                    ("旧词", "45", "bbbb"),
                    ("本地词", "40", "wxyz"),
                    ("后词", "30", "zzzz", "tail"),
                )
            )
        )
        old = (
            self.entry("前词", "aaaa"),
            self.entry("旧词", "bbbb"),
            self.entry("后词", "zzzz"),
        )
        new = (
            self.entry("前词", "aaaa"),
            self.entry("新词", "cccc"),
            self.entry("后词", "zzzz"),
        )

        merged = sync.merge_rows(local, old, new, default_weight=10)

        self.assertNotIn(("旧词", "bbbb"), merged.by_pair)
        self.assertIn(("新词", "cccc"), merged.by_pair)
        self.assertIn(("本地词", "wxyz"), merged.by_pair)
        self.assertEqual(merged.by_pair[("新词", "cccc")].weight, 50)
        self.assertEqual(merged.by_pair[("后词", "zzzz")].stem, "tail")
        self.assertLess(
            [row.pair for row in merged.rows].index(("新词", "cccc")),
            [row.pair for row in merged.rows].index(("后词", "zzzz")),
        )

    def test_code_change_removes_old_pair_and_adds_new_pair(self) -> None:
        local = sync.parse_rime(self.write_rime((("词语", "80", "oldc"),)))
        old = (self.entry("词语", "oldc"),)
        new = (self.entry("词语", "newc"),)

        merged = sync.merge_rows(local, old, new, default_weight=10)

        self.assertNotIn(("词语", "oldc"), merged.by_pair)
        self.assertEqual(merged.by_pair[("词语", "newc")].weight, 10)

    def test_preserves_local_extension_character(self) -> None:
        local = sync.parse_rime(
            self.write_rime((("常", "100", "a"), ("𠀀", "0", "fgf")))
        )
        managed = (self.entry("常", "a", "char"),)

        merged = sync.merge_rows(local, managed, managed, default_weight=0)

        self.assertIn(("𠀀", "fgf"), merged.by_pair)

    def test_new_weight_uses_next_neighbor_then_default(self) -> None:
        local = sync.parse_rime(self.write_rime((("后词", "30", "zzzz"),)))
        next_neighbor = sync.merge_rows(
            local,
            (self.entry("后词", "zzzz"),),
            (self.entry("新词", "aaaa"), self.entry("后词", "zzzz")),
            default_weight=10,
        )
        no_neighbor = sync.merge_rows(
            sync.RimeDocument(local.header, ()),
            (),
            (self.entry("孤词", "bbbb"),),
            default_weight=10,
        )

        self.assertEqual(next_neighbor.by_pair[("新词", "aaaa")].weight, 30)
        self.assertEqual(no_neighbor.by_pair[("孤词", "bbbb")].weight, 10)


class CommonFilterTest(unittest.TestCase):
    def document(self, *texts: str):
        rows = tuple(sync.RimeRow(text=text, weight=1, code="a") for text in texts)
        return sync.RimeDocument(("name: fixture", "..."), rows)

    def test_common_text_ignores_non_cjk_characters(self) -> None:
        core = {"常", "用", "词"}

        self.assertTrue(sync.is_common_text("常用词，OK", core))
        self.assertFalse(sync.is_common_text("常𠀀词", core))
        self.assertFalse(sync.is_common_text("常樂词", core))

    def test_character_dictionary_requires_direct_core_membership(self) -> None:
        result = sync.derive_common(
            self.document("常", "用", "𠀀", "A"),
            {"常", "用"},
            characters_only=True,
        )

        self.assertEqual([row.text for row in result.rows], ["常", "用"])

    def test_word_dictionary_filters_only_non_core_cjk(self) -> None:
        result = sync.derive_common(
            self.document("常用词", "常𠀀词", "API，常用"),
            {"常", "用", "词"},
            characters_only=False,
        )

        self.assertEqual([row.text for row in result.rows], ["常用词", "API，常用"])

    def test_current_common_dictionary_has_exact_expected_filter(self) -> None:
        core = sync.parse_core_chars(ROOT / "core2022.dict.yaml")
        full = sync.parse_rime(ROOT / "tigress_ci.dict.yaml")
        common = sync.parse_rime(ROOT / "tigress_ci.common.dict.yaml")

        expected = sync.derive_common(full, core, characters_only=False)
        excluded = set(full.by_pair) - set(common.by_pair)

        self.assertEqual(set(expected.by_pair), set(common.by_pair))
        self.assertEqual(len(excluded), 26)


if __name__ == "__main__":
    unittest.main()
