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
TEXT_SUFFIXES = {".swift", ".py", ".sh", ".md", ".toml", ".json", ".yaml", ".yml", ".txt"}
TEXT_NAMES = {".editorconfig", ".gitignore", ".gitattributes", "LICENSE"}
# High-confidence credential formats only. Report paths and rule names, never values.
SECRET_PATTERNS = (
    ("private key", re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b")),
    ("OpenAI key", re.compile(rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b")),
    ("Slack token", re.compile(rb"\bxox[baprs]-[0-9A-Za-z-]{24,}\b")),
    ("AWS access key", re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
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
    for label in ("size and secret signatures", "text whitespace", "Python syntax", "shell syntax", "plist syntax", "TOML syntax", "JSON syntax"):
        print(f"{'CHECKED' if totals[label] else 'SKIP'}: {label}: {totals[label]} file(s)")
    for label in ("excluded build/local/dependency paths", "deleted files", "binary text-check skips"):
        if totals[label]:
            print(f"SKIP: {label}: {totals[label]} file(s)")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("PASS: selected source checks (signature checks are not a complete security audit)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
