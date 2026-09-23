#!/usr/bin/env python3
"""Validate a Conventional Commit without printing its potentially private text."""

from pathlib import Path
import re
import sys

HEADER = re.compile(
    r"(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
    r"(?:\([^()\s]+\))?!?: [^\s].*"
)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check-commit-message.py COMMIT_MESSAGE_FILE", file=sys.stderr)
        return 2
    try:
        lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        print(f"ERROR: cannot read commit message ({type(error).__name__})", file=sys.stderr)
        return 1
    lines = [line for line in lines if not line.startswith("#")]
    while lines and not lines[0].strip():
        lines.pop(0)
    if not lines or not HEADER.fullmatch(lines[0]) or lines[0] != lines[0].rstrip():
        print("ERROR: use type(scope): description, e.g. fix(menu): preserve overflow recovery", file=sys.stderr)
        print("Types: feat fix docs style refactor perf test build ci chore revert; scope and ! are optional.", file=sys.stderr)
        return 1
    if len(lines[0]) > 100:
        print("ERROR: commit subject must be at most 100 characters.", file=sys.stderr)
        return 1
    if len(lines) > 1 and lines[1].strip():
        print("ERROR: separate the subject and body with a blank line.", file=sys.stderr)
        return 1
    print("PASS: Conventional Commit message")
    return 0


if __name__ == "__main__":
    sys.exit(main())
