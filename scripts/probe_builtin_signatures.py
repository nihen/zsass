#!/usr/bin/env python3
"""Probe the official `sass` CLI for the arguments each built-in function
requires and the most it takes, from its error messages alone.

    scripts/probe_builtin_signatures.py SASS WORKDIR < names > table

Each input line is `module name` (`-` for a global function). Each output
line is `module name max required...`, with `max` -1 for no limit.
"""
import re
import subprocess
import sys

sass, work = sys.argv[1], sys.argv[2]


def run(module, name, argc):
    args = ", ".join(["1"] * argc)
    if module == "-":
        src = f"a {{ b: {name}({args}); }}\n"
    else:
        src = f'@use "sass:{module}";\na {{ b: {module}.{name}({args}); }}\n'
    path = f"{work}/probe.scss"
    with open(path, "w") as f:
        f.write(src)
    out = subprocess.run([sass, "--no-source-map", path], capture_output=True, text=True).stderr
    for line in out.splitlines():
        if line.startswith("Error: "):
            return line[len("Error: "):]
    return ""


for raw in sys.stdin:
    parts = raw.split()
    if len(parts) < 2:
        continue
    module, name = parts[0], parts[1]
    required = []
    for argc in range(0, 8):
        m = re.fullmatch(r"Missing argument \$([\w-]+)\.", run(module, name, argc))
        if not m:
            break
        required.append(m.group(1))
    m = re.fullmatch(r"Only (\d+) arguments? allowed, but 12 (?:was|were) passed\.", run(module, name, 12))
    most = int(m.group(1)) if m else -1
    print(module, name, most, *required, flush=True)
