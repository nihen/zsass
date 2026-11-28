#!/usr/bin/env python3
"""Probe the official `sass` CLI for the module function each global
built-in function's `global-builtin` deprecation recommends.

    scripts/probe_global_builtins.py SASS WORKDIR < signatures > table

The input is the output of `probe_builtin_signatures.py`. Each global
function is called with as many arguments as it requires (a color for
the color functions that are also CSS filter functions); each output line
is `name replacement`, for the functions that warn. A function that is
also a CSS calculation is called again with an argument that is none.
"""
import re
import subprocess
import sys

sass, work = sys.argv[1], sys.argv[2]
color_first = {"grayscale", "invert", "saturate", "opacity", "alpha"}

for raw in sys.stdin:
    parts = raw.split()
    if len(parts) < 3 or parts[0] != "-":
        continue
    name, required = parts[1], parts[3:]
    args = ["1"] * len(required)
    if name in color_first:
        # saturate() with one argument is the CSS filter function.
        args = ["red"] + (["10%"] if name == "saturate" else [])
    path = f"{work}/global.scss"

    def probe(call_args):
        with open(path, "w") as f:
            f.write(f"a {{ b: {name}({', '.join(call_args)}); }}\n")
        err = subprocess.run([sass, "--no-source-map", path], capture_output=True, text=True).stderr
        return re.search(r"DEPRECATION WARNING \[global-builtin\]:[^\n]*\nUse (\S+) instead\.", err)

    m = probe(args)
    if not m:
        # min(), max(), round(), and abs() are calculations, which do not
        # warn, unless an argument is no calculation, as `1 % 1` is not.
        m = probe(["1 % 1"] + args[1:])
    if m:
        print(name, m.group(1), flush=True)
