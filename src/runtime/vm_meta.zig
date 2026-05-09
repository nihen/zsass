//! Runtime-backed sass:meta builtins.
const std = @import("std");
const shared = @import("../builtin/shared.zig");
const meta_helpers = @import("../builtin/meta_helpers.zig");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");
const resolver = @import("../resolve/resolver.zig");
const color_mod = @import("../color/color.zig");
const meta_dispatch_abi = @import("../builtin/meta_dispatch_abi.zig");

const Value = shared.Value;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;
const InternId = shared.InternId;
const Id = shared.Id;
const color_preserve_slash_marker = "\x01zsass-color-preserve-slash:";

const expectArity = shared.expectArity;
const internString = shared.internString;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;

const VM = vm_mod.VM;

fn getVM(ctx: *BuiltinContext) *VM {
    return @ptrCast(@alignCast(ctx.vm));
}

const ModuleId = union(enum) {
    current,
    user: u32,
    builtin: []const u8,
    not_found,
};

const CalcCall = struct {
    name: []const u8,
    args_text: []const u8,
};

const MapPair = struct {
    key: Value,
    value: Value,
};

const LookupIdResult = struct {
    key: []const u8,
    value: u32,
};

const LookupCallableResult = struct {
    key: []const u8,
    value: resolver.CallableTarget,
};

const LookupVarTargetResult = struct {
    key: []const u8,
    value: resolver.VarTarget,
};

fn trimSassNamespace(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "sass:")) name["sass:".len..] else name;
}

fn findUseBinding(
    use_map: *const std.StringHashMapUnmanaged(resolver.UseBinding),
    module_name: []const u8,
) ?resolver.UseBinding {
    if (use_map.get(module_name)) |binding| return binding;

    const trimmed = trimSassNamespace(module_name);
    if (!std.mem.eql(u8, trimmed, module_name)) {
        if (use_map.get(trimmed)) |binding| return binding;
    }
    return null;
}

fn voidMapContainsIdentifier(map: *const std.StringHashMapUnmanaged(void), name: []const u8) bool {
    if (map.contains(name)) return true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (shared.identifierEq(entry.key_ptr.*, name)) return true;
    }
    return false;
}

fn lookupIdentifierId(map: *const std.StringHashMapUnmanaged(u32), name: []const u8) ?LookupIdResult {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (shared.identifierEq(entry.key_ptr.*, name)) {
            return .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
        }
    }
    return null;
}

fn lookupIdentifierCallable(
    map: *const std.StringHashMapUnmanaged(resolver.CallableTarget),
    name: []const u8,
) ?LookupCallableResult {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (shared.identifierEq(entry.key_ptr.*, name)) {
            return .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
        }
    }
    return null;
}

fn lookupIdentifierVarTarget(
    map: *const std.StringHashMapUnmanaged(resolver.VarTarget),
    name: []const u8,
) ?LookupVarTargetResult {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (shared.identifierEq(entry.key_ptr.*, name)) {
            return .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
        }
    }
    return null;
}

fn moduleDeclaredVarExists(vm: *VM, module_id: u32, name: []const u8) bool {
    if (module_id >= vm.program.modules.len) return false;
    const mod = &vm.program.modules[module_id];
    const local = lookupIdentifierId(&mod.global_slots, name) orelse return false;
    return vm.isModuleGlobalDeclared(module_id, local.value);
}

fn internDisplayIdentifier(ctx: *BuiltinContext, raw: []const u8) BuiltinError!InternId {
    if (std.mem.findScalar(u8, raw, '_') == null) return internString(ctx, raw);
    const buf = try ctx.allocator.dupe(u8, raw);
    defer ctx.allocator.free(buf);
    for (buf) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return internString(ctx, buf);
}

fn internQualifiedDisplayIdentifier(ctx: *BuiltinContext, module_name: []const u8, raw: []const u8) BuiltinError!InternId {
    const member_id = try internDisplayIdentifier(ctx, raw);
    const member = ctx.intern_pool.get(member_id);
    const full = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ module_name, member });
    defer ctx.allocator.free(full);
    return internString(ctx, full);
}

fn sortMapPairs(ctx: *BuiltinContext, items: []MapPair) void {
    const Ctx = struct {
        ctx: *BuiltinContext,

        fn keyBytes(self: @This(), v: Value) []const u8 {
            if (v.isString()) return self.ctx.intern_pool.get(v.stringIntern());
            return "";
        }

        fn lessThan(self: @This(), lhs: MapPair, rhs: MapPair) bool {
            return std.mem.lessThan(u8, self.keyBytes(lhs.key), self.keyBytes(rhs.key));
        }
    };
    std.sort.block(MapPair, items, Ctx{ .ctx = ctx }, Ctx.lessThan);
}

fn pushMapPairs(ctx: *BuiltinContext, pairs: []const MapPair) BuiltinError!Value {
    const owned = try ctx.allocator.alloc(Value, pairs.len * 2);
    for (pairs, 0..) |pair, i| {
        owned[i * 2] = pair.key;
        owned[i * 2 + 1] = pair.value;
    }
    const handle: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(owned);
        try ctx.list_pool.append(ctx.allocator, owned);
    }
    // After `append` succeeds the pool holds a borrowed pointer into
    // `owned`; if the hook fails we must pop+free atomically.
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(owned);
    }
    try shared.maybeNoteListParentSelNoneHook(ctx, handle, owned);
    return Value.listWithMeta(handle, .comma, false, true);
}

fn callableWithPreboundFlag(ctx: *BuiltinContext, value: Value) BuiltinError!Value {
    if (value.kind() != .callable) return value;
    const flags = value.callableRawFlags(ctx.callable_payload_pool);
    if ((flags & value_mod.callable_flag_prebound) != 0) return value;
    return try Value.callableMake(
        value.callableHandle(ctx.callable_payload_pool),
        flags | value_mod.callable_flag_prebound,
        value.callableModuleId(ctx.callable_payload_pool),
        value.callableNameIntern(ctx.callable_payload_pool),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeBuiltinFunctionCallable(ctx: *BuiltinContext, builtin_id: u32, display_name: []const u8, css: bool) BuiltinError!Value {
    var flags: u16 = value_mod.callable_flag_is_builtin;
    if (css) flags |= value_mod.callable_flag_is_css;
    return try Value.callableMake(
        builtin_id,
        flags,
        0,
        try internDisplayIdentifier(ctx, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeCssFunctionCallable(ctx: *BuiltinContext, display_name: []const u8) BuiltinError!Value {
    return try Value.callableMake(
        0,
        value_mod.callable_flag_is_css,
        0,
        try internDisplayIdentifier(ctx, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeUserFunctionCallable(ctx: *BuiltinContext, module_id: u32, function_id: u32, display_name: []const u8) BuiltinError!Value {
    const vm = getVM(ctx);
    var flags: u16 = value_mod.callable_flag_has_module | value_mod.callable_flag_prebound;
    if (module_id < vm.program.modules.len and function_id < vm.program.modules[module_id].functions.len and
        vm.program.modules[module_id].functions[function_id].captures_callers_locals)
    {
        flags |= value_mod.callable_flag_capture_callers_locals;
    }
    return try Value.callableMake(
        function_id,
        flags,
        @truncate(module_id),
        try internDisplayIdentifier(ctx, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeUserFunctionCallableQualified(ctx: *BuiltinContext, module_name: []const u8, module_id: u32, function_id: u32, display_name: []const u8) BuiltinError!Value {
    const vm = getVM(ctx);
    var flags: u16 = value_mod.callable_flag_has_module | value_mod.callable_flag_prebound;
    if (module_id < vm.program.modules.len and function_id < vm.program.modules[module_id].functions.len and
        vm.program.modules[module_id].functions[function_id].captures_callers_locals)
    {
        flags |= value_mod.callable_flag_capture_callers_locals;
    }
    return try Value.callableMake(
        function_id,
        flags,
        @truncate(module_id),
        try internQualifiedDisplayIdentifier(ctx, module_name, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeBuiltinMixinCallable(ctx: *BuiltinContext, builtin_id: u32, display_name: []const u8, accepts_content: bool) BuiltinError!Value {
    var flags: u16 = value_mod.callable_flag_is_mixin | value_mod.callable_flag_is_builtin;
    if (accepts_content) flags |= value_mod.callable_flag_accepts_content;
    return try Value.callableMake(
        builtin_id,
        flags,
        0,
        try internDisplayIdentifier(ctx, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeUserMixinCallable(ctx: *BuiltinContext, module_id: u32, mixin_id: u32, display_name: []const u8, accepts_content: bool) BuiltinError!Value {
    var flags: u16 = value_mod.callable_flag_is_mixin | value_mod.callable_flag_has_module | value_mod.callable_flag_prebound;
    if (accepts_content) flags |= value_mod.callable_flag_accepts_content;
    const vm = getVM(ctx);
    if (module_id < vm.program.modules.len and mixin_id < vm.program.modules[module_id].mixins.len and
        vm.program.modules[module_id].mixins[mixin_id].captures_callers_locals)
    {
        flags |= value_mod.callable_flag_capture_callers_locals;
    }
    return try Value.callableMake(
        mixin_id,
        flags,
        @truncate(module_id),
        try internDisplayIdentifier(ctx, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn makeUserMixinCallableQualified(ctx: *BuiltinContext, module_name: []const u8, module_id: u32, mixin_id: u32, display_name: []const u8, accepts_content: bool) BuiltinError!Value {
    var flags: u16 = value_mod.callable_flag_is_mixin | value_mod.callable_flag_has_module | value_mod.callable_flag_prebound;
    if (accepts_content) flags |= value_mod.callable_flag_accepts_content;
    const vm = getVM(ctx);
    if (module_id < vm.program.modules.len and mixin_id < vm.program.modules[module_id].mixins.len and
        vm.program.modules[module_id].mixins[mixin_id].captures_callers_locals)
    {
        flags |= value_mod.callable_flag_capture_callers_locals;
    }
    return try Value.callableMake(
        mixin_id,
        flags,
        @truncate(module_id),
        try internQualifiedDisplayIdentifier(ctx, module_name, display_name),
        ctx.callable_payload_pool,
        ctx.allocator,
    );
}

fn isCalcName(name: []const u8) bool {
    return shared.identifierEq(name, "calc") or
        shared.identifierEq(name, "clamp") or
        shared.identifierEq(name, "min") or
        shared.identifierEq(name, "max");
}

fn parseCalculationCall(raw: []const u8) ?CalcCall {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const lparen = std.mem.findScalar(u8, text, '(') orelse return null;
    if (text.len < lparen + 2 or text[text.len - 1] != ')') return null;

    const name = std.mem.trim(u8, text[0..lparen], " \t\r\n");
    if (name.len == 0 or !isCalcName(name)) return null;

    var depth: u32 = 0;
    var in_quote: u8 = 0;
    var i: usize = lparen;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_quote != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_quote) in_quote = 0;
            continue;
        }

        switch (c) {
            '"', '\'' => in_quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0 and i != text.len - 1) return null;
            },
            else => {},
        }
    }

    if (depth != 0 or in_quote != 0) return null;
    return .{
        .name = name,
        .args_text = text[lparen + 1 .. text.len - 1],
    };
}

fn splitCalculationArgs(
    alloc: std.mem.Allocator,
    args_text: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) BuiltinError!void {
    const all_trimmed = std.mem.trim(u8, args_text, " \t\r\n");
    if (all_trimmed.len == 0) return;

    var depth: u32 = 0;
    var in_quote: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < args_text.len) : (i += 1) {
        const c = args_text[i];
        if (in_quote != 0) {
            if (c == '\\' and i + 1 < args_text.len) {
                i += 1;
                continue;
            }
            if (c == in_quote) in_quote = 0;
            continue;
        }

        switch (c) {
            '"', '\'' => in_quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    const piece = std.mem.trim(u8, args_text[start..i], " \t\r\n");
                    try out.append(alloc, piece);
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, args_text[start..], " \t\r\n");
    try out.append(alloc, tail);
}

fn isUnitChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '%' or c == '-' or c == '_';
}

fn parseSimpleNumber(ctx: *BuiltinContext, raw: []const u8) BuiltinError!?Value {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;

    var i: usize = 0;
    if (text[i] == '+' or text[i] == '-') i += 1;

    var saw_digit = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        saw_digit = true;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            saw_digit = true;
        }
    }
    if (!saw_digit) return null;

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        const exp_mark = i;
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const exp_start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (exp_start == i) return null;
        if (exp_mark == 0) return null;
    }

    const number_part = text[0..i];
    const unit_part = text[i..];
    for (unit_part) |c| {
        if (!isUnitChar(c)) return null;
    }

    const value = std.fmt.parseFloat(f64, number_part) catch return null;
    if (unit_part.len == 0) return Value.numberUnitless(value);
    const unit_id = try internString(ctx, unit_part);
    return try Value.number(value, unit_id, ctx.number_pool, ctx.allocator);
}

fn calcArgToValue(ctx: *BuiltinContext, raw: []const u8, simplify_number: bool) BuiltinError!Value {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        const id_empty = try internString(ctx, "");
        return Value.string(id_empty, false);
    }
    if (simplify_number) {
        if (try parseSimpleNumber(ctx, trimmed)) |num_v| return num_v;
    }
    const id = try internString(ctx, trimmed);
    return Value.string(id, false);
}

fn pushCommaList(ctx: *BuiltinContext, items: []const Value) BuiltinError!Value {
    const h: u32 = @intCast(ctx.list_pool.items.len);
    const owned = try ctx.allocator.dupe(Value, items);
    {
        errdefer ctx.allocator.free(owned);
        try ctx.list_pool.append(ctx.allocator, owned);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(owned);
    }
    try shared.maybeNoteListParentSelNoneHook(ctx, h, owned);
    return Value.listWithComma(h, false);
}

fn calcTypeTagForString(ctx: *BuiltinContext, v: Value) BuiltinError!?[]const u8 {
    if (v.stringQuoted(ctx.string_flags_pool.items) or v.stringFromInspect(ctx.string_flags_pool.items)) return null;

    const raw = ctx.intern_pool.get(v.stringIntern());
    if (color_mod.lookupNamedColor(raw) != null) return "color";

    const calc = parseCalculationCall(raw) orelse return null;
    if (shared.identifierEq(calc.name, "calc")) {
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(ctx.allocator);
        try splitCalculationArgs(ctx.allocator, calc.args_text, &args);
        if (args.items.len == 1) {
            if ((try parseSimpleNumber(ctx, args.items[0])) != null) return "number";
        }
    }
    return "calculation";
}

fn builtinFunctionExistsCompat(ctx: *BuiltinContext, module_name: []const u8, function_name: []const u8) BuiltinError!bool {
    return (try builtinFunctionIdCompat(ctx, module_name, function_name)) != null;
}

fn builtinFunctionIdCompat(ctx: *BuiltinContext, module_name: []const u8, function_name: []const u8) BuiltinError!?u32 {
    const builtin_mod = @import("../builtin/mod.zig");
    if (builtin_mod.resolve(module_name, function_name)) |id| return id;
    if (std.mem.findScalar(u8, function_name, '_') != null) {
        const normalized = try ctx.allocator.dupe(u8, function_name);
        defer ctx.allocator.free(normalized);
        for (normalized) |*ch| {
            if (ch.* == '_') ch.* = '-';
        }
        if (builtin_mod.resolve(module_name, normalized)) |id| return id;
    }
    return null;
}

fn findModule(ctx: *BuiltinContext, module_name_v: ?Value) BuiltinError!ModuleId {
    if (module_name_v == null or module_name_v.?.kind() == .nil) return .current;
    if (module_name_v.?.kind() != .string) return reportArgumentTypeMismatch(ctx, "module", module_name_v.?, "string");
    const name = ctx.intern_pool.get(module_name_v.?.stringIntern());
    const vm = getVM(ctx);
    const mod = &vm.program.modules[vm.current_module];
    if (findUseBinding(&mod.use_map, name)) |binding| {
        return switch (binding) {
            .builtin_module => |bname| .{ .builtin = bname },
            .user_module => |id| .{ .user = id },
        };
    }
    return .not_found;
}

fn builtinModuleVariableExists(module_name: []const u8, variable_name: []const u8) bool {
    if (!shared.identifierEq(module_name, "math")) return false;
    return shared.identifierEq(variable_name, "e") or
        shared.identifierEq(variable_name, "pi") or
        shared.identifierEq(variable_name, "epsilon") or
        shared.identifierEq(variable_name, "max-safe-integer") or
        shared.identifierEq(variable_name, "min-safe-integer") or
        shared.identifierEq(variable_name, "max-number") or
        shared.identifierEq(variable_name, "min-number");
}

const ForwardedMetaCallable = struct {
    target: Value,
    args: []Value,
    arg_names: []InternId,

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.args);
        alloc.free(self.arg_names);
    }
};

fn splitMetaCallableArgs(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    control_name: []const u8,
) BuiltinError!ForwardedMetaCallable {
    const control_idx = meta_helpers.findMetaControlArgOffset(ctx.intern_pool, arg_names, args.len, control_name) orelse return error.BuiltinArity;
    const forwarded_len = args.len - 1;
    const forwarded_args = try ctx.allocator.alloc(Value, forwarded_len);
    errdefer ctx.allocator.free(forwarded_args);
    const forwarded_names = try ctx.allocator.alloc(InternId, forwarded_len);
    errdefer ctx.allocator.free(forwarded_names);

    var out_i: usize = 0;
    for (args, 0..) |arg, i| {
        if (i == control_idx) continue;
        forwarded_args[out_i] = arg;
        forwarded_names[out_i] = if (i < arg_names.len) arg_names[i] else .none;
        out_i += 1;
    }
    return .{
        .target = args[control_idx],
        .args = forwarded_args,
        .arg_names = forwarded_names,
    };
}

fn invokeMetaCallable(
    ctx: *BuiltinContext,
    expect_mixin: bool,
    target: Value,
    args: []const Value,
    arg_names: []const InternId,
) BuiltinError!Value {
    const vm = getVM(ctx);
    const call_target = try callableWithPreboundFlag(ctx, target);
    vm.validateMetaCallTarget(call_target, expect_mixin) catch |err| return switch (err) {
        error.BuiltinType => error.BuiltinType,
        else => error.SassError,
    };
    return vm.invokeCallableFromBuiltinSync(expect_mixin, call_target, args, arg_names) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BuiltinArity => error.BuiltinArity,
        error.BuiltinType => error.BuiltinType,
        error.BuiltinUnsupported => error.BuiltinUnsupported,
        error.SassError => error.SassError,
        else => blk: {
            std.log.debug("zsass meta callable trampoline failure err={}", .{err});
            break :blk error.SassError;
        },
    };
}

fn meta_call(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    var forwarded = try splitMetaCallableArgs(ctx, args, arg_names, "function");
    defer forwarded.deinit(ctx.allocator);
    return invokeMetaCallable(ctx, false, forwarded.target, forwarded.args, forwarded.arg_names);
}

fn meta_apply(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    var forwarded = try splitMetaCallableArgs(ctx, args, arg_names, "mixin");
    defer forwarded.deinit(ctx.allocator);
    return invokeMetaCallable(ctx, true, forwarded.target, forwarded.args, forwarded.arg_names);
}

fn meta_type_of(ctx: *BuiltinContext, args: []const Value, _: []const InternId) BuiltinError!Value {
    try expectArity(args, 1);
    const value = args[0];
    const tag: []const u8 = blk: {
        if (value.kind() == .nil) break :blk "null";
        if (value.kind() == .boolean) break :blk "bool";
        if (value.isNumber()) break :blk "number";
        if (value.isString()) break :blk (try calcTypeTagForString(ctx, value)) orelse "string";
        if (value.kind() == .color) break :blk "color";
        if (value.kind() == .list) {
            if (value.listIsMap(ctx.list_meta_pool.items)) break :blk "map";
            const vm = getVM(ctx);
            if (vm.arglist_keyword_lists.contains(value.listHandle())) break :blk "arglist";
            break :blk "list";
        }
        if (value.kind() == .calc_fragment) break :blk "calculation";
        if (value.kind() == .callable) break :blk if (value.callableIsMixin(ctx.callable_payload_pool)) "mixin" else "function";
        break :blk "unknown";
    };
    const id = try internString(ctx, tag);
    return Value.string(id, false);
}

fn inspectStringValue(ctx: *BuiltinContext, value: Value) BuiltinError![]const u8 {
    std.debug.assert(value.kind() == .string);
    const stored = ctx.intern_pool.get(value.stringIntern());
    const raw = if (std.mem.startsWith(u8, stored, color_preserve_slash_marker)) stored[color_preserve_slash_marker.len..] else stored;
    if (!value.stringQuoted(ctx.string_flags_pool.items)) return ctx.allocator.dupe(u8, raw) catch error.OutOfMemory;
    const quote_char = preferredQuoteChar(raw);
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(ctx.allocator);
    try acc.ensureTotalCapacity(ctx.allocator, raw.len + 2);
    try acc.append(ctx.allocator, quote_char);
    if (std.unicode.Utf8View.init(raw)) |view| {
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_slice| {
            if (cp_slice.len == 1 and (cp_slice[0] == '\\' or cp_slice[0] == quote_char)) {
                try acc.append(ctx.allocator, '\\');
                try acc.append(ctx.allocator, cp_slice[0]);
                continue;
            }
            const cp = std.unicode.utf8Decode(cp_slice) catch {
                try acc.appendSlice(ctx.allocator, cp_slice);
                continue;
            };
            if (cp >= 0xE000 and cp <= 0xF8FF) {
                var buf: [16]u8 = undefined;
                const escaped = std.fmt.bufPrint(&buf, "\\{x}", .{cp}) catch |err| {
                    std.debug.panic("meta.inspectStringValue formatting failed: {s}", .{@errorName(err)});
                };
                try acc.appendSlice(ctx.allocator, escaped);
                continue;
            }
            try acc.appendSlice(ctx.allocator, cp_slice);
        }
    } else |_| {
        for (raw) |c| {
            switch (c) {
                '\\' => {
                    try acc.append(ctx.allocator, '\\');
                    try acc.append(ctx.allocator, c);
                },
                else => {
                    if (c == quote_char) {
                        try acc.append(ctx.allocator, '\\');
                        try acc.append(ctx.allocator, c);
                    } else {
                        try acc.append(ctx.allocator, c);
                    }
                },
            }
        }
    }
    try acc.append(ctx.allocator, quote_char);
    return acc.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
}

fn preferredQuoteChar(raw: []const u8) u8 {
    var single_count: usize = 0;
    var double_count: usize = 0;
    for (raw) |c| {
        if (c == '\'') single_count += 1;
        if (c == '"') double_count += 1;
    }
    if (single_count < double_count) return '\'';
    return '"';
}

fn channelToByte(raw: f64) ?u8 {
    if (!std.math.isFinite(raw)) return null;
    const scaled = raw * 255.0;
    if (scaled < -1e-8 or scaled > 255.0 + 1e-8) return null;
    const rounded = @round(scaled);
    if (@abs(scaled - rounded) > 1e-8) return null;
    const clamped = std.math.clamp(rounded, 0.0, 255.0);
    return @intFromFloat(clamped);
}

fn encodeHexNibble(n: u8, uppercase: bool) u8 {
    std.debug.assert(n < 16);
    if (n < 10) return '0' + n;
    const base: u8 = if (uppercase) 'A' else 'a';
    return base + (n - 10);
}

fn formatHexColor(
    alloc: std.mem.Allocator,
    r: u8,
    g: u8,
    b: u8,
    short_form: bool,
    uppercase: bool,
) BuiltinError![]const u8 {
    var out: []u8 = if (short_form) try alloc.alloc(u8, 4) else try alloc.alloc(u8, 7);
    out[0] = '#';
    if (short_form) {
        out[1] = encodeHexNibble(r >> 4, uppercase);
        out[2] = encodeHexNibble(g >> 4, uppercase);
        out[3] = encodeHexNibble(b >> 4, uppercase);
        return out;
    }
    out[1] = encodeHexNibble(r >> 4, uppercase);
    out[2] = encodeHexNibble(r & 0x0f, uppercase);
    out[3] = encodeHexNibble(g >> 4, uppercase);
    out[4] = encodeHexNibble(g & 0x0f, uppercase);
    out[5] = encodeHexNibble(b >> 4, uppercase);
    out[6] = encodeHexNibble(b & 0x0f, uppercase);
    return out;
}

fn maybeExpandShortHexInspectAuto(alloc: std.mem.Allocator, text: []const u8) BuiltinError!?[]const u8 {
    if (text.len != 4 or text[0] != '#') return null;
    if (!std.ascii.isHex(text[1]) or !std.ascii.isHex(text[2]) or !std.ascii.isHex(text[3])) return null;
    var out = try alloc.alloc(u8, 7);
    out[0] = '#';
    out[1] = text[1];
    out[2] = text[1];
    out[3] = text[2];
    out[4] = text[2];
    out[5] = text[3];
    out[6] = text[3];
    return out;
}

fn inspectColorValue(ctx: *BuiltinContext, value: Value) BuiltinError![]const u8 {
    std.debug.assert(value.kind() == .color);
    if (value.colorHandle() >= ctx.color_pool.items.len) return error.BuiltinType;
    const entry = ctx.color_pool.items[value.colorHandle()];

    if (entry.space == .srgb and entry.legacy and entry.missing == 0) {
        const rb = channelToByte(entry.channels[0]);
        const gb = channelToByte(entry.channels[1]);
        const bb = channelToByte(entry.channels[2]);
        const alpha = entry.channels[3];
        if (rb != null and gb != null and bb != null and std.math.isFinite(alpha) and @abs(alpha - 1.0) <= 1e-12) {
            switch (entry.inspect_repr) {
                .literal_short_hex => {
                    return formatHexColor(ctx.allocator, rb.?, gb.?, bb.?, true, entry.inspect_uppercase_hex);
                },
                .literal_long_hex => {
                    return formatHexColor(ctx.allocator, rb.?, gb.?, bb.?, false, entry.inspect_uppercase_hex);
                },
                .legacy_rgb_function => {},
                .auto => {},
            }
        }
    }

    var css = try shared.valueToCssString(ctx, value);
    errdefer ctx.allocator.free(css);
    if (entry.inspect_repr == .auto) {
        if (try maybeExpandShortHexInspectAuto(ctx.allocator, css)) |expanded| {
            ctx.allocator.free(css);
            css = expanded;
        }
    }
    return css;
}

fn valueToInspectCssString(ctx: *BuiltinContext, value: Value) BuiltinError![]const u8 {
    if (value.isString()) {
        return inspectStringValue(ctx, value);
    }
    if (value.kind() == .color) {
        return inspectColorValue(ctx, value);
    }
    if (value.kind() == .callable) {
        const name = ctx.intern_pool.get(value.callableNameIntern(ctx.callable_payload_pool));
        const display = if (value.callableIsMixin(ctx.callable_payload_pool)) "get-mixin" else "get-function";
        if (value.callableIsCss(ctx.callable_payload_pool)) {
            return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\", $css: true)", .{ display, name }) catch error.OutOfMemory;
        }
        if (!value.callableIsBuiltin(ctx.callable_payload_pool)) {
            if (std.mem.findScalar(u8, name, '.')) |dot| {
                return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\", $module: \"{s}\")", .{
                    display,
                    name[dot + 1 ..],
                    name[0..dot],
                }) catch error.OutOfMemory;
            }
        }
        return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\")", .{ display, name }) catch error.OutOfMemory;
    }
    if (value.kind() == .list) {
        const view = value_mod.inspectLogicalListView(ctx.list_pool.items, value) orelse unreachable;
        const items = view.items;
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(ctx.allocator);

        if (items.len == 0 and !view.is_map) {
            if (view.bracketed) {
                return ctx.allocator.dupe(u8, "[]") catch error.OutOfMemory;
            }
            return ctx.allocator.dupe(u8, "()") catch error.OutOfMemory;
        }

        // map rendering: map values with listIsMap bit are output in `(k: v, k: v)` format
        if (view.is_map and items.len % 2 == 0) {
            try acc.append(ctx.allocator, '(');
            var i: usize = 0;
            var wrote_any = false;
            while (i + 1 < items.len) : (i += 2) {
                if (wrote_any) try acc.appendSlice(ctx.allocator, ", ");
                const key_raw = items[i];
                const key = try valueToInspectCssString(ctx, key_raw);
                defer ctx.allocator.free(key);
                const val_raw = items[i + 1];
                const val_s = try valueToInspectCssString(ctx, val_raw);
                defer ctx.allocator.free(val_s);
                const wrap_key_in_map = value_mod.inspectMapListNeedsParens(ctx.list_pool.items, key_raw, .key);
                if (wrap_key_in_map) try acc.append(ctx.allocator, '(');
                try acc.appendSlice(ctx.allocator, key);
                if (wrap_key_in_map) try acc.append(ctx.allocator, ')');
                try acc.appendSlice(ctx.allocator, ": ");
                const wrap_list_in_map = value_mod.inspectMapListNeedsParens(ctx.list_pool.items, val_raw, .value);
                if (wrap_list_in_map) try acc.append(ctx.allocator, '(');
                try acc.appendSlice(ctx.allocator, val_s);
                if (wrap_list_in_map) try acc.append(ctx.allocator, ')');
                wrote_any = true;
            }
            try acc.append(ctx.allocator, ')');
            return acc.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
        }

        if (items.len == 0) {
            if (view.bracketed) {
                try acc.appendSlice(ctx.allocator, "[]");
            } else {
                try acc.appendSlice(ctx.allocator, "()");
            }
            return acc.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
        }

        if (items.len == 1 and (view.separator == .comma or view.separator == .slash)) {
            const inner = try valueToInspectCssString(ctx, items[0]);
            defer ctx.allocator.free(inner);
            if (view.bracketed) {
                try acc.append(ctx.allocator, '[');
                try acc.appendSlice(ctx.allocator, inner);
                try acc.appendSlice(ctx.allocator, if (view.separator == .comma) ",]" else " /]");
            } else {
                try acc.append(ctx.allocator, '(');
                try acc.appendSlice(ctx.allocator, inner);
                try acc.appendSlice(ctx.allocator, if (view.separator == .comma) ",)" else "/)");
            }
            return acc.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
        }

        if (view.bracketed) try acc.append(ctx.allocator, '[');

        const sep = value_mod.listSeparatorCssFrom(view.separator);
        try acc.ensureUnusedCapacity(ctx.allocator, items.len * (sep.len + 2) + 1);
        for (items, 0..) |item, i| {
            if (i > 0) try acc.appendSlice(ctx.allocator, sep);
            const part = try valueToInspectCssString(ctx, item);
            defer ctx.allocator.free(part);
            const needs_parens = value_mod.inspectNestedListNeedsParens(ctx.list_pool.items, item, view.separator);
            if (needs_parens) try acc.append(ctx.allocator, '(');
            try acc.appendSlice(ctx.allocator, part);
            if (needs_parens) try acc.append(ctx.allocator, ')');
        }
        if (view.bracketed) try acc.append(ctx.allocator, ']');
        return acc.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
    }
    if (value.kind() == .nil) {
        return ctx.allocator.dupe(u8, "null") catch error.OutOfMemory;
    }
    return shared.valueToCssString(ctx, value);
}

fn meta_inspect(ctx: *BuiltinContext, args: []const Value, _: []const InternId) BuiltinError!Value {
    try expectArity(args, 1);
    const s = try valueToInspectCssString(ctx, args[0]);
    defer ctx.allocator.free(s);
    const id = try internString(ctx, s);
    return Value.stringWithFlags(id, false, true).withPreserveLiteralText();
}

fn meta_feature_exists(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"feature"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const feature_v = b[0] orelse return error.BuiltinArity;
    if (feature_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "feature", feature_v, "string");
    const feature = ctx.intern_pool.get(feature_v.stringIntern());
    // feature-exists() does not equate dash/underscore (dash-sensitive).
    const exists = std.mem.eql(u8, feature, "global-variable-shadowing") or
        std.mem.eql(u8, feature, "extend-selector-pseudoclass") or
        std.mem.eql(u8, feature, "units-level-3") or
        std.mem.eql(u8, feature, "at-error") or
        std.mem.eql(u8, feature, "custom-property");
    return if (exists) Value.true_v else Value.false_v;
}

fn meta_accepts_content(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"mixin"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const mixinv = b[0] orelse return error.BuiltinArity;
    if (mixinv.kind() != .callable or !mixinv.callableIsMixin(ctx.callable_payload_pool)) return reportArgumentTypeMismatch(ctx, "mixin", mixinv, "mixin reference");
    return if (mixinv.callableAcceptsContent(ctx.callable_payload_pool)) Value.true_v else Value.false_v;
}

fn meta_content_exists(ctx: *BuiltinContext, args: []const Value, _: []const InternId) BuiltinError!Value {
    try expectArity(args, 0);
    const vm = getVM(ctx);
    switch (vm.current_chunk) {
        .mixin => {},
        else => return error.SassError,
    }
    if (vm.frame_stack.items.len == 0) return error.SassError;
    const fr = vm.frame_stack.items[vm.frame_stack.items.len - 1];
    const exists = fr.content_chunk_id != std.math.maxInt(u32);
    return if (exists) Value.true_v else Value.false_v;
}

fn meta_keywords(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"args"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const arg_list = b[0] orelse return error.BuiltinArity;
    if (arg_list.kind() != .list) return reportArgumentTypeMismatch(ctx, "args", arg_list, "argument list");

    const vm = getVM(ctx);
    const kw_handle = vm.arglist_keyword_lists.get(arg_list.listHandle()) orelse return error.BuiltinType;
    if (kw_handle >= ctx.list_pool.items.len) return error.BuiltinType;
    return Value.listWithMeta(kw_handle, .comma, false, true);
}

const CalcText = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        if (self.owned) |buf| alloc.free(buf);
    }
};

fn calcValueText(ctx: *BuiltinContext, value: Value) BuiltinError!CalcText {
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        return .{ .text = shared.stripCalcArgMarker(ctx.intern_pool.get(value.stringIntern())) };
    }
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try shared.valueToCssString(ctx, value);
        return .{ .text = rendered, .owned = @constCast(rendered) };
    }
    return error.BuiltinType;
}

fn meta_calc_name(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"calc"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const calc_v = b[0] orelse return error.BuiltinArity;
    if (calc_v.kind() == .number and calc_v.unitId(ctx.number_pool) != .none) {
        const name_id = try internString(ctx, "calc");
        return Value.string(name_id, true);
    }
    const raw = try calcValueText(ctx, calc_v);
    defer raw.deinit(ctx.allocator);
    const parsed = parseCalculationCall(raw.text) orelse return error.BuiltinType;
    const name_id = try internString(ctx, parsed.name);
    return Value.string(name_id, true);
}

fn meta_calc_args(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"calc"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const calc_v = b[0] orelse return error.BuiltinArity;
    if (calc_v.kind() == .number and calc_v.unitId(ctx.number_pool) != .none) {
        const rendered = try shared.valueToCssString(ctx, calc_v);
        defer ctx.allocator.free(rendered);
        const id = try internString(ctx, rendered);
        const item = Value.string(id, false);
        return pushCommaList(ctx, &[_]Value{item});
    }
    const raw = try calcValueText(ctx, calc_v);
    defer raw.deinit(ctx.allocator);
    const parsed = parseCalculationCall(raw.text) orelse return error.BuiltinType;

    var arg_texts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer arg_texts.deinit(ctx.allocator);
    try splitCalculationArgs(ctx.allocator, parsed.args_text, &arg_texts);

    var values: std.ArrayListUnmanaged(Value) = .empty;
    defer values.deinit(ctx.allocator);
    try values.ensureTotalCapacity(ctx.allocator, arg_texts.items.len);

    const simplify_numbers = !shared.identifierEq(parsed.name, "calc");
    for (arg_texts.items) |arg_text| {
        try values.append(ctx.allocator, try calcArgToValue(ctx, arg_text, simplify_numbers));
    }

    return pushCommaList(ctx, values.items);
}

fn meta_variable_exists(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"name"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.BuiltinArity;
    if (name_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "name", name_v, "string");
    const name = ctx.intern_pool.get(name_v.stringIntern());
    const vm = getVM(ctx);

    if (vm.currentBuiltinLocalSlotHint()) |slot| {
        if (vm.isCurrentFrameSlotDeclared(slot)) return Value.true_v;
    }

    const mod = &vm.program.modules[vm.current_module];
    const local_exists = moduleDeclaredVarExists(vm, vm.current_module, name);
    if (voidMapContainsIdentifier(&mod.ambiguous_star_vars, name) and !local_exists) {
        return error.SassError;
    }
    if (local_exists) return Value.true_v;
    if (lookupIdentifierVarTarget(&mod.star_vars, name)) |target| {
        if (vm.isModuleGlobalDeclared(target.value.module_id, target.value.slot)) {
            return Value.true_v;
        }
    }
    return Value.false_v;
}

fn meta_global_variable_exists(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{ "name", "module" };
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.SassError;
    if (name_v.kind() != .string) return error.SassError;
    const name = ctx.intern_pool.get(name_v.stringIntern());

    const vm = getVM(ctx);
    const current_mod = &vm.program.modules[vm.current_module];

    const has_module_arg = if (b[1]) |module_v|
        module_v.kind() != .nil
    else
        false;
    if (has_module_arg) {
        if (b[1] == null or b[1].?.kind() != .string) return error.SassError;
        const module_info = findModule(ctx, b[1]) catch return error.SassError;
        switch (module_info) {
            .current => {
                return if (moduleDeclaredVarExists(vm, vm.current_module, name)) Value.true_v else Value.false_v;
            },
            .user => |mid| {
                return if (moduleDeclaredVarExists(vm, mid, name)) Value.true_v else Value.false_v;
            },
            .builtin => |module_name| {
                return if (builtinModuleVariableExists(module_name, name)) Value.true_v else Value.false_v;
            },
            .not_found => return error.SassError,
        }
    }

    const local_exists = moduleDeclaredVarExists(vm, vm.current_module, name);
    if (voidMapContainsIdentifier(&current_mod.ambiguous_star_vars, name) and !local_exists) return error.SassError;
    if (local_exists) return Value.true_v;
    if (lookupIdentifierVarTarget(&current_mod.star_vars, name)) |target| {
        if (vm.isModuleGlobalDeclared(target.value.module_id, target.value.slot)) {
            return Value.true_v;
        }
    }
    return Value.false_v;
}

fn resolveCurrentFunctionCallable(ctx: *BuiltinContext, name: []const u8) BuiltinError!?Value {
    const vm = getVM(ctx);
    const mod = &vm.program.modules[vm.current_module];
    const builtin_mod = @import("../builtin/mod.zig");

    if (lookupIdentifierId(&mod.function_names, name)) |entry| {
        return try makeUserFunctionCallable(ctx, vm.current_module, entry.value, entry.key);
    }
    if (voidMapContainsIdentifier(&mod.ambiguous_star_functions, name)) {
        return error.SassError;
    }
    if (lookupIdentifierCallable(&mod.star_functions, name)) |entry| {
        return try makeUserFunctionCallable(ctx, entry.value.module_id, entry.value.id, entry.key);
    }
    if (lookupIdentifierId(&mod.star_builtin_fns, name)) |entry| {
        return try makeBuiltinFunctionCallable(ctx, entry.value, entry.key, false);
    }
    if (builtin_mod.resolveLegacyGlobal(name)) |builtin_id| {
        return try makeBuiltinFunctionCallable(ctx, builtin_id, name, false);
    }
    return null;
}

fn resolveSpecificFunctionCallable(ctx: *BuiltinContext, module_info: ModuleId, module_name: ?[]const u8, name: []const u8) BuiltinError!?Value {
    const vm = getVM(ctx);
    switch (module_info) {
        .current => return resolveCurrentFunctionCallable(ctx, name),
        .user => |mid| {
            if (mid >= vm.program.modules.len) return null;
            const mod = &vm.program.modules[mid];
            if (voidMapContainsIdentifier(&mod.ambiguous_export_functions, name)) {
                return error.SassError;
            }
            if (lookupIdentifierCallable(&mod.exported_functions, name)) |entry| {
                if (module_name) |label| {
                    return try makeUserFunctionCallableQualified(ctx, label, entry.value.module_id, entry.value.id, entry.key);
                }
                return try makeUserFunctionCallable(ctx, entry.value.module_id, entry.value.id, entry.key);
            }
            if (lookupIdentifierId(&mod.exported_builtin_fns, name)) |entry| {
                return try makeBuiltinFunctionCallable(ctx, entry.value, entry.key, false);
            }
            return null;
        },
        .builtin => |bname| {
            if (try builtinFunctionIdCompat(ctx, bname, name)) |builtin_id| {
                return try makeBuiltinFunctionCallable(ctx, builtin_id, name, false);
            }
            return null;
        },
        .not_found => return error.SassError,
    }
}

fn mixinAcceptsContent(vm: *VM, module_id: u32, mixin_id: u32) bool {
    if (module_id >= vm.program.modules.len) return false;
    const mod = &vm.program.modules[module_id];
    if (mixin_id >= mod.mixins.len) return false;
    return mod.mixins[mixin_id].has_content;
}

fn resolveCurrentMixinCallable(ctx: *BuiltinContext, name: []const u8) BuiltinError!?Value {
    const vm = getVM(ctx);
    const mod = &vm.program.modules[vm.current_module];
    if (lookupIdentifierId(&mod.mixin_names, name)) |entry| {
        return try makeUserMixinCallable(ctx, vm.current_module, entry.value, entry.key, mixinAcceptsContent(vm, vm.current_module, entry.value));
    }
    if (voidMapContainsIdentifier(&mod.ambiguous_star_mixins, name)) {
        return error.SassError;
    }
    if (lookupIdentifierCallable(&mod.star_mixins, name)) |entry| {
        return try makeUserMixinCallable(ctx, entry.value.module_id, entry.value.id, entry.key, mixinAcceptsContent(vm, entry.value.module_id, entry.value.id));
    }
    return null;
}

fn resolveSpecificMixinCallable(ctx: *BuiltinContext, module_info: ModuleId, module_name: ?[]const u8, name: []const u8) BuiltinError!?Value {
    const vm = getVM(ctx);
    const builtin_mod = @import("../builtin/mod.zig");
    switch (module_info) {
        .current => return resolveCurrentMixinCallable(ctx, name),
        .user => |mid| {
            if (mid >= vm.program.modules.len) return null;
            const mod = &vm.program.modules[mid];
            if (voidMapContainsIdentifier(&mod.ambiguous_export_mixins, name)) {
                return error.SassError;
            }
            if (lookupIdentifierCallable(&mod.exported_mixins, name)) |entry| {
                if (module_name) |label| {
                    return try makeUserMixinCallableQualified(ctx, label, entry.value.module_id, entry.value.id, entry.key, mixinAcceptsContent(vm, entry.value.module_id, entry.value.id));
                }
                return try makeUserMixinCallable(ctx, entry.value.module_id, entry.value.id, entry.key, mixinAcceptsContent(vm, entry.value.module_id, entry.value.id));
            }
            return null;
        },
        .builtin => |bname| {
            if (builtin_mod.resolveMixin(bname, name)) |builtin_id| {
                const display_name = if (builtin_id == builtin_mod.meta_apply_mixin_id) "apply" else "load-css";
                return try makeBuiltinMixinCallable(ctx, builtin_id, display_name, builtin_id == builtin_mod.meta_apply_mixin_id);
            }
            return null;
        },
        .not_found => return error.SassError,
    }
}

fn meta_get_function(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{ "name", "css", "module" };
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.BuiltinArity;
    if (name_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "name", name_v, "string");
    const name = ctx.intern_pool.get(name_v.stringIntern());

    const css_mode = if (b[1]) |css_v| blk: {
        if (css_v.kind() != .boolean) return reportArgumentTypeMismatch(ctx, "css", css_v, "bool");
        break :blk css_v.p64Of() != 0;
    } else false;
    const has_module_arg = b[2] != null and b[2].?.kind() != .nil;
    if (css_mode and has_module_arg) return error.SassError;

    const module_info = try findModule(ctx, b[2]);
    const module_name = if (b[2]) |module_v|
        if (module_v.kind() == .string) ctx.intern_pool.get(module_v.stringIntern()) else null
    else
        null;
    if (css_mode) return makeCssFunctionCallable(ctx, name);
    return (try resolveSpecificFunctionCallable(ctx, module_info, module_name, name)) orelse error.SassError;
}

fn meta_get_mixin(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{ "name", "module" };
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.BuiltinArity;
    if (name_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "name", name_v, "string");
    const name = ctx.intern_pool.get(name_v.stringIntern());

    const module_info = try findModule(ctx, b[1]);
    const module_name = if (b[1]) |module_v|
        if (module_v.kind() == .string) ctx.intern_pool.get(module_v.stringIntern()) else null
    else
        null;
    return (try resolveSpecificMixinCallable(ctx, module_info, module_name, name)) orelse error.SassError;
}

fn meta_function_exists(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{ "name", "module" };
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.BuiltinArity;
    if (name_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "name", name_v, "string");
    const name = ctx.intern_pool.get(name_v.stringIntern());
    const vm = getVM(ctx);
    const exists = switch (try findModule(ctx, b[1])) {
        .current => (try resolveCurrentFunctionCallable(ctx, name)) != null,
        .user => |mid| blk: {
            if (mid >= vm.program.modules.len) break :blk false;
            const mod = &vm.program.modules[mid];
            if (voidMapContainsIdentifier(&mod.ambiguous_export_functions, name)) return error.SassError;
            break :blk lookupIdentifierCallable(&mod.exported_functions, name) != null or
                lookupIdentifierId(&mod.exported_builtin_fns, name) != null;
        },
        .builtin => |bname| try builtinFunctionExistsCompat(ctx, bname, name),
        .not_found => return error.BuiltinUnsupported,
    };
    return if (exists) Value.true_v else Value.false_v;
}

fn meta_mixin_exists(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{ "name", "module" };
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const name_v = b[0] orelse return error.BuiltinArity;
    if (name_v.kind() != .string) return reportArgumentTypeMismatch(ctx, "name", name_v, "string");
    const name = ctx.intern_pool.get(name_v.stringIntern());
    const vm = getVM(ctx);
    const builtin_mod = @import("../builtin/mod.zig");

    const exists = switch (try findModule(ctx, b[1])) {
        .current => (try resolveCurrentMixinCallable(ctx, name)) != null,
        .user => |mid| blk: {
            if (mid >= vm.program.modules.len) break :blk false;
            const mod = &vm.program.modules[mid];
            if (voidMapContainsIdentifier(&mod.ambiguous_export_mixins, name)) return error.SassError;
            break :blk lookupIdentifierCallable(&mod.exported_mixins, name) != null;
        },
        .builtin => |bname| builtin_mod.resolveMixin(bname, name) != null,
        .not_found => return error.BuiltinUnsupported,
    };
    return if (exists) Value.true_v else Value.false_v;
}

fn meta_module_variables(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"module"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const module_info = try findModule(ctx, b[0] orelse return error.BuiltinArity);
    const vm = getVM(ctx);

    var pairs: std.ArrayListUnmanaged(MapPair) = .empty;
    defer pairs.deinit(ctx.allocator);

    switch (module_info) {
        .current => {
            const mid = vm.current_module;
            const mod = &vm.program.modules[mid];
            const globals = vm.mod_globals_bufs[mid];
            var it = mod.global_slots.iterator();
            while (it.next()) |entry| {
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(try internDisplayIdentifier(ctx, entry.key_ptr.*), true),
                    .value = if (entry.value_ptr.* < globals.len) globals[entry.value_ptr.*] else Value.nil_v,
                });
            }
        },
        .user => |mid| {
            if (mid < vm.program.modules.len) {
                const mod = &vm.program.modules[mid];
                var it = mod.exported_vars.iterator();
                while (it.next()) |entry| {
                    if (voidMapContainsIdentifier(&mod.ambiguous_export_vars, entry.key_ptr.*)) continue;
                    const target = entry.value_ptr.*;
                    const value = if (target.module_id < vm.mod_globals_bufs.len) blk: {
                        const globals = vm.mod_globals_bufs[target.module_id];
                        break :blk if (target.slot < globals.len) globals[target.slot] else Value.nil_v;
                    } else Value.nil_v;
                    try pairs.append(ctx.allocator, .{
                        .key = Value.string(try internDisplayIdentifier(ctx, entry.key_ptr.*), true),
                        .value = value,
                    });
                }
            }
        },
        .builtin => {},
        .not_found => return error.BuiltinUnsupported,
    }

    sortMapPairs(ctx, pairs.items);
    return pushMapPairs(ctx, pairs.items);
}

fn meta_module_functions(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"module"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const module_info = try findModule(ctx, b[0] orelse return error.BuiltinArity);
    const module_name = ctx.intern_pool.get((b[0] orelse return error.BuiltinArity).stringIntern());
    const vm = getVM(ctx);
    const builtin_mod = @import("../builtin/mod.zig");

    var pairs: std.ArrayListUnmanaged(MapPair) = .empty;
    defer pairs.deinit(ctx.allocator);

    switch (module_info) {
        .current => {
            const mid = vm.current_module;
            const mod = &vm.program.modules[mid];
            var it = mod.exported_functions.iterator();
            while (it.next()) |entry| {
                if (voidMapContainsIdentifier(&mod.ambiguous_export_functions, entry.key_ptr.*)) continue;
                const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(display_id, false),
                    .value = try makeUserFunctionCallableQualified(ctx, module_name, entry.value_ptr.*.module_id, entry.value_ptr.*.id, entry.key_ptr.*),
                });
            }
            var bit = mod.exported_builtin_fns.iterator();
            while (bit.next()) |entry| {
                const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(display_id, false),
                    .value = try makeBuiltinFunctionCallable(ctx, entry.value_ptr.*, entry.key_ptr.*, false),
                });
            }
        },
        .user => |mid| {
            if (mid < vm.program.modules.len) {
                const mod = &vm.program.modules[mid];
                var it = mod.exported_functions.iterator();
                while (it.next()) |entry| {
                    if (voidMapContainsIdentifier(&mod.ambiguous_export_functions, entry.key_ptr.*)) continue;
                    const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                    try pairs.append(ctx.allocator, .{
                        .key = Value.string(display_id, false),
                        .value = try makeUserFunctionCallableQualified(ctx, module_name, entry.value_ptr.*.module_id, entry.value_ptr.*.id, entry.key_ptr.*),
                    });
                }
                var bit = mod.exported_builtin_fns.iterator();
                while (bit.next()) |entry| {
                    const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                    try pairs.append(ctx.allocator, .{
                        .key = Value.string(display_id, false),
                        .value = try makeBuiltinFunctionCallable(ctx, entry.value_ptr.*, entry.key_ptr.*, false),
                    });
                }
            }
        },
        .builtin => |bname| {
            var fns: std.StringHashMapUnmanaged(u32) = .empty;
            defer fns.deinit(ctx.allocator);
            try builtin_mod.fillBuiltinFunctionNameToIdMap(ctx.allocator, bname, &fns);
            var it = fns.iterator();
            while (it.next()) |entry| {
                const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(display_id, false),
                    .value = try makeBuiltinFunctionCallable(ctx, entry.value_ptr.*, entry.key_ptr.*, false),
                });
            }
        },
        .not_found => return error.BuiltinUnsupported,
    }

    sortMapPairs(ctx, pairs.items);
    return pushMapPairs(ctx, pairs.items);
}

fn meta_module_mixins(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const params = [_][]const u8{"module"};
    const b = try shared.bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &params, 1);
    const module_info = try findModule(ctx, b[0] orelse return error.BuiltinArity);
    const vm = getVM(ctx);
    const builtin_mod = @import("../builtin/mod.zig");

    var pairs: std.ArrayListUnmanaged(MapPair) = .empty;
    defer pairs.deinit(ctx.allocator);

    switch (module_info) {
        .current => {
            const mid = vm.current_module;
            const mod = &vm.program.modules[mid];
            var it = mod.exported_mixins.iterator();
            while (it.next()) |entry| {
                if (voidMapContainsIdentifier(&mod.ambiguous_export_mixins, entry.key_ptr.*)) continue;
                const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(display_id, false),
                    .value = try makeUserMixinCallable(ctx, entry.value_ptr.*.module_id, entry.value_ptr.*.id, entry.key_ptr.*, mixinAcceptsContent(vm, entry.value_ptr.*.module_id, entry.value_ptr.*.id)),
                });
            }
        },
        .user => |mid| {
            if (mid < vm.program.modules.len) {
                const mod = &vm.program.modules[mid];
                var it = mod.exported_mixins.iterator();
                while (it.next()) |entry| {
                    if (voidMapContainsIdentifier(&mod.ambiguous_export_mixins, entry.key_ptr.*)) continue;
                    const display_id = try internDisplayIdentifier(ctx, entry.key_ptr.*);
                    try pairs.append(ctx.allocator, .{
                        .key = Value.string(display_id, false),
                        .value = try makeUserMixinCallable(ctx, entry.value_ptr.*.module_id, entry.value_ptr.*.id, entry.key_ptr.*, mixinAcceptsContent(vm, entry.value_ptr.*.module_id, entry.value_ptr.*.id)),
                    });
                }
            }
        },
        .builtin => |bname| {
            if (std.mem.eql(u8, bname, "meta")) {
                const apply_id = try internString(ctx, "apply");
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(apply_id, false),
                    .value = try makeBuiltinMixinCallable(ctx, builtin_mod.meta_apply_mixin_id, "apply", true),
                });
                const load_css_id = try internString(ctx, "load-css");
                try pairs.append(ctx.allocator, .{
                    .key = Value.string(load_css_id, false),
                    .value = try makeBuiltinMixinCallable(ctx, builtin_mod.meta_load_css_mixin_id, "load-css", false),
                });
            }
        },
        .not_found => return error.BuiltinUnsupported,
    }

    sortMapPairs(ctx, pairs.items);
    return pushMapPairs(ctx, pairs.items);
}

pub export fn zsass_builtin_meta_dispatch(
    ctx: *BuiltinContext,
    id: Id,
    args_ptr: [*]const Value,
    args_len: usize,
    arg_names_ptr: [*]const InternId,
    arg_names_len: usize,
    out_value: *Value,
) callconv(.c) meta_dispatch_abi.Status {
    const args = args_ptr[0..args_len];
    const arg_names = arg_names_ptr[0..arg_names_len];
    const dispatch_kind = meta_dispatch_abi.dispatchKindById(id) orelse return .builtin_unsupported;
    const result = switch (dispatch_kind) {
        .call => meta_call(ctx, args, arg_names),
        .apply => meta_apply(ctx, args, arg_names),
        .type_of => meta_type_of(ctx, args, arg_names),
        .inspect => meta_inspect(ctx, args, arg_names),
        .feature_exists => meta_feature_exists(ctx, args, arg_names),
        .accepts_content => meta_accepts_content(ctx, args, arg_names),
        .variable_exists => meta_variable_exists(ctx, args, arg_names),
        .global_variable_exists => meta_global_variable_exists(ctx, args, arg_names),
        .function_exists => meta_function_exists(ctx, args, arg_names),
        .mixin_exists => meta_mixin_exists(ctx, args, arg_names),
        .content_exists => meta_content_exists(ctx, args, arg_names),
        .keywords => meta_keywords(ctx, args, arg_names),
        .module_variables => meta_module_variables(ctx, args, arg_names),
        .module_functions => meta_module_functions(ctx, args, arg_names),
        .module_mixins => meta_module_mixins(ctx, args, arg_names),
        .calc_name => meta_calc_name(ctx, args, arg_names),
        .calc_args => meta_calc_args(ctx, args, arg_names),
        .get_function => meta_get_function(ctx, args, arg_names),
        .get_mixin => meta_get_mixin(ctx, args, arg_names),
    };
    out_value.* = result catch |err| return meta_dispatch_abi.statusFromBuiltinError(err);
    return .ok;
}
