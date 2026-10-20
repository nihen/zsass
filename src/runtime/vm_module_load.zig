//! First-class modules: module reference values, `meta.load()` and `meta.css()`.
const std = @import("std");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");

const vm_cross_module = @import("vm_cross_module.zig");
const resolver_mod = @import("../resolve/resolver.zig");
const error_format = @import("error_format.zig");
const builtin_shared = @import("../builtin/shared.zig");
const rule_ir_mod = @import("../ir/rule_ir.zig");
const names_mod = @import("../resolve/names.zig");

const Value = value_mod.Value;
const InternId = intern_pool_mod.InternId;
const call_arg_splat_sentinel = resolver_mod.call_arg_splat_sentinel;
const content_none_sentinel: u32 = std.math.maxInt(u32);

pub const ModuleRefTarget = union(enum) {
    builtin: []const u8,
    user: u32,
    not_found,
};

fn isSassNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isSassNameChar(c: u8) bool {
    return isSassNameStart(c) or std.ascii.isDigit(c) or c == '-';
}

fn isPlainSassIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    var rest = text;
    if (rest[0] == '-') {
        if (rest.len == 1) return false;
        if (rest[1] != '-' and !isSassNameStart(rest[1])) return false;
        rest = rest[2..];
    } else {
        if (!isSassNameStart(rest[0])) return false;
        rest = rest[1..];
    }
    for (rest) |c| {
        if (!isSassNameChar(c)) return false;
    }
    return true;
}

/// Namespace shown by `meta.inspect()` for a module: the canonical URL's
/// basename without a leading `_` or any extension. It does not depend on
/// the `@use ... as` alias.
fn moduleDisplayNamespace(path: []const u8) []const u8 {
    var base = std.fs.path.basename(path);
    if (base.len > 0 and base[0] == '_') base = base[1..];
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    return base;
}

fn makeModuleRefValue(vm: anytype, namespace: []const u8, identity: []const u8) !Value {
    const sep = value_mod.module_ref_separator;
    const key = if (isPlainSassIdentifier(namespace))
        try std.fmt.allocPrint(vm.allocator, "get-module(\"{s}\"){c}{s}", .{ namespace, sep, identity })
    else
        try std.fmt.allocPrint(vm.allocator, "get-module(){c}{s}", .{ sep, identity });
    defer vm.allocator.free(key);
    return Value.moduleRef(try vm.intern_pool.intern(key));
}

pub fn makeBuiltinModuleRef(vm: anytype, name: []const u8) !Value {
    var buf: [64]u8 = undefined;
    const identity = std.fmt.bufPrint(&buf, "sass:{s}", .{name}) catch return error.OutOfMemory;
    return makeModuleRefValue(vm, name, identity);
}

pub fn makeUserModuleRef(vm: anytype, module_id: u32) !Value {
    if (module_id >= vm.program.modules.len) return error.SassError;
    const path = vm.program.modules[module_id].module_path;
    if (path.len == 0) {
        var buf: [32]u8 = undefined;
        const identity = std.fmt.bufPrint(&buf, "#{d}", .{module_id}) catch return error.OutOfMemory;
        return makeModuleRefValue(vm, "", identity);
    }
    return makeModuleRefValue(vm, moduleDisplayNamespace(path), path);
}

pub fn moduleIdForPath(vm: anytype, path: []const u8) ?u32 {
    for (vm.program.modules, 0..) |mod, i| {
        if (std.mem.eql(u8, mod.module_path, path)) return @intCast(i);
    }
    return null;
}

pub fn resolveModuleRef(vm: anytype, ref: Value) ModuleRefTarget {
    const identity = value_mod.moduleRefIdentity(vm.intern_pool.get(ref.moduleRefKey()));
    if (std.mem.startsWith(u8, identity, "sass:")) return .{ .builtin = identity["sass:".len..] };
    if (std.mem.startsWith(u8, identity, "#")) {
        const mid = std.fmt.parseInt(u32, identity[1..], 10) catch return .not_found;
        return if (mid < vm.program.modules.len) .{ .user = mid } else .not_found;
    }
    return if (moduleIdForPath(vm, identity)) |mid| .{ .user = mid } else .not_found;
}

fn setMessage(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    error_format.setContextMessage(msg);
}

fn reportMissingNamespace(namespace: []const u8) error{SassError} {
    setMessage("There is no module with namespace \"{s}\".", .{namespace});
    return error.SassError;
}

/// Look up `namespace` among the current module's `@use` bindings.
pub fn moduleTargetForNamespace(vm: anytype, namespace: []const u8) error{SassError}!ModuleRefTarget {
    if (vm.current_module >= vm.program.modules.len) return error.SassError;
    const mod = &vm.program.modules[vm.current_module];
    const binding = mod.use_map.get(namespace) orelse return reportMissingNamespace(namespace);
    return switch (binding) {
        .builtin_module => |name| .{ .builtin = name },
        .user_module => |mid| .{ .user = mid },
    };
}

/// Binds the single `$module` parameter of `meta.css()`.
fn bindSingleModuleArg(vm: anytype, args: []const Value, arg_names: []const InternId) !Value {
    var bound: ?usize = null;
    for (args, 0..) |_, i| {
        const name_id = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id == call_arg_splat_sentinel) return error.BuiltinUnsupported;
        if (name_id == .none) {
            if (bound != null) return builtin_shared.badArity(1, args.len);
            bound = i;
            continue;
        }
        var raw = vm.intern_pool.get(name_id);
        if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
        if (!builtin_shared.identifierEq(raw, "module") or bound != null) return builtin_shared.badArity(1, args.len);
        bound = i;
    }
    const idx = bound orelse return builtin_shared.reportMissingArgument("module");
    return args[idx];
}

/// `meta.css($module)`: emits the CSS of `$module` (including its upstream
/// modules) at the current position.
pub fn invokeMetaCss(self: anytype, args: []const Value, arg_names: []const InternId) !void {
    if (self.pending_content_chunk != content_none_sentinel) return error.BuiltinUnsupported;
    const module_v = try bindSingleModuleArg(self, args, arg_names);
    const target: ModuleRefTarget = switch (module_v.kind()) {
        .module => resolveModuleRef(self, module_v),
        .string => try moduleTargetForNamespace(self, self.intern_pool.get(module_v.stringIntern())),
        else => {
            self.recordModuleArgumentMismatchMessage(module_v);
            return error.BuiltinType;
        },
    };
    switch (target) {
        .builtin => return,
        .not_found => return error.SassError,
        .user => |mid| try emitModuleCss(self, mid),
    }
}

/// Emits the CSS of an executed user module at the current position. The
/// CSS is re-materialized through the `meta.load-css()` path, seeded from the
/// module's saved global state; the re-run is quiet and never writes module
/// state back.
pub fn emitModuleCss(self: anytype, module_id: u32) !void {
    const path = self.program.modules[module_id].module_path;
    if (path.len == 0) return error.SassError;
    const owner_module = self.effectiveModuleTag();
    const child_tag = self.allocateLoadCssModuleTag();
    try self.registerVisibleLoadCssModule(owner_module, owner_module, std.math.maxInt(u32), child_tag);
    try vm_cross_module.runLoadCssModule(self, path, .{}, .{ .sync_state = false, .quiet = true });
}

const LoadConfigEntry = struct {
    /// `$`-less name with `_` normalized to `-`.
    name: []u8,
    value: Value,
};

fn freeLoadConfig(alloc: std.mem.Allocator, entries: []LoadConfigEntry) void {
    for (entries) |entry| alloc.free(entry.name);
    alloc.free(entries);
}

fn parseLoadConfig(self: anytype, ctx: anytype, with_v: Value) builtin_shared.BuiltinError![]LoadConfigEntry {
    const alloc = self.allocator;
    if (with_v.kind() == .nil) return try alloc.alloc(LoadConfigEntry, 0);
    if (with_v.kind() != .list) return builtin_shared.reportArgumentTypeMismatch(ctx, "with", with_v, "map");
    const items = self.list_pool.items[with_v.listHandle()];
    if (items.len == 0) return try alloc.alloc(LoadConfigEntry, 0);
    if (!with_v.listIsMap(self.list_meta_pool.items) or items.len % 2 != 0) {
        return builtin_shared.reportArgumentTypeMismatch(ctx, "with", with_v, "map");
    }
    var out: std.ArrayListUnmanaged(LoadConfigEntry) = .empty;
    errdefer {
        for (out.items) |entry| alloc.free(entry.name);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i + 1 < items.len) : (i += 2) {
        const key = items[i];
        if (key.kind() != .string) return builtin_shared.reportArgumentTypeMismatch(ctx, "with key", key, "string");
        var raw = self.intern_pool.get(key.stringIntern());
        if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
        const name = try alloc.dupe(u8, raw);
        for (name) |*c| {
            if (c.* == '_') c.* = '-';
        }
        for (out.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                setMessage("The variable ${s} was configured twice.", .{name});
                alloc.free(name);
                return error.SassError;
            }
        }
        out.append(alloc, .{ .name = name, .value = items[i + 1] }) catch |err| {
            alloc.free(name);
            return err;
        };
    }
    return try out.toOwnedSlice(alloc);
}

fn lookupVarTarget(map: anytype, name: []const u8) ?resolver_mod.VarTarget {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (builtin_shared.identifierEq(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn nameIsAmbiguous(map: anytype, name: []const u8) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (builtin_shared.identifierEq(entry.key_ptr.*, name)) return true;
    }
    return false;
}

/// Seeds `$with` values into the configurable variables of `module_id`
/// before it runs, like `@use ... with`.
fn configTarget(self: anytype, module_id: u32, name: []const u8) builtin_shared.BuiltinError!resolver_mod.VarTarget {
    const mod = &self.program.modules[module_id];
    const target = lookupVarTarget(&mod.exported_default_vars, name);
    if (nameIsAmbiguous(&mod.ambiguous_export_default_vars, name) or
        (target == null and nameIsAmbiguous(&mod.ambiguous_star_vars, name)))
    {
        setMessage("This variable is available from multiple global modules.", .{});
        return error.SassError;
    }
    return target orelse {
        setMessage("${s} was not declared with !default in the @used module.", .{name});
        return error.SassError;
    };
}

fn validateLoadConfig(self: anytype, module_id: u32, entries: []const LoadConfigEntry) builtin_shared.BuiltinError!void {
    for (entries) |entry| _ = try configTarget(self, module_id, entry.name);
}

fn applyLoadConfig(self: anytype, module_id: u32, entries: []const LoadConfigEntry) builtin_shared.BuiltinError!void {
    for (entries) |entry| {
        const target = try configTarget(self, module_id, entry.name);
        if (target.module_id >= self.mod_globals_bufs.len) return error.SassError;
        if (target.module_id < self.executed_modules.len and self.executed_modules[target.module_id]) {
            setMessage("This module was already loaded, so it can't be configured using \"with\".", .{});
            return error.SassError;
        }
        const row = self.mod_globals_bufs[target.module_id];
        if (target.slot >= row.len) return error.SassError;
        if (entry.value.kind() == .nil and row[target.slot].kind() != .nil) continue;
        row[target.slot] = entry.value;
    }
}

/// Runs `module_id`'s top-level code in place without emitting its CSS:
/// rules, comments and `@extend`s go to a scratch RuleIR that is discarded,
/// so CSS serialization and extension errors are not reported here.
fn runModuleDeferringCss(self: anytype, module_id: u32) !void {
    const executed_before = try self.allocator.dupe(bool, self.executed_modules);
    defer self.allocator.free(executed_before);
    {
        const saved_state = self.saveState();
        defer self.restoreState(&saved_state);
        var scratch = rule_ir_mod.RuleIR.init();
        defer scratch.deinit(self.allocator);
        scratch.module_visibility_matrix = self.rule_ir.module_visibility_matrix;
        scratch.module_visibility_n = self.rule_ir.module_visibility_n;
        const main_ir = self.rule_ir;
        self.rule_ir = &scratch;
        defer self.rule_ir = main_ir;
        const saved_deferred = self.css_output_deferred;
        self.css_output_deferred = true;
        defer self.css_output_deferred = saved_deferred;

        if (module_id < self.module_first_loader_origin.len and
            self.module_first_loader_origin[module_id] == .invalid)
        {
            self.module_first_loader_origin[module_id] = self.current_origin;
        }
        const track_running = module_id < self.module_currently_running.len;
        if (track_running) self.module_currently_running[module_id] = true;
        defer if (track_running) {
            self.module_currently_running[module_id] = false;
        };
        try vm_cross_module.runTopModuleWithSelectorPrefix(self, module_id, &.{}, false);
    }
    for (self.executed_modules, 0..) |now, i| {
        if (now and !executed_before[i] and i < self.module_css_deferred.len) self.module_css_deferred[i] = true;
    }
}

fn mapRunError(err: anyerror) builtin_shared.BuiltinError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FatalDeprecation => error.FatalDeprecation,
        error.BuiltinArity => error.BuiltinArity,
        error.BuiltinType => error.BuiltinType,
        error.BuiltinUnsupported => error.BuiltinUnsupported,
        else => error.SassError,
    };
}

/// `meta.load($url, $with: null)`: loads the module at `$url` like `@use`
/// (one shared instance per canonical URL) without exposing its members or
/// emitting its CSS, and returns a reference to it.
pub fn invokeMetaLoad(self: anytype, ctx: anytype, args: []const Value, arg_names: []const InternId) builtin_shared.BuiltinError!Value {
    const params = [_][]const u8{ "url", "with" };
    const b = try builtin_shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const url_v = b[0] orelse return builtin_shared.reportMissingArgument("url");
    if (url_v.kind() != .string) return builtin_shared.reportArgumentTypeMismatch(ctx, "url", url_v, "string");
    const url = self.intern_pool.get(url_v.stringIntern());
    const config = try parseLoadConfig(self, ctx, b[1] orelse Value.nil_v);
    defer freeLoadConfig(self.allocator, config);

    if (std.mem.startsWith(u8, url, "sass:")) {
        const name = names_mod.builtinModuleUrlToShortName(url) orelse {
            setMessage("Can't find stylesheet to import.", .{});
            return error.SassError;
        };
        if (config.len != 0) {
            setMessage("Built-in module {s} can't be configured.", .{url});
            return error.SassError;
        }
        return makeBuiltinModuleRef(self, name);
    }

    if (self.current_module >= self.program.modules.len) return error.SassError;
    const from_path = self.program.modules[self.current_module].module_path;
    const maybe_resolved: ?[]const u8 = if (from_path.len == 0) null else try resolver_mod.resolveUserModulePath(
        self.allocator,
        from_path,
        url,
        self.program.load_paths,
        .{ .pkg_importer_enabled = self.program.pkg_importer_enabled },
    );
    const resolved_raw = maybe_resolved orelse {
        setMessage("Can't find stylesheet to import.", .{});
        return error.SassError;
    };
    defer self.allocator.free(resolved_raw);
    const canonical = try std.fs.path.resolve(self.allocator, &.{resolved_raw});
    defer self.allocator.free(canonical);
    const module_id = moduleIdForPath(self, canonical) orelse {
        setMessage("meta.load() is only supported for a URL written as a string literal.", .{});
        return error.SassError;
    };

    if (module_id < self.module_currently_running.len and self.module_currently_running[module_id]) {
        setMessage("Module loop: {s} is already being loaded.", .{canonical});
        return error.SassError;
    }
    try validateLoadConfig(self, module_id, config);
    const executed = module_id < self.executed_modules.len and self.executed_modules[module_id];
    if (executed) {
        if (config.len != 0) {
            setMessage("{s} was already loaded, so it can't be configured using \"with\".", .{canonical});
            return error.SassError;
        }
        return makeUserModuleRef(self, module_id);
    }

    try applyLoadConfig(self, module_id, config);
    runModuleDeferringCss(self, module_id) catch |err| return mapRunError(err);
    return makeUserModuleRef(self, module_id);
}

test "module display namespace strips partial prefix and extensions" {
    try std.testing.expectEqualStrings("other", moduleDisplayNamespace("dir/_other.scss"));
    try std.testing.expectEqualStrings("index", moduleDisplayNamespace("dir/_index.scss"));
    try std.testing.expectEqualStrings("d", moduleDisplayNamespace("d.e.scss"));
    try std.testing.expectEqualStrings("plain", moduleDisplayNamespace("plain.css"));
}

test "module display namespace must be a plain Sass identifier" {
    try std.testing.expect(isPlainSassIdentifier("a-b"));
    try std.testing.expect(isPlainSassIdentifier("_c"));
    try std.testing.expect(isPlainSassIdentifier("-a"));
    try std.testing.expect(!isPlainSassIdentifier("1x"));
    try std.testing.expect(!isPlainSassIdentifier("-1"));
    try std.testing.expect(!isPlainSassIdentifier(""));
}

test "module reference keys split into display and identity" {
    const key = "get-module(\"math\")\x00sass:math";
    try std.testing.expectEqualStrings("get-module(\"math\")", value_mod.moduleRefDisplay(key));
    try std.testing.expectEqualStrings("sass:math", value_mod.moduleRefIdentity(key));
}
