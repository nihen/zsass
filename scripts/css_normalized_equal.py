#!/usr/bin/env python3
"""Report whether two CSS files are equal before and after diagnostic normalization."""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--allow-normalized-pass",
        action="store_true",
        help="Deprecated no-op. Raw CSS differences always exit nonzero; normalization is diagnostic-only.",
    )
    parser.add_argument("expected")
    parser.add_argument("actual")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    compat_path = script_dir / "compat_disposable.py"
    spec = importlib.util.spec_from_file_location("compat_disposable", compat_path)
    if spec is None or spec.loader is None:
        print(f"failed to load {compat_path}", file=sys.stderr)
        return 2
    compat = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compat)

    expected = Path(args.expected).read_text(encoding="utf-8", errors="surrogateescape")
    actual = Path(args.actual).read_text(encoding="utf-8", errors="surrogateescape")
    if expected == actual:
        return 0
    if compat.normalize_css(expected) != compat.normalize_css(actual):
        return 1
    print("normalized_equal: raw CSS differs", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
