"""Behavioral regressions for the complete source/catalog localization gate."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
import io

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from localization import read_catalog, source_keys, swift_literals, validate_repository


class LocalizationGateTests(unittest.TestCase):
    def test_bare_view_model_and_backend_copy_are_rejected(self):
        for text in ['Text("中文")', 'managementMessage = "中文"', 'throw Failure(message: "中文")']:
            with self.subTest(text=text):
                self.assertTrue(source_keys(text, "Sources/MenuTidy/Any.swift")[1])

    def test_nested_interpolations_and_escaped_quotes_are_read(self):
        source = r'let m = LocalizedMessage("打开「\(name)」：\(LocalizedMessage("失败 \"请重试\""))")'
        keys, errors = source_keys(source, "Sources/MenuTidy/Any.swift")
        self.assertEqual(errors, [])
        self.assertEqual(keys, {'打开「{0}」：{1}', '失败 "请重试"'})

    def test_comments_do_not_count_as_display_copy(self):
        keys, errors = source_keys('/* 中文 /* "中文" */ */\n// "中文"\ncopy /* 中文 */ ("已保存")',
                                   "Sources/MenuTidy/Any.swift")
        self.assertEqual(errors, [])
        self.assertEqual(keys, {"已保存"})

    def test_raw_multiline_and_unicode_escaped_copy_are_checked(self):
        for source in [r'let m = #"中文 \#(count)"#', 'let m = """\n  中文\n  """',
                       r'let m = "\u{4E2D}文"']:
            with self.subTest(source=source):
                self.assertTrue(source_keys(source, "Sources/MenuTidy/Any.swift")[1])
        literal = swift_literals('LocalizedMessage("""\n    文案\n    第二行\n    """)')[0]
        self.assertEqual(literal.key, "文案\n第二行")

    def test_rendered_interpolation_cannot_be_used_as_lookup_key(self):
        self.assertTrue(source_keys(r'copy("项目 \(count)")', "Sources/MenuTidy/Any.swift")[1])

    def test_matching_exemption_is_limited_to_exact_path_and_value(self):
        text = 'let label = "显示隐藏菜单栏项目"'
        self.assertEqual(source_keys(text, "Sources/MenuTidy/MenuBarAccessibility.swift")[1], [])
        self.assertTrue(source_keys(text, "Sources/MenuTidy/SettingsView.swift")[1])
        self.assertTrue(source_keys('let label = "显示隐藏菜单栏项目新文案"',
                                    "Sources/MenuTidy/MenuBarAccessibility.swift")[1])

    def test_duplicate_and_malformed_catalogs_fail(self):
        self.assertTrue(read_catalog('"键" = "Value";\n"键" = "Other";')[1])
        self.assertTrue(read_catalog('"键" = "Value"')[1])
        self.assertTrue(read_catalog('"键" = "\\q";')[1])

    def make_repo(self, root, source='let m = LocalizedMessage("缺少 \\(count) 项")',
                  catalog=None):
        path = root / "Sources/MenuTidy/Model.swift"
        path.parent.mkdir(parents=True)
        path.write_text(source)
        catalog_path = root / "Resources/en.lproj/Localizable.strings"
        catalog_path.parent.mkdir(parents=True)
        catalog_path.write_text(catalog if catalog is not None else '"缺少 {0} 项" = "{0} items missing";')

    def test_missing_empty_and_untranslated_english_fail(self):
        for catalog in ['', '"缺少 {0} 项" = "";', '"缺少 {0} 项" = "缺少 {0} 项";']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_repo(root, catalog=catalog)
                self.assertTrue(validate_repository(root))

    def test_missing_or_invalid_utf8_catalog_fails(self):
        for data in [None, b'\xff']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_repo(root)
                path = root / "Resources/en.lproj/Localizable.strings"
                if data is None:
                    path.unlink()
                else:
                    path.write_bytes(data)
                self.assertTrue(validate_repository(root))

    def test_message_and_printf_placeholder_mismatches_fail(self):
        cases = [('缺少 {0} 项', 'Missing items'),
                 ('缺少 {0} 项', '{1} missing'),
                 ('共 %lld 项', '%@ items'),
                 ('%@，%lld', '%lld, %@')]
        for key, value in cases:
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_repo(root, source="",
                               catalog=f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value)};')
                self.assertTrue(validate_repository(root))

    def test_placeholder_reordering_is_allowed_with_positions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root, source="", catalog='"%@ %lld {0} {1}" = "{1} %2$lld %1$@ {0}";')
            self.assertEqual(validate_repository(root), [])

    def test_partial_file_hook_still_checks_unchanged_source_and_catalog(self):
        script = Path(__file__).resolve().parents[1] / "check-source.py"
        spec = importlib.util.spec_from_file_location("localization_source_check", script)
        checks = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checks)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root, catalog="")
            (root / "README.md").write_text("Documentation only.\n")
            with patch.object(checks, "ROOT", root), patch.object(sys, "argv", [str(script), "README.md"]), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as error:
                self.assertEqual(checks.main(), 1)
                self.assertIn("missing English key", error.getvalue())

    def test_english_release_history_cannot_omit_a_version_or_contain_chinese(self):
        for english in ["## [0.7.5]\nEnglish notes.\n", "## [0.7.6]\n中文说明。\n"]:
            with self.subTest(english=english), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_repo(root)
                (root / "CHANGELOG.md").write_text("## [0.7.6]\n中文说明。\n")
                (root / "Resources/en.lproj/CHANGELOG.md").write_text(english)
                self.assertTrue(validate_repository(root))
