//! Deprecation warning support for official Sass CLI-compatible deprecation management.
//! `DeprecationOpts` is parsed in the CLI and passed to the builtin / resolver through the VM.
const std = @import("std");
const zsass_io = @import("io.zig");
const error_format = @import("error_format.zig");

pub const DeprecationKind = enum {
    color_functions, // old color functions such as lighten() / darken() / mix() etc.
    mixed_decls, // mix of CSS and SCSS declaration
    abs_percent, // abs(50%) etc.
    fs_importer_cwd, // cwd interpretation of file system importer
    import, // @import itself
    slash_div, // division interpretation of / operator
    strict_unary, // unary operator
    function_units, // function units
    duplicate_var_flags, // !default + !global repeat
    null_alpha, // null alpha (rgb(... / null) etc.)
    css_function_mixin, // CSS level/mixin name conflict

    pub fn kindName(k: DeprecationKind) []const u8 {
        return switch (k) {
            .color_functions => "color-functions",
            .mixed_decls => "mixed-decls",
            .abs_percent => "abs-percent",
            .fs_importer_cwd => "fs-importer-cwd",
            .import => "import",
            .slash_div => "slash-div",
            .strict_unary => "strict-unary",
            .function_units => "function-units",
            .duplicate_var_flags => "duplicate-var-flags",
            .null_alpha => "null-alpha",
            .css_function_mixin => "css-function-mixin",
        };
    }

    pub fn parse(name: []const u8) ?DeprecationKind {
        var normalized: [64]u8 = undefined;
        if (name.len > normalized.len) return null;
        for (name, 0..) |c, i| {
            normalized[i] = if (c == '-') '_' else std.ascii.toLower(c);
        }
        const norm = normalized[0..name.len];
        inline for (@typeInfo(DeprecationKind).@"enum".field_names) |field_name| {
            if (std.mem.eql(u8, norm, field_name)) return @field(DeprecationKind, field_name);
        }
        return null;
    }
};

const SassVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    /// Highest Sass version accepted by `--fatal-deprecation=<version>` (official Sass CLI parity).
    pub const known_max: SassVersion = .{ .major = 1, .minor = 108, .patch = 2 };

    pub fn parse(raw: []const u8) ?SassVersion {
        var parts = std.mem.splitScalar(u8, raw, '.');
        const major_text = parts.next() orelse return null;
        const minor_text = parts.next() orelse return null;
        const patch_text = parts.next() orelse return null;
        if (parts.next() != null) return null;
        const major = std.fmt.parseUnsigned(u16, major_text, 10) catch return null;
        const minor = std.fmt.parseUnsigned(u16, minor_text, 10) catch return null;
        const patch = std.fmt.parseUnsigned(u16, patch_text, 10) catch return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn order(self: SassVersion, other: SassVersion) std.math.Order {
        if (self.major < other.major) return .lt;
        if (self.major > other.major) return .gt;
        if (self.minor < other.minor) return .lt;
        if (self.minor > other.minor) return .gt;
        if (self.patch < other.patch) return .lt;
        if (self.patch > other.patch) return .gt;
        return .eq;
    }
};

/// A deprecation id the official Sass CLI accepts. zsass reports only the ids
/// that have a `DeprecationKind`; the others are accepted so that a command
/// line written for the official CLI keeps working.
const KnownDeprecation = struct {
    name: []const u8,
    /// Version the deprecation became active in; null when no version
    /// includes it.
    since: ?SassVersion = null,
    /// No longer reported by the official CLI; a version does not include it.
    obsolete: bool = false,
    /// Member of the `dart-sass-2` group: behavior removed in Dart Sass 2.0.0.
    dart_sass_2: bool = false,
};

fn v(major: u16, minor: u16, patch: u16) SassVersion {
    return .{ .major = major, .minor = minor, .patch = patch };
}

const known_deprecations = [_]KnownDeprecation{
    .{ .name = "abs-percent", .since = v(1, 65, 0), .dart_sass_2 = true },
    .{ .name = "adjacent-compounds", .since = v(1, 100, 0), .dart_sass_2 = true },
    .{ .name = "bogus-combinators", .since = v(1, 54, 0), .dart_sass_2 = true },
    .{ .name = "calc-interp" },
    .{ .name = "call-string", .since = v(0, 0, 0), .dart_sass_2 = true },
    .{ .name = "color-4-api", .since = v(1, 79, 0), .dart_sass_2 = true },
    .{ .name = "color-functions", .since = v(1, 79, 0), .dart_sass_2 = true },
    .{ .name = "color-module-compat", .since = v(1, 23, 0) },
    .{ .name = "compile-string-relative-url", .since = v(1, 88, 0), .dart_sass_2 = true },
    .{ .name = "css-function-mixin", .since = v(1, 76, 0), .obsolete = true },
    .{ .name = "deprecation-version", .since = v(1, 107, 0) },
    .{ .name = "duplicate-var-flags", .since = v(1, 62, 0), .dart_sass_2 = true },
    .{ .name = "elseif", .since = v(1, 3, 2), .dart_sass_2 = true },
    .{ .name = "feature-exists", .since = v(1, 78, 0), .dart_sass_2 = true },
    .{ .name = "fs-importer-cwd", .since = v(1, 73, 0), .dart_sass_2 = true },
    .{ .name = "function-name", .since = v(1, 98, 0), .dart_sass_2 = true },
    .{ .name = "function-units", .since = v(1, 56, 0), .dart_sass_2 = true },
    .{ .name = "global-builtin", .since = v(1, 80, 0) },
    .{ .name = "if-function", .since = v(1, 95, 0) },
    .{ .name = "import", .since = v(1, 80, 0) },
    .{ .name = "legacy-js-api", .since = v(1, 79, 0), .dart_sass_2 = true },
    .{ .name = "misplaced-rest", .since = v(1, 91, 0), .dart_sass_2 = true },
    .{ .name = "mixed-decls", .since = v(1, 77, 7), .obsolete = true },
    .{ .name = "moz-document", .since = v(1, 7, 2), .dart_sass_2 = true },
    .{ .name = "new-global", .since = v(1, 17, 2), .dart_sass_2 = true },
    .{ .name = "null-alpha", .since = v(1, 62, 3), .dart_sass_2 = true },
    .{ .name = "relative-canonical", .since = v(1, 14, 2), .dart_sass_2 = true },
    .{ .name = "slash-div", .since = v(1, 33, 0), .dart_sass_2 = true },
    .{ .name = "strict-unary", .since = v(1, 55, 0), .dart_sass_2 = true },
    .{ .name = "type-function", .since = v(1, 86, 0), .obsolete = true },
    .{ .name = "user-authored" },
    .{ .name = "with-private", .since = v(1, 92, 0), .dart_sass_2 = true },
};

comptime {
    std.debug.assert(known_deprecations.len <= 64);
    // Every reported kind must be an id the official CLI knows.
    for (@typeInfo(DeprecationKind).@"enum".field_values) |field_value| {
        const kind: DeprecationKind = @fromBackingInt(@intCast(field_value));
        std.debug.assert(lookupKnownDeprecation(kind.kindName()) != null);
    }
}

fn lookupKnownDeprecation(name: []const u8) ?usize {
    for (known_deprecations, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

fn knownDeprecationBit(index: usize) u64 {
    return @as(u64, 1) << @intCast(index);
}

/// Make the deprecation at `index` fatal.
fn includeFatalDeprecation(opts: *DeprecationOpts, index: usize) void {
    opts.fatal_included |= knownDeprecationBit(index);
    if (DeprecationKind.parse(known_deprecations[index].name)) |kind| opts.fatal.insert(kind);
}

fn mergeFatalDeprecationsForVersion(opts: *DeprecationOpts, version: SassVersion) void {
    for (known_deprecations, 0..) |entry, index| {
        if (entry.obsolete) continue;
        const since = entry.since orelse continue;
        if (since.order(version) != .gt) includeFatalDeprecation(opts, index);
    }
}

/// Where the built-in function being called was called, for the
/// deprecations it raises: they have no location of their own.
pub const CallSite = struct {
    path: []const u8,
    line_starts: []const u32,
    offset: u32,
    /// Where the call ends, when known, for the caret under it.
    end_offset: ?u32 = null,
    /// `line_starts` is not at hand: read `path` to place `offset`.
    read_source: bool = false,
};

pub threadlocal var builtin_call_site: ?CallSite = null;

/// Builds the trace of the code running now (outermost frame first) for a
/// warning, set by the VM while it runs. Returns how many frames it filled.
pub const TraceProvider = struct {
    ctx: *anyopaque,
    build: *const fn (ctx: *anyopaque, out: []error_format.ErrorTraceFrame) usize,
};

pub threadlocal var trace_provider: ?TraceProvider = null;

/// Whether a warning may read its file for the source line it shows. The
/// embedding API turns it off: its sources need not be the files on disk.
pub threadlocal var read_sources_for_warnings: bool = true;

fn callSiteLineCol(site: CallSite) struct { line: u32, col: u32 } {
    if (site.read_source) {
        const source = std.Io.Dir.cwd().readFileAlloc(zsass_io.io, site.path, std.heap.c_allocator, .unlimited) catch
            return .{ .line = 1, .col = site.offset + 1 };
        defer std.heap.c_allocator.free(source);
        var line: u32 = 1;
        var line_start: usize = 0;
        const end = @min(@as(usize, site.offset), source.len);
        for (source[0..end], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{ .line = line, .col = @intCast(end - line_start + 1) };
    }
    var lo: usize = 0;
    var hi: usize = site.line_starts.len;
    if (hi == 0) return .{ .line = 1, .col = site.offset + 1 };
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (site.line_starts[mid] <= site.offset) lo = mid else hi = mid;
    }
    return .{ .line = @intCast(lo + 1), .col = (site.offset -| site.line_starts[lo]) + 1 };
}

pub const SlashDivDeprecationSite = struct {
    opts: *DeprecationOpts,
    path: []const u8,
    line: u32,
    col: u32,
};

pub const DeprecationOpts = struct {
    /// Takes the warnings written and counted by `other`, a copy these
    /// options were given to run part of the same compilation.
    pub fn takeWarningState(self: *DeprecationOpts, other: *const DeprecationOpts) void {
        self.emitted = other.emitted;
        self.shown_counts = other.shown_counts;
        self.omitted = other.omitted;
        self.seen = other.seen;
        self.seen_len = other.seen_len;
    }

    /// Records `key`; true when it was recorded before.
    fn alreadyWarned(self: *DeprecationOpts, key: u64) bool {
        for (self.seen[0..self.seen_len]) |k| {
            if (k == key) return true;
        }
        if (self.seen_len < self.seen.len) {
            self.seen[self.seen_len] = key;
            self.seen_len += 1;
        }
        return false;
    }

    silenced: std.enums.EnumSet(DeprecationKind) = .empty,
    fatal: std.enums.EnumSet(DeprecationKind) = .empty,
    future: std.enums.EnumSet(DeprecationKind) = .empty,
    emitted: std.enums.EnumSet(DeprecationKind) = .empty,
    /// Warnings shown for each kind; past `max_repeated_warnings`, the rest
    /// are only counted in `omitted` unless `verbose`.
    shown_counts: std.enums.EnumArray(DeprecationKind, u32) = .initFill(0),
    omitted: u32 = 0,
    /// Warnings already written, by `warningKey`: the same message at the
    /// same place is written once, as in the official CLI.
    seen: [max_seen_warnings]u64 = @splat(0),
    seen_len: u32 = 0,
    /// Ids made fatal and ids excluded with `--fatal-deprecation=-<id>`, as
    /// bits indexed like `known_deprecations`. `finalizeDeprecationOpts`
    /// applies the exclusions once every flag has been read.
    fatal_included: u64 = 0,
    fatal_excluded: u64 = 0,
    verbose: bool = false,
    quiet: bool = false,
    /// Set while an expression is folded ahead of time: a deprecation
    /// fails the folding silently, so the expression runs where it can warn.
    probe: bool = false,
    /// When true, deprecation warnings print a stack trace when available (dart `--trace`).
    trace_deprecation: bool = false,
};

/// Pre-dedup record of one `emitDeprecation` call, captured while an
/// import-preamble checkpoint is being built so checkpoint forks can replay
/// the exact same calls (dedup/fatal state then evolves per entry as usual).
pub const RecordedDeprecation = struct {
    kind: DeprecationKind,
    msg: []const u8,
    path: []const u8,
    line: u32,
    col: u32,
};

pub const DeprecationRecorder = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayListUnmanaged(RecordedDeprecation) = .empty,
    /// Set on any allocation failure; the capture is then rejected instead of
    /// risking an incomplete replay.
    failed: bool = false,

    pub fn deinit(self: *DeprecationRecorder) void {
        for (self.items.items) |item| {
            self.alloc.free(item.msg);
            self.alloc.free(item.path);
        }
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    fn record(self: *DeprecationRecorder, kind: DeprecationKind, msg: []const u8, path: []const u8, line: u32, col: u32) void {
        if (self.failed) return;
        const msg_copy = self.alloc.dupe(u8, msg) catch {
            self.failed = true;
            return;
        };
        const path_copy = self.alloc.dupe(u8, path) catch {
            self.alloc.free(msg_copy);
            self.failed = true;
            return;
        };
        self.items.append(self.alloc, .{
            .kind = kind,
            .msg = msg_copy,
            .path = path_copy,
            .line = line,
            .col = col,
        }) catch {
            self.alloc.free(msg_copy);
            self.alloc.free(path_copy);
            self.failed = true;
        };
    }
};

threadlocal var active_recorder: ?*DeprecationRecorder = null;

/// Installs (or clears) the calling thread's deprecation recorder and returns
/// the previous one so nested windows restore correctly.
pub fn swapActiveRecorder(recorder: ?*DeprecationRecorder) ?*DeprecationRecorder {
    const prev = active_recorder;
    active_recorder = recorder;
    return prev;
}

pub fn emitDeprecation(
    opts: *DeprecationOpts,
    kind: DeprecationKind,
    msg: []const u8,
    path: []const u8,
    line: u32,
    col: u32,
) !void {
    // A built-in function's warning is located where it was called.
    var at_path = path;
    var at_line = line;
    var at_col = col;
    var at_end_col: u32 = 0;
    if (path.len == 0) {
        if (builtin_call_site) |site| {
            const pos = callSiteLineCol(site);
            at_path = site.path;
            at_line = pos.line;
            at_col = pos.col;
            if (site.end_offset) |end| {
                var end_site = site;
                end_site.offset = end;
                const end_pos = callSiteLineCol(end_site);
                if (end_pos.line == pos.line) at_end_col = end_pos.col;
            }
        }
    }
    return emitDeprecationAt(opts, kind, msg, at_path, at_line, at_col, at_end_col);
}

/// `emitDeprecation` with the column the warning's span ends at on its
/// line, for the source line it shows.
pub fn emitDeprecationSpan(
    opts: *DeprecationOpts,
    kind: DeprecationKind,
    msg: []const u8,
    path: []const u8,
    line: u32,
    col: u32,
    end_col: u32,
) !void {
    return emitDeprecationAt(opts, kind, msg, path, line, col, end_col);
}

/// Where a warning happened, as Sass shows it: the source line with a
/// caret, then the trace. The running VM supplies the trace; otherwise it
/// is the one position given, in the root stylesheet.
fn writeWarningLocation(path: []const u8, line: u32, col: u32, end_col: u32) void {
    var frames: [error_format.max_error_stack]error_format.ErrorTraceFrame = undefined;
    if (trace_provider) |provider| {
        const n = provider.build(provider.ctx, &frames);
        if (n > 0) {
            error_format.writeTraceFrames(std.heap.c_allocator, frames[0..n], true, "    ") catch {};
            return;
        }
    }
    if (path.len == 0) return;
    const source = if (read_sources_for_warnings)
        std.Io.Dir.cwd().readFileAlloc(zsass_io.io, path, std.heap.c_allocator, .limited(64 << 20)) catch null
    else
        null;
    defer if (source) |src| std.heap.c_allocator.free(src);
    var line_text: []const u8 = "";
    if (source) |src| {
        var it = std.mem.splitScalar(u8, src, '\n');
        var current: u32 = 1;
        while (it.next()) |text| : (current += 1) {
            if (current == line) {
                line_text = std.mem.trimEnd(u8, text, "\r");
                break;
            }
        }
    }
    const end = if (end_col > col) end_col else col + 1;
    // While the resolver loads modules, its frames are the trace: each
    // module loaded at its `@use`/`@forward`/`@import`, the innermost at
    // the warning.
    var n: usize = 0;
    const stack = error_format.error_state.error_stack[0..error_format.error_state.error_stack_len];
    if (stack.len > 0 and std.mem.eql(u8, stack[stack.len - 1].path, path)) {
        for (stack[0 .. stack.len - 1]) |frame| {
            if (n + 1 >= frames.len) break;
            const pos = offsetLineCol(frame.source, if (frame.has_span) frame.span_start else 0);
            error_format.fillTraceFrame(&frames[n], frame.path, frame.label, pos.line, pos.col, pos.line, pos.col, "");
            n += 1;
        }
        error_format.fillTraceFrame(&frames[n], path, stack[stack.len - 1].label, line, col, line, end, line_text);
    } else {
        error_format.fillTraceFrame(&frames[n], path, "root stylesheet", line, col, line, end, line_text);
    }
    n += 1;
    error_format.writeTraceFrames(std.heap.c_allocator, frames[0..n], line_text.len != 0, "    ") catch {};
}

fn offsetLineCol(source: []const u8, offset: u32) struct { line: u32, col: u32 } {
    const end = @min(@as(usize, offset), source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..end], '\n')) |nl| nl + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, source[0..line_start], "\n") + 1), .col = @intCast(end - line_start + 1) };
}

fn emitDeprecationAt(
    opts: *DeprecationOpts,
    kind: DeprecationKind,
    msg: []const u8,
    path: []const u8,
    line: u32,
    col: u32,
    end_col: u32,
) !void {
    if (opts.probe) return error.SassError;
    if (active_recorder) |recorder| recorder.record(kind, msg, path, line, col);
    // A fatal deprecation fails the compilation even when warnings are
    // quiet or this one is silenced, as in the official CLI.
    // The error is reported with the deprecation's message where it
    // happened, as in the official CLI.
    if (opts.fatal.contains(kind)) {
        var buf: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}\n\nThis is only an error because you've set the {s} deprecation to be fatal.\nRemove this setting if you need to keep using this feature.", .{ msg, kind.kindName() }) catch msg;
        error_format.setContextMessage(text);
        return error.FatalDeprecation;
    }
    if (opts.quiet) return;
    if (opts.silenced.contains(kind)) return;
    if (opts.alreadyWarned(warningKey(kind, msg, path, line, col))) return;
    if (!opts.verbose) {
        const shown = opts.shown_counts.get(kind);
        if (shown >= max_repeated_warnings) {
            opts.omitted += 1;
            return;
        }
        opts.shown_counts.set(kind, shown + 1);
    }
    opts.emitted.insert(kind);

    var err_file = std.Io.File.stderr();
    var err_buf: [1024]u8 = undefined;
    var err_w = err_file.writerStreaming(zsass_io.io, err_buf[0..]);
    err_w.interface.print("DEPRECATION WARNING [{s}]: {s}\n\n", .{ kind.kindName(), msg }) catch {};
    err_w.interface.flush() catch |flush_err| {
        switch (flush_err) {
            else => {},
        }
    }; // best-effort logging
    writeWarningLocation(path, line, col, end_col);
    err_w.interface.writeAll("\n") catch {};
    err_w.interface.flush() catch {};

    if (opts.trace_deprecation) {
        error_format.writeStackTrace(std.heap.c_allocator) catch |trace_err| switch (trace_err) {
            else => {},
        };
    }
}

/// As the official CLI: five warnings of each kind, then a count.
const max_repeated_warnings: u32 = 5;

/// Distinct warnings remembered for de-duplication; past it, a repeat may
/// be written again.
const max_seen_warnings = 1024;

fn warningKey(kind: DeprecationKind, msg: []const u8, path: []const u8, line: u32, col: u32) u64 {
    var h = std.hash.Wyhash.init(@backingInt(kind));
    h.update(msg);
    h.update(&.{0});
    h.update(path);
    h.update(std.mem.asBytes(&line));
    h.update(std.mem.asBytes(&col));
    return h.final() | 1;
}

/// "WARNING: N repetitive deprecation warnings omitted." once a
/// compilation is done, when any were.
pub fn writeOmittedSummary(opts: *const DeprecationOpts) void {
    if (opts.omitted == 0 or opts.quiet) return;
    var err_file = std.Io.File.stderr();
    var err_buf: [256]u8 = undefined;
    var err_w = err_file.writerStreaming(zsass_io.io, err_buf[0..]);
    err_w.interface.print("WARNING: {d} repetitive deprecation warnings omitted.\nRun in verbose mode to see all warnings.\n\n", .{opts.omitted}) catch {};
    err_w.interface.flush() catch {};
}

pub const DeprecationSetType = enum { silence, fatal, future };

pub const ParseDeprecationError = error{
    UnknownDeprecationToken,
    DeprecationVersionTooNew,
    DeprecationExcludedWithoutInclude,
};

fn printDeprecationOptionMessage(comptime fmt: []const u8, args: anytype) void {
    var err_file = std.Io.File.stderr();
    var err_buf: [512]u8 = undefined;
    var err_w = err_file.writerStreaming(zsass_io.io, err_buf[0..]);
    err_w.interface.print(fmt, args) catch {};
    err_w.interface.flush() catch |flush_err| switch (flush_err) {
        else => {},
    };
}

/// Read one `--silence-deprecation`, `--fatal-deprecation` or
/// `--future-deprecation` value. A fatal list may also hold a Sass version
/// (every deprecation active in or before it), `dart-sass-2`, and `-<id>` to
/// exclude an id; call `finalizeDeprecationOpts` after the last flag.
pub fn parseDeprecationList(opts: *DeprecationOpts, set_type: DeprecationSetType, raw: []const u8) ParseDeprecationError!void {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |kind_name| {
        const trimmed = std.mem.trim(u8, kind_name, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (set_type == .fatal and trimmed[0] == '-') {
            if (lookupKnownDeprecation(trimmed[1..])) |index| {
                opts.fatal_excluded |= knownDeprecationBit(index);
                continue;
            }
        } else if (lookupKnownDeprecation(trimmed)) |index| {
            const entry = known_deprecations[index];
            switch (set_type) {
                .silence => {
                    if (entry.obsolete) {
                        printDeprecationOptionMessage(
                            "WARNING: {s} deprecation is obsolete. If you were previously silencing it, your code may now behave in unexpected ways.\n",
                            .{entry.name},
                        );
                    }
                    if (DeprecationKind.parse(entry.name)) |kind| opts.silenced.insert(kind);
                },
                .fatal => {
                    if (entry.obsolete) {
                        printDeprecationOptionMessage(
                            "WARNING: {s} deprecation is obsolete, so does not need to be made fatal.\n",
                            .{entry.name},
                        );
                    }
                    includeFatalDeprecation(opts, index);
                },
                .future => {
                    if (DeprecationKind.parse(entry.name)) |kind| opts.future.insert(kind);
                },
            }
            continue;
        } else if (DeprecationKind.parse(trimmed)) |kind| {
            // Older zsass releases also accepted `slash_div` and `Slash-Div`.
            switch (set_type) {
                .silence => opts.silenced.insert(kind),
                .fatal => includeFatalDeprecation(opts, lookupKnownDeprecation(kind.kindName()).?),
                .future => opts.future.insert(kind),
            }
            continue;
        } else if (set_type == .fatal) {
            if (std.mem.eql(u8, trimmed, "dart-sass-2")) {
                for (known_deprecations, 0..) |entry, index| {
                    if (entry.dart_sass_2) includeFatalDeprecation(opts, index);
                }
                continue;
            }
            if (SassVersion.parse(trimmed)) |version| {
                if (version.order(SassVersion.known_max) == .gt) {
                    printDeprecationOptionMessage(
                        "error: invalid version {d}.{d}.{d}; --fatal-deprecation requires a version <= {d}.{d}.{d}\n",
                        .{ version.major, version.minor, version.patch, SassVersion.known_max.major, SassVersion.known_max.minor, SassVersion.known_max.patch },
                    );
                    return error.DeprecationVersionTooNew;
                }
                mergeFatalDeprecationsForVersion(opts, version);
                continue;
            }
        }
        printDeprecationOptionMessage("error: unknown deprecation kind: '{s}'\n", .{trimmed});
        return error.UnknownDeprecationToken;
    }
}

/// Apply the `--fatal-deprecation=-<id>` exclusions and settle conflicts
/// between the flags. Call once, after every deprecation flag has been read:
/// an exclusion is independent of the order the flags were written in.
pub fn finalizeDeprecationOpts(opts: *DeprecationOpts) ParseDeprecationError!void {
    for (known_deprecations, 0..) |entry, index| {
        const bit = knownDeprecationBit(index);
        if (opts.fatal_excluded & bit == 0) continue;
        if (opts.fatal_included & bit == 0) {
            printDeprecationOptionMessage(
                "error: the fatal deprecation \"{s}\" was excluded without first being included\n",
                .{entry.name},
            );
            return error.DeprecationExcludedWithoutInclude;
        }
        opts.fatal_included &= ~bit;
        if (DeprecationKind.parse(entry.name)) |kind| opts.fatal.remove(kind);
    }
    opts.fatal_excluded = 0;

    inline for (@typeInfo(DeprecationKind).@"enum".field_names) |field_name| {
        const kind: DeprecationKind = @field(DeprecationKind, field_name);
        if (opts.fatal.contains(kind) and opts.silenced.contains(kind)) {
            printDeprecationOptionMessage(
                "WARNING: Ignoring setting to silence {s} deprecation, since it has also been made fatal.\n",
                .{kind.kindName()},
            );
            opts.silenced.remove(kind);
        }
    }
}

test "fatal deprecation list: a version includes what was active by then" {
    var opts: DeprecationOpts = .{};
    try parseDeprecationList(&opts, .fatal, "1.79.9");
    try finalizeDeprecationOpts(&opts);
    try std.testing.expect(opts.fatal.contains(.slash_div));
    try std.testing.expect(opts.fatal.contains(.color_functions));
    try std.testing.expect(!opts.fatal.contains(.import));
    // An obsolete deprecation is not included by a version.
    try std.testing.expect(!opts.fatal.contains(.mixed_decls));
}

test "fatal deprecation list: an exclusion is independent of flag order" {
    const lists = [_][]const []const u8{
        &.{"1.80.0,-import"},
        &.{"-import,1.80.0"},
        &.{ "-import", "1.80.0" },
        &.{ "import", "-import" },
    };
    for (lists) |flags| {
        var opts: DeprecationOpts = .{};
        for (flags) |flag| try parseDeprecationList(&opts, .fatal, flag);
        try finalizeDeprecationOpts(&opts);
        try std.testing.expect(!opts.fatal.contains(.import));
    }
}

test "fatal deprecation list: dart-sass-2 leaves out what Dart Sass 3 removes" {
    var opts: DeprecationOpts = .{};
    try parseDeprecationList(&opts, .fatal, "dart-sass-2,-slash-div");
    try finalizeDeprecationOpts(&opts);
    try std.testing.expect(opts.fatal.contains(.color_functions));
    try std.testing.expect(!opts.fatal.contains(.slash_div));
    try std.testing.expect(!opts.fatal.contains(.import));
}

test "deprecation lists accept ids zsass does not report" {
    var opts: DeprecationOpts = .{};
    try parseDeprecationList(&opts, .silence, "global-builtin,if-function,import");
    try parseDeprecationList(&opts, .fatal, "1.108.2,-global-builtin");
    try finalizeDeprecationOpts(&opts);
    try std.testing.expect(opts.silenced.contains(.import) == false);
    try std.testing.expect(opts.fatal.contains(.import));
}

test "a fatal deprecation fails even when quiet or silenced" {
    var opts: DeprecationOpts = .{ .quiet = true };
    opts.fatal.insert(.import);
    try std.testing.expectError(error.FatalDeprecation, emitDeprecation(&opts, .import, "m", "a.scss", 1, 1));
    opts.quiet = false;
    opts.silenced.insert(.import);
    try std.testing.expectError(error.FatalDeprecation, emitDeprecation(&opts, .import, "m", "a.scss", 1, 1));
    var quiet_only: DeprecationOpts = .{ .quiet = true };
    try emitDeprecation(&quiet_only, .import, "m", "a.scss", 1, 1);
}
