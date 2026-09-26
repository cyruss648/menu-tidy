#!/usr/bin/env python3
"""Fast read-only source checks; no third-party Python packages are needed."""

import ast
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tomllib
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".build", ".swiftpm", ".local", "dist", "node_modules", "vendor", "__pycache__"}
MAX_BYTES = 1024 * 1024
TEXT_SUFFIXES = {".swift", ".c", ".h", ".py", ".sh", ".md", ".toml", ".json", ".yaml", ".yml", ".txt"}
TEXT_NAMES = {".editorconfig", ".gitignore", ".gitattributes", "LICENSE"}
# High-confidence credential formats only. Report paths and rule names, never values.
SECRET_PATTERNS = (
    ("private key", re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b")),
    ("OpenAI key", re.compile(rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b")),
    ("Slack token", re.compile(rb"\bxox[baprs]-[0-9A-Za-z-]{24,}\b")),
    ("AWS access key", re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
)


# Reserve these calls in the app target. PID-scoped CGEvent.postToPid remains
# permitted; a global .post(tap:) call is prohibited regardless of receiver name.
# This is a source regression gate, not a complete Swift semantic/security audit.
GLOBAL_INPUT_PATTERNS = (
    ("CGWarpMouseCursorPosition", re.compile(r"\bCGWarpMouseCursorPosition\s*\(")),
    ("CGDisplayMoveCursorToPoint", re.compile(r"\bCGDisplayMoveCursorToPoint\s*\(")),
    ("CGEvent.post(tap:)", re.compile(r"\bpost\s*\(\s*tap\s*:")),
    ("CGEventPostToPSN", re.compile(r"\bCGEventPostToPSN\s*\(")),
    ("CGEventPost", re.compile(r"\bCGEventPost\s*\(")),
    ("CGPostMouseEvent", re.compile(r"\bCGPostMouseEvent\b")),
    ("CGPostScrollWheelEvent", re.compile(r"\bCGPostScrollWheelEvent\b")),
    ("CGPostKeyboardEvent", re.compile(r"\bCGPostKeyboardEvent\b")),
    ("NSCursor.hide", re.compile(r"\bNSCursor\s*\.\s*hide\s*\(")),
    ("CGDisplayHideCursor", re.compile(r"\bCGDisplayHideCursor\s*\(")),
    ("CGAssociateMouseAndMouseCursorPosition", re.compile(r"\bCGAssociateMouseAndMouseCursorPosition\s*\(")),
    ("CGEventSourceSetLocalEventsFilterDuringSuppressionState", re.compile(r"\bCGEventSourceSetLocalEventsFilterDuringSuppressionState\s*\(")),
    ("setLocalEventsFilterDuringSuppressionState", re.compile(r"\bsetLocalEventsFilterDuringSuppressionState\s*\(")),
    ("CGEventSourceSetLocalEventsSuppressionInterval", re.compile(r"\bCGEventSourceSetLocalEventsSuppressionInterval\s*\(")),
    ("localEventsSuppressionInterval write", re.compile(r"\.\s*localEventsSuppressionInterval\s*=(?!=)")),
)

DIAGNOSTIC_SWIFT = Path("Sources/MenuTidy/LegacyNoCursorEventProbe.swift")
DIAGNOSTIC_SHIM = Path("Sources/MenuTidyDiagnosticInput/LegacyNoCursor.c")
DIAGNOSTIC_HEADER = Path("Sources/MenuTidyDiagnosticInput/include/MenuTidyDiagnosticInput.h")
DIAGNOSTIC_SYMBOLS = re.compile(r"\b(?:MenuTidyDiagnosticInput|MenuTidyDiagnosticLegacyMouseButton|MenuTidyDiagnosticPrivateRecordAvailable|MenuTidyDiagnosticPrivateRecordPost)\b")
RETIRED_COMMAND_NAMES = {"MenuTidyDiagnosticPrivateRecordCommandPost"}
RETIRED_COMMAND_SYMBOLS = re.compile(r"\bMenuTidyDiagnosticPrivateRecordCommandPost\b")
PRIVATE_RECORD_NAMES = {"SLSPostEvent", "SLSPostEventRecord", "SLSMainConnectionID"}
PRIVATE_RECORD_SYMBOLS = re.compile(r"\b(?:SLSPostEvent|SLSPostEventRecord|SLSMainConnectionID)\b")
# This is intentionally a fixed shim, not a general C allowlist. Comparing
# tokens permits formatting/comments while rejecting added macros, helpers,
# cursor=true, extra buttons, nonzero private transport control and another post.
# The only private-record entry requires zero flags. The retired Command entry
# is prohibited even inside the diagnostic; it left global modifier state set.
# Exact build/image/instruction validation is also part of this frozen contract.
# Runtime down/up pairing remains the explicit probe's responsibility.
APPROVED_SHIM = r'''#include "MenuTidyDiagnosticInput.h"
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <sys/sysctl.h>
int32_t MenuTidyDiagnosticLegacyMouseButton(double x, double y, bool down) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
CGError result = CGPostMouseEvent(CGPointMake(x, y), false, 1, down);
#pragma clang diagnostic pop
return (int32_t)result;
}
#if defined(__arm64__)
typedef uint32_t (*DiagnosticMainConnection)(void);
typedef int32_t (*DiagnosticPostEvent)(uint32_t, CGEventRef, uint32_t);
static DiagnosticMainConnection private_main_connection;
static DiagnosticPostEvent private_post_event;
static pthread_once_t private_record_once = PTHREAD_ONCE_INIT;
static void initialize_private_record(void) {
char build[64] = {0};
size_t build_size = sizeof(build);
if (sysctlbyname("kern.osversion", build, &build_size, NULL, 0) != 0 ||
build_size == 0 || build_size > sizeof(build) ||
build[build_size - 1] != '\0' || strcmp(build, "26A428") != 0) {
return;
}
void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
RTLD_LOCAL | RTLD_NOW);
if (image == NULL) return;
void *post = dlsym(image, "SLSPostEvent");
void *record = dlsym(image, "SLSPostEventRecord");
void *connection = dlsym(image, "SLSMainConnectionID");
if (post == NULL || record == NULL || connection == NULL) return;
Dl_info post_info, record_info, connection_info;
if (dladdr(post, &post_info) == 0 || dladdr(record, &record_info) == 0 ||
dladdr(connection, &connection_info) == 0 ||
post_info.dli_fbase != record_info.dli_fbase ||
post_info.dli_fbase != connection_info.dli_fbase ||
post_info.dli_fname == NULL ||
strcmp(post_info.dli_fname,
"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight") != 0) {
return;
}
uint32_t code[8];
memcpy(code, post, sizeof(code));
if (code[0] != 0xb40000c1 || code[1] != 0xf9400c21 ||
code[2] != 0xb4000081 || code[3] != 0xaa0203e3 ||
code[4] != 0xb9400422 || (code[5] & 0xfc000000) != 0x14000000 ||
code[6] != 0x52807d00 || code[7] != 0xd65f03c0) {
return;
}
int64_t displacement = (int64_t)(code[5] & 0x03ffffff);
if ((displacement & 0x02000000) != 0) displacement -= 0x04000000;
uintptr_t branch_target = (uintptr_t)post + 20 + displacement * 4;
if (branch_target != (uintptr_t)record) return;
private_main_connection = (DiagnosticMainConnection)connection;
private_post_event = (DiagnosticPostEvent)post;
}
#endif
bool MenuTidyDiagnosticPrivateRecordAvailable(void) {
#if defined(__arm64__)
pthread_once(&private_record_once, initialize_private_record);
return private_main_connection != NULL && private_post_event != NULL;
#else
return false;
#endif
}
static int32_t private_record_mouse_button(CGEventRef event, CGEventFlags required_flags) {
if (event == NULL || CGEventGetFlags(event) != required_flags) return kCGErrorIllegalArgument;
CGEventType type = CGEventGetType(event);
if (type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp) {
return kCGErrorIllegalArgument;
}
if (!MenuTidyDiagnosticPrivateRecordAvailable()) return kCGErrorNotImplemented;
#if defined(__arm64__)
uint32_t connection = private_main_connection();
if (connection == 0) return kCGErrorInvalidConnection;
return private_post_event(connection, event, 0);
#else
return kCGErrorNotImplemented;
#endif
}
int32_t MenuTidyDiagnosticPrivateRecordPost(CGEventRef event) {
return private_record_mouse_button(event, 0);
}
'''
APPROVED_HEADER = '''#ifndef MENU_TIDY_DIAGNOSTIC_INPUT_H
#define MENU_TIDY_DIAGNOSTIC_INPUT_H
#include <stdbool.h>
#include <stdint.h>
#include <CoreGraphics/CGEvent.h>
int32_t MenuTidyDiagnosticLegacyMouseButton(double x, double y, bool down);
bool MenuTidyDiagnosticPrivateRecordAvailable(void);
int32_t MenuTidyDiagnosticPrivateRecordPost(CGEventRef event);
#endif
'''
APPROVED_DISABLED_COMMAND_PREFIX = r'''if CommandLine.arguments.contains("--probe-private-record-command") {
print("{\"kind\":\"disabled\",\"reason\":\"disabled-known-global-modifier-side-effect\",\"inputSent\":false}")
fflush(stdout)
return
}'''
APPROVED_LEGACY_SELECTION = '''let plan = MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst()))
guard plan == .legacyNoCursor || plan == .privateRecord else { return }'''
APPROVED_MAIN_SELECTION = '''switch MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) {
case .rejected:
print("Menu Tidy: rejected incompatible or unknown arguments; no application UI or input started.")
return
case .disabledCommand:
print("Menu Tidy: disabled-known-global-modifier-side-effect; no application UI or input started.")
return
case .ownerObserver(let bundleIdentifier):
runMenuBarVisibilityObserver(bundleIdentifier: bundleIdentifier)
return
case .statusItems:
runTargetedStatusItemProbe()
return
case .targetedEvents:
runTargetedEventProbe()
return
case .legacyNoCursor, .privateRecord:
runLegacyNoCursorEventProbe()
return
case .normal:
break
}'''
DIAGNOSTIC_ENTRY_PREFIXES = {
    Path("Sources/MenuTidy/Main.swift"): (r"\bstatic\s+func\s+main\s*\(\s*\)\s*\{", APPROVED_MAIN_SELECTION),
    DIAGNOSTIC_SWIFT: (r"\bfunc\s+runLegacyNoCursorEventProbe\s*\(\s*\)\s*\{",
                       APPROVED_DISABLED_COMMAND_PREFIX + "\n" + APPROVED_LEGACY_SELECTION),
    Path("Sources/MenuTidy/TargetedEventProbe.swift"): (r"\bfunc\s+runTargetedEventProbe\s*\(\s*\)\s*\{",
        "guard MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) == .targetedEvents else { return }"),
    Path("Sources/MenuTidy/TargetedStatusItemProbe.swift"): (r"\bfunc\s+runTargetedStatusItemProbe\s*\(\s*\)\s*\{",
        "guard MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) == .statusItems else { return }"),
}
C_TOKENS = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|[^\s]')


def c_source_tokens(source: str) -> list[str]:
    """Conservative source spelling check, not C preprocessing/type analysis."""
    return [token for token in C_TOKENS.findall(source) if not token.startswith(("//", "/*"))]


def c_executable_text(source: str) -> str:
    """Retain offsets while masking C comments, string literals and characters."""
    output = list(source)
    for match in C_TOKENS.finditer(source):
        if match.group().startswith(("//", "/*", '"', "'")):
            for index in range(match.start(), match.end()):
                if output[index] not in "\r\n":
                    output[index] = " "
    return "".join(output)


def private_record_api_violations(source: str, executable: str, *,
                                  names=PRIVATE_RECORD_NAMES, symbols=PRIVATE_RECORD_SYMBOLS,
                                  issue="private record API is restricted to the approved fixed diagnostic C shim") -> list[tuple[int, str]]:
    """Check the three reviewed private names, not arbitrary dynamic dispatch.

    Bare symbol references and direct dlsym calls with exact ordinary/raw
    string arguments are covered. Aliases, constructed/escaped symbol strings,
    macro expansion and the Swift probe's runtime call graph require review.
    """
    violations = [(executable.count("\n", 0, match.start()) + 1, issue)
                  for match in symbols.finditer(executable)]
    for match in re.finditer(r"\bdlsym\s*\(", executable):
        depth = 1
        argument_start = None
        for index in range(match.end(), len(executable)):
            character = executable[index]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth != 0:
                    continue
            elif character == "," and depth == 1:
                if argument_start is None:
                    argument_start = index + 1
                    continue
            else:
                continue
            if depth == 0 or (character == "," and depth == 1):
                if argument_start is not None:
                    argument = "".join(c_source_tokens(source[argument_start:index]))
                    literal = re.fullmatch(r'(?P<hashes>#{0,})"(?P<name>[A-Za-z_][A-Za-z_0-9]*)"(?P=hashes)', argument)
                    if literal and literal.group("name") in names:
                        violations.append((executable.count("\n", 0, match.start()) + 1, issue))
                break
    return violations


def retired_command_violations(source: str, executable: str) -> list[tuple[int, str]]:
    return private_record_api_violations(source, executable,
        names=RETIRED_COMMAND_NAMES, symbols=RETIRED_COMMAND_SYMBOLS,
        issue="retired Command diagnostic wrapper is prohibited in every source path")


def disabled_command_entry_violations(source: str, executable: str) -> list[tuple[int, str]]:
    """Require the reviewed early-return prefix, not a Swift call-graph proof.

    The one CLI function must start with the fixed inert branch, before any
    NSApplication.shared access or other setup in its body. This lexical check
    does not establish Main's dispatch behavior, initialization safety elsewhere
    in the file, or the semantics of aliases/macros; those still require review.
    """
    entries = list(re.finditer(r"\bfunc\s+runLegacyNoCursorEventProbe\s*\(\s*\)\s*\{", executable))
    issue = "diagnostic CLI must begin with the fixed disabled Command early return before NSApplication.shared"
    if len(entries) != 1:
        return [(1, issue)]
    entry = entries[0]
    expected = c_source_tokens(APPROVED_DISABLED_COMMAND_PREFIX)
    actual = c_source_tokens(source[entry.end():])
    if actual[:len(expected)] != expected:
        return [(source.count("\n", 0, entry.end()) + 1, issue)]
    return []


def diagnostic_input_violations(source: str, relative: Path) -> list[tuple[int, str]]:
    """Restrict diagnostic imports/references and the fixed C shim by path.

    No symbol resolution, macro expansion or call-graph proof is attempted.
    Alternate spellings/dynamic lookup require review; this is a regression
    gate for explicit source references, never a semantic safety audit.
    """
    if relative.suffix == ".swift":
        executable = swift_executable_text(source)
        violations = private_record_api_violations(source, executable)
        violations.extend(retired_command_violations(source, executable))
        if relative == DIAGNOSTIC_SWIFT:
            violations.extend(disabled_command_entry_violations(source, executable))
        if relative in DIAGNOSTIC_ENTRY_PREFIXES:
            pattern, prefix = DIAGNOSTIC_ENTRY_PREFIXES[relative]
            entries = list(re.finditer(pattern, executable))
            expected = c_source_tokens(prefix)
            if len(entries) != 1 or c_source_tokens(source[entries[0].end():])[:len(expected)] != expected:
                # Fixed spelling regression only; pure launch-plan tests cover
                # argument semantics. This is not a Swift call-graph proof.
                violations.append((1, "diagnostic entry must validate the complete launch plan before app setup or input"))
        if relative != DIAGNOSTIC_SWIFT:
            violations.extend((executable.count("\n", 0, match.start()) + 1,
                               "diagnostic input module/wrapper is restricted to LegacyNoCursorEventProbe.swift")
                              for match in DIAGNOSTIC_SYMBOLS.finditer(executable))
        # The app target already checks all GLOBAL_INPUT_PATTERNS. Legacy global
        # APIs must not move into a second production Swift target either.
        if relative.parts[:1] == ("Sources",) and relative.parts[:2] != ("Sources", "MenuTidy"):
            violations.extend((executable.count("\n", 0, match.start()) + 1,
                               f"prohibited global input API {label}")
                              for label, pattern in GLOBAL_INPUT_PATTERNS if label.startswith("CGPost")
                              for match in pattern.finditer(executable))
        return sorted(violations)
    if relative.suffix not in {".c", ".h"}:
        return []
    executable = c_executable_text(source)
    violations = retired_command_violations(source, executable)
    expected = APPROVED_SHIM if relative == DIAGNOSTIC_SHIM else APPROVED_HEADER if relative == DIAGNOSTIC_HEADER else None
    if expected is not None:
        # C joins escaped newlines before removing comments. A trailing slash in
        # a // comment must not hide a guard while preserving this lexer's tokens.
        fixed_contract = not re.search(r"\\\r?\n", source) and c_source_tokens(source) == c_source_tokens(expected)
        if not fixed_contract:
            violations.append((1, "diagnostic C/header must retain the approved fixed false/single-button and build-checked zero-control private-record contract"))
        return sorted(violations)
    violations.extend((executable.count("\n", 0, match.start()) + 1,
                   "diagnostic wrapper is restricted to its fixed C shim/header")
                  for match in DIAGNOSTIC_SYMBOLS.finditer(executable))
    violations.extend(private_record_api_violations(source, executable))
    violations.extend((executable.count("\n", 0, match.start()) + 1,
                       f"global input API {label} is prohibited outside the fixed diagnostic shim")
                      for label, pattern in GLOBAL_INPUT_PATTERNS
                      for match in pattern.finditer(executable))
    return sorted(violations)


def swift_executable_text(source: str) -> str:
    """Mask comments/string text, retaining offsets and executable interpolation.

    Swift block comments may nest; ordinary, multiline and raw string literals
    may interpolate executable code. Keep their line breaks for diagnostics.
    This bounded lexical scanner does not attempt type resolution.
    """
    output = list(source)
    length = len(source)
    index = 0
    # Frames are (mode, depth or delimiter). Code depth tracks interpolation
    # parentheses; None denotes the outermost Swift source.
    stack: list[tuple[str, int | str | None]] = [("code", None)]

    def mask(start: int, end: int) -> None:
        for offset in range(start, end):
            if output[offset] not in "\r\n":
                output[offset] = " "

    while index < length:
        mode, value = stack[-1]
        if mode == "line":
            if source[index] == "\n":
                stack.pop()
            else:
                mask(index, index + 1)
            index += 1
        elif mode == "block":
            if source.startswith("/*", index):
                stack[-1] = (mode, int(value) + 1)
                mask(index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                depth = int(value) - 1
                if depth:
                    stack[-1] = (mode, depth)
                else:
                    stack.pop()
                mask(index, index + 2)
                index += 2
            else:
                mask(index, index + 1)
                index += 1
        elif mode == "string":
            delimiter = str(value)
            hashes = delimiter.lstrip('"')
            escape = "\\" + hashes
            if source.startswith(escape + "(", index):
                mask(index, index + len(escape) + 1)
                index += len(escape) + 1
                stack.append(("code", 1))
            elif source.startswith(delimiter, index):
                mask(index, index + len(delimiter))
                index += len(delimiter)
                stack.pop()
            elif source.startswith(escape, index):
                end = min(length, index + len(escape) + 1)
                mask(index, end)
                index = end
            else:
                mask(index, index + 1)
                index += 1
        elif source.startswith("//", index):
            stack.append(("line", None))
            mask(index, index + 2)
            index += 2
        elif source.startswith("/*", index):
            stack.append(("block", 1))
            mask(index, index + 2)
            index += 2
        else:
            opening = re.match(r'(#+)?("{3}|")', source[index:]) if source[index] in '#"' else None
            if opening:
                hashes, quotes = opening.groups()
                stack.append(("string", quotes + (hashes or "")))
                mask(index, index + len(opening.group()))
                index += len(opening.group())
            else:
                if value is not None:
                    if source[index] == "(":
                        stack[-1] = ("code", int(value) + 1)
                    elif source[index] == ")":
                        depth = int(value) - 1
                        if depth:
                            stack[-1] = ("code", depth)
                        else:
                            stack.pop()
                # Escaped Swift identifiers denote the same API names.
                if source[index] == "`":
                    mask(index, index + 1)
                index += 1
    return "".join(output)


def global_input_violations(source: str) -> list[tuple[int, str]]:
    executable = swift_executable_text(source)
    return sorted(
        (executable.count("\n", 0, match.start()) + 1, label)
        for label, pattern in GLOBAL_INPUT_PATTERNS
        for match in pattern.finditer(executable)
    )


def selected_files(arguments: list[str]) -> list[str]:
    if arguments:
        return sorted(set(arguments))
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT, capture_output=True, check=True,
    )
    return sorted(set(item.decode("utf-8") for item in result.stdout.split(b"\0") if item))


def main() -> int:
    totals: Counter[str] = Counter()
    errors: list[str] = []
    try:
        files = selected_files(sys.argv[1:])
    except (OSError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"ERROR: cannot enumerate source files ({type(error).__name__})", file=sys.stderr)
        return 1
    for name in files:
        path = ROOT / name
        try:
            relative = path.absolute().relative_to(ROOT)
            if ".." in relative.parts:
                raise ValueError("path escapes repository")
            if EXCLUDED.intersection(relative.parts):
                totals["excluded build/local/dependency paths"] += 1
                continue
            if path.is_symlink():
                errors.append(f"{name}: symbolic links are not checked; commit ordinary source files")
                continue
            if not path.exists():
                totals["deleted files"] += 1
                continue
            if not path.is_file():
                errors.append(f"{name}: not a regular file")
                continue
            if path.suffix.lower() in {".p12", ".pfx", ".key"} or path.name == ".env":
                errors.append(f"{name}: local credential material must not be committed")
                continue
            if path.stat().st_size > MAX_BYTES:
                errors.append(f"{name}: exceeds 1 MiB source limit; put release artifacts in dist/")
                continue
            data = path.read_bytes()
            totals["size and secret signatures"] += 1
            for label, pattern in SECRET_PATTERNS:
                if pattern.search(data):
                    errors.append(f"{name}: possible {label}; remove it and review privately")
            if path.suffix == ".plist":
                plistlib.loads(data)
                totals["plist syntax"] += 1
            expects_text = path.suffix in TEXT_SUFFIXES or path.name in TEXT_NAMES
            if b"\0" in data:
                if expects_text:
                    errors.append(f"{name}: source must be UTF-8 text without NUL bytes")
                    continue
                totals["binary text-check skips"] += 1
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                if expects_text:
                    errors.append(f"{name}: source must be UTF-8 text")
                    continue
                totals["binary text-check skips"] += 1
                continue
            totals["text whitespace"] += 1
            if b"\r" in data:
                errors.append(f"{name}: use LF line endings")
            if data and not data.endswith(b"\n"):
                errors.append(f"{name}: missing final newline")
            for number, line in enumerate(text.splitlines(), 1):
                if line.rstrip(" \t") != line:
                    errors.append(f"{name}:{number}: trailing whitespace")
            if path.suffix == ".swift" and relative.parts[:2] == ("Sources", "MenuTidy"):
                totals["Swift global input safety"] += 1
                for number, api in global_input_violations(text):
                    errors.append(f"{name}:{number}: prohibited global input API {api}; use a verified PID-scoped operation")
            if path.suffix in {".swift", ".c", ".h"}:
                totals["diagnostic input boundary"] += 1
                for number, issue in diagnostic_input_violations(text, relative):
                    errors.append(f"{name}:{number}: {issue}")
            if path.suffix == ".py":
                ast.parse(text, filename=name)
                totals["Python syntax"] += 1
            elif path.suffix == ".sh":
                result = subprocess.run(["bash", "-n", str(path)], capture_output=True, check=False)
                if result.returncode:
                    errors.append(f"{name}: bash -n failed (run it directly for details)")
                totals["shell syntax"] += 1
            elif path.suffix == ".toml":
                tomllib.loads(text)
                totals["TOML syntax"] += 1
            elif path.suffix == ".json":
                json.loads(text)
                totals["JSON syntax"] += 1
        except (OSError, ValueError, SyntaxError, plistlib.InvalidFileException, ExpatError) as error:
            errors.append(f"{name}: source validation failed ({type(error).__name__})")
    for label in ("size and secret signatures", "text whitespace", "Python syntax", "shell syntax", "plist syntax", "TOML syntax", "JSON syntax", "Swift global input safety", "diagnostic input boundary"):
        print(f"{'CHECKED' if totals[label] else 'SKIP'}: {label}: {totals[label]} file(s)")
    for label in ("excluded build/local/dependency paths", "deleted files", "binary text-check skips"):
        if totals[label]:
            print(f"SKIP: {label}: {totals[label]} file(s)")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("PASS: selected source checks (signature and lexical input checks are not a complete security audit)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
