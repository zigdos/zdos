#!/usr/bin/env python3
"""Generate a candidate exports.def from a port's public C header."""

import argparse
from pathlib import Path
import re
import sys


IDENTIFIER = re.compile(r"\b([A-Za-z_]\w*)\s*\(")


def declarations(header: str) -> list[str]:
    # Comments and directives are no declarations; continued directives go
    # as a unit:
    source = re.sub(r"/\*.*?\*/|//[^\n]*", " ", header, flags=re.DOTALL)
    source = re.sub(r"(?m)^[ \t]*#(?:\\\n|[^\n])*(?:\n|$)", " ", source)
    source = re.sub(r'\bextern\s+"C"\s*\{', " ", source)

    result: list[str] = []
    statement: list[str] = []
    depth = 0
    for char in source:
        if char == "{":
            if depth == 0:
                statement.clear()
            depth += 1
            continue
        elif char == "}":
            depth = max(0, depth - 1)
            if depth == 0:
                statement.clear()
            continue
        if char == ";" and depth == 0:
            result.append("".join(statement))
            statement.clear()
        else:
            statement.append(char)
    return result


def exported_functions(header: str) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for declaration in declarations(header):
        declaration = declaration.strip()
        if not declaration or re.match(r"^(typedef|struct|union|enum)\b", declaration):
            continue
        if re.search(r"\(\s*\*\s*[A-Za-z_]\w*\s*\)\s*\(", declaration):
            continue
        match = IDENTIFIER.search(declaration)
        if not match:
            continue
        name = match.group(1)
        if name not in seen:
            names.append(name)
            seen.add(name)
    return names


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate candidate X(function) entries from a public C header."
    )
    parser.add_argument("header", help="path to a C header")
    args = parser.parse_args()

    try:
        header_path = Path(args.header)
        if not header_path.is_file():
            raise FileNotFoundError(f"header not found: {header_path}")
        output_path = Path.cwd() / "exports.def"
        if output_path.exists():
            raise FileExistsError(
                f"{output_path} already exists; remove it explicitly before regenerating"
            )
        names = exported_functions(header_path.read_text(encoding="utf-8"))
        if not names:
            raise ValueError(f"no function declarations found in {header_path}")

        contents = (
            f"/* Candidate exports from {header_path.name}; review before use.\n"
            " * Keep this order stable once programs link against the library. */\n"
            + "".join(f"X({name})\n" for name in names)
        )
        output_path.write_text(contents, encoding="utf-8")
        print(f"Wrote {len(names)} candidate functions to {output_path}")
        print("Review the list against the built library and remove non-exports.")
        return 0
    except (FileNotFoundError, FileExistsError, OSError, ValueError) as error:
        print(f"defgen.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
