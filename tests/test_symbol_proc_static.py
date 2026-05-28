import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SymbolProcStaticTest(unittest.TestCase):
    def assert_symbol_processors_before_key_binder(self, schema_name):
        schema = (ROOT / schema_name).read_text(encoding="utf-8")

        space_proc = "lua_processor@*space_proc3"
        symbol_proc = "lua_processor@*symbol_proc"
        key_binder = "    - key_binder"

        self.assertIn(space_proc, schema)
        self.assertIn(symbol_proc, schema)
        self.assertLess(schema.index(space_proc), schema.index(symbol_proc))
        self.assertLess(schema.index(symbol_proc), schema.index(key_binder))

    def test_tiger_schema_wires_symbol_processors_before_key_binder(self):
        self.assert_symbol_processors_before_key_binder("tiger.schema.yaml")

    def test_tigress_schema_wires_symbol_processors_before_key_binder(self):
        self.assert_symbol_processors_before_key_binder("tigress.schema.yaml")

    def test_symbol_processor_checks_unique_candidate_before_commit(self):
        lua = (ROOT / "lua" / "symbol_proc.lua").read_text(encoding="utf-8")

        self.assertIn("is_symbol_key(key_event)", lua)
        self.assertIn("key_event:repr() == \"space\"", lua)
        self.assertIn("keycode < 0x21 or keycode > 0x7e", lua)
        self.assertIn("string.char(keycode)", lua)
        self.assertIn("seg.menu:prepare(2)", lua)
        self.assertIn("seg.menu:get_candidate_at(0)", lua)
        self.assertIn("seg.menu:get_candidate_at(1)", lua)
        self.assertIn("first.text == context.input", lua)
        self.assertIn("context:confirm_current_selection()", lua)
        self.assertIn("return kNoop -- 放行当前符号，让后续处理器继续触发快符、反查或标点", lua)
        self.assertNotIn("return kAccepted", lua)


if __name__ == "__main__":
    unittest.main()
