from __future__ import annotations

import importlib.util
import shutil
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


class RepositorySyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.repo = Path(self.temp_dir.name)
        self._write_fixture_repository()

    @staticmethod
    def upstream_bytes(*rows: tuple[str, str]) -> bytes:
        data = "\n".join(f"{code}\t{text}" for code, text in rows)
        return f"KeyCode=abcdefghijklmnopqrstuvwxyz\n[Data]\n{data}\n".encode("utf-8")

    @staticmethod
    def dictionary(name: str, rows: tuple[tuple[str, ...], ...]) -> str:
        data = "\n".join("\t".join(row) for row in rows)
        return (
            f"name: {name}\nversion: \"2026.01.01\"\nsort: by_weight\n"
            "columns:\n  - text\n  - weight\n  - code\n  - stem\n...\n"
            f"{data}\n"
        )

    def _write_fixture_repository(self) -> None:
        files = {
            "tigress.dict.yaml": self.dictionary(
                "tigress", (("常", "100", "a", "stem"), ("𠀀", "0", "fgf"))
            ),
            "tigress.common.dict.yaml": self.dictionary(
                "tigress.common", (("常", "100", "a", "stem"),)
            ),
            "tigress_ci.dict.yaml": self.dictionary(
                "tigress_ci", (("旧词", "50", "abcd"), ("本地词", "40", "wxyz"))
            ),
            "tigress_ci.common.dict.yaml": self.dictionary(
                "tigress_ci.common", (("旧词", "50", "abcd"), ("本地词", "40", "wxyz"))
            ),
            "tigress_simp_ci.dict.yaml": self.dictionary(
                "tigress_simp_ci", (("简词", "80", "ab"),)
            ),
            "tigress_simp_ci.common.dict.yaml": self.dictionary(
                "tigress_simp_ci.common", (("简词", "80", "ab"),)
            ),
            "core2022.dict.yaml": (
                "name: core2022\nversion: \"1\"\n...\n"
                "常\tt\n旧\tt\n词\tt\n简\tt\n本\tt\n地\tt\n"
            ),
        }
        for relative, content in files.items():
            path = self.repo / relative
            path.write_text(content, encoding="utf-8")

    def write_upstream(self, content: bytes, name: str = "new.txt") -> Path:
        path = self.repo / name
        path.write_bytes(content)
        return path

    def install_old_snapshot(self, content: bytes, revision: str = "b" * 40) -> None:
        table = self.repo / "vendor/tiger-code/tables/tiger.txt"
        table.parent.mkdir(parents=True, exist_ok=True)
        table.write_bytes(content)
        (self.repo / "vendor/tiger-code/REVISION").write_text(
            revision + "\n", encoding="ascii"
        )

    @staticmethod
    def limits(max_delta: float = 1.0):
        return sync.SafetyLimits(
            chars=1,
            full_words=1,
            short_words=1,
            max_delta=max_delta,
        )

    def test_synchronizes_all_targets_and_is_idempotent(self) -> None:
        old = self.upstream_bytes(("a", "常"), ("abcd", "旧词"), ("ab", "简词"))
        new = self.upstream_bytes(("a", "常"), ("newc", "新词"), ("bc", "新简"))
        self.install_old_snapshot(old)
        upstream = self.write_upstream(new)

        result = sync.synchronize(
            self.repo,
            upstream,
            revision="a" * 40,
            version="2026.07.29",
            limits=self.limits(),
        )

        self.assertTrue(result.changed)
        self.assertEqual(
            {path.as_posix() for path in result.changed_paths},
            set(sync.MANAGED_PATHS),
        )
        full_words = sync.parse_rime(self.repo / "tigress_ci.dict.yaml")
        self.assertNotIn(("旧词", "abcd"), full_words.by_pair)
        self.assertIn(("新词", "newc"), full_words.by_pair)
        self.assertIn(("本地词", "wxyz"), full_words.by_pair)
        chars = sync.parse_rime(self.repo / "tigress.dict.yaml")
        self.assertIn(("𠀀", "fgf"), chars.by_pair)
        common_chars = sync.parse_rime(self.repo / "tigress.common.dict.yaml")
        self.assertNotIn(("𠀀", "fgf"), common_chars.by_pair)
        self.assertEqual(
            (self.repo / "vendor/tiger-code/tables/tiger.txt").read_bytes(), new
        )
        self.assertEqual(
            (self.repo / "vendor/tiger-code/REVISION").read_text(encoding="ascii"),
            "a" * 40 + "\n",
        )

        second = sync.synchronize(
            self.repo,
            upstream,
            revision="a" * 40,
            version="2026.07.29",
            limits=self.limits(),
        )
        self.assertFalse(second.changed)
        self.assertEqual(second.changed_paths, ())

    def test_bootstrap_adds_missing_official_rows_and_keeps_local_rows(self) -> None:
        upstream = self.write_upstream(
            self.upstream_bytes(("a", "常"), ("newc", "新词"), ("ab", "简词"))
        )

        sync.synchronize(
            self.repo,
            upstream,
            revision="c" * 40,
            version="2026.07.29",
            limits=self.limits(),
        )

        words = sync.parse_rime(self.repo / "tigress_ci.dict.yaml")
        self.assertIn(("新词", "newc"), words.by_pair)
        self.assertIn(("旧词", "abcd"), words.by_pair)
        self.assertIn(("本地词", "wxyz"), words.by_pair)

    def test_ignores_new_revision_when_table_bytes_are_unchanged(self) -> None:
        content = self.upstream_bytes(
            ("a", "常"), ("abcd", "旧词"), ("ab", "简词")
        )
        self.install_old_snapshot(content, revision="b" * 40)
        upstream = self.write_upstream(content)

        result = sync.synchronize(
            self.repo,
            upstream,
            revision="a" * 40,
            version="2026.07.29",
            limits=self.limits(),
        )

        self.assertFalse(result.changed)
        self.assertEqual(
            (self.repo / "vendor/tiger-code/REVISION").read_text(encoding="ascii"),
            "b" * 40 + "\n",
        )

    def test_rejects_invalid_revision_without_writing(self) -> None:
        upstream = self.write_upstream(
            self.upstream_bytes(("a", "常"), ("abcd", "旧词"), ("ab", "简词"))
        )
        before = (self.repo / "tigress.dict.yaml").read_bytes()

        with self.assertRaisesRegex(sync.SyncError, "revision"):
            sync.synchronize(
                self.repo,
                upstream,
                revision="not-a-sha",
                version="2026.07.29",
                limits=self.limits(),
            )

        self.assertEqual((self.repo / "tigress.dict.yaml").read_bytes(), before)
        self.assertFalse((self.repo / "vendor").exists())

    def test_rejects_minimum_count_and_large_delta(self) -> None:
        tiny = self.write_upstream(self.upstream_bytes(("a", "常")))
        with self.assertRaisesRegex(sync.SyncError, "minimum"):
            sync.synchronize(
                self.repo,
                tiny,
                revision="d" * 40,
                version="2026.07.29",
                limits=self.limits(),
            )

        old = self.upstream_bytes(("a", "常"), ("abcd", "旧词"), ("ab", "简词"))
        self.install_old_snapshot(old)
        grown = self.write_upstream(
            self.upstream_bytes(
                ("a", "常"),
                ("abcd", "旧词"),
                ("efgh", "新词"),
                ("ab", "简词"),
            ),
            "grown.txt",
        )
        before = (self.repo / "vendor/tiger-code/tables/tiger.txt").read_bytes()
        with self.assertRaisesRegex(sync.SyncError, "20%"):
            sync.synchronize(
                self.repo,
                grown,
                revision="e" * 40,
                version="2026.07.29",
                limits=self.limits(max_delta=0.20),
            )
        self.assertEqual(
            (self.repo / "vendor/tiger-code/tables/tiger.txt").read_bytes(), before
        )

    def test_rejects_invalid_target_before_any_write(self) -> None:
        upstream = self.write_upstream(
            self.upstream_bytes(("a", "常"), ("abcd", "旧词"), ("ab", "简词"))
        )
        original = (self.repo / "tigress.dict.yaml").read_bytes()
        (self.repo / "tigress_ci.common.dict.yaml").write_text(
            "not a dictionary\n", encoding="utf-8"
        )

        with self.assertRaises(sync.SyncError):
            sync.synchronize(
                self.repo,
                upstream,
                revision="f" * 40,
                version="2026.07.29",
                limits=self.limits(),
            )

        self.assertEqual((self.repo / "tigress.dict.yaml").read_bytes(), original)
        self.assertFalse((self.repo / "vendor").exists())


class RepositoryIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.repo = Path(self.temp_dir.name)
        for relative in (
            "core2022.dict.yaml",
            *sync.MANAGED_PATHS,
        ):
            source = ROOT / relative
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)

    def test_real_snapshot_is_complete_and_idempotent(self) -> None:
        snapshot = self.repo / sync.SNAPSHOT_PATH
        revision = (self.repo / sync.REVISION_PATH).read_text(encoding="ascii").strip()
        upstream = sync.parse_upstream(snapshot)

        result = sync.synchronize(
            self.repo,
            snapshot,
            revision=revision,
            version="2026.06.29",
        )

        self.assertFalse(result.changed)
        targets = {
            kind: sync.parse_rime(self.repo / relative)
            for kind, (relative, _) in sync.FULL_TARGETS.items()
        }
        for kind, document in targets.items():
            official_pairs = {
                entry.pair for entry in upstream.entries if entry.kind == kind
            }
            self.assertTrue(official_pairs <= set(document.by_pair), kind)

        official_chars = {
            entry.pair for entry in upstream.entries if entry.kind == "char"
        }
        local_only_chars = set(targets["char"].by_pair) - official_chars
        self.assertGreater(len(local_only_chars), 70_000)


class SnapshotAttributesTest(unittest.TestCase):
    def test_upstream_snapshot_disables_git_line_ending_conversion(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="ascii")

        self.assertIn("vendor/tiger-code/tables/tiger.txt -text", attributes)


if __name__ == "__main__":
    unittest.main()
