from pathlib import Path
import unittest
import re


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


def active_font_list(config_name: str, key: str) -> list[str]:
    for line in (ROOT / config_name).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or not stripped.startswith(f"{key}:"):
            continue
        value = stripped.split(":", 1)[1].split("#", 1)[0].strip()
        return [font.strip() for font in value.strip('"').split(",")]
    raise AssertionError(f"{key} not found in {config_name}")


def active_config_text(config_name: str) -> str:
    lines = []
    for line in (ROOT / config_name).read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("#"):
            continue
        lines.append(line)
    return "\n".join(lines)


def switches_section(config_name: str) -> str:
    text = active_config_text(config_name)
    start = text.index("switches:")
    end = text.index("\nengine:", start)
    return text[start:end]


def active_schema_field(config_name: str, key: str) -> str:
    in_schema = False
    for line in (ROOT / config_name).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped == "schema:":
            in_schema = True
            continue
        if in_schema and line and not line.startswith(" ") and not line.startswith("\t"):
            in_schema = False
        if in_schema and stripped.startswith(f"{key}:"):
            value = stripped.split(":", 1)[1].split("#", 1)[0].strip()
            return value.strip('"')
    raise AssertionError(f"schema/{key} not found in {config_name}")


class TigressImportTablesTest(unittest.TestCase):
    def test_full_extended_directly_imports_phrase_tables_with_wklf(self):
        self.assertTrue(has_entry("tigress_ci", "官方", "wklf"))
        self.assertIn("tigress_ci", import_tables("tigress_full.extended"))
        self.assertIn("tigress_simp_ci", import_tables("tigress_full.extended"))

    def test_extended_directly_imports_common_phrase_tables_with_wklf(self):
        self.assertTrue(has_entry("tigress_ci.common", "官方", "wklf"))
        self.assertIn("tigress_ci.common", import_tables("tigress.extended"))
        self.assertIn("tigress_simp_ci.common", import_tables("tigress.extended"))


class InputSpeedStatConfigTest(unittest.TestCase):
    def test_speed_stat_switch_defaults_off_in_base_schema(self):
        schema = (ROOT / "tiger_base.schema.yaml").read_text(encoding="utf-8")
        self.assertRegex(
            schema,
            re.compile(
                r"- name: input_speed_stat[^\n]*\n"
                r"\s+reset: 0\n"
                r"\s+states: \[ 测速关, 测速开 \]",
                re.MULTILINE,
            ),
        )

    def test_speed_stat_components_are_registered(self):
        schema = (ROOT / "tiger_base.schema.yaml").read_text(encoding="utf-8")
        custom = (ROOT / "tiger_base.custom.yaml").read_text(encoding="utf-8")
        tigress_full = (ROOT / "tigress_full.schema.yaml").read_text(encoding="utf-8")

        self.assertIn("lua_processor@*input_speed_stat*processor", schema)
        self.assertIn("lua_translator@*input_speed_stat*translator", schema)
        self.assertIn("lua_translator@*input_speed_stat*translator", custom)
        self.assertIn("lua_processor@*input_speed_stat*processor", tigress_full)


class CandidateFontConfigTest(unittest.TestCase):
    def test_candidate_fonts_keep_chinese_and_numbers_on_same_baseline(self):
        for config_name in ("squirrel.custom.yaml", "weasel.custom.yaml"):
            for key in ("font_face", "comment_font_face"):
                fonts = active_font_list(config_name, key)
                self.assertIn("LXGW WenKai GB Screen", fonts)
                self.assertIn("Consolas", fonts)
                self.assertLess(
                    fonts.index("LXGW WenKai GB Screen"),
                    fonts.index("Consolas"),
                    f"{config_name} {key} should prefer the Chinese UI font before Consolas",
                )


class SchemaNameConfigTest(unittest.TestCase):
    schema_names = {
        "tiger.schema.yaml": "虎码单字 9767字",
        "tiger_full.schema.yaml": "虎码单字全字集 99144字",
        "tigress.schema.yaml": "虎码词库 9767字",
        "tigress_full.schema.yaml": "虎码词库全字集 99144字",
    }

    def test_tiger_schema_names_keep_character_counts_for_switch_notice(self):
        for config_name, expected in self.schema_names.items():
            name = active_schema_field(config_name, "name")

            self.assertEqual(name, expected)
            self.assertRegex(name, r"\d+\s*字")

    def test_tiger_schema_descriptions_keep_character_counts(self):
        expectations = {
            "tiger.schema.yaml": "字集：9767 字",
            "tiger_full.schema.yaml": "字集：全字集 99144 字，是 9767 字的父集",
            "tigress.schema.yaml": "字集：9767 字",
            "tigress_full.schema.yaml": "字集：全字集 99144 字，是 9767 字的父集",
        }

        for config_name, expected in expectations.items():
            schema = (ROOT / config_name).read_text(encoding="utf-8")

            self.assertIn(expected, schema)


class SwitchShortcutHintConfigTest(unittest.TestCase):
    def assert_contains_all(self, text: str, expected_values: list[str]) -> None:
        for expected in expected_values:
            self.assertIn(expected, text)

    def test_tiger_base_switch_labels_show_available_shortcuts(self):
        schema = (ROOT / "tiger_base.schema.yaml").read_text(encoding="utf-8")

        self.assert_contains_all(
            schema,
            [
                "states: [ 中文, \"西文 Shift/Caps\" ]",
                '"拼隐"',
                '"拼显 Ctrl+P Ctrl+Shift+Enter上屏拼音"',
                "states: [ 🈚表情, \"🈶表情 Ctrl+I\" ]",
                '"🈶表情 Ctrl+I"',
                "states: [ 测速关, 测速开 ]",
                "测速开",
                '"拆隐"',
                '"拆显 Ctrl+J Ctrl+Shift+Enter上屏拆分"',
                "states: [ 简中, \"繁中 Ctrl+O\" ]",
                '"繁中 Ctrl+O"',
                "states: [ U区关, \"U区开 Ctrl+U\" ]",
                '"U区开 Ctrl+U"',
                "states: [ U编关, \"U编开 Ctrl+Y\" ]",
                '"U编开 Ctrl+Y"',
                "states: [ 。，, \"．， Ctrl+.\" ]",
                '"．， Ctrl+."',
                "states: [ 半角, \"全角 Shift+Space\" ]",
                '"全角 Shift+Space"',
            ],
        )
        self.assertRegex(
            schema,
            re.compile(
                r'^\s+- \{ when: always, accept: "Shift\+space" , toggle: full_shape \}',
                re.MULTILINE,
            ),
        )

    def test_pinyin_schema_switch_labels_show_available_shortcuts(self):
        schema = (ROOT / "PY_c.schema.yaml").read_text(encoding="utf-8")

        self.assert_contains_all(
            schema,
            [
                "states: [ 中文, \"西文 Shift/Caps\" ]",
                '"拼隐"',
                '"拼显 Ctrl+P Ctrl+Shift+Enter上屏拼音"',
                "states: [ 🈚表情, \"🈶表情 Ctrl+I\" ]",
                '"🈶表情 Ctrl+I"',
                "states: [ 简中, \"繁中 Ctrl+O\" ]",
                '"繁中 Ctrl+O"',
                "states: [ U区关, \"U区开 Ctrl+U\" ]",
                '"U区开 Ctrl+U"',
                "states: [ U编关, \"U编开 Ctrl+Y\" ]",
                '"U编开 Ctrl+Y"',
                "states: [ 。，, \"．， Ctrl+.\" ]",
                '"．， Ctrl+."',
                "states: [ 半角, \"全角 Shift+Space\" ]",
                '"全角 Shift+Space"',
            ],
        )

    def test_switch_shortcut_hints_are_not_duplicated_between_states(self):
        expectations = {
            "tiger_base.schema.yaml": [
                "Shift/Caps",
                "Ctrl+P",
                "Ctrl+I",
                "Ctrl+J",
                "Ctrl+O",
                "Ctrl+U",
                "Ctrl+Y",
                "Ctrl+.",
                "Shift+Space",
            ],
            "PY_c.schema.yaml": [
                "Shift/Caps",
                "Ctrl+P",
                "Ctrl+I",
                "Ctrl+O",
                "Ctrl+U",
                "Ctrl+Y",
                "Ctrl+.",
                "Shift+Space",
            ],
        }

        for config_name, shortcuts in expectations.items():
            section = switches_section(config_name)
            for shortcut in shortcuts:
                self.assertEqual(
                    section.count(shortcut),
                    1,
                    f"{config_name} should show {shortcut} once in switch labels",
                )

    def test_speed_stat_command_is_not_shown_in_switch_labels(self):
        section = switches_section("tiger_base.schema.yaml")

        self.assertIn("states: [ 测速关, 测速开 ]", section)
        self.assertNotIn("\\tj", section)

    def test_desktop_schemas_do_not_show_mobile_keyboard_switches(self):
        for config_name in ("tiger_base.schema.yaml", "PY_c.schema.yaml"):
            section = switches_section(config_name)
            for mobile_only in ("_keyboard_default", "键显", "助记"):
                self.assertNotIn(mobile_only, section)

    def test_active_configs_do_not_remap_arrow_keys_in_switcher_menu(self):
        for config_name in (
            "tiger_base.schema.yaml",
            "PY_c.schema.yaml",
            "配置说明/示例.schema.yaml",
            "配置说明/示例.custom.yaml",
        ):
            config = active_config_text(config_name)

            self.assertNotIn("accept: Right, send: Down", config)
            self.assertNotIn("accept: Left, send: Up", config)

    def test_documented_custom_switch_indices_match_tiger_base_order(self):
        custom_example = (ROOT / "配置说明/示例.custom.yaml").read_text(encoding="utf-8")

        self.assert_contains_all(
            custom_example,
            [
                "switches/@3/states: [ 测速关, 测速开 ]",
                'switches/@4/states: [ "拆隐", "拆显 Ctrl+J Ctrl+Shift+Enter上屏拆分" ]',
                'switches/@5/states: [ 简中, "繁中 Ctrl+O" ]',
                'switches/@6/states: [ U区关, "U区开 Ctrl+U" ]',
                'switches/@7/states: [ U编关, "U编开 Ctrl+Y" ]',
                'switches/@8/states: [ 。，, "．， Ctrl+." ]',
                'switches/@9/states: [ 半角, "全角 Shift+Space" ]',
            ],
        )


if __name__ == "__main__":
    unittest.main()
