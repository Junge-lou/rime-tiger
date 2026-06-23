from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def import_tables(dict_name: str) -> list[str]:
    lines = (ROOT / f"{dict_name}.dict.yaml").read_text(encoding="utf-8").splitlines()
    in_import_tables = False
    imports: list[str] = []

    for line in lines:
        if line == "import_tables:":
            in_import_tables = True
            continue
        if in_import_tables:
            if line.startswith("  - "):
                imports.append(line.removeprefix("  - ").strip())
                continue
            break

    return imports


def has_entry(dict_name: str, text: str, code: str) -> bool:
    expected_prefix = f"{text}\t"
    expected_suffix = f"\t{code}"

    for line in (ROOT / f"{dict_name}.dict.yaml").read_text(encoding="utf-8").splitlines():
        if line.startswith(expected_prefix) and line.endswith(expected_suffix):
            return True
    return False


class TigressImportTablesTest(unittest.TestCase):
    def test_full_extended_directly_imports_phrase_tables_with_wklf(self):
        self.assertTrue(has_entry("tigress_ci", "官方", "wklf"))
        self.assertIn("tigress_ci", import_tables("tigress_full.extended"))
        self.assertIn("tigress_simp_ci", import_tables("tigress_full.extended"))

    def test_extended_directly_imports_common_phrase_tables_with_wklf(self):
        self.assertTrue(has_entry("tigress_ci.common", "官方", "wklf"))
        self.assertIn("tigress_ci.common", import_tables("tigress.extended"))
        self.assertIn("tigress_simp_ci.common", import_tables("tigress.extended"))


if __name__ == "__main__":
    unittest.main()
