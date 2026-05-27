import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class TigressUserWordsStaticTest(unittest.TestCase):
    def test_tigress_schema_wires_user_word_manager(self):
        schema = (ROOT / "tigress.schema.yaml").read_text(encoding="utf-8")

        processor = "lua_processor@*tigress_user_words*processor"
        self.assertIn(processor, schema)
        self.assertLess(schema.index(processor), schema.index("    - key_binder"))

        filter_ = "lua_filter@*tigress_user_words*filter"
        self.assertIn(filter_, schema)
        self.assertLess(schema.index(filter_), schema.index("    - uniquifier"))

    def test_tiger_schema_is_not_wired(self):
        schema = (ROOT / "tiger.schema.yaml").read_text(encoding="utf-8")
        self.assertNotIn("tigress_user_words", schema)

    def test_lua_module_targets_tigress_files(self):
        lua = (ROOT / "lua" / "tigress_user_words.lua").read_text(encoding="utf-8")

        self.assertIn('extended_dict = "tigress.extended.dict.yaml"', lua)
        self.assertIn('"tigress.dict.yaml"', lua)
        self.assertIn('"tigress_ci.dict.yaml"', lua)
        self.assertIn('"tigress_simp_ci.dict.yaml"', lua)
        self.assertIn("Ctrl+;", lua)
        self.assertIn("Ctrl+'", lua)
        self.assertNotIn("Shift+Alt++", lua)
        self.assertNotIn("Shift+Alt+-", lua)
        self.assertNotIn("Ctrl+Alt++", lua)
        self.assertNotIn("Ctrl+Alt+-", lua)
        self.assertIn("is_ctrl_shortcut", lua)
        self.assertNotIn("is_shift_alt", lua)
        self.assertNotIn("is_ctrl_alt", lua)
        self.assertIn("key_event:ctrl() and not key_event:alt() and not key_event:shift()", lua)
        self.assertIn("USER_WORDS_MARKER", lua)
        self.assertIn("local shared_state", lua)
        self.assertIn("persist_disable", lua)
        self.assertIn("rewrite_generated_section", lua)
        self.assertIn("disable_in_file", lua)
        self.assertIn("append_disable_marker", lua)
        self.assertIn("append_enable_marker", lua)
        self.assertIn("parse_marker", lua)
        self.assertIn("KEY.UP", lua)
        self.assertIn("KEY.LEFT", lua)
        self.assertIn("KEY.HOME", lua)
        self.assertIn("KEY.END", lua)
        self.assertIn("select_moved_candidate", lua)
        self.assertIn("moved.text", lua)
        self.assertIn("append_capture_input", lua)
        self.assertIn("capture_backspace", lua)
        self.assertIn("capture_status_text", lua)
        self.assertIn("capture_status_candidate", lua)
        self.assertIn("加词", lua)
        self.assertIn("Esc退出", lua)
        self.assertIn("Backspace删除", lua)
        self.assertIn("Enter确认", lua)
        self.assertIn('Candidate("tigress_user_status"', lua)
        self.assertIn('Candidate("tigress_user_word", start, finish, text, "")', lua)
        self.assertIn("is_status_candidate", lua)
        self.assertIn('operation or "add"', lua)
        self.assertIn('enter_capture(env, "add")', lua)
        self.assertIn('enter_capture(env, "disable")', lua)
        self.assertIn("finish_capture(env)", lua)
        self.assertIn("if keycode == KEY.RETURN", lua)
        self.assertIn("if env.state and env.state.capture then", lua)
        self.assertIn("ctx.input = query ~= \"\" and query or env.capture.code", lua)
        self.assertIn("if not env.state.capture.query or env.state.capture.query == \"\" then", lua)
        self.assertNotIn("CAPTURE_STATUS_INPUT", lua)
        self.assertNotIn('"用户词"', lua)

    def test_current_custom_does_not_override_processor_or_filter_lists(self):
        custom = (ROOT / "tigress.custom.yaml").read_text(encoding="utf-8")
        self.assertNotIn("engine/processors", custom)
        self.assertNotIn("engine/filters", custom)


if __name__ == "__main__":
    unittest.main()
