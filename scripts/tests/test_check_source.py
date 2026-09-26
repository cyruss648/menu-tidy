"""Regression tests for the no-global-input source gate (stdlib only)."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check-source.py"
SPEC = importlib.util.spec_from_file_location("source_checks", SCRIPT)
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)
SAFE_DIAGNOSTIC_ENTRY = ("func runLegacyNoCursorEventProbe() {\n" +
                         CHECKS.APPROVED_DISABLED_COMMAND_PREFIX +
                         "\n" + CHECKS.APPROVED_LEGACY_SELECTION +
                         "\nlet application = NSApplication.shared\n}\n")


class GlobalInputSourceGateTests(unittest.TestCase):
    def test_global_cursor_and_event_calls_are_rejected(self):
        cases = {
            "CGWarpMouseCursorPosition(point)": "CGWarpMouseCursorPosition",
            "CoreGraphics.CGDisplayMoveCursorToPoint(display, point)": "CGDisplayMoveCursorToPoint",
            "event.post(tap: .cghidEventTap)": "CGEvent.post(tap:)",
            "CGEventPostToPSN(&serial, event)": "CGEventPostToPSN",
            "CGEventPost(.cghidEventTap, event)": "CGEventPost",
            "CGPostMouseEvent(point, false, 1, down)": "CGPostMouseEvent",
            "CGPostScrollWheelEvent(1, amount)": "CGPostScrollWheelEvent",
            "CGPostKeyboardEvent(0, key, true)": "CGPostKeyboardEvent",
            "NSCursor.hide()": "NSCursor.hide",
            "CGDisplayHideCursor(display)": "CGDisplayHideCursor",
            "CGAssociateMouseAndMouseCursorPosition(false)": "CGAssociateMouseAndMouseCursorPosition",
            "CGEventSourceSetLocalEventsFilterDuringSuppressionState(source, mask, state)": "CGEventSourceSetLocalEventsFilterDuringSuppressionState",
            "source.setLocalEventsFilterDuringSuppressionState([], state: state)": "setLocalEventsFilterDuringSuppressionState",
            "CGEventSourceSetLocalEventsSuppressionInterval(source, 1)": "CGEventSourceSetLocalEventsSuppressionInterval",
            "source.localEventsSuppressionInterval = 1": "localEventsSuppressionInterval write",
        }
        for source, label in cases.items():
            with self.subTest(source=source):
                self.assertEqual(CHECKS.global_input_violations(source), [(1, label)])

    def test_whitespace_multiline_and_inline_comments_do_not_hide_calls(self):
        source = """event
            . post /* receiver remains global */ (
                tap /* argument label */ : .cghidEventTap)
        NSCursor /* note */
            . hide
            ( )
        CGWarpMouseCursorPosition
            (point)
        """
        self.assertEqual(CHECKS.global_input_violations(source), [
            (2, "CGEvent.post(tap:)"), (4, "NSCursor.hide"), (7, "CGWarpMouseCursorPosition"),
        ])

    def test_pid_scoped_post_does_not_allow_a_global_call_in_the_same_file(self):
        source = "event.postToPid(ownerPID)\nevent.post(tap: .cgSessionEventTap)\n"
        self.assertEqual(CHECKS.global_input_violations(source), [(2, "CGEvent.post(tap:)")])
        self.assertEqual(CHECKS.global_input_violations("event.postToPid(ownerPID)"), [])

    def test_comments_including_nested_swift_comments_are_ignored(self):
        source = """// CGWarpMouseCursorPosition(point)
        /* NSCursor.hide()
           /* event.post(tap: .cghidEventTap) */
           CGEventPost(tap, event)
        */
        event.postToPid(ownerPID)
        """
        self.assertEqual(CHECKS.global_input_violations(source), [])

    def test_literal_examples_urls_and_raw_strings_are_not_executable_calls(self):
        source = '''let help = "NSCursor.hide()"
        let url = "https://example.invalid/*docs*/"
        let raw = #"event.post(tap: .cghidEventTap)"#
        let multi = """
            CGEventPost(tap, event)
            """
        let rawMulti = ##"""
            CGWarpMouseCursorPosition(point)
            """##
        '''
        self.assertEqual(CHECKS.global_input_violations(source), [])

    def test_executable_string_interpolation_is_still_checked(self):
        source = r'''let normal = "result: \(CGWarpMouseCursorPosition(point))"
        let raw = #"result: \#(CGDisplayMoveCursorToPoint(display, point))"#
        let nested = "text \("more \(CGAssociateMouseAndMouseCursorPosition(false))")"
        '''
        self.assertEqual(CHECKS.global_input_violations(source), [
            (1, "CGWarpMouseCursorPosition"), (2, "CGDisplayMoveCursorToPoint"),
            (3, "CGAssociateMouseAndMouseCursorPosition"),
        ])

    def test_comment_markers_inside_a_string_do_not_hide_later_code(self):
        source = 'let url = "https://example.invalid"; CGEventPost(tap, event)\n'
        self.assertEqual(CHECKS.global_input_violations(source), [(1, "CGEventPost")])

    def test_escaped_identifiers_and_optional_receivers_remain_checked(self):
        source = "event?.`post`(tap: .cghidEventTap)\nNSCursor.`hide`()\n"
        self.assertEqual(CHECKS.global_input_violations(source), [
            (1, "CGEvent.post(tap:)"), (2, "NSCursor.hide"),
        ])

    def test_similarly_named_functions_are_not_forbidden(self):
        source = "logCGEventPost(tap, event)\nCGEventPostDiagnostic()\ncursor.hide()\n"
        self.assertEqual(CHECKS.global_input_violations(source), [])

    def test_reading_suppression_state_is_not_writing_it(self):
        source = "let interval = source.localEventsSuppressionInterval\nif source.localEventsSuppressionInterval == 0 {}\n"
        self.assertEqual(CHECKS.global_input_violations(source), [])

    def test_cli_fails_app_target_and_reports_location_without_source_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "Sources/MenuTidy/Unsafe.swift"
            path = root / name
            path.parent.mkdir(parents=True)
            path.write_text("// fixture\nCGWarpMouseCursorPosition(privateFixtureValue)\n")
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(CHECKS, "ROOT", root), patch.object(CHECKS.sys, "argv", [str(SCRIPT), name]), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                result = CHECKS.main()
            self.assertEqual(result, 1)
            self.assertIn(f"{name}:2: prohibited global input API CGWarpMouseCursorPosition", stderr.getvalue())
            self.assertNotIn("privateFixtureValue", stderr.getvalue())
            self.assertIn("Swift global input safety: 1 file(s)", stdout.getvalue())

    def test_cli_scope_excludes_core_and_test_fixtures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ["Sources/MenuTidyCore/Fixture.swift", "Tests/Fixture.swift"]
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("CGWarpMouseCursorPosition(point)\n")
            with patch.object(CHECKS, "ROOT", root), patch.object(CHECKS.sys, "argv", [str(SCRIPT), *names]), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(CHECKS.main(), 0)


class DiagnosticInputBoundaryTests(unittest.TestCase):
    def check_file(self, name, data):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / name
            path.parent.mkdir(parents=True)
            if name == "Sources/MenuTidy/Main.swift" and isinstance(data, str) and "static func main()" not in data:
                # Fragment tests exercise separate lexical rules while keeping
                # the new full-file launch prefix present in their fixture.
                data += "\nenum MenuTidyApp { static func main() {\n" + CHECKS.APPROVED_MAIN_SELECTION + "\n} }\n"
            path.write_bytes(data.encode() if isinstance(data, str) else data)
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(CHECKS, "ROOT", root), patch.object(CHECKS.sys, "argv", [str(SCRIPT), name]), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                result = CHECKS.main()
            return result, stdout.getvalue(), stderr.getvalue()

    def test_wrapper_import_or_reference_cannot_move_to_normal_swift(self):
        for name in ["Sources/MenuTidy/Main.swift", "Sources/MenuTidyCore/Helper.swift",
                     "Sources/OtherTarget/LegacyNoCursorEventProbe.swift"]:
            for source in ["import MenuTidyDiagnosticInput\n",
                           "@_implementationOnly import /* comment */\n MenuTidyDiagnosticInput\n",
                           "MenuTidyDiagnosticInput.MenuTidyDiagnosticLegacyMouseButton(x, y, true)\n",
                           "let callback = MenuTidyDiagnosticLegacyMouseButton\n",
                           "MenuTidyDiagnosticPrivateRecordAvailable()\n",
                           "MenuTidyDiagnosticPrivateRecordPost(event)\n",
                           "let callback = MenuTidyDiagnosticPrivateRecordPost\n"]:
                with self.subTest(name=name, source=source):
                    result, _, error = self.check_file(name, source)
                    self.assertEqual(result, 1)
                    self.assertIn("restricted to LegacyNoCursorEventProbe.swift", error)

    def test_only_exact_probe_path_may_use_the_diagnostic_wrapper(self):
        source = ("import MenuTidyDiagnosticInput\nMenuTidyDiagnosticLegacyMouseButton(x, y, false)\n"
                  "if MenuTidyDiagnosticPrivateRecordAvailable() { MenuTidyDiagnosticPrivateRecordPost(event) }\n" +
                  SAFE_DIAGNOSTIC_ENTRY)
        result, _, error = self.check_file("Sources/MenuTidy/LegacyNoCursorEventProbe.swift", source)
        self.assertEqual(result, 0, error)
        # Being the diagnostic entry point does not allow a direct global API.
        result, _, error = self.check_file("Sources/MenuTidy/LegacyNoCursorEventProbe.swift",
                                         "CGPostMouseEvent(point, false, 1, down)\n")
        self.assertEqual(result, 1)
        self.assertIn("prohibited global input API CGPostMouseEvent", error)

    def test_comments_examples_and_main_cli_entry_are_not_wrapper_usage(self):
        source = '''// import MenuTidyDiagnosticInput
        let example = "MenuTidyDiagnosticLegacyMouseButton(x, y, true)"
        /* MenuTidyDiagnosticInput */
        if explicitDiagnosticFlag { runLegacyNoCursorEventProbe() }
        '''.strip() + "\n"
        result, _, error = self.check_file("Sources/MenuTidy/Main.swift", source)
        self.assertEqual(result, 0, error)

    def test_legacy_api_aliases_and_interpolations_remain_forbidden(self):
        source = '''let callback = CGPostKeyboardEvent
        let sample = "\\(CGPostMouseEvent(point, false, 1, down))"
        CGPostScrollWheelEvent /* comment */
            (1, amount)
        '''
        self.assertEqual(CHECKS.global_input_violations(source), [
            (1, "CGPostKeyboardEvent"), (2, "CGPostMouseEvent"), (3, "CGPostScrollWheelEvent"),
        ])
        result, _, error = self.check_file("Sources/MenuTidyCore/NewBridge.swift", source)
        self.assertEqual(result, 1)
        self.assertIn("CGPostKeyboardEvent", error)

    def test_current_fixed_shim_and_header_pass_but_copied_shim_does_not(self):
        for name in ["Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c",
                     "Sources/MenuTidyDiagnosticInput/include/MenuTidyDiagnosticInput.h"]:
            source = (SCRIPT.parents[1] / name).read_text()
            result, _, error = self.check_file(name, source)
            self.assertEqual(result, 0, error)
            result, _, error = self.check_file("Sources/OtherInput/" + Path(name).name, source)
            self.assertEqual(result, 1)
            self.assertIn("restricted to its fixed C shim/header", error)

    def test_fixed_shim_rejects_cursor_updates_extra_buttons_and_macro_changes(self):
        name = "Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c"
        source = (SCRIPT.parents[1] / name).read_text()
        mutations = [
            source.replace("false, 1, down", "true, 1, down"),
            source.replace("false, 1, down", "false, 2, down, true"),
            source.replace("false, 1, down", "false, 1, true"),
            "#define false true\n" + source,
            '#include "UnreviewedInput.h"\n' + source,
            source.replace("return (int32_t)result;", "CGPostKeyboardEvent(0, 1, true);\n    return (int32_t)result;"),
        ]
        for changed in mutations:
            with self.subTest(changed=changed):
                result, _, error = self.check_file(name, changed)
                self.assertEqual(result, 1)
                self.assertIn("approved fixed false/single-button", error)

    def test_fixed_private_record_contract_rejects_nonzero_control_and_additional_posts(self):
        name = "Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c"
        source = (SCRIPT.parents[1] / name).read_text()
        call = "return private_post_event(connection, event, 0);"
        self.assertIn(call, source)
        for replacement in [
            "return private_post_event(connection, event, 1);",
            "return private_post_event(connection, event, true);",
            "return private_post_event(connection, event, CGEventGetFlags(event));",
            "private_post_event(connection, event, 0);\n" + call,
            "MenuTidyDiagnosticLegacyMouseButton(0, 0, true);\n" + call,
        ]:
            with self.subTest(replacement=replacement):
                result, _, error = self.check_file(name, source.replace(call, replacement))
                self.assertEqual(result, 1)
                self.assertIn("zero-control private-record contract", error)

    def test_fixed_private_record_contract_rejects_removed_or_changed_abi_guards(self):
        name = "Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c"
        source = (SCRIPT.parents[1] / name).read_text()
        mutations = [
            ('strcmp(build, "26A428") != 0', 'strcmp(build, "26A429") != 0'),
            ('strcmp(build, "26A428") != 0', "false"),
            ('sysctlbyname("kern.osversion", build, &build_size, NULL, 0) != 0', "false"),
            ("build_size > sizeof(build)", "false"),
            ("post_info.dli_fbase != record_info.dli_fbase", "false"),
            ("post_info.dli_fbase != connection_info.dli_fbase", "false"),
            ("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", "/tmp/SkyLight"),
            ("code[0] != 0xb40000c1", "false"),
            ("code[1] != 0xf9400c21", "code[1] != 0xf9400821"),
            ("code[3] != 0xaa0203e3", "false"),
            ("(code[5] & 0xfc000000) != 0x14000000", "false"),
            ("if (branch_target != (uintptr_t)record) return;", ""),
            ("#if defined(__arm64__)", "#if 1"),
            ("event == NULL || CGEventGetFlags(event) != required_flags", "event == NULL"),
            ("type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp", "false"),
            ("if (!MenuTidyDiagnosticPrivateRecordAvailable()) return kCGErrorNotImplemented;", ""),
        ]
        for before, after in mutations:
            with self.subTest(guard=before):
                self.assertIn(before, source)
                result, _, error = self.check_file(name, source.replace(before, after))
                self.assertEqual(result, 1)
                self.assertIn("build-checked zero-control private-record contract", error)

    def test_ordinary_private_entry_cannot_acquire_command_or_arbitrary_flags(self):
        name = "Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c"
        source = (SCRIPT.parents[1] / name).read_text()
        call = "return private_record_mouse_button(event, 0);"
        self.assertEqual(source.count(call), 1)
        for flags in ["kCGEventFlagMaskCommand", "CGEventGetFlags(event)", "kCGEventFlagMaskShift"]:
            with self.subTest(flags=flags):
                result, _, error = self.check_file(name, source.replace(call, f"return private_record_mouse_button(event, {flags});"))
                self.assertEqual(result, 1)
                self.assertIn("approved fixed", error)

    def test_retired_command_wrapper_cannot_be_referenced_even_by_the_probe(self):
        symbol = "MenuTidyDiagnosticPrivateRecordCommandPost"
        for name in ["Sources/MenuTidy/LegacyNoCursorEventProbe.swift", "Sources/MenuTidy/Main.swift",
                     "Sources/MenuTidyCore/Helper.swift", "Sources/OtherInput/Input.c", "Sources/OtherInput/Input.h"]:
            for statement in [f"{symbol}(event);\n", f"let callback = {symbol}\n",
                              f"MenuTidyDiagnosticInput.{symbol}(event)\n",
                              f'dlsym(handle, "{symbol}");\n']:
                with self.subTest(name=name, statement=statement):
                    source = SAFE_DIAGNOSTIC_ENTRY + statement if name == str(CHECKS.DIAGNOSTIC_SWIFT) else statement
                    result, _, error = self.check_file(name, source)
                    self.assertEqual(result, 1)
                    self.assertIn("retired Command diagnostic wrapper", error)
        for statement in [f"`{symbol}`(event)\n", f'let log = "\\({symbol}(event))"\n',
                          f'dlsym(handle, #"{symbol}"#)\n']:
            result, _, error = self.check_file(str(CHECKS.DIAGNOSTIC_SWIFT), SAFE_DIAGNOSTIC_ENTRY + statement)
            self.assertEqual(result, 1)
            self.assertIn("retired Command diagnostic wrapper", error)

    def test_retired_command_wrapper_cannot_be_reintroduced_in_fixed_c_or_header(self):
        symbol = "MenuTidyDiagnosticPrivateRecordCommandPost"
        for name in [str(CHECKS.DIAGNOSTIC_SHIM), str(CHECKS.DIAGNOSTIC_HEADER)]:
            source = (SCRIPT.parents[1] / name).read_text()
            self.assertNotIn(symbol, CHECKS.c_executable_text(source))
            for addition in [f"int32_t {symbol}(CGEventRef event);\n",
                             f"int32_t {symbol}(CGEventRef event) {{ return private_record_mouse_button(event, kCGEventFlagMaskCommand); }}\n"]:
                with self.subTest(name=name, addition=addition):
                    result, _, error = self.check_file(name, source + addition)
                    self.assertEqual(result, 1)
                    self.assertIn("retired Command diagnostic wrapper", error)
                    self.assertIn("approved fixed", error)

    def test_retired_symbol_in_logs_and_comments_is_not_a_reference(self):
        symbol = "MenuTidyDiagnosticPrivateRecordCommandPost"
        statement = f'// {symbol}(event)\nlet note = "{symbol} was removed"\n'
        result, _, error = self.check_file(str(CHECKS.DIAGNOSTIC_SWIFT), SAFE_DIAGNOSTIC_ENTRY + statement)
        self.assertEqual(result, 0, error)
        result, _, error = self.check_file("Sources/OtherInput/Note.c",
            f'/* {symbol}(event) */\nconst char *note = "{symbol} was removed";\n')
        self.assertEqual(result, 0, error)

    def test_command_cli_disable_must_precede_application_setup_and_return(self):
        name = str(CHECKS.DIAGNOSTIC_SWIFT)
        source = (SCRIPT.parents[1] / name).read_text()
        result, _, error = self.check_file(name, source)
        self.assertEqual(result, 0, error)
        start = source.index('    if CommandLine.arguments.contains("--probe-private-record-command")')
        end = source.index("    let plan =", start)
        disable = source[start:end]
        without = source[:start] + source[end:]
        app_setup = "let application = NSApplication.shared"
        mutations = [
            without,
            source.replace(disable, disable.replace("        return\n", "")),
            source.replace(disable, "    " + app_setup + "\n" + disable),
            without.replace(app_setup, app_setup + "\n" + disable),
            source.replace(disable, disable.replace(") {", ") && false {", 1)),
            source.replace(disable, disable.replace("disabled-known-global-modifier-side-effect", "enabled")),
            source.replace("func runLegacyNoCursorEventProbe()", "func anotherEntry()"),
            source + SAFE_DIAGNOSTIC_ENTRY,
        ]
        for changed in mutations:
            with self.subTest(changed=changed[-1800:]):
                self.assertNotEqual(changed, source)
                result, _, error = self.check_file(name, changed)
                self.assertEqual(result, 1)
                self.assertIn("disabled Command early return before NSApplication.shared", error)

    def test_fixed_contract_allows_only_comment_and_whitespace_changes(self):
        for name in ["Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c",
                     "Sources/MenuTidyDiagnosticInput/include/MenuTidyDiagnosticInput.h"]:
            source = (SCRIPT.parents[1] / name).read_text()
            changed = "/* A review note is not executable. */\n\n" + source.replace("(CGEventRef event)", "( /* type */ CGEventRef  event )")
            result, _, error = self.check_file(name, changed)
            self.assertEqual(result, 0, error)

    def test_c_line_splicing_cannot_hide_a_guard_from_the_fixed_token_check(self):
        name = "Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c"
        source = (SCRIPT.parents[1] / name).read_text()
        guard = "if (branch_target != (uintptr_t)record) return;"
        self.assertIn(guard, source)
        changed = source.replace(guard, "// continued comment " + "\\" + "\n" + guard)
        # Tokens alone would miss C's earlier escaped-newline processing.
        self.assertEqual(CHECKS.c_source_tokens(changed), CHECKS.c_source_tokens(source))
        result, _, error = self.check_file(name, changed)
        self.assertEqual(result, 1)
        self.assertIn("build-checked zero-control private-record contract", error)

    def test_private_symbols_and_literal_lookups_cannot_escape_the_fixed_shim(self):
        names = ["Sources/MenuTidy/Main.swift", "Sources/MenuTidy/LegacyNoCursorEventProbe.swift",
                 "Sources/MenuTidyCore/Helper.swift", "Sources/OtherInput/Input.c", "Sources/OtherInput/Input.h"]
        for name in names:
            for symbol in sorted(CHECKS.PRIVATE_RECORD_NAMES):
                for source in [f"let callback = {symbol}\n", f'{symbol}(connection, event, 0);\n',
                               f'dlsym(handle, "{symbol}");\n',
                               f'dlsym /* name */ (openImage(path), /* symbol */ "{symbol}");\n']:
                    with self.subTest(name=name, symbol=symbol, source=source):
                        result, _, error = self.check_file(name, source)
                        self.assertEqual(result, 1)
                        self.assertIn("private record API is restricted", error)
        for source in ['dlsym(handle, #"SLSPostEvent"#)\n',
                       'dlsym(handle, ##"SLSPostEventRecord"##)\n',
                       'let value = "\\(dlsym(handle, "SLSMainConnectionID"))"\n']:
            result, _, error = self.check_file("Sources/MenuTidy/Main.swift", source)
            self.assertEqual(result, 1)
            self.assertIn("private record API is restricted", error)

    def test_private_api_log_names_and_unrelated_lookups_are_not_executable_private_calls(self):
        source = '''let apiName = "SLSPostEvent"
let example = "dlsym(handle, \\"SLSPostEventRecord\\")"
// dlsym(handle, "SLSMainConnectionID")
/* SLSPostEvent(connection, event, 0) */
let other = dlsym(handle, "_AXUIElementGetWindow")
'''
        for name in ["Sources/MenuTidy/LegacyNoCursorEventProbe.swift", "Sources/MenuTidy/Main.swift"]:
            candidate = source + SAFE_DIAGNOSTIC_ENTRY if name == str(CHECKS.DIAGNOSTIC_SWIFT) else source
            result, _, error = self.check_file(name, candidate)
            self.assertEqual(result, 0, error)

    def test_fixed_header_cannot_add_an_input_macro_or_function(self):
        name = "Sources/MenuTidyDiagnosticInput/include/MenuTidyDiagnosticInput.h"
        source = (SCRIPT.parents[1] / name).read_text() + "#define down true\n"
        result, _, error = self.check_file(name, source)
        self.assertEqual(result, 1)
        self.assertIn("approved fixed", error)

    def test_c_call_detection_ignores_comments_and_literals(self):
        source = '''// CGPostMouseEvent(point, true, 1, down);
const char *example = "CGPostKeyboardEvent(0, key, true)";
/* CGPostScrollWheelEvent(1, amount); */
'''
        result, _, error = self.check_file("Sources/OtherInput/Harmless.c", source)
        self.assertEqual(result, 0, error)
        result, _, error = self.check_file("Sources/OtherInput/Unsafe.c",
                                         source + "CGPostMouseEvent\n (point, false, 1, down);\n")
        self.assertEqual(result, 1)
        self.assertIn("CGPostMouseEvent", error)

    def test_c_and_header_are_required_to_be_utf8_without_nuls(self):
        for suffix in [".c", ".h"]:
            for data in [b"\xff\n", b"int value;\0\n"]:
                with self.subTest(suffix=suffix, data=data):
                    result, _, error = self.check_file("Sources/OtherInput/Fixture" + suffix, data)
                    self.assertEqual(result, 1)
                    self.assertIn("source must be UTF-8 text", error)

    def test_c_and_header_secret_checks_report_rule_without_fixture_value(self):
        token = "ghp_" + "A" * 40
        for suffix in [".c", ".h"]:
            with self.subTest(suffix=suffix):
                result, _, error = self.check_file("Sources/OtherInput/Fixture" + suffix,
                                                 f'const char *fixture = "{token}";\n')
                self.assertEqual(result, 1)
                self.assertIn("possible GitHub token", error)
                self.assertNotIn(token, error)

    def test_all_diagnostic_entries_have_reviewed_launch_selection(self):
        for path in CHECKS.DIAGNOSTIC_ENTRY_PREFIXES:
            with self.subTest(path=path):
                source = (SCRIPT.parents[1] / path).read_text()
                self.assertEqual(CHECKS.diagnostic_input_violations(source, path), [])

    def test_app_setup_before_any_diagnostic_selection_is_rejected(self):
        for path, (pattern, _) in CHECKS.DIAGNOSTIC_ENTRY_PREFIXES.items():
            with self.subTest(path=path):
                source = (SCRIPT.parents[1] / path).read_text()
                entry = CHECKS.re.search(pattern, CHECKS.swift_executable_text(source))
                self.assertIsNotNone(entry)
                changed = source[:entry.end()] + '\nlet early = NSApplication.shared\n' + source[entry.end():]
                errors = CHECKS.diagnostic_input_violations(changed, path)
                self.assertTrue(any('complete launch plan before app setup' in reason for _, reason in errors))

    def test_bypassing_parser_or_dispatching_rejected_arguments_is_rejected(self):
        for path in CHECKS.DIAGNOSTIC_ENTRY_PREFIXES:
            source = (SCRIPT.parents[1] / path).read_text()
            changed = source.replace('MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst()))', '.normal')
            with self.subTest(path=path):
                errors = CHECKS.diagnostic_input_violations(changed, path)
                self.assertTrue(any('complete launch plan before app setup' in reason for _, reason in errors))
        path = Path('Sources/MenuTidy/Main.swift')
        source = (SCRIPT.parents[1] / path).read_text()
        changed = source.replace('case .rejected:', 'case .rejected:\nrunLegacyNoCursorEventProbe()')
        errors = CHECKS.diagnostic_input_violations(changed, path)
        self.assertTrue(any('complete launch plan before app setup' in reason for _, reason in errors))


if __name__ == "__main__":
    unittest.main()
