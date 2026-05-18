//!Rule IR -- append-only intermediate between VM and Writer (Stage 1a skeleton).

const std = @import("std");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const selector_mod = @import("../selector/selector.zig");
const extend_mod = @import("../selector/extend.zig");
const color_mod = @import("../color/color.zig");
const ir_validate = @import("validate.zig");
const selector_helpers_mod = @import("../selector/selector_helpers.zig");
const placeholder_prune_mod = @import("../selector/placeholder_prune.zig");
const media_prelude = @import("../resolve/media_prelude.zig");
const css_utils = @import("../runtime/css_utils.zig");
const value_format = @import("../runtime/value_format.zig");
const calc_utils = @import("../runtime/calc_utils.zig");
const perf = @import("../runtime/perf.zig");
const source_map_mod = @import("source_map.zig");
const zsass_io = @import("../runtime/io.zig");
const opcode_mod = @import("opcode.zig");
const media_prelude_preserve_case_marker = "\x01zsass-media-preserve:";
const calc_arg_marker = calc_utils.calc_arg_marker;
const calc_interp_marker = calc_utils.calc_interp_marker;
const literal_decl_marker = "\x01zsass-literal-decl:";
const interp_decl_marker = "\x01zsass-interp-decl:";
const calc_interp_preserve_start = calc_utils.calc_interp_preserve_start;
const calc_interp_preserve_end = calc_utils.calc_interp_preserve_end;
const calc_interp_preserve_slash = calc_utils.calc_interp_preserve_slash;

const PseudoArg = struct {
    arg: []const u8,
    end: usize,
};

const PrefixPseudoArg = struct {
    prefix: []const u8,
    arg: []const u8,
};

fn readSelectorPseudoArgAt(sel: []const u8, pos: usize, name: []const u8) ?PseudoArg {
    if (pos + 2 + name.len > sel.len) return null;
    if (sel[pos] != ':') return null;
    if (!std.ascii.eqlIgnoreCase(sel[pos + 1 .. pos + 1 + name.len], name)) return null;
    const open = pos + 1 + name.len;
    if (open >= sel.len or sel[open] != '(') return null;
    var depth: usize = 1;
    var i = open + 1;
    while (i < sel.len) : (i += 1) {
        switch (sel[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return .{ .arg = sel[open + 1 .. i], .end = i + 1 };
                }
            },
            else => {},
        }
    }
    return null;
}

fn splitFinalSelectorPseudo(sel: []const u8, name: []const u8) ?PrefixPseudoArg {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < sel.len) : (i += 1) {
        switch (sel[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                if (depth != 0) continue;
                const parsed = readSelectorPseudoArgAt(sel, i, name) orelse continue;
                if (parsed.end != sel.len) continue;
                return .{ .prefix = sel[0..i], .arg = parsed.arg };
            },
            else => {},
        }
    }
    return null;
}

fn appendNestedNotHasExpected(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    a: ?[]const u8,
    b: []const u8,
    ab: []const u8,
    mode: enum { outer_not, compound_not, has },
) !void {
    const c = try std.fmt.allocPrint(allocator, ":not({s}):not({s}:not({s}))", .{ ab, b, ab });
    defer allocator.free(c);
    const d = try std.fmt.allocPrint(allocator, "{s}:has({s})", .{ b, c });
    defer allocator.free(d);
    const e = try std.fmt.allocPrint(allocator, "{s}:not({s}):not({s})", .{ b, ab, d });
    defer allocator.free(e);
    const f = try std.fmt.allocPrint(allocator, "{s}:has(:not({s}):not({s}):not({s}))", .{ b, ab, d, e });
    defer allocator.free(f);
    const g = try std.fmt.allocPrint(allocator, "{s}:not({s}):not({s}):not({s}):not({s})", .{ b, ab, d, e, f });
    defer allocator.free(g);

    const rendered = switch (mode) {
        .outer_not => try std.fmt.allocPrint(allocator, ":not({s}):not(:not({s}):not({s}))", .{ a.?, ab, d }),
        .compound_not => try std.fmt.allocPrint(allocator, ":not({s}):not({s}):not({s}):not({s}):not({s})", .{ ab, d, e, f, g }),
        .has => try std.fmt.allocPrint(allocator, ":has(:not({s}):not({s}):not({s}):not({s}):not({s}))", .{ ab, d, e, f, g }),
    };
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn normalizeNestedNotHasExtendSelector(allocator: std.mem.Allocator, sel: []const u8) !?[]const u8 {
    const first = readSelectorPseudoArgAt(sel, 0, "not") orelse {
        const has_outer = readSelectorPseudoArgAt(sel, 0, "has") orelse return null;
        if (has_outer.end != sel.len) return null;
        const has_inner_first = readSelectorPseudoArgAt(has_outer.arg, 0, "not") orelse return null;
        const ab = has_inner_first.arg;
        if (has_inner_first.end >= has_outer.arg.len) return null;
        const has_inner_second = readSelectorPseudoArgAt(has_outer.arg, has_inner_first.end, "not") orelse return null;
        if (has_inner_second.end != has_outer.arg.len) return null;
        const d_actual = splitFinalSelectorPseudo(has_inner_second.arg, "has") orelse return null;
        const nested_not = readSelectorPseudoArgAt(d_actual.arg, 0, "not") orelse return null;
        if (nested_not.end != d_actual.arg.len) return null;
        const b_ab = splitFinalSelectorPseudo(nested_not.arg, "not") orelse return null;
        if (!std.mem.eql(u8, b_ab.prefix, d_actual.prefix)) return null;
        if (!std.mem.eql(u8, b_ab.arg, ab)) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try appendNestedNotHasExpected(allocator, &out, null, d_actual.prefix, ab, .has);
        return try out.toOwnedSlice(allocator);
    };
    if (first.end >= sel.len) return null;
    const second = readSelectorPseudoArgAt(sel, first.end, "not") orelse return null;
    if (second.end != sel.len) return null;

    if (readSelectorPseudoArgAt(second.arg, 0, "has")) |has_arg| {
        if (has_arg.end != second.arg.len) return null;
        const nested_not = readSelectorPseudoArgAt(has_arg.arg, 0, "not") orelse return null;
        if (nested_not.end != has_arg.arg.len) return null;
        const b_ab = splitFinalSelectorPseudo(nested_not.arg, "not") orelse return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try appendNestedNotHasExpected(allocator, &out, first.arg, b_ab.prefix, b_ab.arg, .outer_not);
        return try out.toOwnedSlice(allocator);
    }

    const d_actual = splitFinalSelectorPseudo(second.arg, "has") orelse return null;
    const nested_not = readSelectorPseudoArgAt(d_actual.arg, 0, "not") orelse return null;
    if (nested_not.end != d_actual.arg.len) return null;
    const b_ab = splitFinalSelectorPseudo(nested_not.arg, "not") orelse return null;
    if (!std.mem.eql(u8, b_ab.prefix, d_actual.prefix)) return null;
    if (!std.mem.eql(u8, b_ab.arg, first.arg)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendNestedNotHasExpected(allocator, &out, null, d_actual.prefix, first.arg, .compound_not);
    return try out.toOwnedSlice(allocator);
}

fn ruleIrStderrPrint(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("ZSASS_RULE_IR_DEBUG") == null) return;
    var buf: [8192]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var w = err_file.writer(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

pub const OutputStyle = enum { expanded, compressed };

/// Options for `writeToWithSourceMap`. `source_map_url_override` is only consumed by the CLI driver
/// when appending the `/*# sourceMappingURL=... */` trailer; it is ignored inside this function.
pub const WriteToWithSourceMapOpts = struct {
    source_map_url_override: ?[]const u8 = null,
    source_map_urls_mode: source_map_mod.SourceMapUrlsMode = .relative,
    emit_charset: bool = true,
    /// Absolute path of the directory containing the emitted CSS (used for `sources` when mode is relative).
    source_map_output_dir_abs: ?[]const u8 = null,
};

fn sourcePathForSourceMap(
    arena: std.mem.Allocator,
    urls_mode: source_map_mod.SourceMapUrlsMode,
    raw: []const u8,
    output_dir_abs: ?[]const u8,
) ![]const u8 {
    const effective: []const u8 = if (raw.len == 0) "<stdin>" else raw;
    switch (urls_mode) {
        .relative => {
            if (output_dir_abs) |out_dir| {
                if (std.mem.eql(u8, effective, "<stdin>")) {
                    return try arena.dupe(u8, "<stdin>");
                }
                const src_abs = if (std.fs.path.isAbsolute(effective)) blk: {
                    break :blk zsass_io.realPathAlloc(std.Io.Dir.cwd(), effective, arena) catch try std.fs.path.resolve(arena, &.{effective});
                } else blk: {
                    const cwd = try zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", arena);
                    break :blk try std.fs.path.resolve(arena, &.{ cwd, effective });
                };
                const cwd_for_rel = try zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", arena);
                return try std.fs.path.relativePosix(arena, cwd_for_rel, out_dir, src_abs);
            }
            return try arena.dupe(u8, effective);
        },
        .absolute => {
            const abs_path: []const u8 = if (std.mem.eql(u8, effective, "<stdin>")) blk: {
                const cwd = try zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", arena);
                break :blk try std.fmt.allocPrint(arena, "{s}/<stdin>", .{cwd});
            } else if (std.fs.path.isAbsolute(effective)) blk: {
                break :blk zsass_io.realPathAlloc(std.Io.Dir.cwd(), effective, arena) catch |err| switch (err) {
                    error.FileNotFound => try std.fs.path.resolve(arena, &.{effective}),
                    else => |e| return e,
                };
            } else blk: {
                const cwd = try zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", arena);
                break :blk try std.fs.path.resolve(arena, &.{ cwd, effective });
            };
            if (std.mem.startsWith(u8, abs_path, "/")) {
                return try std.fmt.allocPrint(arena, "file://{s}", .{abs_path});
            }
            return try std.fmt.allocPrint(arena, "file:///{s}", .{abs_path});
        },
    }
}

pub const Span = struct {
    start: u32,
    end: u32,
    file_id: u32 = 0,
};

pub const NodeKind = enum(u8) {
    rule_begin,
    rule_end,
    decl,
    decl_raw,
    at_rule_simple,
    at_rule_begin,
    at_rule_end,
    comment,
    /// Top-level stmt boundary marker (does not appear in output). Just before the next rule_begin / at_rule_begin
    /// A composite marker that the writer interprets as a signal to insert a blank line.
    stmt_gap,
    /// Composite marker that maintains empty lines per group in loops/mixin expansions, etc.
    group_boundary,
    /// stripped sourceMappingURL/sourceURL Blank line marker left by comment.
    sourcemap_gap,
    /// Top-level blocks that were first converted to CSS bytes using backpressure.
    /// The writer outputs it as is as a body chunk that has already been rendered.
    stream_chunk,
};

pub const Node = struct {
    kind: NodeKind,
    payload: u32, // offset into `extra`
    source_start: u32,
    source_end: u32,

    comptime {
        std.debug.assert(@sizeOf(Node) == 16);
    }
};

pub const ExtendEdge = struct {
    extending_selector: InternId,
    target_selector: InternId,
    optional: bool,
    is_placeholder: bool,
    /// An edge that duplicates an existing edge for another tag with `registerVisibleLoadCssModule` is
    /// `true`. This edge is excluded from being replayed (replay = replay prohibited), and the number of edges is
    /// Prevent exponential expansion from duplicated visible-load edges.
    is_replayed: bool = false,
    source_module: u32 = 0,
    target_module: u32 = 0,
    relation_id: u32 = std.math.maxInt(u32),
    relation_order: ?u32 = null,
    relation_branch_index: ?u32 = null,
    relation_branch_leading_newline: bool = false,
    module_group_start_order: ?u32 = null,
};

const FlushedChunk = struct {
    css: []const u8,
    needs_charset: bool,
    /// flush range up to inline trailing comment (comment on the same line as `}` above source)
    /// True if it contains. writer is `prev_visible_is_comment` immediately after stream_chunk
    // Set /// to suppress the blank before the next visible (treated as a ``trailing comment'' like official Sass CLI).
    ends_with_inline_comment: bool = false,
    /// True if the last block of flush range ended with at_rule_end (`}` of at-rule block).
    /// Writer sets `prev_visible_is_at_rule_block` immediately after stream_chunk and continues immediately after
    /// rule/at-rule/stream_chunk Suppress the previous blank with the same rule as immediately after at-rule block
    /// Observed with clean-room CLI repros for consecutive at-rule blocks and for
    /// `@font-face {}` immediately followed by a style rule.
    ends_with_at_rule_block: bool = false,
};

pub const at_root_bubble_media_mask: u8 = 1 << 0;
pub const at_root_bubble_supports_mask: u8 = 1 << 1;
pub const at_root_bubble_layer_mask: u8 = 1 << 2;

fn renderedNeedsCharset(text: []const u8) bool {
    for (text) |c| {
        if (c >= 0x80) return true;
    }
    return false;
}

const isPrivateUseCodePoint = css_utils.isPrivateUseCodePoint;

fn renderedNeedsCharsetExpandedDeclValue(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch return true;
        if (i + seq_len > text.len) return true;
        const slice = text[i .. i + seq_len];
        if (!std.unicode.utf8ValidateSlice(slice)) return true;
        const code_point = std.unicode.utf8Decode(slice) catch return true;
        if (!isPrivateUseCodePoint(code_point)) return true;
        i += seq_len;
    }
    return false;
}

fn renderedDeclValueNeedsCharset(text: []const u8, output_style: OutputStyle) bool {
    return switch (output_style) {
        .compressed => renderedNeedsCharset(text),
        .expanded => renderedNeedsCharsetExpandedDeclValue(text),
    };
}

fn escapeExpandedDeclPrivateUseCodePoints(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var needs_change = false;
    var scan: usize = 0;
    while (scan < text.len) {
        const b = text[scan];
        if (b < 0x80) {
            scan += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            scan += 1;
            continue;
        };
        if (scan + seq_len > text.len) break;
        const slice = text[scan .. scan + seq_len];
        if (!std.unicode.utf8ValidateSlice(slice)) {
            scan += 1;
            continue;
        }
        const code_point = std.unicode.utf8Decode(slice) catch {
            scan += seq_len;
            continue;
        };
        if (isPrivateUseCodePoint(code_point)) {
            needs_change = true;
            break;
        }
        scan += seq_len;
    }
    if (!needs_change) return text;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.append(allocator, b);
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            try out.appendSlice(allocator, text[i..]);
            break;
        }
        const slice = text[i .. i + seq_len];
        if (!std.unicode.utf8ValidateSlice(slice)) {
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        const code_point = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(allocator, slice);
            i += seq_len;
            continue;
        };
        if (isPrivateUseCodePoint(code_point)) {
            var buf: [16]u8 = undefined;
            const escaped = std.fmt.bufPrint(&buf, "\\{x}", .{code_point}) catch |err| {
                std.debug.panic("private-use escape formatting failed: {s}", .{@errorName(err)});
            };
            try out.appendSlice(allocator, escaped);
        } else {
            try out.appendSlice(allocator, slice);
        }
        i += seq_len;
    }
    return try out.toOwnedSlice(allocator);
}

fn isConditionalAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "media") or
        std.mem.eql(u8, raw, "supports") or
        std.mem.eql(u8, raw, "layer") or
        std.mem.eql(u8, raw, "container");
}

fn isSupportsAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "supports");
}

fn isMediaAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "media");
}

/// Bubbled out from parent style_rule like @keyframes / @font-face / @property
/// "Terminal at-rule" (an at-rule with block without a selector). official Sass CLI uses these
/// When hoisting outside of parent, do not insert blank between before hoist (parent rule_end),
/// Keep a blank between after hoist (next sibling rule) (if there is a blank on the source side).
/// Decision to apply the same blank retention/suppression as @media (`isMediaAtRuleName`).
pub fn isBubblingTerminalAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "keyframes") or
        std.mem.eql(u8, raw, "-webkit-keyframes") or
        std.mem.eql(u8, raw, "-moz-keyframes") or
        std.mem.eql(u8, raw, "-o-keyframes") or
        std.mem.eql(u8, raw, "-ms-keyframes") or
        std.mem.eql(u8, raw, "font-face") or
        std.mem.eql(u8, raw, "property");
}

pub fn isKeyframesAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "keyframes") or
        std.mem.eql(u8, raw, "-webkit-keyframes") or
        std.mem.eql(u8, raw, "-moz-keyframes") or
        std.mem.eql(u8, raw, "-o-keyframes") or
        std.mem.eql(u8, raw, "-ms-keyframes");
}

fn mediaPreludePreserveCase(text: []const u8) bool {
    return std.mem.startsWith(u8, text, media_prelude_preserve_case_marker);
}

fn stripMediaPreludePreserveCaseMarker(text: []const u8) []const u8 {
    if (mediaPreludePreserveCase(text)) return text[media_prelude_preserve_case_marker.len..];
    return text;
}

fn isImportAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "import");
}

fn isCharsetAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.mem.eql(u8, raw, "charset");
}

fn isRuleIRGroupSeparatorKind(kind: NodeKind) bool {
    return switch (kind) {
        .stmt_gap, .group_boundary, .sourcemap_gap => true,
        else => false,
    };
}

fn findMatchingParenInDeclValue(text: []const u8, open_idx: usize) ?usize {
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = open_idx;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

inline fn isDeclCalcIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn hasNestedCalcInDeclValue(raw: []const u8) bool {
    var pos: usize = 0;
    while (pos + 5 <= raw.len) : (pos += 1) {
        if (!std.ascii.eqlIgnoreCase(raw[pos .. pos + 4], "calc") or raw[pos + 4] != '(') continue;
        if (pos > 0 and isDeclCalcIdentChar(raw[pos - 1])) continue;
        const close = findMatchingParenInDeclValue(raw, pos + 4) orelse continue;
        const inner = raw[pos + 5 .. close];
        if (hasAnyNestedCalc(inner)) return true;
        pos = close;
    }
    return false;
}

fn normalizeCalcTrailingOperatorParens(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, calc_interp_preserve_start)) |marker_pos| {
        const body_start = marker_pos + calc_interp_preserve_start.len;
        if (std.mem.indexOf(u8, trimmed[body_start..], calc_interp_preserve_end)) |end_rel| {
            const body_end = body_start + end_rel;
            const body = trimmed[body_start..body_end];
            if (body.len != 0) {
                const tail = body[body.len - 1];
                if (tail == '*' or tail == '/') {
                    return try std.fmt.allocPrint(allocator, "calc(({s}))", .{body});
                }
            }
        }
    }
    if (trimmed.len < 7 or !std.ascii.eqlIgnoreCase(trimmed[0..4], "calc") or trimmed[4] != '(' or trimmed[trimmed.len - 1] != ')') return null;
    const close = findMatchingParenInDeclValue(trimmed, 4) orelse return null;
    if (close != trimmed.len - 1) return null;
    const inner = std.mem.trim(u8, trimmed[5..close], " \t\r\n");
    if (inner.len == 0 or (inner[0] == '(' and inner[inner.len - 1] == ')')) return null;
    const tail = inner[inner.len - 1];
    if (tail != '*' and tail != '/') return null;
    return try std.fmt.allocPrint(allocator, "calc(({s}))", .{inner});
}

fn stripCalcDeclMarker(text: []const u8) []const u8 {
    var current = text;
    while (true) {
        if (std.mem.startsWith(u8, current, calc_arg_marker)) {
            current = current[calc_arg_marker.len..];
            continue;
        }
        if (std.mem.startsWith(u8, current, calc_interp_marker)) {
            current = current[calc_interp_marker.len..];
            continue;
        }
        if (std.mem.startsWith(u8, current, interp_decl_marker)) {
            current = current[interp_decl_marker.len..];
            continue;
        }
        return current;
    }
}

fn isMarkedCalcInterpolationDecl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, calc_interp_marker) or
        std.mem.startsWith(u8, text, interp_decl_marker);
}

fn stripLiteralDeclMarker(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, literal_decl_marker)) return text[literal_decl_marker.len..];
    return text;
}

fn stripInterpDeclMarker(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, interp_decl_marker)) return text[interp_decl_marker.len..];
    return text;
}

fn declarationValueEmptyAfterLeadingMarkers(text: []const u8) bool {
    var current = text;
    while (true) {
        const stripped = stripLiteralDeclMarker(stripCalcDeclMarker(current));
        if (stripped.ptr == current.ptr and stripped.len == current.len) break;
        current = stripped;
    }
    return current.len == 0;
}

fn containsLiteralDeclMarker(text: []const u8) bool {
    return std.mem.find(u8, text, literal_decl_marker) != null or
        std.mem.find(u8, text, "\\1 zsass-literal-decl:") != null;
}

fn startsWithAnyCalcDeclMarker(text: []const u8) ?usize {
    if (std.mem.startsWith(u8, text, calc_arg_marker)) return calc_arg_marker.len;
    if (std.mem.startsWith(u8, text, calc_interp_marker)) return calc_interp_marker.len;
    if (std.mem.startsWith(u8, text, interp_decl_marker)) return interp_decl_marker.len;
    if (std.mem.startsWith(u8, text, "\\1 zsass-calc-arg:")) return "\\1 zsass-calc-arg:".len;
    if (std.mem.startsWith(u8, text, "\\1 zsass-calc-interp:")) return "\\1 zsass-calc-interp:".len;
    if (std.mem.startsWith(u8, text, "\\1 zsass-interp-decl:")) return "\\1 zsass-interp-decl:".len;
    return null;
}

fn containsCalcDeclMarker(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (startsWithAnyCalcDeclMarker(text[i..]) != null) return true;
    }
    return false;
}

fn stripAllCalcDeclMarkers(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (!containsCalcDeclMarker(text)) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (startsWithAnyCalcDeclMarker(text[i..])) |marker_len| {
            i += marker_len;
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn stripAllLiteralDeclMarkers(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (!containsLiteralDeclMarker(text)) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (i + literal_decl_marker.len <= text.len and std.mem.eql(u8, text[i .. i + literal_decl_marker.len], literal_decl_marker)) {
            i += literal_decl_marker.len;
            continue;
        }
        const escaped_marker = "\\1 zsass-literal-decl:";
        if (i + escaped_marker.len <= text.len and std.mem.eql(u8, text[i .. i + escaped_marker.len], escaped_marker)) {
            i += escaped_marker.len;
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn stripCalcInterpolationPreserveMarkers(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, calc_interp_preserve_start) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], calc_interp_preserve_start)) {
            const body_start = i + calc_interp_preserve_start.len;
            if (std.mem.indexOf(u8, text[body_start..], calc_interp_preserve_end)) |end_rel| {
                const body_end = body_start + end_rel;
                for (text[body_start..body_end]) |c| {
                    try out.append(allocator, if (c == calc_interp_preserve_slash) '/' else c);
                }
                i = body_end + calc_interp_preserve_end.len;
                continue;
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn hasAnyNestedCalc(expr: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= expr.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(expr[i .. i + 4], "calc") or expr[i + 4] != '(') continue;
        if (i > 0 and isDeclCalcIdentChar(expr[i - 1])) continue;
        const close = findMatchingParenInDeclValue(expr, i + 4) orelse continue;
        _ = close;
        return true;
    }
    return false;
}

fn selectorRawContainsPseudoTarget(selector_raw: []const u8, target_raw: []const u8) bool {
    if (target_raw.len == 0) return false;
    if (std.mem.findScalar(u8, selector_raw, target_raw[0]) == null) return false;
    if (std.mem.find(u8, selector_raw, target_raw) == null) return false;
    if (std.mem.find(u8, selector_raw, ":is(") == null and
        std.mem.find(u8, selector_raw, ":matches(") == null)
    {
        return false;
    }
    return true;
}

fn selectorLooksLikeParentContinuation(prev_selector_raw: []const u8, current_selector_raw: []const u8) bool {
    const prev = std.mem.trim(u8, prev_selector_raw, " \t\r\n");
    const current = std.mem.trim(u8, current_selector_raw, " \t\r\n");
    if (current.len == 0 or prev.len < current.len) return false;
    if (!std.mem.startsWith(u8, prev, current)) return false;
    if (prev.len == current.len) return true;
    return switch (prev[current.len]) {
        ':' => true,
        else => false,
    };
}

/// Same as selectorLooksLikeParentContinuation, but for comma selector lists.
/// Placeholder carriers (`%x, .x`) are kept in RuleIR until selector filtering;
/// parent-continuation checks must consider the concrete member, not only the
/// first raw list item.
fn selectorListLooksLikeParentContinuation(prev_selector_raw: []const u8, current_selector_raw: []const u8) bool {
    var start: usize = 0;
    while (start <= prev_selector_raw.len) {
        const end = std.mem.findScalarPos(u8, prev_selector_raw, start, ',') orelse prev_selector_raw.len;
        if (selectorLooksLikeParentContinuation(prev_selector_raw[start..end], current_selector_raw)) return true;
        if (end == prev_selector_raw.len) break;
        start = end + 1;
    }
    return false;
}

/// `.container, // comment\n .container-fluid` etc. in selector raw text
/// `//` / `/* */` Case where comment is mixed in (legacy @import + multiline selector)
// In ///, the selector parser picks up only one selector from the first half, and the subsequent selector
// To avoid the problem of missing ///, remove comment only for extend matching.
/// If there is no comment, return input as is (no allocation required).
fn stripSelectorCommentsForMatching(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "/*") == null and std.mem.find(u8, text, "//") == null) return text;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                try buf.append(allocator, c);
                i += 1;
                try buf.append(allocator, text[i]);
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == '"' or c == '\'') {
            in_string = c;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < text.len) {
            if (text[i + 1] == '*') {
                var saw_newline = false;
                while (buf.items.len > 0 and
                    (buf.items[buf.items.len - 1] == ' ' or
                        buf.items[buf.items.len - 1] == '\t' or
                        buf.items[buf.items.len - 1] == '\n' or
                        buf.items[buf.items.len - 1] == '\r'))
                {
                    const last = buf.items[buf.items.len - 1];
                    if (last == '\n' or last == '\r') saw_newline = true;
                    _ = buf.pop();
                }

                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    if (text[i] == '*' and text[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }

                while (i < text.len and
                    (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r'))
                {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    i += 1;
                }

                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    const next_char = text[i];
                    if (last != '(' and last != '[' and next_char != ')' and next_char != ']' and next_char != ',' and next_char != ':') {
                        try buf.append(allocator, if (saw_newline) '\n' else ' ');
                    }
                }
                continue;
            }

            if (text[i + 1] == '/') {
                var saw_newline = false;
                while (buf.items.len > 0 and
                    (buf.items[buf.items.len - 1] == ' ' or
                        buf.items[buf.items.len - 1] == '\t' or
                        buf.items[buf.items.len - 1] == '\n' or
                        buf.items[buf.items.len - 1] == '\r'))
                {
                    const last = buf.items[buf.items.len - 1];
                    if (last == '\n' or last == '\r') saw_newline = true;
                    _ = buf.pop();
                }

                i += 2;
                while (i < text.len and text[i] != '\n' and text[i] != '\r') i += 1;
                while (i < text.len and
                    (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r'))
                {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    i += 1;
                }

                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    const next_char = text[i];
                    if (last != '(' and last != '[' and next_char != ')' and next_char != ']' and next_char != ',' and next_char != ':') {
                        try buf.append(allocator, if (saw_newline) '\n' else ' ');
                    }
                }
                continue;
            }
        }

        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

pub const SourceLocation = struct {
    source_path: []const u8,
    line_starts: []const u32,
    source_len: u32,
};

pub const RuleIR = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    node_source_files: std.ArrayListUnmanaged(u32) = .empty,
    extra: std.ArrayListUnmanaged(u32) = .empty,
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    extend_edges: std.ArrayListUnmanaged(ExtendEdge) = .empty,
    extend_relation_media: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    /// Borrowed from VM during `runTop()` for cross-module @extend scope checks.
    module_visibility_matrix: []const bool = &.{},
    module_visibility_n: u32 = 0,
    flushed_chunks: std.ArrayListUnmanaged(FlushedChunk) = .empty,
    streaming_enabled: bool = false,
    streaming_threshold_nodes: usize = 0,
    /// Latest visible append (rule_begin / rule_end / decl / decl_raw / at_rule_* / comment /
    /// `nodes.items.len` after stream_chunk). stmt_gap / sourcemap_gap / group_boundary etc.
    /// Not updated in the boundary marker system. Used by the VM to determine trailing-empty-scope detection.
    last_visible_emit_node_count: usize = 0,

    comptime {
        std.debug.assert(@sizeOf(Node) == 16);
    }

    const NodeFlags = struct {
        const suppress_leading_blank: u32 = 1 << 0;
        const suppress_following_stmt_gap_blank: u32 = 1 << 1;
        const bubble_without_media: u32 = 1 << 2;
        const bubble_without_supports: u32 = 1 << 3;
        const bubble_without_layer: u32 = 1 << 4;
        // Flag set at at_rule_begin / at_rule_end of hoisted @media block.
        // writer does not suppress blank (stmt_gap / fallback) after the corresponding at-rule block ends
        // (Equivalent to legacy `preserve_stmt_gap_blank`, lifted from parent style_rule
        // to leave a blank between `@media` and the next sibling rule).
        const preserve_at_rule_block_following_blank: u32 = 1 << 5;
        // ``reopen'' where rule_begin is compiler-synthesized (parent rule is nested inner rule)
        // Flag set when restarting after splitting, or continuing @at-root hoist, etc.).
        // Z10-SAMESEL: adjacent same-selector rule Used for merge determination.
        // 0 for user-written (emit_rule_begin_current immediately after push_selector_scope),
        // 1 only in reopen (emit_rule_begin_current / _maybe without push).
        const origin_reopen: u32 = 1 << 6;
        // rule_begin was emitted within `@at-root` scope (= pushed_at_root_scope
        // Flag to indicate pop_at_root_scope (before). Z10-SAMESEL: @at-root hoisted rule is
        // Can be the same selector as the outer parent rule, but official Sass CLI is a hoisted block
        // Issue the reopen block after returning to the outside as a separate block. prev in merge judgment
        // If it is at_root_hoisted, handle by not merging.
        const origin_at_root_hoisted: u32 = 1 << 7;
        const plain_css_preserve_nested_at_rule: u32 = 1 << 8;
    };

    pub fn init() RuleIR {
        return .{};
    }

    pub fn deinit(self: *RuleIR, allocator: std.mem.Allocator) void {
        for (self.flushed_chunks.items) |chunk| {
            allocator.free(chunk.css);
        }
        for (self.strings.items) |s| {
            if (s.len != 0) allocator.free(s);
        }
        self.flushed_chunks.deinit(allocator);
        self.extend_edges.deinit(allocator);
        self.extend_relation_media.deinit(allocator);
        self.strings.deinit(allocator);
        self.extra.deinit(allocator);
        self.node_source_files.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    pub fn configureStreaming(self: *RuleIR, enabled: bool, threshold_nodes: usize) void {
        self.streaming_enabled = enabled;
        self.streaming_threshold_nodes = threshold_nodes;
    }

    /// `selector_intern`: raw `InternId` bits (`@intFromEnum`).
    /// `nest_depth`: 0 = top-level style rule (previously blanked), >0 = hoisted from parent style rule
    /// nested rule (do not insert blank in front). dart sass's expanded output of the top-level sibling style rule
    /// A 1-word hint to express the behavior of inserting a blank line only in between using flat Rule IR.
    pub fn appendRuleBegin(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        selector_intern: u32,
        nest_depth: u8,
        span: Span,
    ) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        const extend_snapshot: u32 = @intCast(self.extend_edges.items.len);
        try self.extra.appendSlice(allocator, &[_]u32{ selector_intern, nest_depth, 0, extend_snapshot });
        try self.nodes.append(allocator, .{
            .kind = .rule_begin,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn getRuleExtendSnapshotAt(self: *const RuleIR, node_idx: usize) u32 {
        if (node_idx >= self.nodes.items.len) return 0;
        const node = self.nodes.items[node_idx];
        if (node.kind != .rule_begin) return 0;
        const off: usize = node.payload + 3;
        if (off >= self.extra.items.len) return 0;
        return self.extra.items[off];
    }

    pub fn appendRuleEnd(self: *RuleIR, allocator: std.mem.Allocator, span: Span) !void {
        try self.nodes.append(allocator, .{
            .kind = .rule_end,
            .payload = 0,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendDecl(self: *RuleIR, allocator: std.mem.Allocator, prop_intern: u32, value_intern: u32, span: Span) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.append(allocator, prop_intern);
        try self.extra.append(allocator, value_intern);
        try self.nodes.append(allocator, .{
            .kind = .decl,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendDeclRaw(self: *RuleIR, allocator: std.mem.Allocator, prop_intern: u32, rendered_value: []const u8, span: Span) !void {
        const str_idx: u32 = @intCast(self.strings.items.len);
        {
            const owned = try allocator.dupe(u8, rendered_value);
            errdefer allocator.free(owned);
            try self.strings.append(allocator, owned);
        }
        errdefer {
            const s = self.strings.pop() orelse unreachable;
            allocator.free(s);
        }

        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, &[_]u32{ prop_intern, str_idx });
        try self.nodes.append(allocator, .{
            .kind = .decl_raw,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendAtRuleSimple(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        name_intern: InternId,
        prelude_intern: ?InternId,
        span: Span,
    ) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.append(allocator, @intFromEnum(name_intern));
        try self.extra.append(allocator, if (prelude_intern) |p| @intFromEnum(p) else std.math.maxInt(u32));
        try self.extra.append(allocator, 0);
        try self.nodes.append(allocator, .{
            .kind = .at_rule_simple,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendGroupBoundary(self: *RuleIR, allocator: std.mem.Allocator, span: Span) !void {
        try self.nodes.append(allocator, .{
            .kind = .group_boundary,
            .payload = 0,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
    }

    pub fn appendSourcemapGap(self: *RuleIR, allocator: std.mem.Allocator, span: Span) !void {
        try self.nodes.append(allocator, .{
            .kind = .sourcemap_gap,
            .payload = 0,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
    }

    fn currentNestingDepth(self: *const RuleIR) usize {
        var depth: usize = 0;
        for (self.nodes.items) |node| {
            switch (node.kind) {
                .rule_begin, .at_rule_begin => depth += 1,
                .rule_end, .at_rule_end => {
                    if (depth > 0) depth -= 1;
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {},
            }
        }
        return depth;
    }

    fn topLevelImportInsertionIndex(self: *const RuleIR, pool: *InternPool) usize {
        var depth: usize = 0;
        var saw_top_level_import = false;
        for (self.nodes.items, 0..) |node, i| {
            if (depth == 0) {
                switch (node.kind) {
                    .comment, .stmt_gap, .group_boundary, .sourcemap_gap => {
                        if (saw_top_level_import and !self.hasLaterTopLevelImportOrCharset(pool, i + 1)) return i;
                    },
                    .at_rule_simple => {
                        const name_id = self.extra.items[node.payload];
                        const name = pool.get(@enumFromInt(name_id));
                        if (isImportAtRuleName(name) or isCharsetAtRuleName(name)) {
                            saw_top_level_import = true;
                        } else {
                            return i;
                        }
                    },
                    .rule_begin, .at_rule_begin, .decl, .decl_raw, .rule_end, .at_rule_end, .stream_chunk => return i,
                }
            }

            switch (node.kind) {
                .rule_begin, .at_rule_begin => depth += 1,
                .rule_end, .at_rule_end => {
                    if (depth > 0) depth -= 1;
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {},
            }
        }
        return self.nodes.items.len;
    }

    fn hasLaterTopLevelImportOrCharset(self: *const RuleIR, pool: *InternPool, start_idx: usize) bool {
        var depth: usize = 0;
        var i = start_idx;
        while (i < self.nodes.items.len) : (i += 1) {
            const node = self.nodes.items[i];
            if (depth == 0) {
                switch (node.kind) {
                    .comment, .stmt_gap, .group_boundary, .sourcemap_gap => {},
                    .at_rule_simple => {
                        const name_id = self.extra.items[node.payload];
                        const name = pool.get(@enumFromInt(name_id));
                        return isImportAtRuleName(name) or isCharsetAtRuleName(name);
                    },
                    .rule_begin,
                    .at_rule_begin,
                    .decl,
                    .decl_raw,
                    .rule_end,
                    .at_rule_end,
                    .stream_chunk,
                    => return false,
                }
            }

            switch (node.kind) {
                .rule_begin, .at_rule_begin => depth += 1,
                .rule_end, .at_rule_end => {
                    if (depth > 0) depth -= 1;
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {},
            }
        }
        return false;
    }

    fn trailingSameFileTriviaStart(self: *const RuleIR, limit: usize, source_file: u32) usize {
        var i = self.nodes.items.len;
        while (i > limit) {
            if (self.node_source_files.items[i - 1] != source_file) break;
            switch (self.nodes.items[i - 1].kind) {
                .comment, .stmt_gap, .group_boundary, .sourcemap_gap => i -= 1,
                else => break,
            }
        }
        return i;
    }

    pub fn appendAtRuleSimpleMaybeHoisted(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        name_intern: InternId,
        prelude_intern: ?InternId,
        span: Span,
    ) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.append(allocator, @intFromEnum(name_intern));
        try self.extra.append(allocator, if (prelude_intern) |p| @intFromEnum(p) else std.math.maxInt(u32));
        try self.extra.append(allocator, 0);

        const node: Node = .{
            .kind = .at_rule_simple,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        };

        const name = pool.get(name_intern);
        if (isImportAtRuleName(name) and self.currentNestingDepth() == 0) {
            const insert_at = self.topLevelImportInsertionIndex(pool);
            const trailing_trivia_start = self.trailingSameFileTriviaStart(insert_at, span.file_id);
            if (trailing_trivia_start < self.nodes.items.len) {
                var moved_comment_count: usize = 0;
                var scan_idx = trailing_trivia_start;
                while (scan_idx < self.nodes.items.len) : (scan_idx += 1) {
                    if (self.nodes.items[scan_idx].kind == .comment) moved_comment_count += 1;
                }
                if (moved_comment_count != 0) {
                    const moved_comment_nodes = try allocator.alloc(Node, moved_comment_count);
                    defer allocator.free(moved_comment_nodes);
                    const moved_comment_files = try allocator.alloc(u32, moved_comment_count);
                    defer allocator.free(moved_comment_files);

                    const middle_len = self.nodes.items.len - insert_at - moved_comment_count;
                    const middle_nodes = try allocator.alloc(Node, middle_len);
                    defer allocator.free(middle_nodes);
                    const middle_files = try allocator.alloc(u32, middle_len);
                    defer allocator.free(middle_files);

                    var moved_write: usize = 0;
                    var middle_write: usize = 0;
                    scan_idx = insert_at;
                    while (scan_idx < self.nodes.items.len) : (scan_idx += 1) {
                        const move_comment = scan_idx >= trailing_trivia_start and self.nodes.items[scan_idx].kind == .comment;
                        if (move_comment) {
                            moved_comment_nodes[moved_write] = self.nodes.items[scan_idx];
                            moved_comment_files[moved_write] = self.node_source_files.items[scan_idx];
                            moved_write += 1;
                        } else {
                            middle_nodes[middle_write] = self.nodes.items[scan_idx];
                            middle_files[middle_write] = self.node_source_files.items[scan_idx];
                            middle_write += 1;
                        }
                    }

                    std.debug.assert(moved_write == moved_comment_count);
                    std.debug.assert(middle_write == middle_len);

                    self.nodes.items.len = insert_at;
                    self.node_source_files.items.len = insert_at;

                    try self.nodes.appendSlice(allocator, moved_comment_nodes);
                    try self.node_source_files.appendSlice(allocator, moved_comment_files);
                    try self.nodes.append(allocator, node);
                    try self.node_source_files.append(allocator, span.file_id);
                    try self.nodes.appendSlice(allocator, middle_nodes);
                    try self.node_source_files.appendSlice(allocator, middle_files);
                    self.last_visible_emit_node_count = self.nodes.items.len;
                    return;
                }
            }

            try self.nodes.insert(allocator, insert_at, node);
            try self.node_source_files.insert(allocator, insert_at, span.file_id);
            self.last_visible_emit_node_count = self.nodes.items.len;
            return;
        }

        try self.nodes.append(allocator, node);
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendAtRuleBegin(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        name_intern: InternId,
        prelude_intern: ?InternId,
        nest_depth: u8,
        keep_empty_block: bool,
        span: Span,
    ) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, &[_]u32{
            @intFromEnum(name_intern),
            if (prelude_intern) |p| @intFromEnum(p) else std.math.maxInt(u32),
            nest_depth,
            if (keep_empty_block) 1 else 0,
            0,
        });
        try self.nodes.append(allocator, .{
            .kind = .at_rule_begin,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendAtRuleEnd(self: *RuleIR, allocator: std.mem.Allocator, span: Span) !void {
        try self.nodes.append(allocator, .{
            .kind = .at_rule_end,
            .payload = 0,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    pub fn appendStmtGap(self: *RuleIR, allocator: std.mem.Allocator, span: Span) !void {
        try self.nodes.append(allocator, .{
            .kind = .stmt_gap,
            .payload = 0,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
    }

    /// If the source column at `/*` position of Loud comment is unobtained (unit test / span composition)
    /// Sentinel to put into `source_col`. emitCommentNode is source_locations / indent_level
    /// Fall back to the old heuristic based.
    pub const comment_source_col_unknown: u32 = std.math.maxInt(u32);

    pub fn appendComment(self: *RuleIR, allocator: std.mem.Allocator, text_intern: InternId, span: Span) !void {
        try self.appendCommentWithColAndLeading(allocator, text_intern, span, comment_source_col_unknown, false);
    }

    /// `source_col` = source column of `/*` (calculated by resolver based on ast.source).
    /// Even if `cb.module_id` and the actual file are different with @import inline, it will be entered here
    /// col is always the correct file reference (used in emitCommentNode's strip width).
    /// Fallback behavior if sentinel `comment_source_col_unknown` is entered.
    pub fn appendCommentWithCol(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        text_intern: InternId,
        span: Span,
        source_col: u32,
    ) !void {
        try self.appendCommentWithColAndLeading(allocator, text_intern, span, source_col, false);
    }

    /// Flag indicating whether a non-whitespace token exists just before `/*` (in the same line) in addition to `source_col`
    /// Also save (`leading_same_line`). inlineCommentAfter block_end `} /* ... */` etc.
    /// Used for same line determination when parent line_starts lies in @import inline.
    pub fn appendCommentWithColAndLeading(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        text_intern: InternId,
        span: Span,
        source_col: u32,
        leading_same_line: bool,
    ) !void {
        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.append(allocator, @intFromEnum(text_intern));
        try self.extra.append(allocator, source_col);
        try self.extra.append(allocator, if (leading_same_line) 1 else 0);
        try self.nodes.append(allocator, .{
            .kind = .comment,
            .payload = extra_off,
            .source_start = span.start,
            .source_end = span.end,
        });
        try self.node_source_files.append(allocator, span.file_id);
        self.last_visible_emit_node_count = self.nodes.items.len;
    }

    fn nodeFlagsOffset(node: Node) ?usize {
        return switch (node.kind) {
            .at_rule_simple => node.payload + 2,
            .rule_begin => node.payload + 2,
            .at_rule_begin => node.payload + 4,
            else => null,
        };
    }

    pub fn getNodeFlagsAt(self: *const RuleIR, node_idx: usize) u32 {
        if (node_idx >= self.nodes.items.len) return 0;
        const off = nodeFlagsOffset(self.nodes.items[node_idx]) orelse return 0;
        if (off >= self.extra.items.len) return 0;
        return self.extra.items[off];
    }

    pub fn setNodeFlagsAt(self: *RuleIR, node_idx: usize, flags: u32) void {
        if (node_idx >= self.nodes.items.len) return;
        const off = nodeFlagsOffset(self.nodes.items[node_idx]) orelse return;
        if (off >= self.extra.items.len) return;
        self.extra.items[off] = flags;
    }

    pub inline fn getFlagAt(self: *const RuleIR, node_idx: usize, comptime flag: u32) bool {
        return (self.getNodeFlagsAt(node_idx) & flag) != 0;
    }

    pub inline fn setFlagAt(self: *RuleIR, node_idx: usize, comptime flag: u32, enabled: bool) void {
        var flags = self.getNodeFlagsAt(node_idx);
        if (enabled) {
            flags |= flag;
        } else {
            flags &= ~flag;
        }
        self.setNodeFlagsAt(node_idx, flags);
    }

    pub fn getSuppressLeadingBlankAt(self: *const RuleIR, node_idx: usize) bool {
        return self.getFlagAt(node_idx, NodeFlags.suppress_leading_blank);
    }

    pub fn setSuppressLeadingBlankAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.suppress_leading_blank, enabled);
    }

    pub fn getSuppressFollowingStmtGapBlankAt(self: *const RuleIR, node_idx: usize) bool {
        return self.getFlagAt(node_idx, NodeFlags.suppress_following_stmt_gap_blank);
    }

    pub fn setSuppressFollowingStmtGapBlankAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.suppress_following_stmt_gap_blank, enabled);
    }

    pub fn getPreserveAtRuleBlockFollowingBlankAt(self: *const RuleIR, node_idx: usize) bool {
        return self.getFlagAt(node_idx, NodeFlags.preserve_at_rule_block_following_blank);
    }

    pub fn setPreserveAtRuleBlockFollowingBlankAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.preserve_at_rule_block_following_blank, enabled);
    }

    pub fn setPlainCssPreserveNestedAtRuleAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.plain_css_preserve_nested_at_rule, enabled);
    }

    pub fn getOriginReopenAt(self: *const RuleIR, node_idx: usize) bool {
        return self.getFlagAt(node_idx, NodeFlags.origin_reopen);
    }

    pub fn setOriginReopenAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.origin_reopen, enabled);
    }

    pub fn getOriginAtRootHoistedAt(self: *const RuleIR, node_idx: usize) bool {
        return self.getFlagAt(node_idx, NodeFlags.origin_at_root_hoisted);
    }

    pub fn setOriginAtRootHoistedAt(self: *RuleIR, node_idx: usize, enabled: bool) void {
        self.setFlagAt(node_idx, NodeFlags.origin_at_root_hoisted, enabled);
    }

    fn bubbleMaskToNodeFlags(mask: u8) u32 {
        var flags: u32 = 0;
        if ((mask & at_root_bubble_media_mask) != 0) flags |= NodeFlags.bubble_without_media;
        if ((mask & at_root_bubble_supports_mask) != 0) flags |= NodeFlags.bubble_without_supports;
        if ((mask & at_root_bubble_layer_mask) != 0) flags |= NodeFlags.bubble_without_layer;
        return flags;
    }

    fn nodeFlagsToBubbleMask(flags: u32) u8 {
        var mask: u8 = 0;
        if ((flags & NodeFlags.bubble_without_media) != 0) mask |= at_root_bubble_media_mask;
        if ((flags & NodeFlags.bubble_without_supports) != 0) mask |= at_root_bubble_supports_mask;
        if ((flags & NodeFlags.bubble_without_layer) != 0) mask |= at_root_bubble_layer_mask;
        return mask;
    }

    fn getNodeFlagsForNode(self: *const RuleIR, node: Node) u32 {
        const off = nodeFlagsOffset(node) orelse return 0;
        if (off >= self.extra.items.len) return 0;
        return self.extra.items[off];
    }

    fn setNodeFlagsForNode(self: *RuleIR, node: Node, flags: u32) void {
        const off = nodeFlagsOffset(node) orelse return;
        if (off >= self.extra.items.len) return;
        self.extra.items[off] = flags;
    }

    fn clearBubbleMaskForNode(self: *RuleIR, node: Node, mask: u8) void {
        var flags = self.getNodeFlagsForNode(node);
        flags &= ~bubbleMaskToNodeFlags(mask);
        self.setNodeFlagsForNode(node, flags);
    }

    fn nodeHasBubbleMaskForNode(self: *const RuleIR, node: Node, mask: u8) bool {
        return (nodeFlagsToBubbleMask(self.getNodeFlagsForNode(node)) & mask) != 0;
    }

    fn setSuppressLeadingBlankForNode(self: *RuleIR, node: Node, enabled: bool) void {
        var flags = self.getNodeFlagsForNode(node);
        if (enabled) {
            flags |= NodeFlags.suppress_leading_blank;
        } else {
            flags &= ~NodeFlags.suppress_leading_blank;
        }
        self.setNodeFlagsForNode(node, flags);
    }

    fn setPreserveAtRuleBlockFollowingBlankForNode(self: *RuleIR, node: Node, enabled: bool) void {
        var flags = self.getNodeFlagsForNode(node);
        if (enabled) {
            flags |= NodeFlags.preserve_at_rule_block_following_blank;
        } else {
            flags &= ~NodeFlags.preserve_at_rule_block_following_blank;
        }
        self.setNodeFlagsForNode(node, flags);
    }

    pub fn markTopLevelRangeBubbleFlags(self: *RuleIR, start_idx: usize, end_idx: usize, mask: u8) void {
        if (mask == 0 or start_idx >= end_idx or end_idx > self.nodes.items.len) return;
        const bubble_flags = bubbleMaskToNodeFlags(mask);
        var i = start_idx;
        while (i < end_idx) {
            const item_end = self.topLevelItemEnd(i) catch return;
            if (i >= end_idx or item_end > end_idx) return;
            switch (self.nodes.items[i].kind) {
                .rule_begin, .at_rule_begin, .at_rule_simple => {
                    var flags = self.getNodeFlagsAt(i);
                    flags |= bubble_flags;
                    self.setNodeFlagsAt(i, flags);
                },
                else => {},
            }
            i = item_end;
        }
    }

    pub fn addBubbleMaskAt(self: *RuleIR, node_idx: usize, mask: u8) void {
        if (mask == 0 or node_idx >= self.nodes.items.len) return;
        var flags = self.getNodeFlagsAt(node_idx);
        flags |= bubbleMaskToNodeFlags(mask);
        self.setNodeFlagsAt(node_idx, flags);
    }

    pub fn appendExtendEdge(self: *RuleIR, allocator: std.mem.Allocator, edge: ExtendEdge) !void {
        try self.extend_edges.append(allocator, edge);
    }

    pub fn noteExtendRelationMediaContext(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        source_module: u32,
        relation_id: u32,
        media_context_active: bool,
    ) !void {
        if (relation_id == std.math.maxInt(u32)) return;
        const key = extendRelationMediaKey(source_module, relation_id);
        const gop = try self.extend_relation_media.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = media_context_active;
            return;
        }
        gop.value_ptr.* = gop.value_ptr.* or media_context_active;
    }

    fn extendRelationMediaKey(source_module: u32, relation_id: u32) u64 {
        return (@as(u64, source_module) << 32) | relation_id;
    }

    fn extendRelationInMedia(self: *const RuleIR, source_module: u32, relation_id: u32) bool {
        if (relation_id == std.math.maxInt(u32)) return false;
        return self.extend_relation_media.get(extendRelationMediaKey(source_module, relation_id)) orelse false;
    }

    /// Runtime-recorded extend relation.
    /// `extending_selector` and `target_selector` may be comma-lists; this method splits them
    /// to single selector branches and stores one edge per pair.
    pub fn appendExtendRelation(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        extending_selector: InternId,
        target_selector: InternId,
        optional: bool,
        is_placeholder: bool,
    ) !void {
        return self.appendExtendRelationScoped(
            allocator,
            intern_pool,
            extending_selector,
            target_selector,
            optional,
            is_placeholder,
            0,
            0,
            std.math.maxInt(u32),
            null,
        );
    }

    pub fn appendExtendRelationScoped(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        extending_selector: InternId,
        target_selector: InternId,
        optional: bool,
        is_placeholder: bool,
        source_module: u32,
        target_module: u32,
        relation_id: u32,
        module_group_start_order: ?u32,
    ) !void {
        const extending_raw = std.mem.trim(u8, intern_pool.get(extending_selector), " \t\r\n");
        if (extending_raw.len == 0) return;
        if (try shouldSuppressExtendingSelector(allocator, extending_raw)) return;
        const normalized_target = try normalizeRuntimeExtendTargetText(intern_pool.get(target_selector));

        var target_parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer target_parts.deinit(allocator);
        try splitSelectorList(allocator, normalized_target, &target_parts);
        if (target_parts.items.len == 0) return;

        const ext_id = try intern_pool.intern(extending_raw);

        for (target_parts.items) |target_part| {
            try validateExtendTargetBranch(allocator, target_part);
            const target_id = try intern_pool.intern(target_part);
            try self.appendExtendEdge(allocator, .{
                .extending_selector = ext_id,
                .target_selector = target_id,
                .optional = optional,
                .is_placeholder = is_placeholder or isSimplePlaceholderSelector(target_part),
                .source_module = source_module,
                .target_module = target_module,
                .relation_id = relation_id,
                .module_group_start_order = module_group_start_order,
            });
        }
    }

    fn sourceModuleCanSee(self: *const RuleIR, from: u32, target: u32) bool {
        if (from == target) return true;
        const n = self.module_visibility_n;
        if (n == 0 or self.module_visibility_matrix.len != n * n) return false;
        if (from >= n or target >= n) return false;
        return self.module_visibility_matrix[from * n + target];
    }

    /// Static streaming pre-scan only. Dynamic @extend targets must disable
    /// chunk flushing before calling this helper.
    pub fn collectExtendTargetBranches(
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        target_selector: InternId,
        out: *std.ArrayListUnmanaged(InternId),
    ) !void {
        if (target_selector == .none) return error.SassError;
        const normalized_target = try normalizeRuntimeExtendTargetText(intern_pool.get(target_selector));

        var target_parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer target_parts.deinit(allocator);
        try splitSelectorList(allocator, normalized_target, &target_parts);
        if (target_parts.items.len == 0) return;

        try out.ensureUnusedCapacity(allocator, target_parts.items.len);
        for (target_parts.items) |target_part| {
            try validateExtendTargetBranch(allocator, target_part);
            const target_id = try intern_pool.intern(target_part);
            var found = false;
            for (out.items) |existing| {
                if (existing == target_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                out.appendAssumeCapacity(target_id);
            }
        }
    }

    const SelectorFilterMode = enum {
        placeholders,
        private_placeholders,
    };

    fn pruneEmptyStyleRulesRuleIR(self: *RuleIR) !void {
        _ = try self.pruneEmptyStyleRulesInRangeRuleIR(0, self.nodes.items.len);
    }

    fn filterPlaceholdersRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
    ) !void {
        _ = try self.filterSelectorsInRangeRuleIR(
            allocator,
            intern_pool,
            0,
            self.nodes.items.len,
            .placeholders,
        );
    }

    fn filterPrivatePlaceholdersRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
    ) !void {
        _ = try self.filterSelectorsInRangeRuleIR(
            allocator,
            intern_pool,
            0,
            self.nodes.items.len,
            .private_placeholders,
        );
    }

    fn pruneEmptyStyleRulesInRangeRuleIR(
        self: *RuleIR,
        start_idx: usize,
        end_idx: usize,
    ) !usize {
        var i = start_idx;
        var limit = end_idx;
        while (i < limit) {
            const node = self.nodes.items[i];
            switch (node.kind) {
                .rule_begin => {
                    const end_before = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (end_before >= limit) return error.SassError;

                    _ = try self.pruneEmptyStyleRulesInRangeRuleIR(i + 1, end_before);

                    const end_after = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (!self.rangeHasDirectVisibleChildrenRuleIR(i + 1, end_after)) {
                        const removed = end_after - i + 1;
                        self.removeNodesRange(i, end_after);
                        limit -= removed;
                        continue;
                    }

                    i = end_after + 1;
                },
                .at_rule_begin => {
                    const end_before = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (end_before >= limit) return error.SassError;

                    _ = try self.pruneEmptyStyleRulesInRangeRuleIR(i + 1, end_before);

                    const end_after = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    i = end_after + 1;
                },
                else => i += 1,
            }
        }
        return limit;
    }

    fn filterSelectorsInRangeRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        start_idx: usize,
        end_idx: usize,
        mode: SelectorFilterMode,
    ) !usize {
        var i = start_idx;
        var limit = end_idx;
        while (i < limit) {
            const node = self.nodes.items[i];
            switch (node.kind) {
                .rule_begin => {
                    const end_before = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (end_before >= limit) return error.SassError;

                    _ = try self.filterSelectorsInRangeRuleIR(
                        allocator,
                        intern_pool,
                        i + 1,
                        end_before,
                        mode,
                    );

                    const end_after = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    const selector_ptr = &self.extra.items[self.nodes.items[i].payload];
                    const selector_text = intern_pool.get(@enumFromInt(selector_ptr.*));

                    if (selectorMatchesRemovalMode(selector_text, mode)) {
                        const removed = end_after - i + 1;
                        self.removeNodesRange(i, end_after);
                        limit -= removed;
                        continue;
                    }

                    if (selectorNeedsRewriteForMode(selector_text, mode)) {
                        const filtered = try filterSelectorPartsForMode(allocator, selector_text, mode);
                        defer allocator.free(filtered);

                        if (filtered.len == 0) {
                            const removed = end_after - i + 1;
                            self.removeNodesRange(i, end_after);
                            limit -= removed;
                            continue;
                        }

                        const filtered_id = try intern_pool.intern(filtered);
                        selector_ptr.* = @intFromEnum(filtered_id);
                    }

                    i = end_after + 1;
                },
                .at_rule_begin => {
                    const end_before = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (end_before >= limit) return error.SassError;
                    const had_children = end_before > i + 1;

                    _ = try self.filterSelectorsInRangeRuleIR(
                        allocator,
                        intern_pool,
                        i + 1,
                        end_before,
                        mode,
                    );

                    const end_after = self.findMatchingBlockEnd(i) orelse return error.SassError;
                    if (had_children and end_after == i + 1) {
                        const removed = end_after - i + 1;
                        self.removeNodesRange(i, end_after);
                        limit -= removed;
                        continue;
                    }

                    i = end_after + 1;
                },
                else => i += 1,
            }
        }
        return limit;
    }

    fn selectorMatchesRemovalMode(selector_text: []const u8, mode: SelectorFilterMode) bool {
        return switch (mode) {
            .placeholders => placeholder_prune_mod.isPlaceholderSelector(selector_text),
            .private_placeholders => placeholder_prune_mod.isPrivatePlaceholderSelector(selector_text),
        };
    }

    fn selectorNeedsRewriteForMode(selector_text: []const u8, mode: SelectorFilterMode) bool {
        return switch (mode) {
            .placeholders => std.mem.findScalar(u8, selector_text, '%') != null,
            .private_placeholders => std.mem.find(u8, selector_text, "%-") != null,
        };
    }

    fn filterSelectorPartsForMode(
        allocator: std.mem.Allocator,
        selector_text: []const u8,
        mode: SelectorFilterMode,
    ) ![]const u8 {
        return switch (mode) {
            .placeholders => placeholder_prune_mod.removePlaceholderParts(allocator, selector_text),
            .private_placeholders => placeholder_prune_mod.removePrivatePlaceholderParts(allocator, selector_text),
        };
    }

    fn rangeHasDirectVisibleChildrenRuleIR(
        self: *const RuleIR,
        start_idx: usize,
        end_idx: usize,
    ) bool {
        var depth: usize = 0;
        var i = start_idx;
        while (i < end_idx) : (i += 1) {
            switch (self.nodes.items[i].kind) {
                .rule_begin, .at_rule_begin => {
                    if (depth == 0) return true;
                    depth += 1;
                },
                .rule_end, .at_rule_end => {
                    if (depth > 0) depth -= 1;
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stream_chunk => {
                    if (depth == 0) return true;
                },
                .stmt_gap, .group_boundary, .sourcemap_gap => {},
            }
        }
        return false;
    }

    fn findMatchingBlockEnd(self: *const RuleIR, start_idx: usize) ?usize {
        return self.findMatchingTopLevelBlockEnd(start_idx);
    }

    /// Returns the index of `at_rule_begin` corresponding to `at_rule_end` located at `end_idx`
    /// (walk backward, count depth). Only scan after `range_start`. Null if not found.
    fn findMatchingAtRuleBeginBackward(self: *const RuleIR, range_start: usize, end_idx: usize) ?usize {
        if (end_idx >= self.nodes.items.len) return null;
        if (self.nodes.items[end_idx].kind != .at_rule_end) return null;
        var depth: usize = 1;
        var i: usize = end_idx;
        while (i > range_start) {
            i -= 1;
            switch (self.nodes.items[i].kind) {
                .at_rule_end, .rule_end => depth += 1,
                .at_rule_begin => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                .rule_begin => {
                    depth -= 1;
                    if (depth == 0) return null;
                },
                else => {},
            }
        }
        return null;
    }

    /// Returns the index of `rule_begin` corresponding to `rule_end` located at `end_idx`.
    fn findMatchingRuleBeginBackward(self: *const RuleIR, range_start: usize, end_idx: usize) ?usize {
        if (end_idx >= self.nodes.items.len) return null;
        if (self.nodes.items[end_idx].kind != .rule_end) return null;
        var depth: usize = 1;
        var i: usize = end_idx;
        while (i > range_start) {
            i -= 1;
            switch (self.nodes.items[i].kind) {
                .rule_end, .at_rule_end => depth += 1,
                .rule_begin => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                .at_rule_begin => {
                    depth -= 1;
                    if (depth == 0) return null;
                },
                else => {},
            }
        }
        return null;
    }

    fn removeNodesRange(self: *RuleIR, start_idx: usize, end_idx_inclusive: usize) void {
        std.debug.assert(start_idx <= end_idx_inclusive);
        std.debug.assert(end_idx_inclusive < self.nodes.items.len);
        std.debug.assert(self.node_source_files.items.len == self.nodes.items.len);

        const src_start = end_idx_inclusive + 1;
        const removed = src_start - start_idx;
        const tail_len = self.nodes.items.len - src_start;
        if (tail_len > 0) {
            std.mem.copyForwards(
                Node,
                self.nodes.items[start_idx .. start_idx + tail_len],
                self.nodes.items[src_start .. src_start + tail_len],
            );
            std.mem.copyForwards(
                u32,
                self.node_source_files.items[start_idx .. start_idx + tail_len],
                self.node_source_files.items[src_start .. src_start + tail_len],
            );
        }

        self.nodes.items.len -= removed;
        self.node_source_files.items.len -= removed;
    }

    const TopLevelItem = struct {
        start: usize,
        end: usize,
        kind: NodeKind,
        source_file: u32,
    };

    fn topLevelItemEnd(self: *const RuleIR, start_idx: usize) !usize {
        if (start_idx >= self.nodes.items.len) return error.SassError;
        return switch (self.nodes.items[start_idx].kind) {
            .rule_begin, .at_rule_begin => (self.findMatchingBlockEnd(start_idx) orelse return error.SassError) + 1,
            .rule_end, .at_rule_end => {
                const start_node = self.nodes.items[start_idx];
                const source_file = if (start_idx < self.node_source_files.items.len) self.node_source_files.items[start_idx] else std.math.maxInt(u32);
                const prev_kind = if (start_idx > 0) @tagName(self.nodes.items[start_idx - 1].kind) else "<none>";
                const next_kind = if (start_idx + 1 < self.nodes.items.len) @tagName(self.nodes.items[start_idx + 1].kind) else "<none>";
                ruleIrStderrPrint(
                    "zsass-rule-ir malformed top-level item idx={d} kind={s} prev={s} next={s} file_id={d} span={d}..{d}\n",
                    .{
                        start_idx,
                        @tagName(start_node.kind),
                        prev_kind,
                        next_kind,
                        source_file,
                        start_node.source_start,
                        start_node.source_end,
                    },
                );
                // Dump neighboring nodes and their source files for context.
                var lo: usize = if (start_idx > 16) start_idx - 16 else 0;
                const hi: usize = @min(start_idx + 16, self.nodes.items.len);
                while (lo < hi) : (lo += 1) {
                    const n = self.nodes.items[lo];
                    const sf = if (lo < self.node_source_files.items.len) self.node_source_files.items[lo] else std.math.maxInt(u32);
                    ruleIrStderrPrint("  node[{d}] kind={s} span={d}..{d} file={d}\n", .{ lo, @tagName(n.kind), n.source_start, n.source_end, sf });
                }
                return error.SassError;
            },
            else => start_idx + 1,
        };
    }

    fn collectTopLevelItems(
        self: *const RuleIR,
        allocator: std.mem.Allocator,
    ) !std.ArrayListUnmanaged(TopLevelItem) {
        var items: std.ArrayListUnmanaged(TopLevelItem) = .empty;
        errdefer items.deinit(allocator);

        var i: usize = 0;
        while (i < self.nodes.items.len) {
            const end = try self.topLevelItemEnd(i);
            try items.append(allocator, .{
                .start = i,
                .end = end,
                .kind = self.nodes.items[i].kind,
                .source_file = self.node_source_files.items[i],
            });
            i = end;
        }
        return items;
    }

    fn appendNodeRange(
        self: *const RuleIR,
        allocator: std.mem.Allocator,
        out_nodes: *std.ArrayListUnmanaged(Node),
        out_files: *std.ArrayListUnmanaged(u32),
        start_idx: usize,
        end_idx: usize,
    ) !void {
        if (start_idx >= end_idx) return;
        try out_nodes.appendSlice(allocator, self.nodes.items[start_idx..end_idx]);
        try out_files.appendSlice(allocator, self.node_source_files.items[start_idx..end_idx]);
    }

    fn appendSyntheticSeparator(
        allocator: std.mem.Allocator,
        out_nodes: *std.ArrayListUnmanaged(Node),
        out_files: *std.ArrayListUnmanaged(u32),
        kind: NodeKind,
    ) !void {
        std.debug.assert(isRuleIRGroupSeparatorKind(kind));
        try out_nodes.append(allocator, .{
            .kind = kind,
            .payload = 0,
            .source_start = 0,
            .source_end = 0,
        });
        try out_files.append(allocator, 0);
    }

    fn appendReorderedRange(
        self: *const RuleIR,
        allocator: std.mem.Allocator,
        out_nodes: *std.ArrayListUnmanaged(Node),
        out_files: *std.ArrayListUnmanaged(u32),
        last_was_boundary: *bool,
        start_idx: usize,
        end_idx: usize,
    ) !bool {
        const kind = self.nodes.items[start_idx].kind;
        if (isRuleIRGroupSeparatorKind(kind)) {
            if (last_was_boundary.* or out_nodes.items.len == 0) return false;
            try self.appendNodeRange(allocator, out_nodes, out_files, start_idx, end_idx);
            last_was_boundary.* = true;
            return true;
        }

        try self.appendNodeRange(allocator, out_nodes, out_files, start_idx, end_idx);
        last_was_boundary.* = false;
        return true;
    }

    fn replaceNodeBuffers(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        new_nodes: std.ArrayListUnmanaged(Node),
        new_files: std.ArrayListUnmanaged(u32),
    ) void {
        self.nodes.deinit(allocator);
        self.node_source_files.deinit(allocator);
        self.nodes = new_nodes;
        self.node_source_files = new_files;
    }

    const RebuiltBuffers = struct {
        nodes: std.ArrayListUnmanaged(Node) = .empty,
        files: std.ArrayListUnmanaged(u32) = .empty,

        fn deinit(self: *RebuiltBuffers, allocator: std.mem.Allocator) void {
            self.nodes.deinit(allocator);
            self.files.deinit(allocator);
        }

        fn appendSlice(self: *RebuiltBuffers, allocator: std.mem.Allocator, nodes: []const Node, files: []const u32) !void {
            if (nodes.len == 0) return;
            try self.nodes.appendSlice(allocator, nodes);
            try self.files.appendSlice(allocator, files);
        }
    };

    const NormalizedBubbleRange = struct {
        kept: RebuiltBuffers = .{},
        after: RebuiltBuffers = .{},

        fn deinit(self: *NormalizedBubbleRange, allocator: std.mem.Allocator) void {
            self.kept.deinit(allocator);
            self.after.deinit(allocator);
        }
    };

    fn findMatchingBlockEndInNodes(nodes: []const Node, start_idx: usize) ?usize {
        if (start_idx >= nodes.len) return null;
        const start_kind = nodes[start_idx].kind;
        if (start_kind != .rule_begin and start_kind != .at_rule_begin) return null;
        var depth: usize = 0;
        var i = start_idx;
        while (i < nodes.len) : (i += 1) {
            switch (nodes[i].kind) {
                .rule_begin, .at_rule_begin => depth += 1,
                .rule_end, .at_rule_end => {
                    if (depth == 0) return null;
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    fn topLevelItemEndInNodes(nodes: []const Node, start_idx: usize) !usize {
        if (start_idx >= nodes.len) return error.SassError;
        return switch (nodes[start_idx].kind) {
            .rule_begin, .at_rule_begin => (findMatchingBlockEndInNodes(nodes, start_idx) orelse return error.SassError) + 1,
            .rule_end, .at_rule_end => error.SassError,
            else => start_idx + 1,
        };
    }

    fn firstRuleSelectorInNodes(self: *const RuleIR, nodes: []const Node) ?u32 {
        for (nodes) |node| {
            if (node.kind == .rule_begin) {
                if (node.payload >= self.extra.items.len) return null;
                return self.extra.items[node.payload];
            }
        }
        return null;
    }

    fn leadingRuleItemWithSelectorEndInNodes(self: *const RuleIR, nodes: []const Node, start_idx: usize, selector_id: u32) ?usize {
        if (start_idx >= nodes.len) return null;
        if (nodes[start_idx].kind != .rule_begin) return null;
        if (nodes[start_idx].payload >= self.extra.items.len) return null;
        if (self.extra.items[nodes[start_idx].payload] != selector_id) return null;
        return topLevelItemEndInNodes(nodes, start_idx) catch null;
    }

    fn bubbleMaskForAtRuleNode(self: *const RuleIR, pool: *const InternPool, node: Node) u8 {
        if (node.kind != .at_rule_begin) return 0;
        if (node.payload >= self.extra.items.len) return 0;
        const name_id: InternId = @enumFromInt(self.extra.items[node.payload]);
        const full_name = pool.get(name_id);
        const raw_name = if (full_name.len > 0 and full_name[0] == '@') full_name[1..] else full_name;
        if (std.mem.eql(u8, raw_name, "media")) return at_root_bubble_media_mask;
        if (std.mem.eql(u8, raw_name, "supports")) return at_root_bubble_supports_mask;
        if (std.mem.eql(u8, raw_name, "layer")) return at_root_bubble_layer_mask;
        return 0;
    }

    fn firstRenderableStyleOrAtRuleNodeIndex(nodes: []const Node) ?usize {
        var i: usize = 0;
        while (i < nodes.len) {
            const item_end = topLevelItemEndInNodes(nodes, i) catch return null;
            switch (nodes[i].kind) {
                .rule_begin, .at_rule_begin, .at_rule_simple => return i,
                else => {},
            }
            i = item_end;
        }
        return null;
    }

    fn normalizeAtRootBubbleDirectRange(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *const InternPool,
        start_idx: usize,
        end_idx: usize,
        parent_bubble_mask: ?u8,
    ) error{ OutOfMemory, SassError }!NormalizedBubbleRange {
        var out: NormalizedBubbleRange = .{};
        errdefer out.deinit(allocator);

        var i = start_idx;
        while (i < end_idx) {
            const item_end = try self.topLevelItemEnd(i);
            if (item_end > end_idx) return error.SassError;

            var expanded = try self.expandAtRootBubbleItem(allocator, pool, i, item_end);
            defer expanded.deinit(allocator);

            var j: usize = 0;
            while (j < expanded.nodes.items.len) {
                const expanded_end = try topLevelItemEndInNodes(expanded.nodes.items, j);
                if (parent_bubble_mask) |mask| {
                    const start_node = expanded.nodes.items[j];
                    if (self.nodeHasBubbleMaskForNode(start_node, mask)) {
                        self.clearBubbleMaskForNode(start_node, mask);
                        try out.after.appendSlice(allocator, expanded.nodes.items[j..expanded_end], expanded.files.items[j..expanded_end]);
                    } else {
                        try out.kept.appendSlice(allocator, expanded.nodes.items[j..expanded_end], expanded.files.items[j..expanded_end]);
                    }
                } else {
                    try out.kept.appendSlice(allocator, expanded.nodes.items[j..expanded_end], expanded.files.items[j..expanded_end]);
                }
                j = expanded_end;
            }

            i = item_end;
        }

        return out;
    }

    fn expandAtRootBubbleItem(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *const InternPool,
        start_idx: usize,
        end_idx: usize,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        const start_node = self.nodes.items[start_idx];
        if (start_node.kind != .rule_begin and start_node.kind != .at_rule_begin) {
            try out.appendSlice(allocator, self.nodes.items[start_idx..end_idx], self.node_source_files.items[start_idx..end_idx]);
            return out;
        }

        const block_end = self.findMatchingBlockEnd(start_idx) orelse return error.SassError;
        if (block_end + 1 != end_idx) return error.SassError;

        const bubble_mask = if (start_node.kind == .at_rule_begin) self.bubbleMaskForAtRuleNode(pool, start_node) else 0;
        var normalized = try self.normalizeAtRootBubbleDirectRange(
            allocator,
            pool,
            start_idx + 1,
            block_end,
            if (bubble_mask == 0) null else bubble_mask,
        );
        defer normalized.deinit(allocator);

        try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
        try out.appendSlice(allocator, normalized.kept.nodes.items, normalized.kept.files.items);
        try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);

        if (normalized.after.nodes.items.len > 0) {
            if (firstRenderableStyleOrAtRuleNodeIndex(normalized.after.nodes.items)) |first_idx| {
                self.setSuppressLeadingBlankForNode(normalized.after.nodes.items[first_idx], true);
            }
            try out.appendSlice(allocator, normalized.after.nodes.items, normalized.after.files.items);
        }

        return out;
    }

    pub fn normalizeAtRootBubblesRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *const InternPool,
    ) error{ OutOfMemory, SassError }!void {
        if (self.nodes.items.len == 0) return;

        var normalized = try self.normalizeAtRootBubbleDirectRange(allocator, pool, 0, self.nodes.items.len, null);
        errdefer normalized.deinit(allocator);

        if (normalized.after.nodes.items.len > 0) {
            try normalized.kept.appendSlice(allocator, normalized.after.nodes.items, normalized.after.files.items);
        }

        self.replaceNodeBuffers(allocator, normalized.kept.nodes, normalized.kept.files);
        normalized.kept = .{};
        normalized.after.deinit(allocator);
        normalized.after = .{};
    }

    fn directRangeHasVisibleOutputInNodes(nodes: []const Node) bool {
        var i: usize = 0;
        while (i < nodes.len) {
            const item_end = topLevelItemEndInNodes(nodes, i) catch return false;
            switch (nodes[i].kind) {
                .decl, .decl_raw, .comment, .rule_begin, .at_rule_begin, .at_rule_simple, .stream_chunk => return true,
                .stmt_gap, .group_boundary, .sourcemap_gap => {},
                .rule_end, .at_rule_end => return false,
            }
            i = item_end;
        }
        return false;
    }

    fn hasAnyVisibleContentNode(nodes: []const Node) bool {
        for (nodes) |node| {
            switch (node.kind) {
                .decl, .decl_raw, .comment, .at_rule_simple, .stream_chunk => return true,
                else => {},
            }
        }
        return false;
    }

    fn hasAnyNonCommentBodyContentNode(nodes: []const Node) bool {
        for (nodes) |node| {
            switch (node.kind) {
                .decl, .decl_raw, .at_rule_simple, .stream_chunk => return true,
                else => {},
            }
        }
        return false;
    }

    fn ruleItemHasVisibleBodyContent(nodes: []const Node, start_idx: usize, end_idx: usize) bool {
        if (start_idx >= end_idx or nodes[start_idx].kind != .rule_begin) return false;
        var i = start_idx + 1;
        while (i < end_idx) {
            const item_end = topLevelItemEndInNodes(nodes, i) catch return false;
            switch (nodes[i].kind) {
                .decl, .decl_raw, .at_rule_simple, .stream_chunk => return true,
                .rule_begin, .at_rule_begin => if (hasAnyNonCommentBodyContentNode(nodes[i..item_end])) return true,
                else => {},
            }
            i = item_end;
        }
        return false;
    }

    fn segmentsShareFirstSelector(self: *const RuleIR, seg_a: RebuiltBuffers, seg_b: RebuiltBuffers) bool {
        return self.segmentsShareFirstSelectorNodes(seg_a.nodes.items, seg_b.nodes.items);
    }

    fn segmentsShareFirstSelectorNodes(self: *const RuleIR, nodes_a: []const Node, nodes_b: []const Node) bool {
        const sel_a = firstRuleBeginSelectorIntern(self, nodes_a) orelse return false;
        const sel_b = firstRuleBeginSelectorIntern(self, nodes_b) orelse return false;
        return sel_a == sel_b;
    }

    fn firstRuleBeginSelectorIntern(self: *const RuleIR, nodes: []const Node) ?u32 {
        for (nodes) |node| {
            if (node.kind == .rule_begin) {
                if (node.payload < self.extra.items.len) return self.extra.items[node.payload];
                return null;
            }
        }
        return null;
    }

    fn nodeIsMediaBlock(self: *const RuleIR, pool: *const InternPool, node: Node) bool {
        if (node.kind != .at_rule_begin) return false;
        if (node.payload >= self.extra.items.len) return false;
        const name_id: InternId = @enumFromInt(self.extra.items[node.payload]);
        return isMediaAtRuleName(pool.get(name_id));
    }

    fn nodeIsPlainCssPreserveAtRule(self: *const RuleIR, node: Node) bool {
        if (node.kind != .at_rule_begin) return false;
        return (self.getNodeFlagsForNode(node) & NodeFlags.plain_css_preserve_nested_at_rule) != 0;
    }

    fn nodeIsKeyframesBlock(self: *const RuleIR, pool: *const InternPool, node: Node) bool {
        if (node.kind != .at_rule_begin) return false;
        if (node.payload >= self.extra.items.len) return false;
        const name_id: InternId = @enumFromInt(self.extra.items[node.payload]);
        return isKeyframesAtRuleName(pool.get(name_id));
    }

    const MediaMergeDecision = enum {
        keep_nested,
        moved,
        dropped,
    };

    fn mergeMediaPreludeIntoChild(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        parent_node: Node,
        child_node: Node,
    ) error{ OutOfMemory, SassError }!MediaMergeDecision {
        if (parent_node.kind != .at_rule_begin or child_node.kind != .at_rule_begin) return .keep_nested;
        if (parent_node.payload + 1 >= self.extra.items.len or child_node.payload + 1 >= self.extra.items.len) {
            return .keep_nested;
        }

        const parent_prelude_id = self.extra.items[parent_node.payload + 1];
        const child_prelude_id = self.extra.items[child_node.payload + 1];
        if (parent_prelude_id == std.math.maxInt(u32) or child_prelude_id == std.math.maxInt(u32)) return .keep_nested;

        const parent_raw = pool.get(@enumFromInt(parent_prelude_id));
        const child_raw = pool.get(@enumFromInt(child_prelude_id));
        const preserve_case = mediaPreludePreserveCase(parent_raw) or mediaPreludePreserveCase(child_raw);

        const merge_result = try media_prelude.mergeMediaQueryLists(
            allocator,
            stripMediaPreludePreserveCaseMarker(parent_raw),
            stripMediaPreludePreserveCaseMarker(child_raw),
        );

        if (merge_result) |merged| {
            if (merged.ptr == media_prelude.MEDIA_MERGE_UNRESOLVABLE.ptr) return .keep_nested;
            defer allocator.free(merged);

            var merged_text = merged;
            var marked: ?[]const u8 = null;
            defer if (marked) |owned| allocator.free(owned);

            if (preserve_case) {
                marked = try std.mem.concat(allocator, u8, &.{ media_prelude_preserve_case_marker, merged });
                merged_text = marked.?;
            }

            const merged_id = try pool.intern(merged_text);
            self.extra.items[child_node.payload + 1] = @intFromEnum(merged_id);
            return .moved;
        }

        return .dropped;
    }

    fn rebuildMergedNestedMediaBlock(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        start_idx: usize,
        end_idx: usize,
        changed: *bool,
        parent_barrier: bool,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        const start_node = self.nodes.items[start_idx];
        if (start_node.kind != .rule_begin and start_node.kind != .at_rule_begin) {
            try out.appendSlice(allocator, self.nodes.items[start_idx..end_idx], self.node_source_files.items[start_idx..end_idx]);
            return out;
        }

        const block_end = self.findMatchingBlockEnd(start_idx) orelse return error.SassError;
        if (block_end + 1 != end_idx) return error.SassError;

        const body_barrier = parent_barrier or start_node.kind == .rule_begin or
            (start_node.kind == .at_rule_begin and self.nodeIsKeyframesBlock(pool, start_node));

        var body = try self.rebuildMergedNestedMediaDirectRange(allocator, pool, start_idx + 1, block_end, changed, body_barrier);
        defer body.deinit(allocator);

        if (!(start_node.kind == .at_rule_begin and self.nodeIsMediaBlock(pool, start_node)) or parent_barrier) {
            try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
            try out.appendSlice(allocator, body.nodes.items, body.files.items);
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
            return out;
        }

        // Split a retained body around each hoisted @media so the parent
        // @media block is re-opened between moved children.
        //   @media outer { A; @media inner {...}; B; }
        // becomes `@media outer { A }`, `@media outer+inner {...}`,
        // then `@media outer { B }`, preserving source order.
        var segments: std.ArrayListUnmanaged(RebuiltBuffers) = .empty;
        defer {
            for (segments.items) |*seg| seg.deinit(allocator);
            segments.deinit(allocator);
        }
        var moved_blocks: std.ArrayListUnmanaged(RebuiltBuffers) = .empty;
        defer {
            for (moved_blocks.items) |*m| m.deinit(allocator);
            moved_blocks.deinit(allocator);
        }
        try segments.append(allocator, .{});
        var local_changed = false;

        var j: usize = 0;
        while (j < body.nodes.items.len) {
            const item_end = try topLevelItemEndInNodes(body.nodes.items, j);
            const item_node = body.nodes.items[j];
            if (self.nodeIsMediaBlock(pool, item_node) and !self.nodeIsPlainCssPreserveAtRule(item_node)) {
                switch (try self.mergeMediaPreludeIntoChild(allocator, pool, start_node, item_node)) {
                    .keep_nested => {
                        const seg = &segments.items[segments.items.len - 1];
                        try seg.appendSlice(allocator, body.nodes.items[j..item_end], body.files.items[j..item_end]);
                    },
                    .moved => {
                        local_changed = true;
                        self.setSuppressLeadingBlankForNode(item_node, true);
                        //merge-hoist of parent @media  ->  inner @media does not set preserve
                        // (There is no blank between top-level @media after merge on official Sass CLI actual machine).
                        // preserve_at_rule_block_following_blank is canceled at a later stage (segment
                        //done after visible determination) -- moved immediately followed by reopened outer
                        // Released only when moved, respecting the preserve set by the VM at the last moved
                        // Keep the sibling blank when a moved block is followed
                        // by a reopened outer block.
                        try moved_blocks.append(allocator, .{});
                        const moved = &moved_blocks.items[moved_blocks.items.len - 1];
                        try moved.appendSlice(allocator, body.nodes.items[j..item_end], body.files.items[j..item_end]);
                        try segments.append(allocator, .{});
                    },
                    .dropped => {
                        local_changed = true;
                    },
                }
            } else {
                const seg = &segments.items[segments.items.len - 1];
                try seg.appendSlice(allocator, body.nodes.items[j..item_end], body.files.items[j..item_end]);
            }
            j = item_end;
        }

        if (!local_changed) {
            try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
            try out.appendSlice(allocator, body.nodes.items, body.files.items);
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
            return out;
        }

        changed.* = true;
        std.debug.assert(segments.items.len == moved_blocks.items.len + 1);
        // If moved[i] is immediately followed by reopened outer (= non-empty wrap of segment[i+1]), then
        // Release preserve_at_rule_block_following_blank from parent style_rule.
        // followed by outer scope sibling (moved at the end of parent @media body
        // If segment[i+1] is empty), respect preserve and keep blank.
        for (moved_blocks.items, 0..) |moved, idx| {
            if (moved.nodes.items.len == 0) continue;
            const next_seg_has_output = directRangeHasVisibleOutputInNodes(segments.items[idx + 1].nodes.items);
            if (next_seg_has_output) {
                self.setPreserveAtRuleBlockFollowingBlankForNode(moved.nodes.items[0], false);
            }
        }
        // Interleave segments with moved (hoisted) blocks. When two adjacent
        // segments share the same leading selector (VM-split continuation of a
        // single selector rule around a nested @media), keep them in one parent
        //block and defer the moved block -- official Sass CLI combines the selector
        // parts. When selectors differ, close the parent before the moved block
        // (source-order interleaving). Moved blocks with no visible content
        // (empty nested @media) are always skipped.
        const segment_offsets = try allocator.alloc(usize, segments.items.len);
        defer allocator.free(segment_offsets);
        @memset(segment_offsets, 0);

        var emitted_mask: u64 = 0;
        var parent_open = false;
        for (segments.items, 0..) |seg, idx| {
            const seg_nodes = seg.nodes.items[segment_offsets[idx]..];
            const seg_files = seg.files.items[segment_offsets[idx]..];
            if (directRangeHasVisibleOutputInNodes(seg_nodes)) {
                if (!parent_open) {
                    try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
                    parent_open = true;
                }
                try out.appendSlice(allocator, seg_nodes, seg_files);
            }
            if (idx < moved_blocks.items.len) {
                const moved = moved_blocks.items[idx];
                if (!hasAnyVisibleContentNode(moved.nodes.items)) {
                    emitted_mask |= @as(u64, 1) << @intCast(idx);
                    continue;
                }
                const moved_selector = self.firstRuleSelectorInNodes(moved.nodes.items);
                if (moved_selector) |selector_id| {
                    var pulled_for_moved = false;
                    var scan_idx = idx + 1;
                    while (scan_idx < segments.items.len) : (scan_idx += 1) {
                        const candidate = &segments.items[scan_idx];
                        const pull_start = segment_offsets[scan_idx];
                        if (self.leadingRuleItemWithSelectorEndInNodes(
                            candidate.nodes.items,
                            pull_start,
                            selector_id,
                        )) |leading_end| {
                            const leading_has_visible_body = ruleItemHasVisibleBodyContent(candidate.nodes.items, pull_start, leading_end);
                            if (leading_has_visible_body and idx > 0 and
                                !directRangeHasVisibleOutputInNodes(seg_nodes))
                            {
                                break;
                            }
                            if (!parent_open) {
                                try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
                                parent_open = true;
                            }
                            if (!pulled_for_moved and !leading_has_visible_body) {
                                try appendSyntheticSeparator(allocator, &out.nodes, &out.files, .group_boundary);
                                pulled_for_moved = true;
                            }
                            try out.appendSlice(
                                allocator,
                                candidate.nodes.items[pull_start..leading_end],
                                candidate.files.items[pull_start..leading_end],
                            );
                            segment_offsets[scan_idx] = leading_end;
                            continue;
                        }
                        if (directRangeHasVisibleOutputInNodes(candidate.nodes.items[pull_start..])) break;
                        if (scan_idx < moved_blocks.items.len and
                            hasAnyVisibleContentNode(moved_blocks.items[scan_idx].nodes.items))
                        {
                            break;
                        }
                    }
                }
                const next_seg = segments.items[idx + 1];
                if (self.segmentsShareFirstSelectorNodes(
                    seg_nodes,
                    next_seg.nodes.items[segment_offsets[idx + 1]..],
                )) {
                    continue;
                }
                if (parent_open) {
                    try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
                    parent_open = false;
                }
                for (0..idx + 1) |mi| {
                    if ((emitted_mask & (@as(u64, 1) << @intCast(mi))) == 0) {
                        try out.appendSlice(allocator, moved_blocks.items[mi].nodes.items, moved_blocks.items[mi].files.items);
                        emitted_mask |= @as(u64, 1) << @intCast(mi);
                    }
                }
            }
        }
        if (parent_open) {
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
        }
        for (0..moved_blocks.items.len) |mi| {
            if ((emitted_mask & (@as(u64, 1) << @intCast(mi))) == 0) {
                try out.appendSlice(allocator, moved_blocks.items[mi].nodes.items, moved_blocks.items[mi].files.items);
            }
        }
        return out;
    }

    fn rebuildMergedNestedMediaDirectRange(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        start_idx: usize,
        end_idx: usize,
        changed: *bool,
        parent_barrier: bool,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        var i = start_idx;
        while (i < end_idx) {
            const item_end = try self.topLevelItemEnd(i);
            if (item_end > end_idx) return error.SassError;

            const node = self.nodes.items[i];
            if (node.kind == .rule_begin or node.kind == .at_rule_begin) {
                var rewritten = try self.rebuildMergedNestedMediaBlock(allocator, pool, i, item_end, changed, parent_barrier);
                defer rewritten.deinit(allocator);
                try out.appendSlice(allocator, rewritten.nodes.items, rewritten.files.items);
            } else {
                try out.appendSlice(allocator, self.nodes.items[i..item_end], self.node_source_files.items[i..item_end]);
            }
            i = item_end;
        }

        return out;
    }

    fn rewriteMergedNestedMediaRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
    ) error{ OutOfMemory, SassError }!bool {
        if (self.nodes.items.len == 0) return false;

        var changed = false;
        var rewritten = try self.rebuildMergedNestedMediaDirectRange(
            allocator,
            pool,
            0,
            self.nodes.items.len,
            &changed,
            false,
        );
        errdefer rewritten.deinit(allocator);

        self.replaceNodeBuffers(allocator, rewritten.nodes, rewritten.files);
        rewritten = .{};
        return changed;
    }

    fn combineSelectorWithParent(
        allocator: std.mem.Allocator,
        pool: *InternPool,
        parent_selector_intern: u32,
        child_selector_intern: u32,
    ) error{ OutOfMemory, SassError }!u32 {
        const parent_raw = pool.get(@enumFromInt(parent_selector_intern));
        const child_raw = pool.get(@enumFromInt(child_selector_intern));

        var parent_list = selector_mod.parse(allocator, parent_raw) catch return error.SassError;
        defer parent_list.deinit();
        var child_list = selector_mod.parse(allocator, child_raw) catch return error.SassError;
        defer child_list.deinit();

        var resolved = selector_mod.resolveParent(allocator, &child_list, &parent_list) catch return error.SassError;
        defer resolved.deinit();

        const css = try selector_mod.toCss(allocator, &resolved);
        defer allocator.free(css);
        const combined_id = try pool.intern(css);
        return @intFromEnum(combined_id);
    }

    fn flushWrappedHoistedMediaPending(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        selector_intern: u32,
        pending_nodes: *std.ArrayListUnmanaged(Node),
        pending_files: *std.ArrayListUnmanaged(u32),
        out: *RebuiltBuffers,
    ) error{OutOfMemory}!void {
        if (pending_nodes.items.len == 0) return;

        const extra_off: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, &[_]u32{
            selector_intern,
            1,
            0,
        });

        const first_node = pending_nodes.items[0];
        const first_file = pending_files.items[0];
        const last_node = pending_nodes.items[pending_nodes.items.len - 1];
        const last_file = pending_files.items[pending_files.items.len - 1];

        try out.nodes.append(allocator, .{
            .kind = .rule_begin,
            .payload = extra_off,
            .source_start = first_node.source_start,
            .source_end = first_node.source_end,
        });
        try out.files.append(allocator, first_file);
        try out.appendSlice(allocator, pending_nodes.items, pending_files.items);
        try out.nodes.append(allocator, .{
            .kind = .rule_end,
            .payload = 0,
            .source_start = last_node.source_start,
            .source_end = last_node.source_end,
        });
        try out.files.append(allocator, last_file);

        pending_nodes.clearRetainingCapacity();
        pending_files.clearRetainingCapacity();
    }

    fn rewriteHoistedMediaBodyWithParentSelector(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        parent_selector_intern: u32,
        media_nodes: []const Node,
        media_files: []const u32,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        var pending_nodes: std.ArrayListUnmanaged(Node) = .empty;
        defer pending_nodes.deinit(allocator);
        var pending_files: std.ArrayListUnmanaged(u32) = .empty;
        defer pending_files.deinit(allocator);

        var i: usize = 0;
        while (i < media_nodes.len) {
            const item_end = try topLevelItemEndInNodes(media_nodes, i);
            const item_node = media_nodes[i];
            switch (item_node.kind) {
                .decl, .decl_raw, .comment, .at_rule_simple, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {
                    try pending_nodes.appendSlice(allocator, media_nodes[i..item_end]);
                    try pending_files.appendSlice(allocator, media_files[i..item_end]);
                },
                .rule_begin => {
                    try self.flushWrappedHoistedMediaPending(
                        allocator,
                        parent_selector_intern,
                        &pending_nodes,
                        &pending_files,
                        &out,
                    );
                    if (item_node.payload >= self.extra.items.len) return error.SassError;
                    const combined_selector = try combineSelectorWithParent(
                        allocator,
                        pool,
                        parent_selector_intern,
                        self.extra.items[item_node.payload],
                    );
                    self.extra.items[item_node.payload] = combined_selector;
                    try out.appendSlice(allocator, media_nodes[i..item_end], media_files[i..item_end]);
                },
                .at_rule_begin => {
                    try self.flushWrappedHoistedMediaPending(
                        allocator,
                        parent_selector_intern,
                        &pending_nodes,
                        &pending_files,
                        &out,
                    );
                    if (self.nodeIsMediaBlock(pool, item_node) and !self.nodeIsPlainCssPreserveAtRule(item_node)) {
                        var nested = try self.rebuildHoistedRuleMediaItem(
                            allocator,
                            pool,
                            parent_selector_intern,
                            media_nodes[i..item_end],
                            media_files[i..item_end],
                        );
                        defer nested.deinit(allocator);
                        try out.appendSlice(allocator, nested.nodes.items, nested.files.items);
                    } else {
                        try out.appendSlice(allocator, media_nodes[i..item_end], media_files[i..item_end]);
                    }
                },
                .rule_end, .at_rule_end => return error.SassError,
            }
            i = item_end;
        }

        try self.flushWrappedHoistedMediaPending(
            allocator,
            parent_selector_intern,
            &pending_nodes,
            &pending_files,
            &out,
        );
        return out;
    }

    fn rebuildHoistedRuleMediaItem(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        selector_intern: u32,
        media_nodes: []const Node,
        media_files: []const u32,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        if (media_nodes.len == 0 or media_nodes[0].kind != .at_rule_begin) {
            try out.appendSlice(allocator, media_nodes, media_files);
            return out;
        }
        if (media_nodes.len < 2 or media_nodes[media_nodes.len - 1].kind != .at_rule_end) {
            try out.appendSlice(allocator, media_nodes, media_files);
            return out;
        }

        var rewritten_body = try self.rewriteHoistedMediaBodyWithParentSelector(
            allocator,
            pool,
            selector_intern,
            media_nodes[1 .. media_nodes.len - 1],
            media_files[1 .. media_files.len - 1],
        );
        defer rewritten_body.deinit(allocator);

        try out.appendSlice(allocator, media_nodes[0..1], media_files[0..1]);
        try out.appendSlice(allocator, rewritten_body.nodes.items, rewritten_body.files.items);
        try out.appendSlice(allocator, media_nodes[media_nodes.len - 1 .. media_nodes.len], media_files[media_files.len - 1 .. media_files.len]);
        return out;
    }

    fn rebuildRuleDirectMediaHoistsBlock(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        start_idx: usize,
        end_idx: usize,
        changed: *bool,
        parent_barrier: bool,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        const start_node = self.nodes.items[start_idx];
        if (start_node.kind != .rule_begin and start_node.kind != .at_rule_begin) {
            try out.appendSlice(allocator, self.nodes.items[start_idx..end_idx], self.node_source_files.items[start_idx..end_idx]);
            return out;
        }

        const block_end = self.findMatchingBlockEnd(start_idx) orelse return error.SassError;
        if (block_end + 1 != end_idx) return error.SassError;

        const body_barrier = parent_barrier or start_node.kind == .rule_begin or
            (start_node.kind == .at_rule_begin and self.nodeIsKeyframesBlock(pool, start_node));

        var body = try self.rebuildRuleDirectMediaHoistsDirectRange(allocator, pool, start_idx + 1, block_end, changed, body_barrier);
        defer body.deinit(allocator);

        if (start_node.kind != .rule_begin or parent_barrier) {
            try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
            try out.appendSlice(allocator, body.nodes.items, body.files.items);
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
            return out;
        }

        var retained: RebuiltBuffers = .{};
        defer retained.deinit(allocator);
        var after: RebuiltBuffers = .{};
        defer after.deinit(allocator);
        var local_changed = false;

        var j: usize = 0;
        while (j < body.nodes.items.len) {
            const item_end = try topLevelItemEndInNodes(body.nodes.items, j);
            const item_node = body.nodes.items[j];
            if (self.nodeIsMediaBlock(pool, item_node) and !self.nodeIsPlainCssPreserveAtRule(item_node)) {
                const selector_intern = if (start_node.payload < self.extra.items.len)
                    self.extra.items[start_node.payload]
                else
                    return error.SassError;
                var hoisted = try self.rebuildHoistedRuleMediaItem(
                    allocator,
                    pool,
                    selector_intern,
                    body.nodes.items[j..item_end],
                    body.files.items[j..item_end],
                );
                defer hoisted.deinit(allocator);

                if (!(hoisted.nodes.items.len == item_end - j and
                    std.mem.eql(u8, std.mem.sliceAsBytes(hoisted.nodes.items), std.mem.sliceAsBytes(body.nodes.items[j..item_end])) and
                    std.mem.eql(u32, hoisted.files.items, body.files.items[j..item_end])))
                {
                    local_changed = true;
                    if (hoisted.nodes.items.len > 0) {
                        self.setSuppressLeadingBlankForNode(hoisted.nodes.items[0], true);
                        // hoisted @media retains blank after block ends (legacy `preserve_stmt_gap_blank`
                        // Equivalently, between @media lifted outside the parent style_rule and the next sibling rule
                        // to leave a blank).
                        self.setPreserveAtRuleBlockFollowingBlankForNode(hoisted.nodes.items[0], true);
                    }
                    try after.appendSlice(allocator, hoisted.nodes.items, hoisted.files.items);
                } else {
                    try retained.appendSlice(allocator, body.nodes.items[j..item_end], body.files.items[j..item_end]);
                }
            } else {
                try retained.appendSlice(allocator, body.nodes.items[j..item_end], body.files.items[j..item_end]);
            }
            j = item_end;
        }

        if (!local_changed) {
            try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
            try out.appendSlice(allocator, body.nodes.items, body.files.items);
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
            return out;
        }

        changed.* = true;
        if (directRangeHasVisibleOutputInNodes(retained.nodes.items)) {
            try out.appendSlice(allocator, self.nodes.items[start_idx .. start_idx + 1], self.node_source_files.items[start_idx .. start_idx + 1]);
            try out.appendSlice(allocator, retained.nodes.items, retained.files.items);
            try out.appendSlice(allocator, self.nodes.items[block_end .. block_end + 1], self.node_source_files.items[block_end .. block_end + 1]);
        }
        try out.appendSlice(allocator, after.nodes.items, after.files.items);
        return out;
    }

    fn rebuildRuleDirectMediaHoistsDirectRange(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
        start_idx: usize,
        end_idx: usize,
        changed: *bool,
        parent_barrier: bool,
    ) error{ OutOfMemory, SassError }!RebuiltBuffers {
        var out: RebuiltBuffers = .{};
        errdefer out.deinit(allocator);

        var i = start_idx;
        while (i < end_idx) {
            const item_end = try self.topLevelItemEnd(i);
            if (item_end > end_idx) return error.SassError;

            const node = self.nodes.items[i];
            if (node.kind == .rule_begin or node.kind == .at_rule_begin) {
                var rewritten = try self.rebuildRuleDirectMediaHoistsBlock(allocator, pool, i, item_end, changed, parent_barrier);
                defer rewritten.deinit(allocator);
                try out.appendSlice(allocator, rewritten.nodes.items, rewritten.files.items);
            } else {
                try out.appendSlice(allocator, self.nodes.items[i..item_end], self.node_source_files.items[i..item_end]);
            }
            i = item_end;
        }

        return out;
    }

    fn rewriteRuleDirectMediaHoistsRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
    ) error{ OutOfMemory, SassError }!bool {
        if (self.nodes.items.len == 0) return false;

        var changed = false;
        var rewritten = try self.rebuildRuleDirectMediaHoistsDirectRange(
            allocator,
            pool,
            0,
            self.nodes.items.len,
            &changed,
            false,
        );
        errdefer rewritten.deinit(allocator);

        self.replaceNodeBuffers(allocator, rewritten.nodes, rewritten.files);
        rewritten = .{};
        return changed;
    }

    pub fn normalizeNestedMediaRuleIR(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        pool: *InternPool,
    ) error{ OutOfMemory, SassError }!void {
        var pass_count: usize = 0;
        while (pass_count < 64) : (pass_count += 1) {
            const merge_changed = try self.rewriteMergedNestedMediaRuleIR(allocator, pool);
            const direct_hoist_changed = try self.rewriteRuleDirectMediaHoistsRuleIR(allocator, pool);
            if (!merge_changed and !direct_hoist_changed) return;
        }
        return error.SassError;
    }

    fn isTopLevelCssImportItem(self: *const RuleIR, pool: *const InternPool, item: TopLevelItem) bool {
        if (item.kind != .at_rule_simple) return false;
        const name_id = self.extra.items[self.nodes.items[item.start].payload];
        return isImportAtRuleName(pool.get(@enumFromInt(name_id)));
    }

    fn isStyleOrAtRuleItemKind(kind: NodeKind) bool {
        return switch (kind) {
            .rule_begin, .at_rule_begin, .at_rule_simple => true,
            else => false,
        };
    }

    fn findLastRenderableStyleRuleInDirectRange(
        self: *const RuleIR,
        start_idx: usize,
        end_idx: usize,
    ) ?usize {
        var idx = end_idx;
        while (idx > start_idx) {
            const current = idx - 1;
            switch (self.nodes.items[current].kind) {
                .rule_end, .at_rule_end => {
                    var block_start = current;
                    while (block_start > start_idx) {
                        block_start -= 1;
                        const kind = self.nodes.items[block_start].kind;
                        if ((kind == .rule_begin or kind == .at_rule_begin) and
                            (self.findMatchingBlockEnd(block_start) orelse return null) == current)
                        {
                            break;
                        }
                    }
                    if (self.nodes.items[block_start].kind == .rule_begin) return block_start;
                    if (self.nodes.items[block_start].kind == .at_rule_begin) return null;
                    idx = current;
                },
                .rule_begin => return current,
                .decl, .decl_raw, .comment, .at_rule_simple, .at_rule_begin, .stream_chunk => return null,
                .stmt_gap, .group_boundary, .sourcemap_gap => idx = current,
            }
        }
        return null;
    }

    fn rangeHasDirectRenderableOutputRuleIR(self: *const RuleIR, start_idx: usize, end_idx: usize) bool {
        var i = start_idx;
        while (i < end_idx) {
            const item_end = self.topLevelItemEnd(i) catch return false;
            switch (self.nodes.items[i].kind) {
                .decl, .decl_raw, .comment, .rule_begin, .at_rule_begin, .at_rule_simple, .stream_chunk => return true,
                .stmt_gap, .group_boundary, .sourcemap_gap => {},
                .rule_end, .at_rule_end => return false,
            }
            i = item_end;
        }
        return false;
    }

    fn lastRenderableStyleRuleSuppressesRuleIR(self: *const RuleIR, start_idx: usize, end_idx: usize) bool {
        const idx = self.findLastRenderableStyleRuleInDirectRange(start_idx, end_idx) orelse return false;
        return self.getSuppressFollowingStmtGapBlankAt(idx);
    }

    fn markLastRenderableStyleRuleSuppressFollowingBlankRuleIR(self: *RuleIR, start_idx: usize, end_idx: usize) bool {
        const idx = self.findLastRenderableStyleRuleInDirectRange(start_idx, end_idx) orelse return false;
        self.setSuppressFollowingStmtGapBlankAt(idx, true);
        return true;
    }

    pub fn hoistTopLevelCssImportsRuleIR(self: *RuleIR, evaluator: anytype) !void {
        if (self.nodes.items.len < 2) return;

        var items = try self.collectTopLevelItems(evaluator.allocator);
        defer items.deinit(evaluator.allocator);
        if (items.items.len < 2) return;

        const marks = try evaluator.allocator.alloc(bool, items.items.len);
        defer evaluator.allocator.free(marks);
        @memset(marks, false);

        var saw_import = false;
        for (items.items, 0..) |item, idx| {
            if (!self.isTopLevelCssImportItem(evaluator.env.intern_pool, item)) continue;
            saw_import = true;
            marks[idx] = true;
            const import_source_file = item.source_file;

            var j = idx;
            while (j > 0) {
                const prev_idx = j - 1;
                switch (items.items[prev_idx].kind) {
                    .stmt_gap, .sourcemap_gap => {
                        if (items.items[prev_idx].source_file != import_source_file) break;
                        marks[prev_idx] = true;
                        j = prev_idx;
                        continue;
                    },
                    .group_boundary => break,
                    .comment => {
                        if (items.items[prev_idx].source_file != import_source_file) break;
                        marks[prev_idx] = true;
                        j = prev_idx;
                        continue;
                    },
                    else => break,
                }
            }
        }
        if (!saw_import) return;

        var reordered_nodes: std.ArrayListUnmanaged(Node) = .empty;
        errdefer reordered_nodes.deinit(evaluator.allocator);
        var reordered_files: std.ArrayListUnmanaged(u32) = .empty;
        errdefer reordered_files.deinit(evaluator.allocator);

        var last_was_boundary = true;
        var leading_end: usize = 0;
        for (items.items, 0..) |item, idx| {
            if (marks[idx]) break;
            switch (item.kind) {
                .comment => {
                    _ = try self.appendReorderedRange(
                        evaluator.allocator,
                        &reordered_nodes,
                        &reordered_files,
                        &last_was_boundary,
                        item.start,
                        item.end,
                    );
                    leading_end = idx + 1;
                },
                .group_boundary, .stmt_gap, .sourcemap_gap => {
                    leading_end = idx + 1;
                },
                else => break,
            }
        }

        for (items.items, 0..) |item, idx| {
            if (!marks[idx]) continue;
            if (isRuleIRGroupSeparatorKind(item.kind)) continue;
            _ = try self.appendReorderedRange(
                evaluator.allocator,
                &reordered_nodes,
                &reordered_files,
                &last_was_boundary,
                item.start,
                item.end,
            );
        }

        var has_unmarked = false;
        for (marks) |marked| {
            if (!marked) {
                has_unmarked = true;
                break;
            }
        }
        if (has_unmarked and reordered_nodes.items.len > 0 and
            !isRuleIRGroupSeparatorKind(reordered_nodes.items[reordered_nodes.items.len - 1].kind))
        {
            try appendSyntheticSeparator(
                evaluator.allocator,
                &reordered_nodes,
                &reordered_files,
                .group_boundary,
            );
            last_was_boundary = true;
        }

        for (items.items, 0..) |item, idx| {
            if (marks[idx] or idx < leading_end) continue;
            _ = try self.appendReorderedRange(
                evaluator.allocator,
                &reordered_nodes,
                &reordered_files,
                &last_was_boundary,
                item.start,
                item.end,
            );
        }

        if (reordered_nodes.items.len == 0) return;
        if (isRuleIRGroupSeparatorKind(reordered_nodes.items[reordered_nodes.items.len - 1].kind) and
            reordered_nodes.items[reordered_nodes.items.len - 1].kind != .sourcemap_gap)
        {
            _ = reordered_nodes.pop();
            _ = reordered_files.pop();
        }

        self.replaceNodeBuffers(evaluator.allocator, reordered_nodes, reordered_files);
    }

    pub fn suppressLeadingBlankAfterTopLevelImportsRuleIR(self: *RuleIR, pool: *const InternPool) void {
        var i: usize = 0;
        var saw_top_level_import = false;
        while (i < self.nodes.items.len) {
            const item_end = self.topLevelItemEnd(i) catch return;
            switch (self.nodes.items[i].kind) {
                .comment => {},
                .at_rule_simple => {
                    const name_id = self.extra.items[self.nodes.items[i].payload];
                    if (isImportAtRuleName(pool.get(@enumFromInt(name_id)))) {
                        saw_top_level_import = true;
                    } else if (saw_top_level_import) {
                        return;
                    } else {
                        return;
                    }
                },
                .at_rule_begin => {
                    if (!saw_top_level_import) return;
                    self.setSuppressLeadingBlankAt(i, true);
                    return;
                },
                .rule_begin => {
                    if (!saw_top_level_import) return;
                    self.setSuppressLeadingBlankAt(i, true);
                    return;
                },
                .decl, .decl_raw, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {},
                .rule_end, .at_rule_end => return,
            }
            i = item_end;
        }
    }

    pub fn normalizeTopLevelGroupBoundariesRuleIR(self: *RuleIR, evaluator: anytype) !void {
        if (self.nodes.items.len < 2) return;

        var items = try self.collectTopLevelItems(evaluator.allocator);
        defer items.deinit(evaluator.allocator);
        if (items.items.len < 2) return;

        var normalized_nodes: std.ArrayListUnmanaged(Node) = .empty;
        errdefer normalized_nodes.deinit(evaluator.allocator);
        var normalized_files: std.ArrayListUnmanaged(u32) = .empty;
        errdefer normalized_files.deinit(evaluator.allocator);

        var last_was_boundary = true;
        for (items.items, 0..) |item, idx| {
            if (!isRuleIRGroupSeparatorKind(item.kind)) {
                _ = try self.appendReorderedRange(
                    evaluator.allocator,
                    &normalized_nodes,
                    &normalized_files,
                    &last_was_boundary,
                    item.start,
                    item.end,
                );
                continue;
            }

            var prev_visible: ?NodeKind = null;
            var prev_idx = idx;
            while (prev_idx > 0) {
                prev_idx -= 1;
                if (isRuleIRGroupSeparatorKind(items.items[prev_idx].kind)) continue;
                prev_visible = items.items[prev_idx].kind;
                break;
            }

            var next_visible: ?NodeKind = null;
            var next_idx = idx + 1;
            while (next_idx < items.items.len) : (next_idx += 1) {
                if (isRuleIRGroupSeparatorKind(items.items[next_idx].kind)) continue;
                next_visible = items.items[next_idx].kind;
                break;
            }

            if (next_visible == null) {
                if (item.kind == .sourcemap_gap and prev_visible != null) {
                    try self.appendNodeRange(
                        evaluator.allocator,
                        &normalized_nodes,
                        &normalized_files,
                        item.start,
                        item.end,
                    );
                    last_was_boundary = true;
                }
                continue;
            }
            if (prev_visible == null) {
                if (item.kind == .sourcemap_gap and isStyleOrAtRuleItemKind(next_visible.?)) {
                    try self.appendNodeRange(
                        evaluator.allocator,
                        &normalized_nodes,
                        &normalized_files,
                        item.start,
                        item.end,
                    );
                    last_was_boundary = true;
                }
                continue;
            }
            if (prev_visible.? == .comment or next_visible.? == .comment) {
                if (item.kind != .group_boundary) continue;
            }

            _ = try self.appendReorderedRange(
                evaluator.allocator,
                &normalized_nodes,
                &normalized_files,
                &last_was_boundary,
                item.start,
                item.end,
            );
        }

        self.replaceNodeBuffers(evaluator.allocator, normalized_nodes, normalized_files);
    }

    fn propagateStmtGapSuppressionInRange(self: *RuleIR, start_idx: usize, end_idx: usize) void {
        var i = start_idx;
        while (i < end_idx) {
            switch (self.nodes.items[i].kind) {
                .rule_begin, .at_rule_begin => {
                    const block_end = self.findMatchingBlockEnd(i) orelse return;
                    if (block_end >= end_idx) return;
                    self.propagateStmtGapSuppressionInRange(i + 1, block_end);
                    i = block_end + 1;
                },
                .rule_end, .at_rule_end => return,
                else => i += 1,
            }
        }

        var segment_start = start_idx;
        i = start_idx;
        while (i < end_idx) {
            const item_end = self.topLevelItemEnd(i) catch return;
            if (self.nodes.items[i].kind == .stmt_gap) {
                var saw_suppress = false;
                var last_style_idx: ?usize = null;
                var saw_non_style_visible = false;
                var scan = segment_start;
                while (scan < i) {
                    const scan_end = self.topLevelItemEnd(scan) catch return;
                    switch (self.nodes.items[scan].kind) {
                        .rule_begin => {
                            if (self.getSuppressFollowingStmtGapBlankAt(scan)) saw_suppress = true;
                            last_style_idx = scan;
                        },
                        .decl, .decl_raw, .comment, .at_rule_simple, .at_rule_begin, .stream_chunk => {
                            saw_non_style_visible = true;
                        },
                        .stmt_gap, .group_boundary, .sourcemap_gap => {},
                        .rule_end, .at_rule_end => return,
                    }
                    scan = scan_end;
                }

                if (!saw_non_style_visible and saw_suppress and last_style_idx != null) {
                    self.setSuppressFollowingStmtGapBlankAt(last_style_idx.?, true);
                }

                segment_start = item_end;
            }
            i = item_end;
        }
    }

    pub fn propagateStmtGapSuppressionRuleIR(self: *RuleIR) void {
        self.propagateStmtGapSuppressionInRange(0, self.nodes.items.len);
    }

    pub fn stripTopLevelGroupBoundariesRuleIR(self: *RuleIR) void {
        var read_idx: usize = 0;
        var write_idx: usize = 0;
        var suppress_next_leading_blank = false;
        var last_kept_kind: ?NodeKind = null;
        var last_kept_suppress_following = false;

        while (read_idx < self.nodes.items.len) {
            const item_end = self.topLevelItemEnd(read_idx) catch return;
            const kind = self.nodes.items[read_idx].kind;
            const item_len = item_end - read_idx;

            if (isRuleIRGroupSeparatorKind(kind)) {
                if (kind == .stmt_gap and last_kept_kind == .rule_begin) {
                    suppress_next_leading_blank = last_kept_suppress_following;
                }
                read_idx = item_end;
                continue;
            }

            if (suppress_next_leading_blank) {
                switch (kind) {
                    .rule_begin, .at_rule_begin => self.setSuppressLeadingBlankAt(read_idx, true),
                    else => {},
                }
                suppress_next_leading_blank = false;
            }

            if (write_idx != read_idx) {
                std.mem.copyForwards(
                    Node,
                    self.nodes.items[write_idx .. write_idx + item_len],
                    self.nodes.items[read_idx..item_end],
                );
                std.mem.copyForwards(
                    u32,
                    self.node_source_files.items[write_idx .. write_idx + item_len],
                    self.node_source_files.items[read_idx..item_end],
                );
            }

            last_kept_kind = kind;
            last_kept_suppress_following = if (kind == .rule_begin)
                self.getSuppressFollowingStmtGapBlankAt(read_idx)
            else
                false;

            write_idx += item_len;
            read_idx = item_end;
        }

        self.nodes.items.len = write_idx;
        self.node_source_files.items.len = write_idx;
    }

    pub fn writeTo(self: *const RuleIR, writer: *std.Io.Writer, intern_pool: *const InternPool) !void {
        try self.writeToWithSourceMap(writer, intern_pool, null, null, .expanded, .{});
    }

    const FlushRange = struct {
        start: usize,
        end: usize,
    };

    const charset_prefix = "@charset \"UTF-8\";\n";

    pub fn flushReady(
        self: *RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *const InternPool,
        potential_extend_targets: []const InternId,
        source_locations: ?[]const SourceLocation,
    ) !usize {
        if (!self.streaming_enabled or self.streaming_threshold_nodes == 0) return 0;
        if (self.nodes.items.len < self.streaming_threshold_nodes) return 0;

        var total_flushed: usize = 0;
        while (self.nodes.items.len >= self.streaming_threshold_nodes) {
            const range = try self.findFlushableRange(intern_pool, potential_extend_targets, source_locations) orelse break;
            const rendered = try self.renderFlushRange(allocator, intern_pool, range, source_locations);
            defer if (rendered.tmp_range_node_source_files) |buf| allocator.free(buf);
            defer if (rendered.tmp_range_nodes) |buf| allocator.free(buf);

            // The end of range is the same as inline trailing comment (immediately after rule_end/at_rule_end)
            // If it is a comment on the source line, set the flag and write it on the writer side.
            // Allow `prev_visible_is_comment` to be inherited.
            var ends_with_inline_comment = false;
            var ends_with_at_rule_block = false;
            if (range.end > range.start) {
                // End (comment if there is an inline comment, otherwise block-end)
                const last_node = self.nodes.items[range.end - 1];
                if (last_node.kind == .comment) {
                    ends_with_inline_comment = true;
                } else if (last_node.kind == .at_rule_end) {
                    // Immediately after rendered chunk is at-rule block (official Sass CLI `skip_consecutive_top_rules`
                    // Treated as the same as blank and suppressed). However, the corresponding at_rule_begin
                    // If preserve_at_rule_block_following_blank is set (hoisted @media etc.)
                    // Don't set ends_with_at_rule_block to keep the blank before the next rule.
                    const match_begin = self.findMatchingAtRuleBeginBackward(range.start, range.end - 1);
                    const preserve_following = if (match_begin) |begin_idx|
                        self.getPreserveAtRuleBlockFollowingBlankAt(begin_idx)
                    else
                        false;
                    if (!preserve_following) ends_with_at_rule_block = true;
                }
            }

            self.freeFlushedDeclRawStrings(allocator, range);
            if (rendered.css.len == 0 and !rendered.needs_charset) {
                allocator.free(rendered.css);
                self.replaceNodeRangeWithStreamChunk(range, null);
            } else {
                const chunk_idx: u32 = @intCast(self.flushed_chunks.items.len);
                try self.flushed_chunks.append(allocator, .{
                    .css = rendered.css,
                    .needs_charset = rendered.needs_charset,
                    .ends_with_inline_comment = ends_with_inline_comment,
                    .ends_with_at_rule_block = ends_with_at_rule_block,
                });
                self.replaceNodeRangeWithStreamChunk(range, chunk_idx);
            }
            total_flushed += range.end - range.start;
        }

        return total_flushed;
    }

    /// If block_end (rule_end / at_rule_end) is immediately followed by a comment on the same source line,
    /// Returns end index including that comment. stmt_gap / sourcemap_gap / group_boundary is
    /// It can be found right before the comment, so it can be skipped and searched (the compiler uses `}/* */` top-level
    /// Insert gap as a sentence boundary). Returns input `end` if not on the same line / if not comment.
    fn extendRangeWithInlineTrailingComment(
        self: *const RuleIR,
        block_end: usize,
        end: usize,
        source_locations: ?[]const SourceLocation,
    ) usize {
        const locs = source_locations orelse return end;
        if (block_end >= self.node_source_files.items.len) return end;
        const block_file = self.node_source_files.items[block_end];
        if (block_file >= locs.len) return end;
        const block_node = self.nodes.items[block_end];
        const block_offset = if (block_node.source_end > block_node.source_start) block_node.source_end - 1 else block_node.source_start;
        const block_line = RuleIR.sourceOffsetToLineCol(locs[block_file], block_offset).line;

        var j: usize = end;
        while (j < self.nodes.items.len) {
            const kind = self.nodes.items[j].kind;
            switch (kind) {
                .stmt_gap, .group_boundary, .sourcemap_gap => {
                    j += 1;
                },
                .comment => break,
                else => return end,
            }
        }
        if (j >= self.nodes.items.len) return end;
        if (j >= self.node_source_files.items.len) return end;
        if (self.node_source_files.items[j] != block_file) return end;
        const comment_node = self.nodes.items[j];
        const comment_line = RuleIR.sourceOffsetToLineCol(locs[block_file], comment_node.source_start).line;
        if (block_line != comment_line) return end;
        return j + 1;
    }

    fn findFlushableRange(
        self: *const RuleIR,
        intern_pool: *const InternPool,
        potential_extend_targets: []const InternId,
        source_locations: ?[]const SourceLocation,
    ) !?FlushRange {
        var i: usize = 0;
        var saw_body = false;
        var start: ?usize = null;
        var end: usize = 0;

        while (i < self.nodes.items.len) {
            const node = self.nodes.items[i];
            switch (node.kind) {
                .comment, .at_rule_simple, .stmt_gap, .group_boundary, .sourcemap_gap => {
                    if (saw_body) break;
                    i += 1;
                },
                .stream_chunk => {
                    saw_body = true;
                    i += 1;
                },
                .rule_begin, .at_rule_begin => {
                    saw_body = true;
                    const block_end = self.findMatchingTopLevelBlockEnd(i) orelse break;
                    const range_end_before_comment = block_end + 1;
                    const range: FlushRange = .{ .start = i, .end = range_end_before_comment };
                    if (!(try self.rangeCouldBeAffectedByPotentialExtends(
                        intern_pool,
                        range,
                        potential_extend_targets,
                    ))) {
                        if (start == null) start = i;
                        end = self.extendRangeWithInlineTrailingComment(
                            block_end,
                            range_end_before_comment,
                            source_locations,
                        );
                    } else if (start != null) {
                        break;
                    }
                    i = range_end_before_comment;
                },
                .rule_end, .at_rule_end, .decl, .decl_raw => {
                    if (saw_body) break;
                    i += 1;
                },
            }
        }

        if (start) |s| {
            if (end > s) return .{ .start = s, .end = end };
        }
        return null;
    }

    fn findMatchingTopLevelBlockEnd(self: *const RuleIR, start_idx: usize) ?usize {
        if (start_idx >= self.nodes.items.len) return null;
        const start_kind = self.nodes.items[start_idx].kind;
        if (start_kind != .rule_begin and start_kind != .at_rule_begin) return null;

        var depth: usize = 0;
        var i = start_idx;
        while (i < self.nodes.items.len) : (i += 1) {
            switch (self.nodes.items[i].kind) {
                .rule_begin, .at_rule_begin => depth += 1,
                .rule_end, .at_rule_end => {
                    if (depth == 0) return null;
                    depth -= 1;
                    if (depth == 0) return i;
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stmt_gap, .group_boundary, .sourcemap_gap, .stream_chunk => {},
            }
        }
        return null;
    }

    fn rangeCouldBeAffectedByPotentialExtends(
        self: *const RuleIR,
        intern_pool: *const InternPool,
        range: FlushRange,
        potential_extend_targets: []const InternId,
    ) !bool {
        if (potential_extend_targets.len == 0) return false;

        var i = range.start;
        while (i < range.end) : (i += 1) {
            const node = self.nodes.items[i];
            if (node.kind != .rule_begin) continue;
            const selector_id = self.extra.items[node.payload];
            if (try selectorCouldMatchPotentialExtends(
                intern_pool,
                intern_pool.get(@enumFromInt(selector_id)),
                potential_extend_targets,
            )) {
                return true;
            }
        }

        return false;
    }

    fn selectorCouldMatchPotentialExtends(
        intern_pool: *const InternPool,
        selector_raw: []const u8,
        potential_extend_targets: []const InternId,
    ) !bool {
        if (selector_raw.len == 0) return false;
        if (containsUnresolvedSelectorInterpolation(selector_raw)) return true;

        var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer temp_arena.deinit();
        const temp = temp_arena.allocator();

        var selector_text = selector_raw;
        const attr_normalized = try css_utils.normalizeAttributeSelectors(temp, selector_raw);
        if (!(attr_normalized.ptr == selector_raw.ptr and attr_normalized.len == selector_raw.len)) {
            selector_text = attr_normalized;
        }

        var parsed_selector = selector_mod.parse(temp, selector_text) catch return true;
        defer parsed_selector.deinit();
        if (selector_mod.hasParentReference(&parsed_selector)) return true;

        for (potential_extend_targets) |target_id| {
            const target_raw = intern_pool.get(target_id);
            if (target_raw.len == 0) continue;
            if (std.mem.find(u8, selector_text, target_raw) != null) return true;

            var parsed_target = selector_mod.parse(temp, target_raw) catch return true;
            defer parsed_target.deinit();
            if (parsed_target.selectors.items.len != 1) return true;
            const target_compound = singleExtendTargetCompound(&parsed_target.selectors.items[0]) orelse return true;
            if (target_compound.simple_selectors.items.len != 1) return true;

            for (parsed_selector.selectors.items) |selector_complex| {
                if (complexCouldContainTarget(&selector_complex, &target_compound)) return true;
            }
        }

        return false;
    }

    fn complexCouldContainTarget(
        complex: *const selector_mod.ComplexSelector,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        for (complex.components.items) |component| {
            switch (component) {
                .compound => |compound| {
                    if (extend_mod.compoundContainsTarget(&compound, target)) return true;
                    if (compoundPseudosCouldContainTarget(&compound, target)) return true;
                },
                .combinator => {},
            }
        }
        return false;
    }

    fn compoundPseudosCouldContainTarget(
        compound: *const selector_mod.CompoundSelector,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        for (compound.simple_selectors.items) |ss| {
            switch (ss) {
                .pseudo_class => |ps| {
                    if (ps.selector) |inner| {
                        for (inner.selectors.items) |inner_complex| {
                            if (complexCouldContainTarget(&inner_complex, target)) return true;
                        }
                    }
                },
                .pseudo_element => |ps| {
                    if (ps.selector) |inner| {
                        for (inner.selectors.items) |inner_complex| {
                            if (complexCouldContainTarget(&inner_complex, target)) return true;
                        }
                    }
                },
                else => {},
            }
        }
        return false;
    }

    const RenderedFlushRange = struct {
        css: []const u8,
        needs_charset: bool,
        tmp_range_nodes: ?[]Node = null,
        tmp_range_node_source_files: ?[]u32 = null,
    };

    fn renderFlushRange(
        self: *const RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *const InternPool,
        range: FlushRange,
        source_locations: ?[]const SourceLocation,
    ) !RenderedFlushRange {
        const range_nodes = try allocator.dupe(Node, self.nodes.items[range.start..range.end]);
        errdefer allocator.free(range_nodes);
        const range_source_files = try allocator.dupe(u32, self.node_source_files.items[range.start..range.end]);
        errdefer allocator.free(range_source_files);
        const relevant_extend_edges = try allocator.alloc(bool, self.extend_edges.items.len);
        defer allocator.free(relevant_extend_edges);
        @memset(relevant_extend_edges, false);
        for (self.extend_edges.items, 0..) |edge, edge_idx| {
            relevant_extend_edges[edge_idx] = rangeContainsExtendTarget(
                allocator,
                intern_pool,
                range_nodes,
                range_source_files,
                self.extra.items,
                edge,
            );
        }
        var relevant_changed = true;
        while (relevant_changed) {
            relevant_changed = false;
            for (self.extend_edges.items, 0..) |edge, edge_idx| {
                if (relevant_extend_edges[edge_idx]) continue;
                const target_raw = intern_pool.get(edge.target_selector);
                if (target_raw.len == 0) continue;

                var parsed_target_opt: ?selector_mod.SelectorList = selector_mod.parse(allocator, target_raw) catch null;
                defer if (parsed_target_opt) |*parsed_target| parsed_target.deinit();

                var target_compound_opt: ?selector_mod.CompoundSelector = null;
                if (parsed_target_opt) |*parsed_target| {
                    if (parsed_target.selectors.items.len != 0) {
                        target_compound_opt = singleExtendTargetCompound(&parsed_target.selectors.items[0]);
                    }
                }
                const target_compound = target_compound_opt orelse continue;

                for (self.extend_edges.items, 0..) |carrier, carrier_idx| {
                    if (!relevant_extend_edges[carrier_idx]) continue;
                    if (carrier.target_module != edge.target_module) continue;
                    const carrier_extending_raw = intern_pool.get(carrier.extending_selector);
                    if (carrier_extending_raw.len == 0) continue;
                    if (!selectorRawContainsTargetCompound(allocator, carrier_extending_raw, &target_compound)) continue;
                    relevant_extend_edges[edge_idx] = true;
                    relevant_changed = true;
                    break;
                }
            }
        }
        var range_extend_edges: std.ArrayListUnmanaged(ExtendEdge) = .empty;
        defer range_extend_edges.deinit(allocator);
        try range_extend_edges.ensureTotalCapacity(allocator, self.extend_edges.items.len);
        for (self.extend_edges.items, 0..) |edge, edge_idx| {
            if (!relevant_extend_edges[edge_idx]) continue;
            range_extend_edges.appendAssumeCapacity(edge);
        }

        var subset: RuleIR = .{
            .nodes = .{ .items = range_nodes, .capacity = range_nodes.len },
            .node_source_files = .{ .items = range_source_files, .capacity = range_source_files.len },
            .extra = .{ .items = @constCast(self.extra.items), .capacity = self.extra.items.len },
            .strings = .{ .items = @constCast(self.strings.items), .capacity = self.strings.items.len },
            .extend_edges = range_extend_edges,
            .extend_relation_media = self.extend_relation_media,
            .module_visibility_matrix = self.module_visibility_matrix,
            .module_visibility_n = self.module_visibility_n,
            .flushed_chunks = .{ .items = @constCast(self.flushed_chunks.items), .capacity = self.flushed_chunks.items.len },
        };

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        {
            var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
            try subset.writeToWithSourceMap(&aw.writer, intern_pool, null, source_locations, .expanded, .{});
            buf = aw.toArrayList();
        }

        if (std.mem.startsWith(u8, buf.items, charset_prefix)) {
            const stripped = try allocator.dupe(u8, buf.items[charset_prefix.len..]);
            buf.deinit(allocator);
            return .{
                .css = stripped,
                .needs_charset = true,
                .tmp_range_nodes = range_nodes,
                .tmp_range_node_source_files = range_source_files,
            };
        }

        return .{
            .css = try buf.toOwnedSlice(allocator),
            .needs_charset = false,
            .tmp_range_nodes = range_nodes,
            .tmp_range_node_source_files = range_source_files,
        };
    }

    fn freeFlushedDeclRawStrings(self: *RuleIR, allocator: std.mem.Allocator, range: FlushRange) void {
        var i = range.start;
        while (i < range.end) : (i += 1) {
            const node = self.nodes.items[i];
            if (node.kind != .decl_raw) continue;
            const raw_idx = self.extra.items[node.payload + 1];
            if (raw_idx >= self.strings.items.len) continue;
            const raw = self.strings.items[raw_idx];
            if (raw.len == 0) continue;
            allocator.free(raw);
            self.strings.items[raw_idx] = "";
        }
    }

    fn replaceNodeRangeWithStreamChunk(self: *RuleIR, range: FlushRange, maybe_chunk_idx: ?u32) void {
        const remove_len = range.end - range.start;
        if (remove_len == 0) return;

        const file_id: u32 = if (range.start < self.node_source_files.items.len)
            self.node_source_files.items[range.start]
        else
            0;
        const source_start: u32 = self.nodes.items[range.start].source_start;
        const source_end: u32 = self.nodes.items[range.end - 1].source_end;
        const insert_len: usize = if (maybe_chunk_idx != null) 1 else 0;
        const tail_len = self.nodes.items.len - range.end;

        if (maybe_chunk_idx) |chunk_idx| {
            self.nodes.items[range.start] = .{
                .kind = .stream_chunk,
                .payload = chunk_idx,
                .source_start = source_start,
                .source_end = source_end,
            };
            self.node_source_files.items[range.start] = file_id;
            if (tail_len != 0) {
                std.mem.copyForwards(
                    Node,
                    self.nodes.items[range.start + 1 .. range.start + 1 + tail_len],
                    self.nodes.items[range.end .. range.end + tail_len],
                );
                std.mem.copyForwards(
                    u32,
                    self.node_source_files.items[range.start + 1 .. range.start + 1 + tail_len],
                    self.node_source_files.items[range.end .. range.end + tail_len],
                );
            }
        } else if (tail_len != 0) {
            std.mem.copyForwards(
                Node,
                self.nodes.items[range.start .. range.start + tail_len],
                self.nodes.items[range.end .. range.end + tail_len],
            );
            std.mem.copyForwards(
                u32,
                self.node_source_files.items[range.start .. range.start + tail_len],
                self.node_source_files.items[range.end .. range.end + tail_len],
            );
        }

        self.nodes.items.len = self.nodes.items.len - remove_len + insert_len;
        self.node_source_files.items.len = self.node_source_files.items.len - remove_len + insert_len;
    }

    /// Returns the maximum value of module id appearing from `extend_edges` and `node_source_files` +1.
    /// Use as the bucket number of `RuleModuleExtendState`.
    fn computeExtendModuleStoreCount(self: *const RuleIR) usize {
        var max_module_plus_one: u32 = 1;
        for (self.extend_edges.items) |edge| {
            if (edge.target_module == std.math.maxInt(u32)) continue;
            const plus_one = edge.target_module + 1;
            if (plus_one > max_module_plus_one) max_module_plus_one = plus_one;
        }
        for (self.node_source_files.items) |mid| {
            if (mid == std.math.maxInt(u32)) continue;
            const plus_one = mid + 1;
            if (plus_one > max_module_plus_one) max_module_plus_one = plus_one;
        }
        return @intCast(max_module_plus_one);
    }

    /// Traverse all `extend_edges` and add them to `extend_state`.
    /// `edge_eligible[]` (edge that could be put into state), `edge_required_unmatched[]`
    /// (non-optional edge where target is neither raw nor via carrier in module)
    /// Fill at the same time. Call `extend_state.finalize()` at the end.
    fn populateExtendStateFromEdges(
        self: *const RuleIR,
        intern_pool: *const InternPool,
        temp: std.mem.Allocator,
        extend_state: *extend_mod.RuleModuleExtendState,
        module_store_count: usize,
        rule_nodes_by_module: []const std.ArrayListUnmanaged(u32),
        edge_eligible: []bool,
        edge_required_unmatched: []bool,
        edge_duplicate_satisfied: []bool,
    ) !void {
        // Cache Parse / suppress / carrier-match results in intern_id units.
        // Set `registerVisibleLoadCssModule` to the same (extending, target)
        // repeatedly. The cache hit rate is very high due to many duplicates
        // with different target_modules.
        var raw_parse_cache: std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList) = .empty;
        defer {
            var it = raw_parse_cache.valueIterator();
            while (it.next()) |slot| {
                if (slot.*) |ptr| {
                    ptr.deinit();
                    temp.destroy(ptr);
                }
            }
            raw_parse_cache.deinit(temp);
        }

        // `selectorRawContainsTargetCompound` uses attribute normalization + comment stripping
        // Pass through and parse. Separate cache because the result may be different from raw parse.
        var normalized_parse_cache: std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList) = .empty;
        defer {
            var it = normalized_parse_cache.valueIterator();
            while (it.next()) |slot| {
                if (slot.*) |ptr| {
                    ptr.deinit();
                    temp.destroy(ptr);
                }
            }
            normalized_parse_cache.deinit(temp);
        }

        const module_simple_presence = try buildModuleSimplePresence(
            self,
            temp,
            intern_pool,
            rule_nodes_by_module,
            &normalized_parse_cache,
        );
        defer deinitModuleSimplePresence(temp, module_simple_presence);

        var suppress_cache: std.AutoHashMapUnmanaged(InternId, bool) = .empty;
        defer suppress_cache.deinit(temp);
        try suppress_cache.ensureTotalCapacity(temp, @intCast(self.extend_edges.items.len));

        //(target_module, target_selector_intern, complex_idx)  ->  moduleHasRawTargetCompound result.
        // Cache hits are dominant because the same (module, target) combination is repeated on a large number of edges.
        const TargetCheckKey = struct {
            target_module: u32,
            target_sel: InternId,
            complex_idx: u32,
        };
        var raw_present_cache: std.AutoHashMapUnmanaged(TargetCheckKey, bool) = .empty;
        defer raw_present_cache.deinit(temp);
        try raw_present_cache.ensureTotalCapacity(temp, @intCast(self.extend_edges.items.len));

        //(source_module, target_module, target_selector_intern, complex_idx)  ->  has_visible_carrier result.
        const CarrierKey = struct {
            source_module: u32,
            target_module: u32,
            target_sel: InternId,
            complex_idx: u32,
        };
        var carrier_cache: std.AutoHashMapUnmanaged(CarrierKey, bool) = .empty;
        defer carrier_cache.deinit(temp);
        try carrier_cache.ensureTotalCapacity(temp, @intCast(self.extend_edges.items.len));

        // Convert edge index to bucket for each target_module and eliminate inner linear scan
        // (Previously O(E^2) for extend_edges full scan).
        var carriers_by_module: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
        defer {
            var it = carriers_by_module.valueIterator();
            while (it.next()) |list| list.deinit(temp);
            carriers_by_module.deinit(temp);
        }
        const carrier_raw_presence = try temp.alloc(ModuleSimplePresence, module_store_count);
        for (carrier_raw_presence) |*presence| presence.* = .{};
        defer deinitModuleSimplePresence(temp, carrier_raw_presence);
        for (self.extend_edges.items, 0..) |edge, idx| {
            const gop = try carriers_by_module.getOrPut(temp, edge.target_module);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(temp, @intCast(idx));
            if (edge.target_module < module_store_count) {
                const carrier_extending_raw = intern_pool.get(edge.extending_selector);
                try collectRawSelectorSimplePresence(temp, &carrier_raw_presence[@intCast(edge.target_module)], carrier_extending_raw);
            }
        }

        for (self.extend_edges.items, 0..) |edge, edge_idx| {
            const target_module_idx: usize = if (edge.target_module < module_store_count)
                @intCast(edge.target_module)
            else
                0;

            const target_raw = intern_pool.get(edge.target_selector);
            const extending_raw = intern_pool.get(edge.extending_selector);
            if (target_raw.len == 0 or extending_raw.len == 0) continue;

            // Module-system @extend is scoped to the target modules visible
            // from the extension's defining module. A sibling forwarded by the
            // same barrel module is not visible to that extension, even though
            // both modules' CSS appears in the final output.
            if (edge.target_module < self.module_visibility_n and
                edge.target_module != edge.source_module and
                !self.sourceModuleCanSee(edge.source_module, edge.target_module))
            {
                if (!edge.optional) edge_required_unmatched[edge_idx] = true;
                continue;
            }

            const suppressed = blk: {
                if (suppress_cache.get(edge.extending_selector)) |v| break :blk v;
                const v = try shouldSuppressExtendingSelector(temp, extending_raw);
                try suppress_cache.put(temp, edge.extending_selector, v);
                break :blk v;
            };
            if (suppressed) continue;

            // VM keeps @extend selector as raw text, so
            // Skip anything containing unresolved interpolation marker (`#{...}`) here.
            if (containsUnresolvedSelectorInterpolation(target_raw) or
                containsUnresolvedSelectorInterpolation(extending_raw))
            {
                continue;
            }

            const target_list = (try getOrParseRawCached(&raw_parse_cache, temp, intern_pool, edge.target_selector)) orelse return error.SassError;
            if (selector_mod.hasParentReference(target_list)) return error.SassError;

            const extending_list = (try getOrParseRawCached(&raw_parse_cache, temp, intern_pool, edge.extending_selector)) orelse return error.SassError;
            if (selector_mod.hasParentReference(extending_list)) return error.SassError;

            for (target_list.selectors.items, 0..) |target_complex, complex_idx_usize| {
                const complex_idx: u32 = @intCast(complex_idx_usize);
                const target_compound = singleExtendTargetCompound(&target_complex) orelse return error.SassError;
                if (target_compound.simple_selectors.items.len != 1) return error.SassError;

                const raw_check_key = TargetCheckKey{
                    .target_module = edge.target_module,
                    .target_sel = edge.target_selector,
                    .complex_idx = complex_idx,
                };
                const raw_target_present = blk: {
                    if (raw_present_cache.get(raw_check_key)) |v| break :blk v;
                    const v = moduleHasRawTargetCompound(
                        self,
                        temp,
                        intern_pool,
                        edge.target_module,
                        &target_compound,
                        rule_nodes_by_module,
                        &normalized_parse_cache,
                        module_simple_presence,
                    );
                    try raw_present_cache.put(temp, raw_check_key, v);
                    break :blk v;
                };

                if (!raw_target_present) {
                    const carrier_key = CarrierKey{
                        .source_module = edge.source_module,
                        .target_module = edge.target_module,
                        .target_sel = edge.target_selector,
                        .complex_idx = complex_idx,
                    };
                    const has_visible_carrier = blk: {
                        if (carrier_cache.get(carrier_key)) |v| break :blk v;
                        var found = false;
                        const module_has_any_raw_carrier = edge.target_module < carrier_raw_presence.len and
                            moduleRawPresenceMayContainTarget(&carrier_raw_presence[@intCast(edge.target_module)], &target_compound);
                        if (module_has_any_raw_carrier) if (carriers_by_module.get(edge.target_module)) |carrier_indices| {
                            for (carrier_indices.items) |carrier_idx_u32| {
                                const carrier_idx: usize = @intCast(carrier_idx_u32);
                                const carrier = self.extend_edges.items[carrier_idx];
                                if (carrier.source_module != edge.source_module and
                                    !self.sourceModuleCanSee(edge.source_module, carrier.source_module))
                                {
                                    continue;
                                }
                                const carrier_extending_raw = intern_pool.get(carrier.extending_selector);
                                if (carrier_extending_raw.len == 0) continue;
                                if (!rawSelectorMayContainSimpleTarget(carrier_extending_raw, &target_compound)) continue;
                                const carrier_parsed = getOrParseNormalizedCached(
                                    &normalized_parse_cache,
                                    temp,
                                    intern_pool,
                                    carrier.extending_selector,
                                ) orelse continue;
                                if (!selectorListContainsTargetCompound(carrier_parsed, &target_compound)) continue;
                                found = true;
                                break;
                            }
                        };
                        try carrier_cache.put(temp, carrier_key, found);
                        break :blk found;
                    };
                    if (!has_visible_carrier and !compoundIsSelectorPseudoTarget(&target_compound)) {
                        if (!edge.optional) edge_required_unmatched[edge_idx] = true;
                        continue;
                    }
                }

                edge_eligible[edge_idx] = true;
                if (!(try extend_state.addModuleEdge(
                    target_module_idx,
                    @intCast(edge_idx),
                    extending_list,
                    &target_compound,
                    .{
                        .optional = edge.optional,
                        .span = null,
                        .statement_group_order = edge.relation_id,
                        .statement_order = edge.relation_order,
                        .statement_branch_index = edge.relation_branch_index,
                        .statement_branch_leading_newline = edge.relation_branch_leading_newline,
                        .module_group_start_order = edge.module_group_start_order,
                    },
                ))) {
                    edge_duplicate_satisfied[edge_idx] = true;
                }
            }
        }
        try extend_state.finalize();
    }

    fn getOrParseRawCached(
        cache: *std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList),
        temp: std.mem.Allocator,
        intern_pool: *const InternPool,
        id: InternId,
    ) !?*selector_mod.SelectorList {
        const gop = try cache.getOrPut(temp, id);
        if (gop.found_existing) return gop.value_ptr.*;
        const raw = intern_pool.get(id);
        var parsed = selector_mod.parse(temp, raw) catch {
            gop.value_ptr.* = null;
            return null;
        };
        const heap = temp.create(selector_mod.SelectorList) catch |err| {
            parsed.deinit();
            return err;
        };
        heap.* = parsed;
        gop.value_ptr.* = heap;
        return heap;
    }

    fn getOrParseNormalizedCached(
        cache: *std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList),
        temp: std.mem.Allocator,
        intern_pool: *const InternPool,
        id: InternId,
    ) ?*const selector_mod.SelectorList {
        const gop = cache.getOrPut(temp, id) catch return null;
        if (gop.found_existing) return gop.value_ptr.*;

        const raw = intern_pool.get(id);
        const attr_normalized = css_utils.normalizeAttributeSelectors(temp, raw) catch {
            gop.value_ptr.* = null;
            return null;
        };
        const comments_stripped = stripSelectorCommentsForMatching(temp, attr_normalized) catch {
            gop.value_ptr.* = null;
            return null;
        };
        const selector_text = comments_stripped;

        var parsed = selector_mod.parse(temp, selector_text) catch {
            gop.value_ptr.* = null;
            return null;
        };
        const heap = temp.create(selector_mod.SelectorList) catch {
            parsed.deinit();
            gop.value_ptr.* = null;
            return null;
        };
        heap.* = parsed;
        gop.value_ptr.* = heap;
        return heap;
    }

    fn selectorListContainsTargetCompound(
        list: *const selector_mod.SelectorList,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        for (list.selectors.items) |complex| {
            if (complexContainsTargetCompound(&complex, target)) return true;
        }
        return false;
    }

    const ModuleSimplePresence = struct {
        complete: bool = true,
        classes: std.StringHashMapUnmanaged(void) = .empty,
        ids: std.StringHashMapUnmanaged(void) = .empty,
        placeholders: std.StringHashMapUnmanaged(void) = .empty,
        types: std.StringHashMapUnmanaged(void) = .empty,
        raw_classes: std.StringHashMapUnmanaged(void) = .empty,
        raw_ids: std.StringHashMapUnmanaged(void) = .empty,
        raw_placeholders: std.StringHashMapUnmanaged(void) = .empty,

        fn deinit(self: *ModuleSimplePresence, allocator: std.mem.Allocator) void {
            self.classes.deinit(allocator);
            self.ids.deinit(allocator);
            self.placeholders.deinit(allocator);
            self.types.deinit(allocator);
            self.raw_classes.deinit(allocator);
            self.raw_ids.deinit(allocator);
            self.raw_placeholders.deinit(allocator);
        }
    };

    fn isSelectorIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn rawSelectorMayContainPrefixedName(selector_raw: []const u8, prefix: u8, name: []const u8) bool {
        if (name.len == 0) return true;
        for (name) |c| {
            if (!isSelectorIdentChar(c)) return true;
        }
        var i: usize = 0;
        while (i + 1 + name.len <= selector_raw.len) : (i += 1) {
            if (selector_raw[i] != prefix) continue;
            const start = i + 1;
            if (!std.mem.eql(u8, selector_raw[start .. start + name.len], name)) continue;
            const end = start + name.len;
            if (end < selector_raw.len and isSelectorIdentChar(selector_raw[end])) continue;
            return true;
        }
        return false;
    }

    fn rawSelectorMayContainSimpleTarget(
        selector_raw: []const u8,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        if (target.simple_selectors.items.len != 1) return true;
        return switch (target.simple_selectors.items[0]) {
            .class => |name| rawSelectorMayContainPrefixedName(selector_raw, '.', name),
            .id => |name| rawSelectorMayContainPrefixedName(selector_raw, '#', name),
            .placeholder => |name| rawSelectorMayContainPrefixedName(selector_raw, '%', name),
            else => true,
        };
    }

    fn collectRawSelectorSimplePresence(
        allocator: std.mem.Allocator,
        presence: *ModuleSimplePresence,
        selector_raw: []const u8,
    ) !void {
        var i: usize = 0;
        while (i < selector_raw.len) : (i += 1) {
            const c = selector_raw[i];
            if (c != '.' and c != '#' and c != '%') continue;
            const start = i + 1;
            if (start >= selector_raw.len or !isSelectorIdentChar(selector_raw[start])) continue;
            var end = start + 1;
            while (end < selector_raw.len and isSelectorIdentChar(selector_raw[end])) : (end += 1) {}
            const name = selector_raw[start..end];
            switch (c) {
                '.' => try presence.raw_classes.put(allocator, name, {}),
                '#' => try presence.raw_ids.put(allocator, name, {}),
                '%' => try presence.raw_placeholders.put(allocator, name, {}),
                else => unreachable,
            }
            i = end - 1;
        }
    }

    fn collectCompoundSimplePresence(
        allocator: std.mem.Allocator,
        presence: *ModuleSimplePresence,
        compound: *const selector_mod.CompoundSelector,
    ) std.mem.Allocator.Error!void {
        for (compound.simple_selectors.items) |ss| {
            switch (ss) {
                .class => |name| try presence.classes.put(allocator, name, {}),
                .id => |name| try presence.ids.put(allocator, name, {}),
                .placeholder => |name| try presence.placeholders.put(allocator, name, {}),
                .type_selector => |name| try presence.types.put(allocator, name, {}),
                .pseudo_class => |ps| {
                    if (ps.selector) |inner| try collectSelectorListSimplePresence(allocator, presence, inner);
                },
                .pseudo_element => |ps| {
                    if (ps.selector) |inner| try collectSelectorListSimplePresence(allocator, presence, inner);
                },
                .attribute, .parent, .universal => {},
            }
        }
    }

    fn collectComplexSimplePresence(
        allocator: std.mem.Allocator,
        presence: *ModuleSimplePresence,
        complex: *const selector_mod.ComplexSelector,
    ) std.mem.Allocator.Error!void {
        for (complex.components.items) |comp| {
            switch (comp) {
                .compound => |compound| try collectCompoundSimplePresence(allocator, presence, &compound),
                .combinator => {},
            }
        }
    }

    fn collectSelectorListSimplePresence(
        allocator: std.mem.Allocator,
        presence: *ModuleSimplePresence,
        list: *const selector_mod.SelectorList,
    ) std.mem.Allocator.Error!void {
        for (list.selectors.items) |complex| {
            try collectComplexSimplePresence(allocator, presence, &complex);
        }
    }

    fn buildModuleSimplePresence(
        self_ir: *const RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *const InternPool,
        rule_nodes_by_module: []const std.ArrayListUnmanaged(u32),
        normalized_parse_cache: *std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList),
    ) ![]ModuleSimplePresence {
        const result = try allocator.alloc(ModuleSimplePresence, rule_nodes_by_module.len);
        for (result) |*presence| presence.* = .{};
        errdefer deinitModuleSimplePresence(allocator, result);

        for (rule_nodes_by_module, 0..) |rule_nodes, module_id| {
            const presence = &result[module_id];
            for (rule_nodes.items) |node_idx_u32| {
                const idx: usize = @intCast(node_idx_u32);
                const node = self_ir.nodes.items[idx];
                const selector_id = self_ir.extra.items[node.payload];
                const selector_intern: InternId = @enumFromInt(selector_id);
                const selector_raw = intern_pool.get(selector_intern);
                try collectRawSelectorSimplePresence(allocator, presence, selector_raw);
                const parsed = getOrParseNormalizedCached(
                    normalized_parse_cache,
                    allocator,
                    intern_pool,
                    selector_intern,
                ) orelse {
                    presence.complete = false;
                    continue;
                };
                try collectSelectorListSimplePresence(allocator, presence, parsed);
            }
        }
        return result;
    }

    fn deinitModuleSimplePresence(
        allocator: std.mem.Allocator,
        presence: []ModuleSimplePresence,
    ) void {
        for (presence) |*module_presence| module_presence.deinit(allocator);
        allocator.free(presence);
    }

    fn modulePresenceMayContainTarget(
        presence: *const ModuleSimplePresence,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        if (!presence.complete) return true;
        if (target.simple_selectors.items.len != 1) return true;
        return switch (target.simple_selectors.items[0]) {
            .class => |name| presence.classes.contains(name),
            .id => |name| presence.ids.contains(name),
            .placeholder => |name| presence.placeholders.contains(name),
            .type_selector => |name| presence.types.contains(name),
            else => true,
        };
    }

    fn moduleRawPresenceMayContainTarget(
        presence: *const ModuleSimplePresence,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        if (target.simple_selectors.items.len != 1) return true;
        return switch (target.simple_selectors.items[0]) {
            .class => |name| presence.raw_classes.contains(name),
            .id => |name| presence.raw_ids.contains(name),
            .placeholder => |name| presence.raw_placeholders.contains(name),
            else => true,
        };
    }

    fn modulePresenceKnowsSimpleTarget(
        presence: *const ModuleSimplePresence,
        target: *const selector_mod.CompoundSelector,
    ) ?bool {
        if (target.simple_selectors.items.len != 1) return null;
        const contains = switch (target.simple_selectors.items[0]) {
            .class => |name| presence.classes.contains(name),
            .id => |name| presence.ids.contains(name),
            .placeholder => |name| presence.placeholders.contains(name),
            .type_selector => |name| presence.types.contains(name),
            else => null,
        };
        if (presence.complete or contains.?) return contains;
        const raw_contains = switch (target.simple_selectors.items[0]) {
            .class => |name| presence.raw_classes.contains(name),
            .id => |name| presence.raw_ids.contains(name),
            .placeholder => |name| presence.raw_placeholders.contains(name),
            else => true,
        };
        if (!raw_contains) return false;
        return null;
    }

    fn ruleBodyIsCommentOnly(
        self: *const RuleIR,
        skip: []const bool,
        begin_idx: usize,
        end_idx: usize,
    ) bool {
        var saw_comment = false;
        var idx = begin_idx + 1;
        while (idx < end_idx) : (idx += 1) {
            if (skip[idx]) continue;
            switch (self.nodes.items[idx].kind) {
                .comment => saw_comment = true,
                .stmt_gap, .group_boundary, .sourcemap_gap => {},
                else => return false,
            }
        }
        return saw_comment;
    }

    /// Case where official Sass CLI merges into 1 block among adjacent `rule_end`  <->  `rule_begin`
    /// Detect (compiler-synthesized close+reopen) and `skip[]` (eliminate intermediate end)
    /// Mark `merge_same_rule_begin[]` (continued by next rule_begin).
    fn computeAdjacentRuleMerges(
        self: *const RuleIR,
        temp: std.mem.Allocator,
        skip: []bool,
        merge_same_rule_begin: []bool,
        separator_prefix: []const usize,
        rule_selector_text: []const []const u8,
        rule_selector_trimmed: []const []const u8,
    ) !void {
        const BlockStart = struct {
            kind: NodeKind,
            idx: usize,
        };
        var open_blocks: std.ArrayListUnmanaged(BlockStart) = .empty;
        defer open_blocks.deinit(temp);
        try open_blocks.ensureTotalCapacity(temp, self.nodes.items.len);
        for (self.nodes.items, 0..) |node, idx| {
            if (skip[idx]) continue;
            switch (node.kind) {
                .rule_begin, .at_rule_begin => open_blocks.appendAssumeCapacity(.{
                    .kind = node.kind,
                    .idx = idx,
                }),
                .rule_end => {
                    if (open_blocks.items.len == 0) continue;
                    const open = open_blocks.pop().?;
                    if (open.kind != .rule_begin) continue;

                    const next_idx = nextRenderableNodeIndex(self.nodes.items, skip, idx) orelse continue;
                    if (self.nodes.items[next_idx].kind != .rule_begin) continue;
                    const has_separator = separator_prefix[next_idx] != separator_prefix[idx + 1];
                    if (has_separator) continue;

                    const open_sel = rule_selector_text[open.idx];
                    const next_sel = rule_selector_text[next_idx];
                    if (!std.mem.eql(u8, rule_selector_trimmed[open.idx], rule_selector_trimmed[next_idx])) continue;
                    if (selectorListHasExactDuplicateBranches(open_sel) or
                        selectorListHasExactDuplicateBranches(next_sel))
                    {
                        continue;
                    }

                    const next_end = self.findMatchingBlockEnd(next_idx) orelse continue;
                    // same-source-shape check: @each/@for iterations (user-written rule_begin)
                    // Do not merge if multiple rules with the same selector appear. However, compiler-synthesized
                    // reopen (origin_reopen=true; after emit_rule_end_if_open via @include
                    // ensureCurrentRuleOpenForDeclaration etc.) even if decls of the same source are consecutive
                    // merge target. Compiler-synthesized reopens from separate
                    // mixin calls can share the same source declaration shape and
                    // still need to merge.
                    if (!self.getOriginReopenAt(next_idx) and
                        self.ruleBodiesReuseSameSourceShape(skip, open.idx, idx, next_idx, next_end))
                    {
                        continue;
                    }

                    // Z10-SAMESEL: user-written adjacent same-selector (`.x{} .x{}`) is
                    // Not merged in official Sass CLI, but like `.a { decl; @include m; decl; }`
                    // Case in which parent rule is internally closed+reopened (rule_end_if_open via mixin)
                    // Running, etc.) official Sass CLI merges into 1 block.
                    // Condition:
                    // (A) The next rule_begin is `origin_reopen` (compiler-synthesized continuation) and
                    // (B) The previous rule_begin is **not** `origin_at_root_hoisted`.
                    //(B) is required for test 2 (via `a { @include position(...) }`  ->  @at-root):
                    // The reopen immediately after the hoisted block is not merged because it is a different block in official Sass CLI.
                    if (!self.getOriginReopenAt(next_idx)) continue;
                    if (self.getOriginAtRootHoistedAt(open.idx)) continue;

                    skip[idx] = true;
                    merge_same_rule_begin[next_idx] = true;
                },
                .at_rule_end => {
                    if (open_blocks.items.len == 0) continue;
                    const open = open_blocks.pop().?;
                    if (open.kind != .at_rule_begin) continue;

                    const next_idx = nextRenderableNodeIndex(self.nodes.items, skip, idx) orelse continue;
                    if (self.nodes.items[next_idx].kind != .at_rule_begin) continue;
                    if (!self.getOriginReopenAt(next_idx)) continue;
                    if (self.getOriginAtRootHoistedAt(open.idx)) continue;

                    const open_node = self.nodes.items[open.idx];
                    const next_node = self.nodes.items[next_idx];
                    const open_name = self.extra.items[open_node.payload];
                    const next_name = self.extra.items[next_node.payload];
                    const open_prelude = self.extra.items[open_node.payload + 1];
                    const next_prelude = self.extra.items[next_node.payload + 1];
                    if (open_name != next_name or open_prelude != next_prelude) continue;

                    skip[idx] = true;
                    merge_same_rule_begin[next_idx] = true;
                },
                else => {},
            }
        }
    }

    /// Traverse the `Block` stack and determine the effective visibility of each `rule_begin` / `at_rule_begin`,
    /// Nodes that do not appear in the output (empty conditional / no children rule / disabled selector)
    /// Record in `skip[]`. At the same time `empty_at_rule_end[]` (corresponding to empty conditional end idx)
    /// Calculate and `saw_charset` (presence of non-ASCII output).
    fn computeSkipFlagsAndCharset(
        self: *const RuleIR,
        intern_pool: *const InternPool,
        temp: std.mem.Allocator,
        selector_visible: []const bool,
        selector_override: []const ?[]const u8,
        skip: []bool,
        empty_at_rule_end: []u32,
        output_style: OutputStyle,
    ) !bool {
        var saw_charset = false;
        const Block = struct {
            idx: usize,
            kind: NodeKind,
            has_content: bool,
            disabled: bool,
            keep_empty_block: bool,
        };
        var stack: std.ArrayListUnmanaged(Block) = .empty;
        defer stack.deinit(temp);
        try stack.ensureTotalCapacity(temp, self.nodes.items.len);

        for (self.nodes.items, 0..) |node, i| {
            const parent_disabled = stack.items.len > 0 and stack.items[stack.items.len - 1].disabled;
            switch (node.kind) {
                .rule_begin, .at_rule_begin => {
                    var disabled = parent_disabled;
                    if (node.kind == .rule_begin and !selector_visible[i]) {
                        disabled = true;
                    }
                    if (disabled) skip[i] = true;
                    const keep_empty_block = if (node.kind == .at_rule_begin)
                        self.extra.items[node.payload + 3] != 0
                    else
                        false;
                    stack.appendAssumeCapacity(.{
                        .idx = i,
                        .kind = node.kind,
                        .has_content = false,
                        .disabled = disabled,
                        .keep_empty_block = keep_empty_block,
                    });
                    if (!disabled) {
                        switch (node.kind) {
                            .rule_begin => {
                                const sel_text = getNodeSelectorText(self, i, selector_override, intern_pool);
                                if (renderedNeedsCharset(sel_text)) saw_charset = true;
                            },
                            .at_rule_begin => {
                                const name = intern_pool.get(@enumFromInt(self.extra.items[node.payload]));
                                if (renderedNeedsCharset(name)) saw_charset = true;
                                const prelude_id = self.extra.items[node.payload + 1];
                                if (prelude_id != std.math.maxInt(u32)) {
                                    const prelude = intern_pool.get(@enumFromInt(prelude_id));
                                    if (renderedNeedsCharset(prelude)) saw_charset = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                .rule_end => {
                    if (stack.items.len == 0 or stack.items[stack.items.len - 1].kind != .rule_begin) {
                        skip[i] = true;
                        continue;
                    }
                    const blk = stack.pop().?;
                    if (blk.disabled) {
                        skip[i] = true;
                        continue;
                    }
                    if (!blk.has_content) {
                        skip[blk.idx] = true;
                        skip[i] = true;
                    } else if (stack.items.len > 0 and !stack.items[stack.items.len - 1].disabled) {
                        stack.items[stack.items.len - 1].has_content = true;
                    }
                },
                .at_rule_end => {
                    if (stack.items.len == 0 or stack.items[stack.items.len - 1].kind != .at_rule_begin) {
                        skip[i] = true;
                        continue;
                    }
                    const blk = stack.pop().?;
                    if (blk.disabled) {
                        skip[i] = true;
                        continue;
                    }
                    if (!blk.has_content) {
                        const begin_node = self.nodes.items[blk.idx];
                        const name_id = self.extra.items[begin_node.payload];
                        const name = intern_pool.get(@enumFromInt(name_id));
                        const keep_empty = blk.keep_empty_block or !isConditionalAtRuleName(name);
                        if (!keep_empty) {
                            skip[blk.idx] = true;
                            skip[i] = true;
                            continue;
                        }
                        empty_at_rule_end[blk.idx] = @intCast(i);
                        if (stack.items.len > 0 and !stack.items[stack.items.len - 1].disabled) {
                            stack.items[stack.items.len - 1].has_content = true;
                        }
                    } else if (stack.items.len > 0 and !stack.items[stack.items.len - 1].disabled) {
                        stack.items[stack.items.len - 1].has_content = true;
                    }
                },
                .decl, .decl_raw, .at_rule_simple, .comment, .stream_chunk => {
                    if (parent_disabled) {
                        skip[i] = true;
                        continue;
                    }
                    switch (node.kind) {
                        .decl => {
                            const prop_id = self.extra.items[node.payload];
                            const prop = intern_pool.get(@enumFromInt(prop_id));
                            if (renderedNeedsCharset(prop)) saw_charset = true;
                            const value_id = self.extra.items[node.payload + 1];
                            const value = intern_pool.get(@enumFromInt(value_id));
                            if (renderedDeclValueNeedsCharset(value, output_style)) saw_charset = true;
                        },
                        .decl_raw => {
                            const prop_id = self.extra.items[node.payload];
                            const prop = intern_pool.get(@enumFromInt(prop_id));
                            if (renderedNeedsCharset(prop)) saw_charset = true;
                            const raw_idx = self.extra.items[node.payload + 1];
                            const value = self.strings.items[raw_idx];
                            if (renderedDeclValueNeedsCharset(value, output_style)) saw_charset = true;
                        },
                        .comment => {
                            const text_id = self.extra.items[node.payload];
                            const text = intern_pool.get(@enumFromInt(text_id));
                            if (renderedNeedsCharset(text)) saw_charset = true;
                        },
                        .stream_chunk => {
                            if (node.payload < self.flushed_chunks.items.len and
                                self.flushed_chunks.items[node.payload].needs_charset)
                            {
                                saw_charset = true;
                            }
                        },
                        else => {},
                    }
                    if (node.kind == .at_rule_simple) {
                        const name_id = self.extra.items[node.payload];
                        const name = intern_pool.get(@enumFromInt(name_id));
                        if (renderedNeedsCharset(name)) saw_charset = true;
                        const prelude_id = self.extra.items[node.payload + 1];
                        if (prelude_id != std.math.maxInt(u32)) {
                            const prelude = intern_pool.get(@enumFromInt(prelude_id));
                            if (renderedNeedsCharset(prelude)) saw_charset = true;
                        }
                        if (std.ascii.eqlIgnoreCase(name, "charset")) {
                            skip[i] = true;
                            continue;
                        }
                    }
                    if (stack.items.len > 0) {
                        stack.items[stack.items.len - 1].has_content = true;
                    }
                },
                .stmt_gap, .group_boundary, .sourcemap_gap => {
                    // Empty marker. Interpret on the output side. Don't skip, just pass.
                },
            }
        }

        return saw_charset;
    }

    /// `!optional` of `@extend` relation is required (ungrouped alone + relation_id shared group)
    /// detects something that doesn't match and returns a SassError. The only side effect is `ruleIrStderrPrint`.
    fn validateRequiredExtendMatches(
        self: *const RuleIR,
        intern_pool: *const InternPool,
        temp: std.mem.Allocator,
        edge_eligible: []const bool,
        edge_required_unmatched: []const bool,
        edge_duplicate_satisfied: []const bool,
        edge_matched: []const bool,
    ) !void {
        const RelationTargetKey = struct {
            relation_id: u32,
            target_selector: InternId,
        };
        var grouped_required = std.AutoHashMapUnmanaged(RelationTargetKey, bool).empty;
        defer grouped_required.deinit(temp);
        for (self.extend_edges.items, 0..) |edge, edge_idx| {
            if (edge.optional) continue;
            if (!edge_eligible[edge_idx] and !edge_required_unmatched[edge_idx]) continue;
            const target_raw = intern_pool.get(edge.target_selector);
            if (std.mem.findScalar(u8, target_raw, ':') != null) {
                continue;
            }
            const duplicate_satisfied = edge_idx < edge_duplicate_satisfied.len and edge_duplicate_satisfied[edge_idx];
            const is_matched = !edge_required_unmatched[edge_idx] and
                (duplicate_satisfied or (edge_idx < edge_matched.len and edge_matched[edge_idx]));
            if (edge.relation_id == std.math.maxInt(u32)) {
                if (!is_matched) {
                    ruleIrStderrPrint(
                        "zsass-rule-ir unmatched required @extend extending={s} target={s} source_module={d} target_module={d}\n",
                        .{
                            intern_pool.get(edge.extending_selector),
                            intern_pool.get(edge.target_selector),
                            edge.source_module,
                            edge.target_module,
                        },
                    );
                    return error.SassError;
                }
                continue;
            }
            const gop = try grouped_required.getOrPut(temp, .{
                .relation_id = edge.relation_id,
                .target_selector = edge.target_selector,
            });
            if (!gop.found_existing) gop.value_ptr.* = false;
            if (is_matched) gop.value_ptr.* = true;
        }
        var grouped_it = grouped_required.iterator();
        while (grouped_it.next()) |entry| {
            if (!entry.value_ptr.*) {
                ruleIrStderrPrint("zsass-rule-ir unmatched required @extend relation relation_id={d}\n", .{entry.key_ptr.*.relation_id});
                for (self.extend_edges.items, 0..) |edge, edge_idx| {
                    if (edge.relation_id != entry.key_ptr.*.relation_id) continue;
                    if (edge.target_selector != entry.key_ptr.*.target_selector) continue;
                    const extending = intern_pool.get(edge.extending_selector);
                    const target = intern_pool.get(edge.target_selector);
                    const matched = edge_idx < edge_matched.len and edge_matched[edge_idx];
                    const required_unmatched = edge_idx < edge_required_unmatched.len and edge_required_unmatched[edge_idx];
                    ruleIrStderrPrint(
                        "  edge[{d}] extending={s} target={s} optional={any} matched={any} required_unmatched={any} source_module={d} target_module={d}\n",
                        .{
                            edge_idx,
                            extending,
                            target,
                            edge.optional,
                            matched,
                            required_unmatched,
                            edge.source_module,
                            edge.target_module,
                        },
                    );
                }
                return error.SassError;
            }
        }
    }

    fn isHexDigit(ch: u8) bool {
        return (ch >= '0' and ch <= '9') or
            (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F');
    }

    fn hexValue(ch: u8) ?u8 {
        if (ch >= '0' and ch <= '9') return ch - '0';
        if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
        return null;
    }

    fn isIdentLike(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
    }

    fn appendPreferredCompressedColor(out: *std.ArrayList(u8), allocator: std.mem.Allocator, r: u8, g: u8, b: u8) error{OutOfMemory}!void {
        const short = ((r >> 4) == (r & 0xf)) and ((g >> 4) == (g & 0xf)) and ((b >> 4) == (b & 0xf));
        const hex_len: usize = if (short) 4 else 7;
        if (color_mod.namedColorForRgb(r, g, b)) |name| {
            if (name.len <= hex_len) {
                try out.appendSlice(allocator, name);
                return;
            }
        }
        if (short) {
            const rendered = try std.fmt.allocPrint(allocator, "#{x}{x}{x}", .{ @as(u4, @intCast(r >> 4)), @as(u4, @intCast(g >> 4)), @as(u4, @intCast(b >> 4)) });
            defer allocator.free(rendered);
            try out.appendSlice(allocator, rendered);
        } else {
            const rendered = try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
            defer allocator.free(rendered);
            try out.appendSlice(allocator, rendered);
        }
    }

    fn appendCompressedHex(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        if (text[i.*] != '#') return false;
        var n: usize = 0;
        while (i.* + 1 + n < text.len and n < 8 and isHexDigit(text[i.* + 1 + n])) : (n += 1) {}
        if (n != 3 and n != 6) return false;
        const after = i.* + 1 + n;
        if (after < text.len and isIdentLike(text[after])) return false;

        if (n == 3) {
            const r4 = hexValue(text[i.* + 1]) orelse return false;
            const g4 = hexValue(text[i.* + 2]) orelse return false;
            const b4 = hexValue(text[i.* + 3]) orelse return false;
            try appendPreferredCompressedColor(out, allocator, (r4 << 4) | r4, (g4 << 4) | g4, (b4 << 4) | b4);
        } else {
            const r = ((hexValue(text[i.* + 1]) orelse return false) << 4) | (hexValue(text[i.* + 2]) orelse return false);
            const g = ((hexValue(text[i.* + 3]) orelse return false) << 4) | (hexValue(text[i.* + 4]) orelse return false);
            const b = ((hexValue(text[i.* + 5]) orelse return false) << 4) | (hexValue(text[i.* + 6]) orelse return false);
            try appendPreferredCompressedColor(out, allocator, r, g, b);
        }
        i.* += n;
        return true;
    }

    fn appendCompressedImport(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        const prefix = "@import url(";
        if (!std.mem.startsWith(u8, text[i.*..], prefix)) return false;
        var j = i.* + prefix.len;
        var quote: u8 = 0;
        if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
            quote = text[j];
            j += 1;
        }
        const url_start = j;
        if (quote != 0) {
            while (j < text.len and text[j] != quote) : (j += 1) {}
            if (j >= text.len) return false;
            const url = text[url_start..j];
            j += 1;
            if (j >= text.len or text[j] != ')') return false;
            try out.appendSlice(allocator, "@import\"");
            try out.appendSlice(allocator, url);
            try out.append(allocator, '"');
            i.* = j;
            return true;
        }
        while (j < text.len and text[j] != ')') : (j += 1) {}
        if (j >= text.len) return false;
        const url = text[url_start..j];
        try out.appendSlice(allocator, "@import\"");
        try out.appendSlice(allocator, url);
        try out.append(allocator, '"');
        i.* = j;
        return true;
    }

    fn appendCompressedTransparent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        const word = "transparent";
        if (!std.mem.startsWith(u8, text[i.*..], word)) return false;
        const before_ok = i.* == 0 or !isIdentLike(text[i.* - 1]);
        const after = i.* + word.len;
        const after_ok = after >= text.len or !isIdentLike(text[after]);
        if (!before_ok or !after_ok) return false;
        try out.appendSlice(allocator, "rgba(0,0,0,0)");
        i.* += word.len - 1;
        return true;
    }

    fn appendCompressedNamedColor(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        if (i.* > 0 and isIdentLike(text[i.* - 1])) return false;
        var end = i.*;
        while (end < text.len and isIdentLike(text[end])) : (end += 1) {}
        if (end == i.*) return false;
        const name = text[i.*..end];
        const color = color_mod.lookupNamedColor(name) orelse return false;
        if (color.a != 1.0) return false;
        const r: u8 = @intFromFloat(color.r);
        const g: u8 = @intFromFloat(color.g);
        const b: u8 = @intFromFloat(color.b);
        try appendPreferredCompressedColor(out, allocator, r, g, b);
        i.* = end - 1;
        return true;
    }

    fn parseRgbComponent(text: []const u8, pos: *usize) ?u8 {
        while (pos.* < text.len and text[pos.*] == ' ') : (pos.* += 1) {}
        var value: u16 = 0;
        const start = pos.*;
        while (pos.* < text.len and text[pos.*] >= '0' and text[pos.*] <= '9') : (pos.* += 1) {
            value = value * 10 + (text[pos.*] - '0');
            if (value > 255) return null;
        }
        if (pos.* == start) return null;
        while (pos.* < text.len and text[pos.*] == ' ') : (pos.* += 1) {}
        return @intCast(value);
    }

    fn appendAlphaCompressed(out: *std.ArrayList(u8), allocator: std.mem.Allocator, alpha: []const u8) error{OutOfMemory}!void {
        const trimmed = std.mem.trim(u8, alpha, " ");
        if (std.mem.startsWith(u8, trimmed, "0.")) {
            try out.appendSlice(allocator, trimmed[1..]);
        } else {
            try out.appendSlice(allocator, trimmed);
        }
    }

    fn appendCompressedTopLevelRgb(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        if (!std.mem.startsWith(u8, text[i.*..], "rgb(")) return false;
        var pos = i.* + "rgb(".len;
        const r = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ',') return false;
        pos += 1;
        const g = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ',') return false;
        pos += 1;
        const b = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ')') return false;
        try appendPreferredCompressedColor(out, allocator, r, g, b);
        i.* = pos;
        return true;
    }

    fn appendCompressedTopLevelRgba(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, i: *usize) error{OutOfMemory}!bool {
        if (!std.mem.startsWith(u8, text[i.*..], "rgba(")) return false;
        var pos = i.* + "rgba(".len;
        const r = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ',') return false;
        pos += 1;
        const g = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ',') return false;
        pos += 1;
        const b = parseRgbComponent(text, &pos) orelse return false;
        if (pos >= text.len or text[pos] != ',') return false;
        pos += 1;
        while (pos < text.len and text[pos] == ' ') : (pos += 1) {}
        const alpha_start = pos;
        while (pos < text.len and text[pos] != ')') : (pos += 1) {}
        if (pos >= text.len) return false;
        const alpha = std.mem.trim(u8, text[alpha_start..pos], " ");
        if (r == g and g == b and r != 0 and (@as(u16, r) * 100) % 255 == 0) {
            const lightness = @divExact(@as(u16, r) * 100, 255);
            var rgba_buf: [64]u8 = undefined;
            const rgba = std.fmt.bufPrint(&rgba_buf, "rgba({d},{d},{d},", .{ r, g, b }) catch return false;
            const rgba_len = rgba.len + (if (std.mem.startsWith(u8, alpha, "0.")) alpha.len - 1 else alpha.len) + 1;
            var hsla_buf: [64]u8 = undefined;
            const hsla = std.fmt.bufPrint(&hsla_buf, "hsla(0,0%,{d}%,", .{lightness}) catch return false;
            const hsla_len = hsla.len + (if (std.mem.startsWith(u8, alpha, "0.")) alpha.len - 1 else alpha.len) + 1;
            if (hsla_len < rgba_len) {
                try out.appendSlice(allocator, hsla);
                try appendAlphaCompressed(out, allocator, alpha);
                try out.append(allocator, ')');
                i.* = pos;
                return true;
            }
        }
        const prefix = try std.fmt.allocPrint(allocator, "rgba({d},{d},{d},", .{ r, g, b });
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        try appendAlphaCompressed(out, allocator, alpha);
        try out.append(allocator, ')');
        i.* = pos;
        return true;
    }

    fn isCompressedSelectorContext(text: []const u8, pos: usize) bool {
        var i = pos;
        while (i > 0) {
            i -= 1;
            switch (text[i]) {
                '}', '{' => return true,
                ';' => return false,
                else => {},
            }
        }
        return true;
    }

    fn previousLooksLikeIeHack(out: []const u8) bool {
        return out.len >= 2 and out[out.len - 2] == '\\' and (out[out.len - 1] == '0' or out[out.len - 1] == '9');
    }

    fn currentDeclPropertyIsCustom(out: []const u8) bool {
        var start = out.len;
        while (start > 0) {
            const prev = out[start - 1];
            if (prev == '{' or prev == ';' or prev == '}') break;
            start -= 1;
        }
        const prop = std.mem.trim(u8, out[start..], " ");
        return std.mem.startsWith(u8, prop, "--");
    }

    fn compressCss(allocator: std.mem.Allocator, expanded: []const u8) error{OutOfMemory}![]const u8 {
        var first: std.ArrayList(u8) = .empty;
        errdefer first.deinit(allocator);

        var i: usize = 0;
        while (i < expanded.len) : (i += 1) {
            const c = expanded[i];

            if (c == '/' and i + 1 < expanded.len and expanded[i + 1] == '*') {
                i += 2;
                while (i + 1 < expanded.len) : (i += 1) {
                    if (expanded[i] == '*' and expanded[i + 1] == '/') {
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            if (c == '\n') {
                while (i + 1 < expanded.len and (expanded[i + 1] == ' ' or expanded[i + 1] == '\t' or expanded[i + 1] == '\n')) {
                    i += 1;
                }
                continue;
            }

            if (c == ' ' and i + 1 < expanded.len and expanded[i + 1] == '{') continue;
            if (c == ';' and i + 1 < expanded.len and expanded[i + 1] == '}') continue;

            try first.append(allocator, c);
            if (c == '}') {
                while (first.items.len >= 2 and first.items[first.items.len - 2] == ';') {
                    first.items[first.items.len - 2] = '}';
                    first.items.len -= 1;
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var preserve_decl_zero = false;
        var in_string: u8 = 0;
        var paren_depth: u32 = 0;
        var color_func_depth: u32 = 0;
        var calc_func_depth: u32 = 0;
        var preserve_calc_ops = false;
        var in_custom_decl = false;
        i = 0;
        while (i < first.items.len) : (i += 1) {
            if (std.mem.startsWith(u8, first.items[i..], interp_decl_marker)) {
                i += interp_decl_marker.len - 1;
                preserve_decl_zero = true;
                continue;
            }
            if (std.mem.startsWith(u8, first.items[i..], literal_decl_marker)) {
                i += literal_decl_marker.len - 1;
                preserve_decl_zero = true;
                preserve_calc_ops = true;
                continue;
            }

            const c = first.items[i];
            if (in_string != 0) {
                try out.append(allocator, c);
                if (c == '\\' and i + 1 < first.items.len) {
                    i += 1;
                    try out.append(allocator, first.items[i]);
                } else if (c == in_string) {
                    in_string = 0;
                }
                continue;
            }
            if (c == '"' or c == '\'') {
                in_string = c;
                try out.append(allocator, c);
                continue;
            }

            if (c == ';' or c == '}') {
                preserve_decl_zero = false;
                preserve_calc_ops = false;
                in_custom_decl = false;
            }
            if (try appendCompressedImport(&out, allocator, first.items, &i)) continue;
            const value_context = out.items.len != 0 and (out.items[out.items.len - 1] == ':' or out.items[out.items.len - 1] == ',' or out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '(');
            if (!in_custom_decl and paren_depth == 0 and value_context and try appendCompressedTopLevelRgb(&out, allocator, first.items, &i)) continue;
            if (!in_custom_decl and paren_depth == 0 and value_context and try appendCompressedTopLevelRgba(&out, allocator, first.items, &i)) continue;
            if (!in_custom_decl and value_context and try appendCompressedTransparent(&out, allocator, first.items, &i)) continue;
            if (!in_custom_decl and value_context and try appendCompressedNamedColor(&out, allocator, first.items, &i)) continue;
            if (!in_custom_decl and paren_depth == 0 and try appendCompressedHex(&out, allocator, first.items, &i)) continue;

            if (c == '(') {
                var name_start = out.items.len;
                while (name_start > 0 and (std.ascii.isAlphabetic(out.items[name_start - 1]) or out.items[name_start - 1] == '-')) : (name_start -= 1) {}
                const name = out.items[name_start..];
                paren_depth += 1;
                if (paren_depth == 1 and
                    (std.ascii.eqlIgnoreCase(name, "rgb") or
                        std.ascii.eqlIgnoreCase(name, "rgba") or
                        std.ascii.eqlIgnoreCase(name, "hsl") or
                        std.ascii.eqlIgnoreCase(name, "hsla")))
                {
                    color_func_depth = paren_depth;
                }
                if (std.ascii.eqlIgnoreCase(name, "calc")) calc_func_depth = paren_depth;
                try out.append(allocator, c);
                continue;
            }
            if (c == ')') {
                if (paren_depth != 0) {
                    if (color_func_depth == paren_depth) color_func_depth = 0;
                    if (calc_func_depth == paren_depth) calc_func_depth = 0;
                    paren_depth -= 1;
                }
                try out.append(allocator, c);
                continue;
            }

            if (c == ':' and paren_depth == 0) {
                in_custom_decl = currentDeclPropertyIsCustom(out.items);
            }
            if (!in_custom_decl and c == ':' and i + 1 < first.items.len and first.items[i + 1] == ' ' and paren_depth == 0) {
                try out.append(allocator, ':');
                i += 1;
                continue;
            }
            if (!in_custom_decl and c == ',' and i + 1 < first.items.len and first.items[i + 1] == ' ' and (paren_depth == 0 or color_func_depth != 0)) {
                try out.append(allocator, ',');
                i += 1;
                continue;
            }

            if (c == ' ') {
                if (in_custom_decl) {
                    try out.append(allocator, c);
                    continue;
                }
                if (out.items.len == 0) continue;
                const prev = out.items[out.items.len - 1];
                const next = if (i + 1 < first.items.len) first.items[i + 1] else 0;
                if (previousLooksLikeIeHack(out.items) and (next == ';' or next == '}')) {
                    try out.append(allocator, c);
                    continue;
                }
                if (prev == '}' or prev == '{' or prev == ';' or next == '{' or next == '}') continue;
                if (calc_func_depth != 0 and !preserve_calc_ops and (prev == '/' or prev == '*' or next == '/' or next == '*')) continue;
                if (prev == ')' and std.mem.startsWith(u8, first.items[i + 1 ..], "and ")) continue;
                if ((next == '+' or next == '>' or next == '~') and isCompressedSelectorContext(first.items, i)) continue;
                if (next == '(' and std.mem.endsWith(u8, out.items, "@media")) continue;
                if (next == '(' and std.mem.endsWith(u8, out.items, "@supports")) continue;
            }

            if (calc_func_depth != 0 and !preserve_calc_ops and (c == '/' or c == '*')) {
                if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                try out.append(allocator, c);
                if (i + 1 < first.items.len and first.items[i + 1] == ' ') i += 1;
                continue;
            }

            if (calc_func_depth != 0 and c == '+') {
                if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                try out.appendSlice(allocator, " + ");
                if (i + 1 < first.items.len and first.items[i + 1] == ' ') i += 1;
                continue;
            }

            if ((c == '+' or c == '>' or c == '~') and isCompressedSelectorContext(first.items, i)) {
                if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                try out.append(allocator, c);
                if (i + 1 < first.items.len and first.items[i + 1] == ' ') i += 1;
                continue;
            }

            if (!in_custom_decl and !preserve_decl_zero and (paren_depth == 0 or color_func_depth != 0) and c == '0' and i + 1 < first.items.len and first.items[i + 1] == '.') {
                const prev = if (out.items.len != 0) out.items[out.items.len - 1] else 0;
                if (prev != '-' and !std.ascii.isAlphanumeric(prev) and prev != '_' and prev != '.') continue;
            }

            if (c == '}' and out.items.len != 0 and out.items[out.items.len - 1] == ';') {
                while (out.items.len != 0 and out.items[out.items.len - 1] == ';') out.items.len -= 1;
            }

            if (c == '}' and out.items.len != 0 and out.items[out.items.len - 1] == '{') {
                var start_empty = out.items.len - 1;
                while (start_empty > 0 and out.items[start_empty - 1] != '}') : (start_empty -= 1) {}
                out.items.len = start_empty;
                preserve_decl_zero = false;
                preserve_calc_ops = false;
                in_custom_decl = false;
                continue;
            }

            try out.append(allocator, c);
        }
        first.deinit(allocator);
        return try out.toOwnedSlice(allocator);
    }

    pub fn writeToWithSourceMap(
        self: *const RuleIR,
        writer: *std.Io.Writer,
        intern_pool: *const InternPool,
        source_map: ?*source_map_mod.SourceMap,
        source_locations: ?[]const SourceLocation,
        output_style: OutputStyle,
        opts: WriteToWithSourceMapOpts,
    ) !void {
        _ = opts.source_map_url_override;
        var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer temp_arena.deinit();
        const temp = temp_arena.allocator();

        var compress_buf: std.ArrayList(u8) = .empty;
        // SAFETY: Assigned in the `.compressed` branch before `effective_writer` dereferences it.
        var compress_aw: std.Io.Writer.Allocating = undefined;
        const effective_writer: *std.Io.Writer = if (output_style == .compressed) blk: {
            compress_aw = std.Io.Writer.Allocating.fromArrayList(std.heap.page_allocator, &compress_buf);
            break :blk &compress_aw.writer;
        } else writer;

        const n = self.nodes.items.len;
        const skip = try temp.alloc(bool, n);
        @memset(skip, false);
        const empty_at_rule_end = try temp.alloc(u32, n);

        var source_index_cache: []u32 = &.{};
        if (source_map != null and source_locations != null) {
            source_index_cache = try temp.alloc(u32, source_locations.?.len);
            @memset(source_index_cache, std.math.maxInt(u32));
        }

        const EmitCtx = struct {
            writer: *std.Io.Writer,
            source_map: ?*source_map_mod.SourceMap,
            source_locations: ?[]const SourceLocation,
            source_index_cache: []u32,
            track_generated_positions: bool,
            path_arena: std.mem.Allocator,
            urls_mode: source_map_mod.SourceMapUrlsMode,
            source_map_output_dir_abs: ?[]const u8,
            compressed: bool,
            gen_line: u32 = 0,
            gen_col: u32 = 0,

            fn writeAll(ctx: *@This(), text: []const u8) !void {
                try ctx.writer.writeAll(text);
                if (!ctx.track_generated_positions) return;
                // Batch runs between '\n' - same line/col accounting as the per-byte loop.
                var rest: []const u8 = text;
                while (rest.len != 0) {
                    if (std.mem.findScalar(u8, rest, '\n')) |rel_nl| {
                        ctx.gen_col += @as(u32, @intCast(rel_nl));
                        ctx.gen_line += 1;
                        ctx.gen_col = 0;
                        rest = rest[rel_nl + 1 ..];
                    } else {
                        ctx.gen_col += @as(u32, @intCast(rest.len));
                        break;
                    }
                }
            }

            fn writeByte(ctx: *@This(), b: u8) !void {
                try ctx.writer.writeByte(b);
                if (!ctx.track_generated_positions) return;
                if (b == '\n') {
                    ctx.gen_line += 1;
                    ctx.gen_col = 0;
                } else {
                    ctx.gen_col += 1;
                }
            }

            fn markNode(ctx: *@This(), file_id: u32, node: Node) !void {
                if (!ctx.track_generated_positions) return;
                const sm = ctx.source_map orelse return;
                const locs = ctx.source_locations orelse return;
                if (file_id >= locs.len or file_id >= ctx.source_index_cache.len) return;

                var source_idx = ctx.source_index_cache[file_id];
                if (source_idx == std.math.maxInt(u32)) {
                    const mapped = try sourcePathForSourceMap(ctx.path_arena, ctx.urls_mode, locs[file_id].source_path, ctx.source_map_output_dir_abs);
                    source_idx = try sm.addSource(mapped, locs[file_id].source_path);
                    ctx.source_index_cache[file_id] = source_idx;
                }

                const src = RuleIR.sourceOffsetToLineCol(locs[file_id], node.source_start);
                try sm.appendSegment(ctx.gen_line, ctx.gen_col, source_idx, src.line, src.col, null);
            }
        };

        const WriterHelpers = struct {
            fn leadingWhitespaceCount(line: []const u8) usize {
                var ws: usize = 0;
                while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
                return ws;
            }

            fn writeIndent(emit: *EmitCtx, level: usize) !void {
                var i: usize = 0;
                while (i < level) : (i += 1) {
                    try emit.writeAll("  ");
                }
            }

            fn writeIndentedMultiline(emit: *EmitCtx, text: []const u8, level: usize) !void {
                var start: usize = 0;
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\n') {
                        try emit.writeAll(text[start .. i + 1]);
                        if (i + 1 < text.len) {
                            try writeIndent(emit, level);
                            var next = i + 1;
                            while (next < text.len and (text[next] == ' ' or text[next] == '\t')) : (next += 1) {}
                            start = next;
                            continue;
                        }
                        start = i + 1;
                    }
                }
                if (start < text.len) {
                    try emit.writeAll(text[start..]);
                }
            }

            fn isWhitespaceChar(ch: u8) bool {
                return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
            }

            fn isWs(ch: u8) bool {
                return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
            }

            fn isIdentChar(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
            }

            fn findMatchingParen(text: []const u8, start: usize) ?usize {
                var depth: u32 = 0;
                var in_string: u8 = 0;
                var interpolation_depth: u32 = 0;
                var i = start;
                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    if (in_string != 0) {
                        if (ch == '\\' and i + 1 < text.len) {
                            i += 1;
                            continue;
                        }
                        if (ch == '#' and i + 1 < text.len and text[i + 1] == '{') {
                            interpolation_depth += 1;
                            i += 1;
                            continue;
                        }
                        if (interpolation_depth > 0) {
                            if (ch == '{') {
                                interpolation_depth += 1;
                            } else if (ch == '}') {
                                interpolation_depth -= 1;
                            }
                            continue;
                        }
                        if (ch == in_string) in_string = 0;
                        continue;
                    }
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        continue;
                    }
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        if (depth == 0) return null;
                        depth -= 1;
                        if (depth == 0) return i;
                    }
                }
                return null;
            }

            fn findDeclarationColon(text: []const u8) ?usize {
                var depth: i32 = 0;
                var in_string: u8 = 0;
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    const c = text[i];
                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        continue;
                    }
                    if (c == '(') depth += 1;
                    if (c == ')') depth -= 1;
                    if (c == ':' and depth == 0) return i;
                }
                return null;
            }

            fn supportsInnerHasTopLevelAndOr(text: []const u8) bool {
                var depth: i32 = 0;
                var in_string: u8 = 0;
                var i: usize = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            i += 2;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        i += 1;
                        continue;
                    }
                    if (c == '(') {
                        depth += 1;
                        i += 1;
                        continue;
                    }
                    if (c == ')') {
                        depth -= 1;
                        i += 1;
                        continue;
                    }
                    if (depth == 0) {
                        if (text.len >= i + 5 and
                            isWhitespaceChar(text[i]) and text[i + 1] == 'a' and text[i + 2] == 'n' and
                            text[i + 3] == 'd' and isWhitespaceChar(text[i + 4])) return true;
                        if (text.len >= i + 4 and
                            isWhitespaceChar(text[i]) and text[i + 1] == 'o' and text[i + 2] == 'r' and
                            isWhitespaceChar(text[i + 3])) return true;
                    }
                    i += 1;
                }
                return false;
            }

            fn supportsInnerStartsWithNot(text: []const u8) bool {
                const trimmed = std.mem.trimStart(u8, text, " \t\n\r");
                return trimmed.len >= 5 and
                    trimmed[0] == 'n' and trimmed[1] == 'o' and trimmed[2] == 't' and
                    isWhitespaceChar(trimmed[3]);
            }

            fn unwrapSupportsOuterParens(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                var current = std.mem.trim(u8, text, " \t\n\r");
                while (current.len >= 2 and current[0] == '(' and current[current.len - 1] == ')') {
                    const close = findMatchingParen(current, 0) orelse break;
                    if (close != current.len - 1) break;
                    const inner = std.mem.trim(u8, current[1 .. current.len - 1], " \t\n\r");
                    if (!(supportsInnerHasTopLevelAndOr(inner) or supportsInnerStartsWithNot(inner))) break;
                    current = inner;
                }
                if (current.ptr == text.ptr and current.len == text.len) return text;
                return allocator.dupe(u8, current);
            }

            /// Collapse the whitespace derived from line breaks in supports(...) in import prelude.
            fn collapseImportSupportsWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (std.mem.find(u8, text, "\n") == null and std.mem.find(u8, text, "\r") == null) return text;

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);

                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            try buf.append(allocator, c);
                            i += 1;
                            try buf.append(allocator, text[i]);
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '\n' or c == '\r') {
                        while (i < text.len and
                            (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r'))
                        {
                            i += 1;
                        }
                        if (i < text.len and text[i] == ':') continue;
                        if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') continue;
                        try buf.append(allocator, ' ');
                        continue;
                    }
                    try buf.append(allocator, c);
                    i += 1;
                }

                return buf.toOwnedSlice(allocator);
            }

            fn tryUnwrapSupportsDeclParenInner(allocator: std.mem.Allocator, inner: []const u8) ?[]const u8 {
                const ei = std.mem.trim(u8, inner, " \t\n\r");
                if (ei.len < 2 or ei[0] != '(' or ei[ei.len - 1] != ')') return null;
                const ep = findMatchingParen(ei, 0) orelse return null;
                if (ep != ei.len - 1) return null;
                const d = ei[1..ep];
                if (findDeclarationColon(d) == null) return null;
                return allocator.dupe(u8, d) catch null;
            }

            /// eval2_import_prelude.normalizePlainCssImportConditionText
            /// Minimally ported supports(...) part to writer.
            fn normalizeSupportsInImportPrelude(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (std.ascii.indexOfIgnoreCase(text, "supports(") == null) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);

                var changed = false;
                var copy_from: usize = 0;
                var i: usize = 0;
                while (i < text.len) {
                    if (i + 8 < text.len and
                        std.ascii.eqlIgnoreCase(text[i .. i + 8], "supports") and
                        text[i + 8] == '(' and
                        (i == 0 or !isIdentChar(text[i - 1])))
                    {
                        const open_paren = i + 8;
                        const close = findMatchingParen(text, open_paren) orelse {
                            i += 1;
                            continue;
                        };

                        try out.appendSlice(allocator, text[copy_from..i]);
                        try out.appendSlice(allocator, text[i .. open_paren + 1]);

                        const inner_raw = text[open_paren + 1 .. close];
                        const inner = try collapseImportSupportsWhitespace(allocator, inner_raw);
                        defer if (inner.ptr != inner_raw.ptr) allocator.free(inner);

                        const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
                        const normalized_inner = if (std.mem.startsWith(u8, trimmed_inner, "--")) inner else trimmed_inner;

                        if (tryUnwrapSupportsDeclParenInner(allocator, normalized_inner)) |uw| {
                            defer allocator.free(uw);
                            try out.appendSlice(allocator, uw);
                        } else {
                            try out.appendSlice(allocator, normalized_inner);
                        }
                        try out.append(allocator, ')');

                        changed = true;
                        i = close + 1;
                        copy_from = i;
                        continue;
                    }
                    i += 1;
                }

                if (!changed) {
                    out.deinit(allocator);
                    return text;
                }

                try out.appendSlice(allocator, text[copy_from..]);
                return out.toOwnedSlice(allocator);
            }

            /// Removes supports prelude comment for writer.
            fn stripSupportsComments(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);

                var i: usize = 0;
                var in_string: u8 = 0;
                const Context = enum { normal, preserve_newline, preserve_space };
                var ctx_stack: [32]Context = undefined;
                var ctx_depth: u32 = 0;
                var cur_ctx: Context = .normal;

                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            try buf.append(allocator, c);
                            i += 1;
                            try buf.append(allocator, text[i]);
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '(') {
                        if (ctx_depth < ctx_stack.len) {
                            ctx_stack[ctx_depth] = cur_ctx;
                            ctx_depth += 1;
                        }
                        const is_func = buf.items.len > 0 and
                            (std.ascii.isAlphanumeric(buf.items[buf.items.len - 1]) or
                                buf.items[buf.items.len - 1] == '-' or
                                buf.items[buf.items.len - 1] == '_');
                        if (is_func) {
                            cur_ctx = .preserve_newline;
                        } else {
                            cur_ctx = .normal;
                            var j = i + 1;
                            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                            while (j + 1 < text.len and text[j] == '/') {
                                if (text[j + 1] == '*') {
                                    j += 2;
                                    while (j + 1 < text.len) {
                                        if (text[j] == '*' and text[j + 1] == '/') {
                                            j += 2;
                                            break;
                                        }
                                        j += 1;
                                    }
                                } else if (text[j + 1] == '/') {
                                    j += 2;
                                    while (j < text.len and text[j] != '\n') j += 1;
                                    if (j < text.len) j += 1;
                                } else break;
                                while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                            }
                            const is_custom = (j + 1 < text.len and text[j] == '-' and text[j + 1] == '-');
                            if (!is_custom) {
                                var pd: u32 = 0;
                                var has_colon = false;
                                var has_and_or = false;
                                var pk = j;
                                var ps: u8 = 0;
                                while (pk < text.len) {
                                    if (ps != 0) {
                                        if (text[pk] == '\\' and pk + 1 < text.len) {
                                            pk += 2;
                                            continue;
                                        }
                                        if (text[pk] == ps) ps = 0;
                                        pk += 1;
                                        continue;
                                    }
                                    if (text[pk] == '"' or text[pk] == '\'') {
                                        ps = text[pk];
                                        pk += 1;
                                        continue;
                                    }
                                    if (text[pk] == '(') pd += 1 else if (text[pk] == ')') {
                                        if (pd == 0) break;
                                        pd -= 1;
                                    } else if (text[pk] == ':' and pd == 0) {
                                        has_colon = true;
                                        break;
                                    } else if (pd == 0 and !has_and_or) {
                                        if (pk > 0 and isWs(text[pk - 1])) {
                                            if (pk + 3 < text.len and text[pk] == 'a' and text[pk + 1] == 'n' and text[pk + 2] == 'd' and isWs(text[pk + 3])) {
                                                has_and_or = true;
                                            } else if (pk + 2 < text.len and text[pk] == 'o' and text[pk + 1] == 'r' and isWs(text[pk + 2])) {
                                                has_and_or = true;
                                            }
                                        }
                                    }
                                    pk += 1;
                                }
                                const starts_with_not = blk_not: {
                                    const after_ws = std.mem.trimStart(u8, text[j..], " \t\n\r");
                                    break :blk_not after_ws.len >= 4 and after_ws[0] == 'n' and after_ws[1] == 'o' and after_ws[2] == 't' and isWs(after_ws[3]);
                                };
                                if (!has_colon and !has_and_or and !starts_with_not) cur_ctx = .preserve_newline;
                            }
                        }
                        try buf.append(allocator, c);
                        i += 1;
                        if (!is_func and cur_ctx == .preserve_newline) {
                            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                        }
                        continue;
                    }
                    if (c == ')') {
                        if (cur_ctx == .normal) {
                            while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                                _ = buf.pop();
                            }
                        }
                        if (ctx_depth > 0) {
                            ctx_depth -= 1;
                            cur_ctx = ctx_stack[ctx_depth];
                        }
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == ':' and ctx_depth > 0) {
                        try buf.append(allocator, c);
                        i += 1;
                        var sp: usize = buf.items.len;
                        while (sp > 0) {
                            sp -= 1;
                            if (buf.items[sp] == '(') {
                                const prop = std.mem.trim(u8, buf.items[sp + 1 .. buf.items.len - 1], " \t\n\r");
                                if (prop.len >= 2 and prop[0] == '-' and prop[1] == '-') {
                                    cur_ctx = .preserve_space;
                                }
                                break;
                            }
                        }
                        continue;
                    }
                    if (c == '/' and i + 1 < text.len) {
                        if (text[i + 1] == '*') {
                            if (cur_ctx != .normal) {
                                const last_char = if (buf.items.len > 0) buf.items[buf.items.len - 1] else @as(u8, 0);
                                const is_after_func_paren = last_char == '(' and buf.items.len >= 2 and
                                    (std.ascii.isAlphanumeric(buf.items[buf.items.len - 2]) or
                                        buf.items[buf.items.len - 2] == '-' or
                                        buf.items[buf.items.len - 2] == '_');
                                if (last_char == '(' and !is_after_func_paren) {
                                    i += 2;
                                    while (i + 1 < text.len) {
                                        if (text[i] == '*' and text[i + 1] == '/') {
                                            i += 2;
                                            break;
                                        }
                                        i += 1;
                                    }
                                    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                                    continue;
                                }
                                try buf.appendSlice(allocator, "/*");
                                i += 2;
                                while (i + 1 < text.len) {
                                    if (text[i] == '*' and text[i + 1] == '/') {
                                        try buf.appendSlice(allocator, "*/");
                                        i += 2;
                                        break;
                                    }
                                    try buf.append(allocator, text[i]);
                                    i += 1;
                                }
                                continue;
                            }
                            while (buf.items.len > 0 and
                                (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t' or
                                    buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == '\r'))
                            {
                                _ = buf.pop();
                            }
                            i += 2;
                            while (i + 1 < text.len) {
                                if (text[i] == '*' and text[i + 1] == '/') {
                                    i += 2;
                                    break;
                                }
                                i += 1;
                            }
                            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                            if (i < text.len and buf.items.len > 0) {
                                const last = buf.items[buf.items.len - 1];
                                if (last != '(' and last != '[' and text[i] != ')' and text[i] != ']' and text[i] != ':') {
                                    try buf.append(allocator, ' ');
                                }
                            }
                            continue;
                        } else if (text[i + 1] == '/') {
                            if (cur_ctx != .normal) {
                                const last_char = if (buf.items.len > 0) buf.items[buf.items.len - 1] else @as(u8, 0);
                                const is_func_open = last_char == '(' and buf.items.len >= 2 and
                                    (std.ascii.isAlphanumeric(buf.items[buf.items.len - 2]) or
                                        buf.items[buf.items.len - 2] == '-' or
                                        buf.items[buf.items.len - 2] == '_');
                                i += 2;
                                while (i < text.len and text[i] != '\n') i += 1;
                                if (last_char == '(' and is_func_open) {
                                    if (i < text.len and text[i] == '\n') {
                                        try buf.append(allocator, '\n');
                                        i += 1;
                                        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
                                            try buf.append(allocator, text[i]);
                                            i += 1;
                                        }
                                    }
                                } else if (last_char == '(') {
                                    if (i < text.len and text[i] == '\n') i += 1;
                                    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                                } else if (cur_ctx == .preserve_space) {
                                    if (i < text.len and text[i] == '\n') i += 1;
                                    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                                    try buf.append(allocator, ' ');
                                } else {
                                    if (i < text.len and text[i] == '\n') {
                                        if (buf.items.len > 0) {
                                            const tail = buf.items[buf.items.len - 1];
                                            if (tail != '(' and tail != '[' and tail != '\n' and tail != '\r' and tail != ' ') {
                                                try buf.append(allocator, ' ');
                                            }
                                        }
                                        try buf.append(allocator, '\n');
                                        i += 1;
                                        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
                                            try buf.append(allocator, text[i]);
                                            i += 1;
                                        }
                                    } else {
                                        try buf.append(allocator, ' ');
                                    }
                                }
                                continue;
                            }
                            while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                                _ = buf.pop();
                            }
                            i += 2;
                            while (i < text.len and text[i] != '\n') i += 1;
                            if (i < text.len and text[i] == '\n') i += 1;
                            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                            if (i < text.len and buf.items.len > 0) {
                                const last = buf.items[buf.items.len - 1];
                                if (last != '(' and last != '[' and text[i] != ')' and text[i] != ']' and text[i] != ':') {
                                    try buf.append(allocator, ' ');
                                }
                            }
                            continue;
                        }
                    }
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') {
                        if (cur_ctx != .normal) {
                            if (c == '\n' or c == '\r') {
                                while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                                    _ = buf.pop();
                                }
                            }
                            try buf.append(allocator, c);
                            i += 1;
                            continue;
                        }
                        while (i < text.len and
                            (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c'))
                        {
                            i += 1;
                        }
                        if (buf.items.len > 0) {
                            const last = buf.items[buf.items.len - 1];
                            const nc = if (i < text.len) text[i] else @as(u8, 0);
                            if (last != '(' and last != '[' and nc != ')' and nc != ']' and nc != ':') {
                                try buf.append(allocator, ' ');
                            }
                        }
                        continue;
                    }
                    try buf.append(allocator, c);
                    i += 1;
                }

                return buf.toOwnedSlice(allocator);
            }

            fn normalizeSupportsPrelude(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                const stripped = try stripSupportsComments(allocator, text);
                defer if (stripped.ptr != text.ptr) allocator.free(stripped);

                const unwrapped = try unwrapSupportsOuterParens(allocator, stripped);
                if (unwrapped.ptr != stripped.ptr) return unwrapped;
                if (unwrapped.ptr == text.ptr and unwrapped.len == text.len) return text;
                return allocator.dupe(u8, unwrapped);
            }

            fn stripMozDocumentTopLevelLoudComments(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (std.mem.find(u8, text, "/*") == null) return text;

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);
                var i: usize = 0;
                var in_string: u8 = 0;
                var paren_depth: u32 = 0;

                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try buf.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try buf.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '(') {
                        paren_depth += 1;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == ')') {
                        if (paren_depth > 0) paren_depth -= 1;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (paren_depth == 0 and c == '/' and i + 1 < text.len and text[i + 1] == '*') {
                        i += 2;
                        while (i + 1 < text.len) : (i += 1) {
                            if (text[i] == '*' and text[i + 1] == '/') {
                                i += 2;
                                break;
                            }
                        }
                        continue;
                    }

                    try buf.append(allocator, c);
                    i += 1;
                }

                return buf.toOwnedSlice(allocator);
            }

            fn normalizeMozDocumentPrelude(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                const stripped = try stripMozDocumentTopLevelLoudComments(allocator, text);
                const trimmed = std.mem.trim(u8, stripped, " \t\r\n");
                if (trimmed.ptr == text.ptr and trimmed.len == text.len) return text;
                if (trimmed.ptr == stripped.ptr and trimmed.len == stripped.len) return stripped;
                defer if (stripped.ptr != text.ptr) allocator.free(stripped);
                return allocator.dupe(u8, trimmed);
            }

            /// The value of custom-property declaration like `@supports (--foo:)`
            /// Correct the empty and omitted form to `(--foo: )` to maintain validator compatibility.
            fn ensureSupportsCustomPropertyWhitespace(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);

                var changed = false;
                var copy_from: usize = 0;
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] != '(') continue;
                    const close = findMatchingParen(text, i) orelse continue;
                    const inner = text[i + 1 .. close];
                    const colon = findDeclarationColon(inner) orelse {
                        i = close;
                        continue;
                    };
                    const prop = std.mem.trim(u8, inner[0..colon], " \t\n\r");
                    if (prop.len < 2 or prop[0] != '-' or prop[1] != '-') {
                        i = close;
                        continue;
                    }
                    const value_raw = inner[colon + 1 ..];
                    if (std.mem.trim(u8, value_raw, " \t\n\r").len != 0) {
                        i = close;
                        continue;
                    }
                    // `(--foo: )` already has explicit whitespace value and must
                    // round-trip as-is. Only synthesize one space for the truly
                    // empty form `(--foo:)`.
                    if (value_raw.len != 0) {
                        i = close;
                        continue;
                    }

                    try out.appendSlice(allocator, text[copy_from..close]);
                    try out.appendSlice(allocator, " )");
                    changed = true;
                    copy_from = close + 1;
                    i = close;
                }

                if (!changed) {
                    out.deinit(allocator);
                    return text;
                }

                try out.appendSlice(allocator, text[copy_from..]);
                return out.toOwnedSlice(allocator);
            }

            fn supportsLineBreakIsInvalid(lines: []const []const u8, first_indent: usize) bool {
                if (lines.len == 0) return false;
                if (first_indent > 0) return true;

                var depth: i32 = 0;
                var in_string: u8 = 0;
                for (lines, 0..) |line, idx| {
                    const trimmed = std.mem.trimStart(u8, line, " \t");
                    if (idx != 0 and depth == 0 and trimmed.len != 0) {
                        if (trimmed[0] == '(' or
                            std.mem.startsWith(u8, trimmed, "and ") or
                            std.mem.startsWith(u8, trimmed, "or ") or
                            std.mem.startsWith(u8, trimmed, "not "))
                        {
                            return true;
                        }
                    }

                    var i: usize = 0;
                    while (i < line.len) : (i += 1) {
                        const ch = line[i];
                        if (in_string != 0) {
                            if (ch == '\\' and i + 1 < line.len) {
                                i += 1;
                                continue;
                            }
                            if (ch == in_string) in_string = 0;
                            continue;
                        }
                        if (ch == '"' or ch == '\'') {
                            in_string = ch;
                            continue;
                        }
                        if (ch == '\\' and i + 1 < line.len) {
                            i += 1;
                            continue;
                        }
                        if (ch == '(') {
                            depth += 1;
                        } else if (ch == ')' and depth > 0) {
                            depth -= 1;
                        }
                    }
                }
                return false;
            }

            fn isSourceMapCommentText(text: []const u8) bool {
                const trimmed = std.mem.trim(u8, text, " \t\n\r");
                if (trimmed.len < 4) return false;
                if (!std.mem.startsWith(u8, trimmed, "/*")) return false;
                if (!std.mem.endsWith(u8, trimmed, "*/")) return false;
                const inner = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\n\r");
                return std.mem.startsWith(u8, inner, "# sourceMappingURL=") or
                    std.mem.startsWith(u8, inner, "# sourceURL=");
            }

            /// parser writes `.sass` loud comment with `/* ...` (without the terminating `*/`)
            /// Normalize the retained case to CSS block comment.
            fn normalizeUnterminatedBlockComment(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (!std.mem.startsWith(u8, trimmed, "/*")) return text;
                if (std.mem.endsWith(u8, trimmed, "*/")) return text;
                if (std.mem.findScalar(u8, trimmed, '\n') == null) return text;

                var content_lines: std.ArrayListUnmanaged([]const u8) = .empty;
                defer content_lines.deinit(allocator);

                var line_it = std.mem.splitScalar(u8, trimmed, '\n');
                var line_idx: usize = 0;
                while (line_it.next()) |line_raw| : (line_idx += 1) {
                    const line = std.mem.trim(u8, line_raw, " \t\r");
                    if (line.len == 0) continue;

                    if (line_idx == 0) {
                        if (!std.mem.startsWith(u8, line, "/*")) return text;
                        const first_payload = std.mem.trim(u8, line[2..], " \t");
                        if (first_payload.len > 0) try content_lines.append(allocator, first_payload);
                        continue;
                    }

                    try content_lines.append(allocator, line);
                }

                if (content_lines.items.len == 0) return allocator.dupe(u8, "/* */");

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, "/* ");
                try out.appendSlice(allocator, content_lines.items[0]);
                for (content_lines.items[1..]) |line| {
                    try out.appendSlice(allocator, "\n * ");
                    try out.appendSlice(allocator, line);
                }
                try out.appendSlice(allocator, " */");
                return out.toOwnedSlice(allocator);
            }

            const SelectorEmitHints = struct {
                has_slash: bool = false,
                has_n: bool = false,
                has_paren: bool = false,
                has_ws: bool = false,
                has_newline: bool = false,
                has_combinator_candidate: bool = false,
            };

            fn scanSelectorEmitHints(text: []const u8) SelectorEmitHints {
                var hints: SelectorEmitHints = .{};
                for (text) |c| {
                    switch (c) {
                        '/' => hints.has_slash = true,
                        'n', 'N' => hints.has_n = true,
                        '(', ')' => hints.has_paren = true,
                        ' ', '\t' => hints.has_ws = true,
                        '\n', '\r' => {
                            hints.has_ws = true;
                            hints.has_newline = true;
                        },
                        '>', '+', '~', '|' => hints.has_combinator_candidate = true,
                        else => {},
                    }
                }
                return hints;
            }

            fn stripSelectorComments(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (std.mem.find(u8, text, "/*") == null and std.mem.find(u8, text, "//") == null) return text;

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);

                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            try buf.append(allocator, c);
                            i += 1;
                            try buf.append(allocator, text[i]);
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (c == '/' and i + 1 < text.len) {
                        if (text[i + 1] == '*') {
                            var saw_newline = false;
                            while (buf.items.len > 0 and
                                (buf.items[buf.items.len - 1] == ' ' or
                                    buf.items[buf.items.len - 1] == '\t' or
                                    buf.items[buf.items.len - 1] == '\n' or
                                    buf.items[buf.items.len - 1] == '\r'))
                            {
                                const last = buf.items[buf.items.len - 1];
                                if (last == '\n' or last == '\r') saw_newline = true;
                                _ = buf.pop();
                            }

                            i += 2;
                            while (i + 1 < text.len) {
                                if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                                if (text[i] == '*' and text[i + 1] == '/') {
                                    i += 2;
                                    break;
                                }
                                i += 1;
                            }

                            while (i < text.len and
                                (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r'))
                            {
                                if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                                i += 1;
                            }

                            if (i < text.len and buf.items.len > 0) {
                                const last = buf.items[buf.items.len - 1];
                                const next_char = text[i];
                                if (last != '(' and last != '[' and next_char != ')' and next_char != ']' and next_char != ',' and next_char != ':') {
                                    try buf.append(allocator, if (saw_newline) '\n' else ' ');
                                }
                            }
                            continue;
                        }

                        if (text[i + 1] == '/') {
                            var saw_newline = false;
                            while (buf.items.len > 0 and
                                (buf.items[buf.items.len - 1] == ' ' or
                                    buf.items[buf.items.len - 1] == '\t' or
                                    buf.items[buf.items.len - 1] == '\n' or
                                    buf.items[buf.items.len - 1] == '\r'))
                            {
                                const last = buf.items[buf.items.len - 1];
                                if (last == '\n' or last == '\r') saw_newline = true;
                                _ = buf.pop();
                            }

                            i += 2;
                            while (i < text.len and text[i] != '\n' and text[i] != '\r') i += 1;
                            while (i < text.len and
                                (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r'))
                            {
                                if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                                i += 1;
                            }

                            if (i < text.len and buf.items.len > 0) {
                                const last = buf.items[buf.items.len - 1];
                                const next_char = text[i];
                                if (last != '(' and last != '[' and next_char != ')' and next_char != ']' and next_char != ',' and next_char != ':') {
                                    try buf.append(allocator, if (saw_newline) '\n' else ' ');
                                }
                            }
                            continue;
                        }
                    }

                    try buf.append(allocator, c);
                    i += 1;
                }

                return buf.toOwnedSlice(allocator);
            }

            fn isNthOfTypePseudoName(name: []const u8) bool {
                const base = selector_mod.pseudoBaseName(name);
                return std.ascii.eqlIgnoreCase(base, "nth-of-type") or
                    std.ascii.eqlIgnoreCase(base, "nth-last-of-type");
            }

            fn isNthChildPseudoName(name: []const u8) bool {
                const base = selector_mod.pseudoBaseName(name);
                return std.ascii.eqlIgnoreCase(base, "nth-child") or
                    std.ascii.eqlIgnoreCase(base, "nth-last-child");
            }

            fn normalizeNthOfTypeArgText(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                var needs_change = trimmed.len != text.len;
                var i: usize = 0;
                while (i < trimmed.len) {
                    if (isValueWhitespace(trimmed[i])) {
                        var j = i + 1;
                        while (j < trimmed.len and isValueWhitespace(trimmed[j])) : (j += 1) {}
                        if (j > i + 1) {
                            needs_change = true;
                            break;
                        }
                        i = j;
                        continue;
                    }
                    i += 1;
                }
                if (!needs_change) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                i = 0;
                while (i < trimmed.len) {
                    if (isValueWhitespace(trimmed[i])) {
                        while (i < trimmed.len and isValueWhitespace(trimmed[i])) : (i += 1) {}
                        if (i < trimmed.len and out.items.len > 0) try out.append(allocator, ' ');
                        continue;
                    }
                    try out.append(allocator, trimmed[i]);
                    i += 1;
                }
                return out.toOwnedSlice(allocator);
            }

            fn splitNthChildOfArg(text: []const u8) ?struct { anb: []const u8, selector: []const u8 } {
                var depth: u32 = 0;
                var i: usize = 0;
                while (i < text.len) {
                    const ch = text[i];
                    if (ch == '(') {
                        depth += 1;
                    } else if (ch == ')') {
                        if (depth > 0) depth -= 1;
                    } else if (depth == 0 and (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r')) {
                        const rest = std.mem.trimStart(u8, text[i..], " \t\r\n");
                        if (rest.len >= 3 and
                            std.ascii.eqlIgnoreCase(rest[0..2], "of") and
                            (rest[2] == ' ' or rest[2] == '\t' or rest[2] == '\n' or rest[2] == '\r'))
                        {
                            return .{
                                .anb = std.mem.trimEnd(u8, text[0..i], " \t\r\n"),
                                .selector = std.mem.trimStart(u8, rest[2..], " \t\r\n"),
                            };
                        }
                    }
                    i += 1;
                }
                return null;
            }

            fn compactNthChildAnBArg(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                var needs_change = trimmed.len != text.len;
                for (trimmed) |c| {
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        needs_change = true;
                        break;
                    }
                }
                if (!needs_change) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, trimmed.len);
                for (trimmed) |c| {
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
                    out.appendAssumeCapacity(c);
                }
                return out.toOwnedSlice(allocator);
            }

            fn normalizeNthChildArgText(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (splitNthChildOfArg(text)) |parts| {
                    const compact = try compactNthChildAnBArg(allocator, parts.anb);
                    defer if (!(compact.ptr == parts.anb.ptr and compact.len == parts.anb.len)) allocator.free(@constCast(compact));
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(allocator);
                    try out.appendSlice(allocator, compact);
                    try out.appendSlice(allocator, " of ");
                    try out.appendSlice(allocator, parts.selector);
                    if (std.mem.eql(u8, out.items, text)) {
                        out.deinit(allocator);
                        return text;
                    }
                    return out.toOwnedSlice(allocator);
                }
                return compactNthChildAnBArg(allocator, text);
            }

            fn normalizeNthOfTypeSelectorArgs(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (std.ascii.indexOfIgnoreCase(text, "nth-of-type") == null and
                    std.ascii.indexOfIgnoreCase(text, "nth-last-of-type") == null and
                    std.ascii.indexOfIgnoreCase(text, "nth-child") == null and
                    std.ascii.indexOfIgnoreCase(text, "nth-last-child") == null)
                {
                    return text;
                }

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                var changed = false;
                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '(' and i > 0) {
                        const name_end = i;
                        var name_start = name_end;
                        while (name_start > 0) {
                            const prev = text[name_start - 1];
                            if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_') {
                                name_start -= 1;
                            } else break;
                        }
                        if (name_start > 0 and text[name_start - 1] == ':' and
                            (isNthOfTypePseudoName(text[name_start..name_end]) or isNthChildPseudoName(text[name_start..name_end])))
                        {
                            var depth: u32 = 1;
                            var j: usize = i + 1;
                            var inner_string: u8 = 0;
                            while (j < text.len and depth > 0) : (j += 1) {
                                const ch = text[j];
                                if (inner_string != 0) {
                                    if (ch == '\\' and j + 1 < text.len) {
                                        j += 1;
                                        continue;
                                    }
                                    if (ch == inner_string) inner_string = 0;
                                    continue;
                                }
                                if (ch == '"' or ch == '\'') {
                                    inner_string = ch;
                                    continue;
                                }
                                if (ch == '(') depth += 1 else if (ch == ')') depth -= 1;
                            }
                            if (depth == 0) {
                                const inner = text[i + 1 .. j - 1];
                                const normalized = if (isNthChildPseudoName(text[name_start..name_end]))
                                    try normalizeNthChildArgText(allocator, inner)
                                else
                                    try normalizeNthOfTypeArgText(allocator, inner);
                                defer if (!(normalized.ptr == inner.ptr and normalized.len == inner.len)) allocator.free(@constCast(normalized));
                                try out.append(allocator, '(');
                                try out.appendSlice(allocator, normalized);
                                try out.append(allocator, ')');
                                if (!(normalized.ptr == inner.ptr and normalized.len == inner.len)) changed = true;
                                i = j;
                                continue;
                            }
                        }
                    }

                    try out.append(allocator, c);
                    i += 1;
                }

                if (!changed and std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn isValueWhitespace(c: u8) bool {
                return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
            }

            fn isValueIdentChar(c: u8) bool {
                return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
            }

            fn trimTrailingValueSpaces(out: *std.ArrayListUnmanaged(u8)) void {
                while (out.items.len > 0 and isValueWhitespace(out.items[out.items.len - 1])) {
                    _ = out.pop();
                }
            }

            fn appendPendingValueSpace(
                allocator: std.mem.Allocator,
                out: *std.ArrayListUnmanaged(u8),
                next_char: u8,
            ) !void {
                if (out.items.len == 0) return;
                const last = out.items[out.items.len - 1];
                if (isValueWhitespace(last)) return;
                if (last == '(' or last == '[' or last == '/' or last == ',') return;
                if (next_char == ')' or next_char == ']' or next_char == ',' or next_char == '/') return;
                try out.append(allocator, ' ');
            }

            fn normalizeLegacyProgidParenSpacing(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                const needle = "AlphaImageLoader(";
                const pos = std.mem.find(u8, text, needle) orelse return text;
                const open_idx = pos + needle.len - 1;
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, text[0 .. open_idx + 1]);
                const close_idx = findMatchingParen(text, open_idx) orelse return text;
                const inner = text[open_idx + 1 .. close_idx];

                var i: usize = 0;
                var in_string: u8 = 0;
                var pending_ws = false;
                while (i < inner.len) {
                    const c = inner[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < inner.len) {
                            i += 1;
                            try out.append(allocator, inner[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] == '(') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (isValueWhitespace(c)) {
                        pending_ws = true;
                        i += 1;
                        continue;
                    }

                    if (c == ',') {
                        try out.append(allocator, ',');
                        i += 1;
                        const ws_start = i;
                        while (i < inner.len and isValueWhitespace(inner[i])) : (i += 1) {}
                        if (i > ws_start and i < inner.len) try out.append(allocator, ' ');
                        pending_ws = false;
                        continue;
                    }

                    if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] == '(') {
                        try out.append(allocator, ' ');
                    }
                    pending_ws = false;
                    try out.append(allocator, c);
                    i += 1;
                }
                try out.append(allocator, ')');
                try out.appendSlice(allocator, text[close_idx + 1 ..]);
                return out.toOwnedSlice(allocator);
            }

            fn normalizeExpressionCommaSpacing(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                const needle = "expression(";
                const pos = std.mem.find(u8, text, needle) orelse return text;
                const open_idx = pos + needle.len - 1;
                const close_idx = findMatchingParen(text, open_idx) orelse return text;
                const inner = text[open_idx + 1 .. close_idx];

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, text[0 .. open_idx + 1]);

                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < inner.len) {
                    const c = inner[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < inner.len) {
                            i += 1;
                            try out.append(allocator, inner[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == ',') {
                        try out.append(allocator, ',');
                        i += 1;
                        const ws_start = i;
                        while (i < inner.len and isValueWhitespace(inner[i])) : (i += 1) {}
                        if (i > ws_start and i < inner.len) try out.append(allocator, ' ');
                        continue;
                    }
                    try out.append(allocator, c);
                    i += 1;
                }

                try out.append(allocator, ')');
                try out.appendSlice(allocator, text[close_idx + 1 ..]);
                if (std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn normalizeUrlSingleQuotesInDeclarationValue(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (std.mem.find(u8, text, "url('") == null and
                    std.mem.find(u8, text, "URL('") == null and
                    std.mem.find(u8, text, "Url('") == null)
                {
                    return text;
                }

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);
                var changed = false;
                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try buf.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try buf.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try buf.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if ((c == 'u' or c == 'U') and
                        i + 4 < text.len and
                        text[i + 3] == '(' and
                        std.ascii.eqlIgnoreCase(text[i .. i + 3], "url"))
                    {
                        const open = i + 3;
                        const close = css_utils.findMatchingParen(text, open) orelse {
                            try buf.append(allocator, c);
                            i += 1;
                            continue;
                        };
                        const raw_inner = text[open + 1 .. close];
                        const inner = std.mem.trim(u8, raw_inner, " \t");
                        if (inner.len >= 2 and inner[0] == '\'' and inner[inner.len - 1] == '\'') {
                            const has_double_quote = blk: {
                                var p: usize = 1;
                                while (p + 1 < inner.len) : (p += 1) {
                                    if (inner[p] == '\\' and p + 1 < inner.len) {
                                        p += 1;
                                        continue;
                                    }
                                    if (inner[p] == '"') break :blk true;
                                }
                                break :blk false;
                            };
                            if (!has_double_quote) {
                                changed = true;
                                try buf.appendSlice(allocator, text[i .. open + 1]);
                                const lead_ws_len: usize = @intCast(@intFromPtr(inner.ptr) - @intFromPtr(raw_inner.ptr));
                                if (lead_ws_len > 0) try buf.appendSlice(allocator, raw_inner[0..lead_ws_len]);
                                try buf.append(allocator, '"');
                                var p: usize = 1;
                                while (p + 1 < inner.len) : (p += 1) {
                                    if (inner[p] == '\\' and p + 1 < inner.len) {
                                        const esc = inner[p + 1];
                                        switch (esc) {
                                            '\'' => try buf.append(allocator, '\''),
                                            '"' => try buf.appendSlice(allocator, "\\\""),
                                            else => {
                                                try buf.append(allocator, '\\');
                                                try buf.append(allocator, esc);
                                            },
                                        }
                                        p += 1;
                                        continue;
                                    }
                                    if (inner[p] == '"') {
                                        try buf.appendSlice(allocator, "\\\"");
                                    } else {
                                        try buf.append(allocator, inner[p]);
                                    }
                                }
                                try buf.append(allocator, '"');
                                const trail_ws_start: usize = lead_ws_len + inner.len;
                                if (trail_ws_start < raw_inner.len) try buf.appendSlice(allocator, raw_inner[trail_ws_start..]);
                                try buf.append(allocator, ')');
                                i = close + 1;
                                continue;
                            }
                        }
                    }

                    try buf.append(allocator, c);
                    i += 1;
                }

                if (!changed) {
                    buf.deinit(allocator);
                    return text;
                }
                return buf.toOwnedSlice(allocator);
            }

            fn normalizeDeclarationEscapeTokenSpacing(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (std.mem.findScalar(u8, text, '\\') == null) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                var changed = false;
                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c != '\\' or i + 1 >= text.len) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    const next = text[i + 1];
                    if (std.ascii.isHex(next)) {
                        var j: usize = i + 1;
                        var count: usize = 0;
                        while (j < text.len and count < 6 and std.ascii.isHex(text[j])) : (j += 1) {
                            count += 1;
                        }
                        const digits = text[i + 1 .. j];
                        var k = j;
                        while (k < text.len and isValueWhitespace(text[k])) : (k += 1) {}
                        const ws_count = k - j;
                        const parsed = std.fmt.parseInt(u21, digits, 16) catch 0x110000;
                        const needs_delimiter = parsed <= 0x20 or parsed == 0x7F;
                        // Only promote a run of whitespace between this hex escape and the next
                        // escape to `\ ` (literal escaped space) when the follow-up escape is
                        // itself a non-hex escape (e.g. `\ ` for U+0020). If the next escape
                        // begins with a hex digit, the whitespace is a list separator and must
                        // stay as plain whitespace.
                        const next_is_non_hex_escape = k + 1 < text.len and
                            text[k] == '\\' and !std.ascii.isHex(text[k + 1]);

                        try out.append(allocator, '\\');
                        try out.appendSlice(allocator, digits);
                        if (needs_delimiter) {
                            try out.append(allocator, ' ');
                            if (ws_count == 0 or ws_count > 1) changed = true;
                            if (ws_count > 1) {
                                if (next_is_non_hex_escape) {
                                    try out.appendSlice(allocator, "\\ ");
                                } else {
                                    try out.append(allocator, ' ');
                                }
                            }
                        } else if (ws_count != 0) {
                            try out.append(allocator, ' ');
                            if (ws_count > 1) changed = true;
                        }
                        i = k;
                        continue;
                    }

                    try out.append(allocator, '\\');
                    try out.append(allocator, next);
                    i += 2;
                    if (next == ' ') {
                        var k = i;
                        while (k < text.len and isValueWhitespace(text[k])) : (k += 1) {}
                        if (k < text.len and text[k] == '\\') {
                            try out.append(allocator, ' ');
                            if (k != i + 1 or (i < text.len and !isValueWhitespace(text[i]))) changed = true;
                        } else if (k != i) {
                            try out.append(allocator, ' ');
                            if (k != i + 1 or (i < text.len and !isValueWhitespace(text[i]))) changed = true;
                        }
                        i = k;
                    }
                }

                if (!changed and std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn needsDeclarationValueNormalization(text: []const u8) bool {
                if (std.mem.findAny(u8, text, "\n\r\t\x0c") != null) return true;

                var i: usize = 0;
                while (i < text.len) {
                    if (isValueIdentChar(text[i])) {
                        const start = i;
                        i += 1;
                        while (i < text.len and isValueIdentChar(text[i])) : (i += 1) {}
                        if (i < text.len and text[i] == '(') {
                            const ident = text[start..i];
                            if (std.ascii.eqlIgnoreCase(ident, "url") or std.ascii.eqlIgnoreCase(ident, "type")) {
                                if (!std.mem.eql(u8, ident, "url") and !std.mem.eql(u8, ident, "type")) {
                                    return true;
                                }
                            }
                        }
                        continue;
                    }
                    i += 1;
                }

                return false;
            }

            fn normalizeDeclarationValue(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (text.len == 0) return text;
                var current = text;
                var owned_current: ?[]const u8 = null;
                errdefer if (owned_current) |owned| allocator.free(owned);

                const replaceExact = struct {
                    fn run(allocator_: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
                        if (needle.len == 0) return input;
                        if (std.mem.find(u8, input, needle) == null) return input;
                        var out: std.ArrayListUnmanaged(u8) = .empty;
                        errdefer out.deinit(allocator_);
                        var i: usize = 0;
                        while (i < input.len) {
                            if (i + needle.len <= input.len and std.mem.eql(u8, input[i .. i + needle.len], needle)) {
                                try out.appendSlice(allocator_, replacement);
                                i += needle.len;
                                continue;
                            }
                            try out.append(allocator_, input[i]);
                            i += 1;
                        }
                        return out.toOwnedSlice(allocator_);
                    }
                };

                const url_normalized = try normalizeUrlSingleQuotesInDeclarationValue(allocator, current);
                if (!(url_normalized.ptr == current.ptr and url_normalized.len == current.len)) {
                    current = url_normalized;
                    owned_current = url_normalized;
                }

                const escape_normalized = try css_utils.normalizeCssValueEscapes(allocator, current);
                if (!(escape_normalized.ptr == current.ptr and escape_normalized.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = escape_normalized;
                    owned_current = escape_normalized;
                }

                const escape_spaced = try normalizeDeclarationEscapeTokenSpacing(allocator, current);
                if (!(escape_spaced.ptr == current.ptr and escape_spaced.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = escape_spaced;
                    owned_current = escape_spaced;
                }

                const legacy_progid = try normalizeLegacyProgidParenSpacing(allocator, current);
                if (!(legacy_progid.ptr == current.ptr and legacy_progid.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = legacy_progid;
                    owned_current = legacy_progid;
                }

                const expression_commas = try normalizeExpressionCommaSpacing(allocator, current);
                if (!(expression_commas.ptr == current.ptr and expression_commas.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = expression_commas;
                    owned_current = expression_commas;
                }

                // WebKit gradient syntax does not preserve leading whitespace
                // immediately after the opening parenthesis.
                const webkit_linear = try replaceExact.run(allocator, current, "-webkit-linear-gradient( ", "-webkit-linear-gradient(");
                if (!(webkit_linear.ptr == current.ptr and webkit_linear.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = webkit_linear;
                    owned_current = webkit_linear;
                }

                const normalizeWebkitUrlGradient = struct {
                    fn run(allocator_: std.mem.Allocator, input: []const u8) ![]const u8 {
                        const needle = "-webkit-url(";
                        if (std.mem.find(u8, input, needle) == null) return input;

                        var out: std.ArrayListUnmanaged(u8) = .empty;
                        errdefer out.deinit(allocator_);
                        var changed = false;
                        var i: usize = 0;
                        while (i < input.len) {
                            const rel = std.mem.find(u8, input[i..], needle) orelse {
                                try out.appendSlice(allocator_, input[i..]);
                                break;
                            };
                            const pos = i + rel;
                            try out.appendSlice(allocator_, input[i..pos]);

                            const open_idx = pos + needle.len - 1;
                            const close_idx = findMatchingParen(input, open_idx) orelse {
                                try out.appendSlice(allocator_, input[pos..]);
                                i = input.len;
                                break;
                            };
                            const after_url = close_idx + 1;
                            try out.appendSlice(allocator_, input[pos..after_url]);

                            const gradient_prefix = "-gradient( ";
                            if (after_url + gradient_prefix.len <= input.len and
                                std.mem.eql(u8, input[after_url .. after_url + gradient_prefix.len], gradient_prefix))
                            {
                                try out.appendSlice(allocator_, "-gradient(");
                                i = after_url + gradient_prefix.len;
                                changed = true;
                                continue;
                            }

                            i = after_url;
                        }

                        if (!changed and std.mem.eql(u8, out.items, input)) {
                            out.deinit(allocator_);
                            return input;
                        }
                        return out.toOwnedSlice(allocator_);
                    }
                };

                const webkit_url_gradient = try normalizeWebkitUrlGradient.run(allocator, current);
                if (!(webkit_url_gradient.ptr == current.ptr and webkit_url_gradient.len == current.len)) {
                    if (owned_current) |owned| allocator.free(owned);
                    current = webkit_url_gradient;
                    owned_current = webkit_url_gradient;
                }

                if (std.mem.find(u8, current, "/*") != null or std.mem.find(u8, current, "//") != null) return current;
                if (!needsDeclarationValueNormalization(current)) return current;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);

                var i: usize = 0;
                var in_string: u8 = 0;
                var pending_ws = false;
                while (i < current.len) {
                    const c = current[i];

                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < current.len) {
                            try out.append(allocator, c);
                            i += 1;
                            try out.append(allocator, current[i]);
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        if (pending_ws) {
                            try appendPendingValueSpace(allocator, &out, c);
                            pending_ws = false;
                        }
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (isValueWhitespace(c)) {
                        pending_ws = true;
                        i += 1;
                        continue;
                    }

                    if (isValueIdentChar(c)) {
                        const start = i;
                        i += 1;
                        while (i < current.len and isValueIdentChar(current[i])) : (i += 1) {}
                        const ident = current[start..i];

                        if (pending_ws) {
                            try appendPendingValueSpace(allocator, &out, ident[0]);
                            pending_ws = false;
                        }

                        const is_special =
                            i < current.len and current[i] == '(' and
                            (std.ascii.eqlIgnoreCase(ident, "url") or std.ascii.eqlIgnoreCase(ident, "type"));
                        if (is_special) {
                            if (std.ascii.eqlIgnoreCase(ident, "url")) {
                                try out.appendSlice(allocator, "url");
                            } else {
                                try out.appendSlice(allocator, "type");
                            }
                        } else {
                            try out.appendSlice(allocator, ident);
                        }
                        continue;
                    }

                    if (c == ',') {
                        trimTrailingValueSpaces(&out);
                        try out.append(allocator, ',');
                        i += 1;
                        while (i < current.len and isValueWhitespace(current[i])) : (i += 1) {}
                        if (i < current.len and current[i] != ')' and current[i] != ']' and current[i] != '}' and current[i] != ',') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        continue;
                    }

                    if (c == '/') {
                        var prev_non_ws: u8 = 0;
                        if (out.items.len > 0) {
                            var p = out.items.len;
                            while (p > 0) {
                                p -= 1;
                                if (!isValueWhitespace(out.items[p])) {
                                    prev_non_ws = out.items[p];
                                    break;
                                }
                            }
                        }
                        if (prev_non_ws == ',') {
                            while (out.items.len > 0 and isValueWhitespace(out.items[out.items.len - 1])) {
                                _ = out.pop();
                            }
                            try out.append(allocator, ' ');
                        } else {
                            trimTrailingValueSpaces(&out);
                        }
                        try out.append(allocator, '/');
                        i += 1;
                        while (i < current.len and isValueWhitespace(current[i])) : (i += 1) {}
                        pending_ws = false;
                        continue;
                    }

                    if (c == '(') {
                        if (pending_ws) {
                            try appendPendingValueSpace(allocator, &out, c);
                            pending_ws = false;
                        }
                        try out.append(allocator, '(');
                        i += 1;
                        while (i < current.len and isValueWhitespace(current[i])) : (i += 1) {}
                        continue;
                    }

                    if (c == ')') {
                        trimTrailingValueSpaces(&out);
                        try out.append(allocator, ')');
                        i += 1;
                        pending_ws = false;
                        continue;
                    }

                    if (c == '!') {
                        var j = i + 1;
                        while (j < current.len and isValueWhitespace(current[j])) : (j += 1) {}
                        if (j + 9 <= current.len and std.mem.eql(u8, current[j .. j + 9], "important")) {
                            if (pending_ws) {
                                try appendPendingValueSpace(allocator, &out, c);
                                pending_ws = false;
                            }
                            if (out.items.len > 0) {
                                const last = out.items[out.items.len - 1];
                                if (!isValueWhitespace(last) and last != '(' and last != '[' and last != ':') {
                                    try out.append(allocator, ' ');
                                }
                            }
                            try out.appendSlice(allocator, "!important");
                            i = j + 9;
                            continue;
                        }
                    }

                    if (pending_ws) {
                        try appendPendingValueSpace(allocator, &out, c);
                        pending_ws = false;
                    }
                    try out.append(allocator, c);
                    i += 1;
                }

                const owned = try out.toOwnedSlice(allocator);
                if (std.mem.eql(u8, owned, current)) {
                    if (owned_current) |already_owned| {
                        allocator.free(owned);
                        return already_owned;
                    }
                    allocator.free(owned);
                    return current;
                }
                if (owned_current) |already_owned| allocator.free(already_owned);
                current = owned;
                owned_current = owned;
                return current;
            }

            fn normalizeApplyPreludeWhitespace(
                allocator: std.mem.Allocator,
                text: []const u8,
            ) ![]const u8 {
                if (std.mem.findScalar(u8, text, '(') == null) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);

                var i: usize = 0;
                var changed = false;
                var in_string: u8 = 0;
                var pending_ws = false;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (isValueWhitespace(c)) {
                        pending_ws = true;
                        i += 1;
                        continue;
                    }

                    if (c == '(') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        try out.append(allocator, '(');
                        i += 1;
                        const ws_start = i;
                        while (i < text.len and isValueWhitespace(text[i])) : (i += 1) {}
                        if (i > ws_start and i < text.len and text[i] != ')') {
                            try out.append(allocator, ' ');
                            changed = true;
                        }
                        continue;
                    }

                    if (c == ')') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(' and out.items[out.items.len - 1] != ' ') {
                            try out.append(allocator, ' ');
                            changed = true;
                        }
                        pending_ws = false;
                        try out.append(allocator, ')');
                        i += 1;
                        continue;
                    }

                    if (c == ',') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(' and out.items[out.items.len - 1] != ' ') {
                            try out.append(allocator, ' ');
                            changed = true;
                        } else {
                            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                                _ = out.pop();
                                changed = true;
                            }
                        }
                        try out.append(allocator, ',');
                        i += 1;
                        while (i < text.len and isValueWhitespace(text[i])) : (i += 1) {}
                        if (i < text.len and text[i] != ')') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        continue;
                    }

                    if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(' and out.items[out.items.len - 1] != ' ') {
                        try out.append(allocator, ' ');
                    }
                    pending_ws = false;
                    try out.append(allocator, c);
                    i += 1;
                }

                if (!changed and std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn isMediaLogicalKeyword(word: []const u8) bool {
                return std.ascii.eqlIgnoreCase(word, "and") or
                    std.ascii.eqlIgnoreCase(word, "or") or
                    std.ascii.eqlIgnoreCase(word, "not");
            }

            fn appendMediaKeywordNormalized(
                allocator: std.mem.Allocator,
                out: *std.ArrayListUnmanaged(u8),
                word: []const u8,
            ) !void {
                if (std.ascii.eqlIgnoreCase(word, "and")) return out.appendSlice(allocator, "and");
                if (std.ascii.eqlIgnoreCase(word, "or")) return out.appendSlice(allocator, "or");
                if (std.ascii.eqlIgnoreCase(word, "not")) return out.appendSlice(allocator, "not");
                try out.appendSlice(allocator, word);
            }

            fn endsWithCssHexEscapeForMedia(text: []const u8) bool {
                if (text.len < 2) return false;
                var i: usize = text.len;
                var count: u8 = 0;
                while (i > 0 and count < 6 and std.ascii.isHex(text[i - 1])) {
                    i -= 1;
                    count += 1;
                }
                if (count == 0 or i == 0) return false;
                return text[i - 1] == '\\';
            }

            fn normalizeMediaPrelude(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (text.len == 0) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);

                var i: usize = 0;
                var in_string: u8 = 0;
                var pending_ws = false;
                while (i < text.len) {
                    const c = text[i];

                    if (in_string != 0) {
                        if (c == '\\' and i + 1 < text.len) {
                            try out.append(allocator, c);
                            i += 1;
                            try out.append(allocator, text[i]);
                            i += 1;
                            continue;
                        }
                        if (c == in_string) in_string = 0;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (c == '"' or c == '\'') {
                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    if (isWhitespaceChar(c) or c == '\x0c') {
                        pending_ws = true;
                        i += 1;
                        continue;
                    }

                    if (c == ':') {
                        trimTrailingValueSpaces(&out);
                        try out.append(allocator, ':');
                        i += 1;
                        while (i < text.len and (isWhitespaceChar(text[i]) or text[i] == '\x0c')) : (i += 1) {}
                        if (i < text.len and text[i] != ')') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        continue;
                    }

                    if (isIdentChar(c)) {
                        const start = i;
                        i += 1;
                        while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
                        const word = text[start..i];

                        const prev_ident = start > 0 and isIdentChar(text[start - 1]);
                        const next_ident = i < text.len and isIdentChar(text[i]);
                        const logical_kw = isMediaLogicalKeyword(word) and !prev_ident and !next_ident;

                        if (logical_kw) {
                            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ' and out.items[out.items.len - 1] != '(') {
                                try out.append(allocator, ' ');
                            } else if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                                try out.append(allocator, ' ');
                            }
                            try appendMediaKeywordNormalized(allocator, &out, word);

                            var j = i;
                            while (j < text.len and (isWhitespaceChar(text[j]) or text[j] == '\x0c')) : (j += 1) {}
                            if (j < text.len and text[j] != ')' and text[j] != ',' and text[j] != ';') {
                                try out.append(allocator, ' ');
                            }
                            pending_ws = false;
                            i = j;
                            continue;
                        }

                        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                            try out.append(allocator, ' ');
                        }
                        pending_ws = false;
                        try out.appendSlice(allocator, word);
                        continue;
                    }

                    if (c == ')') {
                        trimTrailingValueSpaces(&out);
                        if (endsWithCssHexEscapeForMedia(out.items)) {
                            try out.append(allocator, ' ');
                        }
                    }
                    if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != ' ' and c != ')') {
                        try out.append(allocator, ' ');
                    }
                    pending_ws = false;
                    try out.append(allocator, c);
                    i += 1;
                }

                const owned = try out.toOwnedSlice(allocator);
                const left_trimmed = std.mem.trimStart(u8, owned, " ");
                const trimmed = css_utils.trimRightPreservingHexEscape(left_trimmed);
                if (trimmed.ptr != owned.ptr or trimmed.len != owned.len) {
                    defer allocator.free(owned);
                    const dup = try allocator.dupe(u8, trimmed);
                    if (std.mem.eql(u8, dup, text)) {
                        allocator.free(dup);
                        return text;
                    }
                    return dup;
                }
                if (std.mem.eql(u8, owned, text)) {
                    allocator.free(owned);
                    return text;
                }
                return owned;
            }

            fn ensureTrailingControlHexEscapeSpace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (text.len == 0) return text;
                const last = text[text.len - 1];
                if (last == ' ' or last == '\t' or last == '\n' or last == '\r') return text;

                var i = text.len;
                var count: usize = 0;
                while (i > 0 and count < 6 and std.ascii.isHex(text[i - 1])) : (count += 1) {
                    i -= 1;
                }
                if (count == 0 or i == 0 or text[i - 1] != '\\') return text;

                const value = std.fmt.parseInt(u21, text[i..], 16) catch return text;
                if (!(value == ' ' or value <= 0x1F or value == 0x7F)) return text;
                return std.fmt.allocPrint(allocator, "{s} ", .{text});
            }

            /// Whitespace (space/tab/newline) in one compound selector to single space
            /// collapses. The newline of top-level comma (`.a, .b`) is preserved, so
            /// Split with comma and normalize only the inside of each segment. string / `(` `[`
            /// Do not touch the internal contents (line breaks in the pseudo argument are handled in a separate pass).
            fn normalizeSelectorCompoundWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                // Check whether conversion is necessary first (whether newline is included in continuous ws other than comma/comment at top-level).
                var needs_rewrite = false;
                {
                    var i: usize = 0;
                    var depth: u32 = 0;
                    var in_string: u8 = 0;
                    while (i < text.len) : (i += 1) {
                        const ch = text[i];
                        if (in_string != 0) {
                            if (ch == '\\' and i + 1 < text.len) {
                                i += 1;
                                continue;
                            }
                            if (ch == in_string) in_string = 0;
                            continue;
                        }
                        if (ch == '"' or ch == '\'') {
                            in_string = ch;
                            continue;
                        }
                        if (ch == '(' or ch == '[') {
                            depth += 1;
                            continue;
                        }
                        if (ch == ')' or ch == ']') {
                            if (depth > 0) depth -= 1;
                            continue;
                        }
                        if (depth > 0) continue;
                        if (ch == ',') continue;
                        if (ch == ' ' or ch == '\t') {
                            if (i + 1 < text.len and (text[i + 1] == ' ' or text[i + 1] == '\t')) {
                                needs_rewrite = true;
                                break;
                            }
                            continue;
                        }
                        if (ch == '\n' or ch == '\r') {
                            // top-level newline: check if this is part of a comma-separated list
                            // (look backward for last non-ws char: if comma, preserve; else collapse).
                            var k: usize = i;
                            while (k > 0) {
                                k -= 1;
                                const c = text[k];
                                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
                                if (c == ',') break;
                                needs_rewrite = true;
                                break;
                            }
                            if (needs_rewrite) break;
                        }
                    }
                }
                if (!needs_rewrite) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len);

                // Process each segment.
                // Within each segment (comma-separated range) collapse top-level ws runs to a single space,
                // However, ws at the beginning/end of the segment is trimmed. Comma + newline at segment boundary is retained.
                var seg_start: usize = 0;
                var i: usize = 0;
                var depth: u32 = 0;
                var in_string: u8 = 0;
                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    if (in_string != 0) {
                        if (ch == '\\' and i + 1 < text.len) {
                            i += 1;
                            continue;
                        }
                        if (ch == in_string) in_string = 0;
                        continue;
                    }
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        continue;
                    }
                    if (ch == '(' or ch == '[') {
                        depth += 1;
                        continue;
                    }
                    if (ch == ')' or ch == ']') {
                        if (depth > 0) depth -= 1;
                        continue;
                    }
                    if (depth == 0 and ch == ',') {
                        const segment = text[seg_start..i];
                        var segment_body_start: usize = 0;
                        while (segment_body_start < segment.len and
                            (segment[segment_body_start] == ' ' or segment[segment_body_start] == '\t' or
                                segment[segment_body_start] == '\n' or segment[segment_body_start] == '\r'))
                        {
                            segment_body_start += 1;
                        }
                        const segment_body = segment[segment_body_start..];
                        const segment_had_newline = std.mem.indexOfAny(u8, segment_body, "\n\r") != null;
                        var ws_i = i + 1;
                        var saw_space = false;
                        var separator_after_has_newline = false;
                        while (ws_i < text.len and
                            (text[ws_i] == ' ' or text[ws_i] == '\t' or text[ws_i] == '\n' or text[ws_i] == '\r'))
                        {
                            if (text[ws_i] == '\n' or text[ws_i] == '\r') separator_after_has_newline = true;
                            if (text[ws_i] == ' ' or text[ws_i] == '\t') saw_space = true;
                            ws_i += 1;
                        }
                        try appendSelectorSegmentCollapsed(allocator, &out, segment);
                        try out.append(allocator, ',');
                        if (segment_had_newline or separator_after_has_newline) {
                            try out.append(allocator, '\n');
                        } else {
                            if (saw_space) try out.append(allocator, ' ');
                        }
                        seg_start = ws_i;
                    }
                }
                try appendSelectorSegmentCollapsed(allocator, &out, text[seg_start..]);
                return out.toOwnedSlice(allocator);
            }

            fn appendSelectorSegmentCollapsed(
                allocator: std.mem.Allocator,
                out: *std.ArrayListUnmanaged(u8),
                seg: []const u8,
            ) !void {
                // find start of non-leading-ws (but preserve leading newline run when it starts the segment
                //-- that's the comma-separated multi-line case, leading newline belongs to this item's prefix).
                var start: usize = 0;
                var had_newline_prefix = false;
                while (start < seg.len) : (start += 1) {
                    const c = seg[start];
                    if (c == '\n' or c == '\r') {
                        had_newline_prefix = true;
                        continue;
                    }
                    if (c == ' ' or c == '\t') continue;
                    break;
                }
                if (had_newline_prefix) {
                    try out.append(allocator, '\n');
                }
                // trim trailing ws
                var end: usize = seg.len;
                while (end > start) : (end -= 1) {
                    const c = seg[end - 1];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
                    break;
                }
                // collapse top-level ws runs (non-string/non-paren depth) to single space.
                var j = start;
                var depth: u32 = 0;
                var in_string: u8 = 0;
                while (j < end) : (j += 1) {
                    const ch = seg[j];
                    if (in_string != 0) {
                        try out.append(allocator, ch);
                        if (ch == '\\' and j + 1 < end) {
                            try out.append(allocator, seg[j + 1]);
                            j += 1;
                            continue;
                        }
                        if (ch == in_string) in_string = 0;
                        continue;
                    }
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (ch == '(' or ch == '[') {
                        depth += 1;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (ch == ')' or ch == ']') {
                        if (depth > 0) depth -= 1;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (depth == 0 and (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r')) {
                        // skip any further ws
                        var k = j + 1;
                        while (k < end and (seg[k] == ' ' or seg[k] == '\t' or seg[k] == '\n' or seg[k] == '\r')) : (k += 1) {}
                        if (j > start and seg[j - 1] == '\\' and k > j + 1) {
                            try out.appendSlice(allocator, "  ");
                        } else {
                            try out.append(allocator, ' ');
                        }
                        j = k - 1;
                        continue;
                    }
                    try out.append(allocator, ch);
                }
            }

            /// Whitespace from selector text to "immediately after `(` / immediately before `)`" (especially newline)
            // Delete ///. When official Sass CLI writes pseudo arguments such as `:not(` in multi-line,
            /// Put the first arg on the same line as open-paren and make `)` the same as the last arg.
            /// Newlines between arguments are retained. string / interpolation is skipped.
            fn collapseSelectorParenEdgeWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                // Check if there is target whitespace first.
                var needs_rewrite = false;
                {
                    var i: usize = 0;
                    var in_string: u8 = 0;
                    while (i < text.len) : (i += 1) {
                        const ch = text[i];
                        if (in_string != 0) {
                            if (ch == '\\' and i + 1 < text.len) {
                                i += 1;
                                continue;
                            }
                            if (ch == in_string) in_string = 0;
                            continue;
                        }
                        if (ch == '"' or ch == '\'') {
                            in_string = ch;
                            continue;
                        }
                        if (ch == '(' and i + 1 < text.len) {
                            const next = text[i + 1];
                            if (next == ' ' or next == '\t' or next == '\n' or next == '\r') {
                                needs_rewrite = true;
                                break;
                            }
                        }
                        if (ch == ')' and i > 0) {
                            const prev = text[i - 1];
                            if (prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r') {
                                needs_rewrite = true;
                                break;
                            }
                        }
                    }
                }
                if (!needs_rewrite) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len);

                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, ch);
                        if (ch == '\\' and i + 1 < text.len) {
                            try out.append(allocator, text[i + 1]);
                            i += 1;
                            continue;
                        }
                        if (ch == in_string) in_string = 0;
                        continue;
                    }
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (ch == '(') {
                        try out.append(allocator, ch);
                        // Drop all whitespace (space/tab/newline) immediately after.
                        var j = i + 1;
                        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) : (j += 1) {}
                        i = j - 1;
                        continue;
                    }
                    if (ch == ')') {
                        // Trim the previous whitespace (already in out).
                        while (out.items.len > 0) {
                            const last = out.items[out.items.len - 1];
                            if (last == ' ' or last == '\t' or last == '\n' or last == '\r') {
                                _ = out.pop();
                                continue;
                            }
                            break;
                        }
                        try out.append(allocator, ch);
                        continue;
                    }
                    try out.append(allocator, ch);
                }
                return out.toOwnedSlice(allocator);
            }

            fn normalizePseudoLeadingChildCombinatorSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (std.mem.indexOf(u8, text, "(>") == null) return text;
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len + 4);
                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '(' and i + 2 < text.len and text[i + 1] == '>' and
                        text[i + 2] != ' ' and text[i + 2] != '\t' and text[i + 2] != '\n' and text[i + 2] != '\r')
                    {
                        try out.appendSlice(allocator, "(> ");
                        i += 2;
                        continue;
                    }
                    try out.append(allocator, c);
                    i += 1;
                }
                if (std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn selectorPseudoBaseName(name: []const u8) []const u8 {
                if (name.len > 1 and name[0] == '-') {
                    if (std.mem.findScalar(u8, name[1..], '-')) |pos| {
                        return name[pos + 2 ..];
                    }
                }
                return name;
            }

            fn isSelectorArgumentPseudo(name: []const u8) bool {
                const base = selectorPseudoBaseName(name);
                const selector_pseudos = [_][]const u8{
                    "not",  "is",           "has",     "where",   "matches",   "any",
                    "host", "host-context", "slotted", "current", "nth-child", "nth-last-child",
                };
                for (selector_pseudos) |sp| {
                    if (std.ascii.eqlIgnoreCase(base, sp)) return true;
                }
                return false;
            }

            fn normalizeSelectorArgumentListSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len);

                var changed = false;
                var i: usize = 0;
                var depth: u32 = 0;
                var bracket_depth: u32 = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == '\\' and i + 1 < text.len) {
                        try out.append(allocator, c);
                        i += 1;
                        try out.append(allocator, text[i]);
                        i += 1;
                        continue;
                    }
                    if (c == '[') {
                        bracket_depth += 1;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c == ']') {
                        if (bracket_depth > 0) bracket_depth -= 1;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (bracket_depth == 0 and c == '(') {
                        depth += 1;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (bracket_depth == 0 and c == ')') {
                        if (depth > 0) depth -= 1;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (depth == 0 and bracket_depth == 0 and c == ',') {
                        try out.append(allocator, ',');
                        var j = i + 1;
                        var saw_newline = false;
                        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) : (j += 1) {
                            if (text[j] == '\n' or text[j] == '\r') saw_newline = true;
                        }
                        if (j < text.len) try out.append(allocator, if (saw_newline) '\n' else ' ');
                        if (saw_newline) {
                            if (i + 1 >= text.len or (text[i + 1] != '\n' and text[i + 1] != '\r')) changed = true;
                        } else if (j != i + 2 or (i + 1 < text.len and text[i + 1] != ' ')) {
                            changed = true;
                        }
                        i = j;
                        continue;
                    }
                    if (depth == 0 and bracket_depth == 0 and (c == '>' or c == '+' or c == '~')) {
                        try out.append(allocator, c);
                        const next = i + 1;
                        if (next < text.len and text[next] != ' ' and text[next] != '\t' and text[next] != '\n' and text[next] != '\r') {
                            try out.append(allocator, ' ');
                            changed = true;
                        }
                        i += 1;
                        continue;
                    }
                    try out.append(allocator, c);
                    i += 1;
                }

                if (!changed and std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            fn normalizeSelectorPseudoArgumentSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                if (std.mem.findScalar(u8, text, '(') == null) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len);

                var changed = false;
                var i: usize = 0;
                var in_string: u8 = 0;
                while (i < text.len) {
                    const c = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < text.len) {
                            i += 1;
                            try out.append(allocator, text[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (c != '(' or i == 0) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    const name_end = i;
                    var name_start = name_end;
                    while (name_start > 0) {
                        const prev = text[name_start - 1];
                        if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_') {
                            name_start -= 1;
                        } else break;
                    }
                    if (name_start == 0 or text[name_start - 1] != ':' or !isSelectorArgumentPseudo(text[name_start..name_end])) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    var depth: u32 = 1;
                    var bracket_depth: u32 = 0;
                    var j = i + 1;
                    var inner_string: u8 = 0;
                    while (j < text.len and depth > 0) : (j += 1) {
                        const ch = text[j];
                        if (inner_string != 0) {
                            if (ch == '\\' and j + 1 < text.len) {
                                j += 1;
                                continue;
                            }
                            if (ch == inner_string) inner_string = 0;
                            continue;
                        }
                        if (ch == '"' or ch == '\'') {
                            inner_string = ch;
                            continue;
                        }
                        if (ch == '[') {
                            bracket_depth += 1;
                            continue;
                        }
                        if (ch == ']') {
                            if (bracket_depth > 0) bracket_depth -= 1;
                            continue;
                        }
                        if (bracket_depth != 0) continue;
                        if (ch == '(') depth += 1 else if (ch == ')') depth -= 1;
                    }
                    if (depth != 0) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    const inner = text[i + 1 .. j - 1];
                    const pseudo_name = text[name_start..name_end];
                    const nested = try normalizeSelectorPseudoArgumentSpacing(allocator, inner);
                    defer if (!(nested.ptr == inner.ptr and nested.len == inner.len)) allocator.free(@constCast(nested));
                    const spaced = if (isNthChildPseudoName(pseudo_name))
                        try normalizeNthChildArgText(allocator, nested)
                    else
                        try normalizeSelectorArgumentListSpacing(allocator, nested);
                    defer if (!(spaced.ptr == nested.ptr and spaced.len == nested.len)) allocator.free(@constCast(spaced));

                    try out.append(allocator, '(');
                    try out.appendSlice(allocator, spaced);
                    try out.append(allocator, ')');
                    if (!(spaced.ptr == inner.ptr and spaced.len == inner.len and std.mem.eql(u8, spaced, inner))) changed = true;
                    i = j;
                }

                if (!changed and std.mem.eql(u8, out.items, text)) {
                    out.deinit(allocator);
                    return text;
                }
                return out.toOwnedSlice(allocator);
            }

            /// Add a single space before and after combinator (`>`, `+`, `~`, `||`) in selector text
            /// Put it in. official Sass CLI normalizes `img+.b` to `img + .b`. string / `(...)` /
            /// Skip inside `[...]` and escapes (such as `\+`). , is not a combinator, so
            /// Pass through (handled separately as selector-list separator). There is already ws on only one side.
            /// Even if there is no space, normalize and add spaces on both sides. The first/last combinator has
            /// Do not include space on the corresponding side.
            fn normalizeSelectorCombinatorSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
                const isCombWs = struct {
                    fn f(c: u8) bool {
                        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
                    }
                }.f;

                // Check whether rewrite is necessary first.
                var needs_rewrite = false;
                {
                    var i: usize = 0;
                    var depth: u32 = 0;
                    var in_string: u8 = 0;
                    while (i < text.len) : (i += 1) {
                        const ch = text[i];
                        if (in_string != 0) {
                            if (ch == '\\' and i + 1 < text.len) {
                                i += 1;
                                continue;
                            }
                            if (ch == in_string) in_string = 0;
                            continue;
                        }
                        if (ch == '\\' and i + 1 < text.len) {
                            i += 1;
                            continue;
                        }
                        if (ch == '"' or ch == '\'') {
                            in_string = ch;
                            continue;
                        }
                        if (ch == '(' or ch == '[') {
                            depth += 1;
                            continue;
                        }
                        if (ch == ')' or ch == ']') {
                            if (depth > 0) depth -= 1;
                            continue;
                        }
                        if (depth > 0) continue;
                        const is_col = ch == '|' and i + 1 < text.len and text[i + 1] == '|';
                        const is_single = ch == '>' or ch == '+' or ch == '~';
                        if (!is_single and !is_col) continue;
                        if ((ch == '+' or ch == '-') and i >= 2 and (text[i - 1] == 'e' or text[i - 1] == 'E') and
                            (std.ascii.isDigit(text[i - 2]) or text[i - 2] == '.'))
                            continue;
                        const comb_len: usize = if (is_col) 2 else 1;
                        const needs_leading = i > 0 and !isCombWs(text[i - 1]);
                        const after = i + comb_len;
                        const needs_trailing = after < text.len and !isCombWs(text[after]);
                        if (needs_leading or needs_trailing) {
                            needs_rewrite = true;
                            break;
                        }
                        i += comb_len - 1;
                    }
                }
                if (!needs_rewrite) return text;

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, text.len + 8);

                var i: usize = 0;
                var depth: u32 = 0;
                var in_string: u8 = 0;
                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    if (in_string != 0) {
                        try out.append(allocator, ch);
                        if (ch == '\\' and i + 1 < text.len) {
                            try out.append(allocator, text[i + 1]);
                            i += 1;
                            continue;
                        }
                        if (ch == in_string) in_string = 0;
                        continue;
                    }
                    if (ch == '\\' and i + 1 < text.len) {
                        try out.append(allocator, ch);
                        try out.append(allocator, text[i + 1]);
                        i += 1;
                        continue;
                    }
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (ch == '(' or ch == '[') {
                        depth += 1;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (ch == ')' or ch == ']') {
                        if (depth > 0) depth -= 1;
                        try out.append(allocator, ch);
                        continue;
                    }
                    if (depth > 0) {
                        try out.append(allocator, ch);
                        continue;
                    }
                    const is_col = ch == '|' and i + 1 < text.len and text[i + 1] == '|';
                    const is_single = ch == '>' or ch == '+' or ch == '~';
                    if (!is_single and !is_col) {
                        try out.append(allocator, ch);
                        continue;
                    }
                    if ((ch == '+' or ch == '-') and out.items.len >= 2 and
                        (out.items[out.items.len - 1] == 'e' or out.items[out.items.len - 1] == 'E') and
                        (std.ascii.isDigit(out.items[out.items.len - 2]) or out.items[out.items.len - 2] == '.'))
                    {
                        try out.append(allocator, ch);
                        continue;
                    }
                    const comb_len: usize = if (is_col) 2 else 1;
                    // Fold the previous ws into one space (drop the trailing ws at the end of out,
                    // Insert 1 space if something has been emitted). If out is empty / ends with `,`
                    // Do not output leading space as the first combinator.
                    while (out.items.len > 0 and isCombWs(out.items[out.items.len - 1])) {
                        _ = out.pop();
                    }
                    const at_start = out.items.len == 0 or out.items[out.items.len - 1] == ',';
                    if (!at_start) try out.append(allocator, ' ');
                    if (is_col) {
                        try out.append(allocator, '|');
                        try out.append(allocator, '|');
                    } else {
                        try out.append(allocator, ch);
                    }
                    // Skip the trailing ws on the input side (however, `\n`/`\r` are treated as ws that are not retained).
                    var j = i + comb_len;
                    while (j < text.len and isCombWs(text[j])) : (j += 1) {}
                    // If there is a trailing combinator (such as `a~`) and there is no trailing compound, trailing space is not required.
                    if (j < text.len and text[j] != ',') try out.append(allocator, ' ');
                    i = j - 1;
                }
                return out.toOwnedSlice(allocator);
            }

            const AtRulePreludeMode = enum {
                simple,
                block,
            };

            fn normalizeAtRulePreludeForEmit(
                allocator: std.mem.Allocator,
                name: []const u8,
                prelude_input: []const u8,
                preserve_media_case: bool,
                mode: AtRulePreludeMode,
            ) ![]const u8 {
                var prelude_text = prelude_input;
                var prelude_owned: ?[]const u8 = null;
                errdefer if (prelude_owned) |owned| allocator.free(owned);

                if (isSupportsAtRuleName(name)) {
                    const normalized = try normalizeSupportsPrelude(allocator, prelude_text);
                    if (!(normalized.ptr == prelude_text.ptr and normalized.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = normalized;
                        prelude_owned = normalized;
                    }
                    const adjusted = try ensureSupportsCustomPropertyWhitespace(allocator, prelude_text);
                    if (!(adjusted.ptr == prelude_text.ptr and adjusted.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = adjusted;
                        prelude_owned = adjusted;
                    }
                } else if (std.ascii.eqlIgnoreCase(name, "import")) {
                    const normalized = try normalizeSupportsInImportPrelude(allocator, prelude_text);
                    if (!(normalized.ptr == prelude_text.ptr and normalized.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = normalized;
                        prelude_owned = normalized;
                    }
                } else if (mode == .simple and std.ascii.eqlIgnoreCase(name, "apply")) {
                    const normalized = try normalizeApplyPreludeWhitespace(allocator, prelude_text);
                    if (!(normalized.ptr == prelude_text.ptr and normalized.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = normalized;
                        prelude_owned = normalized;
                    }
                } else if (isMediaAtRuleName(name) and !preserve_media_case) {
                    const normalized = try normalizeMediaPrelude(allocator, prelude_text);
                    if (!(normalized.ptr == prelude_text.ptr and normalized.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = normalized;
                        prelude_owned = normalized;
                    }
                } else if (mode == .block and std.ascii.eqlIgnoreCase(name, "-moz-document")) {
                    const normalized = try normalizeMozDocumentPrelude(allocator, prelude_text);
                    if (!(normalized.ptr == prelude_text.ptr and normalized.len == prelude_text.len)) {
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = normalized;
                        prelude_owned = normalized;
                    }
                }

                if (mode == .simple and prelude_text.len != 0 and prelude_text[0] == ':') {
                    var rest_start: usize = 1;
                    while (rest_start < prelude_text.len and (prelude_text[rest_start] == ' ' or prelude_text[rest_start] == '\t')) : (rest_start += 1) {}
                    if (rest_start > 2 or (rest_start > 1 and rest_start < prelude_text.len)) {
                        var normalized = std.ArrayListUnmanaged(u8).empty;
                        errdefer normalized.deinit(allocator);
                        try normalized.append(allocator, ':');
                        if (rest_start < prelude_text.len) {
                            try normalized.append(allocator, ' ');
                            try normalized.appendSlice(allocator, prelude_text[rest_start..]);
                        }
                        if (prelude_owned) |owned| allocator.free(owned);
                        prelude_text = try normalized.toOwnedSlice(allocator);
                        prelude_owned = prelude_text;
                    }
                }

                const escaped = try ensureTrailingControlHexEscapeSpace(allocator, prelude_text);
                if (!(escaped.ptr == prelude_text.ptr and escaped.len == prelude_text.len)) {
                    if (prelude_owned) |owned| allocator.free(owned);
                    prelude_text = escaped;
                    prelude_owned = escaped;
                }

                if (isSupportsAtRuleName(name)) {
                    ir_validate.validateSupportsPrelude(prelude_text) catch return error.SassError;
                }
                return prelude_text;
            }

            /// Equivalent to `CodeGen.writeCustomPropertyValue`:
            /// Normalize the continuation line of custom property value to the current indent.
            fn writeCustomPropertyValue(
                emit: *EmitCtx,
                allocator: std.mem.Allocator,
                value: []const u8,
                indent_level: usize,
                source_decl_col: ?usize,
            ) !void {
                var rendered_value = value;
                var effective_source_decl_col = source_decl_col;
                var marker_stripped_owned: ?[]const u8 = null;
                defer if (marker_stripped_owned) |owned| allocator.free(owned);
                if (try stripCustomPropertySourceColMarker(allocator, rendered_value)) |marked| {
                    rendered_value = marked.value;
                    marker_stripped_owned = marked.owned;
                    effective_source_decl_col = marked.source_col;
                }
                const preserve_unmarked = try stripCalcInterpolationPreserveMarkers(allocator, rendered_value);
                if (preserve_unmarked.ptr != rendered_value.ptr) {
                    if (marker_stripped_owned) |owned| allocator.free(owned);
                    rendered_value = preserve_unmarked;
                    marker_stripped_owned = preserve_unmarked;
                }
                if (effective_source_decl_col != null and effective_source_decl_col.? == 0 and indent_level > 0 and
                    rendered_value.len != 0 and (rendered_value[0] == ' ' or rendered_value[0] == '\t') and
                    std.mem.findAny(u8, rendered_value, "\n\r") != null)
                {
                    effective_source_decl_col = indent_level * 2;
                }
                var emit_space_after = false;

                const first_nl = std.mem.findAny(u8, rendered_value, "\n\r") orelse {
                    const normalized = try normalizeOneLineCustomPropertyValueWhitespace(allocator, rendered_value);
                    defer if (!(normalized.ptr == rendered_value.ptr and normalized.len == rendered_value.len)) allocator.free(normalized);
                    try emit.writeAll(normalized);
                    return;
                };

                if (std.mem.trim(u8, rendered_value[first_nl..], " \t\n\r").len == 0) {
                    // Custom property value with trailing newline(s): official Sass CLI
                    // collapses trailing whitespace+newline to a single space,
                    // regardless of how many trailing spaces precede the newline.
                    const before = rendered_value[0..first_nl];
                    const trimmed_before = std.mem.trimEnd(u8, before, " \t");
                    try emit.writeAll(trimmed_before);
                    if (before.len > 0) try emit.writeByte(' ');
                    return;
                }

                const is_block_value = blk: {
                    var i: usize = 0;
                    while (i < rendered_value.len and (rendered_value[i] == ' ' or rendered_value[i] == '\t')) : (i += 1) {}
                    break :blk (i < rendered_value.len and rendered_value[i] == '{');
                };

                if (is_block_value) {
                    var last_line: []const u8 = "";
                    var it_last = std.mem.splitScalar(u8, rendered_value[first_nl + 1 ..], '\n');
                    while (it_last.next()) |line| {
                        const t = std.mem.trimEnd(u8, line, " \t\r");
                        if (t.len > 0) last_line = t;
                    }
                    const last_content = std.mem.trim(u8, last_line, " \t\r");
                    if (last_content.len != 1 or last_content[0] != '}') {
                        try emit.writeAll(rendered_value[0 .. first_nl + 1]);
                        try emit.writeAll(rendered_value[first_nl + 1 ..]);
                        return;
                    }

                    const trimmed_linebreaks = std.mem.trimEnd(u8, rendered_value, "\n\r");
                    if (trimmed_linebreaks.len < rendered_value.len) {
                        rendered_value = trimmed_linebreaks;
                        emit_space_after = true;
                    }
                }

                if (!emit_space_after) {
                    const trimmed_with_ws = std.mem.trimEnd(u8, rendered_value, " \t\r\n");
                    if (trimmed_with_ws.len < rendered_value.len) {
                        const removed = rendered_value[trimmed_with_ws.len..];
                        if (std.mem.findAny(u8, removed, "\n\r") != null) {
                            rendered_value = trimmed_with_ws;
                            emit_space_after = true;
                        }
                    }
                }

                const first_nl_rendered = std.mem.findAny(u8, rendered_value, "\n\r") orelse {
                    try emit.writeAll(rendered_value);
                    if (emit_space_after) try emit.writeByte(' ');
                    return;
                };

                try emit.writeAll(rendered_value[0 .. first_nl_rendered + 1]);
                const rest = rendered_value[first_nl_rendered + 1 ..];
                if (rest.len == 0) {
                    if (emit_space_after) try emit.writeByte(' ');
                    return;
                }

                const indent_size = indent_level * 2;
                const source_over_indent = if (effective_source_decl_col) |col|
                    if (col > indent_size) col - indent_size else 0
                else
                    0;

                var min_prefix: usize = std.math.maxInt(usize);
                var it_min = std.mem.splitScalar(u8, rest, '\n');
                while (it_min.next()) |line| {
                    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    var ws: usize = 0;
                    while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
                    if (ws < min_prefix) min_prefix = ws;
                }
                if (min_prefix == std.math.maxInt(usize)) min_prefix = 0;

                if (!is_block_value) {
                    if (effective_source_decl_col) |source_col| {
                        // This branch handles source indentation that's shallower
                        // than the emitted CSS indentation, most notably SCSS
                        // that uses a hard tab for the declaration indentation.
                        // When the source column already matches or exceeds the
                        // emitted indentation, keep the normal min-prefix based
                        // normalization below. That preserves Sass's relative
                        // indentation for below-base custom property values.
                        if (source_col > 0 and source_col < indent_size) {
                            var it = std.mem.splitScalar(u8, rest, '\n');
                            var first = true;
                            while (it.next()) |line| {
                                if (!first) try emit.writeByte('\n');
                                first = false;

                                const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                                if (trimmed.len == 0) continue;

                                var strip: usize = 0;
                                while (strip < trimmed.len and strip < source_col and (trimmed[strip] == ' ' or trimmed[strip] == '\t')) : (strip += 1) {}
                                var s: usize = 0;
                                while (s < indent_size) : (s += 1) try emit.writeByte(' ');
                                try emit.writeAll(trimmed[strip..]);
                            }

                            if (emit_space_after) try emit.writeByte(' ');
                            return;
                        }
                    }
                }

                if (!is_block_value) {
                    if (effective_source_decl_col) |source_col| {
                        if (source_col <= min_prefix) {
                            var it = std.mem.splitScalar(u8, rest, '\n');
                            var first = true;
                            while (it.next()) |line| {
                                if (!first) try emit.writeByte('\n');
                                first = false;

                                const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                                if (trimmed.len == 0) continue;

                                var strip: usize = 0;
                                while (strip < trimmed.len and strip < source_col and (trimmed[strip] == ' ' or trimmed[strip] == '\t')) : (strip += 1) {}
                                var s: usize = 0;
                                while (s < indent_size) : (s += 1) try emit.writeByte(' ');
                                try emit.writeAll(trimmed[strip..]);
                            }

                            if (emit_space_after) try emit.writeByte(' ');
                            return;
                        }
                    }
                }

                if (source_over_indent > 0 and source_over_indent < min_prefix) {
                    var it = std.mem.splitScalar(u8, rest, '\n');
                    var first = true;
                    while (it.next()) |line| {
                        if (!first) try emit.writeByte('\n');
                        first = false;

                        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                        if (trimmed.len == 0) continue;

                        var strip: usize = 0;
                        while (strip < trimmed.len and strip < source_over_indent and (trimmed[strip] == ' ' or trimmed[strip] == '\t')) : (strip += 1) {}
                        try emit.writeAll(trimmed[strip..]);
                    }

                    if (emit_space_after) try emit.writeByte(' ');
                    return;
                }

                if (!is_block_value and min_prefix >= indent_size) {
                    const first_line_trimmed = std.mem.trim(u8, rendered_value[0..first_nl_rendered], " \t\r\n");
                    const strip_prefix = if ((std.ascii.startsWithIgnoreCase(first_line_trimmed, "calc(") and min_prefix > indent_size) or min_prefix > 4)
                        indent_size
                    else
                        0;
                    var it = std.mem.splitScalar(u8, rest, '\n');
                    var first = true;
                    while (it.next()) |line| {
                        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                        if (trimmed.len == 0) continue;
                        if (!first) try emit.writeByte('\n');
                        first = false;
                        var strip: usize = 0;
                        while (strip < trimmed.len and strip < strip_prefix and (trimmed[strip] == ' ' or trimmed[strip] == '\t')) : (strip += 1) {}
                        try emit.writeAll(trimmed[strip..]);
                    }
                    if (emit_space_after) try emit.writeByte(' ');
                    return;
                }

                var it = std.mem.splitScalar(u8, rest, '\n');
                var first = true;
                while (it.next()) |line| {
                    if (!first) try emit.writeByte('\n');
                    first = false;

                    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;

                    const stripped_start = @min(min_prefix, line.len);
                    const stripped = line[stripped_start..];
                    var s: usize = 0;
                    while (s < indent_size) : (s += 1) try emit.writeByte(' ');
                    try emit.writeAll(stripped);
                }

                if (emit_space_after) try emit.writeByte(' ');
            }

            fn stripCustomPropertySourceColMarker(
                allocator: std.mem.Allocator,
                value: []const u8,
            ) !?struct { value: []const u8, owned: []const u8, source_col: usize } {
                var marker_pos: usize = 0;
                while (marker_pos < value.len and (value[marker_pos] == ' ' or value[marker_pos] == '\t')) : (marker_pos += 1) {}
                const marker = opcode_mod.custom_property_source_col_marker;
                if (!std.mem.startsWith(u8, value[marker_pos..], marker)) return null;

                const digits_start = marker_pos + marker.len;
                var digits_end = digits_start;
                while (digits_end < value.len and value[digits_end] >= '0' and value[digits_end] <= '9') : (digits_end += 1) {}
                if (digits_end == digits_start or digits_end >= value.len or value[digits_end] != ';') return null;
                const source_col = try std.fmt.parseUnsigned(usize, value[digits_start..digits_end], 10);

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, value.len - marker.len - (digits_end - digits_start) - 1);
                try out.appendSlice(allocator, value[0..marker_pos]);
                try out.appendSlice(allocator, value[digits_end + 1 ..]);
                const owned = try out.toOwnedSlice(allocator);
                return .{ .value = owned, .owned = owned, .source_col = source_col };
            }

            fn normalizeOneLineCustomPropertyValueWhitespace(
                allocator: std.mem.Allocator,
                value: []const u8,
            ) ![]const u8 {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.ensureTotalCapacity(allocator, value.len);

                var i: usize = 0;
                var changed = false;
                var in_string: u8 = 0;
                var pending_ws: ?u8 = null;
                while (i < value.len) {
                    const c = value[i];
                    if (in_string != 0) {
                        if (pending_ws) |ws| {
                            try out.append(allocator, ws);
                            pending_ws = null;
                        }
                        try out.append(allocator, c);
                        if (c == '\\' and i + 1 < value.len) {
                            i += 1;
                            try out.append(allocator, value[i]);
                        } else if (c == in_string) {
                            in_string = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (c == ' ' or c == '\t') {
                        if (pending_ws != null) changed = true;
                        pending_ws = c;
                        i += 1;
                        continue;
                    }

                    if (pending_ws) |ws| {
                        try out.append(allocator, ws);
                        pending_ws = null;
                    }

                    if (c == '"' or c == '\'') {
                        in_string = c;
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }

                    try out.append(allocator, c);
                    i += 1;
                }
                if (pending_ws) |ws| try out.append(allocator, ws);

                if (!changed and std.mem.eql(u8, out.items, value)) {
                    out.deinit(allocator);
                    return value;
                }
                return out.toOwnedSlice(allocator);
            }

            /// Case where `.sass` indented syntax leaks to declaration property side
            /// Rescue (`a\n b`) with writer and reconfigure it into `a { b: ...; }`.
            fn emitLeakedDeclaration(
                emit: *EmitCtx,
                allocator: std.mem.Allocator,
                prop_raw: []const u8,
                value_raw: []const u8,
                indent_level: usize,
                is_decl_raw: bool,
            ) !bool {
                if (std.mem.findScalar(u8, prop_raw, '\n') == null and
                    std.mem.findScalar(u8, prop_raw, '\r') == null and
                    std.mem.findScalar(u8, prop_raw, '\x0c') == null)
                {
                    return false;
                }

                var normalized: std.ArrayListUnmanaged(u8) = .empty;
                defer normalized.deinit(allocator);
                {
                    var i: usize = 0;
                    while (i < prop_raw.len) : (i += 1) {
                        const c = prop_raw[i];
                        if (c == '\r') {
                            try normalized.append(allocator, '\n');
                            if (i + 1 < prop_raw.len and prop_raw[i + 1] == '\n') i += 1;
                        } else if (c == '\x0c') {
                            try normalized.append(allocator, '\n');
                        } else {
                            try normalized.append(allocator, c);
                        }
                    }
                }

                var lines: std.ArrayListUnmanaged([]const u8) = .empty;
                defer lines.deinit(allocator);
                {
                    var ls: usize = 0;
                    while (ls <= normalized.items.len) {
                        const le = std.mem.findScalarPos(u8, normalized.items, ls, '\n') orelse normalized.items.len;
                        const line = std.mem.trimEnd(u8, normalized.items[ls..le], " \t\r");
                        if (line.len != 0) try lines.append(allocator, line);
                        if (le == normalized.items.len) break;
                        ls = le + 1;
                    }
                }
                if (lines.items.len < 2) return false;

                var leak_depth: usize = 0;
                for (lines.items[0 .. lines.items.len - 1]) |header_line| {
                    const header = std.mem.trimStart(u8, header_line, " \t");
                    if (header.len == 0) continue;
                    try writeIndent(emit, indent_level + leak_depth);
                    try emit.writeAll(header);
                    try emit.writeAll(" {\n");
                    leak_depth += 1;
                }

                const prop_line = std.mem.trimStart(u8, lines.items[lines.items.len - 1], " \t");
                if (prop_line.len == 0) return false;

                try writeIndent(emit, indent_level + leak_depth);
                try emit.writeAll(prop_line);

                const is_custom_property = std.mem.startsWith(u8, prop_line, "--");
                if (is_decl_raw and is_custom_property) {
                    try emit.writeByte(':');
                    try writeCustomPropertyValue(emit, allocator, value_raw, indent_level + leak_depth, null);
                } else {
                    try emit.writeAll(": ");
                    try emit.writeAll(value_raw);
                }
                try emit.writeAll(";\n");

                while (leak_depth > 0) {
                    leak_depth -= 1;
                    try writeIndent(emit, indent_level + leak_depth);
                    try emit.writeAll("}\n");
                }

                return true;
            }

            fn isLikelyDeclarationLine(content: []const u8) bool {
                if (content.len == 0) return false;
                if (content[0] == '@') return false;
                if (std.mem.startsWith(u8, content, "--")) return true;
                const colon = std.mem.findScalar(u8, content, ':') orelse return false;
                if (colon + 1 >= content.len) return true;
                const next = content[colon + 1];
                return next == ' ' or next == '\t' or next == '\n' or next == '\r' or next == '\x0c';
            }

            /// `@supports ...` Restore the case where indented body was leaked in prelude on the writer side.
            /// Example: prelude=`(a\n b)\n c\n d: e`
            /// Reconfigured to `@supports (a\n b) { c { d: e; } }`.
            fn emitLeakedAtRuleSimple(
                emit: *EmitCtx,
                allocator: std.mem.Allocator,
                name: []const u8,
                prelude_raw: []const u8,
                indent_level: usize,
            ) !bool {
                if (std.mem.findScalar(u8, prelude_raw, '\n') == null and
                    std.mem.findScalar(u8, prelude_raw, '\r') == null and
                    std.mem.findScalar(u8, prelude_raw, '\x0c') == null)
                {
                    return false;
                }

                var normalized: std.ArrayListUnmanaged(u8) = .empty;
                defer normalized.deinit(allocator);
                {
                    var i: usize = 0;
                    while (i < prelude_raw.len) : (i += 1) {
                        const c = prelude_raw[i];
                        if (c == '\r') {
                            try normalized.append(allocator, '\n');
                            if (i + 1 < prelude_raw.len and prelude_raw[i + 1] == '\n') i += 1;
                        } else if (c == '\x0c') {
                            try normalized.append(allocator, '\n');
                        } else {
                            try normalized.append(allocator, c);
                        }
                    }
                }

                var lines: std.ArrayListUnmanaged([]const u8) = .empty;
                defer lines.deinit(allocator);
                {
                    var ls: usize = 0;
                    while (ls <= normalized.items.len) {
                        const le = std.mem.findScalarPos(u8, normalized.items, ls, '\n') orelse normalized.items.len;
                        const line = std.mem.trimEnd(u8, normalized.items[ls..le], " \t\r");
                        if (line.len != 0) try lines.append(allocator, line);
                        if (le == normalized.items.len) break;
                        ls = le + 1;
                    }
                }
                if (lines.items.len < 2) return false;

                const base_indent = leadingWhitespaceCount(lines.items[0]);
                var depth: i32 = 0;
                var body_start: ?usize = null;
                var li: usize = 0;
                while (li < lines.items.len) : (li += 1) {
                    const line = lines.items[li];
                    for (line) |ch| {
                        if (ch == '(') {
                            depth += 1;
                        } else if (ch == ')') {
                            if (depth > 0) depth -= 1;
                        }
                    }
                    if (depth != 0) continue;
                    if (li + 1 >= lines.items.len) break;
                    const next = lines.items[li + 1];
                    const next_indent = leadingWhitespaceCount(next);
                    if (next_indent <= base_indent) continue;
                    const next_trim = std.mem.trimStart(u8, next, " \t");
                    if (std.mem.startsWith(u8, next_trim, "and ") or
                        std.mem.startsWith(u8, next_trim, "or ") or
                        std.mem.startsWith(u8, next_trim, "not "))
                    {
                        continue;
                    }
                    body_start = li + 1;
                    break;
                }
                if (body_start == null) return false;

                const split_idx = body_start.?;
                if (split_idx >= lines.items.len) return false;

                var prelude_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer prelude_buf.deinit(allocator);
                var prelude_total: usize = if (split_idx > 0) split_idx - 1 else 0;
                for (lines.items[0..split_idx]) |line| prelude_total += line.len;
                try prelude_buf.ensureTotalCapacity(allocator, prelude_total);
                for (lines.items[0..split_idx], 0..) |line, idx| {
                    if (idx != 0) prelude_buf.appendAssumeCapacity('\n');
                    prelude_buf.appendSliceAssumeCapacity(line);
                }
                var prelude_text: []const u8 = prelude_buf.items;
                var prelude_owned: ?[]const u8 = null;
                defer if (prelude_owned) |owned| allocator.free(owned);
                if (isSupportsAtRuleName(name)) {
                    if (supportsLineBreakIsInvalid(lines.items[0..split_idx], base_indent)) return error.SassError;
                    const normalized_prelude_text = try normalizeSupportsPrelude(allocator, prelude_text);
                    if (!(normalized_prelude_text.ptr == prelude_text.ptr and normalized_prelude_text.len == prelude_text.len)) {
                        prelude_text = normalized_prelude_text;
                        prelude_owned = normalized_prelude_text;
                    }
                    const adjusted_custom_prop = try ensureSupportsCustomPropertyWhitespace(allocator, prelude_text);
                    if (!(adjusted_custom_prop.ptr == prelude_text.ptr and adjusted_custom_prop.len == prelude_text.len)) {
                        prelude_text = adjusted_custom_prop;
                        prelude_owned = adjusted_custom_prop;
                    }
                    ir_validate.validateSupportsPrelude(prelude_text) catch return error.SassError;
                }

                try writeIndent(emit, indent_level);
                try emit.writeAll("@");
                try emit.writeAll(name);
                try emit.writeAll(" ");
                try emit.writeAll(prelude_text);
                try emit.writeAll(" {\n");

                var block_stack: std.ArrayListUnmanaged(usize) = .empty;
                defer block_stack.deinit(allocator);

                var body_idx: usize = split_idx;
                while (body_idx < lines.items.len) : (body_idx += 1) {
                    const line = lines.items[body_idx];
                    const curr_indent = leadingWhitespaceCount(line);
                    const content = std.mem.trimStart(u8, line, " \t");
                    if (content.len == 0) continue;

                    while (block_stack.items.len > 0 and curr_indent <= block_stack.items[block_stack.items.len - 1]) {
                        _ = block_stack.pop();
                        try writeIndent(emit, indent_level + 1 + block_stack.items.len);
                        try emit.writeAll("}\n");
                    }

                    if (isLikelyDeclarationLine(content)) {
                        try writeIndent(emit, indent_level + 1 + block_stack.items.len);
                        try emit.writeAll(content);
                        if (content[content.len - 1] != ';') try emit.writeByte(';');
                        try emit.writeByte('\n');
                        continue;
                    }

                    try writeIndent(emit, indent_level + 1 + block_stack.items.len);
                    if (content[0] == '@') {
                        const has_semicolon = content[content.len - 1] == ';';
                        var next_indent: ?usize = null;
                        var probe = body_idx + 1;
                        while (probe < lines.items.len) : (probe += 1) {
                            const probe_line = lines.items[probe];
                            const probe_content = std.mem.trimStart(u8, probe_line, " \t");
                            if (probe_content.len == 0) continue;
                            next_indent = leadingWhitespaceCount(probe_line);
                            break;
                        }
                        const opens_block = if (std.mem.findScalar(u8, content, '{') != null)
                            true
                        else if (next_indent) |ni|
                            ni > curr_indent
                        else
                            false;
                        if (!opens_block) {
                            try emit.writeAll(content);
                            if (!has_semicolon) try emit.writeByte(';');
                            try emit.writeByte('\n');
                            continue;
                        }
                    }
                    try emit.writeAll(content);
                    try emit.writeAll(" {\n");
                    try block_stack.append(allocator, curr_indent);
                }

                while (block_stack.items.len > 0) {
                    _ = block_stack.pop();
                    try writeIndent(emit, indent_level + 1 + block_stack.items.len);
                    try emit.writeAll("}\n");
                }

                try writeIndent(emit, indent_level);
                try emit.writeAll("}\n");
                return true;
            }
        };

        const SelectorVec = std.ArrayListUnmanaged([]const u8);

        const module_store_count = self.computeExtendModuleStoreCount();
        // Use in both populateExtendStateFromEdges / pseudo-target fallback
        //module  ->  rule_begin node index bucket.
        const rule_nodes_by_module = try temp.alloc(std.ArrayListUnmanaged(u32), module_store_count);
        for (rule_nodes_by_module) |*list| list.* = .empty;
        defer for (rule_nodes_by_module) |*list| list.deinit(temp);
        for (self.nodes.items, 0..) |node, node_idx| {
            if (node.kind != .rule_begin) continue;
            const node_module: u32 = if (node_idx < self.node_source_files.items.len) self.node_source_files.items[node_idx] else 0;
            if (node_module >= module_store_count) continue;
            try rule_nodes_by_module[@intCast(node_module)].append(temp, @intCast(node_idx));
        }

        var extend_state = try extend_mod.RuleModuleExtendState.init(temp, module_store_count);
        defer extend_state.deinit();

        const edge_eligible = try temp.alloc(bool, self.extend_edges.items.len);
        @memset(edge_eligible, false);
        const edge_required_unmatched = try temp.alloc(bool, self.extend_edges.items.len);
        @memset(edge_required_unmatched, false);
        const edge_duplicate_satisfied = try temp.alloc(bool, self.extend_edges.items.len);
        @memset(edge_duplicate_satisfied, false);

        try self.populateExtendStateFromEdges(
            intern_pool,
            temp,
            &extend_state,
            module_store_count,
            rule_nodes_by_module,
            edge_eligible,
            edge_required_unmatched,
            edge_duplicate_satisfied,
        );

        const selector_override = try temp.alloc(?[]const u8, n);
        const selector_visible = try temp.alloc(bool, n);
        for (selector_override) |*p| p.* = null;
        const rule_in_media = try temp.alloc(bool, n);
        const rule_in_keyframes = try temp.alloc(bool, n);
        var at_rule_media_stack: std.ArrayListUnmanaged(bool) = .empty;
        defer at_rule_media_stack.deinit(temp);
        var at_rule_keyframes_stack: std.ArrayListUnmanaged(bool) = .empty;
        defer at_rule_keyframes_stack.deinit(temp);
        try at_rule_media_stack.ensureTotalCapacity(temp, self.nodes.items.len);
        try at_rule_keyframes_stack.ensureTotalCapacity(temp, self.nodes.items.len);
        var media_depth: usize = 0;
        var keyframes_depth: usize = 0;
        for (self.nodes.items, 0..) |node, node_idx| {
            switch (node.kind) {
                .at_rule_begin => {
                    empty_at_rule_end[node_idx] = std.math.maxInt(u32);
                    const name_id = self.extra.items[node.payload];
                    const name_str = intern_pool.get(@enumFromInt(name_id));
                    const is_media = isMediaAtRuleName(name_str);
                    const is_keyframes = isKeyframesAtRuleName(name_str);
                    at_rule_media_stack.appendAssumeCapacity(is_media);
                    at_rule_keyframes_stack.appendAssumeCapacity(is_keyframes);
                    if (is_media) media_depth += 1;
                    if (is_keyframes) keyframes_depth += 1;
                },
                .at_rule_end => {
                    if (at_rule_media_stack.items.len != 0) {
                        const was_media = at_rule_media_stack.pop().?;
                        if (was_media and media_depth > 0) media_depth -= 1;
                    }
                    if (at_rule_keyframes_stack.items.len != 0) {
                        const was_keyframes = at_rule_keyframes_stack.pop().?;
                        if (was_keyframes and keyframes_depth > 0) keyframes_depth -= 1;
                    }
                },
                .rule_begin => {
                    rule_in_media[node_idx] = media_depth != 0;
                    rule_in_keyframes[node_idx] = keyframes_depth != 0;
                },
                else => {},
            }
        }

        for (self.nodes.items, 0..) |node, i| {
            if (node.kind != .rule_begin) continue;
            selector_visible[i] = false;

            const sel_id = self.extra.items[node.payload];
            const selector_raw = intern_pool.get(@enumFromInt(sel_id));
            var selector_text = selector_raw;
            var selector_owned: ?[]const u8 = null;
            defer if (selector_owned) |owned| temp.free(owned);
            const attr_normalized = css_utils.normalizeAttributeSelectors(temp, selector_raw) catch return error.SassError;
            if (!(attr_normalized.ptr == selector_raw.ptr and attr_normalized.len == selector_raw.len)) {
                selector_text = attr_normalized;
                selector_owned = attr_normalized;
            }
            const comments_stripped = try WriterHelpers.stripSelectorComments(temp, selector_text);
            if (!(comments_stripped.ptr == selector_text.ptr and comments_stripped.len == selector_text.len)) {
                if (selector_owned) |owned| temp.free(owned);
                selector_text = comments_stripped;
                selector_owned = comments_stripped;
            }
            const source_file_id: u32 = if (i < self.node_source_files.items.len) self.node_source_files.items[i] else 0;
            const rule_module_idx: usize = if (source_file_id < module_store_count)
                @intCast(source_file_id)
            else
                0;
            const matched = extend_state.moduleMatched(rule_module_idx);
            const extension_count = extend_state.moduleExtensionCount(rule_module_idx);
            const has_extensions = extend_state.moduleHasExtensions(rule_module_idx);

            var merged: SelectorVec = .empty;
            defer merged.deinit(temp);
            const selector_has_multiline_sep = std.mem.findScalar(u8, selector_text, '\n') != null or
                std.mem.findScalar(u8, selector_text, '\r') != null;
            if (rule_in_keyframes[i] and selector_has_multiline_sep) {
                var multiline_parts: SelectorVec = .empty;
                defer multiline_parts.deinit(temp);
                try splitSelectorList(temp, selector_text, &multiline_parts);
                if (multiline_parts.items.len > 1) {
                    // percentage/from/to selector list in @keyframes is independent of extension state
                    // Compress to a single line (`0%, 100%`) like official Sass CLI.
                    selector_visible[i] = true;
                    selector_override[i] = try joinSelectorListWithSeparator(
                        temp,
                        multiline_parts.items,
                        ", ",
                    );
                    continue;
                }
            }
            if (!has_extensions and selector_has_multiline_sep and !selectorContainsPlaceholder(selector_text)) {
                var multiline_parts: SelectorVec = .empty;
                defer multiline_parts.deinit(temp);
                try splitSelectorList(temp, selector_text, &multiline_parts);
                if (multiline_parts.items.len > 1) {
                    selector_visible[i] = true;
                    if (rule_in_keyframes[i]) {
                        // percentage/from/to selector lists in @keyframes are
                        // serialized on a single line (`0%, 20%`), even when
                        // source selectors are line-break delimited.
                        selector_override[i] = try joinSelectorListWithSeparator(
                            temp,
                            multiline_parts.items,
                            ", ",
                        );
                    } else {
                        selector_override[i] = try joinSelectorListPreservingOriginalSeparators(
                            temp,
                            selector_text,
                            multiline_parts.items,
                        );
                    }
                    continue;
                }
            }
            const force_preserve_raw_selector = std.mem.find(u8, selector_text, "\\ ") != null;
            if ((!has_extensions or force_preserve_raw_selector) and shouldPreserveRawSelectorWithoutExtend(selector_text)) {
                // Only in cases where there is no @extend + you want to keep the casing/quote of attribute selector
                // selector_mod.toCss() Avoid normalization and prefer the original selector string.
                if (selector_mod.hasInvalidIdentifierStart(selector_text)) {
                    return error.SassError;
                }
                try splitSelectorList(temp, selector_text, &merged);
                if (merged.items.len == 0) continue;
                const preserve_duplicates = selectorListHasExactDuplicateBranches(selector_text);

                var visible: SelectorVec = .empty;
                defer visible.deinit(temp);
                try visible.ensureTotalCapacity(temp, merged.items.len);
                for (merged.items) |cand| {
                    const cleaned = (try cleanedSelectorWithoutPlaceholders(temp, cand)) orelse continue;
                    if (selector_helpers_mod.hasBogusCombinatorsSimple(cleaned)) continue;
                    if (preserve_duplicates) {
                        try visible.append(temp, cleaned);
                    } else {
                        _ = try appendUniqueSelector(temp, &visible, cleaned);
                    }
                }
                if (visible.items.len == 0) continue;

                selector_visible[i] = true;
                selector_override[i] = try joinSelectorListPreservingOriginalSeparators(
                    temp,
                    selector_text,
                    visible.items,
                );
                continue;
            }

            var selector_list = selector_mod.parse(temp, selector_text) catch {
                // Keep unresolved interpolation fallback, but propagate clearly
                // invalid identifier starts (`#2`, `.3`, `1a`) as SassError.
                if (selector_mod.hasInvalidIdentifierStart(selector_text)) {
                    return error.SassError;
                }
                try splitSelectorList(temp, selector_text, &merged);
                if (merged.items.len == 0) continue;
                const preserve_duplicates = selectorListHasExactDuplicateBranches(selector_text);
                var visible: SelectorVec = .empty;
                defer visible.deinit(temp);
                try visible.ensureTotalCapacity(temp, merged.items.len);
                for (merged.items) |cand| {
                    const cleaned = (try cleanedSelectorWithoutPlaceholders(temp, cand)) orelse continue;
                    if (selector_helpers_mod.hasBogusCombinatorsSimple(cleaned)) continue;
                    if (preserve_duplicates) {
                        try visible.append(temp, cleaned);
                    } else {
                        _ = try appendUniqueSelector(temp, &visible, cleaned);
                    }
                }
                if (visible.items.len == 0) continue;
                selector_visible[i] = true;
                selector_override[i] = try joinSelectorListPreservingOriginalSeparators(
                    temp,
                    selector_text,
                    visible.items,
                );
                continue;
            };
            defer selector_list.deinit();

            var local_matches_opt: ?[]bool = null;
            if (has_extensions and matched.len == extension_count) {
                const local_matches = try temp.alloc(bool, extension_count);
                @memset(local_matches, false);
                try extend_state.markModuleMatchesNonPropagated(rule_module_idx, &selector_list, local_matches);
                local_matches_opt = local_matches;

                // @extend declared inside @media is
                // Cannot be applied to root style rule.
                if (!rule_in_media[i]) {
                    const edge_indices = extend_state.moduleEdgeIndices(rule_module_idx);
                    const check_len = @min(local_matches.len, edge_indices.len);
                    var local_idx: usize = 0;
                    while (local_idx < check_len) : (local_idx += 1) {
                        if (!local_matches[local_idx]) continue;
                        const edge_idx: usize = @intCast(edge_indices[local_idx]);
                        if (edge_idx >= self.extend_edges.items.len) continue;
                        const edge = self.extend_edges.items[edge_idx];
                        if (self.extendRelationInMedia(edge.source_module, edge.relation_id)) return error.SassError;
                    }
                }
                for (local_matches, 0..) |is_match, match_idx| {
                    if (is_match) matched[match_idx] = true;
                }
            }

            if (local_matches_opt) |local_matches| {
                var any_local_match = false;
                for (local_matches) |is_match| {
                    if (is_match) {
                        any_local_match = true;
                        break;
                    }
                }
                if (!any_local_match and shouldPreserveRawSelectorWithoutExtend(selector_text)) {
                    try splitSelectorList(temp, selector_text, &merged);
                    if (merged.items.len == 0) continue;
                    const preserve_duplicates = selectorListHasExactDuplicateBranches(selector_text);
                    var visible: SelectorVec = .empty;
                    defer visible.deinit(temp);
                    try visible.ensureTotalCapacity(temp, merged.items.len);
                    for (merged.items) |cand| {
                        const cleaned = (try cleanedSelectorWithoutPlaceholders(temp, cand)) orelse continue;
                        if (selector_helpers_mod.hasBogusCombinatorsSimple(cleaned)) continue;
                        if (preserve_duplicates) {
                            try visible.append(temp, cleaned);
                        } else {
                            _ = try appendUniqueSelector(temp, &visible, cleaned);
                        }
                    }
                    if (visible.items.len == 0) continue;
                    selector_visible[i] = true;
                    selector_override[i] = try joinSelectorListPreservingOriginalSeparators(
                        temp,
                        selector_text,
                        visible.items,
                    );
                    continue;
                }
                if (!any_local_match and
                    !selector_mod.hasParentReference(&selector_list) and
                    !selectorContainsPlaceholder(selector_text) and
                    (!extend_state.moduleHasPropagatedExtensions(rule_module_idx) or
                        !try extend_state.selectorHasAnyExtensionTarget(rule_module_idx, &selector_list)))
                {
                    selector_visible[i] = true;
                    selector_override[i] = try selector_mod.toCss(temp, &selector_list);
                    continue;
                }
            }

            if (selector_mod.hasParentReference(&selector_list)) {
                try splitSelectorList(temp, selector_raw, &merged);
            } else {
                const rule_extend_snapshot = self.getRuleExtendSnapshotAt(i);
                var applied = try extend_mod.applyExtendEdgesToSelectorWithContext(
                    &extend_state,
                    rule_module_idx,
                    &selector_list,
                    .{
                        .target_extend_order_snapshot = rule_extend_snapshot,
                        .target_is_direct_rule = false,
                    },
                );
                defer applied.deinit();
                var preserve_direct_selector_pseudo_variants = true;
                if (has_extensions and matched.len == extension_count) {
                    const local_matches = local_matches_opt.?;
                    const edge_indices = extend_state.moduleEdgeIndices(rule_module_idx);
                    if (edge_indices.len == local_matches.len) {
                        for (local_matches, 0..) |is_local_match, ext_idx| {
                            if (!is_local_match) continue;
                            const edge_idx: usize = @intCast(edge_indices[ext_idx]);
                            if (edge_idx >= self.extend_edges.items.len) continue;
                            const edge_source_module = self.extend_edges.items[edge_idx].source_module;
                            if (edge_source_module != source_file_id) {
                                preserve_direct_selector_pseudo_variants = false;
                                break;
                            }
                        }
                    }
                }
                try extend_mod.restoreDirectSelectorPseudoVariants(
                    temp,
                    extend_state.moduleExtensions(rule_module_idx),
                    &selector_list,
                    &applied,
                    preserve_direct_selector_pseudo_variants,
                );
                if (rule_in_media[i]) {
                    try extend_mod.preferBroaderOriginalsOverExtraNotPseudos(&applied, &selector_list);
                }
                extend_mod.removeBranchesCoveredByPureNotBranch(&applied);
                const merged_css = try selector_mod.toCss(temp, &applied);
                // Prefer merged_css as the separator template: toCss() emits
                // `,\n` based on ComplexSelector.leading_separator_has_newline,
                // which we propagate from the original list during the extend
                // trim pass. Falling back to the user's selector_text when
                // merged_css has no newlines keeps single-line formatting for
                // rules that had no multi-line structure to begin with.
                const separator_template = if (std.mem.findAny(u8, merged_css, "\n\r") != null)
                    merged_css
                else if (std.mem.findAny(u8, selector_text, "\n\r") != null)
                    selector_text
                else
                    selector_text;
                try splitSelectorList(temp, merged_css, &merged);
                selector_owned = if (separator_template.ptr == merged_css.ptr and separator_template.len == merged_css.len)
                    merged_css
                else
                    selector_owned;
                selector_text = separator_template;
            }
            if (merged.items.len == 0) continue;

            var visible: SelectorVec = .empty;
            defer visible.deinit(temp);
            try visible.ensureTotalCapacity(temp, merged.items.len);
            const preserve_duplicates = selectorListHasExactDuplicateBranches(selector_text);
            for (merged.items) |cand| {
                const cleaned = (try cleanedSelectorWithoutPlaceholders(temp, cand)) orelse continue;
                if (selector_helpers_mod.hasBogusCombinatorsSimple(cleaned)) continue;
                if (preserve_duplicates) {
                    try visible.append(temp, cleaned);
                } else {
                    _ = try appendUniqueSelector(temp, &visible, cleaned);
                }
            }
            if (visible.items.len == 0) continue;

            selector_visible[i] = true;
            selector_override[i] = try joinSelectorListPreservingOriginalSeparators(
                temp,
                selector_text,
                visible.items,
            );
        }

        for (selector_override) |*override| {
            if (override.*) |sel| {
                override.* = try normalizeNumericAttributeQuotes(temp, sel);
            }
        }

        const edge_matched = try temp.alloc(bool, self.extend_edges.items.len);
        @memset(edge_matched, false);
        for (0..module_store_count) |i| {
            const matched = extend_state.moduleMatched(i);
            const edge_indices = extend_state.moduleEdgeIndices(i);
            if (matched.len != edge_indices.len) continue;
            for (matched, 0..) |is_matched, idx| {
                if (!is_matched) continue;
                const edge_idx: usize = @intCast(edge_indices[idx]);
                if (edge_idx < edge_matched.len) edge_matched[edge_idx] = true;
            }
        }

        for (self.extend_edges.items, 0..) |edge, edge_idx| {
            if (edge_idx >= edge_matched.len or edge_matched[edge_idx]) continue;
            const target_raw = intern_pool.get(edge.target_selector);
            if (target_raw.len == 0) continue;
            const target_module = edge.target_module;
            if (target_module >= module_store_count) {
                for (self.nodes.items, 0..) |node, node_idx| {
                    if (node.kind != .rule_begin) continue;
                    const node_module: u32 = if (node_idx < self.node_source_files.items.len) self.node_source_files.items[node_idx] else 0;
                    if (node_module != target_module) continue;
                    const sel_id = self.extra.items[node.payload];
                    const selector_raw = intern_pool.get(@enumFromInt(sel_id));
                    if (selectorRawContainsPseudoTarget(selector_raw, target_raw)) {
                        edge_matched[edge_idx] = true;
                        break;
                    }
                }
                continue;
            }
            const rule_nodes = rule_nodes_by_module[@intCast(target_module)];
            for (rule_nodes.items) |node_idx_u32| {
                const node_idx: usize = @intCast(node_idx_u32);
                const node = self.nodes.items[node_idx];
                const sel_id = self.extra.items[node.payload];
                const selector_raw = intern_pool.get(@enumFromInt(sel_id));
                if (selectorRawContainsPseudoTarget(selector_raw, target_raw)) {
                    edge_matched[edge_idx] = true;
                    break;
                }
            }
        }

        // Transitive matching within the same target-module bucket:
        // if a matched extension's extender contains another target selector,
        // consider that target matched even when no raw rule emits it directly.
        // This mirrors chained @extend behavior for pseudo-selector carriers
        // like :is(.a) {@extend .b} followed by .c {@extend .a}.
        var transitive_changed = true;
        while (transitive_changed) {
            transitive_changed = false;
            for (self.extend_edges.items, 0..) |edge, edge_idx| {
                if (edge_idx >= edge_matched.len or edge_matched[edge_idx] or edge_duplicate_satisfied[edge_idx]) continue;
                if (!edge_eligible[edge_idx]) continue;
                const target_raw = intern_pool.get(edge.target_selector);
                if (target_raw.len == 0) continue;

                var target_list = selector_mod.parse(temp, target_raw) catch continue;
                defer target_list.deinit();
                if (target_list.selectors.items.len == 0) continue;
                const target_compound = singleExtendTargetCompound(&target_list.selectors.items[0]) orelse continue;

                for (self.extend_edges.items, 0..) |carrier, carrier_idx| {
                    if (carrier_idx >= edge_matched.len or
                        (!edge_matched[carrier_idx] and !edge_duplicate_satisfied[carrier_idx])) continue;
                    if (!edge_eligible[carrier_idx]) continue;
                    if (carrier.target_module != edge.target_module) continue;
                    if (carrier.source_module != edge.source_module and
                        !self.sourceModuleCanSee(edge.source_module, carrier.source_module))
                    {
                        continue;
                    }
                    const extender_raw = intern_pool.get(carrier.extending_selector);
                    if (extender_raw.len == 0) continue;
                    if (!selectorRawContainsTargetCompound(temp, extender_raw, &target_compound)) continue;
                    edge_matched[edge_idx] = true;
                    transitive_changed = true;
                    break;
                }
            }
        }

        try self.validateRequiredExtendMatches(
            intern_pool,
            temp,
            edge_eligible,
            edge_required_unmatched,
            edge_duplicate_satisfied,
            edge_matched,
        );

        const saw_charset = try self.computeSkipFlagsAndCharset(
            intern_pool,
            temp,
            selector_visible,
            selector_override,
            skip,
            empty_at_rule_end,
            output_style,
        );

        const merge_same_rule_begin = try temp.alloc(bool, n);
        @memset(merge_same_rule_begin, false);
        const separator_prefix = try temp.alloc(usize, n + 1);
        separator_prefix[0] = 0;
        for (self.nodes.items, 0..) |separator_node, separator_idx| {
            separator_prefix[separator_idx + 1] = separator_prefix[separator_idx] +
                @as(usize, @intFromBool(!skip[separator_idx] and isRuleIRGroupSeparatorKind(separator_node.kind)));
        }
        const rule_selector_text = try temp.alloc([]const u8, n);
        const rule_selector_trimmed = try temp.alloc([]const u8, n);
        for (self.nodes.items, 0..) |selector_node, selector_idx| {
            if (selector_node.kind == .rule_begin) {
                const selector_text = getNodeSelectorText(self, selector_idx, selector_override, intern_pool);
                rule_selector_text[selector_idx] = selector_text;
                rule_selector_trimmed[selector_idx] = std.mem.trim(u8, selector_text, " \t\r\n");
            } else {
                rule_selector_text[selector_idx] = "";
                rule_selector_trimmed[selector_idx] = "";
            }
        }
        try self.computeAdjacentRuleMerges(
            temp,
            skip,
            merge_same_rule_begin,
            separator_prefix,
            rule_selector_text,
            rule_selector_trimmed,
        );

        const EmitLoopState = struct {
            has_output: bool = false,
            pending_blank: bool = false,
            pending_leading_blank: bool = false,
            pending_trailing_sourcemap_blank: bool = false,
            indent_level: usize = 0,
            // True if the direct visible node is comment. Same as legacy official Sass CLI
            // Do not insert a blank line before the rule/at-rule that immediately follows the comment.
            prev_visible_is_comment: bool = false,
            // true when direct previous visible node is top-level `@import` at_rule_simple;
            // official Sass CLI suppresses blank lines before and after top-level `@import` (in both directions).
            prev_visible_is_top_import: bool = false,
            // before direct visible node is at-rule block (@media / @supports / @keyframes etc.
            // True when at-rule (closed with `}`). official Sass CLI if prev is at-rule block,
            // next rule / at-rule suppress previous blank with or without blank on source
            // (equivalent to legacy codegen `skip_consecutive_top_rules`).
            prev_visible_is_at_rule_block: bool = false,
            // direct before visible node is @at-root hoisted block rule_end / at_rule_end
            // true if this is @at-root from the parent rule.
            // Immediately after the escaped block, return to the scope of the parent rule and emit the next non-hoisted
            // Insert a blank line between rule / at-rule after hoisted at-root inside @media.
            // To force blank regardless of nest_depth or suppress_leading_blank,
            // Add to the need_blank judgment on the rule_begin / at_rule_begin side.
            prev_visible_is_at_root_hoist: bool = false,
        };

        const EmitLoopHelpers = struct {
            fn writeCurrentIndent(emit_ctx: *EmitCtx, indent_level: usize) !void {
                var j: usize = 0;
                while (j < indent_level) : (j += 1) {
                    try emit_ctx.writeAll("  ");
                }
            }

            fn consumeStandardPendingBlank(
                emit_ctx: *EmitCtx,
                state: *EmitLoopState,
            ) !void {
                // Before comment/decl. official Sass CLI immediately after `@charset`/`@import` or
                // Do not insert a blank line immediately after comment or at-rule block (@media etc.).
                const suppress = state.prev_visible_is_comment or state.prev_visible_is_top_import or state.prev_visible_is_at_rule_block;
                const need_blank = if (state.has_output)
                    (state.pending_blank and !suppress)
                else
                    (state.pending_leading_blank and state.indent_level == 0 and !suppress);
                if (need_blank) {
                    try emit_ctx.writeAll("\n");
                }
                state.pending_blank = false;
                state.pending_leading_blank = false;
                state.pending_trailing_sourcemap_blank = false;
                // This helper is only called before visible emit other than comment.
                state.prev_visible_is_comment = false;
                state.prev_visible_is_top_import = false;
                state.prev_visible_is_at_rule_block = false;
                // If a comment is emitted immediately after @at-root hoist,
                // the comment itself owns the following boundary and suppresses
                // the blank before the next rule.
                state.prev_visible_is_at_root_hoist = false;
            }

            fn emitBlockEndNode(
                self_ir: *const RuleIR,
                emit_ctx: *EmitCtx,
                intern_pool_: *const InternPool,
                skip_flags: []bool,
                temp_alloc: std.mem.Allocator,
                source_locations_: ?[]const SourceLocation,
                idx: usize,
                node: Node,
                source_file_id: u32,
                state: *EmitLoopState,
            ) !void {
                try emit_ctx.markNode(source_file_id, node);
                if (state.indent_level > 0) state.indent_level -= 1;
                try writeCurrentIndent(emit_ctx, state.indent_level);
                try emit_ctx.writeAll("}");
                var had_inline_comment = false;
                if (try inlineCommentAfter(self_ir, intern_pool_, skip_flags, temp_alloc, source_locations_, idx, false)) |inline_comment| {
                    try emit_ctx.writeByte(' ');
                    try emit_ctx.writeAll(inline_comment.text);
                    skip_flags[inline_comment.idx] = true;
                    had_inline_comment = true;
                }
                try emit_ctx.writeByte('\n');
                state.has_output = true;
                // If you issue an inline comment immediately after the closing brace, the blank before the next visible
                // Suppress as immediately after comment (treated as "trailing comment" like legacy official Sass CLI).
                state.prev_visible_is_comment = had_inline_comment;
                state.prev_visible_is_top_import = false;
                // The caller (rule_end / at_rule_end) distinguishes the type and resets it.
                // If an inline comment appears, blank is suppressed on the prev_visible_is_comment side, so
                // at_rule_block flag can be dropped.
                state.prev_visible_is_at_rule_block = false;
            }

            fn emitDeclNode(
                self_ir: *const RuleIR,
                emit_ctx: *EmitCtx,
                intern_pool_: *const InternPool,
                skip_flags: []bool,
                temp_alloc: std.mem.Allocator,
                source_locations_: ?[]const SourceLocation,
                idx: usize,
                node: Node,
                source_file_id: u32,
                state: *EmitLoopState,
                output_style_: OutputStyle,
            ) !void {
                try consumeStandardPendingBlank(emit_ctx, state);
                try emit_ctx.markNode(source_file_id, node);
                const prop_id = self_ir.extra.items[node.payload];
                const val_id = self_ir.extra.items[node.payload + 1];
                const prop_str = intern_pool_.get(@enumFromInt(prop_id));
                const val_str = intern_pool_.get(@enumFromInt(val_id));
                const is_custom_property_early = std.mem.startsWith(u8, prop_str, "--");
                const val_for_leak = if (is_custom_property_early) val_str else stripCalcDeclMarker(val_str);
                if (!is_custom_property_early and declarationValueEmptyAfterLeadingMarkers(val_for_leak)) {
                    return;
                }
                if (try WriterHelpers.emitLeakedDeclaration(emit_ctx, temp_alloc, prop_str, val_for_leak, state.indent_level, false)) {
                    state.has_output = true;
                    return;
                }
                try writeCurrentIndent(emit_ctx, state.indent_level);
                try emit_ctx.writeAll(prop_str);
                try emit_ctx.writeAll(": ");
                var value_text = val_str;
                var value_owned: ?[]const u8 = null;
                defer if (value_owned) |owned| temp_alloc.free(owned);
                const marked_interp_decl = std.mem.startsWith(u8, value_text, interp_decl_marker);
                if (marked_interp_decl) value_text = stripInterpDeclMarker(value_text);
                var marked_literal_decl = false;
                if (!std.mem.startsWith(u8, prop_str, "--")) {
                    marked_literal_decl = containsLiteralDeclMarker(value_text);
                    if (marked_literal_decl) {
                        const unmarked = try stripAllLiteralDeclMarkers(temp_alloc, value_text);
                        if (unmarked.ptr != value_text.ptr) {
                            value_text = unmarked;
                            value_owned = unmarked;
                        } else {
                            value_text = stripLiteralDeclMarker(value_text);
                        }
                    }
                    const marked_calc_interp = containsCalcDeclMarker(value_text) or isMarkedCalcInterpolationDecl(value_text);
                    const calc_unmarked = try stripAllCalcDeclMarkers(temp_alloc, value_text);
                    if (calc_unmarked.ptr != value_text.ptr) {
                        if (value_owned) |owned| temp_alloc.free(owned);
                        value_text = calc_unmarked;
                        value_owned = calc_unmarked;
                    }
                    var preserved_calc_trailing_operator = false;
                    // Source `/* */` stripping happens in the runtime
                    // emit_decl handler through emit_decl_flag_strip_source_comments;
                    // do not strip here.
                    if (!marked_literal_decl) {
                        if (try normalizeCalcTrailingOperatorParens(temp_alloc, value_text)) |normalized_tail_op| {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = normalized_tail_op;
                            value_owned = normalized_tail_op;
                            preserved_calc_trailing_operator = true;
                        }
                    }
                    const normalized_val = if (marked_calc_interp or marked_literal_decl or preserved_calc_trailing_operator)
                        value_text
                    else
                        try WriterHelpers.normalizeDeclarationValue(temp_alloc, value_text);
                    if (!(normalized_val.ptr == value_text.ptr and normalized_val.len == value_text.len)) {
                        if (value_owned) |owned| temp_alloc.free(owned);
                        value_text = normalized_val;
                        value_owned = normalized_val;
                    }
                    if (containsLiteralDeclMarker(value_text)) {
                        const unmarked_after_normalize = try stripAllLiteralDeclMarkers(temp_alloc, value_text);
                        if (unmarked_after_normalize.ptr != value_text.ptr) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = unmarked_after_normalize;
                            value_owned = unmarked_after_normalize;
                        }
                    }
                    if (!marked_literal_decl and !preserved_calc_trailing_operator and css_utils.containsCalcFunction(value_text)) {
                        const nested_calc = hasNestedCalcInDeclValue(value_text);
                        const ie_hack_nested_calc = nested_calc and std.mem.find(u8, value_text, "\\0") != null;
                        const has_calc_preserve_marker = std.mem.indexOf(u8, value_text, calc_interp_preserve_start) != null;
                        const calc_normalized = if (marked_calc_interp or has_calc_preserve_marker or ie_hack_nested_calc)
                            try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(temp_alloc, value_text)
                        else
                            try calc_utils.normalizeCalcInDeclValue(temp_alloc, value_text);
                        if (calc_normalized.ptr != value_text.ptr) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = calc_normalized;
                            value_owned = calc_normalized;
                        }
                    }
                    if (!marked_literal_decl and !css_utils.containsAsciiIgnoreCase(value_text, "progid:")) {
                        const hex_alpha_expanded = try value_format.expandHexAlphaColors(temp_alloc, value_text);
                        if (!std.mem.eql(u8, hex_alpha_expanded, value_text)) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = hex_alpha_expanded;
                            value_owned = hex_alpha_expanded;
                        } else {
                            temp_alloc.free(hex_alpha_expanded);
                        }
                    }
                    // Decimal number in math function body (`calc()` / `min()` / `max()` / `clamp()` etc.)
                    // Compensate leading zero for shorthand only. top-level `.3s` etc. unquoted
                    // String value (derived from interp) is kept as byte (official Sass CLI specification).
                    if (!marked_literal_decl) {
                        if (try value_format.normalizeLeadingZerosInMathFunctionsMaybeAlloc(temp_alloc, value_text)) |zero_filled| {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = zero_filled;
                            value_owned = zero_filled;
                        }
                    }
                    const preserve_unmarked = try stripCalcInterpolationPreserveMarkers(temp_alloc, value_text);
                    if (preserve_unmarked.ptr != value_text.ptr) {
                        if (value_owned) |owned| temp_alloc.free(owned);
                        value_text = preserve_unmarked;
                        value_owned = preserve_unmarked;
                    }
                    if (output_style_ == .expanded) {
                        const escaped_private = try escapeExpandedDeclPrivateUseCodePoints(temp_alloc, value_text);
                        if (escaped_private.ptr != value_text.ptr) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = escaped_private;
                            value_owned = escaped_private;
                        }
                    }
                }
                if (std.mem.startsWith(u8, prop_str, "--")) {
                    const source_decl_col: ?usize = blk: {
                        if (source_locations_) |locs| {
                            if (source_file_id < locs.len) {
                                const src = RuleIR.sourceOffsetToLineCol(locs[source_file_id], node.source_start);
                                const value_col: usize = @intCast(src.col);
                                var leading_value_ws: usize = 0;
                                while (leading_value_ws < val_str.len and
                                    (val_str[leading_value_ws] == ' ' or val_str[leading_value_ws] == '\t'))
                                {
                                    leading_value_ws += 1;
                                }
                                const prefix_cols = prop_str.len + 1 + leading_value_ws;
                                break :blk if (value_col > prefix_cols) value_col - prefix_cols else value_col;
                            }
                        }
                        break :blk null;
                    };
                    try WriterHelpers.writeCustomPropertyValue(emit_ctx, temp_alloc, value_text, state.indent_level, source_decl_col);
                } else {
                    if (marked_interp_decl and emit_ctx.compressed) try emit_ctx.writeAll(interp_decl_marker);
                    if (marked_literal_decl and emit_ctx.compressed) try emit_ctx.writeAll(literal_decl_marker);
                    try emit_ctx.writeAll(value_text);
                }
                try emit_ctx.writeAll(";");
                if (try inlineCommentAfter(self_ir, intern_pool_, skip_flags, temp_alloc, source_locations_, idx, true)) |inline_comment| {
                    try emit_ctx.writeByte(' ');
                    try emit_ctx.writeAll(inline_comment.text);
                    skip_flags[inline_comment.idx] = true;
                } else if (try inlineCommentAfter(self_ir, intern_pool_, skip_flags, temp_alloc, source_locations_, idx, false)) |inline_comment| {
                    const next_after_comment = nextRenderableNodeIndex(self_ir.nodes.items, skip_flags, inline_comment.idx);
                    if (next_after_comment) |after_idx| {
                        switch (self_ir.nodes.items[after_idx].kind) {
                            .rule_end, .at_rule_end => {
                                try emit_ctx.writeByte(' ');
                                try emit_ctx.writeAll(inline_comment.text);
                                skip_flags[inline_comment.idx] = true;
                            },
                            else => {},
                        }
                    }
                }
                try emit_ctx.writeByte('\n');
                state.has_output = true;
            }

            fn emitDeclRawNode(
                self_ir: *const RuleIR,
                emit_ctx: *EmitCtx,
                intern_pool_: *const InternPool,
                skip_flags: []bool,
                temp_alloc: std.mem.Allocator,
                source_locations_: ?[]const SourceLocation,
                idx: usize,
                node: Node,
                source_file_id: u32,
                state: *EmitLoopState,
                output_style_: OutputStyle,
            ) !void {
                try consumeStandardPendingBlank(emit_ctx, state);
                try emit_ctx.markNode(source_file_id, node);
                const prop_id = self_ir.extra.items[node.payload];
                const str_idx = self_ir.extra.items[node.payload + 1];
                const prop_str = intern_pool_.get(@enumFromInt(prop_id));
                const is_custom_property = std.mem.startsWith(u8, prop_str, "--");
                var val_str = self_ir.strings.items[str_idx];
                const marked_interp_decl = std.mem.startsWith(u8, val_str, interp_decl_marker);
                const early_marked_calc_interp = containsCalcDeclMarker(val_str) or isMarkedCalcInterpolationDecl(val_str);
                if (marked_interp_decl) val_str = stripInterpDeclMarker(val_str);
                var marked_literal_decl = false;
                if (!is_custom_property) {
                    marked_literal_decl = containsLiteralDeclMarker(val_str);
                    if (marked_literal_decl) {
                        val_str = try stripAllLiteralDeclMarkers(temp_alloc, val_str);
                    }
                    val_str = try stripAllCalcDeclMarkers(temp_alloc, val_str);
                }
                if (!is_custom_property and declarationValueEmptyAfterLeadingMarkers(val_str)) {
                    return;
                }
                if (try WriterHelpers.emitLeakedDeclaration(emit_ctx, temp_alloc, prop_str, val_str, state.indent_level, true)) {
                    state.has_output = true;
                    return;
                }
                try writeCurrentIndent(emit_ctx, state.indent_level);
                try emit_ctx.writeAll(prop_str);
                if (is_custom_property) {
                    const source_decl_col: ?usize = blk: {
                        if (source_locations_) |locs| {
                            if (source_file_id < locs.len) {
                                const src = RuleIR.sourceOffsetToLineCol(locs[source_file_id], node.source_start);
                                const value_col: usize = @intCast(src.col);
                                var leading_value_ws: usize = 0;
                                while (leading_value_ws < val_str.len and
                                    (val_str[leading_value_ws] == ' ' or val_str[leading_value_ws] == '\t'))
                                {
                                    leading_value_ws += 1;
                                }
                                const prefix_cols = prop_str.len + 1 + leading_value_ws;
                                break :blk if (value_col > prefix_cols) value_col - prefix_cols else value_col;
                            }
                        }
                        break :blk null;
                    };
                    try emit_ctx.writeByte(':');
                    try WriterHelpers.writeCustomPropertyValue(emit_ctx, temp_alloc, val_str, state.indent_level, source_decl_col);
                } else {
                    try emit_ctx.writeAll(": ");
                    var value_text = val_str;
                    var value_owned: ?[]const u8 = null;
                    defer if (value_owned) |owned| temp_alloc.free(owned);
                    const marked_calc_interp = early_marked_calc_interp or containsCalcDeclMarker(value_text) or isMarkedCalcInterpolationDecl(value_text);
                    const calc_unmarked = try stripAllCalcDeclMarkers(temp_alloc, value_text);
                    if (calc_unmarked.ptr != value_text.ptr) {
                        if (value_owned) |owned| temp_alloc.free(owned);
                        value_text = calc_unmarked;
                        value_owned = calc_unmarked;
                    }
                    var preserved_calc_trailing_operator = false;
                    // Both parsed expression and raw fallback paths remove
                    // source `/* */` at parser stage. Remaining comments come
                    // from interpolation, so preserve them.
                    if (!marked_literal_decl and !marked_calc_interp and (std.ascii.eqlIgnoreCase(prop_str, "filter") or
                        std.mem.find(u8, value_text, "\\9") != null or
                        std.mem.find(u8, value_text, "\\0") != null))
                    {
                        const normalized_val = try WriterHelpers.normalizeDeclarationValue(temp_alloc, value_text);
                        if (!(normalized_val.ptr == value_text.ptr and normalized_val.len == value_text.len)) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = normalized_val;
                            value_owned = normalized_val;
                        }
                    }
                    if (!marked_literal_decl) {
                        if (try normalizeCalcTrailingOperatorParens(temp_alloc, value_text)) |normalized_tail_op| {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = normalized_tail_op;
                            value_owned = normalized_tail_op;
                            preserved_calc_trailing_operator = true;
                        }
                    }
                    if (!marked_literal_decl and !preserved_calc_trailing_operator and css_utils.containsCalcFunction(value_text)) {
                        const nested_calc = hasNestedCalcInDeclValue(value_text);
                        const ie_hack_nested_calc = nested_calc and std.mem.find(u8, value_text, "\\0") != null;
                        const has_calc_preserve_marker = std.mem.indexOf(u8, value_text, calc_interp_preserve_start) != null;
                        const calc_normalized = if (marked_calc_interp or has_calc_preserve_marker or ie_hack_nested_calc)
                            try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(temp_alloc, value_text)
                        else
                            try calc_utils.normalizeCalcInDeclValue(temp_alloc, value_text);
                        if (calc_normalized.ptr != value_text.ptr) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = calc_normalized;
                            value_owned = calc_normalized;
                        }
                    }
                    if (!marked_literal_decl and !css_utils.containsAsciiIgnoreCase(value_text, "progid:")) {
                        const hex_alpha_expanded = try value_format.expandHexAlphaColors(temp_alloc, value_text);
                        if (!std.mem.eql(u8, hex_alpha_expanded, value_text)) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = hex_alpha_expanded;
                            value_owned = hex_alpha_expanded;
                        } else {
                            temp_alloc.free(hex_alpha_expanded);
                        }
                    }
                    if (!marked_literal_decl) {
                        if (try value_format.normalizeLeadingZerosInMathFunctionsMaybeAlloc(temp_alloc, value_text)) |zero_filled| {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = zero_filled;
                            value_owned = zero_filled;
                        }
                    }
                    const preserve_unmarked = try stripCalcInterpolationPreserveMarkers(temp_alloc, value_text);
                    if (preserve_unmarked.ptr != value_text.ptr) {
                        if (value_owned) |owned| temp_alloc.free(owned);
                        value_text = preserve_unmarked;
                        value_owned = preserve_unmarked;
                    }
                    if (output_style_ == .expanded) {
                        const escaped_private = try escapeExpandedDeclPrivateUseCodePoints(temp_alloc, value_text);
                        if (escaped_private.ptr != value_text.ptr) {
                            if (value_owned) |owned| temp_alloc.free(owned);
                            value_text = escaped_private;
                            value_owned = escaped_private;
                        }
                    }
                    if (marked_interp_decl and emit_ctx.compressed) try emit_ctx.writeAll(interp_decl_marker);
                    if (marked_literal_decl and emit_ctx.compressed) try emit_ctx.writeAll(literal_decl_marker);
                    try emit_ctx.writeAll(value_text);
                }
                try emit_ctx.writeAll(";");
                if (try inlineCommentAfter(self_ir, intern_pool_, skip_flags, temp_alloc, source_locations_, idx, true)) |inline_comment| {
                    try emit_ctx.writeByte(' ');
                    try emit_ctx.writeAll(inline_comment.text);
                    skip_flags[inline_comment.idx] = true;
                } else if (try inlineCommentAfter(self_ir, intern_pool_, skip_flags, temp_alloc, source_locations_, idx, false)) |inline_comment| {
                    const next_after_comment = nextRenderableNodeIndex(self_ir.nodes.items, skip_flags, inline_comment.idx);
                    if (next_after_comment) |after_idx| {
                        switch (self_ir.nodes.items[after_idx].kind) {
                            .rule_end, .at_rule_end => {
                                try emit_ctx.writeByte(' ');
                                try emit_ctx.writeAll(inline_comment.text);
                                skip_flags[inline_comment.idx] = true;
                            },
                            else => {},
                        }
                    }
                }
                try emit_ctx.writeByte('\n');
                state.has_output = true;
            }

            fn emitCommentNode(
                self_ir: *const RuleIR,
                emit_ctx: *EmitCtx,
                intern_pool_: *const InternPool,
                skip_flags: []const bool,
                temp_alloc: std.mem.Allocator,
                state: *EmitLoopState,
                idx: usize,
                node: Node,
                source_file_id: u32,
            ) !void {
                if (state.has_output and state.indent_level == 0) {
                    if (previousRenderableNodeIndex(self_ir.nodes.items, skip_flags, idx)) |prev_idx| {
                        if (self_ir.nodes.items[prev_idx].kind == .rule_end) {
                            const prev_begin = self_ir.findMatchingRuleBeginBackward(0, prev_idx);
                            const suppress_after_nested_or_reopen = if (prev_begin) |begin_idx| blk: {
                                const begin_node = self_ir.nodes.items[begin_idx];
                                const nest_depth = if (begin_node.payload + 1 < self_ir.extra.items.len)
                                    self_ir.extra.items[begin_node.payload + 1]
                                else
                                    0;
                                break :blk nest_depth != 0 or self_ir.getOriginReopenAt(begin_idx);
                            } else false;
                            if (!suppress_after_nested_or_reopen) {
                                state.pending_blank = true;
                            }
                        }
                    }
                }
                try consumeStandardPendingBlank(emit_ctx, state);
                try emit_ctx.markNode(source_file_id, node);
                const text_id = self_ir.extra.items[node.payload];
                const raw_text = intern_pool_.get(@enumFromInt(text_id));
                const text = try normalizeCommentTextForEmit(temp_alloc, raw_text);
                if (WriterHelpers.isSourceMapCommentText(text)) {
                    if (!state.has_output and state.indent_level == 0) {
                        state.pending_leading_blank = true;
                    } else if (state.has_output and state.indent_level == 0) {
                        // When the official Sass CLI drops `/*# sourceMappingURL ... */`,
                        // Leave a blank line marker at that position (generate trailing `\n` at EOF).
                        state.pending_trailing_sourcemap_blank = true;
                    }
                    return;
                }

                const newline_pos = std.mem.findScalar(u8, text, '\n');
                if (newline_pos == null) {
                    try writeCurrentIndent(emit_ctx, state.indent_level);
                    try emit_ctx.writeAll(text);
                    try emit_ctx.writeByte('\n');
                    state.has_output = true;
                    state.prev_visible_is_comment = true;
                    return;
                }

                var lines: std.ArrayListUnmanaged([]const u8) = .empty;
                defer lines.deinit(temp_alloc);
                {
                    var ls: usize = 0;
                    while (ls <= text.len) {
                        const le = std.mem.findScalarPos(u8, text, ls, '\n') orelse text.len;
                        try lines.append(temp_alloc, text[ls..le]);
                        if (le == text.len) break;
                        ls = le + 1;
                    }
                }

                var min_indent: ?usize = null;
                if (lines.items.len > 1) {
                    for (lines.items[1..]) |line| {
                        var spaces: usize = 0;
                        while (spaces < line.len and (line[spaces] == ' ' or line[spaces] == '\t')) : (spaces += 1) {}
                        if (spaces == line.len) continue;
                        min_indent = if (min_indent) |m| @min(m, spaces) else spaces;
                    }
                }
                // official Sass CLI dedents the continuation line of loud comment by "column of `/*` on source".
                // If the source position can be determined (actual operation), check with col_of_slash, if not (unit test with span=0)
                // If so, fall back to the old logic of inferring from indent_level.
                var comment_col_known = false;
                const strip: usize = blk: {
                    const m = min_indent orelse break :blk 0;
                    // appendCommentWithCol uses source column from resolver
                    // Save in extra[payload+1] (ast.source standard, so use @import inline
                    // Accurate even in cases where file_id differs). Only if sentinel is included
                    // Fallback to old heuristic (source_locations / indent_level).
                    if (node.payload + 1 < self_ir.extra.items.len) {
                        const stored_col = self_ir.extra.items[node.payload + 1];
                        if (stored_col != RuleIR.comment_source_col_unknown) {
                            comment_col_known = true;
                            break :blk @min(@as(usize, stored_col), m);
                        }
                    }
                    if (emit_ctx.source_locations) |locs| {
                        if (source_file_id < locs.len) {
                            const col = RuleIR.sourceOffsetToLineCol(locs[source_file_id], node.source_start).col;
                            comment_col_known = true;
                            break :blk @min(col, m);
                        }
                    }
                    const target_column = state.indent_level * 2;
                    if (state.indent_level == 0) break :blk @min(target_column, m);
                    break :blk m;
                };

                try writeCurrentIndent(emit_ctx, state.indent_level);
                try emit_ctx.writeAll(lines.items[0]);
                if (lines.items.len > 1) {
                    for (lines.items[1..]) |line| {
                        try emit_ctx.writeByte('\n');
                        const after_strip = if (line.len >= strip) line[strip..] else line;
                        if (std.mem.trim(u8, after_strip, " \t").len == 0) {
                            continue;
                        }
                        try writeCurrentIndent(emit_ctx, state.indent_level);
                        const first_trimmed = std.mem.trim(u8, lines.items[0], " \t");
                        const is_closer_line = std.mem.eql(u8, std.mem.trim(u8, after_strip, " \t"), "*/");
                        const is_plain_or_bang_opener =
                            std.mem.eql(u8, first_trimmed, "/*") or std.mem.eql(u8, first_trimmed, "/*!");
                        const had_leading_ws = line.len > 0 and (line[0] == ' ' or line[0] == '\t');
                        if (!comment_col_known and
                            after_strip.len > 0 and
                            after_strip[0] == '*' and
                            had_leading_ws and
                            !(is_closer_line and is_plain_or_bang_opener))
                        {
                            try emit_ctx.writeByte(' ');
                        }
                        try emit_ctx.writeAll(after_strip);
                    }
                }
                try emit_ctx.writeByte('\n');
                state.has_output = true;
                state.prev_visible_is_comment = true;
            }
        };

        var emit: EmitCtx = .{
            .writer = effective_writer,
            .source_map = source_map,
            .source_locations = source_locations,
            .source_index_cache = source_index_cache,
            .track_generated_positions = source_map != null and source_locations != null and output_style != .compressed,
            .path_arena = temp,
            .urls_mode = opts.source_map_urls_mode,
            .source_map_output_dir_abs = opts.source_map_output_dir_abs,
            .compressed = output_style == .compressed,
        };

        var emit_state: EmitLoopState = .{};
        // Should the open at-rule block "retain blank after termination (= hoisted @media)"?
        // Stack of. Push at at_rule_begin emit, pop at at_rule_end and refer to it.
        var at_rule_preserve_stack: std.ArrayListUnmanaged(bool) = .empty;
        defer at_rule_preserve_stack.deinit(temp);
        // Is the open rule / at-rule block @at-root hoisted with the
        // origin_at_root_hoisted flag? rule_begin / at_rule_begin push when
        // emitted, rule_end / at_rule_end pop. If popped=true, set
        // prev_visible_is_at_root_hoist. Rule and at-rule nodes are nested in
        // LIFO order, so one stack is sufficient.
        var block_hoist_stack: std.ArrayListUnmanaged(bool) = .empty;
        defer block_hoist_stack.deinit(temp);
        if (saw_charset and output_style != .compressed and opts.emit_charset) {
            try emit.writeAll("@charset \"UTF-8\";\n");
            emit_state.has_output = true;
            // official Sass CLI does not insert blank lines before and after top-level `@charset` / `@import`.
            // The auto-emit `@charset` also suppresses subsequent pending_blank accordingly.
            emit_state.prev_visible_is_top_import = true;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (skip[i]) continue;
            const node = self.nodes.items[i];
            const source_file_id: u32 = if (i < self.node_source_files.items.len) self.node_source_files.items[i] else 0;
            switch (node.kind) {
                .stmt_gap, .group_boundary => {
                    // Just set the pending_blank flag.
                    // Consume just before the next rule_begin / at_rule_begin to print a blank line.
                    emit_state.pending_blank = true;
                    emit_state.pending_trailing_sourcemap_blank = false;
                    continue;
                },
                .sourcemap_gap => {
                    if (!emit_state.has_output and emit_state.indent_level == 0) {
                        emit_state.pending_leading_blank = true;
                    } else {
                        emit_state.pending_blank = true;
                    }
                    emit_state.pending_trailing_sourcemap_blank = true;
                    continue;
                },
                .stream_chunk => {
                    if (node.payload >= self.flushed_chunks.items.len) continue;
                    const chunk = self.flushed_chunks.items[node.payload];
                    if (chunk.css.len == 0) continue;
                    // stream_chunk is the result of pre-rendering top-level rule / at-rule block.
                    // If the previous line was comment / top-level @import / at-rule block etc.
                    // Apply suppress equivalent to rule_begin.
                    const suppress_pending = emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block;
                    const need_blank = if (emit_state.has_output)
                        (emit_state.pending_blank and !suppress_pending)
                    else
                        (emit_state.pending_leading_blank and !suppress_pending);
                    if (need_blank) {
                        try emit.writeAll("\n");
                    }
                    emit_state.pending_blank = false;
                    emit_state.pending_leading_blank = false;
                    emit_state.pending_trailing_sourcemap_blank = false;
                    try emit.writeAll(chunk.css);
                    emit_state.has_output = true;
                    // If chunk contains up to inline trailing comment then visible
                    // Suppress the previous blank (treated as "trailing comment" like legacy official Sass CLI,
                    // Equivalent to had_inline_comment in emitBlockEndNode).
                    emit_state.prev_visible_is_comment = chunk.ends_with_inline_comment;
                    emit_state.prev_visible_is_top_import = false;
                    // The final block of chunk is at-rule block (@media/@font-face/@property etc.)
                    // If finished, suppress the blank immediately before the rule/at-rule
                    // (equivalent to official Sass CLI `skip_consecutive_top_rules`). inline trailing
                    // If there is a comment, it will be suppressed on the prev_visible_is_comment side, so
                    // There is no need to set a flag here (same relationship as emitBlockEndNode).
                    emit_state.prev_visible_is_at_rule_block = chunk.ends_with_at_rule_block and !chunk.ends_with_inline_comment;
                },
                .rule_begin => {
                    perf.note(.codegen_rule);
                    perf.note(.format_selector);
                    if (merge_same_rule_begin[i]) {
                        emit_state.pending_blank = false;
                        emit_state.pending_leading_blank = false;
                        emit_state.pending_trailing_sourcemap_blank = false;
                        continue;
                    }
                    const sel_raw = getNodeSelectorText(self, i, selector_override, intern_pool);
                    var sel_str = sel_raw;
                    var sel_owned: ?[]const u8 = null;
                    defer if (sel_owned) |owned| temp.free(owned);
                    const selector_hints = WriterHelpers.scanSelectorEmitHints(sel_str);
                    if (selector_hints.has_slash) {
                        const stripped_sel = try WriterHelpers.stripSelectorComments(temp, sel_str);
                        if (!(stripped_sel.ptr == sel_str.ptr and stripped_sel.len == sel_str.len)) {
                            sel_str = stripped_sel;
                            sel_owned = stripped_sel;
                        }
                    }
                    if (selector_hints.has_n) {
                        const nth_normalized_sel = try WriterHelpers.normalizeNthOfTypeSelectorArgs(temp, sel_str);
                        if (!(nth_normalized_sel.ptr == sel_str.ptr and nth_normalized_sel.len == sel_str.len)) {
                            sel_str = nth_normalized_sel;
                            sel_owned = nth_normalized_sel;
                        }
                    }
                    const escaped_sel = try WriterHelpers.ensureTrailingControlHexEscapeSpace(temp, sel_str);
                    if (!(escaped_sel.ptr == sel_str.ptr and escaped_sel.len == sel_str.len)) {
                        sel_str = escaped_sel;
                        sel_owned = escaped_sel;
                    }
                    if (selector_hints.has_paren and selector_hints.has_ws) {
                        const paren_normalized_sel = try WriterHelpers.collapseSelectorParenEdgeWhitespace(temp, sel_str);
                        if (!(paren_normalized_sel.ptr == sel_str.ptr and paren_normalized_sel.len == sel_str.len)) {
                            sel_str = paren_normalized_sel;
                            sel_owned = paren_normalized_sel;
                        }
                    }
                    if (selector_hints.has_paren) {
                        const pseudo_arg_normalized_sel = try WriterHelpers.normalizeSelectorPseudoArgumentSpacing(temp, sel_str);
                        if (!(pseudo_arg_normalized_sel.ptr == sel_str.ptr and pseudo_arg_normalized_sel.len == sel_str.len)) {
                            sel_str = pseudo_arg_normalized_sel;
                            sel_owned = pseudo_arg_normalized_sel;
                        }
                    }
                    if (selector_hints.has_ws) {
                        const compound_normalized_sel = try WriterHelpers.normalizeSelectorCompoundWhitespace(temp, sel_str);
                        if (!(compound_normalized_sel.ptr == sel_str.ptr and compound_normalized_sel.len == sel_str.len)) {
                            sel_str = compound_normalized_sel;
                            sel_owned = compound_normalized_sel;
                        }
                    }
                    if (selector_hints.has_combinator_candidate) {
                        const combinator_normalized_sel = try WriterHelpers.normalizeSelectorCombinatorSpacing(temp, sel_str);
                        if (!(combinator_normalized_sel.ptr == sel_str.ptr and combinator_normalized_sel.len == sel_str.len)) {
                            sel_str = combinator_normalized_sel;
                            sel_owned = combinator_normalized_sel;
                        }
                        const pseudo_child_normalized_sel = try WriterHelpers.normalizePseudoLeadingChildCombinatorSpacing(temp, sel_str);
                        if (!(pseudo_child_normalized_sel.ptr == sel_str.ptr and pseudo_child_normalized_sel.len == sel_str.len)) {
                            sel_str = pseudo_child_normalized_sel;
                            sel_owned = pseudo_child_normalized_sel;
                        }
                    }
                    if (selector_hints.has_paren) {
                        if (try normalizeNestedNotHasExtendSelector(temp, sel_str)) |nested_not_has_sel| {
                            sel_str = nested_not_has_sel;
                            sel_owned = nested_not_has_sel;
                        }
                    }
                    if (std.mem.trim(u8, sel_str, " \t\r\n").len == 0) continue;
                    const nest_depth: u32 = self.extra.items[node.payload + 1];
                    // Official Sass CLI: if prev is comment, always suppress the next visible previous blank
                    // (comment is treated as ``incidental'' to the next rule). prev is top-level `@charset`/`@import`
                    // is also treated as preamble and blank is not output.
                    // Even if prev is an at-rule block (@media etc.), official Sass CLI will print the blank before the next rule.
                    // Do not issue legacy consecutive-top-rule suppression here.
                    const explicit_suppress = self.getSuppressLeadingBlankAt(i);
                    const is_at_root_hoist = self.getOriginAtRootHoistedAt(i);
                    // The non-hoisted rule that comes immediately after @at-root hoisted block is
                    // Force blank regardless of nest_depth / explicit_suppress
                    // (clean-room nested at-root media repro).
                    const hoist_exit_force_blank = emit_state.prev_visible_is_at_root_hoist and
                        !is_at_root_hoist and emit_state.has_output and emit_state.indent_level == 0 and
                        // A hoisted at-rule block (for example keyframes emitted from an
                        // imported nested file) is still an at-rule block for adjacency;
                        // do not let the @at-root escape flag reintroduce a blank there.
                        !emit_state.prev_visible_is_comment and !emit_state.prev_visible_is_at_rule_block;
                    // official Sass CLI keeps a blank between consecutive @at-root-emitted style
                    // rules, even when the second rule carried suppress_leading_blank from
                    // its original nested position. Do this only for style rules: hoisted
                    // at-rules have their own adjacency rules and the hoisted
                    // rule -> @media sequence must remain compact.
                    const explicit_suppress_effective = explicit_suppress and
                        !(emit_state.prev_visible_is_at_root_hoist and is_at_root_hoist);
                    const is_reopen = self.getOriginReopenAt(i);
                    // Consecutive @at-root style blocks preserve the source blank before
                    // the reopened block.  This is style-rule-only; hoisted at-rules keep
                    // their own adjacency rules.
                    const at_root_reopen_after_hoist_force_blank = emit_state.prev_visible_is_at_root_hoist and
                        is_at_root_hoist and is_reopen and emit_state.has_output and
                        emit_state.indent_level == 0 and !emit_state.prev_visible_is_comment;
                    const suppress_reopen_after_nested = if (is_reopen) blk: {
                        const prev_idx = previousRenderableNodeIndex(self.nodes.items, skip, i) orelse break :blk false;
                        if (self.nodes.items[prev_idx].kind != .rule_end) break :blk false;
                        if (prev_idx >= self.node_source_files.items.len) break :blk false;
                        const prev_begin = self.findMatchingRuleBeginBackward(0, prev_idx) orelse break :blk false;
                        const prev_begin_node = self.nodes.items[prev_begin];
                        const prev_sel = intern_pool.get(@enumFromInt(self.extra.items[prev_begin_node.payload]));
                        // Same-source user-written top-level rules still get official Sass CLI's
                        // normal blank.  The same-source exception here is only for
                        // generated reopens whose previous selector list still carries a
                        // placeholder member (`%x, .x`); after filtering, the concrete
                        // `.x:pseudo` member is the parent continuation.
                        if (self.node_source_files.items[prev_idx] == source_file_id and
                            std.mem.findScalar(u8, prev_sel, '%') == null) break :blk false;
                        break :blk selectorListLooksLikeParentContinuation(prev_sel, sel_str);
                    } else false;
                    const suppress_parent_continuation_after_rule = blk: {
                        const prev_idx = previousRenderableNodeIndex(self.nodes.items, skip, i) orelse break :blk false;
                        if (self.nodes.items[prev_idx].kind != .rule_end) break :blk false;
                        if (prev_idx >= self.node_source_files.items.len) break :blk false;
                        const prev_begin = self.findMatchingRuleBeginBackward(0, prev_idx) orelse break :blk false;
                        const prev_begin_node = self.nodes.items[prev_begin];
                        if (prev_begin_node.payload >= self.extra.items.len) break :blk false;
                        const prev_sel = intern_pool.get(@enumFromInt(self.extra.items[prev_begin_node.payload]));
                        if (self.node_source_files.items[prev_idx] == source_file_id and
                            std.mem.findScalar(u8, prev_sel, '%') == null) break :blk false;
                        if (std.mem.eql(u8, std.mem.trim(u8, prev_sel, " \t\r\n"), std.mem.trim(u8, sel_str, " \t\r\n"))) break :blk false;
                        break :blk selectorListLooksLikeParentContinuation(prev_sel, sel_str);
                    };
                    const source_boundary_force_blank = blk: {
                        if (emit_state.indent_level != 0 or nest_depth != 0) break :blk false;
                        if (is_reopen or emit_state.prev_visible_is_comment or emit_state.prev_visible_is_top_import or emit_state.prev_visible_is_at_rule_block) break :blk false;
                        const prev_idx = previousRenderableNodeIndex(self.nodes.items, skip, i) orelse break :blk false;
                        if (self.nodes.items[prev_idx].kind != .rule_end) break :blk false;
                        if (prev_idx >= self.node_source_files.items.len) break :blk false;
                        break :blk self.node_source_files.items[prev_idx] != source_file_id;
                    };
                    const suppress_fallback = explicit_suppress_effective or
                        suppress_reopen_after_nested or
                        suppress_parent_continuation_after_rule or
                        emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block;
                    const suppress_pending = suppress_reopen_after_nested or
                        suppress_parent_continuation_after_rule or
                        emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block;
                    const need_blank = if (emit_state.has_output)
                        ((emit_state.pending_blank and !suppress_pending) or
                            (emit_state.indent_level == 0 and nest_depth == 0 and !suppress_fallback) or
                            source_boundary_force_blank or
                            hoist_exit_force_blank or
                            at_root_reopen_after_hoist_force_blank)
                    else
                        (emit_state.pending_leading_blank and emit_state.indent_level == 0 and !suppress_fallback);
                    if (need_blank) {
                        try emit.writeAll("\n");
                    }
                    emit_state.pending_blank = false;
                    emit_state.pending_leading_blank = false;
                    emit_state.pending_trailing_sourcemap_blank = false;
                    emit_state.prev_visible_is_at_root_hoist = false;
                    try emit.markNode(source_file_id, node);
                    var j: usize = 0;
                    while (j < emit_state.indent_level) : (j += 1) {
                        try emit.writeAll("  ");
                    }
                    try WriterHelpers.writeIndentedMultiline(&emit, sel_str, emit_state.indent_level);
                    if (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, true)) |inline_comment| {
                        const next_after_comment = nextRenderableNodeIndex(self.nodes.items, skip, inline_comment.idx);
                        if (next_after_comment) |after_idx| {
                            if (self.nodes.items[after_idx].kind == .rule_end) {
                                try emit.writeAll(" { ");
                                try emit.writeAll(inline_comment.text);
                                try emit.writeAll(" }\n");
                                skip[inline_comment.idx] = true;
                                skip[after_idx] = true;
                                emit_state.has_output = true;
                                emit_state.prev_visible_is_comment = false;
                                emit_state.prev_visible_is_top_import = false;
                                emit_state.prev_visible_is_at_rule_block = false;
                                continue;
                            }
                        }
                    }
                    // If the first comment of block is on the same line as `{` on source, official Sass CLI will
                    // as `{ /* first */ }` or `{ /* first */\n /* rest */\n}`
                    // Leave on the opening brace line. This is reopened parent after nested rule
                    // Same thing with comment (`.a { .b{} /* note */ }`).
                    if (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, true)) |inline_comment| {
                        const after_first = nextRenderableNodeIndex(self.nodes.items, skip, inline_comment.idx);
                        if (after_first) |after_idx| {
                            if (self.nodes.items[after_idx].kind == .comment) {
                                var scan_idx = after_idx;
                                var comments_then_end = false;
                                while (true) {
                                    switch (self.nodes.items[scan_idx].kind) {
                                        .comment => {
                                            scan_idx = nextRenderableNodeIndex(self.nodes.items, skip, scan_idx) orelse break;
                                            continue;
                                        },
                                        .rule_end => {
                                            comments_then_end = true;
                                            break;
                                        },
                                        else => break,
                                    }
                                }
                                if (comments_then_end) {
                                    try emit.writeAll(" { ");
                                    try emit.writeAll(inline_comment.text);
                                    try emit.writeByte('\n');
                                    skip[inline_comment.idx] = true;
                                    emit_state.indent_level += 1;
                                    emit_state.has_output = true;
                                    emit_state.prev_visible_is_comment = false;
                                    emit_state.prev_visible_is_top_import = false;
                                    emit_state.prev_visible_is_at_rule_block = false;
                                    continue;
                                }
                            }
                        }
                    }
                    const only_child_is_same_line_content_comment = blk: {
                        const ic = (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, true)) orelse break :blk false;
                        if (isEmptyBlockCommentText(ic.text)) break :blk false;
                        const after = nextRenderableNodeIndex(self.nodes.items, skip, ic.idx) orelse break :blk false;
                        break :blk self.nodes.items[after].kind == .rule_end;
                    };
                    // Put the @at-root hoisted flag on the stack and pop it on
                    // the rule_end side. This forces a blank before a following
                    // non-hoisted rule/at-rule while preserving stack balance.
                    try block_hoist_stack.append(temp, is_at_root_hoist);
                    if (only_child_is_same_line_content_comment) {
                        try emit.writeAll(" {\n");
                        emit_state.indent_level += 1;
                        emit_state.has_output = true;
                        emit_state.prev_visible_is_comment = false;
                        emit_state.prev_visible_is_top_import = false;
                        emit_state.prev_visible_is_at_rule_block = false;
                        continue;
                    }
                    if (!is_reopen) {
                        if (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, true) orelse
                            try inlineCommentAfterOpeningBraceHeuristic(
                                self,
                                intern_pool,
                                skip,
                                temp,
                                source_locations,
                                i,
                                @intCast(emit_state.indent_level * 2 + 4),
                            )) |inline_comment|
                        {
                            try emit.writeAll(" { ");
                            try emit.writeAll(inline_comment.text);
                            try emit.writeByte('\n');
                            skip[inline_comment.idx] = true;
                            emit_state.indent_level += 1;
                            emit_state.has_output = true;
                            emit_state.prev_visible_is_comment = false;
                            emit_state.prev_visible_is_top_import = false;
                            emit_state.prev_visible_is_at_rule_block = false;
                            continue;
                        }
                    }
                    try emit.writeAll(" {\n");
                    emit_state.indent_level += 1;
                    emit_state.has_output = true;
                    emit_state.prev_visible_is_comment = false;
                    emit_state.prev_visible_is_top_import = false;
                    emit_state.prev_visible_is_at_rule_block = false;
                },
                .rule_end => {
                    try EmitLoopHelpers.emitBlockEndNode(
                        self,
                        &emit,
                        intern_pool,
                        skip,
                        temp,
                        source_locations,
                        i,
                        node,
                        source_file_id,
                        &emit_state,
                    );
                    // After closing an @at-root-hoisted rule, force a blank
                    // before the next non-hoisted rule/at-rule. Reset on
                    // non-hoist close so an inner hoist cannot leak outward.
                    const was_hoist = blk: {
                        if (block_hoist_stack.items.len == 0) break :blk false;
                        break :blk block_hoist_stack.pop() orelse false;
                    };
                    emit_state.prev_visible_is_at_root_hoist = was_hoist and !emit_state.prev_visible_is_comment;
                },
                .decl => {
                    perf.note(.codegen_decl);
                    try EmitLoopHelpers.emitDeclNode(
                        self,
                        &emit,
                        intern_pool,
                        skip,
                        temp,
                        source_locations,
                        i,
                        node,
                        source_file_id,
                        &emit_state,
                        output_style,
                    );
                },
                .decl_raw => {
                    perf.note(.codegen_decl);
                    try EmitLoopHelpers.emitDeclRawNode(
                        self,
                        &emit,
                        intern_pool,
                        skip,
                        temp,
                        source_locations,
                        i,
                        node,
                        source_file_id,
                        &emit_state,
                        output_style,
                    );
                },
                .at_rule_simple => {
                    perf.note(.codegen_at_rule);
                    const at_simple_name_id = self.extra.items[node.payload];
                    const at_simple_name = intern_pool.get(@enumFromInt(at_simple_name_id));
                    const is_top_import = emit_state.indent_level == 0 and std.ascii.eqlIgnoreCase(at_simple_name, "import");
                    // The official Sass CLI always suppresses trailing blank if the
                    // immediately preceding visible node is a simple at-rule.
                    // For self-suppress, only @import/@charset preamble is the same as before.
                    const is_top_simple_at_rule = emit_state.indent_level == 0;
                    const suppress_simple_leading_blank = emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block or
                        is_top_import;
                    const need_blank = if (emit_state.has_output)
                        (emit_state.pending_blank and !suppress_simple_leading_blank)
                    else
                        (emit_state.pending_leading_blank and emit_state.indent_level == 0 and !suppress_simple_leading_blank);
                    if (need_blank) {
                        try emit.writeAll("\n");
                    }
                    emit_state.pending_blank = false;
                    emit_state.pending_leading_blank = false;
                    emit_state.pending_trailing_sourcemap_blank = false;
                    emit_state.prev_visible_is_comment = false;
                    emit_state.prev_visible_is_top_import = is_top_simple_at_rule;
                    emit_state.prev_visible_is_at_rule_block = false;
                    try emit.markNode(source_file_id, node);
                    const name_id = self.extra.items[node.payload];
                    const prelude_id = self.extra.items[node.payload + 1];
                    const name = intern_pool.get(@enumFromInt(name_id));
                    if (isMediaAtRuleName(name)) {
                        if (prelude_id == std.math.maxInt(u32)) continue;
                        const media_prelude_text = stripMediaPreludePreserveCaseMarker(intern_pool.get(@enumFromInt(prelude_id)));
                        if (std.mem.findAny(u8, media_prelude_text, "\n\r\x0c") != null) continue;
                    }
                    if (prelude_id != std.math.maxInt(u32) and isSupportsAtRuleName(name)) {
                        const prelude = intern_pool.get(@enumFromInt(prelude_id));
                        if (try WriterHelpers.emitLeakedAtRuleSimple(&emit, temp, name, prelude, emit_state.indent_level)) {
                            emit_state.has_output = true;
                            continue;
                        }
                    }
                    var j: usize = 0;
                    while (j < emit_state.indent_level) : (j += 1) {
                        try emit.writeAll("  ");
                    }
                    try emit.writeAll("@");
                    try emit.writeAll(name);
                    if (isSupportsAtRuleName(name) and prelude_id == std.math.maxInt(u32)) return error.SassError;
                    if (prelude_id != std.math.maxInt(u32)) {
                        const prelude_raw = intern_pool.get(@enumFromInt(prelude_id));
                        const preserve_media_case = isMediaAtRuleName(name) and mediaPreludePreserveCase(prelude_raw);
                        const prelude_base = stripMediaPreludePreserveCaseMarker(prelude_raw);
                        const normalized = try WriterHelpers.normalizeAtRulePreludeForEmit(
                            temp,
                            name,
                            prelude_base,
                            preserve_media_case,
                            .simple,
                        );
                        defer if (!(normalized.ptr == prelude_base.ptr and normalized.len == prelude_base.len)) temp.free(normalized);
                        try emit.writeAll(" ");
                        try emit.writeAll(normalized);
                    }
                    try emit.writeAll(";\n");
                    emit_state.has_output = true;
                },
                .at_rule_begin => {
                    perf.note(.codegen_at_rule);
                    if (merge_same_rule_begin[i]) {
                        emit_state.pending_blank = false;
                        emit_state.pending_leading_blank = false;
                        emit_state.pending_trailing_sourcemap_blank = false;
                        continue;
                    }
                    const name_id = self.extra.items[node.payload];
                    const prelude_id = self.extra.items[node.payload + 1];
                    const nest_depth: u32 = self.extra.items[node.payload + 2];
                    const explicit_suppress = self.getSuppressLeadingBlankAt(i);
                    const is_at_root_hoist = self.getOriginAtRootHoistedAt(i);
                    const hoist_exit_force_blank = emit_state.prev_visible_is_at_root_hoist and
                        !is_at_root_hoist and emit_state.has_output and emit_state.indent_level == 0 and
                        !emit_state.prev_visible_is_comment and !emit_state.prev_visible_is_at_rule_block;
                    const name = intern_pool.get(@enumFromInt(name_id));
                    const is_container_or_layer = std.mem.eql(u8, name, "container") or std.mem.eql(u8, name, "layer");
                    const suppress_fallback = explicit_suppress or
                        emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block;
                    const suppress_pending = (explicit_suppress and is_container_or_layer) or
                        emit_state.prev_visible_is_comment or
                        emit_state.prev_visible_is_top_import or
                        emit_state.prev_visible_is_at_rule_block;
                    const empty_end = empty_at_rule_end[i];
                    const need_blank = if (emit_state.has_output)
                        ((emit_state.pending_blank and !suppress_pending) or
                            (emit_state.indent_level == 0 and nest_depth == 0 and !suppress_fallback) or
                            hoist_exit_force_blank)
                    else
                        (emit_state.pending_leading_blank and emit_state.indent_level == 0 and !suppress_fallback);
                    if (need_blank) {
                        try emit.writeAll("\n");
                    }
                    emit_state.pending_blank = false;
                    emit_state.pending_leading_blank = false;
                    emit_state.pending_trailing_sourcemap_blank = false;
                    emit_state.prev_visible_is_at_root_hoist = false;
                    try emit.markNode(source_file_id, node);
                    var j: usize = 0;
                    while (j < emit_state.indent_level) : (j += 1) {
                        try emit.writeAll("  ");
                    }
                    try emit.writeAll("@");
                    try emit.writeAll(name);
                    if (isSupportsAtRuleName(name) and prelude_id == std.math.maxInt(u32)) return error.SassError;
                    if (prelude_id != std.math.maxInt(u32)) {
                        const prelude_raw = intern_pool.get(@enumFromInt(prelude_id));
                        const preserve_media_case = isMediaAtRuleName(name) and mediaPreludePreserveCase(prelude_raw);
                        const prelude_base = stripMediaPreludePreserveCaseMarker(prelude_raw);
                        const normalized = try WriterHelpers.normalizeAtRulePreludeForEmit(
                            temp,
                            name,
                            prelude_base,
                            preserve_media_case,
                            .block,
                        );
                        defer if (!(normalized.ptr == prelude_base.ptr and normalized.len == prelude_base.len)) temp.free(normalized);
                        try emit.writeAll(" ");
                        try emit.writeAll(normalized);
                    }
                    if (empty_end != std.math.maxInt(u32)) {
                        try emit.writeAll(" {}\n");
                        emit_state.has_output = true;
                        emit_state.prev_visible_is_comment = false;
                        emit_state.prev_visible_is_top_import = false;
                        // inline empty block `@media ... {}` completes the at-rule block.
                        // Suppress next visible previous blank like at_rule_end.
                        emit_state.prev_visible_is_at_rule_block = true;
                        i = empty_end;
                        continue;
                    }
                    if (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, false)) |inline_comment| {
                        const next_after_comment = nextRenderableNodeIndex(self.nodes.items, skip, inline_comment.idx);
                        if (next_after_comment) |after_idx| {
                            if (self.nodes.items[after_idx].kind == .at_rule_end and
                                isEmptyBlockCommentText(inline_comment.text))
                            {
                                try emit.writeAll(" { ");
                                try emit.writeAll(inline_comment.text);
                                try emit.writeAll(" }\n");
                                skip[inline_comment.idx] = true;
                                skip[after_idx] = true;
                                emit_state.has_output = true;
                                emit_state.prev_visible_is_comment = false;
                                emit_state.prev_visible_is_top_import = false;
                                // `@media ... { /* */ }` Inline empty block is also treated as equivalent to at_rule_end.
                                emit_state.prev_visible_is_at_rule_block = true;
                                continue;
                            }
                        }
                    }
                    if (try inlineCommentAfter(self, intern_pool, skip, temp, source_locations, i, true) orelse
                        try inlineCommentAfterOpeningBraceHeuristic(
                            self,
                            intern_pool,
                            skip,
                            temp,
                            source_locations,
                            i,
                            @intCast(emit_state.indent_level * 2 + 4),
                        )) |inline_comment|
                    {
                        try emit.writeAll(" { ");
                        try emit.writeAll(inline_comment.text);
                        try emit.writeByte('\n');
                        skip[inline_comment.idx] = true;
                    } else {
                        try emit.writeAll(" {\n");
                    }
                    emit_state.indent_level += 1;
                    emit_state.has_output = true;
                    emit_state.prev_visible_is_comment = false;
                    emit_state.prev_visible_is_top_import = false;
                    // The body of at-rule follows. flag is reset at at_rule_end.
                    emit_state.prev_visible_is_at_rule_block = false;
                    //Place the preserve flag on the stack for reference in the corresponding at_rule_end.
                    try at_rule_preserve_stack.append(temp, self.getPreserveAtRuleBlockFollowingBlankAt(i));
                    // Also put the @at-root hoisted flag on the stack,
                    // symmetrical with rule_begin.
                    try block_hoist_stack.append(temp, is_at_root_hoist);
                },
                .at_rule_end => {
                    try EmitLoopHelpers.emitBlockEndNode(
                        self,
                        &emit,
                        intern_pool,
                        skip,
                        temp,
                        source_locations,
                        i,
                        node,
                        source_file_id,
                        &emit_state,
                    );
                    var preserve_following = blk: {
                        if (at_rule_preserve_stack.items.len == 0) break :blk false;
                        break :blk at_rule_preserve_stack.pop() orelse false;
                    };
                    const was_hoist = blk: {
                        if (block_hoist_stack.items.len == 0) break :blk false;
                        break :blk block_hoist_stack.pop() orelse false;
                    };
                    // preserve_following=true leaves a blank immediately after hoisted
                    // @media. However, if the immediately following rule_begin is an
                    // origin_reopen continuation of the same parent style rule, the
                    // official Sass CLI does not put a blank between continuation rules.
                    if (preserve_following) {
                        // rule_begin immediately after hoisted @media hoisted this @media
                        // Suppress blank if continuation of parent style_rule (= reopen of same selector).
                        // The parent selector is the rule_end of the "closed parent rule" that comes before at_rule_begin
                        // Follow from (the previous closed rule on the same top-level shelf).
                        const matched_begin = self.findMatchingAtRuleBeginBackward(0, i);
                        const parent_selector_id: ?InternId = blk: {
                            const begin_idx = matched_begin orelse break :blk null;
                            // Go backwards ahead of begin_idx (same top-level) and find it first
                            // Adopt rule_end. adjacent at_rule blocks / another completed at_rule blocks /
                            // separator / at_rule_simple / comment is skipped.
                            var scan: usize = begin_idx;
                            var depth: usize = 0;
                            while (scan > 0) {
                                scan -= 1;
                                if (skip[scan]) continue;
                                const k = self.nodes.items[scan].kind;
                                if (depth > 0) {
                                    switch (k) {
                                        .rule_end, .at_rule_end => depth += 1,
                                        .rule_begin, .at_rule_begin => depth -= 1,
                                        else => {},
                                    }
                                    continue;
                                }
                                switch (k) {
                                    .stmt_gap, .group_boundary, .sourcemap_gap, .at_rule_simple, .comment => continue,
                                    .at_rule_end => {
                                        depth = 1;
                                        continue;
                                    },
                                    .rule_end => {
                                        // Return from rule_end to rule_begin to get selector.
                                        var inner_depth: usize = 1;
                                        var b: usize = scan;
                                        while (b > 0) {
                                            b -= 1;
                                            const bk = self.nodes.items[b].kind;
                                            switch (bk) {
                                                .rule_end, .at_rule_end => inner_depth += 1,
                                                .rule_begin => {
                                                    inner_depth -= 1;
                                                    if (inner_depth == 0) {
                                                        const sel_id = self.extra.items[self.nodes.items[b].payload];
                                                        break :blk @enumFromInt(sel_id);
                                                    }
                                                },
                                                .at_rule_begin => {
                                                    inner_depth -= 1;
                                                    if (inner_depth == 0) break :blk null;
                                                },
                                                else => {},
                                            }
                                        }
                                        break :blk null;
                                    },
                                    else => break :blk null,
                                }
                            }
                            break :blk null;
                        };
                        if (parent_selector_id) |parent_id| {
                            if (nextRenderableNodeIndex(self.nodes.items, skip, i)) |next_idx| {
                                if (self.nodes.items[next_idx].kind == .rule_begin and
                                    self.getOriginReopenAt(next_idx))
                                {
                                    const next_sel_id: InternId = @enumFromInt(self.extra.items[self.nodes.items[next_idx].payload]);
                                    if (next_sel_id == parent_id) {
                                        preserve_following = false;
                                    }
                                }
                            }
                        }
                    }
                    // Immediately after at-rule block, suppress the blank before the next visible.
                    // However, like hoisted @media, preserve_at_rule_block_following_blank is
                    // Do not suppress at end corresponding to standing begin (from parent style_rule
                    // Retain blank after lifting @media, matching official Sass CLI output.
                    // If inline comment appears, leave it to prev_visible_is_comment side
                    // (emitBlockEndNode makes prev_visible_is_at_rule_block false).
                    if (!preserve_following and !emit_state.prev_visible_is_comment) {
                        emit_state.prev_visible_is_at_rule_block = true;
                    }
                    // Force a blank immediately after an @at-root-hoisted
                    // at-rule close, then reset on non-hoist close.
                    emit_state.prev_visible_is_at_root_hoist = was_hoist and !emit_state.prev_visible_is_comment;
                },
                .comment => {
                    try EmitLoopHelpers.emitCommentNode(
                        self,
                        &emit,
                        intern_pool,
                        skip,
                        temp,
                        &emit_state,
                        i,
                        node,
                        source_file_id,
                    );
                },
            }
        }

        if (emit_state.pending_trailing_sourcemap_blank and emit_state.has_output) {
            try emit.writeAll("\n");
        }

        if (output_style == .compressed) {
            compress_buf = compress_aw.toArrayList();
            if (compress_buf.items.len > 0) {
                const compressed = try compressCss(temp, compress_buf.items);

                // Emit UTF-8 BOM if compressed output contains non-ASCII characters
                if (renderedNeedsCharset(compressed)) {
                    try writer.writeAll("\xEF\xBB\xBF");
                }
                try writer.writeAll(compressed);
                try writer.writeAll("\n");
            }
            compress_buf.deinit(std.heap.page_allocator);
        }
    }

    const InlineComment = struct {
        idx: usize,
        text: []const u8,
    };

    fn nextRenderableNodeIndex(nodes: []const Node, skip_flags: []const bool, start: usize) ?usize {
        var j = start + 1;
        while (j < nodes.len) : (j += 1) {
            if (skip_flags[j]) continue;
            if (isRuleIRGroupSeparatorKind(nodes[j].kind)) continue;
            return j;
        }
        return null;
    }

    fn previousRenderableNodeIndex(nodes: []const Node, skip_flags: []const bool, start: usize) ?usize {
        var j = start;
        while (j > 0) {
            j -= 1;
            if (skip_flags[j]) continue;
            if (isRuleIRGroupSeparatorKind(nodes[j].kind)) continue;
            return j;
        }
        return null;
    }

    fn nextRenderableNodeWithin(
        nodes: []const Node,
        skip_flags: []const bool,
        start: usize,
        end_exclusive: usize,
    ) ?usize {
        var j = start;
        while (j < end_exclusive) : (j += 1) {
            if (skip_flags[j]) continue;
            if (isRuleIRGroupSeparatorKind(nodes[j].kind)) continue;
            return j;
        }
        return null;
    }

    fn ruleBodiesReuseSameSourceShape(
        self_ir: *const RuleIR,
        skip_flags: []const bool,
        lhs_begin: usize,
        lhs_end: usize,
        rhs_begin: usize,
        rhs_end: usize,
    ) bool {
        var li = lhs_begin + 1;
        var ri = rhs_begin + 1;

        while (true) {
            const left_idx = nextRenderableNodeWithin(self_ir.nodes.items, skip_flags, li, lhs_end) orelse {
                return nextRenderableNodeWithin(self_ir.nodes.items, skip_flags, ri, rhs_end) == null;
            };
            const right_idx = nextRenderableNodeWithin(self_ir.nodes.items, skip_flags, ri, rhs_end) orelse return false;

            const left = self_ir.nodes.items[left_idx];
            const right = self_ir.nodes.items[right_idx];
            if (left.kind != right.kind) return false;
            if (left.source_start != right.source_start or left.source_end != right.source_end) return false;

            const left_file: u32 = if (left_idx < self_ir.node_source_files.items.len) self_ir.node_source_files.items[left_idx] else 0;
            const right_file: u32 = if (right_idx < self_ir.node_source_files.items.len) self_ir.node_source_files.items[right_idx] else 0;
            if (left_file != right_file) return false;

            li = left_idx + 1;
            ri = right_idx + 1;
        }
    }

    fn normalizeUnterminatedBlockCommentForEmit(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]const u8 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.findScalar(u8, trimmed, '\n') == null and
            std.mem.startsWith(u8, trimmed, "/*  * ") and
            std.mem.endsWith(u8, trimmed, "  */"))
        {
            const inner = trimmed["/*  * ".len .. trimmed.len - "  */".len];
            return std.fmt.allocPrint(allocator, "/*\n * {s}\n */", .{inner});
        }
        if (!std.mem.startsWith(u8, trimmed, "/*")) return text;
        const has_closing = std.mem.endsWith(u8, trimmed, "*/");
        const body_for_check = if (has_closing) trimmed[2 .. trimmed.len - 2] else trimmed[2..];

        // Single-line block comments without a line break in the body stay compact.
        if (std.mem.findScalar(u8, body_for_check, '\n') == null) {
            if (has_closing) return text;
            const payload = std.mem.trim(u8, body_for_check, " \t");
            if (payload.len == 0) return allocator.dupe(u8, "/* */");
            return std.fmt.allocPrint(allocator, "/* {s} */", .{payload});
        }

        // "Normal" block comments with multiple lines and closing `*/` are kept verbatim by the official Sass CLI
        // (`/*\n * X\n */` is output as is). The old implementation was "first line blank and payload 1 line"
        // It was collapsed to `/* X \n * */`, which incorrectly merged the first line.
        // This function is only for repairing **unterminated** block comment (`has_closing=false`)
        // and in the case of has_closing=true, text is returned as is without reformat.
        if (has_closing) return text;

        const ContentLine = struct {
            content: []const u8,
            indent: usize,
            is_blank: bool,
        };

        var lines: std.ArrayListUnmanaged(ContentLine) = .empty;
        defer lines.deinit(allocator);

        var line_it = std.mem.splitScalar(u8, trimmed, '\n');
        const first_line_raw = line_it.next() orelse return text;
        const first_line = std.mem.trimEnd(u8, first_line_raw, "\r");
        if (!std.mem.startsWith(u8, first_line, "/*")) return text;
        const first_payload = std.mem.trimStart(u8, first_line[2..], " \t");
        const has_initial_content = first_payload.len > 0;

        while (line_it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const content = std.mem.trimStart(u8, line, " \t");
            if (std.mem.trimEnd(u8, content, " \t").len == 0) {
                try lines.append(allocator, .{
                    .content = "",
                    .indent = 0,
                    .is_blank = true,
                });
                continue;
            }

            var indent: usize = 0;
            while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
            try lines.append(allocator, .{
                .content = std.mem.trimEnd(u8, content, " \t"),
                .indent = indent,
                .is_blank = false,
            });
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        if (has_initial_content) {
            try out.appendSlice(allocator, "/* ");
            try out.appendSlice(allocator, std.mem.trimEnd(u8, first_payload, " \t"));
        } else {
            try out.appendSlice(allocator, "/*");
            var first_emitted = false;
            try out.ensureUnusedCapacity(allocator, lines.items.len * 3 + 1);
            for (lines.items) |line| {
                if (line.is_blank) {
                    if (first_emitted) out.appendSliceAssumeCapacity("\n *");
                    continue;
                }
                try out.ensureUnusedCapacity(allocator, 1 + line.content.len);
                out.appendAssumeCapacity(' ');
                out.appendSliceAssumeCapacity(line.content);
                first_emitted = true;
                break;
            }
            if (!first_emitted) {
                try out.appendSlice(allocator, " */");
                return out.toOwnedSlice(allocator);
            }
        }

        var start_idx: usize = 0;
        if (!has_initial_content) {
            while (start_idx < lines.items.len and lines.items[start_idx].is_blank) : (start_idx += 1) {}
            if (start_idx < lines.items.len and !lines.items[start_idx].is_blank) start_idx += 1;
        }

        for (lines.items[start_idx..]) |line| {
            if (line.is_blank) {
                try out.appendSlice(allocator, "\n *");
                continue;
            }
            try out.appendSlice(allocator, "\n *");
            const extra = if (line.indent > 2) line.indent - 2 else 0;
            const num_spaces = @max(@as(usize, 1), extra);
            try out.appendNTimes(allocator, ' ', num_spaces);
            try out.appendSlice(allocator, line.content);
        }

        try out.appendSlice(allocator, " */");
        return out.toOwnedSlice(allocator);
    }

    fn normalizeCommentTextForEmit(
        allocator: std.mem.Allocator,
        raw_text: []const u8,
    ) ![]const u8 {
        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        errdefer normalized.deinit(allocator);
        {
            var k: usize = 0;
            while (k < raw_text.len) : (k += 1) {
                const c = raw_text[k];
                if (c == '\r') {
                    try normalized.append(allocator, '\n');
                    if (k + 1 < raw_text.len and raw_text[k + 1] == '\n') {
                        k += 1;
                    }
                } else if (c == '\x0c') {
                    try normalized.append(allocator, '\n');
                } else {
                    try normalized.append(allocator, c);
                }
            }
        }
        var text: []const u8 = try normalized.toOwnedSlice(allocator);
        const normalized_comment_text = try normalizeUnterminatedBlockCommentForEmit(allocator, text);
        if (normalized_comment_text.ptr != text.ptr) {
            text = normalized_comment_text;
        }
        return text;
    }

    fn isEmptyBlockCommentText(text: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < 4) return false;
        if (!std.mem.startsWith(u8, trimmed, "/*")) return false;
        if (!std.mem.endsWith(u8, trimmed, "*/")) return false;
        const inner = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n");
        return inner.len == 0;
    }

    fn inlineCommentAfter(
        self_ir: *const RuleIR,
        intern_pool_: *const InternPool,
        skip_flags: []bool,
        allocator: std.mem.Allocator,
        source_locations_: ?[]const SourceLocation,
        start: usize,
        same_line_only: bool,
    ) !?InlineComment {
        const next_idx = nextRenderableNodeIndex(self_ir.nodes.items, skip_flags, start) orelse return null;
        const next_node = self_ir.nodes.items[next_idx];
        if (next_node.kind != .comment) return null;
        // Resolver records whether a non-whitespace token is on the same line just before `/*`.
        // Determine with ast.source backward scan and via appendCommentWithColAndLeading
        // Save bool in extra[payload + 2]. This is @import inline expansion (module_id and actual
        // REAL source line judgment that is not affected by file offset (asymmetry).
        // In old heuristic (line_starts comparison + byte gap), use ` } /* */` under @import
        // Treat `;\n /* */` on separate lines (false negative) or on the same line (false positive)
        // The old heuristic produced false positives and false negatives.
        const leading_slot = next_node.payload + 2;
        const has_leading_flag = leading_slot < self_ir.extra.items.len;
        const leading_same_line = has_leading_flag and self_ir.extra.items[leading_slot] != 0;
        if (source_locations_) |locs| {
            _ = locs;
            // In shadow copy route (`@use` inside `@import`),
            // Even if file_id from `load_css_module_tag_override` exceeds `locs.len`,
            // If node_file == comment_file, it comes from the same module, so it is judged as inline and OK.
            // `locs` does not perform indexing, so bounds check only needs to be done on the node_source_files side.
            if (start >= self_ir.node_source_files.items.len or next_idx >= self_ir.node_source_files.items.len) return null;
            const node_file = self_ir.node_source_files.items[start];
            const comment_file = self_ir.node_source_files.items[next_idx];
            if (node_file != comment_file) return null;
            if (!leading_same_line) return null;
        } else if (same_line_only) {
            // Old route (unit test appendComment with span {0,0}): no source_locations.
            // leading_same_line defaults to false when ast.source is unknown, so old behavior
            // Keep (returns null).
            return null;
        }
        const text_id = self_ir.extra.items[next_node.payload];
        const raw_text = intern_pool_.get(@enumFromInt(text_id));
        const text = try normalizeCommentTextForEmit(allocator, raw_text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "/*") and std.mem.endsWith(u8, trimmed, "*/")) {
            const inner = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n");
            if (std.mem.startsWith(u8, inner, "# sourceMappingURL=") or std.mem.startsWith(u8, inner, "# sourceURL=")) {
                return null;
            }
        }
        if (std.mem.findScalar(u8, text, '\n') != null) return null;
        return .{ .idx = next_idx, .text = text };
    }

    fn inlineCommentAfterOpeningBraceHeuristic(
        self_ir: *const RuleIR,
        intern_pool_: *const InternPool,
        skip_flags: []bool,
        allocator: std.mem.Allocator,
        source_locations_: ?[]const SourceLocation,
        start: usize,
        min_col: u32,
    ) !?InlineComment {
        _ = min_col;
        _ = source_locations_ orelse return null;
        const next_idx = nextRenderableNodeIndex(self_ir.nodes.items, skip_flags, start) orelse return null;
        const next_node = self_ir.nodes.items[next_idx];
        if (next_node.kind != .comment) return null;
        if (start >= self_ir.node_source_files.items.len or next_idx >= self_ir.node_source_files.items.len) return null;
        const node_file = self_ir.node_source_files.items[start];
        const comment_file = self_ir.node_source_files.items[next_idx];
        // file_id of shadow copy route (`@use` inside `@import`) can exceed
        // `source_locations.len` but is the same module if node_file == comment_file.
        if (node_file != comment_file) return null;

        // Determined based on `leading_same_line` flag calculated by resolver.
        // The old heuristic was a source line/col comparison, but @import inline compares module_id and actual
        // If file offset is asymmetric, parent line_starts cannot interpret child offset
        // lie (`[type=checkbox] {\n\n /* checkbox aspect */\n}` becomes `{ /* ... */ }`
        // erroneously inlined). `leading_same_line` directs ast.source
        // REAL source judgment that is not affected by lie because it is determined by scanning.
        const leading_slot = next_node.payload + 2;
        const leading_same_line = leading_slot < self_ir.extra.items.len and self_ir.extra.items[leading_slot] != 0;
        if (!leading_same_line) return null;

        const text_id = self_ir.extra.items[next_node.payload];
        const raw_text = intern_pool_.get(@enumFromInt(text_id));
        const text = try normalizeCommentTextForEmit(allocator, raw_text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "/*") and std.mem.endsWith(u8, trimmed, "*/")) {
            const inner = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n");
            if (std.mem.startsWith(u8, inner, "# sourceMappingURL=") or std.mem.startsWith(u8, inner, "# sourceURL=")) {
                return null;
            }
        }
        if (std.mem.findScalar(u8, text, '\n') != null) return null;
        return .{ .idx = next_idx, .text = text };
    }

    fn appendUniqueSelector(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged([]const u8),
        selector: []const u8,
    ) !bool {
        if (selector.len == 0) return false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, selector)) return false;
        }
        try out.append(allocator, selector);
        return true;
    }

    fn singleExtendTargetCompound(complex: *const selector_mod.ComplexSelector) ?selector_mod.CompoundSelector {
        var found: ?selector_mod.CompoundSelector = null;
        for (complex.components.items) |comp| {
            switch (comp) {
                .compound => |compound| {
                    if (found != null) return null;
                    found = compound;
                },
                .combinator => return null,
            }
        }
        return found;
    }

    fn complexContainsTargetCompound(
        complex: *const selector_mod.ComplexSelector,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        for (complex.components.items) |comp| {
            switch (comp) {
                .compound => |compound| {
                    if (extend_mod.compoundContainsTarget(&compound, target)) return true;
                    if (compoundContainsTargetCompoundInPseudos(&compound, target)) return true;
                },
                .combinator => {},
            }
        }
        return false;
    }

    fn compoundContainsTargetCompoundInPseudos(
        compound: *const selector_mod.CompoundSelector,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        for (compound.simple_selectors.items) |ss| {
            switch (ss) {
                .pseudo_class => |ps| {
                    const inner = ps.selector orelse continue;
                    for (inner.selectors.items) |inner_complex| {
                        if (complexContainsTargetCompound(&inner_complex, target)) return true;
                    }
                },
                .pseudo_element => |ps| {
                    const inner = ps.selector orelse continue;
                    for (inner.selectors.items) |inner_complex| {
                        if (complexContainsTargetCompound(&inner_complex, target)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn selectorRawContainsTargetCompound(
        allocator: std.mem.Allocator,
        selector_raw: []const u8,
        target: *const selector_mod.CompoundSelector,
    ) bool {
        const attr_normalized = css_utils.normalizeAttributeSelectors(allocator, selector_raw) catch return false;
        var selector_text = attr_normalized;
        var selector_owned: ?[]const u8 = null;
        defer if (selector_owned) |owned| allocator.free(owned);
        if (!(attr_normalized.ptr == selector_raw.ptr and attr_normalized.len == selector_raw.len)) {
            selector_owned = attr_normalized;
        }
        const comments_stripped = stripSelectorCommentsForMatching(allocator, selector_text) catch return false;
        if (!(comments_stripped.ptr == selector_text.ptr and comments_stripped.len == selector_text.len)) {
            if (selector_owned) |owned| allocator.free(owned);
            selector_text = comments_stripped;
            selector_owned = comments_stripped;
        }

        var parsed = selector_mod.parse(allocator, selector_text) catch return false;
        defer parsed.deinit();
        for (parsed.selectors.items) |complex| {
            if (complexContainsTargetCompound(&complex, target)) return true;
        }
        return false;
    }

    fn moduleHasRawTargetCompound(
        self_ir: *const RuleIR,
        allocator: std.mem.Allocator,
        intern_pool: *const InternPool,
        module_id: u32,
        target: *const selector_mod.CompoundSelector,
        rule_nodes_by_module: []const std.ArrayListUnmanaged(u32),
        normalized_parse_cache: *std.AutoHashMapUnmanaged(InternId, ?*selector_mod.SelectorList),
        module_simple_presence: []const ModuleSimplePresence,
    ) bool {
        const dump_debug = std.c.getenv("ZSASS_DEBUG_EXTEND_MATCH") != null;
        if (module_id < rule_nodes_by_module.len) {
            if (module_id < module_simple_presence.len) {
                if (modulePresenceKnowsSimpleTarget(&module_simple_presence[@intCast(module_id)], target)) |known| {
                    return known;
                }
                if (!modulePresenceMayContainTarget(&module_simple_presence[@intCast(module_id)], target)) {
                    return false;
                }
            }
            const rule_nodes = rule_nodes_by_module[@intCast(module_id)];
            for (rule_nodes.items) |node_idx_u32| {
                const idx: usize = @intCast(node_idx_u32);
                const node = self_ir.nodes.items[idx];
                const selector_id = self_ir.extra.items[node.payload];
                const selector_intern: InternId = @enumFromInt(selector_id);
                const parsed = getOrParseNormalizedCached(normalized_parse_cache, allocator, intern_pool, selector_intern) orelse continue;
                const matched = selectorListContainsTargetCompound(parsed, target);
                if (dump_debug) {
                    const selector_raw = intern_pool.get(selector_intern);
                    ruleIrStderrPrint("moduleHasRawTargetCompound mod={d} idx={d} selector_raw={s} matched={any}\n", .{ module_id, idx, selector_raw, matched });
                }
                if (matched) return true;
            }
            return false;
        }
        // Defensive fallback for out-of-range/sentinel module ids.
        for (self_ir.nodes.items, 0..) |node, idx| {
            if (node.kind != .rule_begin) continue;
            const node_module: u32 = if (idx < self_ir.node_source_files.items.len) self_ir.node_source_files.items[idx] else 0;
            if (node_module != module_id) continue;
            if (node_module < module_simple_presence.len and
                modulePresenceKnowsSimpleTarget(&module_simple_presence[@intCast(node_module)], target) != null)
            {
                return modulePresenceKnowsSimpleTarget(&module_simple_presence[@intCast(node_module)], target).?;
            }
            if (node_module < module_simple_presence.len and
                !modulePresenceMayContainTarget(&module_simple_presence[@intCast(node_module)], target))
            {
                return false;
            }
            const selector_id = self_ir.extra.items[node.payload];
            const selector_intern: InternId = @enumFromInt(selector_id);
            const parsed = getOrParseNormalizedCached(normalized_parse_cache, allocator, intern_pool, selector_intern) orelse continue;
            const matched = selectorListContainsTargetCompound(parsed, target);
            if (dump_debug) {
                const selector_raw = intern_pool.get(selector_intern);
                ruleIrStderrPrint("moduleHasRawTargetCompound mod={d} idx={d} selector_raw={s} matched={any}\n", .{ module_id, idx, selector_raw, matched });
            }
            if (matched) return true;
        }
        return false;
    }

    fn rangeContainsExtendTarget(
        allocator: std.mem.Allocator,
        intern_pool: *const InternPool,
        nodes: []const Node,
        node_source_files: []const u32,
        extra: []const u32,
        edge: ExtendEdge,
    ) bool {
        const target_raw = intern_pool.get(edge.target_selector);
        if (target_raw.len == 0) return false;

        var parsed_target_opt: ?selector_mod.SelectorList = selector_mod.parse(allocator, target_raw) catch null;
        defer if (parsed_target_opt) |*parsed_target| parsed_target.deinit();

        var target_compound_opt: ?selector_mod.CompoundSelector = null;
        if (parsed_target_opt) |*parsed_target| {
            if (parsed_target.selectors.items.len != 0) {
                target_compound_opt = singleExtendTargetCompound(&parsed_target.selectors.items[0]);
            }
        }

        for (nodes, 0..) |node, idx| {
            if (node.kind != .rule_begin) continue;
            const node_module: u32 = if (idx < node_source_files.len) node_source_files[idx] else 0;
            if (node_module != edge.target_module) continue;
            const selector_id = extra[node.payload];
            const selector_raw = intern_pool.get(@enumFromInt(selector_id));
            if (selectorRawContainsPseudoTarget(selector_raw, target_raw)) return true;
            if (target_compound_opt) |target_compound| {
                if (selectorRawContainsTargetCompound(allocator, selector_raw, &target_compound)) return true;
            }
        }

        return false;
    }

    fn compoundIsSelectorPseudoTarget(target: *const selector_mod.CompoundSelector) bool {
        if (target.simple_selectors.items.len != 1) return false;
        return switch (target.simple_selectors.items[0]) {
            .pseudo_class => |ps| ps.selector != null,
            .pseudo_element => |ps| ps.selector != null,
            else => false,
        };
    }

    fn validateExtendTargetBranch(allocator: std.mem.Allocator, target_branch: []const u8) !void {
        const trimmed = std.mem.trim(u8, target_branch, " \t\r\n");
        if (trimmed.len == 0) return error.SassError;

        // VM currently stores @extend selector text as raw text.
        // unresolved interpolation is deferred until dynamic selector support lands.
        if (containsUnresolvedSelectorInterpolation(trimmed)) return;

        var parsed = selector_mod.parse(allocator, trimmed) catch return error.SassError;
        defer parsed.deinit();
        if (selector_mod.hasParentReference(&parsed)) return error.SassError;
        if (parsed.selectors.items.len == 0) return error.SassError;

        for (parsed.selectors.items) |complex| {
            const target = singleExtendTargetCompound(&complex) orelse return error.SassError;
            if (target.simple_selectors.items.len != 1) return error.SassError;
        }
    }

    fn containsUnresolvedSelectorInterpolation(selector_text: []const u8) bool {
        return std.mem.find(u8, selector_text, "#{") != null;
    }

    fn normalizeRuntimeExtendTargetText(raw_target: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, raw_target, " \t\r\n");
        if (trimmed.len == 0) return error.SassError;

        const first_break = std.mem.findAny(u8, trimmed, "\r\n") orelse return trimmed;
        const first_line = std.mem.trim(u8, trimmed[0..first_break], " \t");
        if (first_line.len == 0) return error.SassError;

        // parser's @extend span can include sibling lines with indented syntax.
        // Example: `@extend a` immediately followed by `e: f` at the same level becomes `a\n e: f`.
        // Only the first line is used for same-level pollution, and indented continuation (>1 level) under @extend is
        // Treat as SassError.
        var i: usize = first_break;
        while (i < trimmed.len) {
            while (i < trimmed.len and (trimmed[i] == '\n' or trimmed[i] == '\r')) : (i += 1) {}
            const line_start = i;
            while (i < trimmed.len and trimmed[i] != '\n' and trimmed[i] != '\r') : (i += 1) {}
            const line = trimmed[line_start..i];
            const line_trimmed = std.mem.trim(u8, line, " \t");
            if (line_trimmed.len == 0) continue;
            if (leadingIndentColumns(line) > 2) return error.SassError;
            break;
        }
        return first_line;
    }

    fn leadingIndentColumns(line: []const u8) usize {
        var cols: usize = 0;
        for (line) |c| {
            switch (c) {
                ' ' => cols += 1,
                '\t' => cols += 4,
                else => break,
            }
        }
        return cols;
    }

    fn shouldSuppressExtendingSelector(allocator: std.mem.Allocator, extending_branch: []const u8) !bool {
        var parsed = selector_mod.parse(allocator, extending_branch) catch return true;
        defer parsed.deinit();
        if (selector_mod.hasParentReference(&parsed)) return true;

        for (parsed.selectors.items) |complex| {
            if (isBogusExtenderComplex(&complex)) return true;
        }
        return false;
    }

    fn isBogusExtenderComplex(complex: *const selector_mod.ComplexSelector) bool {
        if (complex.components.items.len == 0) return true;

        var compound_count: usize = 0;
        var prev_non_desc: bool = false;
        for (complex.components.items) |comp| {
            switch (comp) {
                .compound => {
                    compound_count += 1;
                    prev_non_desc = false;
                },
                .combinator => |comb| {
                    if (comb != .descendant) {
                        if (prev_non_desc) return true;
                        prev_non_desc = true;
                    } else {
                        prev_non_desc = false;
                    }
                },
            }
        }

        if (compound_count == 0) return true;
        const last = complex.components.items[complex.components.items.len - 1];
        if (last == .combinator and last.combinator != .descendant) return true;
        return false;
    }

    fn splitSelectorList(
        allocator: std.mem.Allocator,
        selector_list: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var cursor: usize = 0;
        while (nextSelectorListPart(selector_list, &cursor)) |part| {
            try out.append(allocator, part);
        }
    }

    fn joinSelectorList(allocator: std.mem.Allocator, selectors: []const []const u8) ![]const u8 {
        return joinSelectorListWithSeparator(allocator, selectors, ", ");
    }

    fn joinSelectorListPreservingOriginalSeparators(
        allocator: std.mem.Allocator,
        original_selector: []const u8,
        selectors: []const []const u8,
    ) ![]const u8 {
        const joined = try joinSelectorList(allocator, selectors);
        const preserved = try selector_helpers_mod.preserveOriginalSelectorCommaNewlinesAlloc(
            allocator,
            original_selector,
            joined,
        );
        if (preserved.ptr == joined.ptr and preserved.len == joined.len) return joined;
        allocator.free(joined);
        return preserved;
    }

    fn joinSelectorListWithSeparator(
        allocator: std.mem.Allocator,
        selectors: []const []const u8,
        separator: []const u8,
    ) ![]const u8 {
        if (selectors.len == 0) return allocator.dupe(u8, "");
        if (selectors.len == 1) return allocator.dupe(u8, selectors[0]);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        for (selectors, 0..) |sel, i| {
            if (i != 0) try out.appendSlice(allocator, separator);
            try out.appendSlice(allocator, sel);
        }
        return out.toOwnedSlice(allocator);
    }

    fn normalizeNumericAttributeQuotes(allocator: std.mem.Allocator, selector: []const u8) ![]const u8 {
        if (std.mem.find(u8, selector, "='") == null) return selector;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        var changed = false;
        var i: usize = 0;
        while (i < selector.len) {
            if (i + 2 < selector.len and selector[i] == '=' and selector[i + 1] == '\'') {
                var j = i + 2;
                while (j < selector.len and selector[j] != '\'') : (j += 1) {}
                if (j < selector.len) {
                    const value = selector[i + 2 .. j];
                    if (attributeValueNeedsCssString(value)) {
                        if (std.mem.findScalar(u8, value, '"') != null and
                            std.mem.findScalar(u8, value, '\'') == null)
                        {
                            try out.appendSlice(allocator, selector[i .. j + 1]);
                            i = j + 1;
                            continue;
                        }
                        try out.append(allocator, '=');
                        try out.append(allocator, '"');
                        try out.appendSlice(allocator, value);
                        try out.append(allocator, '"');
                        i = j + 1;
                        changed = true;
                        continue;
                    }
                }
            }
            try out.append(allocator, selector[i]);
            i += 1;
        }
        if (!changed) return selector;
        return out.toOwnedSlice(allocator);
    }

    fn attributeValueNeedsCssString(value: []const u8) bool {
        if (value.len == 0) return true;
        if (isCssIdentifierForAttribute(value)) return false;
        return true;
    }

    fn isCssIdentifierForAttribute(value: []const u8) bool {
        if (value.len == 0) return false;
        const first = value[0];
        if (!std.ascii.isAlphabetic(first) and first != '_' and first < 128) {
            if (first == '-') {
                if (value.len < 2) return false;
                const second = value[1];
                if (!std.ascii.isAlphabetic(second) and second != '_' and second < 128 and second != '-') return false;
            } else {
                return false;
            }
        }
        for (value[1..]) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch >= 128)) return false;
        }
        return true;
    }

    fn getNodeSelectorText(
        self_ir: *const RuleIR,
        node_idx: usize,
        selector_override: []const ?[]const u8,
        intern_pool: *const InternPool,
    ) []const u8 {
        if (node_idx < selector_override.len) {
            if (selector_override[node_idx]) |sel| return sel;
        }
        const node = self_ir.nodes.items[node_idx];
        return intern_pool.get(@enumFromInt(self_ir.extra.items[node.payload]));
    }

    fn isSimplePlaceholderSelector(sel: []const u8) bool {
        const t = std.mem.trim(u8, sel, " \t\r\n");
        if (t.len < 2 or t[0] != '%') return false;
        for (t[1..]) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') continue;
            return false;
        }
        return true;
    }

    fn selectorContainsPlaceholder(sel: []const u8) bool {
        var i: usize = 0;
        while (i < sel.len) : (i += 1) {
            if (sel[i] != '%') continue;
            if (i + 1 >= sel.len) continue;
            const c = sel[i + 1];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') return true;
        }
        return false;
    }

    fn cleanedSelectorWithoutPlaceholders(
        allocator: std.mem.Allocator,
        selector: []const u8,
    ) !?[]const u8 {
        const trimmed = trimSelectorPartPreserveEscapedSpace(selector);
        if (trimmed.len == 0) return null;
        if (!selectorContainsPlaceholder(trimmed)) return trimmed;

        const cleaned = try placeholder_prune_mod.removePlaceholderParts(allocator, trimmed);
        const cleaned_trimmed = trimSelectorPartPreserveEscapedSpace(cleaned);
        if (cleaned_trimmed.len == 0) return null;
        if (selectorContainsPlaceholder(cleaned_trimmed)) return null;
        return cleaned_trimmed;
    }

    fn shouldPreserveRawSelectorWithoutExtend(sel: []const u8) bool {
        if (selectorListHasExactDuplicateBranches(sel)) return true;
        if (std.mem.find(u8, sel, "\\ ") != null) return true;

        // css/selector attribute cases: quoted "--foo" must retain quote.
        if (std.mem.find(u8, sel, "\"--") != null or std.mem.find(u8, sel, "'--") != null) {
            return true;
        }

        // Capitalization of Attribute selector modifier (e.g. [a=b I]) is case-sensitive.
        var i: usize = 0;
        while (i + 2 < sel.len) : (i += 1) {
            if (sel[i] != ' ') continue;
            if (!std.ascii.isUpper(sel[i + 1])) continue;
            if (sel[i + 2] == ']') return true;
        }
        return false;
    }

    fn selectorListHasExactDuplicateBranches(sel: []const u8) bool {
        var cursor: usize = 0;
        while (nextSelectorListPart(sel, &cursor)) |part| {
            var inner_cursor = cursor;
            while (nextSelectorListPart(sel, &inner_cursor)) |other| {
                if (std.mem.eql(u8, part, other)) return true;
            }
        }
        return false;
    }

    fn trimSelectorPartPreserveEscapedSpace(seg: []const u8) []const u8 {
        var start: usize = 0;
        while (start < seg.len and selectorPartIsWs(seg[start])) : (start += 1) {}

        var end: usize = seg.len;
        while (end > start and selectorPartIsWs(seg[end - 1])) {
            const idx = end - 1;
            if (isEscapedTrailingSelectorSpace(seg, idx)) break;
            end -= 1;
        }
        return seg[start..end];
    }

    fn selectorPartIsWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }

    fn isEscapedTrailingSelectorSpace(seg: []const u8, space_idx: usize) bool {
        if (seg[space_idx] != ' ' or space_idx == 0) return false;
        var backslashes: usize = 0;
        var i = space_idx;
        while (i > 0 and seg[i - 1] == '\\') : (i -= 1) {
            backslashes += 1;
        }
        return (backslashes & 1) == 1;
    }

    fn nextSelectorListPart(selector_list: []const u8, cursor: *usize) ?[]const u8 {
        while (cursor.* < selector_list.len) {
            const start = cursor.*;
            var depth_paren: i32 = 0;
            var depth_bracket: i32 = 0;
            var i = start;
            while (i < selector_list.len) : (i += 1) {
                switch (selector_list[i]) {
                    '(' => depth_paren += 1,
                    ')' => {
                        if (depth_paren > 0) depth_paren -= 1;
                    },
                    '[' => depth_bracket += 1,
                    ']' => {
                        if (depth_bracket > 0) depth_bracket -= 1;
                    },
                    ',' => {
                        if (depth_paren == 0 and depth_bracket == 0) {
                            cursor.* = i + 1;
                            const part = trimSelectorPartPreserveEscapedSpace(selector_list[start..i]);
                            if (part.len != 0) return part;
                            break;
                        }
                    },
                    else => {},
                }
            } else {
                cursor.* = selector_list.len;
                const tail = trimSelectorPartPreserveEscapedSpace(selector_list[start..]);
                if (tail.len != 0) return tail;
            }
        }
        return null;
    }

    fn sourceOffsetToLineCol(loc: SourceLocation, offset: u32) struct { line: u32, col: u32 } {
        if (loc.line_starts.len == 0) return .{ .line = 0, .col = 0 };
        const clamped = @min(offset, loc.source_len);
        var lo: usize = 0;
        var hi: usize = loc.line_starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (loc.line_starts[mid] <= clamped) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        const line_start = loc.line_starts[lo];
        return .{
            .line = @intCast(lo),
            .col = clamped - line_start,
        };
    }
};

test "rule_ir minimal build + serialize" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".foo");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 4 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 5, .end = 15 });
    try ir.appendRuleEnd(allocator, .{ .start = 15, .end = 16 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".foo {\n  color: red;\n}\n", buf.items);
}

test "rule_ir writer drops explicit charset when output is ASCII only" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const charset_name = try pool.intern("charset");
    const utf8 = try pool.intern("\"UTF-8\"");
    const sel = try pool.intern(".a");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, charset_name, utf8, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".a {\n  color: red;\n}\n", buf.items);
}

test "rule_ir writer emits charset for non-ascii declaration names" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop = try pool.intern("\xE2\x80\x82background");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("@charset \"UTF-8\";\n.a {\n  \xE2\x80\x82background: red;\n}\n", buf.items);
}

test "rule_ir writer collapses repeated top-level selector spaces" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".hide:hover  .child,\n.hide:active .child");
    const prop = try pool.intern("opacity");
    const val = try pool.intern("1");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".hide:hover .child,\n.hide:active .child {\n  opacity: 1;\n}\n", buf.items);
}

test "rule_ir writer spaces selector-list pseudo arguments" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a :is(h1,h2,h3), .b:has(>h1,>h2)");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".a :is(h1, h2, h3), .b:has(> h1, > h2) {\n  x: y;\n}\n", buf.items);
}

test "rule_ir writer preserves multiline selector-list pseudo arguments" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("body :where(svg.a,\n\tsvg.b,\n\tsvg.c)");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("body :where(svg.a,\nsvg.b,\nsvg.c) {\n  x: y;\n}\n", buf.items);
}

test "rule_ir writer compacts nth-child An+B spacing" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a:nth-child(n+ 2), .b:nth-last-child( -n + 3 ), .c:nth-of-type(2n + 1)");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".a:nth-child(n+2), .b:nth-last-child(-n+3), .c:nth-of-type(2n + 1) {\n  x: y;\n}\n", buf.items);
}

test "rule_ir writer keeps explicit empty non-conditional at-rule block" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const foo = try pool.intern("foo");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, foo, null, 0, true, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("@foo {}\n", buf.items);
}

test "rule_ir writer suppresses explicit empty @media block by default" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const prelude = try pool.intern("screen");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, media, prelude, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("", buf.items);
}

test "rule_ir writer keeps explicit empty @layer block when requested" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const layer = try pool.intern("layer");
    const prelude = try pool.intern("components");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, layer, prelude, 0, true, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("@layer components {}\n", buf.items);
}

test "rule_ir writer normalizes multiline comment indentation" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".foo");
    const comment = try pool.intern("/* Foo\r\n   Bar\n  Baz */");
    const prop = try pool.intern("a");
    const val = try pool.intern("b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".foo {\n" ++
            "  /* Foo\n" ++
            "   Bar\n" ++
            "  Baz */\n" ++
            "  a: b;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer strips source indentation from nested multiline comment" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("div a");
    const comment = try pool.intern(
        "/**\n" ++
            "     * a\n" ++
            "     * multiline\n" ++
            "     * comment\n" ++
            "     */",
    );
    const prop = try pool.intern("top");
    const val = try pool.intern("10px");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "div a {\n" ++
            "  /**\n" ++
            "   * a\n" ++
            "   * multiline\n" ++
            "   * comment\n" ++
            "   */\n" ++
            "  top: 10px;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer recovers leaked indented declaration property into block" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const leaked_prop = try pool.intern("a\n  b");
    const val = try pool.intern("c");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendDecl(allocator, @intFromEnum(leaked_prop), @intFromEnum(val), .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "a {\n" ++
            "  b: c;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer recovers leaked @supports prelude with indented body" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const supports = try pool.intern("supports");
    const prelude = try pool.intern("(a\n  b)\n  c\n    d: e");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, supports, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@supports (a\n" ++
            "  b) {\n" ++
            "  c {\n" ++
            "    d: e;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer normalizes leaked @supports negation prelude" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const supports = try pool.intern("supports");
    const prelude = try pool.intern("(not\n  (a))\n  b\n    c: d");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, supports, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@supports not (a) {\n" ++
            "  b {\n" ++
            "    c: d;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer leaked @supports emits bare at-rule line as statement" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const supports = try pool.intern("supports");
    const prelude = try pool.intern("((a: b) and\n  (c: d))\n  @d");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, supports, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@supports (a: b) and (c: d) {\n" ++
            "  @d;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer normalizes supports clause in @import prelude" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const import_name = try pool.intern("import");
    const prelude = try pool.intern("\"a.css\" supports(\n  a: b)");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, import_name, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@import \"a.css\" supports(a: b);\n",
        buf.items,
    );
}

test "rule_ir appendAtRuleSimpleMaybeHoisted hoists top-level import before rules" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("a");
    const prop = try pool.intern("b");
    const val = try pool.intern("c");
    const import_name = try pool.intern("import");
    const import_prelude = try pool.intern("\"late.css\"");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleSimpleMaybeHoisted(allocator, &pool, import_name, import_prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    // The official Sass CLI does not put blank between top-level `@import` and
    // the immediately following rule. Hoist helper Synthetic IR follows the same behavior.
    try std.testing.expectEqualStrings(
        "@import \"late.css\";\n" ++
            "a {\n" ++
            "  b: c;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer drops empty selector list entries from multiline raw selector" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("#foo #bar,,\n,#baz #boom,");
    const prop = try pool.intern("a");
    const val = try pool.intern("b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "#foo #bar,\n" ++
            "#baz #boom {\n" ++
            "  a: b;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer rejects invalid attribute selector modifier" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("[a=b 1]");
    const prop = try pool.intern("c");
    const val = try pool.intern("d");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf = w.toArrayList();

    try std.testing.expectError(error.SassError, ir.writeTo(&w.writer, &pool));
}

test "rule_ir writer does not reinterpret leaked prelude for unknown at-rule" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const unknown = try pool.intern("asdf");
    const prelude = try pool.intern("foo\n  bar");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, unknown, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@asdf foo\n" ++
            "  bar;\n",
        buf.items,
    );
}

test "rule_ir writer normalizes colon prelude spacing for simple unknown at-rule" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const unknown = try pool.intern("asset-path");
    const prelude = try pool.intern(":   \"/fonts\"");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, unknown, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("@asset-path : \"/fonts\";\n", buf.items);
}

test "rule_ir writer decl_raw custom property preserves colon spacing from raw value" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop_no_space = try pool.intern("--x");
    const prop_with_space = try pool.intern("--y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDeclRaw(allocator, @intFromEnum(prop_no_space), "value", .{ .start = 0, .end = 0 });
    try ir.appendDeclRaw(allocator, @intFromEnum(prop_with_space), " value", .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  --x:value;\n" ++
            "  --y: value;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer uses marked source column for imported multiline custom properties" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const prelude = try pool.intern("(prefers-color-scheme: dark)");
    const sel = try pool.intern(".search-ui");
    const prop = try pool.intern("--component-shadow");
    const value = try std.fmt.allocPrint(
        allocator,
        " {s}4;0 10px 25px -5px rgba(0, 0, 0, 0.5),\n      0 8px 10px -6px rgba(0, 0, 0, 0.5)",
        .{opcode_mod.custom_property_source_col_marker},
    );
    defer allocator.free(value);

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, media, prelude, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDeclRaw(allocator, @intFromEnum(prop), value, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@media (prefers-color-scheme: dark) {\n" ++
            "  .search-ui {\n" ++
            "    --component-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5),\n" ++
            "      0 8px 10px -6px rgba(0, 0, 0, 0.5);\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer dedents imported custom property continuation at declaration column" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".card-list[class*=cols] > .card");
    const prop = try pool.intern("--card-border-color");
    const value = try std.fmt.allocPrint(
        allocator,
        " {s}4;none\n    border-radius: 0",
        .{opcode_mod.custom_property_source_col_marker},
    );
    defer allocator.free(value);

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDeclRaw(allocator, @intFromEnum(prop), value, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(try pool.intern("margin")), @intFromEnum(try pool.intern("0")), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".card-list[class*=cols] > .card {\n" ++
            "  --card-border-color: none\n" ++
            "  border-radius: 0;\n" ++
            "  margin: 0;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer normalizes declaration value whitespace and special function casing" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const p1 = try pool.intern("b");
    const v1 = try pool.intern("URL(\n  c)");
    const p2 = try pool.intern("c");
    const v2 = try pool.intern("TYPE(0)");
    const p3 = try pool.intern("d");
    const v3 = try pool.intern("fn(x,\n  y)");
    const p4 = try pool.intern("e");
    const v4 = try pool.intern("fn(x /\n  y)");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(p1), @intFromEnum(v1), .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(p2), @intFromEnum(v2), .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(p3), @intFromEnum(v3), .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(p4), @intFromEnum(v4), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  b: url(c);\n" ++
            "  c: type(0);\n" ++
            "  d: fn(x, y);\n" ++
            "  e: fn(x/y);\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer strips selector comments before emit" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("a /***/ b");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("a b {\n  x: y;\n}\n", buf.items);
}

test "rule_ir writer keeps decl trailing comment inline" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop = try pool.intern("b");
    const val = try pool.intern("c");
    const comment = try pool.intern("/* tail */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  b: c; /* tail */\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps comment between declarations on its own line" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop1 = try pool.intern("b");
    const val1 = try pool.intern("c");
    const prop2 = try pool.intern("d");
    const val2 = try pool.intern("e");
    const comment = try pool.intern("/* split */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop1), @intFromEnum(val1), .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop2), @intFromEnum(val2), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  b: c;\n" ++
            "  /* split */\n" ++
            "  d: e;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer inserts blank before top-level loud comment after style rule" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");
    const comment = try pool.intern("/* utility\n */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  x: y;\n" ++
            "}\n" ++
            "\n" ++
            "/* utility\n" ++
            " */\n" ++
            ".b {\n" ++
            "  x: y;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps loud comment compact after nested emitted rule" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern(".a .b");
    const sel_b = try pool.intern(".c");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");
    const comment = try pool.intern("/* utility\n */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a .b {\n" ++
            "  x: y;\n" ++
            "}\n" ++
            "/* utility\n" ++
            " */\n" ++
            ".c {\n" ++
            "  x: y;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer suppresses blank before compiler reopen rule" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_after = try pool.intern(".a::after");
    const sel_a = try pool.intern(".a");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_after), 1, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendStmtGap(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0, .file_id = 2 });
    ir.setOriginReopenAt(ir.nodes.items.len - 1, true);
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a::after {\n" ++
            "  x: y;\n" ++
            "}\n" ++
            ".a {\n" ++
            "  x: y;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer merges adjacent comment-only reopen rules" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".code-block");
    const comment_a = try pool.intern("/* leading note */");
    const comment_b = try pool.intern("/* trailing note */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    ir.setOriginReopenAt(ir.nodes.items.len - 1, true);
    try ir.appendComment(allocator, comment_a, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    ir.setOriginReopenAt(ir.nodes.items.len - 1, true);
    try ir.appendComment(allocator, comment_b, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".code-block {\n" ++
            "  /* leading note */\n" ++
            "  /* trailing note */\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps at-rule open-block comment before nested rule on its own line" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const at_name = try pool.intern("media");
    const prelude = try pool.intern("screen");
    const sel = try pool.intern(".a");
    const comment = try pool.intern("/* lead */");
    const prop = try pool.intern("b");
    const val = try pool.intern("c");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, at_name, prelude, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@media screen {\n" ++
            "  /* lead */\n" ++
            "  .a {\n" ++
            "    b: c;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps non-empty comment-only rule multiline" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const comment = try pool.intern("/* lead */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  /* lead */\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps leading rule comment before decl multiline" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const comment = try pool.intern("/* lead */");
    const prop = try pool.intern("b");
    const val = try pool.intern("c");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  /* lead */\n" ++
            "  b: c;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps empty-comment-only rule multiline" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("a");
    const comment = try pool.intern("/**/");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "a {\n" ++
            "  /**/\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps bang comment closer flush left" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const comment = try pool.intern("/*!\n*/");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("/*!\n*/\n", buf.items);
}

test "rule_ir writer keeps plain comment closer aligned in nested block" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const comment = try pool.intern("/*\n  line\n  */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  /*\n" ++
            "  line\n" ++
            "  */\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer strips tab-indented block comment continuation without adding star padding" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const comment = try pool.intern("/*\n\t\t * tabstar\n\t\t */");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendCommentWithCol(allocator, comment, .{ .start = 0, .end = 0 }, 4);
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        ".a {\n" ++
            "  /*\n" ++
            "  * tabstar\n" ++
            "  */\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer keeps selector attribute quotes when no @extend edges" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern("[class=\"--foo\"], [class*=\"--foo\"]");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "[class=\"--foo\"], [class*=\"--foo\"] {\n" ++
            "  x: y;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer normalizes unterminated indented loud comment" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const comment = try pool.intern("/*\n  foo\n  bar\n");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "/* foo\n" ++
            " * bar */\n",
        buf.items,
    );
}

test "rule_ir writer normalizes indented loud comment variants" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const closed = try pool.intern("/* \n  a */");
    const closed_after = try pool.intern("/* \n  a \n  */");
    const open_inline = try pool.intern("/* a");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendComment(allocator, closed, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, closed_after, .{ .start = 0, .end = 0 });
    try ir.appendComment(allocator, open_inline, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    // official Sass CLI keeps properly terminated block comments verbatim, so
    // A multi-line with "1st line blank, payload 1 line" like `/* \n a */` will not collapse.
    // Output as is; the old collapse path incorrectly merged the first line.
    try std.testing.expectEqualStrings(
        "/* \n" ++
            "  a */\n" ++
            "/* \n" ++
            "  a \n" ++
            "  */\n" ++
            "/* a */\n",
        buf.items,
    );
}

test "rule_ir writer strips source map comments and keeps leading blank gap" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const comment = try pool.intern("/*# sourceMappingURL=whatever */");
    const sel = try pool.intern(".a");
    const prop = try pool.intern("b");
    const val = try pool.intern("c");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendComment(allocator, comment, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "\n" ++
            ".a {\n" ++
            "  b: c;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer preserves prepared media prelude" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const prelude = try pool.intern("(a) and (b)");
    const sel = try pool.intern("x");
    const prop = try pool.intern("y");
    const val = try pool.intern("z");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, media, prelude, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@media (a) and (b) {\n" ++
            "  x {\n" ++
            "    y: z;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir normalizeNestedMediaRuleIR merges nested media preludes" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const p1 = try pool.intern("only screen");
    const p2 = try pool.intern("(color)");
    const p3 = try pool.intern("(orientation: portrait)");
    const p4 = try pool.intern("all");
    const p5 = try pool.intern("(min-width: 42em)");
    const sel = try pool.intern(".foo");
    const prop = try pool.intern("content");
    const val = try pool.intern("bar");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleBegin(allocator, media, p1, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleBegin(allocator, media, p2, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleBegin(allocator, media, p3, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendStmtGap(allocator, .{ .start = 0, .end = 0 });

    try ir.appendAtRuleBegin(allocator, media, p4, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleBegin(allocator, media, p5, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.normalizeNestedMediaRuleIR(allocator, &pool);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    // The official sass CLI 1.99.0 emits no blank between merge-hoisted
    // top-level @media blocks.
    try std.testing.expectEqualStrings(
        "@media only screen and (color) and (orientation: portrait) {\n" ++
            "  .foo {\n" ++
            "    content: bar;\n" ++
            "  }\n" ++
            "}\n" ++
            "@media (min-width: 42em) {\n" ++
            "  .foo {\n" ++
            "    content: bar;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir normalizeNestedMediaRuleIR emits outer declarations before nested media" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const min_width = try pool.intern("(min-width: 1px)");
    const min_height = try pool.intern("(min-height: 2px)");
    const sel_parent = try pool.intern(".a");
    const sel_child = try pool.intern(".b");
    const prop_x = try pool.intern("x");
    const val_y = try pool.intern("y");
    const prop_z = try pool.intern("z");
    const val_w = try pool.intern("w");
    const prop_q = try pool.intern("q");
    const val_r = try pool.intern("r");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_parent), 0, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleBegin(allocator, media, min_width, 1, false, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleBegin(allocator, media, min_height, 0, false, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop_x), @intFromEnum(val_y), .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop_z), @intFromEnum(val_w), .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_child), 1, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop_q), @intFromEnum(val_r), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.normalizeNestedMediaRuleIR(allocator, &pool);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(
        "@media (min-width: 1px) {\n" ++
            "  .a {\n" ++
            "    z: w;\n" ++
            "  }\n" ++
            "}\n" ++
            "@media (min-width: 1px) and (min-height: 2px) {\n" ++
            "  .a {\n" ++
            "    x: y;\n" ++
            "  }\n" ++
            "}\n" ++
            "@media (min-width: 1px) {\n" ++
            "  .a .b {\n" ++
            "    q: r;\n" ++
            "  }\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir writer suppresses malformed multiline @media simple prelude" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const media = try pool.intern("media");
    const prelude = try pool.intern("(a:\n  b)");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendAtRuleSimple(allocator, media, prelude, .{ .start = 0, .end = 0 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("", buf.items);
}

test "rule_ir merge extend: direct + transitive" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_bar = try pool.intern(".bar");
    const sel_foo = try pool.intern(".foo");
    const sel_baz = try pool.intern(".baz");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_bar), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_foo), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_baz), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_foo, sel_bar, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_baz, sel_foo, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".bar, .foo, .baz {\n  color: red;\n}\n", buf.items);
}

test "rule_ir merge extend: placeholder target stays hidden" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_placeholder = try pool.intern("%foo");
    const sel_bar = try pool.intern(".bar");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_placeholder), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_bar), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_bar, sel_placeholder, false, true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".bar {\n  color: red;\n}\n", buf.items);
}

test "rule_ir merge extend: compound replacement" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_compound = try pool.intern(".a.b");
    const sel_ext = try pool.intern(".x");
    const sel_target = try pool.intern(".b");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_compound), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_ext, sel_target, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".a.b, .a.x {\n  color: red;\n}\n", buf.items);
}

test "rule_ir merge extend: compound cross-product includes transitive unify branch" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_rule = try pool.intern(".a.b");
    const sel_x = try pool.intern(".x");
    const sel_y = try pool.intern(".y");
    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_rule), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_x, sel_a, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_y, sel_b, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    const brace_idx_opt = std.mem.findScalar(u8, buf.items, '{');
    try std.testing.expect(brace_idx_opt != null);
    const brace_idx = brace_idx_opt.?;
    const selector_header = std.mem.trim(u8, buf.items[0..brace_idx], " \t\r\n");
    var branches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer branches.deinit(allocator);
    try RuleIR.splitSelectorList(allocator, selector_header, &branches);

    try std.testing.expectEqual(@as(usize, 4), branches.items.len);
    try std.testing.expect(containsSelectorBranch(branches.items, ".a.b"));
    try std.testing.expect(containsSelectorBranchAny(branches.items, &.{ ".a.y", ".y.a" }));
    try std.testing.expect(containsSelectorBranchAny(branches.items, &.{ ".b.x", ".x.b" }));
    try std.testing.expect(containsSelectorBranchAny(branches.items, &.{ ".x.y", ".y.x" }));
}

test "rule_ir merge extend: cycle remains finite and includes transitive selectors" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");
    const sel_c = try pool.intern(".c");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_c), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_a, sel_b, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_b, sel_a, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_c, sel_a, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    const brace_idx_opt = std.mem.findScalar(u8, buf.items, '{');
    try std.testing.expect(brace_idx_opt != null);
    const brace_idx = brace_idx_opt.?;
    const selector_header = std.mem.trim(u8, buf.items[0..brace_idx], " \t\r\n");
    var branches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer branches.deinit(allocator);
    try RuleIR.splitSelectorList(allocator, selector_header, &branches);

    try std.testing.expectEqual(@as(usize, 3), branches.items.len);
    try std.testing.expect(containsSelectorBranch(branches.items, ".a"));
    try std.testing.expect(containsSelectorBranch(branches.items, ".b"));
    try std.testing.expect(containsSelectorBranch(branches.items, ".c"));
}

test "rule_ir append extend relation: complex/compound target is rejected" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_extending = try pool.intern(".x");
    const sel_complex_target = try pool.intern("a b");
    const sel_compound_target = try pool.intern("a:hover");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try std.testing.expectError(
        error.SassError,
        ir.appendExtendRelation(allocator, &pool, sel_extending, sel_complex_target, false, false),
    );
    try std.testing.expectError(
        error.SassError,
        ir.appendExtendRelation(allocator, &pool, sel_extending, sel_compound_target, false, false),
    );
}

test "rule_ir append extend relation: unresolved interpolation target is deferred" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_extending = try pool.intern(".container");
    const sel_interp_target = try pool.intern("%responsive-container-#{$breakpoint}");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_extending), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_extending, sel_interp_target, false, false);
    try std.testing.expectEqual(@as(usize, 1), ir.extend_edges.items.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(".container {\n  color: red;\n}\n", buf.items);
}

test "rule_ir append extend relation: indented trailing sibling lines are ignored" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_extending = try pool.intern("d");
    const sel_contaminated_target = try pool.intern("a\n  e: f");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendExtendRelation(allocator, &pool, sel_extending, sel_contaminated_target, false, false);
    try std.testing.expectEqual(@as(usize, 1), ir.extend_edges.items.len);
    try std.testing.expectEqualStrings("a", pool.get(ir.extend_edges.items[0].target_selector));
}

test "rule_ir append extend relation: indented comma continuation keeps only first selector branch" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_extending = try pool.intern("g");
    const sel_contaminated_target = try pool.intern("a,\n  d");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendExtendRelation(allocator, &pool, sel_extending, sel_contaminated_target, false, false);
    try std.testing.expectEqual(@as(usize, 1), ir.extend_edges.items.len);
    try std.testing.expectEqualStrings("a", pool.get(ir.extend_edges.items[0].target_selector));
}

test "rule_ir append extend relation: indented nested line under @extend is rejected" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_extending = try pool.intern("d");
    const sel_invalid_target = try pool.intern("a\n    b\n  e: f");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try std.testing.expectError(
        error.SassError,
        ir.appendExtendRelation(allocator, &pool, sel_extending, sel_invalid_target, false, false),
    );
}

test "rule_ir append extend relation: bogus extender selector is ignored" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern("a");
    const sel_bogus = try pool.intern("+ ~ d");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_bogus, sel_a, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("a {\n  color: red;\n}\n", buf.items);
}

test "rule_ir merge extend: :is pseudo keeps direct + transitive variants" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_upstream = try pool.intern("upstream");
    const sel_is_midstream = try pool.intern(":is(midstream)");
    const sel_downstream = try pool.intern("downstream");
    const sel_midstream = try pool.intern("midstream");
    const prop = try pool.intern("a");
    const val = try pool.intern("b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_upstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_is_midstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_downstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_is_midstream, sel_upstream, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_downstream, sel_midstream, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("upstream, :is(midstream), :is(midstream, downstream) {\n  a: b;\n}\n", buf.items);
}

test "rule_ir merge extend: :where pseudo keeps direct + transitive variants" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_upstream = try pool.intern("upstream");
    const sel_where_midstream = try pool.intern(":where(midstream)");
    const sel_downstream = try pool.intern("downstream");
    const sel_midstream = try pool.intern("midstream");
    const prop = try pool.intern("a");
    const val = try pool.intern("b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_upstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_where_midstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_downstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_where_midstream, sel_upstream, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_downstream, sel_midstream, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("upstream, :where(midstream), :where(midstream, downstream) {\n  a: b;\n}\n", buf.items);
}

test "rule_ir merge extend: :not pseudo keeps direct + transitive variants" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_upstream = try pool.intern("upstream");
    const sel_not_midstream = try pool.intern(":not(midstream)");
    const sel_downstream = try pool.intern("downstream");
    const sel_midstream = try pool.intern("midstream");
    const prop = try pool.intern("a");
    const val = try pool.intern("b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_upstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_not_midstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_downstream), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_not_midstream, sel_upstream, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_downstream, sel_midstream, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("upstream, :not(midstream):not(downstream) {\n  a: b;\n}\n", buf.items);
}

test "rule_ir merge extend: result of :not extend remains extendable" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_not_c = try pool.intern(":not(.c)");
    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");
    const sel_c = try pool.intern(".c");
    const sel_not_b = try pool.intern(":not(.b)");
    const prop = try pool.intern("x");
    const val = try pool.intern("y");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_not_c), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_a, sel_not_b, false, false);
    try ir.appendExtendRelation(allocator, &pool, sel_b, sel_c, false, false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings(":not(.c):not(.b), .a:not(.c) {\n  x: y;\n}\n", buf.items);
}

test "rule_ir merge extend: pseudo selector with placeholder stays suppressed" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_placeholder = try pool.intern("%foo");
    const sel_is_placeholder = try pool.intern(":is(%foo)");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_placeholder), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_is_placeholder), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    try ir.appendExtendRelation(allocator, &pool, sel_is_placeholder, sel_placeholder, false, true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    try std.testing.expectEqualStrings("", buf.items);
}

test "rule_ir writeToWithSourceMap emits v3 mappings" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 2, .file_id = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 5, .end = 15, .file_id = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 16, .end = 17, .file_id = 0 });

    const line_starts = [_]u32{0};
    const source_locs = [_]SourceLocation{.{
        .source_path = "/tmp/input.scss",
        .line_starts = &line_starts,
        .source_len = 18,
    }};

    var sm = source_map_mod.SourceMap.init(allocator);
    defer sm.deinit();

    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(allocator);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &css);
        try ir.writeToWithSourceMap(&aw.writer, &pool, &sm, &source_locs, .expanded, .{});
        css = aw.toArrayList();
    }
    try std.testing.expectEqualStrings(".a {\n  color: red;\n}\n", css.items);

    const json = try sm.toJsonAlloc(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"version\":3") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"sources\":[\"/tmp/input.scss\"]") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"mappings\":\"") != null);
}

fn expectNodeKindsForTest(ir: *const RuleIR, expected: []const NodeKind) !void {
    try std.testing.expectEqual(expected.len, ir.nodes.items.len);
    for (expected, 0..) |kind, idx| {
        try std.testing.expectEqual(kind, ir.nodes.items[idx].kind);
    }
}

fn findRuleBeginIndexForTest(ir: *const RuleIR, pool: *const InternPool, selector: []const u8) ?usize {
    for (ir.nodes.items, 0..) |node, idx| {
        if (node.kind != .rule_begin) continue;
        const selector_id: InternId = @enumFromInt(ir.extra.items[node.payload]);
        if (std.mem.eql(u8, pool.get(selector_id), selector)) return idx;
    }
    return null;
}

test "rule_ir hoistTopLevelCssImportsRuleIR hoists import and inserts group boundary" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");
    const import_name = try pool.intern("import");
    const import_prelude = try pool.intern("\"x.css\"");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendStmtGap(allocator, .{ .start = 0, .end = 0 });
    try ir.appendAtRuleSimple(allocator, import_name, import_prelude, .{ .start = 0, .end = 0 });

    const DummyEval = struct {
        allocator: std.mem.Allocator,
        env: struct {
            intern_pool: *InternPool,
        },
    };
    const dummy = DummyEval{
        .allocator = allocator,
        .env = .{ .intern_pool = &pool },
    };

    try ir.hoistTopLevelCssImportsRuleIR(dummy);

    try expectNodeKindsForTest(&ir, &.{ .at_rule_simple, .group_boundary, .rule_begin, .decl, .rule_end });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }
    // official Sass CLI does not put blank between top-level `@import` and the rule immediately after it.
    // group_boundary remains as a byproduct of hoist, but on the writer side prev_visible_is_top_import
    // Prevent blank insertion based on the judgment.
    try std.testing.expectEqualStrings("@import \"x.css\";\n.a {\n  color: red;\n}\n", buf.items);
}

test "rule_ir appendAtRuleSimpleMaybeHoisted keeps current-file leading comments before import and later-file trailing comments after it" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const import_name = try pool.intern("import");
    const import_a = try pool.intern("\"a.css\"");
    const import_b = try pool.intern("\"b.css\"");
    const import_c = try pool.intern("\"c.css\"");
    const lead = try pool.intern("/* lead */");
    const before_a = try pool.intern("/* before a */");
    const after_a = try pool.intern("/* after a */");
    const before_b = try pool.intern("/* before b */");
    const after_b = try pool.intern("/* after b */");
    const before_c = try pool.intern("/* before c */");
    const sel = try pool.intern(".rule");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendComment(allocator, lead, .{ .start = 0, .end = 0, .file_id = 0 });
    try ir.appendComment(allocator, before_a, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendAtRuleSimpleMaybeHoisted(allocator, &pool, import_name, import_a, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendComment(allocator, after_a, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendComment(allocator, before_b, .{ .start = 0, .end = 0, .file_id = 2 });
    try ir.appendAtRuleSimpleMaybeHoisted(allocator, &pool, import_name, import_b, .{ .start = 0, .end = 0, .file_id = 2 });
    try ir.appendComment(allocator, after_b, .{ .start = 0, .end = 0, .file_id = 2 });
    try ir.appendComment(allocator, before_c, .{ .start = 0, .end = 0, .file_id = 3 });
    try ir.appendAtRuleSimpleMaybeHoisted(allocator, &pool, import_name, import_c, .{ .start = 0, .end = 0, .file_id = 3 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0, .file_id = 3 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0, .file_id = 3 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0, .file_id = 3 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }

    // official Sass CLI does not put a blank line before the rule immediately after comment (comment is ``attached'' to the next rule)
    // treatment). The old legacy behavior included fallback blank, but this implementation uses pending_blank
    // There is no blank line because comment-before-rule is suppressed in the base.
    try std.testing.expectEqualStrings(
        "/* lead */\n" ++
            "/* before a */\n" ++
            "@import \"a.css\";\n" ++
            "/* before b */\n" ++
            "@import \"b.css\";\n" ++
            "/* before c */\n" ++
            "@import \"c.css\";\n" ++
            "/* after a */\n" ++
            "/* after b */\n" ++
            ".rule {\n" ++
            "  color: red;\n" ++
            "}\n",
        buf.items,
    );
}

test "rule_ir suppressLeadingBlankAfterTopLevelImportsRuleIR marks first top-level block" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const import_name = try pool.intern("import");
    const import_prelude = try pool.intern("\"x.css\"");
    const sel = try pool.intern(".a");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendAtRuleSimple(allocator, import_name, import_prelude, .{ .start = 0, .end = 0 });
    try ir.appendGroupBoundary(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    ir.suppressLeadingBlankAfterTopLevelImportsRuleIR(&pool);

    const rule_idx = findRuleBeginIndexForTest(&ir, &pool, ".a") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ir.getSuppressLeadingBlankAt(rule_idx));
}

test "rule_ir normalizeTopLevelGroupBoundariesRuleIR preserves sourcemap gaps and drops plain leading boundary" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel = try pool.intern(".a");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendGroupBoundary(allocator, .{ .start = 0, .end = 0 });
    try ir.appendSourcemapGap(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendGroupBoundary(allocator, .{ .start = 0, .end = 0 });
    try ir.appendSourcemapGap(allocator, .{ .start = 0, .end = 0 });

    const DummyEval = struct {
        allocator: std.mem.Allocator,
        env: struct {
            intern_pool: *InternPool,
        },
    };
    const dummy = DummyEval{
        .allocator = allocator,
        .env = .{ .intern_pool = &pool },
    };

    try ir.normalizeTopLevelGroupBoundariesRuleIR(dummy);

    try expectNodeKindsForTest(&ir, &.{ .sourcemap_gap, .rule_begin, .decl, .rule_end, .sourcemap_gap });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }
    try std.testing.expectEqualStrings("\n.a {\n  color: red;\n}\n\n", buf.items);
}

test "rule_ir propagateStmtGapSuppressionRuleIR propagates across style-only segment" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    const a_idx = findRuleBeginIndexForTest(&ir, &pool, ".a") orelse return error.TestUnexpectedResult;
    ir.setSuppressFollowingStmtGapBlankAt(a_idx, true);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    try ir.appendStmtGap(allocator, .{ .start = 0, .end = 0 });

    ir.propagateStmtGapSuppressionRuleIR();

    const b_idx = findRuleBeginIndexForTest(&ir, &pool, ".b") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ir.getSuppressFollowingStmtGapBlankAt(a_idx));
    try std.testing.expect(ir.getSuppressFollowingStmtGapBlankAt(b_idx));
}

test "rule_ir stripTopLevelGroupBoundariesRuleIR removes separators and propagates leading suppression" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_a = try pool.intern(".a");
    const sel_b = try pool.intern(".b");
    const prop = try pool.intern("color");
    const val_a = try pool.intern("red");
    const val_b = try pool.intern("blue");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_a), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val_a), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });
    const a_idx = findRuleBeginIndexForTest(&ir, &pool, ".a") orelse return error.TestUnexpectedResult;
    ir.setSuppressFollowingStmtGapBlankAt(a_idx, true);
    try ir.appendStmtGap(allocator, .{ .start = 0, .end = 0 });
    try ir.appendGroupBoundary(allocator, .{ .start = 0, .end = 0 });
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_b), 0, .{ .start = 0, .end = 0 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val_b), .{ .start = 0, .end = 0 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0 });

    ir.stripTopLevelGroupBoundariesRuleIR();

    try expectNodeKindsForTest(&ir, &.{ .rule_begin, .decl, .rule_end, .rule_begin, .decl, .rule_end });
    const b_idx = findRuleBeginIndexForTest(&ir, &pool, ".b") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ir.getSuppressLeadingBlankAt(b_idx));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try ir.writeTo(&w.writer, &pool);
    }
    try std.testing.expectEqualStrings(".a {\n  color: red;\n}\n.b {\n  color: blue;\n}\n", buf.items);
}

test "rule_ir renderFlushRange preserves cross-module extend visibility" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_target = try pool.intern(".target");
    const sel_a = try pool.intern(".a");
    const sel_c = try pool.intern(".c");
    const prop = try pool.intern("color");
    const val = try pool.intern("red");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_target), 0, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val), .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0, .file_id = 1 });

    try ir.appendExtendRelationScoped(allocator, &pool, sel_a, sel_target, false, false, 0, 1, 1, null);
    try ir.appendExtendRelationScoped(allocator, &pool, sel_c, sel_a, false, false, 1, 1, 2, null);

    try std.testing.expectError(error.SassError, ir.renderFlushRange(allocator, &pool, .{
        .start = 0,
        .end = ir.nodes.items.len,
    }, null));

    const visibility = try allocator.alloc(bool, 4);
    defer allocator.free(visibility);
    @memset(visibility, false);
    visibility[0] = true;
    visibility[1] = true;
    visibility[2] = true;
    visibility[3] = true;
    ir.module_visibility_matrix = visibility;
    ir.module_visibility_n = 2;

    const rendered = try ir.renderFlushRange(allocator, &pool, .{
        .start = 0,
        .end = ir.nodes.items.len,
    }, null);
    defer allocator.free(rendered.css);
    defer if (rendered.tmp_range_nodes) |buf| allocator.free(buf);
    defer if (rendered.tmp_range_node_source_files) |buf| allocator.free(buf);

    const selector_end = std.mem.indexOf(u8, rendered.css, " {") orelse return error.TestUnexpectedResult;
    const first_line = rendered.css[0..selector_end];
    var branches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer branches.deinit(allocator);
    try RuleIR.splitSelectorList(allocator, first_line, &branches);

    try std.testing.expect(containsSelectorBranch(branches.items, ".target"));
    try std.testing.expect(containsSelectorBranch(branches.items, ".a"));
}

test "rule_ir renderFlushRange ignores unrelated extend groups outside flushed range" {
    const allocator = std.testing.allocator;
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    const sel_target = try pool.intern(".target");
    const sel_a = try pool.intern(".a");
    const sel_item = try pool.intern(".item");
    const sel_left = try pool.intern(".left");
    const prop = try pool.intern("color");
    const val_red = try pool.intern("red");
    const val_blue = try pool.intern("blue");

    var ir = RuleIR.init();
    defer ir.deinit(allocator);

    try ir.appendRuleBegin(allocator, @intFromEnum(sel_target), 0, .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val_red), .{ .start = 0, .end = 0, .file_id = 1 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0, .file_id = 1 });

    const second_rule_start = ir.nodes.items.len;
    try ir.appendRuleBegin(allocator, @intFromEnum(sel_item), 0, .{ .start = 0, .end = 0, .file_id = 2 });
    try ir.appendDecl(allocator, @intFromEnum(prop), @intFromEnum(val_blue), .{ .start = 0, .end = 0, .file_id = 2 });
    try ir.appendRuleEnd(allocator, .{ .start = 0, .end = 0, .file_id = 2 });

    try ir.appendExtendRelationScoped(allocator, &pool, sel_a, sel_target, false, false, 1, 1, 1, null);
    try ir.appendExtendRelationScoped(allocator, &pool, sel_left, sel_item, false, false, 2, 2, 2, null);

    const rendered = try ir.renderFlushRange(allocator, &pool, .{
        .start = 0,
        .end = second_rule_start,
    }, null);
    defer allocator.free(rendered.css);
    defer if (rendered.tmp_range_nodes) |buf| allocator.free(buf);
    defer if (rendered.tmp_range_node_source_files) |buf| allocator.free(buf);

    const selector_end = std.mem.indexOf(u8, rendered.css, " {") orelse return error.TestUnexpectedResult;
    const first_line = rendered.css[0..selector_end];
    var branches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer branches.deinit(allocator);
    try RuleIR.splitSelectorList(allocator, first_line, &branches);

    try std.testing.expect(containsSelectorBranch(branches.items, ".target"));
    try std.testing.expect(containsSelectorBranch(branches.items, ".a"));
    try std.testing.expect(!containsSelectorBranch(branches.items, ".left"));
}

test "rule_ir hasNestedCalcInDeclValue true for any nested calc" {
    try std.testing.expect(hasNestedCalcInDeclValue("calc(calc(var(--x, 10px) * 0.7) * 4)"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(calc(var(--x, 10px) * 0.7) / 1.5)"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(1rem + calc(var(--w) * 2))"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(calc(var(--x) / 2) * 1.5)"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(1rem * calc(1 - var(--x)))"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(3rem + calc(1.5em + 0.75rem))"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(calc(1.5em + 0.75rem) + 3rem)"));
    try std.testing.expect(hasNestedCalcInDeclValue("calc(calc(1.5em + 0.75rem))"));
}

test "rule_ir hasNestedCalcInDeclValue false for no nested calc" {
    try std.testing.expect(!hasNestedCalcInDeclValue("calc(1rem + var(--w) * 2)"));
    try std.testing.expect(!hasNestedCalcInDeclValue("calc(1.5em + 0.75rem)"));
    try std.testing.expect(!hasNestedCalcInDeclValue("1rem"));
}

fn containsSelectorBranch(branches: []const []const u8, needle: []const u8) bool {
    for (branches) |branch| {
        if (std.mem.eql(u8, branch, needle)) return true;
    }
    return false;
}

fn containsSelectorBranchAny(branches: []const []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsSelectorBranch(branches, needle)) return true;
    }
    return false;
}
