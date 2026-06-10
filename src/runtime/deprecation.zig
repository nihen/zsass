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
        inline for (@typeInfo(DeprecationKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, norm, field.name)) return @field(DeprecationKind, field.name);
        }
        return null;
    }

    /// Sass language version when this deprecation became active (official Sass CLI compatible thresholds).
    pub fn activatedIn(self: DeprecationKind) ?SassVersion {
        return switch (self) {
            .import => .{ .major = 1, .minor = 80, .patch = 0 },
            .slash_div => .{ .major = 1, .minor = 33, .patch = 0 },
            .strict_unary => .{ .major = 1, .minor = 55, .patch = 0 },
            .function_units => .{ .major = 1, .minor = 56, .patch = 0 },
            .duplicate_var_flags => .{ .major = 1, .minor = 62, .patch = 0 },
            .null_alpha => .{ .major = 1, .minor = 62, .patch = 3 },
            .abs_percent => .{ .major = 1, .minor = 65, .patch = 0 },
            .color_functions => .{ .major = 1, .minor = 79, .patch = 0 },
            .mixed_decls => .{ .major = 1, .minor = 77, .patch = 7 },
            .fs_importer_cwd => .{ .major = 1, .minor = 23, .patch = 0 },
            .css_function_mixin => null,
        };
    }
};

pub const SassVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    /// Highest Sass version accepted by `--fatal-deprecation=<version>` (official Sass CLI parity).
    pub const known_max: SassVersion = .{ .major = 1, .minor = 99, .patch = 0 };

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

fn mergeFatalDeprecationsForVersion(opts: *DeprecationOpts, version: SassVersion) void {
    inline for (@typeInfo(DeprecationKind).@"enum".fields) |field| {
        const k: DeprecationKind = @field(DeprecationKind, field.name);
        if (k.activatedIn()) |activated| {
            if (activated.order(version) != .gt) opts.fatal.insert(k);
        }
    }
}

pub const SlashDivDeprecationSite = struct {
    opts: *DeprecationOpts,
    path: []const u8,
    line: u32,
    col: u32,
};

pub const DeprecationOpts = struct {
    silenced: std.enums.EnumSet(DeprecationKind) = .empty,
    fatal: std.enums.EnumSet(DeprecationKind) = .empty,
    future: std.enums.EnumSet(DeprecationKind) = .empty,
    emitted: std.enums.EnumSet(DeprecationKind) = .empty,
    verbose: bool = false,
    quiet: bool = false,
    /// When true, deprecation warnings print a stack trace when available (dart `--trace`).
    trace_deprecation: bool = false,

    pub fn warnDeprecationOnceShown(opts: *DeprecationOpts) void {
        if (opts.verbose) return;
        if (opts.quiet) return;
        var err_file = std.Io.File.stderr();
        var err_buf: [512]u8 = undefined;
        var err_w = err_file.writer(zsass_io.io, err_buf[0..]);
        err_w.interface.writeAll("DEPRECATION WARNING: Use of deprecated Sass features detected. Run with --verbose to see per-invocation details.\n") catch return;
        err_w.interface.flush() catch return;
    }
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
    if (active_recorder) |recorder| recorder.record(kind, msg, path, line, col);
    if (opts.quiet) return;
    if (opts.silenced.contains(kind)) return;
    if (opts.fatal.contains(kind)) {
        var err_file = std.Io.File.stderr();
        var err_buf: [512]u8 = undefined;
        var err_w = err_file.writer(zsass_io.io, err_buf[0..]);
        err_w.interface.print(
            "Error: Deprecation [{s}]: {s}\n     on line {d}, column {d} of {s}\n",
            .{ kind.kindName(), msg, line, col, path },
        ) catch {};
        err_w.interface.flush() catch |flush_err| {
            switch (flush_err) {
                else => {},
            }
        }; // best-effort logging
        return error.FatalDeprecation;
    }
    if (!opts.verbose and opts.emitted.contains(kind)) return;
    opts.emitted.insert(kind);

    var err_file = std.Io.File.stderr();
    var err_buf: [1024]u8 = undefined;
    var err_w = err_file.writer(zsass_io.io, err_buf[0..]);
    err_w.interface.print(
        "DEPRECATION WARNING [{s}]: {s}\n  {s} {d}:{d}\n",
        .{ kind.kindName(), msg, path, line, col },
    ) catch {};
    err_w.interface.flush() catch |flush_err| {
        switch (flush_err) {
            else => {},
        }
    }; // best-effort logging

    if (opts.trace_deprecation) {
        error_format.writeStackTrace(std.heap.c_allocator) catch |trace_err| switch (trace_err) {
            else => {},
        };
    }
}

pub const DeprecationSetType = enum { silence, fatal, future };

pub const ParseDeprecationError = error{
    UnknownDeprecationToken,
    DeprecationVersionTooNew,
};

pub fn parseDeprecationList(opts: *DeprecationOpts, set_type: DeprecationSetType, raw: []const u8) ParseDeprecationError!void {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |kind_name| {
        const trimmed = std.mem.trim(u8, kind_name, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (DeprecationKind.parse(trimmed)) |kind| {
            switch (set_type) {
                .silence => opts.silenced.insert(kind),
                .fatal => opts.fatal.insert(kind),
                .future => opts.future.insert(kind),
            }
            continue;
        }
        if (set_type == .fatal) {
            if (SassVersion.parse(trimmed)) |version| {
                if (version.order(SassVersion.known_max) == .gt) {
                    var err_file = std.Io.File.stderr();
                    var err_buf: [256]u8 = undefined;
                    var err_w = err_file.writer(zsass_io.io, err_buf[0..]);
                    err_w.interface.print(
                        "error: invalid version {d}.{d}.{d}; --fatal-deprecation requires a version <= {d}.{d}.{d}\n",
                        .{ version.major, version.minor, version.patch, SassVersion.known_max.major, SassVersion.known_max.minor, SassVersion.known_max.patch },
                    ) catch {};
                    err_w.interface.flush() catch |flush_err| switch (flush_err) {
                        else => {},
                    };
                    return error.DeprecationVersionTooNew;
                }
                mergeFatalDeprecationsForVersion(opts, version);
                continue;
            }
        }
        var err_file = std.Io.File.stderr();
        var err_buf: [512]u8 = undefined;
        var err_w = err_file.writer(zsass_io.io, err_buf[0..]);
        err_w.interface.print("error: unknown deprecation kind: '{s}'\n", .{trimmed}) catch {};
        err_w.interface.flush() catch |flush_err| switch (flush_err) {
            else => {},
        };
        return error.UnknownDeprecationToken;
    }
}
