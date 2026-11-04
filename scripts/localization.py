"""Localization source/catalog regression gate. Python stdlib only.

The Swift compiler checks message types; this lexer checks literal coverage.
It is deliberately not a Swift semantic analyzer. Matching tokens are exempt
by exact path/value, never by entire backend/model directories.
"""

from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import json
import re
import sys


HAN = re.compile(r"[\u3400-\u9fff\U00020000-\U0003134f]")
KEY_CALLS = {"LocalizedMessage", "copy", "localized", "format", "localizedFormat"}
# AX matching data, not display copy. Both system-language spellings are needed.
MATCHING_DATA = {
    ("Sources/MenuTidy/MenuBarAccessibility.swift", "显示隐藏菜单栏项目"),
    ("Sources/MenuTidy/MenuBarAccessibility.swift", "隐藏菜单栏项目"),
}


@dataclass
class Literal:
    start: int
    end: int
    key: str
    interpolated: bool
    arguments: tuple[str, ...] = ()


def swift_literals(source: str) -> list[Literal]:
    """Read nested comments, ordinary/raw/multiline strings and interpolations.

    Interpolation expressions are scanned recursively, including nested strings.
    Literal escapes are decoded before catalog lookup. Unsupported escapes fail
    closed instead of silently overlooking a display message.
    """
    literals = []
    length = len(source)

    def comment(index):
        if source.startswith("//", index):
            end = source.find("\n", index)
            return length if end < 0 else end
        depth = 1
        index += 2
        while index < length and depth:
            if source.startswith("/*", index):
                depth += 1
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        if depth:
            raise ValueError("unterminated Swift comment")
        return index

    def string(index, hashes, quote):
        start = index
        index += len(hashes) + len(quote)
        closing = quote + hashes
        escape = "\\" + hashes
        parts = []
        argument_count = 0
        arguments = []
        while index < length:
            if source.startswith(closing, index):
                end = index + len(closing)
                key = "".join(parts)
                if len(quote) == 3:
                    # Swift removes the opening newline and the indentation of
                    # the closing delimiter from each line.
                    closing_indent = source[source.rfind("\n", start, index) + 1:index]
                    if closing_indent.strip():
                        raise ValueError("multiline delimiter must be on its own line")
                    if key.startswith("\n"):
                        key = key[1:]
                    key = "\n".join(line[len(closing_indent):] if line.startswith(closing_indent) else line
                                    for line in key.split("\n"))
                    key = key.removesuffix("\n")
                literals.append(Literal(start, end, key, argument_count > 0, tuple(arguments)))
                return end
            if source.startswith(escape, index):
                index += len(escape)
                if source.startswith("(", index):
                    parts.append("{" + str(argument_count) + "}")
                    argument_count += 1
                    argument_start = index + 1
                    index = code(argument_start, interpolation=True)
                    arguments.append(source[argument_start:index - 1])
                    continue
                if index >= length:
                    break
                character = source[index]
                escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
                if character in escapes:
                    parts.append(escapes[character])
                    index += 1
                elif source.startswith("u{", index):
                    end = source.find("}", index + 2)
                    if end < 0:
                        raise ValueError("unterminated Swift Unicode escape")
                    parts.append(chr(int(source[index + 2:end], 16)))
                    index = end + 1
                elif character == "\n":
                    index += 1
                    while index < length and source[index] in " \t":
                        index += 1
                else:
                    raise ValueError(f"unsupported Swift escape at offset {index}")
            else:
                parts.append(source[index])
                index += 1
        raise ValueError("unterminated Swift string")

    def code(index, interpolation=False):
        depth = 1
        while index < length:
            if source.startswith(("//", "/*"), index):
                index = comment(index)
                continue
            opening = re.match(r'(#{0,})("""|")', source[index:]) if source[index] in '#"' else None
            if opening:
                index = string(index, opening[1], opening[2])
            elif interpolation and source[index] == "(":
                depth += 1
                index += 1
            elif interpolation and source[index] == ")":
                depth -= 1
                index += 1
                if depth == 0:
                    return index
            else:
                index += 1
        if interpolation:
            raise ValueError("unterminated Swift interpolation")
        return index

    code(0)
    return sorted(literals, key=lambda item: item.start)


def literal_call(source: str, literal: Literal) -> str | None:
    # Comments between the call and argument are permitted.
    prefix = re.sub(r"/\*[\s\S]*?\*/|//[^\n]*", " ", source[max(0, literal.start - 2048):literal.start])
    match = re.search(r"([A-Za-z_]\w*)\s*\(\s*$", prefix)
    return match[1] if match else None


def read_catalog(source: str) -> tuple[dict[str, str], list[str]]:
    # Localizable.strings uses quoted entries; JSON-compatible escapes are the
    # project's canonical UTF-8 spelling. Reject stray or partially parsed text.
    token = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', re.DOTALL)
    entries = {}
    errors = []
    offset = 0
    while offset < len(source):
        match = token.match(source, offset)
        if not match:
            errors.append(f"invalid .strings syntax at line {source.count(chr(10), 0, offset) + 1}")
            break
        if match[1] is not None:
            try:
                key, value = json.loads(match[1]), json.loads(match[2])
            except ValueError:
                errors.append("invalid .strings escape")
                break
            if key in entries:
                errors.append(f"duplicate localization key: {key}")
            entries[key] = value
        offset = match.end()
    return entries, errors


def placeholders(text: str) -> Counter:
    # Include printf position and type so changing %lld to %@ cannot reach
    # String(format:). Numbered message tokens may be reordered in translation.
    tokens = Counter(re.findall(r"\{\d+\}", text))
    index = 0
    for match in re.finditer(r"%(?:%|(?:(\d+)\$)?(lld|ld|d|@|(?:\.\d+)?f))", text):
        if match[0] == "%%":
            continue
        index += 1
        tokens[f"%{match[1] or index}${match[2]}"] += 1
    return tokens


def source_keys(source: str, relative: str) -> tuple[set[str], list[str]]:
    keys, errors = set(), []
    for literal in swift_literals(source):
        call = literal_call(source, literal)
        line = source.count("\n", 0, literal.start) + 1
        if call in KEY_CALLS:
            if literal.interpolated and call != "LocalizedMessage":
                errors.append(f"{relative}:{line}: interpolate with LocalizedMessage, not a rendered String key")
            keys.add(literal.key)
        elif HAN.search(literal.key) and (relative, literal.key) not in MATCHING_DATA:
            errors.append(f"{relative}:{line}: bare display copy; wrap the literal in LocalizedMessage or a localization accessor")
    return keys, errors


def validate_repository(root: Path) -> list[str]:
    catalog_path = root / "Resources/en.lproj/Localizable.strings"
    if not catalog_path.exists():
        return ["Resources/en.lproj/Localizable.strings: missing English catalog"]
    try:
        catalog, errors = read_catalog(catalog_path.read_text(encoding="utf-8"))
        errors = [f"Resources/en.lproj/Localizable.strings: {error}" for error in errors]
        keys = set()
        for path in sorted((root / "Sources").rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            found, issues = source_keys(path.read_text(encoding="utf-8"), relative)
            keys.update(found)
            errors.extend(issues)
        for key in sorted(keys):
            # Empty strings and punctuation-only keys need no translation.
            if not re.search(r"\w", key):
                continue
            if key not in catalog:
                errors.append(f"Resources/en.lproj/Localizable.strings: missing English key: {key}")
        for key, value in catalog.items():
            if not value.strip():
                errors.append(f"Resources/en.lproj/Localizable.strings: empty translation: {key}")
            if HAN.search(value):
                errors.append(f"Resources/en.lproj/Localizable.strings: untranslated English value: {key}")
            if placeholders(key) != placeholders(value):
                errors.append(f"Resources/en.lproj/Localizable.strings: placeholder mismatch: {key}")
        changelog = root / "CHANGELOG.md"
        if changelog.exists():
            english_history = root / "Resources/en.lproj/CHANGELOG.md"
            if not english_history.exists():
                errors.append("Resources/en.lproj/CHANGELOG.md: missing English release history")
            else:
                english = english_history.read_text(encoding="utf-8")
                versions = lambda text: re.findall(r"^## \[([^\]]+)\]", text, re.MULTILINE)
                if versions(english) != versions(changelog.read_text(encoding="utf-8")):
                    errors.append("Resources/en.lproj/CHANGELOG.md: release versions differ from CHANGELOG.md")
                if HAN.search(english):
                    errors.append("Resources/en.lproj/CHANGELOG.md: untranslated English history")
        return errors
    except (OSError, UnicodeError, ValueError) as error:
        return [f"localization validation failed: {error}"]


if __name__ == "__main__":
    failures = validate_repository(Path(__file__).resolve().parents[1])
    for failure in failures:
        print(f"ERROR: {failure}", file=sys.stderr)
    if not failures:
        print("PASS: localization source, English catalog, placeholders and release history")
    sys.exit(bool(failures))
