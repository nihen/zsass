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
    load,
    get_module,
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
    .{ .id = 188, .name = "load", .dispatch_kind = .load },
    .{ .id = 189, .name = "get-module", .dispatch_kind = .get_module },
    .{ .id = 190, .name = "css", .mixin_only = true },
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
pub const meta_load_id: Id = idByNameComptime("load");
pub const meta_get_module_id: Id = idByNameComptime("get-module");
pub const meta_css_mixin_id: Id = idByNameComptime("css");

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
    source_size_limit = 6,
    syntax_nesting_limit = 7,
    nesting_limit = 8,
    execution_limit = 9,
    selector_expansion_limit = 10,
    ir_node_limit = 11,
    output_size_limit = 12,
    compilation_cancelled = 13,
    file_import_denied = 14,
};

pub fn statusFromBuiltinError(err: BuiltinError) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.BuiltinArity => .builtin_arity,
        error.BuiltinType => .builtin_type,
        error.BuiltinUnsupported => .builtin_unsupported,
        error.SassError => .sass_error,
        error.FatalDeprecation => .sass_error,
        error.SourceSizeLimit => .source_size_limit,
        error.SyntaxNestingLimit => .syntax_nesting_limit,
        error.NestingLimit => .nesting_limit,
        error.ExecutionLimit => .execution_limit,
        error.SelectorExpansionLimit => .selector_expansion_limit,
        error.IrNodeLimit => .ir_node_limit,
        error.OutputSizeLimit => .output_size_limit,
        error.CompilationCancelled => .compilation_cancelled,
        error.FileImportDenied => .file_import_denied,
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
        .source_size_limit => error.SourceSizeLimit,
        .syntax_nesting_limit => error.SyntaxNestingLimit,
        .nesting_limit => error.NestingLimit,
        .execution_limit => error.ExecutionLimit,
        .selector_expansion_limit => error.SelectorExpansionLimit,
        .ir_node_limit => error.IrNodeLimit,
        .output_size_limit => error.OutputSizeLimit,
        .compilation_cancelled => error.CompilationCancelled,
        .file_import_denied => error.FileImportDenied,
    };
}
