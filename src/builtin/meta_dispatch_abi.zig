const std = @import("std");
const shared = @import("shared.zig");

const BuiltinError = shared.BuiltinError;
const BuiltinContext = shared.BuiltinContext;
const Id = shared.Id;
const InternId = shared.InternId;
const Value = shared.Value;

pub const DispatchKind = enum {
    call,
    apply,
    type_of,
    inspect,
    feature_exists,
    accepts_content,
    variable_exists,
    global_variable_exists,
    function_exists,
    mixin_exists,
    content_exists,
    keywords,
    module_variables,
    module_functions,
    module_mixins,
    calc_name,
    calc_args,
    get_function,
    get_mixin,
};

const MetaBuiltinSpec = struct {
    id: Id,
    name: []const u8,
    mixin_only: bool = false,
    dispatch_kind: ?DispatchKind = null,
};

pub const meta_builtin_specs = [_]MetaBuiltinSpec{
    .{ .id = 77, .name = "call", .dispatch_kind = .call },
    .{ .id = 78, .name = "apply", .mixin_only = true, .dispatch_kind = .apply },
    .{ .id = 79, .name = "type-of", .dispatch_kind = .type_of },
    .{ .id = 80, .name = "inspect", .dispatch_kind = .inspect },
    .{ .id = 125, .name = "feature-exists", .dispatch_kind = .feature_exists },
    .{ .id = 126, .name = "accepts-content", .dispatch_kind = .accepts_content },
    .{ .id = 127, .name = "variable-exists", .dispatch_kind = .variable_exists },
    .{ .id = 128, .name = "global-variable-exists", .dispatch_kind = .global_variable_exists },
    .{ .id = 129, .name = "function-exists", .dispatch_kind = .function_exists },
    .{ .id = 130, .name = "mixin-exists", .dispatch_kind = .mixin_exists },
    .{ .id = 131, .name = "content-exists", .dispatch_kind = .content_exists },
    .{ .id = 132, .name = "keywords", .dispatch_kind = .keywords },
    .{ .id = 133, .name = "module-variables", .dispatch_kind = .module_variables },
    .{ .id = 134, .name = "module-functions", .dispatch_kind = .module_functions },
    .{ .id = 135, .name = "module-mixins", .dispatch_kind = .module_mixins },
    .{ .id = 150, .name = "calc-name", .dispatch_kind = .calc_name },
    .{ .id = 151, .name = "calc-args", .dispatch_kind = .calc_args },
    .{ .id = 181, .name = "load-css", .mixin_only = true },
    .{ .id = 182, .name = "get-function", .dispatch_kind = .get_function },
    .{ .id = 183, .name = "get-mixin", .dispatch_kind = .get_mixin },
};

fn idByNameComptime(comptime name: []const u8) Id {
    inline for (meta_builtin_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.id;
    }
    @compileError("unknown meta builtin name");
}

pub const meta_apply_mixin_id: Id = idByNameComptime("apply");
pub const meta_load_css_mixin_id: Id = idByNameComptime("load-css");
pub const meta_get_function_id: Id = idByNameComptime("get-function");
pub const meta_get_mixin_id: Id = idByNameComptime("get-mixin");

pub fn isMixinOnlyId(id: Id) bool {
    inline for (meta_builtin_specs) |spec| {
        if (spec.id == id) return spec.mixin_only;
    }
    return false;
}

pub fn resolveMixinId(name: []const u8) ?Id {
    inline for (meta_builtin_specs) |spec| {
        if (!spec.mixin_only) continue;
        if (shared.identifierEq(name, spec.name)) return spec.id;
    }
    return null;
}

pub inline fn dispatchKindById(id: Id) ?DispatchKind {
    inline for (meta_builtin_specs) |spec| {
        if (spec.id == id) return spec.dispatch_kind;
    }
    return null;
}

pub inline fn isDispatchId(id: Id) bool {
    return dispatchKindById(id) != null;
}

pub const Status = enum(u8) {
    ok = 0,
    out_of_memory = 1,
    builtin_arity = 2,
    builtin_type = 3,
    builtin_unsupported = 4,
    sass_error = 5,
};

/// The stable call boundary used for sass:meta builtins that need runtime
/// state. `builtin/mod.zig` owns the generic builtin dispatch table; the
/// runtime owns the concrete implementation behind this ABI.
pub const DispatchRequest = struct {
    ctx: *BuiltinContext,
    id: Id,
    args: []const Value,
    arg_names: []const InternId,
};

pub const DispatchResult = struct {
    status: Status,
    value: Value = Value.nil_v,
};

pub const DispatchFn = *const fn (request: DispatchRequest) callconv(.c) DispatchResult;

/// Runtime-only module identity used by meta lookups. This mirrors the current
/// `meta.zig` private ModuleId shape without exposing resolver or VM types.
pub const ModuleRef = union(enum) {
    current,
    user: u32,
    builtin: []const u8,
    not_found,
};

pub const CallableKind = enum {
    function,
    mixin,
};

pub const UserCallableRef = struct {
    module_id: u32,
    id: u32,
    display_name: []const u8,
    module_display_name: ?[]const u8 = null,
    captures_callers_locals: bool = false,
    accepts_content: bool = false,
};

pub const BuiltinCallableRef = struct {
    id: u32,
    display_name: []const u8,
    css: bool = false,
    accepts_content: bool = false,
};

pub const CallableRef = union(enum) {
    user: UserCallableRef,
    builtin: BuiltinCallableRef,
    css_function: []const u8,
};

pub const NamedValue = struct {
    name: []const u8,
    value: Value,
};

pub const NamedCallable = struct {
    name: []const u8,
    callable: CallableRef,
};

/// Access categories currently embedded in builtin/meta.zig and intended to be
/// owned by runtime/vm_meta.zig in G1b. This enum is documentation plus a
/// compile-checked checklist for the move; it deliberately avoids VM/resolver
/// imports.
pub const RuntimeAccessKind = enum {
    current_module_use_binding,
    declared_global_lookup,
    star_variable_lookup,
    current_function_lookup,
    exported_function_lookup,
    current_mixin_lookup,
    exported_mixin_lookup,
    module_variables,
    module_functions,
    module_mixins,
    callable_validation,
    callable_invocation,
    arglist_keywords,
    content_exists,
    current_local_slot_hint,
    callable_capture_flags,
    mixin_accepts_content,
};

pub fn statusFromBuiltinError(err: BuiltinError) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.BuiltinArity => .builtin_arity,
        error.BuiltinType => .builtin_type,
        error.BuiltinUnsupported => .builtin_unsupported,
        error.SassError => .sass_error,
        error.FatalDeprecation => .sass_error,
    };
}

pub fn builtinErrorFromStatus(status: Status) BuiltinError {
    return switch (status) {
        .ok => unreachable,
        .out_of_memory => error.OutOfMemory,
        .builtin_arity => error.BuiltinArity,
        .builtin_type => error.BuiltinType,
        .builtin_unsupported => error.BuiltinUnsupported,
        .sass_error => error.SassError,
    };
}
