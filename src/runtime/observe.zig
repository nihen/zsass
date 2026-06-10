//! Stage 1a observation: phase timer, opcode histogram hooks, disassembler, trace diff.
const std = @import("std");
const opcode_mod = @import("../ir/opcode.zig");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

fn nanoTimestampMonotonic() i128 {
    // std.Io.Timestamp.now is implemented per-OS by the runtime's I/O
    // backend, so this works on Linux, macOS, and Windows without OS-aware
    // bookkeeping in zsass.
    const ts = std.Io.Timestamp.now(zsass_io.io, .awake);
    return @as(i128, ts.nanoseconds);
}

pub const PhaseTimer = struct {
    parse_ns: i128 = 0,
    resolve_ns: i128 = 0,
    compile_ns: i128 = 0,
    execute_ns: i128 = 0,
    emit_ns: i128 = 0,

    pub fn begin() i128 {
        return nanoTimestampMonotonic();
    }

    pub fn record(self: *PhaseTimer, phase: Phase, start: i128) void {
        const now = nanoTimestampMonotonic();
        const elapsed = now - start;
        switch (phase) {
            .parse => self.parse_ns += elapsed,
            .resolve => self.resolve_ns += elapsed,
            .compile => self.compile_ns += elapsed,
            .execute => self.execute_ns += elapsed,
            .emit => self.emit_ns += elapsed,
        }
    }

    pub const Phase = enum { parse, resolve, compile, execute, emit };

    pub fn report(self: *const PhaseTimer, writer: anytype) !void {
        const total: i128 = self.parse_ns + self.resolve_ns + self.compile_ns + self.execute_ns + self.emit_ns;
        const phases = [_]struct { name: []const u8, ns: i128 }{
            .{ .name = "parse", .ns = self.parse_ns },
            .{ .name = "resolve", .ns = self.resolve_ns },
            .{ .name = "compile", .ns = self.compile_ns },
            .{ .name = "execute", .ns = self.execute_ns },
            .{ .name = "emit", .ns = self.emit_ns },
        };
        for (phases) |p| {
            const ms = @as(f64, @floatFromInt(p.ns)) / 1_000_000.0;
            const pct: f64 = if (total == 0)
                0.0
            else
                @as(f64, @floatFromInt(p.ns)) * 100.0 / @as(f64, @floatFromInt(total));
            try writer.print("{s:<10} {d:.3} ms ({d:.1}%)\n", .{ p.name, ms, pct });
        }
        const total_ms = @as(f64, @floatFromInt(total)) / 1_000_000.0;
        try writer.print("-------\n", .{});
        try writer.print("{s:<10} {d:.3} ms\n", .{ "total", total_ms });
    }
};

pub const OpcodeHistogram = struct {
    counts: [@intFromEnum(opcode_mod.Opcode._op_count)]u64 = [_]u64{0} ** @intFromEnum(opcode_mod.Opcode._op_count),

    pub inline fn tick(self: *OpcodeHistogram, op: opcode_mod.Opcode) void {
        std.debug.assert(op != ._op_count);
        self.counts[@intFromEnum(op)] += 1;
    }

    pub fn report(self: *const OpcodeHistogram, writer: anytype) !void {
        var total: u64 = 0;
        for (self.counts) |c| total += c;
        try writer.print("opcode counts:\n", .{});
        if (total == 0) {
            try writer.print("  (no samples)\n", .{});
            try writer.print("top 10 = 0% of total\n", .{});
            return;
        }

        const OpCount = @intFromEnum(opcode_mod.Opcode._op_count);
        const HistEntry = struct { op: opcode_mod.Opcode, count: u64 };
        var scratch: [OpCount]HistEntry = undefined;
        var n: usize = 0;
        for (0..@intFromEnum(opcode_mod.Opcode._op_count)) |i| {
            const tag: opcode_mod.Opcode = @enumFromInt(i);
            const c = self.counts[i];
            if (c == 0) continue;
            scratch[n] = .{ .op = tag, .count = c };
            n += 1;
        }
        std.mem.sort(HistEntry, scratch[0..n], {}, struct {
            fn lessThan(_: void, a: HistEntry, b: HistEntry) bool {
                return a.count > b.count;
            }
        }.lessThan);

        const top_n = @min(10, n);
        var top_sum: u64 = 0;
        for (0..top_n) |i| {
            const item = scratch[i];
            top_sum += item.count;
            const pct = @as(f64, @floatFromInt(item.count)) * 100.0 / @as(f64, @floatFromInt(total));
            var mnem_buf: [72]u8 = undefined;
            const mnem = opcodeMnemonicBuf(item.op, &mnem_buf);
            try writer.print("  {s:<16} {d:>12}  {d:.1}%\n", .{ mnem, item.count, pct });
        }
        const top_pct = @as(f64, @floatFromInt(top_sum)) * 100.0 / @as(f64, @floatFromInt(total));
        try writer.print("top {d} = {d:.1}% of total\n", .{ top_n, top_pct });
    }
};

pub fn disassemble(
    chunk_name: []const u8,
    argc: u16,
    local_count: u16,
    code: []const opcode_mod.Instruction,
    const_pool: []const value_mod.Value,
    intern_pool: *const intern_pool_mod.InternPool,
    writer: anytype,
) !void {
    try writer.print("=== {s} [argc={d}, locals={d}] ===\n", .{ chunk_name, argc, local_count });
    for (code, 0..) |inst, pc| {
        try disassembleInstruction(@intCast(pc), inst, const_pool, intern_pool, writer);
    }
}

fn disassembleInstruction(
    pc: u32,
    inst: opcode_mod.Instruction,
    const_pool: []const value_mod.Value,
    intern_pool: *const intern_pool_mod.InternPool,
    writer: anytype,
) !void {
    if (inst.op >= @intFromEnum(opcode_mod.Opcode._op_count)) {
        try writer.print("  {d:0>4}  (unknown)     op={d} arg_a={d} arg_b={d}\n", .{
            pc, inst.op, inst.arg_a, inst.arg_b,
        });
        return;
    }
    const op: opcode_mod.Opcode = @enumFromInt(inst.op);
    var mnem_buf: [72]u8 = undefined;
    const mnem = opcodeMnemonicBuf(op, &mnem_buf);

    var arg_buf: [96]u8 = undefined;
    const arg_part = switch (op) {
        .load_const => try std.fmt.bufPrint(&arg_buf, "{d}", .{inst.arg_b}),
        .load_local, .load_local_strict, .store_local, .store_local_writeback, .clear_local => try std.fmt.bufPrint(&arg_buf, "{d}", .{inst.arg_b}),
        .unpack => try std.fmt.bufPrint(&arg_buf, "{d}", .{inst.arg_a}),
        .push_flow_scope, .pop_flow_scope => "",
        .call_mixin => try std.fmt.bufPrint(&arg_buf, "mod={d} packed={d}", .{ inst.arg_a, inst.arg_b }),
        .call_function => try std.fmt.bufPrint(&arg_buf, "mod={d} packed={d}", .{ inst.arg_a, inst.arg_b }),
        .call_content => try std.fmt.bufPrint(&arg_buf, "meta={d}", .{inst.arg_b}),
        .call_placeholder => try std.fmt.bufPrint(&arg_buf, "mod={d} sel={d}", .{ inst.arg_a, inst.arg_b }),
        .record_extend => try std.fmt.bufPrint(&arg_buf, "flags={d} target={d}", .{ inst.arg_a, inst.arg_b }),
        .make_number_unit => try std.fmt.bufPrint(&arg_buf, "unit={d}", .{inst.arg_b}),
        .make_string => try std.fmt.bufPrint(&arg_buf, "intern={d} quoted={d}", .{ inst.arg_b, inst.arg_a }),
        .make_list => blk: {
            const sep = switch (value_mod.Value.unpackListSeparator(inst.arg_b)) {
                .space => "space",
                .comma => "comma",
                .slash => "slash",
                .undecided => "undecided",
            };
            break :blk try std.fmt.bufPrint(&arg_buf, "len={d} sep={s} bracketed={d}", .{
                inst.arg_a,
                sep,
                if (value_mod.Value.unpackListBracketed(inst.arg_b)) @as(u1, 1) else @as(u1, 0),
            });
        },
        .make_bool => try std.fmt.bufPrint(&arg_buf, "{d}", .{inst.arg_a}),
        .emit_decl, .emit_decl_raw, .emit_rule_begin, .push_selector_scope, .emit_fragment, .emit_raw_decl, .emit_at_rule_simple, .emit_at_rule_begin, .emit_comment => try std.fmt.bufPrint(&arg_buf, "{d}", .{inst.arg_b}),
        .emit_rule_begin_current, .emit_rule_begin_current_maybe => try std.fmt.bufPrint(&arg_buf, "", .{}),
        .load_local_add_const, .load_local_mul_const, .load_local_ge_const, .load_const_add_local => try std.fmt.bufPrint(&arg_buf, "slot={d} const={d}", .{ inst.arg_a, inst.arg_b }),
        .load_emit_decl => try std.fmt.bufPrint(&arg_buf, "slot={d} prop={d}", .{ inst.arg_a, inst.arg_b }),
        .branch_if_false_local => try std.fmt.bufPrint(&arg_buf, "slot={d} rel={d}", .{ inst.arg_a, @as(i32, @bitCast(inst.arg_b)) }),
        .for_test, .for_step, .each_test, .each_step => try std.fmt.bufPrint(&arg_buf, "loop={d} rel={d}", .{ inst.arg_a, @as(i32, @bitCast(inst.arg_b)) }),
        .each_bind => try std.fmt.bufPrint(&arg_buf, "loop={d}", .{inst.arg_a}),
        .branch_local_cmp_local_false => try std.fmt.bufPrint(&arg_buf, "cmp={d} rel={d}", .{ inst.arg_a, @as(i32, @bitCast(inst.arg_b)) }),
        .local_binop_local_store => try std.fmt.bufPrint(&arg_buf, "binop={d}", .{inst.arg_a}),
        .local_inc_const, .store_const_local => try std.fmt.bufPrint(&arg_buf, "slot={d} const={d}", .{ inst.arg_a, inst.arg_b }),
        .emit_rule_end_pop => try std.fmt.bufPrint(&arg_buf, "", .{}),
        .jmp, .jmp_if_false, .jmp_if_true => try std.fmt.bufPrint(&arg_buf, "rel={d}", .{@as(i32, @bitCast(inst.arg_b))}),
        .enter_frame => try std.fmt.bufPrint(&arg_buf, "locals={d}", .{inst.arg_a}),
        .load_arg => try std.fmt.bufPrint(&arg_buf, "idx={d}", .{inst.arg_a}),
        .set_content => try std.fmt.bufPrint(&arg_buf, "mod={d} content={d}", .{ inst.arg_a, inst.arg_b }),
        .call_indirect => try std.fmt.bufPrint(&arg_buf, "kind={d} meta={d}", .{ inst.arg_a, inst.arg_b }),
        .call_builtin => try std.fmt.bufPrint(&arg_buf, "id={d} meta={d}", .{ inst.arg_a, inst.arg_b }),
        .load_mod_global, .load_mod_global_strict => try std.fmt.bufPrint(&arg_buf, "mod={d} slot={d}", .{ inst.arg_a, inst.arg_b }),
        .run_dependency => try std.fmt.bufPrint(&arg_buf, "mod={d}", .{inst.arg_a}),
        .list_len, .list_item, .coerce_slash_free => try std.fmt.bufPrint(&arg_buf, "", .{}),
        .make_selector => try std.fmt.bufPrint(&arg_buf, "parts={d}", .{inst.arg_a}),
        .emit_rule_begin_dynamic, .push_selector_scope_dynamic, .emit_decl_dynamic, .push_at_root_scope, .pop_at_root_scope, .push_at_root_bubble, .pop_at_root_bubble, .push_prop_namespace, .pop_prop_namespace, .load_parent_selector => try std.fmt.bufPrint(&arg_buf, "", .{}),
        .nop, .halt, .pop, .dup, .add, .sub, .mul, .div, .mod, .neg, .pos, .slash_prefix, .not_op, .eq, .neq, .lt, .gt, .le, .ge, .and_op, .or_op, .ret, .ret_value, .ret_void, .leave_frame, .emit_rule_end, .emit_rule_end_maybe, .emit_rule_end_if_open, .emit_at_rule_end, .pop_rule_scope, .emit_comment_dynamic, .emit_error, .emit_debug, .emit_warn, .emit_stmt_gap => try std.fmt.bufPrint(&arg_buf, "", .{}),
        ._op_count => unreachable,
    };

    var comment_buf: [160]u8 = undefined;
    const comment = constComment(op, inst, const_pool, intern_pool, &comment_buf) orelse "";

    if (comment.len == 0) {
        try writer.print("  {d:0>4}  {s:<13} {s}\n", .{ pc, mnem, arg_part });
    } else {
        try writer.print("  {d:0>4}  {s:<13} {s:<23} ; {s}\n", .{ pc, mnem, arg_part, comment });
    }
}

fn constComment(
    op: opcode_mod.Opcode,
    inst: opcode_mod.Instruction,
    const_pool: []const value_mod.Value,
    intern_pool: *const intern_pool_mod.InternPool,
    buf: []u8,
) ?[]const u8 {
    switch (op) {
        .load_const => {
            const idx: usize = @intCast(inst.arg_b);
            if (idx >= const_pool.len) return tryFmt(buf, "const #{d} (oob)", .{idx});
            return formatValueBrief(const_pool[idx], intern_pool, buf);
        },
        .make_string => return tryFmt(buf, "\"{s}\"", .{intern_pool.get(@enumFromInt(@as(u32, @truncate(inst.arg_b))))}),
        else => return null,
    }
}

fn tryFmt(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch null;
}

fn formatValueBrief(v: value_mod.Value, intern_pool: *const intern_pool_mod.InternPool, buf: []u8) ?[]const u8 {
    if (v.kind() == .nil) return tryFmt(buf, "nil", .{});
    if (v.kind() == .boolean) return tryFmt(buf, "{s}", .{if (v.p64Of() != 0) "true" else "false"});
    if (v.kind() == .number) return tryFmt(buf, "{d}", .{@as(f64, @bitCast(v.p64Of()))});
    if (v.kind() == .string) return tryFmt(buf, "\"{s}\"", .{intern_pool.get(v.stringIntern())});
    if (v.kind() == .color) return tryFmt(buf, "color", .{});
    if (v.kind() == .list) return tryFmt(buf, "list", .{});
    if (v.kind() == .calc_fragment) return tryFmt(buf, "calc_frag", .{});
    if (v.kind() == .interp_fragment) return tryFmt(buf, "interp_frag", .{});
    if (v.kind() == .callable) return tryFmt(buf, "callable", .{});
    return null;
}

fn opcodeMnemonicBuf(op: opcode_mod.Opcode, buf: *[72]u8) []const u8 {
    const name = @tagName(op);
    var o: usize = 0;
    for (name) |c| {
        buf[o] = if (c == '_') '_' else std.ascii.toUpper(c);
        o += 1;
    }
    return buf[0..o];
}

const zsass_io = @import("io.zig");

pub fn traceDiff(
    reference_path: []const u8,
    generated: []const u8,
    writer: anytype,
    allocator: std.mem.Allocator,
) !bool {
    const ref_bytes = try std.Io.Dir.cwd().readFileAlloc(zsass_io.io, reference_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(ref_bytes);

    var ref_lines: std.ArrayList([]const u8) = .empty;
    defer ref_lines.deinit(allocator);
    try splitLinesAlloc(ref_bytes, allocator, &ref_lines);

    var gen_lines: std.ArrayList([]const u8) = .empty;
    defer gen_lines.deinit(allocator);
    try splitLinesAlloc(generated, allocator, &gen_lines);

    const max_len = @max(ref_lines.items.len, gen_lines.items.len);
    var diff_lines: usize = 0;
    var i: usize = 0;
    while (i < max_len) : (i += 1) {
        const r = if (i < ref_lines.items.len) ref_lines.items[i] else "";
        const g = if (i < gen_lines.items.len) gen_lines.items[i] else "";
        if (!std.mem.eql(u8, r, g)) diff_lines += 2;
    }

    if (diff_lines == 0) return true;

    try writer.print("=== diff with {s} ===\n", .{reference_path});

    var printed: usize = 0;
    const max_print = 10;
    i = 0;
    while (i < max_len and printed < max_print) : (i += 1) {
        const r = if (i < ref_lines.items.len) ref_lines.items[i] else "";
        const g = if (i < gen_lines.items.len) gen_lines.items[i] else "";
        if (std.mem.eql(u8, r, g)) continue;
        const line_no = i + 1;
        if (printed < max_print) {
            try writer.print("- {d}: {s}\n", .{ line_no, r });
            printed += 1;
        }
        if (printed < max_print) {
            try writer.print("+ {d}: {s}\n", .{ line_no, g });
            printed += 1;
        }
    }

    const remaining: usize = if (diff_lines > printed) diff_lines - printed else 0;
    if (remaining > 0) {
        try writer.print("(... {d} more differences)\n", .{remaining});
    }

    return false;
}

fn splitLinesAlloc(text: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var line_count: usize = 1;
    for (text) |c| {
        if (c == '\n') line_count += 1;
    }
    try out.ensureTotalCapacity(allocator, line_count);

    var start: usize = 0;
    for (text, 0..) |c, idx| {
        if (c == '\n') {
            var line = text[start..idx];
            if (line.len > 0 and line[line.len - 1] == '\r') line.len -= 1;
            try out.append(allocator, line);
            start = idx + 1;
        }
    }
    var last = text[start..];
    if (last.len > 0 and last[last.len - 1] == '\r') last.len -= 1;
    try out.append(allocator, last);
}

test "PhaseTimer record and report" {
    var timer: PhaseTimer = .{};
    const t0 = PhaseTimer.begin();
    timer.record(.parse, t0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    try timer.report(&aw.writer);
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "total") != null);
}

test "disassemble minimal chunk (LOAD_CONST + HALT)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try intern_pool_mod.InternPool.init(alloc);
    const code: [2]opcode_mod.Instruction = .{
        opcode_mod.Instruction.make(.load_const, 0, 0),
        opcode_mod.Instruction.make(.halt, 0, 0),
    };
    const consts: [1]value_mod.Value = .{value_mod.Value.numberUnitless(42)};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    try disassemble("mixin wrap", 2, 3, &code, &consts, &pool, &aw.writer);
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "LOAD_CONST") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "HALT") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "[argc=2, locals=3]") != null);
}
