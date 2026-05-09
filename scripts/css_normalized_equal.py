#!/usr/bin/env python3
"""Exit 0 when two CSS files are equal after compat-disposable normalization."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: css_normalized_equal.py EXPECTED ACTUAL", file=sys.stderr)
        return 2

    script_dir = Path(__file__).resolve().parent
    compat_path = script_dir / "compat_disposable.py"
    spec = importlib.util.spec_from_file_location("compat_disposable", compat_path)
    if spec is None or spec.loader is None:
        print(f"failed to load {compat_path}", file=sys.stderr)
        return 2
    compat = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compat)

    expected = Path(sys.argv[1]).read_text(encoding="utf-8", errors="surrogateescape")
    actual = Path(sys.argv[2]).read_text(encoding="utf-8", errors="surrogateescape")
    return 0 if compat.normalize_css(expected) == compat.normalize_css(actual) else 1


if __name__ == "__main__":
    raise SystemExit(main())
