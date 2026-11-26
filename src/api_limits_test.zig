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
    const css = try compile(a, fourteen, "", &.{}, withLimits(.{ .max_selector_candidates = 2_000_000 }));
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
