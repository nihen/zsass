const std = @import("std");
const builtin_mod = @import("../builtin/mod.zig");
const color_mod = @import("../color/color.zig");
const error_format = @import("error_format.zig");
const intern_pool_mod = @import("intern_pool.zig");
const perf = @import("perf.zig");
const resolver_mod = @import("../resolve/resolver.zig");
const name_lookup_mod = @import("../resolve/name_lookup.zig");
const value_format = @import("value_format.zig");
const value_mod = @import("value.zig");

const InternId = intern_pool_mod.InternId;
const Value = value_mod.Value;
const ListSeparator = value_mod.ListSeparator;

const meta_call_builtin_id: u32 = 77;
const meta_keywords_builtin_id: u32 = 132;
const content_none_sentinel: u32 = std.math.maxInt(u32);
const call_arg_splat_sentinel = resolver_mod.call_arg_splat_sentinel;

const vmStderrPrint = error_format.stderrPrint;

const identifierEq = name_lookup_mod.identifierEq;

fn lookupIdentifierIdMap(map: *const std.StringHashMapUnmanaged(u32), name: []const u8) ?u32 {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn lookupIdentifierCallableMap(
    map: *const std.StringHashMapUnmanaged(resolver_mod.CallableTarget),
    name: []const u8,
) ?resolver_mod.CallableTarget {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn callableWithPreboundFlag(self: anytype, value: Value) !Value {
    if (value.kind() != .callable) return value;
    const flags = value.callableRawFlags(&self.callable_payload_pool);
    if ((flags & value_mod.callable_flag_prebound) != 0) return value;
    return try Value.callableMake(
        value.callableHandle(&self.callable_payload_pool),
        flags | value_mod.callable_flag_prebound,
        value.callableModuleId(&self.callable_payload_pool),
        value.callableNameIntern(&self.callable_payload_pool),
        &self.callable_payload_pool,
        self.allocator,
    );
}

fn findMetaControlArgIndexRuntime(self: anytype, arg_names: []const InternId, argc: usize, control_name: []const u8) ?usize {
    var control_index: ?usize = null;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const name_id = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none and name_id != call_arg_splat_sentinel) {
            var raw = self.intern_pool.get(name_id);
            if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
            if (identifierEq(raw, control_name) and control_index == null) {
                control_index = i;
            }
            continue;
        }
        if (control_index == null) control_index = i;
    }
    return control_index;
}

fn builtinPreservesSlashLists(builtin_id: u32) bool {
    return switch (builtin_id) {
        62, // join
        66, // slash
        => true,
        else => false,
    };
}

pub fn dispatchBuiltinArgs(self: anytype, builtin_id: u32, args: []const Value, arg_names: []const InternId) !Value {
    perf.note(.vm_call_builtin);
    perf.note(.builtin_call);
    if (builtin_id == meta_keywords_builtin_id and args.len == 1) {
        if (try dispatchMetaKeywordsSingleArg(self, args, arg_names)) |out| return out;
    }
    var bctx = builtin_mod.BuiltinContext{
        .allocator = self.allocator,
        .intern_pool = self.intern_pool,
        .list_pool = &self.list_pool,
        .color_pool = self.color_pool,
        .number_pool = &self.number_pool,
        .callable_payload_pool = &self.callable_payload_pool,
        .list_meta_pool = &self.list_meta_pool,
        .string_flags_pool = &self.string_flags_pool,
        .random_state = &self.random_state,
        .vm = self,
        .map_lookup_index_cache = &self.map_lookup_index_cache,
        .list_index_cache = &self.list_index_cache,
        .slash_list_preserve = &self.slash_list_preserve,
        .list_parent_sel_none_hook = @TypeOf(self.*).builtinListSidecarHook,
        .deprecation_opts = &self.deprecation_opts,
    };
    const out = builtin_mod.dispatch(&bctx, builtin_id, args, arg_names) catch |e| {
        return reportBuiltinDispatchFailure(self, builtin_id, e);
    };
    if (builtin_id == 29 and // string.quote
        args.len >= 1 and
        args[0].kind() == .string and
        !args[0].stringQuoted(self.string_flags_pool.items) and
        out.kind() == .string and
        out.stringQuoted(self.string_flags_pool.items))
    {
        return normalizeQuotedDispatchResult(self, out);
    }
    if (builtinPreservesSlashLists(builtin_id)) {
        try self.markSlashListPreserve(out);
    }
    return out;
}

/// `meta.keywords($args)` special case: serve keyword maps recorded for the
/// arglist handle. Returns null when the single arg is named something other
/// than `$args`, letting the regular dispatch path take over.
noinline fn dispatchMetaKeywordsSingleArg(self: anytype, args: []const Value, arg_names: []const InternId) !?Value {
    const keywords_single_arg = blk: {
        if (arg_names.len == 0) break :blk true;
        if (arg_names.len != 1) break :blk false;
        if (arg_names[0] == .none) break :blk true;
        var raw = self.intern_pool.get(arg_names[0]);
        if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
        break :blk identifierEq(raw, "args");
    };
    if (!keywords_single_arg) return null;
    const arg = args[0];
    if (arg.kind() != .list) {
        self.recordArgumentTypeMismatchMessageForDispatch("args", arg, "argument list");
        return error.BuiltinType;
    }
    if (self.lookupArglistKeywordHandle(arg.listHandle())) |kw_handle| {
        _ = self.listItemsAt(kw_handle) catch {
            self.recordArgumentTypeMismatchMessageForDispatch("args", arg, "argument list");
            return error.BuiltinType;
        }; // validate handle
        return Value.listWithMeta(kw_handle, .comma, false, true);
    }
    self.recordArgumentTypeMismatchMessageForDispatch("args", arg, "argument list");
    return error.BuiltinType;
}

noinline fn reportBuiltinDispatchFailure(self: anytype, builtin_id: u32, e: builtin_mod.BuiltinError) builtin_mod.BuiltinError {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    const name = builtin_mod.debugNameById(builtin_id) orelse "?";
    if (error_format.verboseErrorsEnabled()) {
        vmStderrPrint("zsass builtin failure id={d} name={s} err={}\n", .{
            builtin_id,
            name,
            e,
        });
    }
    // The TAGD sink fd is a POSIX concept; on Windows the field is
    // unused, so skip the write entirely.
    if (@import("builtin").target.os.tag != .windows) {
        if (self.error_sink_fd) |fd| {
            var buf: [128]u8 = undefined;
            const line_opt = std.fmt.bufPrint(&buf, "TAGD={s}:{s}\n", .{ @errorName(e), name }) catch null;
            if (line_opt) |line| {
                _ = std.c.write(fd, line.ptr, line.len);
            }
        }
    }
    return e;
}

noinline fn normalizeQuotedDispatchResult(self: anytype, out: Value) !Value {
    const quoted_raw = self.stripCalcArgMarkerForDispatch(self.intern_pool.get(out.stringIntern()));
    const normalized = try self.serializeUnquotedDeclStringForDispatch(quoted_raw);
    defer self.allocator.free(normalized);
    const normalized_id = try self.intern_pool.intern(normalized);
    return Value.string(normalized_id, true);
}

fn shouldSerializeIndirectBuiltinAsRgb(name: []const u8) bool {
    // Legacy rgb/rgba via meta.call/get-function performs value evaluation on the builtin side.
    // Prefer rgb()/rgba() only for serialization (avoid shortening to hex).
    return identifierEq(name, "rgb") or identifierEq(name, "rgba");
}

fn clampLegacyByte(v: f64) f64 {
    if (!std.math.isFinite(v)) return 0.0;
    const clamped = std.math.clamp(v, 0.0, 255.0);
    const rounded = @round(clamped);
    return if (@abs(clamped - rounded) <= 1e-10) rounded else clamped;
}

pub fn maybeSerializeIndirectBuiltinColor(self: anytype, call_name: []const u8, result: Value) !Value {
    if (!shouldSerializeIndirectBuiltinAsRgb(call_name)) return result;
    if (result.kind() != .color) return result;

    const entry = result.colorEntry(self.color_pool);
    const primitive = color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
    const srgb = if (entry.space == .srgb) primitive else color_mod.convert(primitive, .srgb);

    const r = clampLegacyByte(srgb.channels[0] * 255.0);
    const g = clampLegacyByte(srgb.channels[1] * 255.0);
    const b = clampLegacyByte(srgb.channels[2] * 255.0);
    const a = std.math.clamp(srgb.channels[3], 0.0, 1.0);

    const rs = try value_format.formatNumberCore(self.allocator, r);
    defer self.allocator.free(rs);
    const gs = try value_format.formatNumberCore(self.allocator, g);
    defer self.allocator.free(gs);
    const bs = try value_format.formatNumberCore(self.allocator, b);
    defer self.allocator.free(bs);

    const text = if (identifierEq(call_name, "rgba") or @abs(a - 1.0) > 1e-12) blk: {
        const as = try value_format.formatNumberCore(self.allocator, a);
        defer self.allocator.free(as);
        break :blk try std.fmt.allocPrint(self.allocator, "rgba({s}, {s}, {s}, {s})", .{ rs, gs, bs, as });
    } else try std.fmt.allocPrint(self.allocator, "rgb({s}, {s}, {s})", .{ rs, gs, bs });
    defer self.allocator.free(text);

    const id = self.intern_pool.intern(text) catch return error.OutOfMemory;
    return Value.string(id, false);
}

fn resolveLegacyGlobalCached(self: anytype, name_id: InternId) !?builtin_mod.Id {
    const miss_sentinel = std.math.maxInt(u32);
    if (self.legacy_global_builtin_cache.get(name_id)) |cached| {
        return if (cached == miss_sentinel) null else cached;
    }

    const name = self.intern_pool.get(name_id);
    const resolved = builtin_mod.resolveLegacyGlobal(name);
    try self.legacy_global_builtin_cache.put(
        self.allocator,
        name_id,
        resolved orelse miss_sentinel,
    );
    return resolved;
}

pub fn invokeCallableFromBuiltinSync(
    self: anytype,
    expect_mixin: bool,
    target_v: Value,
    args: []const Value,
    arg_names: []const InternId,
) !Value {
    const saved_module = self.current_module;
    const saved_chunk = self.current_chunk;
    const saved_pc = self.pc;
    const saved_frame_depth = self.frame_stack.items.len;
    const saved_stack_len = self.stack.items.len;

    if (try invokeCallable(self, expect_mixin, target_v, args, arg_names, null)) |out| {
        return out;
    }

    while (true) {
        const step_result = try self.step();
        switch (step_result) {
            .continue_exec => {},
            .halt_top => return error.InternalError,
            .exit_run_chunk => return error.InternalError,
        }

        if (self.frame_stack.items.len == saved_frame_depth and
            self.current_module == saved_module and
            self.encodeChunkRefForDispatch(self.current_chunk) == self.encodeChunkRefForDispatch(saved_chunk) and
            self.pc == saved_pc)
        {
            break;
        }
    }

    if (expect_mixin) {
        if (self.stack.items.len != saved_stack_len) return error.InternalError;
        return Value.nil_v;
    }
    if (self.stack.items.len != saved_stack_len + 1) return error.InternalError;
    return try self.pop();
}

pub fn invokeCallable(
    self: anytype,
    expect_mixin: bool,
    target_v: Value,
    args: []const Value,
    arg_names: []const InternId,
    rest_separator_override: ?ListSeparator,
) !?Value {
    if (target_v.kind() == .string) {
        if (expect_mixin) return error.BuiltinType;
        const name_id = target_v.stringIntern();
        const name = self.intern_pool.get(name_id);
        if (lookupIdentifierIdMap(&self.program.modules[self.current_module].function_names, name)) |fid| {
            const module_id: u32 = self.current_module;
            try self.doCallPrepared(module_id, .{ .function = fid }, args, arg_names, rest_separator_override, false);
            return null;
        }
        if (lookupIdentifierCallableMap(&self.program.modules[self.current_module].star_functions, name)) |target| {
            try self.doCallPrepared(target.module_id, .{ .function = target.id }, args, arg_names, rest_separator_override, false);
            return null;
        }
        if (lookupIdentifierIdMap(&self.program.modules[self.current_module].star_builtin_fns, name)) |bid| {
            const result = try dispatchBuiltinArgs(self, bid, args, arg_names);
            return try maybeSerializeIndirectBuiltinColor(self, name, result);
        }
        if (try resolveLegacyGlobalCached(self, name_id)) |bid| {
            const result = try dispatchBuiltinArgs(self, bid, args, arg_names);
            return try maybeSerializeIndirectBuiltinColor(self, name, result);
        }
        return try self.buildCssCallableResult(target_v.stringIntern(), args, arg_names);
    }

    if (target_v.kind() != .callable) {
        self.recordArgumentTypeMismatchMessageForDispatch(
            if (expect_mixin) "mixin" else "function",
            target_v,
            if (expect_mixin) "mixin reference" else "function reference",
        );
        return error.BuiltinType;
    }
    if (target_v.callableIsMixin(&self.callable_payload_pool) != expect_mixin) {
        self.recordArgumentTypeMismatchMessageForDispatch(
            if (expect_mixin) "mixin" else "function",
            target_v,
            if (expect_mixin) "mixin reference" else "function reference",
        );
        return error.BuiltinType;
    }
    if (expect_mixin and self.pending_content_chunk != content_none_sentinel and !target_v.callableAcceptsContent(&self.callable_payload_pool)) {
        return error.BuiltinUnsupported;
    }

    if (target_v.callableIsCss(&self.callable_payload_pool)) {
        if (expect_mixin) return error.BuiltinType;
        const name_id = target_v.callableNameIntern(&self.callable_payload_pool);
        const name = self.intern_pool.get(name_id);
        if (target_v.callableCssLateSassResolution(&self.callable_payload_pool)) {
            if (lookupIdentifierIdMap(&self.program.modules[self.current_module].function_names, name)) |fid| {
                const module_id: u32 = self.current_module;
                try self.doCallPrepared(module_id, .{ .function = fid }, args, arg_names, rest_separator_override, false);
                return null;
            }
            if (lookupIdentifierCallableMap(&self.program.modules[self.current_module].star_functions, name)) |target| {
                try self.doCallPrepared(target.module_id, .{ .function = target.id }, args, arg_names, rest_separator_override, false);
                return null;
            }
            if (lookupIdentifierIdMap(&self.program.modules[self.current_module].star_builtin_fns, name)) |bid| {
                const result = try dispatchBuiltinArgs(self, bid, args, arg_names);
                return try maybeSerializeIndirectBuiltinColor(self, name, result);
            }
            if (try resolveLegacyGlobalCached(self, name_id)) |bid| {
                const result = try dispatchBuiltinArgs(self, bid, args, arg_names);
                return try maybeSerializeIndirectBuiltinColor(self, name, result);
            }
        }
        return try self.buildCssCallableResult(name_id, args, arg_names);
    }

    if (target_v.callableIsBuiltin(&self.callable_payload_pool)) {
        const handle = target_v.callableHandle(&self.callable_payload_pool);
        if (expect_mixin) {
            if (handle == builtin_mod.meta_apply_mixin_id) {
                const expanded_meta = try self.expandMetaApplyImplicitSplatArgs(args, arg_names);
                defer self.freeExpandedCallArgs(expanded_meta);
                const meta_args = expanded_meta.args;
                const meta_names = expanded_meta.arg_names;
                const control_idx = findMetaControlArgIndexRuntime(self, meta_names, meta_args.len, "mixin") orelse return error.BuiltinArity;
                const target = try callableWithPreboundFlag(self, meta_args[control_idx]);
                try self.validateMetaCallTarget(target, true);
                var forwarded_args = std.ArrayListUnmanaged(Value).empty;
                defer forwarded_args.deinit(self.allocator);
                var forwarded_names = std.ArrayListUnmanaged(InternId).empty;
                defer forwarded_names.deinit(self.allocator);
                try forwarded_args.ensureTotalCapacity(self.allocator, meta_args.len - 1);
                try forwarded_names.ensureTotalCapacity(self.allocator, meta_args.len - 1);
                for (meta_args, 0..) |arg, i| {
                    if (i == control_idx) continue;
                    try forwarded_args.append(self.allocator, arg);
                    if (meta_names.len != 0) try forwarded_names.append(self.allocator, meta_names[i]);
                }
                return try invokeCallable(self, true, target, forwarded_args.items, if (meta_names.len != 0) forwarded_names.items else &.{}, expanded_meta.last_spread_separator);
            }
            if (handle == builtin_mod.meta_load_css_mixin_id) {
                try self.invokeMetaLoadCss(args, arg_names);
                return null;
            }
            return error.BuiltinUnsupported;
        }
        if (handle == meta_call_builtin_id) {
            const control_idx = findMetaControlArgIndexRuntime(self, arg_names, args.len, "function") orelse return error.BuiltinArity;
            const target = try callableWithPreboundFlag(self, args[control_idx]);
            try self.validateMetaCallTarget(target, false);
            var forwarded_args = std.ArrayListUnmanaged(Value).empty;
            defer forwarded_args.deinit(self.allocator);
            var forwarded_names = std.ArrayListUnmanaged(InternId).empty;
            defer forwarded_names.deinit(self.allocator);
            try forwarded_args.ensureTotalCapacity(self.allocator, args.len - 1);
            try forwarded_names.ensureTotalCapacity(self.allocator, args.len - 1);
            for (args, 0..) |arg, i| {
                if (i == control_idx) continue;
                try forwarded_args.append(self.allocator, arg);
                if (arg_names.len != 0) try forwarded_names.append(self.allocator, arg_names[i]);
            }
            return try invokeCallable(self, false, target, forwarded_args.items, if (arg_names.len != 0) forwarded_names.items else &.{}, rest_separator_override);
        }
        const result = try dispatchBuiltinArgs(self, handle, args, arg_names);
        if (target_v.callableNameIntern(&self.callable_payload_pool) != .none) {
            const call_name = self.intern_pool.get(target_v.callableNameIntern(&self.callable_payload_pool));
            return try maybeSerializeIndirectBuiltinColor(self, call_name, result);
        }
        return result;
    }

    const callable_has_module = target_v.callableHasModule(&self.callable_payload_pool);
    const callable_module_matches_current = !callable_has_module or
        target_v.callableModuleId(&self.callable_payload_pool) == self.current_module;
    // Most unqualified calls are resolved at include/call time. Values returned by
    // meta.get-function()/meta.get-mixin() are explicit snapshots and must keep
    // their pre-bound handle even if the same name is redefined later.
    if (!expect_mixin and
        callable_module_matches_current and
        !target_v.callableCapturesCallersLocals(&self.callable_payload_pool) and
        !target_v.callablePrebound(&self.callable_payload_pool))
    {
        const name = blk: {
            const name_id = target_v.callableNameIntern(&self.callable_payload_pool);
            if (name_id != .none) break :blk self.intern_pool.get(name_id);
            const handle = target_v.callableHandle(&self.callable_payload_pool);
            if (expect_mixin) {
                if (handle >= self.program.modules[self.current_module].mixins.len) break :blk "";
                break :blk self.program.modules[self.current_module].mixins[handle].name;
            } else {
                if (handle >= self.program.modules[self.current_module].functions.len) break :blk "";
                break :blk self.program.modules[self.current_module].functions[handle].name;
            }
        };
        if (name.len == 0) {
            // Fall through to the pre-bound handle below.
        } else if (expect_mixin) {
            if (lookupIdentifierIdMap(&self.program.modules[self.current_module].mixin_names, name)) |mid| {
                try self.doCallPrepared(
                    self.current_module,
                    .{ .mixin = mid },
                    args,
                    arg_names,
                    rest_separator_override,
                    false,
                );
                return null;
            }
        } else {
            if (lookupIdentifierIdMap(&self.program.modules[self.current_module].function_names, name)) |fid| {
                try self.doCallPrepared(
                    self.current_module,
                    .{ .function = fid },
                    args,
                    arg_names,
                    rest_separator_override,
                    false,
                );
                return null;
            }
        }
    }

    const target_module: u32 = if (target_v.callableHasModule(&self.callable_payload_pool))
        target_v.callableModuleId(&self.callable_payload_pool)
    else
        self.current_module;
    const capture_callers_locals = target_v.callableCapturesCallersLocals(&self.callable_payload_pool);
    try self.doCallPrepared(
        target_module,
        if (expect_mixin) .{ .mixin = target_v.callableHandle(&self.callable_payload_pool) } else .{ .function = target_v.callableHandle(&self.callable_payload_pool) },
        args,
        arg_names,
        rest_separator_override,
        capture_callers_locals,
    );
    return null;
}
