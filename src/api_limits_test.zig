//! Resource limits, cancellation, and the file import policy, through the
//! embedding API. Deep or large inputs are generated here rather than
//! stored in the repository.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const zsass_io = @import("runtime/io.zig");

const compile = api.compileSourceToCss;

fn repeat(alloc: std.mem.Allocator, parts: []const []const u8, counts: []const usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, counts) |part, n| {
        for (0..n) |_| try out.appendSlice(alloc, part);
    }
    return out.toOwnedSlice(alloc);
}

fn nestedParens(alloc: std.mem.Allocator, depth: usize) ![]u8 {
    return repeat(alloc, &.{ "a{x:", "(", "1", ")", ";}" }, &.{ 1, depth, 1, depth, 1 });
}

fn nestedRules(alloc: std.mem.Allocator, depth: usize) ![]u8 {
    return repeat(alloc, &.{ "a{", "x:y;", "}" }, &.{ depth, 1, depth });
}

fn independentExtends(alloc: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(alloc, ".a{d} ", .{i});
    try out.appendSlice(alloc, "{x:y}\n");
    for (0..n) |i| try out.print(alloc, ".x{d} {{@extend .a{d}}}\n", .{ i, i });
    return out.toOwnedSlice(alloc);
}

fn writeFile(dir: std.Io.Dir, rel_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| try dir.createDirPath(zsass_io.io, parent);
    const file = try dir.createFile(zsass_io.io, rel_path, .{ .truncate = true });
    defer file.close(zsass_io.io);
    var buf: [4096]u8 = undefined;
    var w = file.writerStreaming(zsass_io.io, &buf);
    try w.interface.writeAll(bytes);
    try w.flush();
}

fn tmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return zsass_io.realPathAlloc(tmp.dir, ".", alloc);
}

const quiet: api.CompileOptions = .{ .quiet = true };

fn withLimits(limits: api.CompileLimits) api.CompileOptions {
    var opts = quiet;
    opts.limits = limits;
    return opts;
}

// ---------------------------------------------------------------------
// Syntax nesting
// ---------------------------------------------------------------------

test "limits: parentheses nest up to the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const limit = 64;
    // The rule's block is one level, each parenthesis one more, and the
    // number inside them one more.
    const fits = try nestedParens(a, limit - 2);
    _ = try compile(a, fits, "", &.{}, withLimits(.{ .max_syntax_depth = limit }));
    const too_deep = try nestedParens(a, limit - 1);
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, too_deep, "", &.{}, withLimits(.{ .max_syntax_depth = limit })));
}

test "limits: nested rules stop at the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = withLimits(.{ .max_syntax_depth = 40 });
    // Each block is one level and the declaration's value one more.
    _ = try compile(a, try nestedRules(a, 39), "", &.{}, opts);
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, try nestedRules(a, 40), "", &.{}, opts));
}

test "limits: the default bound stops the reported crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 16000 parentheses and 8000 rules overflowed the native stack.
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, try nestedParens(a, 16000), "", &.{}, quiet));
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, try nestedRules(a, 8000), "", &.{}, quiet));
}

test "limits: chains of operators count as nesting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const chain = try repeat(a, &.{ "a{x:1", "+1", ";}" }, &.{ 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, chain, "", &.{}, quiet));
    const unary = try repeat(a, &.{ "a{x:", "- ", "1;}" }, &.{ 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, unary, "", &.{}, quiet));
    const short = try repeat(a, &.{ "a{x:1", "+1", ";}" }, &.{ 1, 100, 1 });
    const css = try compile(a, short, "", &.{}, quiet);
    try std.testing.expectEqualStrings("a {\n  x: 101;\n}\n", css);
}

test "limits: interpolation and selector arguments are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const interp = try repeat(a, &.{ "a{x:", "#{", "1", "}", ";}" }, &.{ 1, 20000, 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, interp, "", &.{}, quiet));
    const in_selector = try repeat(a, &.{ "#{", "a", "}", "{x:y}" }, &.{ 20000, 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, in_selector, "", &.{}, quiet));
    // A selector built at run time is parsed by the selector parser.
    const pseudo = try repeat(a, &.{ "@use \"sass:selector\";a{x:selector.parse(\"", ":is(", "b", ")", "\")}" }, &.{ 1, 20000, 1, 20000, 1 });
    try std.testing.expectError(error.NestingLimit, compile(a, pseudo, "", &.{}, quiet));
}

test "limits: values nested at run time are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "$l: 1; @for $i from 1 through 100000 { $l: [$l]; } a { x: inspect($l); }";
    try std.testing.expectError(error.NestingLimit, compile(a, src, "", &.{}, quiet));
    const shallow = "$l: 1; @for $i from 1 through 3 { $l: [$l]; } a { x: inspect($l); }";
    try std.testing.expectEqualStrings("a {\n  x: [[[1]]];\n}\n", try compile(a, shallow, "", &.{}, quiet));
}

test "limits: nesting in a loaded module counts against the same limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_deep.scss", try nestedRules(a, 41));
    try writeFile(tmp.dir, "_imported.scss", try nestedRules(a, 41));
    const root = try tmpPath(a, &tmp);
    const entry = try std.fs.path.join(a, &.{ root, "entry.scss" });
    const opts = withLimits(.{ .max_syntax_depth = 40 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, "@use \"deep\";", entry, &.{}, opts));
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, "@import \"imported\";", entry, &.{}, opts));
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, "@use \"sass:meta\"; a { @include meta.load-css(\"deep\"); }", entry, &.{}, opts));
}

// ---------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------

test "limits: an endless loop in a function stops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "@function spin() { @while true {} @return 1; } a { x: spin(); }";
    try std.testing.expectError(error.ExecutionLimit, compile(a, src, "", &.{}, withLimits(.{ .max_vm_steps = 100_000 })));
}

test "limits: endless and huge top-level loops stop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = withLimits(.{ .max_vm_steps = 1_000_000, .max_ir_nodes = 10_000 });
    const endless = compile(a, "@while true {}", "", &.{}, opts);
    try std.testing.expect(endless == error.ExecutionLimit or endless == error.IrNodeLimit);
    const huge = compile(a, "@for $i from 1 through 1000000000 {}", "", &.{}, opts);
    try std.testing.expect(huge == error.ExecutionLimit or huge == error.IrNodeLimit);
    const rules = compile(a, "@for $i from 1 through 1000000 { a { b: $i; } }", "", &.{}, withLimits(.{ .max_ir_nodes = 10_000 }));
    try std.testing.expectError(error.IrNodeLimit, rules);
}

const CancelAfter = struct {
    calls: usize = 0,
    after: usize,
    fn check(ctx: ?*anyopaque) bool {
        const self: *CancelAfter = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return self.calls > self.after;
    }
};

test "limits: cancellation stops finite work and is otherwise invisible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "$n: 0; @for $i from 1 through 50000 { $n: $n + 1; } a { x: $n; }";
    var cancel: CancelAfter = .{ .after = 3 };
    var opts = quiet;
    opts.cancellation_check = CancelAfter.check;
    opts.cancellation_ctx = &cancel;
    try std.testing.expectError(error.CompilationCancelled, compile(a, src, "", &.{}, opts));

    var never: CancelAfter = .{ .after = std.math.maxInt(usize) };
    opts.cancellation_ctx = &never;
    const with_callback = try compile(a, src, "", &.{}, opts);
    const without = try compile(a, src, "", &.{}, quiet);
    try std.testing.expectEqualStrings(without, with_callback);
    try std.testing.expect(never.calls > 0);
}

test "limits: loaded modules share the entry's step budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const busy = "$n: 0; @for $i from 1 through 20000 { $n: $n + 1; } b { x: $n; }";
    try writeFile(tmp.dir, "_busy.scss", busy);
    const root = try tmpPath(a, &tmp);
    const entry = try std.fs.path.join(a, &.{ root, "entry.scss" });

    var budget_probe = withLimits(.{ .max_vm_steps = std.math.maxInt(u64) });
    _ = try compile(a, busy, entry, &.{}, budget_probe);
    // Enough for one copy of the work, not for two.
    budget_probe.limits.max_vm_steps = 150_000;
    _ = try compile(a, busy, entry, &.{}, budget_probe);
    const twice_use = "@use \"busy\";\n" ++ busy;
    try std.testing.expectError(error.ExecutionLimit, compile(a, twice_use, entry, &.{}, budget_probe));
    const twice_load_css = "@use \"sass:meta\";\na { @include meta.load-css(\"busy\"); }\n" ++ busy;
    try std.testing.expectError(error.ExecutionLimit, compile(a, twice_load_css, entry, &.{}, budget_probe));
}

test "limits: values that double each step stop at the memory limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = withLimits(.{ .max_memory_bytes = 64 * 1024 * 1024 });
    const strings = "$s: a; @for $i from 1 through 40 { $s: $s + $s; } a { x: str-length($s); }";
    try std.testing.expectError(error.MemoryLimit, compile(a, strings, "", &.{}, opts));
    const lists = "@use \"sass:list\"; $l: 1 2; @for $i from 1 through 40 { $l: list.join($l, $l); } a { x: list.length($l); }";
    try std.testing.expectError(error.MemoryLimit, compile(a, lists, "", &.{}, opts));
    const few = "$s: a; @for $i from 1 through 4 { $s: $s + $s; } a { x: str-length($s); }";
    try std.testing.expectEqualStrings("a {\n  x: 16;\n}\n", try compile(a, few, "", &.{}, opts));
}

test "limits: source and output size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.SourceSizeLimit, compile(a, "a { b: c; }", "", &.{}, withLimits(.{ .max_source_bytes = 4 })));
    const src = "@for $i from 1 through 100 { .a#{$i} { b: c; } }";
    try std.testing.expectError(error.OutputSizeLimit, compile(a, src, "", &.{}, withLimits(.{ .max_output_bytes = 100 })));
    const css = try compile(a, src, "", &.{}, withLimits(.{ .max_output_bytes = 1 << 20 }));
    try std.testing.expect(css.len > 100);
}

const CapturedCode = struct {
    code: ?[]const u8 = null,
    message: []const u8 = "",
    fn sink(diag: *const api.Diagnostic, ctx: ?*anyopaque) void {
        const self: *CapturedCode = @ptrCast(@alignCast(ctx.?));
        if (diag.level != .err) return;
        self.code = diag.code;
        self.message = diag.message;
    }
};

test "limits: diagnostics carry a stable code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var captured: CapturedCode = .{};
    var opts = withLimits(.{ .max_vm_steps = 1000 });
    opts.diagnostic_sink = CapturedCode.sink;
    opts.diagnostic_ctx = &captured;
    try std.testing.expectError(error.ExecutionLimit, compile(a, "@while true {}", "", &.{}, opts));
    try std.testing.expectEqualStrings("ZSASS_LIMIT_VM_STEPS", captured.code.?);
    try std.testing.expectEqualStrings("Execution step limit exceeded.", captured.message);
}

// ---------------------------------------------------------------------
// Selector expansion
// ---------------------------------------------------------------------

test "limits: independent extends stop at the selector budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ten = try compile(a, try independentExtends(a, 10), "", &.{}, quiet);
    try std.testing.expectEqual(@as(usize, 1024), std.mem.count(u8, ten[0..std.mem.indexOfScalar(u8, ten, '{').?], ",") + 1);
    _ = try compile(a, try independentExtends(a, 12), "", &.{}, quiet);
    const fourteen = try independentExtends(a, 14);
    try std.testing.expectError(error.SelectorExpansionLimit, compile(a, fourteen, "", &.{}, quiet));
    // A higher limit lets it through, with every combination.
    const css = try compile(a, fourteen, "", &.{}, withLimits(.{ .max_selector_candidates = 2_000_000, .max_memory_bytes = std.math.maxInt(usize) }));
    try std.testing.expectEqual(@as(usize, 16384), std.mem.count(u8, css[0..std.mem.indexOfScalar(u8, css, '{').?], ",") + 1);
}

test "limits: selector functions and extends from another module share the budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = withLimits(.{ .max_selector_candidates = 2_000 });

    var func: std.ArrayList(u8) = .empty;
    try func.appendSlice(a, "@use \"sass:selector\";\na { x: selector.extend(\"");
    for (0..14) |i| try func.print(a, ".a{d} ", .{i});
    try func.appendSlice(a, "\", \"");
    for (0..14) |i| try func.print(a, "{s}.a{d}", .{ if (i == 0) "" else ", ", i });
    try func.appendSlice(a, "\", \".x\"); }\n");
    try std.testing.expectError(error.SelectorExpansionLimit, compile(a, func.items, "", &.{}, opts));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rules: std.ArrayList(u8) = .empty;
    for (0..14) |i| try rules.print(a, ".a{d} ", .{i});
    try rules.appendSlice(a, "{x:y}\n");
    try writeFile(tmp.dir, "_rules.scss", rules.items);
    var extends: std.ArrayList(u8) = .empty;
    try extends.appendSlice(a, "@use \"rules\";\n");
    for (0..14) |i| try extends.print(a, ".x{d} {{@extend .a{d}}}\n", .{ i, i });
    const root = try tmpPath(a, &tmp);
    const entry = try std.fs.path.join(a, &.{ root, "entry.scss" });
    try std.testing.expectError(error.SelectorExpansionLimit, compile(a, extends.items, entry, &.{}, opts));
}

// ---------------------------------------------------------------------
// File import policy
// ---------------------------------------------------------------------

const PolicyFixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    allowed: []const u8,
    roots: [1][]const u8,
    entry: []const u8,

    fn init(a: std.mem.Allocator) !PolicyFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeFile(tmp.dir, "outside/_secret.scss", ".secret { x: y; }");
        try writeFile(tmp.dir, "allowed/_partial.scss", ".partial { x: y; }");
        try writeFile(tmp.dir, "allowed/dir/_index.scss", ".index { x: y; }");
        try writeFile(tmp.dir, "allowed/plain.css", ".plain { x: y; }");
        try writeFile(tmp.dir, "allowed/_reaches_out.scss", "@use \"../outside/secret\";");
        const root = try tmpPath(a, &tmp);
        const allowed = try std.fs.path.join(a, &.{ root, "allowed" });
        return .{
            .tmp = tmp,
            .root = root,
            .allowed = allowed,
            .roots = .{allowed},
            .entry = try std.fs.path.join(a, &.{ allowed, "entry.scss" }),
        };
    }

    fn deinit(self: *PolicyFixture) void {
        self.tmp.cleanup();
    }

    fn opts(self: *const PolicyFixture) api.CompileOptions {
        var o = api.CompileOptions.forUntrustedInput(&self.roots);
        o.quiet = true;
        return o;
    }
};

test "file policy: files inside the roots load" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    const css = try compile(a, "@use \"partial\"; @use \"dir\"; @import \"plain\";", f.entry, &.{}, f.opts());
    try std.testing.expect(std.mem.indexOf(u8, css, ".partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".index") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".plain") != null);
}

test "file policy: an absolute path resolves like the official CLI" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    const use = try std.fmt.allocPrint(a, "@use \"{s}/outside/secret\";", .{f.root});
    try std.testing.expectEqualStrings(".secret {\n  x: y;\n}\n", try compile(a, use, f.entry, &.{}, quiet));
    const index = try std.fmt.allocPrint(a, "@use \"{s}/dir\";", .{f.allowed});
    try std.testing.expectEqualStrings(".index {\n  x: y;\n}\n", try compile(a, index, f.entry, &.{}, quiet));
    const missing = try std.fmt.allocPrint(a, "@use \"{s}/outside/nothing\";", .{f.root});
    try std.testing.expectError(error.UsermoduleNotFound, compile(a, missing, f.entry, &.{}, quiet));
}

test "file policy: escapes from the roots are refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    const opts = f.opts();
    const absolute = try std.fmt.allocPrint(a, "@use \"{s}/outside/secret\";", .{f.root});
    const sources = [_][]const u8{
        "@use \"../outside/secret\";",
        "@forward \"../outside/secret\";",
        "@import \"../outside/secret\";",
        "@use \"sass:meta\"; a { @include meta.load-css(\"../outside/secret\"); }",
        absolute,
        "@use \"pkg:anything\";",
        // A module inside the root cannot reach out either.
        "@use \"reaches_out\";",
        "@use \"sass:meta\"; a { @include meta.load-css(\"reaches_out\"); }",
    };
    for (sources) |src| {
        try std.testing.expectError(error.FileImportDenied, compile(a, src, f.entry, &.{}, opts));
    }
    // Load paths only say where to look; they grant nothing.
    const outside = try std.fs.path.join(a, &.{ f.root, "outside" });
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"secret\";", f.entry, &.{outside}, opts));
}

test "file policy: a symbolic link out of a root is refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    try f.tmp.dir.symLink(zsass_io.io, "../outside/_secret.scss", "allowed/_link.scss", .{});
    try f.tmp.dir.symLink(zsass_io.io, "../outside", "allowed/linkdir", .{});
    const opts = f.opts();
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"link\";", f.entry, &.{}, opts));
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"linkdir/secret\";", f.entry, &.{}, opts));
}

test "file policy: the refusal does not tell whether the file exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    var existing: CapturedCode = .{};
    var missing: CapturedCode = .{};
    var opts = f.opts();
    opts.diagnostic_sink = CapturedCode.sink;
    opts.diagnostic_ctx = &existing;
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"../outside/secret\";", f.entry, &.{}, opts));
    const existing_message = try a.dupe(u8, existing.message);
    opts.diagnostic_ctx = &missing;
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"../outside/nothing\";", f.entry, &.{}, opts));
    try std.testing.expectEqualStrings(existing_message, missing.message);
    try std.testing.expectEqualStrings("ZSASS_IMPORT_DENIED", missing.code.?);
    try std.testing.expect(std.mem.indexOf(u8, existing_message, "outside") == null);
}

test "file policy: disabled imports keep the built-in modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var opts = api.CompileOptions.forUntrustedInput(&.{});
    opts.quiet = true;
    const css = try compile(a, "@use \"sass:math\"; a { x: math.div(4, 2); }", "/virtual/in.scss", &.{}, opts);
    try std.testing.expectEqualStrings("a {\n  x: 2;\n}\n", css);
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"other\";", "/virtual/in.scss", &.{}, opts));
    // A CSS import is left in the output, not read.
    const plain = try compile(a, "@import \"theme.css\";", "/virtual/in.scss", &.{}, opts);
    try std.testing.expectEqualStrings("@import \"theme.css\";\n", plain);
}

test "batch: each entry has its own budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const busy = "$n: 0; @for $i from 1 through 20000 { $n: $n + 1; } b { x: $n; }";
    try writeFile(tmp.dir, "one.scss", busy);
    try writeFile(tmp.dir, "two.scss", busy);
    const root = try tmpPath(a, &tmp);
    const paths = [_][]const u8{
        try std.fs.path.join(a, &.{ root, "one.scss" }),
        try std.fs.path.join(a, &.{ root, "two.scss" }),
    };
    const results = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 1, .limits = .{ .max_vm_steps = 150_000 } });
    for (results) |r| {
        try std.testing.expect(r.err == null);
        try std.testing.expect(r.css != null);
    }
    const tight = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 1, .limits = .{ .max_vm_steps = 1_000 } });
    for (tight) |r| try std.testing.expectEqual(@as(?anyerror, error.ExecutionLimit), r.err);
}

// ---------------------------------------------------------------------
// Review follow-ups
// ---------------------------------------------------------------------

test "limits: the selector budget bounds one selector, not the stylesheet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..3000) |i| try src.print(a, ".a-{d} .b {{ x: y; }}\n", .{i});
    try src.appendSlice(a, ".c { @extend .b; }\n");
    const opts = withLimits(.{ .max_selector_candidates = 2_000 });
    const css = try compile(a, src.items, "", &.{}, opts);
    try std.testing.expect(std.mem.indexOf(u8, css, ".a-2999 .b, .a-2999 .c") != null);
    const calls = "@use \"sass:selector\"; @for $i from 1 through 2000 { .x-#{$i} { y: selector.extend(\".a-#{$i} .b\", \".b\", \".c\"); } }";
    _ = try compile(a, calls, "", &.{}, opts);
}

test "limits: a deeply nested selector stops before it is parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try repeat(a, &.{ "a", ":is(", "b", ")", "{x:y}" }, &.{ 1, 20000, 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, deep, "", &.{}, quiet));
    const indented = try repeat(a, &.{ "a", ":is(", "b", ")", "\n  x: y\n" }, &.{ 1, 20000, 1, 20000, 1 });
    try std.testing.expectError(error.SyntaxNestingLimit, compile(a, indented, "input.sass", &.{}, quiet));
    const runtime = try repeat(a, &.{ "@use \"sass:selector\"; a { x: selector.parse(\"", ":is(", "b", ")", "\"); }" }, &.{ 1, 600, 1, 600, 1 });
    try std.testing.expectError(error.NestingLimit, compile(a, runtime, "", &.{}, quiet));
}

test "limits: lifting the limits still keeps the parser on the stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NestingLimit, compile(a, try nestedParens(a, 64000), "", &.{}, withLimits(api.CompileLimits.unlimited())));
}

test "limits: deferred CSS of meta.load and load-css wrappers count as nodes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_big.scss", "@for $i from 1 through 100000 { .r#{$i} { x: y; } }");
    try writeFile(tmp.dir, "_comments.scss", "/**/@foo; /**/@bar;");
    const root = try tmpPath(a, &tmp);
    const entry = try std.fs.path.join(a, &.{ root, "entry.scss" });
    const opts = withLimits(.{ .max_ir_nodes = 10_000 });
    try std.testing.expectError(error.IrNodeLimit, compile(a, "@use \"sass:meta\"; $m: meta.load(\"big\");", entry, &.{}, opts));
    const wrap = "@use \"sass:meta\"; a { @include meta.load-css(\"comments\"); }";
    const css = try compile(a, wrap, entry, &.{}, quiet);
    try std.testing.expect(std.mem.indexOf(u8, css, "@foo") != null);
    try std.testing.expectError(error.IrNodeLimit, compile(a, wrap, entry, &.{}, withLimits(.{ .max_ir_nodes = 6 })));
}

test "limits: a batch entry counts what its arena keeps and the shared caches" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "grow.scss", "$s: a; @for $i from 1 through 40 { $s: $s + $s; } a { x: str-length($s); }");
    var big: std.ArrayList(u8) = .empty;
    for (0..60000) |i| try big.print(a, "$v{d}: {d};\n", .{ i, i });
    try writeFile(tmp.dir, "_big.scss", big.items);
    try writeFile(tmp.dir, "uses.scss", "@use \"big\"; a { x: big.$v1; }");
    const root = try tmpPath(a, &tmp);
    const paths = [_][]const u8{
        try std.fs.path.join(a, &.{ root, "grow.scss" }),
        try std.fs.path.join(a, &.{ root, "uses.scss" }),
    };
    const results = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 1, .limits = .{ .max_memory_bytes = 1024 * 1024 } });
    for (results) |r| try std.testing.expectEqual(@as(?anyerror, error.MemoryLimit), r.err);
}

test "file policy: a failure to set it up reports the memory limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    var opts = f.opts();
    opts.limits.max_memory_bytes = 1;
    try std.testing.expectError(error.MemoryLimit, compile(a, "a { b: c; }", f.entry, &.{}, opts));
}

test "file policy: a link out of a root tells nothing about its target" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    try f.tmp.dir.symLink(zsass_io.io, "../outside", "allowed/linkdir", .{});
    try f.tmp.dir.symLink(zsass_io.io, "../outside/_nothing.scss", "allowed/_dangling.scss", .{});
    const opts = f.opts();
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"linkdir/secret\";", f.entry, &.{}, opts));
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"linkdir/nothing\";", f.entry, &.{}, opts));
    try std.testing.expectError(error.FileImportDenied, compile(a, "@use \"dangling\";", f.entry, &.{}, opts));
    // A link that stays inside the root is followed.
    try f.tmp.dir.symLink(zsass_io.io, "dir", "allowed/alias", .{});
    const css = try compile(a, "@use \"alias\";", f.entry, &.{}, opts);
    try std.testing.expect(std.mem.indexOf(u8, css, ".index") != null);
}

test "limits: registered extenders add up while the engine keeps them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, ".x {\n");
    for (0..2000) |i| try src.print(a, "  @extend .t{d} !optional;\n", .{i});
    try src.appendSlice(a, "}\n");
    try std.testing.expectError(error.SelectorExpansionLimit, compile(a, src.items, "", &.{}, withLimits(.{ .max_selector_candidates = 1000 })));
    _ = try compile(a, src.items, "", &.{}, withLimits(.{ .max_selector_candidates = 10_000 }));
}

test "limits: extending while writing counts toward the memory limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..100) |k| {
        for (0..10) |i| try src.print(a, ".a{d} ", .{i});
        try src.print(a, ".q{d} {{ x: y; }}\n", .{k});
    }
    for (0..10) |i| try src.print(a, ".x{d} {{ @extend .a{d}; }}\n", .{ i, i });
    const css = try compile(a, src.items, "", &.{}, quiet);
    try std.testing.expect(std.mem.indexOf(u8, css, ".x0 .x1 .x2 .x3 .x4 .x5 .x6 .x7 .x8 .x9 .q99") != null);
    if (compile(a, src.items, "", &.{}, withLimits(.{ .max_memory_bytes = 4 * 1024 * 1024 }))) |_| {
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MemoryLimit, err);
}

test "limits: a raised syntax depth lets selectors nest deeper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runtime = try repeat(a, &.{ "@use \"sass:selector\"; a { x: selector.parse(\"", ":is(", "b", ")", "\"); }" }, &.{ 1, 520, 1, 520, 1 });
    try std.testing.expectError(error.NestingLimit, compile(a, runtime, "", &.{}, quiet));
    // Debug builds take about 8 KiB of stack per level here.
    _ = try compile(a, runtime, "", &.{}, withLimits(.{ .max_syntax_depth = 1000, .stack_bytes = 6 * 1024 * 1024 }));
}

test "limits: consecutive comments loaded into a rule share one wrapper" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_c.scss", "/**//**/");
    const root = try tmpPath(a, &tmp);
    const entry = try std.fs.path.join(a, &.{ root, "entry.scss" });
    _ = try compile(a, "@use \"sass:meta\"; a { @include meta.load-css(\"c\"); }", entry, &.{}, withLimits(.{ .max_ir_nodes = 6 }));
}

test "batch: a memory limit too small for the shared caches is a memory limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "one.scss", "a { b: c; }");
    const root = try tmpPath(a, &tmp);
    const paths = [_][]const u8{try std.fs.path.join(a, &.{ root, "one.scss" })};
    try std.testing.expectError(error.MemoryLimit, api.compileFiles(a, &paths, .{ .quiet = true, .limits = .{ .max_memory_bytes = 1 } }));
}

test "file policy: a root given through a link accepts links spelled that way" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try PolicyFixture.init(a);
    defer f.deinit();
    try f.tmp.dir.symLink(zsass_io.io, "allowed", "via", .{});
    const via = try std.fs.path.join(a, &.{ f.root, "via" });
    const target = try std.fs.path.join(a, &.{ via, "_partial.scss" });
    try f.tmp.dir.symLink(zsass_io.io, target, "allowed/_abs.scss", .{});
    const roots = [_][]const u8{via};
    var opts = api.CompileOptions.forUntrustedInput(&roots);
    opts.quiet = true;
    const entry = try std.fs.path.join(a, &.{ via, "entry.scss" });
    const css = try compile(a, "@use \"abs\";", entry, &.{}, opts);
    try std.testing.expect(std.mem.indexOf(u8, css, ".partial") != null);
}

test "limits: a placeholder extended by many rules stays within the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "%p { x: y; }\n");
    for (0..1000) |i| try src.print(a, ".c{d} .d > .e {{ @extend %p; }}\n", .{i});
    const css = try compile(a, src.items, "", &.{}, withLimits(.{ .max_memory_bytes = 256 * 1024 * 1024 }));
    try std.testing.expect(std.mem.indexOf(u8, css, ".c999 .d > .e") != null);
}

test "limits: the compressed writer frees its buffer when output stops" {
    const css = compile(std.testing.allocator, "@for $i from 1 through 1000 { .a#{$i} { x: y; } }", "", &.{}, .{ .quiet = true, .output_style = .compressed, .limits = .{ .max_output_bytes = 1 } });
    try std.testing.expectError(error.OutputSizeLimit, css);
}

test "numbers: integers past the 64-bit range are refused, not converted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = [_][]const u8{
        "a { x: nth(1 2 3, 1e300); }",
        "@use \"sass:list\"; a { x: list.nth(1 2 3, 18446744073709551616); }",
        "@use \"sass:list\"; a { x: list.set-nth(1 2 3, -1e300, 4); }",
        "@use \"sass:math\"; a { x: math.random(18446744073709551616); }",
        "@use \"sass:string\"; a { x: string.insert(\"abc\", \"x\", 1e300); }",
    };
    for (refused) |src| {
        if (compile(a, src, "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    }
    // The official CLI reads 2^63 as the largest 64-bit integer.
    try std.testing.expectEqualStrings(
        "a {\n  x: 9223372036854775807;\n  y: -9223372036854775808;\n}\n",
        try compile(a, "a { x: 9223372036854775808; y: -9223372036854775809; }", "", &.{}, quiet),
    );
    try std.testing.expectEqualStrings(
        "a {\n  a: \"bc\";\n  b: \"abc\";\n  c: \"abcx\";\n  d: \"\";\n}\n",
        try compile(a, "@use \"sass:string\"; a { a: string.slice(\"abc\", 2, 9223372036854775807); b: string.slice(\"abc\", -9223372036854775808); c: string.insert(\"abc\", \"x\", 9223372036854775808); d: string.slice(\"abc\", 9223372036854775808); }", "", &.{}, quiet),
    );
}

test "limits: comparing map keys counts as execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "$m: (");
    for (0..3000) |i| try src.print(a, "{s}{d}px: a", .{ if (i == 0) "" else ", ", i });
    try src.appendSlice(a, "); a { x: length($m); }");
    try std.testing.expectEqualStrings("a {\n  x: 3000;\n}\n", try compile(a, src.items, "", &.{}, quiet));
    try std.testing.expectError(error.ExecutionLimit, compile(a, src.items, "", &.{}, withLimits(.{ .max_vm_steps = 1_000_000 })));
}

test "batch: an entry that configures a module does not change another entry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_lib.scss", "$c: blue !default; .lib { c: $c; }");
    try writeFile(tmp.dir, "_cfg.scss", "$c: green;");
    try writeFile(tmp.dir, "a_configured.scss", "@use \"lib\" with ($c: red);");
    try writeFile(tmp.dir, "b_default.scss", "@use \"lib\";");
    try writeFile(tmp.dir, "c_import.scss", "@import \"cfg\"; @import \"lib\";");
    try writeFile(tmp.dir, "d_default.scss", "@import \"lib\";");
    const root = try tmpPath(a, &tmp);
    const names = [_][]const u8{ "a_configured.scss", "b_default.scss", "c_import.scss", "d_default.scss" };
    var paths: [names.len][]const u8 = undefined;
    for (names, &paths) |n, *p| p.* = try std.fs.path.join(a, &.{ root, n });
    const expected = [_][]const u8{ ".lib {\n  c: red;\n}\n", ".lib {\n  c: blue;\n}\n", ".lib {\n  c: green;\n}\n", ".lib {\n  c: blue;\n}\n" };
    // Each order, so every entry has a chance to come after another.
    const orders = [_][4]usize{ .{ 0, 1, 2, 3 }, .{ 1, 0, 3, 2 }, .{ 2, 3, 0, 1 }, .{ 3, 2, 1, 0 } };
    for (orders) |order| {
        var ordered: [4][]const u8 = undefined;
        for (order, &ordered) |i, *p| p.* = paths[i];
        const results = try api.compileFiles(a, &ordered, .{ .quiet = true, .jobs = 1 });
        for (order, results) |i, r| try std.testing.expectEqualStrings(expected[i], r.css orelse return error.TestUnexpectedResult);
    }
}

test "batch: a module configured through another one keeps each entry's value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_lib.scss", "$c: blue !default; @function c() { @return $c; }");
    try writeFile(tmp.dir, "_util.scss", "@use \"lib\"; .util { c: lib.c(); }");
    try writeFile(tmp.dir, "_fwd.scss", "@forward \"lib\" with ($c: purple !default);");
    try writeFile(tmp.dir, "_fwduser.scss", "@use \"fwd\"; .fwd { c: fwd.c(); }");
    try writeFile(tmp.dir, "e1.scss", "@use \"lib\" with ($c: red); @use \"util\";");
    try writeFile(tmp.dir, "e2.scss", "@use \"util\";");
    try writeFile(tmp.dir, "e3.scss", "@use \"fwd\" with ($c: orange); @use \"fwduser\";");
    try writeFile(tmp.dir, "e4.scss", "@use \"fwduser\";");
    try writeFile(tmp.dir, "e5.scss", "$c: pink; @import \"util\";");
    const root = try tmpPath(a, &tmp);
    const names = [_][]const u8{ "e1.scss", "e2.scss", "e3.scss", "e4.scss", "e5.scss" };
    var solo: [names.len][]const u8 = undefined;
    var paths: [names.len][]const u8 = undefined;
    for (names, &paths, &solo) |n, *p, *o| {
        p.* = try std.fs.path.join(a, &.{ root, n });
        const one = [_][]const u8{p.*};
        const r = try api.compileFiles(a, &one, .{ .quiet = true, .jobs = 1 });
        o.* = r[0].css orelse "ERR";
    }
    // The official CLI writes purple for e4, the default its @forward sets.
    try std.testing.expectEqualStrings(".fwd {\n  c: purple;\n}\n", solo[3]);
    var orders: [3][5]usize = .{ .{ 0, 1, 2, 3, 4 }, .{ 4, 3, 2, 1, 0 }, .{ 1, 3, 0, 2, 4 } };
    for (&orders) |*order| {
        var ordered: [5][]const u8 = undefined;
        for (order, &ordered) |i, *p| p.* = paths[i];
        const results = try api.compileFiles(a, &ordered, .{ .quiet = true, .jobs = 1 });
        for (order, results) |i, r| {
            const got = r.css orelse "ERR";
            try std.testing.expectEqualStrings(solo[i], got);
        }
    }
}

test "batch: a module that configures another one is not replayed from shared records" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_lib.scss", "$c: blue !default; .lib { c: $c; }");
    try writeFile(tmp.dir, "_configured.scss", "@use \"lib\" with ($c: red);");
    try writeFile(tmp.dir, "_imports.scss", "$c: green; @import \"lib\";");
    try writeFile(tmp.dir, "_fwd.scss", "@forward \"lib\";");
    try writeFile(tmp.dir, "_mixed.scss", "$c: red; @import url(\"external.css\"), \"fwd\";");
    try writeFile(tmp.dir, "usemixed.scss", "@use \"mixed\";");
    try writeFile(tmp.dir, "via.scss", "@use \"configured\";");
    try writeFile(tmp.dir, "plain.scss", "@use \"lib\";");
    try writeFile(tmp.dir, "nested.scss", "@use \"imports\";");
    const root = try tmpPath(a, &tmp);
    const names = [_][]const u8{ "via.scss", "plain.scss", "nested.scss", "usemixed.scss" };
    // The official CLI: red, blue, green, red.
    const expected = [_][]const u8{ ".lib {\n  c: red;\n}\n", ".lib {\n  c: blue;\n}\n", ".lib {\n  c: green;\n}\n", "@import url(\"external.css\");\n.lib {\n  c: red;\n}\n" };
    const orders = [_][6]usize{ .{ 0, 0, 1, 2, 1, 3 }, .{ 1, 3, 3, 0, 2, 2 }, .{ 2, 1, 0, 3, 1, 3 } };
    for (orders) |order| {
        var paths: [6][]const u8 = undefined;
        for (order, &paths) |i, *p| p.* = try std.fs.path.join(a, &.{ root, names[i] });
        const results = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 1 });
        for (order, results) |i, r| try std.testing.expectEqualStrings(expected[i], r.css orelse return error.TestUnexpectedResult);
    }
}

test "batch: parallel workers give the same results as one at a time" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_lib.scss", "$c: blue !default; .lib { c: $c; }");
    try writeFile(tmp.dir, "_configured.scss", "@use \"lib\" with ($c: red);");
    try writeFile(tmp.dir, "via.scss", "@use \"configured\";");
    try writeFile(tmp.dir, "plain.scss", "@use \"lib\";");
    try writeFile(tmp.dir, "bad.scss", "a { b: $missing; }");
    const root = try tmpPath(a, &tmp);
    const names = [_][]const u8{ "via.scss", "plain.scss", "bad.scss" };
    var paths: [24][]const u8 = undefined;
    for (&paths, 0..) |*p, i| p.* = try std.fs.path.join(a, &.{ root, names[i % names.len] });

    try std.testing.expect(!zsass_io.supportsThreads());
    const serial = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 4 });

    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const saved_io = zsass_io.io;
    defer zsass_io.io = saved_io;
    zsass_io.io = threaded.io();
    try std.testing.expect(zsass_io.supportsThreads());
    const parallel = try api.compileFiles(a, &paths, .{ .quiet = true, .jobs = 4 });

    for (serial, parallel, 0..) |s, p, i| {
        if (i % names.len == 2) {
            try std.testing.expect(s.err != null and p.err != null);
            continue;
        }
        try std.testing.expectEqualStrings(s.css orelse return error.TestUnexpectedResult, p.css orelse return error.TestUnexpectedResult);
    }
    try std.testing.expectEqualStrings(".lib {\n  c: red;\n}\n", parallel[0].css.?);
    try std.testing.expectEqualStrings(".lib {\n  c: blue;\n}\n", parallel[1].css.?);
}

test "limits: comparing values counts the values visited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shared structure: each level holds the one below twice, so comparing
    // two keys visits 2^14 values although the map has two pairs.
    const shared =
        \\$x: (1,);
        \\@for $i from 1 through 14 { $x: ($x, $x); }
        \\$m: (($x, 0): a, ($x, 1): b);
        \\a { x: length($m); }
    ;
    try std.testing.expectEqualStrings("a {\n  x: 2;\n}\n", try compile(a, shared, "", &.{}, quiet));
    try std.testing.expectError(error.ExecutionLimit, compile(a, shared, "", &.{}, withLimits(.{ .max_vm_steps = 10_000 })));
    // Map-valued keys compare pair by pair.
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "$m: (");
    for (0..200) |i| {
        try src.appendSlice(a, if (i == 0) "(" else ", (");
        for (0..50) |k| try src.print(a, "{s}k{d}: {d}", .{ if (k == 0) "" else ", ", k, if (k == 49) i else 0 });
        try src.appendSlice(a, "): a");
    }
    try src.appendSlice(a, "); a { x: length($m); }");
    try std.testing.expectEqualStrings("a {\n  x: 200;\n}\n", try compile(a, src.items, "", &.{}, quiet));
    try std.testing.expectError(error.ExecutionLimit, compile(a, src.items, "", &.{}, withLimits(.{ .max_vm_steps = 1_000_000 })));
}

test "limits: a list built by appending in a loop stays within memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\@use "sass:list";
        \\$l: ();
        \\@for $i from 1 through 25000 { $l: list.append($l, $i); }
        \\a { b: list.length($l); c: list.nth($l, -1); }
    ;
    // Each append used to copy the whole list: about 2.5 GB here.
    try std.testing.expectEqualStrings("a {\n  b: 25000;\n  c: 25000;\n}\n", try compile(a, src, "", &.{}, withLimits(.{ .max_memory_bytes = 64 * 1024 * 1024 })));
}

test "list.append: appending twice to one list keeps both results apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\@use "sass:list";
        \\$base: ();
        \\@for $i from 1 through 20 { $base: list.append($base, $i); }
        \\$a: list.append($base, a);
        \\$b: list.append($base, b);
        \\$a2: list.append($a, a2);
        \\x { a: list.nth($a, -1); b: list.nth($b, -1); a2: list.nth($a2, -2) list.nth($a2, -1); n: list.length($base) list.length($a) list.length($b); }
    ;
    try std.testing.expectEqualStrings("x {\n  a: a;\n  b: b;\n  a2: a a2;\n  n: 20 21 21;\n}\n", try compile(a, src, "", &.{}, quiet));
}

test "arguments: non-int indexes and incompatible min/max units are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (compile(a, "@use \"sass:list\"; a { b: list.nth((1 2 3), 1.5); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    if (compile(a, "@use \"sass:math\"; a { b: math.max(1px, 2em); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    if (compile(a, "@use \"sass:math\" as *; a { b: max(1px, 2em); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    // The CSS function keeps what it cannot compare.
    try std.testing.expectEqualStrings("a {\n  b: max(1px, 2em);\n}\n", try compile(a, "a { b: max(1px, 2em); }", "", &.{}, quiet));
    try std.testing.expectEqualStrings("a {\n  b: [\"a\", \"b c\"];\n}\n", try compile(a, "@use \"sass:string\"; a { b: string.split(\"a b c\", \" \", 1px); }", "", &.{}, quiet));
}

test "selector functions: comments in a selector argument read as spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a {\n  b: .a .b;\n  c: .a.b;\n  d: [a=\"/* kept */\"];\n}\n", try compile(a,
        \\@use "sass:selector";
        \\a { b: selector.parse(".a/**/.b"); c: selector.unify(".a /* x */", ".b"); d: selector.parse("[a=\"/* kept */\"]"); }
    , "", &.{}, quiet));
    if (compile(a, "@use \"sass:selector\"; a { b: selector.parse(\".a /* open\"); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
}

test "@supports: parentheses around one group drop inside operations and in @import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("@supports (x) and (y) {\n  a {\n    b: c;\n  }\n}\n", try compile(a, "@supports ((x)) and ((y)) { a { b: c; } }", "", &.{}, quiet));
    try std.testing.expectEqualStrings("@supports ((a: b) or (c: d)) and (e: f) {\n  a {\n    b: c;\n  }\n}\n", try compile(a, "@supports (((a: b) or (c: d))) and (e: f) { a { b: c; } }", "", &.{}, quiet));
    try std.testing.expectEqualStrings("@import url(a.css) supports(display: grid);\n", try compile(a, "@import url(a.css) supports(((display: grid)));", "", &.{}, quiet));
}

test "@extend: many independent extends keep every pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..3000) |i| try src.print(a, ".a{d} {{ c: d; }}\n", .{i});
    for (0..3000) |i| try src.print(a, ".b{d} {{ @extend .a{d}; }}\n", .{ i, i });
    const css = try compile(a, src.items, "", &.{}, quiet);
    try std.testing.expect(std.mem.indexOf(u8, css, ".a0, .b0 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".a2999, .b2999 {") != null);
}

test "variables: a function or mixin reading a variable nothing set is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (compile(a, "@mixin m { b: $u; } .a { @include m; }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    if (compile(a, "@function f() { @return $u; } .a { b: f(); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    // Also where the read is fused with what uses it.
    if (compile(a, "@function f() { @return $u + 1; } .a { b: f(); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    if (compile(a, "@mixin m { @if $u { b: c; } } .a { @include m; }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    // Set before the call, plainly or with !default: fine.
    try std.testing.expectEqualStrings(".a {\n  b: 1px;\n}\n", try compile(a, "@mixin m { b: $u; } $u: 1px; .a { @include m; }", "", &.{}, quiet));
    try std.testing.expectEqualStrings(".a {\n  b: 2px;\n}\n", try compile(a, "@mixin m { b: $u; } $u: 2px !default; .a { @include m; }", "", &.{}, quiet));
}

test "string.unquote: an `&` it returns is text, not the parent selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(".p {\n  z: &;\n  y: 1 2 &;\n}\n", try compile(a, "@use 'sass:list'; @use 'sass:string'; .p { z: string.unquote('&'); y: list.append((1 2), string.unquote('&')); }", "", &.{}, quiet));
    try std.testing.expectEqualStrings(".p-x {\n  a: b;\n}\n", try compile(a, "@use 'sass:string'; .p { #{string.unquote('&')}-x { a: b; } }", "", &.{}, quiet));
}

test "meta.get-function: the global min() is the Sass function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (compile(a, "@use \"sass:meta\"; a { b: meta.call(meta.get-function(\"min\"), 1px, 2em); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqualStrings("a {\n  b: 2px;\n}\n", try compile(a, "@use \"sass:meta\"; a { b: meta.call(meta.get-function(\"max\"), 1px, 2px); }", "", &.{}, quiet));
}

test "math.min/max: compound units are compared factor by factor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a {\n  b: calc(1px * 1px);\n  c: calc(2px * 1px);\n  d: calc(1px * 1em);\n}\n", try compile(a, "@use \"sass:math\"; a { b: math.min(calc(1px * 1px), calc(2px * 1px)); c: math.max(1px * 1px, 2px * 1px); d: math.min(1px * 1em, 1em * 2px); }", "", &.{}, quiet));
    if (compile(a, "@use \"sass:math\"; a { b: math.min(1px * 1px, 1px); }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
}

test "meta.load-css: a configured number with a unit reaches the module" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "_lib.scss", "$u: original !default; @mixin m { b: $u; } .a { @include m; }");
    try writeFile(tmp.dir, "main.scss", "@use \"sass:meta\"; @include meta.load-css(\"lib\", $with: (u: 2px));");
    const root = try tmpPath(a, &tmp);
    const main = try std.fs.path.join(a, &.{ root, "main.scss" });
    const results = try api.compileFiles(a, &.{main}, .{ .quiet = true, .jobs = 1 });
    try std.testing.expectEqualStrings(".a {\n  b: 2px;\n}\n", results[0].css orelse return error.TestUnexpectedResult);
}

test "variables: a parameter default that reads a variable nothing set is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.SassError, compile(a, "@mixin m($x: $u) { b: $x; } .a { @include m; }", "", &.{}, quiet));
    try std.testing.expectEqualStrings(".a {\n  b: 1px;\n}\n", try compile(a, "@mixin m($x: $u) { b: $x; } $u: 1px; .a { @include m; }", "", &.{}, quiet));
}

test "variables: a new variable in a top-level block is not the global a mixin reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (compile(a, "@mixin m { b: $u; } @if true { $u: 2px; } .a { @include m; }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqualStrings(".a {\n  b: 2px;\n}\n", try compile(a, "@mixin m { b: $u; } $u: 1px; @if true { $u: 2px; } .a { @include m; }", "", &.{}, quiet));
}

test "variables: a global only an unrun !global sets is undefined in a mixin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (compile(a, "@mixin m { @if false { $u: 1 !global; } b: $u; } .a { @include m; }", "", &.{}, quiet)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqualStrings(".a {\n  b: 3px;\n}\n", try compile(a, "@mixin s { $u: 3px !global; } @mixin m { b: $u; } .a { @include s; @include m; }", "", &.{}, quiet));
}
