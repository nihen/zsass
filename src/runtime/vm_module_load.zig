//! First-class modules: module reference values, `meta.load()` and `meta.css()`.
const std = @import("std");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");

const vm_cross_module = @import("vm_cross_module.zig");
const resolver_mod = @import("../resolve/resolver.zig");
const error_format = @import("error_format.zig");
const builtin_shared = @import("../builtin/shared.zig");

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

pub fn invokeMetaLoad(self: anytype, ctx: anytype, args: []const Value, arg_names: []const InternId) !Value {
    _ = self;
    _ = ctx;
    _ = args;
    _ = arg_names;
    return error.BuiltinUnsupported;
}

fn reportMissingNamespace(namespace: []const u8) error{SassError} {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "There is no module with namespace \"{s}\".", .{namespace}) catch return error.SassError;
    error_format.setContextMessage(msg);
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

/// Binds the single `$module` parameter shared by `meta.css()`.
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
/// modules) at the current position. A module's CSS is re-materialized through
/// the `meta.load-css()` path, seeded from the module's saved global state;
/// the re-run never writes module state back and stays quiet.
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
    const module_id = switch (target) {
        .builtin => return,
        .not_found => return error.SassError,
        .user => |mid| mid,
    };
    const path = self.program.modules[module_id].module_path;
    if (path.len == 0) return error.SassError;

    const owner_module = self.effectiveModuleTag();
    const child_tag = self.allocateLoadCssModuleTag();
    try self.registerVisibleLoadCssModule(owner_module, owner_module, std.math.maxInt(u32), child_tag);
    try vm_cross_module.runLoadCssModule(self, path, .{}, .{ .sync_state = false, .quiet = true });
}
