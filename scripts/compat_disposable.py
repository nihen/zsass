#!/usr/bin/env python3
"""Disposable real-world Sass compatibility runner.

This runner checks one git repository at a time against Dart Sass CLI and
zsass, writes durable pass/failure records into ../zsass-realworld-fixtures, and
removes successful source checkouts. It intentionally does not add anything to
zig build realworld.
"""
from __future__ import annotations

import argparse
import datetime as dt
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from typing import Any
import urllib.parse
import urllib.request
import zipfile

NORMALIZER_VERSION = 26
IGNORED_DIFF_KINDS = ["blank", "comment", "comment-license", "quote", "selector-comma-newline", "selector-list-order", "selector-where-list", "selector-pseudo-order", "selector-compound-class-order", "selector-impossible-body-descendant", "selector-impossible-form-control-descendant", "selector-redundant-child-combinator", "selector-redundant-descendant-compound", "selector-redundant-compound-class", "selector-redundant-pseudo-class", "selector-disjoint-pseudo-block-order", "media-and-order", "media-nested-and", "media-disjoint-decl-order", "empty-rule", "adjacent-same-selector-block", "calc-arithmetic", "calc-min-arg-wrapper", "opaque-color", "transparent-color", "line-indent"]


def split_top_level_commas(value: str) -> list[str] | None:
    parts: list[str] = []
    start = 0
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(value):
        ch = value[i]
        if in_string:
            if ch == "\\" and i + 1 < len(value):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
        elif ch == "(":
            paren += 1
        elif ch == ")" and paren:
            paren -= 1
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "," and paren == 0 and bracket == 0:
            parts.append(value[start:i].strip())
            start = i + 1
        i += 1
    if not parts:
        return None
    parts.append(value[start:].strip())
    if any(not p for p in parts):
        return None
    return parts


def find_matching_paren(value: str, open_idx: int) -> int | None:
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = open_idx
    while i < len(value):
        ch = value[i]
        if in_string:
            if ch == "\\" and i + 1 < len(value):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "(" and bracket == 0:
            paren += 1
        elif ch == ")" and bracket == 0:
            paren -= 1
            if paren == 0:
                return i
        i += 1
    return None


def normalize_checked_where_order(selector: str) -> str:
    out: list[str] = []
    i = 0
    needle = ":where("
    while i < len(selector):
        if selector.startswith(needle, i):
            open_idx = i + len(":where")
            close_idx = find_matching_paren(selector, open_idx)
            if close_idx is not None and selector.startswith(":checked", close_idx + 1):
                out.append(":checked")
                out.append(selector[i : close_idx + 1])
                i = close_idx + 1 + len(":checked")
                continue
        out.append(selector[i])
        i += 1
    return "".join(out)


def expand_standalone_where_selector(selector: str) -> list[str]:
    selector = normalize_checked_where_order(selector)
    expanded = expand_where_selector(selector)
    if expanded is not None:
        return expanded
    return [selector]


def selector_has_impossible_body_descendant(selector: str) -> bool:
    """Return true for selectors that require a body descendant of body.

    HTML documents have a single `body` element, so a top-level selector such as
    `body[data-theme=dark] body[data-theme=light] .x` is unsatisfiable. Sass
    @extend can generate or prune these impossible branches in different orders;
    they do not affect CSS behavior, so disposable compat compares only the
    satisfiable selector branches.
    """
    body_count = 0
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == "(" and bracket == 0:
            paren += 1
            i += 1
            continue
        if ch == ")" and bracket == 0 and paren:
            paren -= 1
            i += 1
            continue
        if bracket == 0 and paren == 0 and selector.startswith("body", i):
            prev = selector[i - 1] if i else ""
            nxt = selector[i + 4] if i + 4 < len(selector) else ""
            prev_allows_type = i == 0 or prev in " \t\r\n>+~("
            next_ends_ident = i + 4 == len(selector) or nxt in " \t\r\n>+~.#[:"
            if prev_allows_type and next_ends_ident:
                body_count += 1
                if body_count > 1:
                    return True
                i += 4
                continue
        i += 1
    return False


def selector_has_impossible_form_control_descendant(selector: str) -> bool:
    """Return true for branches requiring descendants inside void/text controls."""
    controls = ("input", "select", "textarea")
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == "(" and bracket == 0:
            paren += 1
            i += 1
            continue
        if ch == ")" and bracket == 0 and paren:
            paren -= 1
            i += 1
            continue
        if bracket == 0 and paren == 0:
            for name in controls:
                if not selector.startswith(name, i):
                    continue
                prev = selector[i - 1] if i else ""
                nxt = selector[i + len(name)] if i + len(name) < len(selector) else ""
                prev_allows_type = i == 0 or prev in " \t\r\n>+~("
                next_ends_ident = i + len(name) == len(selector) or nxt in " \t\r\n>+~.#[:"
                if not (prev_allows_type and next_ends_ident):
                    continue
                j = i + len(name)
                while j < len(selector):
                    cj = selector[j]
                    if cj in ".#:[(":
                        j += 1
                        continue
                    break
                while j < len(selector) and selector[j] not in " \t\r\n>+~":
                    j += 1
                while j < len(selector) and selector[j] in " \t\r\n":
                    j += 1
                if j < len(selector) and selector[j] == ">":
                    return True
                if j < len(selector) and selector[j] not in "+~":
                    return True
                i += len(name)
                break
        i += 1
    return False


def selector_has_impossible_self_not_type(selector: str) -> bool:
    """Return true for impossible compounds like `button:not(button)`.

    Some @extend paths differ only by branches that require an element to be a
    type selector and not that same type at once. Those branches match nothing.
    """
    compact = re.sub(r"[ \t\r\n]+", " ", selector)
    for m in re.finditer(r"(^|[ >+~])([A-Za-z_][A-Za-z0-9_-]*)(?=[.#:\[]|:not\()", compact):
        typ = m.group(2)
        start = m.end(2)
        end = len(compact)
        for pos in range(start, len(compact)):
            if compact[pos] in " >+~":
                end = pos
                break
        compound = compact[start:end]
        if re.search(r":not\(\s*" + re.escape(typ) + r"\s*\)", compound):
            return True
    return False


def last_top_level_semicolon(value: str) -> int | None:
    paren = 0
    bracket = 0
    in_string: str | None = None
    last: int | None = None
    i = 0
    while i < len(value):
        ch = value[i]
        if in_string:
            if ch == "\\" and i + 1 < len(value):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "(" and bracket == 0:
            paren += 1
        elif ch == ")" and bracket == 0 and paren:
            paren -= 1
        elif ch == ";" and paren == 0 and bracket == 0:
            last = i
        i += 1
    return last


def expand_where_selector(selector: str) -> list[str] | None:
    i = 0
    paren = 0
    bracket = 0
    in_string: str | None = None
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if bracket == 0 and selector.startswith(":where(", i) and paren == 0:
            close_idx = find_matching_paren(selector, i + len(":where"))
            if close_idx is None:
                return None
            inner = selector[i + len(":where(") : close_idx]
            parts = split_top_level_commas(inner)
            if not parts:
                i = close_idx + 1
                continue
            prefix = selector[:i]
            suffix = selector[close_idx + 1 :]
            out: list[str] = []
            for part in parts:
                candidate = f"{prefix}:where({part}){suffix}"
                nested = expand_where_selector(candidate)
                if nested is None:
                    out.append(candidate)
                else:
                    out.extend(nested)
            return out
        if ch == "(" and bracket == 0:
            paren += 1
        elif ch == ")" and bracket == 0 and paren:
            paren -= 1
        i += 1
    return None


def expand_standalone_where_selector_old(selector: str) -> list[str]:
    selector = normalize_checked_where_order(selector)
    if not selector.startswith(":where("):
        return [selector]
    close_idx = find_matching_paren(selector, len(":where"))
    if close_idx is None:
        return [selector]
    inner = selector[len(":where(") : close_idx]
    parts = split_top_level_commas(inner)
    if not parts:
        return [selector]
    suffix = selector[close_idx + 1 :]
    return [f":where({part}){suffix}" for part in parts]


def normalize_selector_list_order(css: str) -> str:
    """Sort selectors inside a style-rule selector list.

    Selector order within a single CSS rule is semantically irrelevant. This
    intentionally skips at-rule preludes (`@media ... {`) and only canonicalizes
    comma-separated style selectors immediately before `{`.
    """
    out: list[str] = []
    segment_start = 0
    i = 0
    in_string: str | None = None
    while i < len(css):
        ch = css[i]
        if in_string:
            if ch == "\\" and i + 1 < len(css):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch == '"':
            in_string = ch
            i += 1
            continue
        if ch == "{":
            segment = css[segment_start:i]
            selector_prefix = ""
            selector_segment = segment
            last_semicolon = last_top_level_semicolon(segment)
            if last_semicolon is not None:
                selector_prefix = segment[: last_semicolon + 1]
                selector_segment = segment[last_semicolon + 1 :]
            stripped = selector_segment.strip()
            if stripped and not stripped.startswith("@"):
                prefix_len = len(selector_segment) - len(selector_segment.lstrip())
                suffix_len = len(selector_segment) - len(selector_segment.rstrip())
                parts = split_top_level_commas(stripped)
                if parts:
                    expanded: list[str] = []
                    for part in parts:
                        expanded.extend(canonical_selector_for_redundancy(normalize_compound_class_order(p)) for p in expand_standalone_where_selector(part))
                    filtered = [
                        part
                        for part in expanded
                        if not selector_has_impossible_body_descendant(part)
                        and not selector_has_impossible_form_control_descendant(part)
                        and not selector_has_impossible_self_not_type(part)
                    ]
                    if filtered:
                        expanded = filtered
                    expanded = remove_redundant_selector_branches(expanded)
                    selector_segment = selector_segment[:prefix_len] + ", ".join(sorted(expanded)) + (selector_segment[len(selector_segment) - suffix_len :] if suffix_len else "")
                else:
                    expanded = [canonical_selector_for_redundancy(normalize_compound_class_order(p)) for p in expand_standalone_where_selector(stripped)]
                    expanded = [
                        part
                        for part in expanded
                        if not selector_has_impossible_body_descendant(part)
                        and not selector_has_impossible_form_control_descendant(part)
                        and not selector_has_impossible_self_not_type(part)
                    ]
                    expanded = remove_redundant_selector_branches(expanded)
                    if expanded:
                        selector_segment = selector_segment[:prefix_len] + ", ".join(sorted(expanded)) + (selector_segment[len(selector_segment) - suffix_len :] if suffix_len else "")
            segment = selector_prefix + selector_segment
            out.append(segment)
            out.append("{")
            segment_start = i + 1
        elif ch == "}":
            out.append(css[segment_start : i + 1])
            segment_start = i + 1
        i += 1
    out.append(css[segment_start:])
    return "".join(out)


def selector_child_to_descendant(selector: str) -> str | None:
    """Return selector with top-level child combinators relaxed to descendants.

    A selector branch `A > B` is a strict subset of `A B`. If a selector list
    contains both branches with the same declaration block, the child branch is
    redundant and may be dropped for CSS-equivalent comparison. Attribute
    selectors and functional pseudo arguments are skipped so `>` in values is
    not treated as a combinator.
    """
    out: list[str] = []
    changed = False
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(selector):
                out.append(selector[i + 1])
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            out.append(ch)
        elif ch == "[":
            bracket += 1
            out.append(ch)
        elif ch == "]" and bracket:
            bracket -= 1
            out.append(ch)
        elif ch == "(" and bracket == 0:
            paren += 1
            out.append(ch)
        elif ch == ")" and bracket == 0 and paren:
            paren -= 1
            out.append(ch)
        elif ch == ">" and paren == 0 and bracket == 0:
            changed = True
            while out and out[-1].isspace():
                out.pop()
            out.append(" ")
            i += 1
            while i < len(selector) and selector[i].isspace():
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    if not changed:
        return None
    return re.sub(r"[ \t\r\n]+", " ", "".join(out)).strip()


def remove_redundant_child_selector_branches(selectors: list[str]) -> list[str]:
    selector_set = {re.sub(r"[ \t\r\n]+", " ", s).strip() for s in selectors}
    out: list[str] = []
    for selector in selectors:
        descendant = selector_child_to_descendant(selector)
        if descendant is not None and descendant in selector_set:
            continue
        out.append(selector)
    return out


def removable_descendant_compound_ranges(selector: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == "(" and bracket == 0:
            paren += 1
            i += 1
            continue
        if ch == ")" and bracket == 0 and paren:
            paren -= 1
            i += 1
            continue
        if paren == 0 and bracket == 0 and ch in " \t\r\n":
            j = i + 1
            while j < len(selector) and selector[j].isspace():
                j += 1
            if j >= len(selector) or selector[j] in ">+~,":
                i += 1
                continue
            k = j
            local_paren = 0
            local_bracket = 0
            local_string: str | None = None
            while k < len(selector):
                ck = selector[k]
                if local_string:
                    if ck == "\\" and k + 1 < len(selector):
                        k += 2
                        continue
                    if ck == local_string:
                        local_string = None
                    k += 1
                    continue
                if ck in {'"', "'"}:
                    local_string = ck
                    k += 1
                    continue
                if ck == "[":
                    local_bracket += 1
                elif ck == "]" and local_bracket:
                    local_bracket -= 1
                elif ck == "(" and local_bracket == 0:
                    local_paren += 1
                elif ck == ")" and local_bracket == 0 and local_paren:
                    local_paren -= 1
                elif local_paren == 0 and local_bracket == 0 and ck in " \t\r\n>+~":
                    break
                k += 1
            next_nonspace = k
            while next_nonspace < len(selector) and selector[next_nonspace].isspace():
                next_nonspace += 1
            if (
                k > j
                and k < len(selector)
                and selector[k] in " \t\r\n"
                and next_nonspace < len(selector)
                and selector[next_nonspace] not in ">+~"
            ):
                ranges.append((i, k))
                i = k
                continue
        i += 1
    return ranges


def remove_redundant_descendant_compound_branches(selectors: list[str]) -> list[str]:
    selector_set = {re.sub(r"[ \t\r\n]+", " ", s).strip() for s in selectors}
    out: list[str] = []
    for selector in selectors:
        normalized = re.sub(r"[ \t\r\n]+", " ", selector).strip()
        redundant = False
        for start, end in removable_descendant_compound_ranges(normalized):
            candidate = re.sub(r"[ \t\r\n]+", " ", (normalized[:start] + " " + normalized[end:]).strip()).strip()
            if candidate in selector_set:
                redundant = True
                break
        if not redundant:
            out.append(selector)
    return out


def removable_class_ranges(selector: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == "(" and bracket == 0:
            paren += 1
            i += 1
            continue
        if ch == ")" and bracket == 0 and paren:
            paren -= 1
            i += 1
            continue
        if ch == "." and paren == 0 and bracket == 0 and i + 1 < len(selector) and re.match(r"[A-Za-z_-]", selector[i + 1]):
            j = i + 2
            while j < len(selector) and re.match(r"[A-Za-z0-9_-]", selector[j]):
                j += 1
            ranges.append((i, j))
            i = j
            continue
        i += 1
    return ranges


def removable_type_ranges(selector: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == "(" and bracket == 0:
            paren += 1
            i += 1
            continue
        if ch == ")" and bracket == 0 and paren:
            paren -= 1
            i += 1
            continue
        at_compound_start = i == 0 or selector[i - 1] in " >+~"
        if paren == 0 and bracket == 0 and at_compound_start and re.match(r"[A-Za-z_]", ch):
            j = i + 1
            while j < len(selector) and re.match(r"[A-Za-z0-9_-]", selector[j]):
                j += 1
            if j < len(selector) and selector[j] in ".#:[ ":
                ranges.append((i, j))
            i = j
            continue
        i += 1
    return ranges


def remove_redundant_compound_class_branches(selectors: list[str]) -> list[str]:
    selector_set = {re.sub(r"[ \t\r\n]+", " ", s).strip() for s in selectors}
    out: list[str] = []
    for selector in selectors:
        normalized = re.sub(r"[ \t\r\n]+", " ", selector).strip()
        redundant = False
        for start, end in removable_class_ranges(normalized):
            candidate = (normalized[:start] + normalized[end:]).strip()
            if candidate in selector_set:
                redundant = True
                break
        if not redundant:
            out.append(selector)
    return out


def pseudo_class_ranges(selector: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(selector):
        ch = selector[i]
        if in_string:
            if ch == "\\" and i + 1 < len(selector):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if ch == ":" and bracket == 0 and not (i + 1 < len(selector) and selector[i + 1] == ":"):
            j = i + 1
            while j < len(selector) and re.match(r"[A-Za-z0-9_-]", selector[j]):
                j += 1
            if j < len(selector) and selector[j] == "(":
                close = find_matching_paren(selector, j)
                if close is None:
                    i += 1
                    continue
                j = close + 1
            if j > i + 1:
                ranges.append((i, j))
                i = j
                continue
        i += 1
    return ranges


def remove_redundant_pseudo_class_branches(selectors: list[str]) -> list[str]:
    selector_set = {re.sub(r"[ \t\r\n]+", " ", s).strip() for s in selectors}
    out: list[str] = []
    for selector in selectors:
        normalized = re.sub(r"[ \t\r\n]+", " ", selector).strip()
        redundant = False
        for start, end in pseudo_class_ranges(normalized):
            candidate = (normalized[:start] + normalized[end:]).strip()
            if candidate in selector_set:
                redundant = True
                break
        if not redundant:
            out.append(selector)
    return out


def selector_redundancy_candidates(selector: str, limit: int = 512) -> set[str]:
    """Generate broader selectors produced by safe, CSS-superset rewrites."""
    seen = {re.sub(r"[ \t\r\n]+", " ", selector).strip()}
    queue = list(seen)
    out: set[str] = set()
    while queue and len(seen) < limit:
        current = queue.pop(0)
        variants: list[str] = []
        child_relaxed = selector_child_to_descendant(current)
        if child_relaxed is not None:
            variants.append(child_relaxed)
        for start, end in removable_descendant_compound_ranges(current):
            variants.append(re.sub(r"[ \t\r\n]+", " ", (current[:start] + " " + current[end:]).strip()).strip())
        for start, end in removable_class_ranges(current):
            variants.append(re.sub(r"[ \t\r\n]+", " ", (current[:start] + current[end:]).strip()).strip())
        for start, end in removable_type_ranges(current):
            variants.append(re.sub(r"[ \t\r\n]+", " ", (current[:start] + current[end:]).strip()).strip())
        for start, end in pseudo_class_ranges(current):
            variants.append(re.sub(r"[ \t\r\n]+", " ", (current[:start] + current[end:]).strip()).strip())
        for variant in variants:
            if not variant or variant == current or variant in seen:
                continue
            seen.add(variant)
            out.add(variant)
            queue.append(variant)
            if len(seen) >= limit:
                break
    return out


def remove_redundant_selector_branches(selectors: list[str]) -> list[str]:
    selector_set = {canonical_selector_for_redundancy(s) for s in selectors}
    out: list[str] = []
    for selector in selectors:
        normalized = canonical_selector_for_redundancy(selector)
        candidates = {canonical_selector_for_redundancy(s) for s in selector_redundancy_candidates(normalized)}
        if candidates & selector_set:
            continue
        out.append(selector)
    return out


def canonical_selector_for_redundancy(selector: str) -> str:
    normalized = re.sub(r"[ \t\r\n]+", " ", selector).strip()
    normalized = normalize_compound_class_order(normalized)
    normalized = re.sub(r"(^|[ >+~])\*(?=[.#:\[])", r"\1", normalized)
    normalized = re.sub(r":not\(([^()]*)\)(\.(?:valid|invalid))", r"\2:not(\1)", normalized)
    normalized = re.sub(r":not\(([^()]*)\)(:not\(\1\))+", r":not(\1)", normalized)
    normalized = normalize_pseudo_order_in_selector(normalized)
    return normalize_not_pseudo_set_order(normalized)


def normalize_not_pseudo_set_order(selector: str) -> str:
    """Sort and dedupe same-compound `:not(...)` pseudo-classes.

    Multiple `:not()` pseudo-classes in the same compound are an intersection;
    their order and duplicate occurrences do not change which elements match.
    Disposable real-world comparison ignores these selector formatting/branching
    differences after @extend.
    """
    parts: list[str] = []
    buf: list[str] = []
    paren = 0
    bracket = 0
    in_string: str | None = None
    for ch in selector:
        if in_string:
            buf.append(ch)
            if ch == "\\" and len(buf) >= 1:
                continue
            if ch == in_string:
                in_string = None
            continue
        if ch in {'"', "'"}:
            in_string = ch
            buf.append(ch)
            continue
        if ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "(" and bracket == 0:
            paren += 1
        elif ch == ")" and bracket == 0 and paren:
            paren -= 1
        if paren == 0 and bracket == 0 and ch in " >+~":
            parts.append(normalize_not_pseudo_set_in_compound("".join(buf)))
            parts.append(ch)
            buf = []
        else:
            buf.append(ch)
    parts.append(normalize_not_pseudo_set_in_compound("".join(buf)))
    return "".join(parts)


def normalize_not_pseudo_set_in_compound(compound: str) -> str:
    nots: list[str] = []
    spans: list[tuple[int, int]] = []
    for start, end in pseudo_class_ranges(compound):
        pseudo = compound[start:end]
        if pseudo.startswith(":not("):
            nots.append(pseudo)
            spans.append((start, end))
    if len(nots) < 2:
        return compound
    out: list[str] = []
    last = 0
    for start, end in spans:
        out.append(compound[last:start])
        last = end
    out.append(compound[last:])
    return "".join(out) + "".join(sorted(set(nots)))


def normalize_pseudo_order_in_selector(selector: str) -> str:
    parts: list[str] = []
    buf: list[str] = []
    paren = 0
    bracket = 0
    in_string: str | None = None
    for ch in selector:
        if in_string:
            buf.append(ch)
            if ch == in_string:
                in_string = None
            continue
        if ch in {'"', "'"}:
            in_string = ch
            buf.append(ch)
            continue
        if ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "(" and bracket == 0:
            paren += 1
        elif ch == ")" and bracket == 0 and paren:
            paren -= 1
        if paren == 0 and bracket == 0 and ch in " >+~":
            parts.append(normalize_pseudo_order_in_compound("".join(buf)))
            parts.append(ch)
            buf = []
        else:
            buf.append(ch)
    parts.append(normalize_pseudo_order_in_compound("".join(buf)))
    return "".join(parts)


def normalize_pseudo_order_in_compound(compound: str) -> str:
    pseudos: list[str] = []
    spans: list[tuple[int, int]] = []
    for start, end in pseudo_class_ranges(compound):
        pseudos.append(compound[start:end])
        spans.append((start, end))
    if len(pseudos) < 2:
        return compound
    out: list[str] = []
    last = 0
    for start, end in spans:
        out.append(compound[last:start])
        last = end
    out.append(compound[last:])
    return "".join(out) + "".join(sorted(pseudos))


def normalize_compound_class_order(selector: str) -> str:
    """Sort consecutive class simple selectors within a compound selector."""
    out: list[str] = []
    i = 0
    while i < len(selector):
        if selector[i] != "." or i + 1 >= len(selector) or not re.match(r"[A-Za-z_-]", selector[i + 1]):
            out.append(selector[i])
            i += 1
            continue
        classes: list[str] = []
        j = i
        while j < len(selector) and selector[j] == "." and j + 1 < len(selector) and re.match(r"[A-Za-z_-]", selector[j + 1]):
            k = j + 2
            while k < len(selector) and re.match(r"[A-Za-z0-9_-]", selector[k]):
                k += 1
            classes.append(selector[j:k])
            j = k
        if len(classes) > 1:
            out.append("".join(sorted(classes)))
            i = j
        else:
            out.append(classes[0])
            i = j
    return "".join(out)


def normalize_min_calc_args(css: str) -> str:
    """Normalize `min(calc(A), calc(B))` to `min(A, B)` in CSS math."""
    needle = "min("
    out: list[str] = []
    i = 0
    while i < len(css):
        if not css.startswith(needle, i):
            out.append(css[i])
            i += 1
            continue
        open_idx = i + len("min")
        close_idx = find_matching_paren(css, open_idx)
        if close_idx is None:
            out.append(css[i])
            i += 1
            continue
        inner = css[i + len(needle) : close_idx]
        parts = split_top_level_commas(inner)
        if not parts:
            out.append(css[i : close_idx + 1])
            i = close_idx + 1
            continue
        changed = False
        normalized_parts: list[str] = []
        for part in parts:
            stripped = part.strip()
            if stripped.startswith("calc("):
                part_close = find_matching_paren(stripped, len("calc"))
                if part_close == len(stripped) - 1:
                    normalized_parts.append(stripped[len("calc(") : -1].strip())
                    changed = True
                    continue
            normalized_parts.append(stripped)
        out.append("min(" + ", ".join(normalized_parts) + ")" if changed else css[i : close_idx + 1])
        i = close_idx + 1
    return "".join(out)


def _matching_block_end(lines: list[str], start: int) -> int | None:
    depth = 0
    for idx in range(start, len(lines)):
        line = lines[idx]
        if line.endswith("{"):
            depth += 1
        if line == "}":
            depth -= 1
            if depth == 0:
                return idx
        if depth < 0:
            return None
    return None


def normalize_adjacent_same_selector_blocks(lines: list[str]) -> list[str]:
    """Merge adjacent identical style-rule blocks.

    `a { x } a { y }` and `a { x; y }` are equivalent when the two blocks are
    adjacent and have the exact same selector in the same parent context. This
    ignores emission chunking differences without changing cascade order.
    """
    changed = True
    while changed:
        changed = False
        out: list[str] = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if not line.endswith("{") or line.startswith("@"):
                out.append(line)
                i += 1
                continue
            first_end = _matching_block_end(lines, i)
            if first_end is None or first_end + 1 >= len(lines) or lines[first_end + 1] != line:
                out.append(line)
                i += 1
                continue
            second_end = _matching_block_end(lines, first_end + 1)
            if second_end is None:
                out.append(line)
                i += 1
                continue
            out.extend(lines[i:first_end])
            out.extend(lines[first_end + 2 : second_end])
            out.append("}")
            i = second_end + 1
            changed = True
        lines = out
    return lines


def selector_pseudo_subject(selector: str) -> tuple[str, bool] | None:
    """Return (subject, has_pseudo_element) for simple pseudo-tail selectors."""
    if "," in selector or " " in selector or ">" in selector or "+" in selector or "~" in selector:
        return None
    idx = selector.find(":")
    if idx < 0:
        return None
    subject = selector[:idx]
    if not subject:
        return None
    has_pseudo_element = selector.startswith("::", idx)
    return subject, has_pseudo_element


def disjoint_pseudo_same_subject(a: str, b: str) -> bool:
    pa = selector_pseudo_subject(a[:-1].strip() if a.endswith("{") else a.strip())
    pb = selector_pseudo_subject(b[:-1].strip() if b.endswith("{") else b.strip())
    if pa is None or pb is None:
        return False
    return pa[0] == pb[0] and pa[1] != pb[1]


def normalize_adjacent_disjoint_pseudo_block_order(lines: list[str]) -> list[str]:
    """Canonicalize adjacent same-subject pseudo-element vs pseudo-class blocks.

    `.x::part { ... }` and `.x:focus { ... }` target different CSS boxes, so
    swapping adjacent blocks cannot change cascade. This removes source-order
    noise from mixin chunking while avoiding broad rule sorting.
    """
    out = lines[:]
    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(out):
            if not out[i].endswith("{") or out[i].startswith("@"):
                i += 1
                continue
            first_end = _matching_block_end(out, i)
            if first_end is None or first_end + 1 >= len(out):
                i += 1
                continue
            j = first_end + 1
            if not out[j].endswith("{") or out[j].startswith("@"):
                i += 1
                continue
            second_end = _matching_block_end(out, j)
            if second_end is None:
                i += 1
                continue
            if disjoint_pseudo_same_subject(out[i], out[j]) and out[j] < out[i]:
                first = out[i : first_end + 1]
                second = out[j : second_end + 1]
                out[i : second_end + 1] = second + first
                changed = True
                i = 0
                continue
            i += 1
    return out


def block_immediate_style_blocks(lines: list[str], start: int, end: int) -> list[tuple[int, int]]:
    blocks: list[tuple[int, int]] = []
    i = start + 1
    while i < end:
        if lines[i].endswith("{") and not lines[i].startswith("@"):
            b_end = _matching_block_end(lines, i)
            if b_end is None or b_end > end:
                break
            blocks.append((i, b_end))
            i = b_end + 1
            continue
        i += 1
    return blocks


def style_block_props(lines: list[str], start: int, end: int) -> tuple[str, set[str]] | None:
    if start >= len(lines) or end >= len(lines) or not lines[start].endswith("{"):
        return None
    selector = lines[start][:-1].strip()
    props: set[str] = set()
    for line in lines[start + 1 : end]:
        if ":" not in line or line.endswith("{") or line == "}":
            continue
        props.add(line.split(":", 1)[0].strip())
    return selector, props


def prelude_is_refinement(parent_line: str, child_line: str) -> bool:
    if not (parent_line.startswith("@media ") and child_line.startswith("@media ")):
        return False
    if not parent_line.endswith("{") or not child_line.endswith("{"):
        return False
    parent = parent_line[len("@media ") : -1].strip()
    child = child_line[len("@media ") : -1].strip()
    return child.startswith(parent + " and ")


def split_top_level_media_and(prelude: str) -> list[str]:
    parts: list[str] = []
    start = 0
    paren = 0
    bracket = 0
    in_string: str | None = None
    i = 0
    while i < len(prelude):
        ch = prelude[i]
        if in_string:
            if ch == "\\" and i + 1 < len(prelude):
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            i += 1
            continue
        if ch == "(":
            paren += 1
            i += 1
            continue
        if ch == ")" and paren:
            paren -= 1
            i += 1
            continue
        if ch == "[":
            bracket += 1
            i += 1
            continue
        if ch == "]" and bracket:
            bracket -= 1
            i += 1
            continue
        if paren == 0 and bracket == 0 and prelude[i : i + 5].lower() == " and ":
            part = prelude[start:i].strip()
            if part:
                parts.append(part)
            i += 5
            start = i
            continue
        i += 1
    tail = prelude[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def normalize_media_clause(clause: str) -> str:
    clause = re.sub(r"\s+", " ", clause.strip())
    if clause.lower().startswith("not "):
        return f"(not {clause[4:].strip()})"
    return clause


def normalize_media_prelude(prelude: str) -> str:
    if "," in prelude or re.search(r"(?i)(^|[\s(])or([\s(]|$)", prelude):
        return re.sub(r"\s+", " ", prelude.strip())
    clauses = [normalize_media_clause(p) for p in split_top_level_media_and(prelude)]
    if not clauses:
        return re.sub(r"\s+", " ", prelude.strip())
    return " and ".join(sorted(set(clauses)))


def normalize_media_line(line: str) -> str:
    if not (line.startswith("@media ") and line.endswith("{")):
        return line
    return "@media " + normalize_media_prelude(line[len("@media ") : -1].strip()) + " {"


def matching_block_end(lines: list[str], start: int) -> int | None:
    depth = 0
    for i in range(start, len(lines)):
        if lines[i].endswith("{"):
            depth += 1
        if lines[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def normalize_nested_media_and(lines: list[str]) -> list[str]:
    out = [normalize_media_line(line) for line in lines]
    changed = True
    while changed:
        changed = False
        i = 0
        rebuilt: list[str] = []
        while i < len(out):
            if (
                i + 1 < len(out)
                and out[i].startswith("@media ")
                and out[i].endswith("{")
                and out[i + 1].startswith("@media ")
                and out[i + 1].endswith("{")
            ):
                child_end = matching_block_end(out, i + 1)
                if child_end is not None and child_end + 1 < len(out) and out[child_end + 1] == "}":
                    parent = out[i][len("@media ") : -1].strip()
                    child = out[i + 1][len("@media ") : -1].strip()
                    rebuilt.append("@media " + normalize_media_prelude(parent + " and " + child) + " {")
                    rebuilt.extend(out[i + 2 : child_end + 1])
                    i = child_end + 2
                    changed = True
                    continue
            rebuilt.append(out[i])
            i += 1
        out = rebuilt
        i = 0
        rebuilt = []
        while i < len(out):
            if not (out[i].startswith("@media ") and out[i].endswith("{")):
                rebuilt.append(out[i])
                i += 1
                continue
            outer_end = matching_block_end(out, i)
            if outer_end is None:
                rebuilt.append(out[i])
                i += 1
                continue
            parent = out[i][len("@media ") : -1].strip()
            inner = out[i + 1 : outer_end]
            kept_inner: list[str] = []
            hoisted: list[list[str]] = []
            depth = 0
            j = 0
            while j < len(inner):
                line = inner[j]
                if depth == 0 and line.startswith("@media ") and line.endswith("{"):
                    rel_end = matching_block_end(inner, j)
                    if rel_end is not None:
                        child = line[len("@media ") : -1].strip()
                        hoisted.append([
                            "@media " + normalize_media_prelude(parent + " and " + child) + " {",
                            *inner[j + 1 : rel_end],
                            "}",
                        ])
                        j = rel_end + 1
                        changed = True
                        continue
                kept_inner.append(line)
                if line.endswith("{"):
                    depth += 1
                elif line == "}" and depth:
                    depth -= 1
                j += 1
            rebuilt.append(out[i])
            rebuilt.extend(kept_inner)
            rebuilt.append("}")
            for block in hoisted:
                rebuilt.extend(block)
            i = outer_end + 1
        out = rebuilt
    return out


def normalize_media_disjoint_decl_order(lines: list[str]) -> list[str]:
    """Move safe same-media declarations before an intervening refined @media.

    Sass implementations can split `@media M { .a { @media N {x} y } }` as
    either `M{.a{y}} M and N{.a{x}}` or `M and N{.a{x}} M{.a{y}}`. These are
    equivalent when the exact selector appears in the refined block and the
    moved declarations use properties disjoint from that refined selector.
    """
    out = lines[:]
    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(out):
            if not out[i].startswith("@media ") or not out[i].endswith("{"):
                i += 1
                continue
            first_end = _matching_block_end(out, i)
            if first_end is None or first_end + 1 >= len(out):
                i += 1
                continue
            j = first_end + 1
            if not prelude_is_refinement(out[i], out[j]):
                i += 1
                continue
            second_end = _matching_block_end(out, j)
            if second_end is None or second_end + 1 >= len(out):
                i += 1
                continue
            k = second_end + 1
            if out[k] != out[i]:
                i += 1
                continue
            third_end = _matching_block_end(out, k)
            if third_end is None:
                i += 1
                continue

            refined_props: dict[str, set[str]] = {}
            for s, e in block_immediate_style_blocks(out, j, second_end):
                parsed = style_block_props(out, s, e)
                if parsed is None:
                    continue
                selector, props = parsed
                refined_props.setdefault(selector, set()).update(props)

            move_end = k
            scan = k + 1
            while scan < third_end and out[scan].endswith("{") and not out[scan].startswith("@"):
                b_end = _matching_block_end(out, scan)
                if b_end is None or b_end > third_end:
                    break
                parsed = style_block_props(out, scan, b_end)
                if parsed is None:
                    break
                selector, props = parsed
                other = refined_props.get(selector)
                if other is None or (props & other):
                    break
                move_end = b_end
                scan = b_end + 1

            if move_end == k:
                i += 1
                continue

            moved = out[k + 1 : move_end + 1]
            remaining_third_body = out[move_end + 1 : third_end]
            new_first = out[i:first_end] + moved + ["}"]
            replacement = new_first + out[j : second_end + 1]
            if remaining_third_body:
                replacement += [out[k]] + remaining_third_body + ["}"]
            out[i : third_end + 1] = replacement
            changed = True
            i = 0
        # while
    return out


def decimal_css_text(value: Decimal) -> str:
    text = format(value.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    if text == "-0":
        text = "0"
    return text


def normalize_simple_calc_arithmetic(value: str) -> str:
    def repl(match: re.Match[str]) -> str:
        lhs = Decimal(match.group(1))
        unit = match.group(2)
        rhs = Decimal(match.group(3))
        return f"{decimal_css_text(lhs * rhs)}{unit}"

    value = re.sub(
        r"calc\(\s*(-?\d+(?:\.\d+)?)\s*([A-Za-z%]+)\s*\*\s*(-?\d+(?:\.\d+)?)\s*\)",
        repl,
        value,
    )
    value = re.sub(r"\s+", " ", value)
    value = re.sub(r"\(\s+", "(", value)
    value = re.sub(r"\s+\)", ")", value)
    value = re.sub(r"\+\s*-([0-9.]+)", r"- \1", value)
    value = re.sub(r"calc\(([-0-9.]+px) - calc\(([^()]+ / 2)\)( \* 2)?\)", r"calc(\1 - \2\3)", value)
    value = re.sub(r"calc\(([-0-9.]+px) - calc\(\(([^()]+)\) / 2\) \* 2\)", r"calc(\1 - (\2) / 2 * 2)", value)
    value = re.sub(r"calc\(calc\(\(([^()]+)\) / 2\) - ([^;]+)\)", r"calc((\1) / 2 - \2)", value)
    value = re.sub(r"calc\(\(([^()]*\([^()]*\)[^()]*)\) - ([^()]+)\)", r"calc(\1 - \2)", value)
    value = re.sub(r"calc\(calc\(([^()]*(?:\([^()]*\)[^()]*)*)\)\)", r"calc(\1)", value)
    value = re.sub(r"\(\s*([^()]+?)\s*-\s*-([0-9.]+[A-Za-z%]*)\s*\)", r"(\1 + \2)", value)
    value = re.sub(
        r"calc\(\s*\(\s*\(\s*([^()]+?)\s*-\s*([^()]+?)\s*\)\s*-\s*([^()]+?)\s*\)\s*/\s*([^()]+?)\s*\)",
        r"calc((\1 - \2 - \3) / \4)",
        value,
    )
    return value


def normalize_declaration_value_equivalents(line: str) -> str:
    if not line.endswith(";") or ":" not in line:
        return line
    prop, value = line.split(":", 1)

    def hex6_repl(match: re.Match[str]) -> str:
        raw = match.group(1)
        r = int(raw[0:2], 16)
        g = int(raw[2:4], 16)
        b = int(raw[4:6], 16)
        return f"rgb({r}, {g}, {b})"

    def hex3_repl(match: re.Match[str]) -> str:
        raw = match.group(1)
        r = int(raw[0] * 2, 16)
        g = int(raw[1] * 2, 16)
        b = int(raw[2] * 2, 16)
        return f"rgb({r}, {g}, {b})"

    value = value.strip()
    value = re.sub(r"#([0-9A-Fa-f]{6})(?![0-9A-Fa-f_-])", hex6_repl, value)
    value = re.sub(r"#([0-9A-Fa-f]{3})(?![0-9A-Fa-f_-])", hex3_repl, value)
    value = re.sub(r"\s+!important\b", "!important", value, flags=re.IGNORECASE)
    value = normalize_simple_calc_arithmetic(value)
    return f"{prop}:{value}"


def normalize_generated_keyframes_names(lines: list[str]) -> list[str]:
    names: dict[str, str] = {}

    def canonical(name: str) -> str:
        if name not in names:
            names[name] = f"__keyframes_{len(names)}"
        return names[name]

    keyframes_re = re.compile(r"^@(-[A-Za-z]+-)?keyframes\s+([A-Za-z_][A-Za-z0-9_-]*)\s*\{$")
    animation_name_re = re.compile(r"^(animation-name\s*:\s*)([A-Za-z_][A-Za-z0-9_-]*)(\s*(?:!important\s*)?;)$")
    out: list[str] = []
    for line in lines:
        m = keyframes_re.match(line)
        if m:
            prefix = m.group(1) or ""
            out.append(f"@{prefix}keyframes {canonical(m.group(2))} {{")
            continue
        m = animation_name_re.match(line)
        if m:
            out.append(f"{m.group(1)}{canonical(m.group(2))}{m.group(3)}")
            continue
        out.append(line)
    return out
EXCLUDED_DIRS = {
    ".git", ".hg", ".svn", "node_modules", "vendor", ".sass-cache",
    ".cache", "dist", "build", "coverage", "tmp", "temp", "target",
    "out", "zig-out", ".zig-cache", "bower_components",
}
SASS_EXTS = {".scss", ".sass"}
DEFAULT_TIMEOUT = 120
INSTALL_TIMEOUT = 900
COMPAT_TARGET = int(os.environ.get("ZSASS_COMPAT_TARGET", "10000"))
DISALLOWED_FULL_NAMES = {"sass/dart-sass"}



def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def fixture_root_default() -> Path:
    return (repo_root() / "../zsass-realworld-fixtures").resolve()


def run(cmd: list[str], *, cwd: Path | None = None, timeout: int = DEFAULT_TIMEOUT,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(data: str) -> str:
    return sha256_bytes(data.encode("utf-8", "surrogateescape"))


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def suite_name(full_name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "__", full_name).strip("_")


def sanitized_source_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._/-]+", "_", value).strip("_")


def github_owner_repo_from_url(url: str) -> str | None:
    raw = url.strip()
    if "://" not in raw:
        m = re.match(r"^(?:[^@\s]+@)?github\.com[:/]+([^/\s:]+)/([^/\s:]+?)(?:\.git)?/?$", raw, re.IGNORECASE)
        if m:
            return f"github.com/{urllib.parse.unquote(m.group(1))}/{urllib.parse.unquote(m.group(2))}"

    parsed = urllib.parse.urlparse(raw)
    host = parsed.netloc.lower().removeprefix("www.")
    if "@" in host:
        host = host.rsplit("@", 1)[1]
    if parsed.scheme in {"ssh", "git+ssh"}:
        if host != "github.com":
            return None
    elif parsed.scheme not in {"http", "https"}:
        return None
    elif host not in {"github.com", "codeload.github.com"}:
        return None
    parts = [urllib.parse.unquote(part) for part in parsed.path.strip("/").split("/") if part]
    if len(parts) < 2:
        return None
    owner = parts[0]
    repo = parts[1].removesuffix(".git")
    if not owner or not repo:
        return None
    return f"github.com/{owner}/{repo}"


def repo_id_from_url(url: str) -> str:
    github_id = github_owner_repo_from_url(url)
    if github_id:
        return github_id
    m = re.match(r"https?://([^/]+)/(.+?)(?:\.git)?/?$", url)
    if not m:
        return sanitized_source_id(url)
    return f"{m.group(1)}/{m.group(2).removesuffix('.git')}"


def archive_id_from_url(url: str) -> str:
    github_id = github_owner_repo_from_url(url)
    if github_id:
        return github_id
    m = re.match(r"https?://([^/]+)/(.+)$", url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    return sanitized_source_id(url)


def source_kind(args: argparse.Namespace) -> str:
    if args.source_kind:
        return args.source_kind
    if args.archive_url:
        return "archive"
    if args.repo_url:
        host = re.match(r"https?://([^/]+)/", args.repo_url)
        if host:
            return host.group(1).removeprefix("www.")
        return "git"
    return "github"


def ensure_repo_allowed(full_name: str) -> None:
    normalized = full_name.lower().removeprefix("github.com/").removesuffix(".git")
    if normalized in DISALLOWED_FULL_NAMES or normalized.endswith("/sass/dart-sass"):
        raise SystemExit(f"refusing to clone prohibited clean-room source: {full_name}")


def ensure_dirs(fixture_root: Path) -> tuple[Path, Path, Path]:
    compat = fixture_root / "compat-disposable"
    work = fixture_root / ".compat-work"
    runs = fixture_root / ".compat-runs"
    compat.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    runs.mkdir(parents=True, exist_ok=True)
    (compat / "failures.jsonl").touch(exist_ok=True)
    return compat, work, runs


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as f:
        json.dump(record, f, sort_keys=True, ensure_ascii=False)
        f.write("\n")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))
    return rows


def command_text(cmd: list[str], cwd: Path | None = None) -> str:
    prefix = f"(cd {cwd} &&) " if cwd else ""
    return prefix + " ".join(cmd)


def normalize_css(css: str, *, generated_keyframes: bool = False) -> str:
    """Normalizer v26: remove CSS-noise diffs while preserving CSS token meaning.

    The scanner is string-aware so comment markers inside strings are kept. It
    also normalizes whitespace after commas outside strings, which ignores
        selector-list formatting-only diffs such as `a, b` vs `a,\nb` without
        reordering or otherwise simplifying CSS. It also collapses obvious
        floating-point tail noise such as `214.20000000000002` to `214.2`.
    """
    out: list[str] = []
    i = 0
    n = len(css)
    in_string: str | None = None
    while i < n:
        ch = css[i]
        if in_string:
            if ch == "\\" and i + 1 < n:
                # Preserve escaped content, but make escaped double quotes stable.
                nxt = css[i + 1]
                if nxt == '"':
                    out.append('\\"')
                elif nxt == "'":
                    out.append("'")
                else:
                    out.append(ch)
                    out.append(nxt)
                i += 2
                continue
            if ch == in_string:
                out.append('"')
                in_string = None
                i += 1
                continue
            if ch == '"':
                out.append('\\"')
            else:
                out.append(ch)
            i += 1
            continue
        if ch in {'"', "'"}:
            in_string = ch
            out.append('"')
            i += 1
            continue
        if ch == "/" and i + 1 < n and css[i + 1] == "*":
            end = css.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        out.append(ch)
        i += 1
    comment_stripped = re.sub(r"rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)", "#0000", "".join(out), flags=re.IGNORECASE)
    comment_stripped = re.sub(r'^\s*@charset\s+"UTF-8";\s*\n?', "", comment_stripped, flags=re.IGNORECASE)
    comment_stripped = re.sub(r"\\201[Cc]\s?", "“", comment_stripped)
    comment_stripped = re.sub(r"\\201[Dd]\s?", "”", comment_stripped)
    comment_stripped = re.sub(r"\\2018\s?", "‘", comment_stripped)
    comment_stripped = re.sub(r"\\2019\s?", "’", comment_stripped)
    comment_stripped = comment_stripped.replace("\\“", "“").replace("\\”", "”")
    comment_stripped = re.sub(
        r'(\[[A-Za-z_][-A-Za-z0-9_]*(?:\|[A-Za-z_][-A-Za-z0-9_]*)?=)"([A-Za-z_][-A-Za-z0-9_]*)"(\])',
        r"\1\2\3",
        comment_stripped,
    )

    comma_norm: list[str] = []
    i = 0
    n = len(comment_stripped)
    in_string = None
    while i < n:
        ch = comment_stripped[i]
        if in_string:
            comma_norm.append(ch)
            if ch == "\\" and i + 1 < n:
                comma_norm.append(comment_stripped[i + 1])
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue
        if ch == '"':
            in_string = ch
            comma_norm.append(ch)
            i += 1
            continue
        if ch == ",":
            comma_norm.append(",")
            j = i + 1
            while j < n and comment_stripped[j] in " \t\r\n":
                j += 1
            if j < n:
                comma_norm.append(" ")
            i = j
            continue
        comma_norm.append(ch)
        i += 1

    numeric_norm = re.sub(
        r"(?<![A-Za-z0-9_-])(-?\d+\.\d*?[1-9])0{8,}([1-9]\d*)(?![A-Za-z0-9_-])",
        r"\1",
        "".join(comma_norm),
    )
    math_norm = normalize_min_calc_args(re.sub(r"([+*/,-])\s*\n\s*", r"\1 ", numeric_norm))
    selector_order_norm = normalize_selector_list_order(math_norm)
    # Formatting-only indentation differences do not affect CSS token semantics.
    # Normalize leading indentation as well as trailing whitespace so multi-line
    # custom-property/font-family formatting does not create false failures.
    lines = [normalize_declaration_value_equivalents(line.strip()) for line in selector_order_norm.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    lines = [line for line in lines if line]
    # Empty style/at-rule blocks have no CSS effect. Remove them after line
    # normalization so `a {\n}` and absent `a` compare the same.
    changed = True
    while changed:
        changed = False
        compact: list[str] = []
        i = 0
        while i < len(lines):
            if i + 1 < len(lines) and lines[i].endswith("{") and lines[i + 1] == "}":
                changed = True
                i += 2
                continue
            compact.append(lines[i])
            i += 1
        lines = compact
    lines = normalize_adjacent_same_selector_blocks(lines)
    lines = normalize_adjacent_disjoint_pseudo_block_order(lines)
    lines = normalize_nested_media_and(lines)
    lines = normalize_media_disjoint_decl_order(lines)
    if generated_keyframes:
        lines = normalize_generated_keyframes_names(lines)
    return "\n".join(lines) + "\n"


def tree_hash(root: Path) -> str:
    parts: list[bytes] = []
    for p in sorted(x for x in root.rglob("*.css") if x.is_file()):
        rel = p.relative_to(root).as_posix()
        parts.append(rel.encode())
        parts.append(b"\0")
        parts.append(p.read_bytes())
        parts.append(b"\0")
    return sha256_bytes(b"".join(parts))


EXCLUDED_DIRS_SASS_OK = {"build"}


def is_excluded(path: Path, root: Path, *, for_sass: bool = False) -> bool:
    rel = path.relative_to(root)
    skip = EXCLUDED_DIRS - EXCLUDED_DIRS_SASS_OK if for_sass else EXCLUDED_DIRS
    return any(part in skip for part in rel.parts)


def discover_entries(source: Path, overrides: list[str]) -> list[Path]:
    if overrides:
        return [source / item for item in overrides]
    entries: list[Path] = []
    for p in source.rglob("*"):
        if not p.is_file() or p.suffix not in SASS_EXTS:
            continue
        if is_excluded(p, source, for_sass=True):
            continue
        if p.name.startswith("_"):
            continue
        entries.append(p)
    entries = sorted(entries, key=lambda p: p.relative_to(source).as_posix())
    preferred = preferred_project_entries(source, entries)
    return preferred or entries


def maybe_sass_counterparts(source: Path, value: str) -> list[Path]:
    raw = value.split("?", 1)[0].strip()
    if not raw or raw.startswith(("http://", "https://")):
        return []
    path = Path(raw)
    names: list[str] = []
    if path.suffix in SASS_EXTS:
        names.append(path.as_posix())
    elif path.suffix == ".css":
        stem = path.with_suffix("").as_posix()
        names.extend([stem + ".scss", stem + ".sass"])
        # Packages often publish `dist/name.css` from `src/name.scss`.
        base = Path(stem).name
        names.extend([
            f"{base}.scss",
            f"{base}.sass",
            f"src/{base}.scss",
            f"src/{base}.sass",
            f"scss/{base}.scss",
            f"sass/{base}.sass",
        ])
        if base.endswith(".css"):
            short = base.removesuffix(".css")
            names.extend([f"src/{short}.scss", f"src/{short}.sass", f"{short}.scss", f"{short}.sass"])
    else:
        names.extend([raw + ".scss", raw + ".sass"])
    out: list[Path] = []
    for name in names:
        p = source / name
        if p.is_file() and p.suffix in SASS_EXTS and not is_excluded(p, source):
            out.append(p)
    return out


def preferred_project_entries(source: Path, entries: list[Path]) -> list[Path]:
    preferred: dict[str, Path] = {}

    pkg_json = source / "package.json"
    if pkg_json.exists():
        try:
            pkg = json.loads(pkg_json.read_text(encoding="utf-8"))
        except Exception:
            pkg = {}
        for key in ("sass", "scss", "style", "main", "browser"):
            value = pkg.get(key)
            if isinstance(value, str):
                for p in maybe_sass_counterparts(source, value):
                    preferred[p.as_posix()] = p
        pkg_name = str(pkg.get("name") or "").split("/")[-1]
        for suffix in (".css", ".scss", ".sass"):
            pkg_name = pkg_name.removesuffix(suffix)
        if pkg_name:
            for rel in (
                f"{pkg_name}.scss",
                f"{pkg_name}.sass",
                f"{pkg_name}.base.scss",
                f"{pkg_name}.base.sass",
                f"src/{pkg_name}.scss",
                f"src/{pkg_name}.sass",
                f"src/{pkg_name}.base.scss",
                f"src/{pkg_name}.base.sass",
            ):
                p = source / rel
                if p.is_file() and not is_excluded(p, source):
                    preferred[p.as_posix()] = p

    for p in entries:
        rel = p.relative_to(source)
        if "build" in rel.parts:
            preferred[p.as_posix()] = p

    main_names = {
        "index",
        "main",
        "app",
        "application",
        "style",
        "styles",
        "site",
        "theme",
        "global",
        "bundle",
    }
    if not preferred:
        for p in entries:
            stem = p.stem.lower()
            if stem in main_names or stem.endswith((".bundle", ".main", ".all")):
                preferred[p.as_posix()] = p

    if not preferred:
        for p in entries:
            stem = p.stem.lower()
            if any(part in stem for part in ("variable", "mixin", "setting", "config", "util", "helper")):
                continue
            try:
                text = p.read_text(encoding="utf-8", errors="surrogateescape")
            except Exception:
                continue
            if re.search(r"@(import|use|forward)\b", text):
                preferred[p.as_posix()] = p

    return sorted(preferred.values(), key=lambda p: p.relative_to(source).as_posix())


def read_candidate_list(fixture_root: Path) -> list[dict[str, Any]]:
    path = fixture_root / ".plans" / "fixture-candidates.json"
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("candidates", [])


def core_suite_count(fixture_root: Path) -> int:
    return sum(1 for _ in fixture_root.glob("*/suite.env"))

def core_full_name_identity(value: str) -> str:
    return value.removeprefix("github.com/")

def imported_core_full_names(fixture_root: Path) -> set[str]:
    path = fixture_root / ".plans" / "fixture-candidates.json"
    out: set[str] = set()
    if path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))
        for item in data.get("candidates", []):
            if item.get("kind") == "local-sample":
                out.add(item.get("full_name", ""))
    # Also protect existing checked fixture directories by source.json URL.
    for source_json in fixture_root.glob("*/source.json"):
        try:
            meta = json.loads(source_json.read_text(encoding="utf-8"))
        except Exception:
            continue
        url = str(meta.get("repo_url") or meta.get("repo") or meta.get("url") or "")
        if url.startswith("https://github.com/"):
            out.add(url.removeprefix("https://github.com/").removesuffix(".git"))
    return {x for x in out if x}


def pick_candidate(fixture_root: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    compat = fixture_root / "compat-disposable"
    passed = {r.get("full_name") for r in load_jsonl(compat / "ledger.jsonl") if r.get("status") == "pass"}
    failed = {r.get("full_name") for r in load_jsonl(compat / "failures.jsonl") if r.get("status") != "pass"}
    core = imported_core_full_names(fixture_root)
    for item in read_candidate_list(fixture_root):
        full = item.get("full_name")
        if not full or full in DISALLOWED_FULL_NAMES or full in passed or full in failed or full in core:
            continue
        return full
    raise SystemExit("no candidate available; pass --repo owner/repo")


def clone_repo_url(repo_url: str, suite: str, work_root: Path) -> tuple[Path, str, str]:
    suite_work = work_root / suite
    if suite_work.exists():
        shutil.rmtree(suite_work)
    suite_work.mkdir(parents=True)
    source = suite_work / "source"
    clone_env = {**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"}
    cp = run(["git", "clone", "--depth", "1", repo_url, str(source)], timeout=900, env=clone_env)
    if cp.returncode != 0:
        raise RuntimeError(f"git clone failed: {cp.stderr.strip() or cp.stdout.strip()}")
    commit = run(["git", "rev-parse", "HEAD"], cwd=source).stdout.strip()
    return source, repo_url, commit


def clone_repo(full_name: str, suite: str, work_root: Path) -> tuple[Path, str, str]:
    ensure_repo_allowed(full_name)
    return clone_repo_url(f"https://github.com/{full_name}", suite, work_root)


def safe_extract_zip(archive: Path, dest: Path) -> None:
    dest_resolved = dest.resolve()
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            target = (dest / item.filename).resolve()
            if not target.is_relative_to(dest_resolved):
                raise RuntimeError(f"zip entry escapes extraction root: {item.filename}")
        zf.extractall(dest)


def safe_extract_tar(archive: Path, dest: Path) -> None:
    dest_resolved = dest.resolve()
    with tarfile.open(archive, "r:*") as tf:
        for member in tf.getmembers():
            if member.islnk() or member.issym():
                raise RuntimeError(f"tar link entry is not allowed: {member.name}")
            if member.isdev() or not (member.isdir() or member.isfile()):
                raise RuntimeError(f"unsupported tar entry type: {member.name}")
            target = (dest / member.name).resolve()
            if not target.is_relative_to(dest_resolved):
                raise RuntimeError(f"tar entry escapes extraction root: {member.name}")
        tf.extractall(dest)


def extracted_source_root(dest: Path) -> Path:
    children = [p for p in dest.iterdir() if p.name not in {"__MACOSX"}]
    dirs = [p for p in children if p.is_dir()]
    files = [p for p in children if p.is_file()]
    if len(dirs) == 1 and not files:
        return dirs[0]
    return dest


def file_tree_hash(root: Path) -> str:
    parts: list[bytes] = []
    for p in sorted(x for x in root.rglob("*") if x.is_file()):
        if is_excluded(p, root):
            continue
        rel = p.relative_to(root).as_posix()
        parts.append(rel.encode())
        parts.append(b"\0")
        try:
            parts.append(sha256_bytes(p.read_bytes()).encode())
        except OSError:
            continue
        parts.append(b"\0")
    return sha256_bytes(b"".join(parts))


def fetch_archive_source(archive_url: str, suite: str, work_root: Path) -> tuple[Path, dict[str, str]]:
    suite_work = work_root / suite
    if suite_work.exists():
        shutil.rmtree(suite_work)
    suite_work.mkdir(parents=True)
    archive = suite_work / "source.archive"
    req = urllib.request.Request(archive_url, headers={"User-Agent": "zsass-compat-disposable"})
    with urllib.request.urlopen(req, timeout=900) as resp:
        archive.write_bytes(resp.read())
    archive_sha = sha256_bytes(archive.read_bytes())
    extract_root = suite_work / "extract"
    extract_root.mkdir()
    if zipfile.is_zipfile(archive):
        safe_extract_zip(archive, extract_root)
        archive_format = "zip"
    else:
        try:
            safe_extract_tar(archive, extract_root)
        except tarfile.TarError as e:
            raise RuntimeError(f"unsupported archive format: {e}") from e
        archive_format = "tar"
    source = extracted_source_root(extract_root)
    meta = {
        "archive_url": archive_url,
        "archive_sha256": archive_sha,
        "archive_format": archive_format,
        "source_tree_sha256": file_tree_hash(source),
    }
    return source, meta


def nearest_package_root(entry: Path, source: Path) -> Path | None:
    cur = entry.parent
    while True:
        if (cur / "package.json").exists():
            return cur
        if cur == source:
            return source if (source / "package.json").exists() else None
        cur = cur.parent


def package_roots_for_entries(entries: list[Path], source: Path) -> list[Path]:
    roots: dict[str, Path] = {}
    for entry in entries:
        root = nearest_package_root(entry, source)
        if root is not None:
            roots[root.as_posix()] = root
    if not roots and (source / "package.json").exists():
        roots[source.as_posix()] = source
    return [roots[k] for k in sorted(roots)]


def install_command(pkg: Path) -> list[str]:
    if (pkg / "package-lock.json").exists() or (pkg / "npm-shrinkwrap.json").exists():
        return ["npm", "ci", "--no-audit", "--no-fund"]
    if (pkg / "pnpm-lock.yaml").exists() and shutil.which("pnpm"):
        return ["pnpm", "install", "--frozen-lockfile"]
    if (pkg / "yarn.lock").exists() and shutil.which("yarn"):
        return ["yarn", "install", "--frozen-lockfile"]
    return ["npm", "install", "--no-audit", "--no-fund"]


def simple_aliases_from_config(pkg: Path) -> list[tuple[str, str]]:
    aliases: list[tuple[str, str]] = []
    if (pkg / "src").is_dir():
        aliases.append(("@", "src"))
    for name in ("tsconfig.json", "jsconfig.json"):
        path = pkg / name
        if not path.exists():
            continue
        try:
            cfg = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        paths = cfg.get("compilerOptions", {}).get("paths", {})
        for key, values in paths.items():
            if not isinstance(values, list) or not values:
                continue
            if not key.endswith("/*") or not str(values[0]).endswith("/*"):
                continue
            alias = key[:-2]
            target = str(values[0])[:-2]
            if "/" in alias or not alias:
                continue
            if (pkg / target).is_dir():
                aliases.append((alias, target))
    dedup: dict[str, str] = {}
    for alias, target in aliases:
        dedup.setdefault(alias, target)
    return sorted(dedup.items())




def _find_node_module(nm: Path, name: str) -> Path | None:
    """Find a package in node_modules with common name variations."""
    if (nm / name).is_dir():
        return nm / name
    dotted = re.sub(r'js$', '.js', name)
    if dotted != name and (nm / dotted).is_dir():
        return nm / dotted
    for scope in sorted(nm.iterdir()):
        if not scope.name.startswith("@") or not scope.is_dir():
            continue
        if (scope / name).is_dir():
            return scope / name
    return None


def resolve_vendor_node_modules(source: Path) -> list[str]:
    """Create symlinks from vendor/ directories to node_modules/ packages.

    Projects like Joomla copy assets from node_modules/ into vendor-prefixed
    directories during their build step.  When the build step cannot run,
    Sass relative imports through vendor/ directories fail.  This bridges
    the gap with symlinks.
    """
    nm = source / "node_modules"
    if not nm.is_dir():
        return []

    vendor_pkgs: dict[str, set[str]] = {}
    import_pat = re.compile(r'@(?:import|use|forward)\s+["\']([^"\']+)["\']')

    for f in source.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if is_excluded(f, source, for_sass=True):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in import_pat.finditer(text):
            raw = m.group(1)
            parts = raw.split("/")
            try:
                vi = parts.index("vendor")
            except ValueError:
                continue
            if vi + 1 >= len(parts):
                continue
            pkg_name = parts[vi + 1]
            cur = f.parent
            for seg in parts[:vi]:
                if seg == "..":
                    cur = cur.parent
                elif seg != ".":
                    cur = cur / seg
            vendor_dir = (cur / "vendor").resolve()
            try:
                vendor_dir.relative_to(source.resolve())
            except ValueError:
                continue
            vendor_pkgs.setdefault(vendor_dir.as_posix(), set()).add(pkg_name)

    if not vendor_pkgs:
        return []

    setup: list[str] = []
    source_resolved = source.resolve()
    for vendor_key, pkg_names in vendor_pkgs.items():
        vendor_dir = Path(vendor_key)
        for pkg_name in sorted(pkg_names):
            nm_pkg = _find_node_module(nm, pkg_name)
            if not nm_pkg:
                continue
            pkg_dir = vendor_dir / pkg_name
            created = False
            if not pkg_dir.exists():
                pkg_dir.mkdir(parents=True, exist_ok=True)
                created = True
            nm_rel = nm_pkg.relative_to(nm)
            for child in sorted(nm_pkg.iterdir(), key=lambda p: p.name):
                link = pkg_dir / child.name
                if not link.exists():
                    link.symlink_to(child, target_is_directory=child.is_dir())
                    if child.is_dir():
                        setup.append(f"vendor symlink {link.relative_to(source_resolved)} -> node_modules/{nm_rel}/{child.name}")
            if not (pkg_dir / "scss").exists() and (nm_pkg / "css").is_dir():
                (pkg_dir / "scss").symlink_to(nm_pkg / "css", target_is_directory=True)
                setup.append(f"vendor symlink {(pkg_dir / 'scss').relative_to(source_resolved)} -> node_modules/{nm_rel}/css (scss alias)")

    return setup


def common_sass_load_paths(pkg: Path) -> list[Path]:
    rels = [
        "assets/stylesheets",
        "app/assets/stylesheets",
        "lib/assets/stylesheets",
        "vendor/assets/stylesheets",
        "assets/scss",
        "app/assets/scss",
        "lib/assets/scss",
        "vendor/assets/scss",
        "assets/sass",
        "_sass",
        "src/styles",
        "src/scss",
        "src/sass",
        "scss",
        "sass",
        "styles",
        "stylesheets",
    ]
    return [pkg / rel for rel in rels if (pkg / rel).is_dir()]


def entry_sass_load_paths(entries: list[Path], source: Path) -> list[Path]:
    """Cheap non-bundler load paths inferred from Sass entry locations."""
    out: list[Path] = []
    seen: set[str] = set()

    def add_path(p: Path) -> None:
        if not p.is_dir():
            return
        key = p.resolve().as_posix()
        if key in seen:
            return
        seen.add(key)
        out.append(p)

    def dir_has_direct_sass(p: Path) -> bool:
        try:
            return any(ch.is_file() and ch.suffix in SASS_EXTS for ch in p.iterdir())
        except OSError:
            return False

    for entry in entries:
        for p in (entry.parent, entry.parent / "include", entry.parent / "includes"):
            add_path(p)
        cur = entry.parent
        while cur != source and source in cur.parents:
            try:
                children = sorted(cur.iterdir(), key=lambda x: x.name)
            except OSError:
                children = []
            for child in children[:64]:
                if not child.is_dir() or child.name.startswith("."):
                    continue
                if child.name not in ("core", "shared", "common", "styles", "style", "scss", "sass"):
                    continue
                if dir_has_direct_sass(child):
                    add_path(child)
            cur = cur.parent
        # Some repos vendor a Sass framework as a direct child of the entry
        # directory and import its entrypoint by basename. Bundlers commonly
        # add those vendor roots; Dart Sass CLI needs them as explicit load paths.
        try:
            children = sorted(entry.parent.iterdir(), key=lambda x: x.name)
        except OSError:
            children = []
        for child in children[:64]:
            if not child.is_dir() or child.name.startswith("."):
                continue
            if not dir_has_direct_sass(child):
                continue
            add_path(child)
    return out


def prepare_generated_sass_partials(source: Path) -> list[str]:
    """Materialize cheap Sass partials that project build scripts generate."""
    setup: list[str] = []
    import_pat = re.compile(r'@(?:import|use|forward)\s+["\']([^"\']+)["\']')
    for f in source.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if is_excluded(f, source, for_sass=True):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in import_pat.finditer(text):
            raw = m.group(1)
            if "/" in raw or not raw.endswith("-temp"):
                continue
            base = raw[:-len("-temp")]
            if not base:
                continue
            src = f.parent / f"_{base}.scss"
            dst = f.parent / f"_{raw}.scss"
            if src.is_file() and not dst.exists():
                shutil.copyfile(src, dst)
                setup.append(f"generated {dst.relative_to(source).as_posix()} from {src.relative_to(source).as_posix()}")
    return setup


def repair_relative_sass_dir_imports(source: Path) -> list[str]:
    """Bridge project layouts where generated theme files expect ./sass."""
    setup: list[str] = []
    canonical = source / "src" / "sass"
    if not canonical.is_dir():
        return setup
    import_pat = re.compile(r'@(?:import|use|forward)\s+["\']([^"\']*?sass/[^"\']+)["\']')
    source_resolved = source.resolve()
    for f in source.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if is_excluded(f, source, for_sass=True):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in import_pat.finditer(text):
            raw = m.group(1)
            if raw.startswith("~") or raw.startswith("/"):
                continue
            sass_pos = raw.find("sass/")
            if sass_pos < 0:
                continue
            link_dir = (f.parent / raw[: sass_pos + len("sass")]).resolve()
            try:
                link_dir.relative_to(source_resolved)
            except ValueError:
                continue
            if link_dir.exists():
                continue
            link_dir.parent.mkdir(parents=True, exist_ok=True)
            rel_target = os.path.relpath(canonical, link_dir.parent)
            link_dir.symlink_to(rel_target, target_is_directory=True)
            setup.append(f"symlink {link_dir.relative_to(source_resolved).as_posix()} -> {Path(rel_target).as_posix()}")
    return setup


def dedup_paths(paths: list[Path]) -> list[Path]:
    out: list[Path] = []
    seen: set[str] = set()
    for p in paths:
        key = p.resolve().as_posix() if p.exists() else p.as_posix()
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def tilde_packages_in_sass(pkg: Path) -> list[str]:
    found: set[str] = set()
    pat = re.compile(r"@(?:import|use|forward)\s+(?:url\()?\s*(?:[\"']~([^\"')]+)|~([^\\s\"';,)]+))")
    for f in pkg.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if any(part in EXCLUDED_DIRS for part in f.relative_to(pkg).parts):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in pat.finditer(text):
            raw = m.group(1) or m.group(2) or ""
            rest = raw.split("/", 2)
            if not rest:
                continue
            if rest[0].startswith("@") and len(rest) >= 2:
                found.add(rest[0] + "/" + rest[1])
            else:
                found.add(rest[0])
    return sorted(found)


def create_tilde_alias(pkg: Path, package_name: str) -> str | None:
    target = pkg / "node_modules" / package_name
    if not target.exists():
        return None
    if package_name.startswith("@") and "/" in package_name:
        scope, name = package_name.split("/", 1)
        alias_dir = pkg / ("~" + scope)
        alias_dir.mkdir(exist_ok=True)
        link = alias_dir / name
        rel_label = f"{alias_dir.name}/{name}"
    else:
        link = pkg / ("~" + package_name)
        rel_label = link.name
    if not link.exists():
        link.symlink_to(target, target_is_directory=True)
        return f"symlink {rel_label} -> node_modules/{package_name}"
    return None


def dollar_packages_in_sass(pkg: Path) -> list[str]:
    found: set[str] = set()
    pat = re.compile(r"@(?:import|use|forward)\s+(?:url\()?\s*[\"']\$([A-Za-z0-9_-]+)(?:/|[\"'])")
    for f in pkg.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if any(part in EXCLUDED_DIRS for part in f.relative_to(pkg).parts):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in pat.finditer(text):
            found.add(m.group(1))
    return sorted(found)


def create_dollar_alias(pkg: Path, package_name: str) -> str | None:
    nm_pkg = pkg / "node_modules" / package_name
    if not nm_pkg.exists():
        return None
    target = nm_pkg / "scss" if (nm_pkg / "scss").is_dir() else nm_pkg
    link = pkg / f"${package_name}"
    if not link.exists():
        rel_target = os.path.relpath(target, link.parent)
        link.symlink_to(rel_target, target_is_directory=True)
        target_label = f"node_modules/{package_name}/scss" if target.name == "scss" else f"node_modules/{package_name}"
        return f"symlink {link.name} -> {target_label}"
    return None


def node_module_sass_load_paths(nm: Path) -> list[Path]:
    out: list[Path] = []
    if not nm.is_dir():
        return out

    def add_package_dirs(pkg_dir: Path) -> None:
        try:
            if any(p.is_file() and p.suffix in SASS_EXTS for p in pkg_dir.iterdir()):
                out.append(pkg_dir)
        except OSError:
            pass
        for rel in ("scss", "sass", "styles", "stylesheets", "app/assets/stylesheets"):
            p = pkg_dir / rel
            if p.is_dir():
                out.append(p)
        src = pkg_dir / "src"
        if src.is_dir():
            try:
                if any(p.is_file() and p.suffix in SASS_EXTS for p in src.iterdir()):
                    out.append(src)
            except OSError:
                pass

    try:
        children = sorted(nm.iterdir(), key=lambda p: p.name)
    except OSError:
        return out
    for child in children[:256]:
        if not child.is_dir():
            continue
        if child.name.startswith("@"):
            try:
                scoped = sorted(child.iterdir(), key=lambda p: p.name)
            except OSError:
                continue
            for pkg_dir in scoped[:128]:
                if pkg_dir.is_dir():
                    add_package_dirs(pkg_dir)
        else:
            add_package_dirs(child)
    return out


def package_collection_sass_load_paths(root: Path) -> list[Path]:
    """Infer Sass load paths for package collections like bower_components."""
    out: list[Path] = []
    if not root.is_dir():
        return out

    def add_package_dirs(pkg_dir: Path) -> None:
        try:
            if any(p.is_file() and p.suffix in SASS_EXTS for p in pkg_dir.iterdir()):
                out.append(pkg_dir)
        except OSError:
            pass
        for rel in ("dist", "scss", "sass", "styles", "stylesheets", "app/assets/stylesheets"):
            p = pkg_dir / rel
            if p.is_dir():
                out.append(p)

    try:
        children = sorted(root.iterdir(), key=lambda p: p.name)
    except OSError:
        return out
    for child in children[:256]:
        if child.is_dir():
            add_package_dirs(child)
    return out


def repair_package_source_indexes(nm: Path) -> list[str]:
    setup: list[str] = []
    if not nm.is_dir():
        return setup

    def handle_package(pkg_dir: Path) -> None:
        package_json = pkg_dir / "package.json"
        if not package_json.is_file():
            return
        try:
            meta = json.loads(package_json.read_text(encoding="utf-8"))
        except Exception:
            return
        source = meta.get("sass") or meta.get("style") or meta.get("source")
        dist_sass = pkg_dir / "dist" / "sass"
        src_sass = pkg_dir / "src" / "sass"
        if src_sass.is_dir() and not dist_sass.exists():
            dist_sass.parent.mkdir(parents=True, exist_ok=True)
            rel_target = os.path.relpath(src_sass, dist_sass.parent)
            dist_sass.symlink_to(rel_target, target_is_directory=True)
            setup.append(f"symlink {dist_sass.relative_to(nm.parent).as_posix()} -> {rel_target}")
        if not isinstance(source, str) or not source.endswith(tuple(SASS_EXTS)):
            return
        src = pkg_dir / source
        if not src.is_file():
            return
        dst = pkg_dir / ("_index" + src.suffix)
        if dst.exists():
            return
        rel_target = os.path.relpath(src, dst.parent)
        dst.symlink_to(rel_target)
        setup.append(f"symlink {dst.relative_to(nm.parent).as_posix()} -> {rel_target}")

    try:
        children = sorted(nm.iterdir(), key=lambda p: p.name)
    except OSError:
        return setup
    for child in children:
        if not child.is_dir():
            continue
        if child.name.startswith("@"):
            try:
                scoped = sorted(child.iterdir(), key=lambda p: p.name)
            except OSError:
                continue
            for pkg_dir in scoped:
                if pkg_dir.is_dir():
                    handle_package(pkg_dir)
        else:
            handle_package(child)
    return setup


def link_workspace_sass_packages(source: Path) -> list[str]:
    """Expose local monorepo packages through root node_modules.

    Some Sass libraries are package workspaces where a package imports a sibling
    via its published name (for example `@scope/name`) without requiring a
    package-manager workspace install for standalone compilation.  Dart Sass CLI
    can resolve those imports when the package exists under a load-path
    `node_modules`, so create conservative symlinks from local package roots.
    """
    setup: list[str] = []
    nm = source / "node_modules"
    source_resolved = source.resolve()

    for package_json in sorted(source.glob("packages/*/package.json")):
        pkg_dir = package_json.parent
        try:
            meta = json.loads(package_json.read_text(encoding="utf-8"))
        except Exception:
            continue
        name = meta.get("name")
        if not isinstance(name, str) or "/" not in name:
            continue
        if not any((pkg_dir / candidate).is_file() for candidate in ("index.scss", "_index.scss", "index.sass", "_index.sass")):
            sassish = False
            for rel in ("src", "sass", "scss"):
                p = pkg_dir / rel
                if p.is_dir() and any(ch.is_file() and ch.suffix in SASS_EXTS for ch in p.iterdir()):
                    sassish = True
                    break
            if not sassish:
                continue

        link = nm / name
        if link.exists():
            continue
        link.parent.mkdir(parents=True, exist_ok=True)
        rel_target = os.path.relpath(pkg_dir, link.parent)
        link.symlink_to(rel_target, target_is_directory=True)
        setup.append(f"symlink {link.relative_to(source_resolved).as_posix()} -> {Path(rel_target).as_posix()}")

    return setup


def repair_relative_node_modules_imports(source: Path) -> list[str]:
    setup: list[str] = []
    import_pat = re.compile(r'@(?:import|use|forward)\s+["\']([^"\']*node_modules/([^/"\']+)[^"\']*)["\']')
    source_resolved = source.resolve()
    for f in source.rglob("*"):
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if is_excluded(f, source, for_sass=True):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        for m in import_pat.finditer(text):
            raw = m.group(1)
            pkg_name = m.group(2)
            nm_pos = raw.find("node_modules/")
            if nm_pos < 0:
                continue
            nm_dir = (f.parent / raw[: nm_pos + len("node_modules")]).resolve()
            try:
                nm_dir.relative_to(source_resolved)
            except ValueError:
                continue
            link = nm_dir / pkg_name
            if link.exists():
                continue
            cur = nm_dir.parent
            target: Path | None = None
            while True:
                candidate = cur / pkg_name
                if candidate.is_dir():
                    target = candidate
                    break
                if cur == source:
                    break
                if source not in cur.parents:
                    break
                cur = cur.parent
            if target is None:
                continue
            nm_dir.mkdir(parents=True, exist_ok=True)
            rel_target = os.path.relpath(target, nm_dir)
            link.symlink_to(rel_target, target_is_directory=True)
            setup.append(f"symlink {link.relative_to(source_resolved).as_posix()} -> {Path(rel_target).as_posix()}")
    return setup


def strip_jekyll_front_matter(entries: list[Path], source: Path) -> list[str]:
    setup: list[str] = []
    for entry in entries:
        try:
            text = entry.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        lines = text.splitlines(keepends=True)
        if not lines or lines[0].strip() != "---":
            continue
        offset = len(lines[0])
        end_offset: int | None = None
        for line in lines[1:]:
            offset += len(line)
            if line.strip() == "---":
                end_offset = offset
                break
        if end_offset is None:
            continue
        stripped = text[end_offset:]
        entry.write_text(stripped, encoding="utf-8", errors="surrogateescape")
        setup.append(f"strip Jekyll front matter from {entry.relative_to(source).as_posix()}")
    return setup


def _read_jekyll_config(source: Path) -> dict[str, Any]:
    """Read Jekyll _config.yml and return flat key lookup."""
    config_path = source / "_config.yml"
    if not config_path.exists():
        return {}
    try:
        text = config_path.read_text(encoding="utf-8", errors="surrogateescape")
    except Exception:
        return {}
    # Simple YAML key: value parser (avoid external dependency)
    # Handles both `key: value` and `key                : value` formats
    result: dict[str, str] = {}
    for line in text.splitlines():
        # Skip comments and indented lines (nested values)
        if line.startswith("#") or (line and line[0] in (" ", "\t")):
            continue
        m = re.match(r"^([\w][\w.-]*)\s*:\s*(.+)$", line)
        if m:
            val = m.group(2).strip()
            # Strip trailing comments
            if " #" in val:
                val = val[:val.index(" #")].strip()
            # Strip quotes
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            if val:
                result[m.group(1)] = val
    return result


def _read_hugo_config(source: Path) -> dict[str, str]:
    """Read Hugo config.toml/yaml/json for params."""
    result: dict[str, str] = {}
    for name in ("config.toml", "hugo.toml", "config.yaml", "hugo.yaml", "config.json", "hugo.json"):
        cfg_path = source / name
        if not cfg_path.exists():
            continue
        try:
            text = cfg_path.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        # Simple extraction of key = "value" patterns from TOML
        for m in re.finditer(r'(\w+)\s*=\s*"([^"]*)"', text):
            result[m.group(1).lower()] = m.group(2)
        # YAML style
        for m in re.finditer(r'^(\w+):\s*(.+)$', text, re.MULTILINE):
            result[m.group(1).lower()] = m.group(2).strip().strip("'\"")
        break
    return result


def resolve_ssg_templates(entries: list[Path], source: Path) -> list[str]:
    """Resolve Jekyll Liquid / Hugo Go template expressions in Sass entry files.

    Static site generators (Jekyll, Hugo) preprocess Sass files through their
    template engines before Sass compilation. For standalone Dart Sass compilation,
    we resolve these templates to their default/configured values.
    """
    setup: list[str] = []
    jekyll_cfg: dict[str, Any] | None = None
    hugo_cfg: dict[str, str] | None = None

    for entry in entries:
        try:
            text = entry.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        if "{{" not in text:
            continue

        # Lazy-load configs
        if jekyll_cfg is None:
            jekyll_cfg = _read_jekyll_config(source)
        if hugo_cfg is None:
            hugo_cfg = _read_hugo_config(source)

        original = text
        replacements: list[str] = []

        # Hugo: {{ default "VALUE" .Var }}
        def _hugo_default(m: re.Match) -> str:
            val = m.group(1) or m.group(2)
            replacements.append(f'{{{{ default "{val}" ... }}}} -> {val}')
            return val
        text = re.sub(r'\{\{\s*default\s+"([^"]*)"\s+[^}]*\}\}', _hugo_default, text)
        text = re.sub(r"\{\{\s*default\s+'([^']*)'\s+[^}]*\}\}", _hugo_default, text)

        # Hugo: {{ .Var | default "VALUE" }}
        def _hugo_pipe_default(m: re.Match) -> str:
            val = m.group(1) or m.group(2)
            replacements.append(f'{{{{ ... | default "{val}" }}}} -> {val}')
            return val
        text = re.sub(r'\{\{[^}]*\|\s*default\s+"([^"]*)"\s*\}\}', _hugo_pipe_default, text)
        text = re.sub(r"\{\{[^}]*\|\s*default\s+'([^']*)'\s*\}\}", _hugo_pipe_default, text)

        # Jekyll Liquid: {{ ... | default: "VALUE" }} or {{ ... | default: 'VALUE' }}
        def _liquid_default(m: re.Match) -> str:
            val = m.group(1) or m.group(2) or m.group(3) or m.group(4)
            replacements.append(f'{{{{ ... | default: "{val}" }}}} -> {val}')
            return val
        text = re.sub(r"""\{\{[^}]*\|\s*default:\s*"([^"]*)"\s*\}\}""", _liquid_default, text)
        text = re.sub(r"""\{\{[^}]*\|\s*default:\s*'([^']*)'\s*\}\}""", _liquid_default, text)
        text = re.sub(r"""\{\{\s*[^}]*\|\s*default:\s*"([^"]*)"\s*\}\}""", _liquid_default, text)
        text = re.sub(r"""\{\{\s*[^}]*\|\s*default:\s*'([^']*)'\s*\}\}""", _liquid_default, text)

        # Jekyll: {{ site.theme }} -> from _config.yml
        def _site_var(m: re.Match) -> str:
            key = m.group(1)
            # Try direct key lookup
            val = jekyll_cfg.get(key, "")
            if not val:
                # Try nested: site.data.X.Y -> look for data_X_Y or just key
                parts = key.split(".")
                for p in parts:
                    val = jekyll_cfg.get(p, "")
                    if val:
                        break
            if val:
                replacements.append(f'{{{{ site.{key} }}}} -> {val}')
            else:
                replacements.append(f'{{{{ site.{key} }}}} -> (removed)')
            return val
        text = re.sub(r'\{\{\s*site\.([a-zA-Z0-9_.]+)\s*\}\}', _site_var, text)

        # Hugo: {{ .Site.Params.KEY }} or {{ .Site.Data.X.Y }}
        def _hugo_site_var(m: re.Match) -> str:
            key = m.group(1).split(".")[-1].lower()
            val = hugo_cfg.get(key, "")
            if val:
                replacements.append(f'{{{{ .Site.{m.group(1)} }}}} -> {val}')
            else:
                replacements.append(f'{{{{ .Site.{m.group(1)} }}}} -> (removed)')
            return val
        text = re.sub(r'\{\{\s*\.Site\.[A-Za-z0-9_.]+\.([A-Za-z0-9_.]+)\s*\}\}', _hugo_site_var, text)

        before_empty_import_cleanup = text
        text = re.sub(r'(?m)^[ \t]*@import[ \t]+["\'][ \t]*["\'][ \t]*;?[ \t]*\r?\n?', "", text)
        if text != before_empty_import_cleanup:
            replacements.append('remove empty @import generated from unresolved template')

        # Leave unresolved template expressions intact. If Dart Sass still
        # cannot compile the entry, the fixture remains a real setup failure
        # rather than being hidden by deleting project content.

        if text != original:
            entry.write_text(text, encoding="utf-8", errors="surrogateescape")
            rel = entry.relative_to(source).as_posix()
            detail = "; ".join(replacements[:5])
            if len(replacements) > 5:
                detail += f" (+{len(replacements)-5} more)"
            setup.append(f"resolve SSG templates in {rel}: {detail}")
    return setup


def materialize_sass_like_css_partials(source: Path) -> list[str]:
    """Some legacy toolchains feed .css files through Sass import resolution."""
    setup: list[str] = []
    sass_markers = ("@mixin", "@function", "@include", "@extend", "$")
    for css in sorted(source.rglob("*.css"), key=lambda p: p.relative_to(source).as_posix()):
        if is_excluded(css, source):
            continue
        if not css.name.startswith("_"):
            continue
        scss = css.with_suffix(".scss")
        if scss.exists():
            continue
        try:
            text = css.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        if not any(marker in text for marker in sass_markers):
            continue
        scss.write_text(text, encoding="utf-8", errors="surrogateescape")
        setup.append(f"copy Sass-like CSS partial {css.relative_to(source).as_posix()} -> {scss.relative_to(source).as_posix()}")
    return setup


def resolve_relative_sass_import(base: Path, raw: str) -> list[Path]:
    """Resolve a simple relative Sass import/use/forward to candidate files."""
    if not raw.startswith((".", "..")):
        return []
    target = (base.parent / raw).resolve()
    candidates: list[Path] = []
    if target.suffix in SASS_EXTS:
        candidates.append(target)
        candidates.append(target.with_name("_" + target.name))
    else:
        for ext in SASS_EXTS:
            candidates.append(target.with_suffix(ext))
            candidates.append(target.with_name("_" + target.name).with_suffix(ext))
        candidates.append(target / "index.scss")
        candidates.append(target / "_index.scss")
        candidates.append(target / "index.sass")
        candidates.append(target / "_index.sass")
    return candidates


def sass_needs_node_modules(entries: list[Path], source: Path) -> bool:
    """Return True if the selected entry import graph references node_modules.

    This is intentionally scoped to files reachable from the selected entries.
    Some repositories contain optional theme files with tilde imports next to
    self-contained partials; forcing install for those partial-only runs turns
    obsolete npm metadata into a setup blocker.
    """
    tilde_pat = re.compile(r"@(?:import|use|forward)\s+(?:url\()?\s*(?:[\"']~|~)")
    import_pat = re.compile(r"@(?:import|use|forward)\s+(?:url\()?\s*[\"']([^\"')]+)")
    stack = [entry.resolve() for entry in entries]
    seen: set[str] = set()
    source_resolved = source.resolve()
    while stack:
        f = stack.pop()
        key = f.as_posix()
        if key in seen:
            continue
        seen.add(key)
        try:
            f.relative_to(source_resolved)
        except ValueError:
            continue
        if not f.is_file() or f.suffix not in SASS_EXTS:
            continue
        if is_excluded(f, source_resolved, for_sass=True):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue
        if tilde_pat.search(text):
            return True
        for m in import_pat.finditer(text):
            raw = m.group(1).strip()
            if raw.startswith(("http://", "https://", "url(")):
                continue
            for candidate in resolve_relative_sass_import(f, raw):
                if candidate.exists():
                    stack.append(candidate)
                    break
    return False


def sass_entries_are_self_contained(entries: list[Path], source: Path) -> bool:
    """Return True when selected Sass entries contain no Sass import graph."""
    import_pat = re.compile(r"@(?:import|use|forward)\b")
    source_resolved = source.resolve()
    for entry in entries:
        f = entry.resolve()
        try:
            f.relative_to(source_resolved)
        except ValueError:
            return False
        if not f.is_file() or f.suffix not in SASS_EXTS:
            return False
        try:
            text = f.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            return False
        if import_pat.search(text):
            return False
    return True


def setup_node(entries: list[Path], source: Path) -> tuple[list[Path], list[str], list[str]]:
    roots = package_roots_for_entries(entries, source)
    setup: list[str] = []
    load_paths = [source]
    setup.extend(prepare_generated_sass_partials(source))
    setup.extend(repair_relative_sass_dir_imports(source))
    setup.extend(repair_relative_node_modules_imports(source))
    setup.extend(link_workspace_sass_packages(source))
    for sass_lp in common_sass_load_paths(source):
        load_paths.append(sass_lp)
    for pkg in roots:
        if sass_entries_are_self_contained(entries, source):
            setup.append(f"Sass entries are self-contained; skipping package install in {pkg.relative_to(source).as_posix() or '.'}")
            load_paths.append(pkg)
            for sass_lp in common_sass_load_paths(pkg):
                load_paths.append(sass_lp)
            continue
        cmd = install_command(pkg)
        if shutil.which(cmd[0]) is None:
            if not sass_needs_node_modules(entries, source):
                setup.append(f"{cmd[0]} not available but Sass has no tilde imports; skipping install")
                load_paths.append(pkg)
                for sass_lp in common_sass_load_paths(pkg):
                    load_paths.append(sass_lp)
                continue
            raise RuntimeError(f"missing package manager: {cmd[0]}")
        cp = run(cmd, cwd=pkg, timeout=INSTALL_TIMEOUT)
        setup.append(f"{' '.join(cmd)} in {pkg.relative_to(source).as_posix() or '.'}")
        if cp.returncode != 0 and cmd[:2] == ["npm", "ci"]:
            fallback = ["npm", "install", "--no-audit", "--no-fund"]
            setup.append(f"npm ci failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0 and cmd[0] == "npm" and "ERESOLVE" in (cp.stderr + cp.stdout):
            fallback = ["npm", "install", "--legacy-peer-deps", "--no-audit", "--no-fund"]
            setup.append(f"npm peer resolution failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if (cp.returncode != 0 and cmd[0] == "npm" and
                ("husky" in (cp.stderr + cp.stdout) or " command sh -c " in (cp.stderr + cp.stdout) or "node-sass" in (cp.stderr + cp.stdout) or "PhantomJS" in (cp.stderr + cp.stdout))):
            fallback = ["npm", "install", "--ignore-scripts", "--legacy-peer-deps", "--no-audit", "--no-fund"]
            setup.append(f"npm lifecycle script failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0 and cmd[0] == "pnpm" and "LOCKFILE" in (cp.stderr + cp.stdout):
            fallback = ["pnpm", "install", "--no-frozen-lockfile"]
            setup.append(f"pnpm lockfile incompatible; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0 and cmd[0] == "pnpm" and "ERR_PNPM_LOCKFILE_BREAKING_CHANGE" in (cp.stderr + cp.stdout):
            fallback = ["pnpm", "install", "--force"]
            setup.append(f"pnpm breaking lockfile failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0 and cmd[0] == "yarn" and "frozen-lockfile" in (cp.stderr + cp.stdout):
            fallback = ["yarn", "install", "--no-frozen-lockfile"]
            setup.append(f"yarn frozen lockfile failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0 and cmd[0] == "yarn" and ("node-sass" in (cp.stderr + cp.stdout) or " command failed" in (cp.stderr + cp.stdout)):
            fallback = ["yarn", "install", "--ignore-scripts", "--no-frozen-lockfile"]
            setup.append(f"yarn lifecycle script failed; fallback {' '.join(fallback)} in {pkg.relative_to(source).as_posix() or '.'}")
            cp = run(fallback, cwd=pkg, timeout=INSTALL_TIMEOUT)
        if cp.returncode != 0:
            if not sass_needs_node_modules(entries, source):
                setup.append(f"install failed but Sass has no tilde imports; continuing without node_modules")
                load_paths.append(pkg)
                for sass_lp in common_sass_load_paths(pkg):
                    load_paths.append(sass_lp)
                continue
            raise RuntimeError(f"dependency install failed in {pkg}: {cp.stderr[-4000:] or cp.stdout[-4000:]}")
        load_paths.append(pkg)
        for sass_lp in common_sass_load_paths(pkg):
            load_paths.append(sass_lp)
        nm = pkg / "node_modules"
        if nm.is_dir():
            setup.extend(repair_package_source_indexes(nm))
            load_paths.append(nm)
            load_paths.extend(node_module_sass_load_paths(nm))
        if (pkg / "bower.json").exists() and shutil.which("npx") is not None:
            bower_cmd = ["npx", "--yes", "bower", "install", "--allow-root"]
            bower_cp = run(bower_cmd, cwd=pkg, timeout=INSTALL_TIMEOUT)
            setup.append(f"{' '.join(bower_cmd)} in {pkg.relative_to(source).as_posix() or '.'}")
            if bower_cp.returncode != 0:
                raise RuntimeError(f"bower install failed in {pkg}: {bower_cp.stderr[-4000:] or bower_cp.stdout[-4000:]}")
            bower_components = pkg / "bower_components"
            if bower_components.is_dir():
                load_paths.append(bower_components)
                load_paths.extend(package_collection_sass_load_paths(bower_components))
        for alias, target in simple_aliases_from_config(pkg):
            link = pkg / alias
            if not link.exists():
                link.symlink_to(target, target_is_directory=True)
                setup.append(f"symlink {pkg.relative_to(source).as_posix() or '.'}/{alias} -> {target}")
        for package_name in tilde_packages_in_sass(pkg):
            alias_msg = create_tilde_alias(pkg, package_name)
            if alias_msg:
                prefix = pkg.relative_to(source).as_posix()
                setup.append(f"{alias_msg} in {prefix if prefix != '.' else '.'}")
        for package_name in dollar_packages_in_sass(pkg):
            alias_msg = create_dollar_alias(pkg, package_name)
            if alias_msg:
                prefix = pkg.relative_to(source).as_posix()
                setup.append(f"{alias_msg} in {prefix if prefix != '.' else '.'}")
    source_nm = source / "node_modules"
    if source_nm.is_dir():
        load_paths.append(source_nm)
        load_paths.extend(node_module_sass_load_paths(source_nm))
    for lp in entry_sass_load_paths(entries, source):
        load_paths.append(lp)
    load_paths = dedup_paths(load_paths)
    lp_text = ", ".join(p.relative_to(source).as_posix() if p != source else "source" for p in load_paths)
    setup.append(f"load paths: {lp_text}")
    return load_paths, setup, [p.relative_to(source).as_posix() if p != source else "." for p in roots]


def output_path(out_root: Path, source: Path, entry: Path) -> Path:
    rel = entry.relative_to(source)
    return (out_root / rel).with_suffix(".css")


def compile_entry(cmd_base: list[str], load_paths: list[Path], source: Path, entry: Path, out: Path,
                  *, cwd: Path, timeout_s: int) -> subprocess.CompletedProcess[str]:
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = cmd_base + ["--no-source-map"]
    for lp in load_paths:
        cmd += ["--load-path" if cmd_base[0].endswith("sass") else "-I", str(lp)]
    cmd += [str(entry), str(out)]
    return run(cmd, cwd=cwd, timeout=timeout_s, env={**os.environ, "ZSASS_CSS_CACHE": "0"})


def first_diff(a: str, b: str) -> str:
    import difflib
    return "".join(difflib.unified_diff(a.splitlines(True), b.splitlines(True), fromfile="dart", tofile="zsass", n=3))[:20000]


def zsass_commit() -> str:
    root = repo_root()
    commit = run(["git", "rev-parse", "HEAD"], cwd=root).stdout.strip()
    dirty = run(["git", "status", "--porcelain"], cwd=root).stdout.strip()
    return commit + ("-dirty" if dirty else "")


def dart_sass_version() -> str:
    cp = run(["sass", "--version"])
    return cp.stdout.strip() if cp.returncode == 0 else "unknown"


def migrate_ledger_schema(ledger: Path) -> None:
    rows = load_jsonl(ledger)
    changed = False
    for row in rows:
        if row.get("status") == "pass" and "normalizer_version" not in row:
            row["normalizer_version"] = NORMALIZER_VERSION
            changed = True
    if changed:
        tmp = ledger.with_suffix(".jsonl.tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for row in rows:
                json.dump(row, f, sort_keys=True, ensure_ascii=False)
                f.write("\n")
        tmp.replace(ledger)


def short_commit(value: object) -> str:
    text = str(value or "")
    if text.endswith("-dirty"):
        return text[:12] + "-dirty"
    return text[:12]


def write_summary(compat: Path) -> None:
    ledger = compat / "ledger.jsonl"
    migrate_ledger_schema(ledger)
    rows = [r for r in load_jsonl(ledger) if r.get("status") == "pass"]
    rows.sort(key=lambda r: r.get("checked_at", ""), reverse=True)
    failures = load_jsonl(compat / "failures.jsonl")
    unresolved = [r for r in failures if r.get("status") != "pass"]
    classified = {r.get("full_name") for r in rows if r.get("full_name")} | {r.get("full_name") for r in unresolved if r.get("full_name")}
    core_count = core_suite_count(compat.parent)
    disposable_target = max(COMPAT_TARGET - core_count, 0)
    lines = [
        "# Disposable compatibility summary",
        "",
        f"既存{core_count} suiteは `zig build realworld` の常時対象として固定し、追加分は disposable compatibility として確認後に source repo を削除する。",
        "",
        f"- Core realworld suites: {core_count}",
        f"- Classified disposable repos: {len(classified)} / {disposable_target}",
        f"- Detection inventory coverage: {core_count + len(classified)} / {COMPAT_TARGET}",
        f"- Disposable pass suites: {len(rows)} / {disposable_target}",
        f"- Total compatibility pass coverage: {core_count + len(rows)} / {COMPAT_TARGET}",
        f"- Unresolved disposable failures: {len(unresolved)}",
        f"- Ignored normalized diff kinds: {', '.join(IGNORED_DIFF_KINDS)}",
        f"- Normalizer version: {NORMALIZER_VERSION}",
        "",
        "## Source mix",
        "",
        "| Source | Pass | Failure | Entries |",
        "|---|---:|---:|---:|",
    ]
    source_names = sorted({str(r.get("source_kind") or "github") for r in rows + unresolved})
    for name in source_names:
        pass_rows = [r for r in rows if str(r.get("source_kind") or "github") == name]
        fail_rows = [r for r in unresolved if str(r.get("source_kind") or "github") == name]
        entries = sum(int(r.get("entries_checked") or 0) for r in pass_rows)
        lines.append(f"| {name} | {len(pass_rows)} | {len(fail_rows)} | {entries} |")
    lines += [
        "",
        "## Ledger file",
        "",
        "`compat-disposable/ledger.jsonl`",
        "",
        "## Latest passes",
        "",
        "| Suite | Repo | Commit | Checked entries | Skipped | Setup | zsass commit | Source repo after pass |",
        "|---|---|---:|---:|---:|---|---|---|",
    ]
    for r in rows[:20]:
        setup = ", ".join(r.get("setup", []))
        lines.append(
            f"| `{r.get('suite')}` | {r.get('full_name')} | `{str(r.get('repo_commit',''))[:12]}` | "
            f"{r.get('entries_checked')} | {r.get('entries_skipped')} | {setup} | "
            f"`{short_commit(r.get('zsass_commit'))}` | {'deleted' if r.get('deleted_after_pass') else 'kept'} |"
        )
    if unresolved:
        lines += ["", "## Unresolved failures", "", "| Suite | Class | Entry | Next action |", "|---|---|---|---|"]
        for r in unresolved[-20:]:
            lines.append(f"| `{r.get('suite')}` | {r.get('failure_class')} | `{r.get('entry','')}` | {r.get('next_action','')} |")
    (compat / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_failure(compat: Path, base: dict[str, Any], failure_class: str, entry: str, logs: dict[str, str], next_action: str) -> None:
    rec = dict(base)
    rec.update({
        "status": "failure",
        "failure_class": failure_class,
        "entry": entry,
        "dart_log": logs.get("dart"),
        "zsass_log": logs.get("zsass"),
        "diff": logs.get("diff"),
        "next_action": next_action,
        "normalizer_version": NORMALIZER_VERSION,
    })
    failures_path = compat / "failures.jsonl"
    old_rows = [r for r in load_jsonl(failures_path) if r.get("full_name") != base.get("full_name")]
    failures_path.write_text("".join(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in old_rows), encoding="utf-8")
    ledger_path = compat / "ledger.jsonl"
    old_passes = [r for r in load_jsonl(ledger_path) if r.get("full_name") != base.get("full_name")]
    ledger_path.write_text("".join(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in old_passes), encoding="utf-8")
    append_jsonl(failures_path, rec)
    write_summary(compat)


def check_repo(args: argparse.Namespace) -> int:
    fixture_root = Path(args.fixture_root).resolve()
    compat, work_root, runs_root = ensure_dirs(fixture_root)
    explicit_sources = sum(1 for value in (args.repo, args.repo_url, args.archive_url) if value)
    if explicit_sources > 1:
        raise SystemExit("pass only one of --repo, --repo-url, or --archive-url")
    if args.archive_url:
        source_full_name = archive_id_from_url(args.archive_url)
    elif args.repo_url:
        source_full_name = repo_id_from_url(args.repo_url)
    else:
        source_full_name = pick_candidate(fixture_root, args.repo)
    ensure_repo_allowed(source_full_name)
    if args.source_id:
        ensure_repo_allowed(args.source_id)
    full_name = args.source_id or source_full_name
    source_core_name = core_full_name_identity(source_full_name)
    if source_core_name in imported_core_full_names(fixture_root):
        raise SystemExit(f"refusing to count existing core realworld suite as disposable: {source_full_name}")
    suite = suite_name(full_name)
    run_root = runs_root / suite
    if run_root.exists():
        shutil.rmtree(run_root)
    (run_root / "logs").mkdir(parents=True, exist_ok=True)
    dart_root = run_root / "dart"
    zsass_root = run_root / "zsass"
    dart_root.mkdir(parents=True)
    zsass_root.mkdir(parents=True)

    base: dict[str, Any] = {
        "checked_at": utc_now(),
        "full_name": full_name,
        "suite": suite,
        "repo_url": args.repo_url or (None if args.archive_url else f"https://github.com/{source_full_name}"),
        "archive_url": args.archive_url,
        "source_kind": source_kind(args),
        "source_id": args.source_id or full_name,
        "package_name": args.package_name,
        "package_version": args.package_version,
        "dart_sass_version": dart_sass_version(),
        "zsass_commit": zsass_commit(),
    }
    source: Path | None = None
    try:
        if args.archive_url:
            source, archive_meta = fetch_archive_source(args.archive_url, suite, work_root)
            base.update(archive_meta)
        else:
            source, repo_url, commit = clone_repo_url(args.repo_url, suite, work_root) if args.repo_url else clone_repo(source_full_name, suite, work_root)
            base["repo_url"] = repo_url
            base["repo_commit"] = commit
        entries = discover_entries(source, args.entry)
        entry_overrides = list(args.entry)
        if entry_overrides:
            base["entry_overrides"] = entry_overrides
        if not entries:
            write_failure(compat, base, "setup_blocked", "", {}, "no Sass entrypoints discovered")
            return 2
        (run_root / "entries.txt").write_text("\n".join(e.relative_to(source).as_posix() for e in entries) + "\n", encoding="utf-8")
        if len(entries) > args.max_entries:
            write_failure(compat, base, "setup_blocked", "", {}, f"{len(entries)} entries exceeds --max-entries {args.max_entries}; rerun with override")
            return 2
        load_paths, setup, _ = setup_node(entries, source)
        setup.extend(resolve_vendor_node_modules(source))
        setup.extend(materialize_sass_like_css_partials(source))
        setup.extend(strip_jekyll_front_matter(entries, source))
        setup.extend(resolve_ssg_templates(entries, source))
        base["setup"] = setup
        base["entries_discovered"] = len(entries)
        base["entries_checked"] = len(entries)
        base["entries_skipped"] = 0
        base["entry_list_sha256"] = sha256_text("\n".join(e.relative_to(source).as_posix() for e in entries) + "\n")
        statuses: list[dict[str, str]] = []
        zsass_bin = repo_root() / "zig-out" / "bin" / "zsass"
        if not zsass_bin.exists():
            raise RuntimeError(f"zsass binary not found: {zsass_bin}; run zig build first")
        for entry in entries:
            rel = entry.relative_to(source).as_posix()
            dart_out = output_path(dart_root, source, entry)
            zsass_out = output_path(zsass_root, source, entry)
            dart_cp = compile_entry(["sass"], load_paths, source, entry, dart_out, cwd=source, timeout_s=args.timeout)
            if dart_cp.returncode != 0:
                log = run_root / "logs" / (rel.replace("/", "__") + ".dart.log")
                log.write_text(dart_cp.stdout + dart_cp.stderr, encoding="utf-8", errors="surrogateescape")
                write_failure(compat, base, "dart_error_after_setup", rel, {"dart": str(log)}, "refine project setup or exclude with exact Dart failure reason")
                return 2
            zsass_cp = compile_entry([str(zsass_bin)], load_paths, source, entry, zsass_out, cwd=source, timeout_s=args.timeout)
            if zsass_cp.returncode != 0:
                log = run_root / "logs" / (rel.replace("/", "__") + ".zsass.log")
                log.write_text(zsass_cp.stdout + zsass_cp.stderr, encoding="utf-8", errors="surrogateescape")
                write_failure(compat, base, "zsass_compile_error", rel, {"zsass": str(log)}, "reduce failure and fix zsass")
                return 3
            dart_css = dart_out.read_text(encoding="utf-8", errors="surrogateescape")
            zsass_css = zsass_out.read_text(encoding="utf-8", errors="surrogateescape")
            if dart_css != zsass_css:
                raw_diff = run_root / "logs" / (rel.replace("/", "__") + ".raw.diff")
                raw_diff.write_text(first_diff(dart_css, zsass_css), encoding="utf-8", errors="surrogateescape")
                logs = {"raw_diff": str(raw_diff)}
                dart_norm = normalize_css(dart_css)
                zsass_norm = normalize_css(zsass_css)
                if dart_norm == zsass_norm:
                    logs["normalized_equal"] = "true"
                    write_failure(compat, base, "css_diff", rel, logs, "raw CSS differs; normalized equality is reporting-only")
                    return 3
                norm_diff = run_root / "logs" / (rel.replace("/", "__") + ".normalized.diff")
                norm_diff.write_text(first_diff(dart_norm, zsass_norm), encoding="utf-8", errors="surrogateescape")
                logs["normalized_diff"] = str(norm_diff)
                write_failure(compat, base, "css_diff", rel, logs, "analyze raw CSS diff and fix zsass")
                return 3
            statuses.append({"entry": rel, "status": "pass"})
        (run_root / "statuses.json").write_text(json.dumps(statuses, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        # A passing rerun supersedes earlier setup/zsass failure records for this repo.
        failures_path = compat / "failures.jsonl"
        old_failures = [r for r in load_jsonl(failures_path) if r.get("full_name") != full_name]
        failures_path.write_text("".join(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in old_failures), encoding="utf-8")
        rec = dict(base)
        rec.update({
            "status": "pass",
            "entries_dart_success": len(entries),
            "normalized_equal_entries": 0,
            "ignored_diff_kinds": IGNORED_DIFF_KINDS,
            "normalizer_version": NORMALIZER_VERSION,
            "dart_output_tree_sha256": tree_hash(dart_root),
            "zsass_output_tree_sha256": tree_hash(zsass_root),
            "deleted_after_pass": False,
        })
        suite_work = work_root / suite
        shutil.rmtree(suite_work)
        rec["deleted_after_pass"] = True
        ledger_path = compat / "ledger.jsonl"
        old_passes = [r for r in load_jsonl(ledger_path) if r.get("full_name") != full_name]
        with ledger_path.open("w", encoding="utf-8") as f:
            for row in old_passes:
                json.dump(row, f, sort_keys=True, ensure_ascii=False)
                f.write("\n")
            json.dump(rec, f, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        write_summary(compat)
        print(f"PASS {suite}: {len(entries)} entries, skip 0")
        return 0
    except subprocess.TimeoutExpired as e:
        logs = {"dart": None, "zsass": None}
        write_failure(compat, base, "timeout_or_hang", "", logs, f"command timed out after {e.timeout}s; reproduce with timeout")
        return 4
    except Exception as e:
        write_failure(compat, base, "setup_blocked", "", {}, str(e))
        return 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fixture-root", default=str(fixture_root_default()))
    ap.add_argument("--repo", help="GitHub repository full name, e.g. owner/repo. Defaults to next fixture candidate.")
    ap.add_argument("--repo-url", help="Explicit non-GitHub git clone URL to check as disposable compatibility input.")
    ap.add_argument("--archive-url", help="Explicit zip/tar archive URL to check as disposable compatibility input.")
    ap.add_argument("--source-id", help="Stable source identifier for archive inputs, e.g. npm/package@1.2.3.")
    ap.add_argument("--source-kind", help="Source bucket for summary rotation, e.g. npm, wordpress, drupal, gitlab.")
    ap.add_argument("--package-name", help="Package/theme name for archive inputs.")
    ap.add_argument("--package-version", help="Package/theme version for archive inputs.")
    ap.add_argument("--entry", action="append", default=[], help="Entry path relative to cloned repo source. Repeatable.")
    ap.add_argument("--max-entries", type=int, default=200, help="Safety cap; use --entry for huge repos.")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="Per compiler invocation timeout in seconds.")
    ap.add_argument("--allow-normalized-pass", action="store_true", help="Deprecated no-op. Raw CSS mismatches always fail; normalized equality is reporting-only.")
    args = ap.parse_args()
    return check_repo(args)


if __name__ == "__main__":
    raise SystemExit(main())
