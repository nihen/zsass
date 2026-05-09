//! Compile-time gated profile counters for the rewrite VM.
//!
//! Enable: `zig build -Dprofile=true`. When disabled, `bump`/`note`/`time` is
//! `if (comptime !enabled) return;` completely disappears into the optimizer (zero-cost).
//!
//! Multi-thread support: `compileFiles()` thread pool allows worker threads to be
//! To update the counter, each thread has a thread-local `Slot` array,
//! Aggregate at dump time. No need for atomic, hot path is simply `+= 1`.
//!
//! Usage (when enabled):
//!     const perf = @import("perf.zig");
//!     perf.note(.vm_step);                      // calls += 1
//!     perf.bump(.value_clone, payload_bytes);   // calls += 1, bytes += N
//!     {
//! var t = perf.timeBegin(); // ns measurement start
//! defer perf.timeEnd(.compile_ns, t); // end
//!         ...heavy work...
//!     }
//!
//! If you call `dumpAll(writer)` just before the process ends, all threads will be aggregated + sorted.
//! Emitted in the `zsass-perf <tag> calls=N bytes=N ns=N` format.

const std = @import("std");
const zsass_options = @import("zsass_options");

/// True with build option `-Dprofile=true`. When disabled, a set of measurement codes is
/// Disappears in the optimizer (callsites outside this module are also `if (comptime !enabled)`
/// It crashes on the return immediately after).
pub const enabled: bool = zsass_options.profile;

/// Measurement point. Can be added as necessary. The order is the sort key (descending calls) when dumping.
/// Since the enum order is determined, the enum order is divided into semantic groups for stability.
pub const Counter = enum {
    //---------- VM ----------
    /// Number of calls to `VM.step()` = total number of opcodes executed.
    vm_step,
    /// Builtin call during VM dispatch (`call_builtin` opcode route).
    vm_call_builtin,
    /// User function call (`call`/`call_dynamic`) during VM dispatch.
    vm_call_user,
    /// chunk frame push (function / loop body / @each etc.).
    vm_frame_push,
    /// `runLoadCssModule` call (runs dependent modules one by one).
    vm_module_run,

    //---------- GO compile ----------
    /// `compiler.compile()` once = 1 module's worth of bytecode generation.
    ir_compile_module,
    /// IR Chunk generation (function / mixin / top body etc.).
    ir_compile_chunk,
    /// 1 instruction emit.
    ir_emit_op,
    /// Number of peephole superinstruction fusion applications.
    ir_peephole_fuse,

    //---------- Resolve ----------
    /// resolver.resolve() call (1 source program  ->  ResolvedProgram).
    resolve_program,
    /// Load one external module with `@use` / `@import`.
    resolve_module_load,
    /// Cache hit for the same module (double load suppression).
    resolve_module_cache_hit,
    /// `@extend` apply (extend merge to selector tree).
    resolve_extend_apply,
    /// selector clone (occurs with extend / parent selector / interp).
    resolve_selector_clone,

    //---------- Frontend ----------
    /// lex 1 token.
    frontend_lex_token,
    /// parser emits one AST node.
    frontend_parse_node,

    //---------- Value ----------
    /// Clone (including deep copy) of runtime Value.
    value_clone,
    /// Create a new list (empty/non-single element).
    value_list_alloc,
    /// Create new map.
    value_map_alloc,
    /// string concat / new alloc (including via intern).
    value_string_alloc,

    //---------- InternPool ----------
    /// 1 intern lookup (including both hit/miss).
    intern_lookup,
    /// intern miss = new entry added.
    intern_miss,

    //---------- Builtin ----------
    /// Builtin function Called once.
    builtin_call,
    /// Color system builtin (color.* / hsl / rgb / mix, etc.).
    builtin_color_call,
    /// math system builtin.
    builtin_math_call,
    /// list / map builtin.
    builtin_list_call,
    /// Meta builtin (call / get-function / module-functions etc.).
    builtin_meta_call,

    //---------- Codegen ----------
    /// 1 CSS rule emit.
    codegen_rule,
    /// 1 declaration emit.
    codegen_decl,
    /// 1 at-rule emit.
    codegen_at_rule,
    /// selector String formatting/normalization path.
    format_selector,
    /// number CSS stringification (`formatNumberCore`).
    format_number,
    /// color CSS stringification (`formatColorCss`).
    format_color,
    /// declaration value string normalization.
    format_string,
    /// format string: `.5` candidate exists (dot + digit).
    format_string_dot_digit_candidate,
    /// format string: Detect math functions (`calc` / `min` etc.).
    format_string_math_function_detected,
    /// Pass format string: comment token (`/*` or `//`).
    format_string_comment_path,
    /// Pass through format string: escape (`\x`).
    format_string_escape_path,
    /// format string: actually insert leading zero.
    format_string_zero_filled,

    //---------- Phase timer (ns cumulative) ----------
    /// ns: parse phase cumulative.
    phase_parse_ns,
    /// ns: resolve phase cumulative.
    phase_resolve_ns,
    /// ns: compile phase cumulative.
    phase_compile_ns,
    /// ns: execute phase cumulative.
    phase_execute_ns,
    /// ns: emit (codegen + write) cumulative.
    phase_emit_ns,
};

const N: usize = @typeInfo(Counter).@"enum".fields.len;

const Slot = struct {
    calls: u64 = 0,
    bytes: u64 = 0,
    ns: u64 = 0,
};

/// Thread-local counter array. Each worker thread has its own array. dump at
/// Aggregate all threads via `registry`.
// SAFETY: When perf is disabled at comptime, `local` is never read; only the enabled branch uses this storage.
threadlocal var local: [N]Slot = if (enabled) [_]Slot{.{}} ** N else undefined;
threadlocal var local_registered: bool = false;

/// Keep the `local` pointers of all threads and aggregate them during dump. worker thread
/// Register own `local` at the first bump, and flush it just before the thread ends.
/// contention only when registerSelfIfNeeded / flushThread / dumpAll (during compile)
/// hot path is thread-local fast path (no lock required), spinlock is sufficient.
const Registry = struct {
    lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Committed (= flushed from workers that have already exited) aggregate value.
    finalized: [N]Slot = [_]Slot{.{}} ** N,
    /// `&local` list of currently alive threads. Lick this and add it when dumping.
    live: std.ArrayListUnmanaged(*[N]Slot) = .empty,
};

var registry: Registry = .{};

fn registryLock() void {
    while (registry.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn registryUnlock() void {
    registry.lock.store(0, .release);
}

inline fn registerSelfIfNeeded() void {
    if (comptime !enabled) return;
    if (local_registered) return;
    local_registered = true;
    registryLock();
    defer registryUnlock();
    // page_allocator: registry is process lifetime, no deinit required.
    registry.live.append(std.heap.page_allocator, &local) catch {
        // Measurement drop when OOM. Do not drop this process due to the measurement mechanism.
        local_registered = false;
    };
}

/// Called just before the Worker thread exits. Merge the value of `local` into `finalized`,
/// Remove from `live`. The main thread (alive until just before process exit) does not need to be called
/// OK because `dumpAll` picks it up via `live`.
pub fn flushThread() void {
    if (comptime !enabled) return;
    if (!local_registered) return;
    registryLock();
    defer registryUnlock();
    for (local, 0..) |slot, i| {
        registry.finalized[i].calls += slot.calls;
        registry.finalized[i].bytes += slot.bytes;
        registry.finalized[i].ns += slot.ns;
    }
    local = [_]Slot{.{}} ** N;
    // Exclude yourself from live.
    var idx: usize = 0;
    while (idx < registry.live.items.len) : (idx += 1) {
        if (registry.live.items[idx] == &local) {
            _ = registry.live.swapRemove(idx);
            break;
        }
    }
    local_registered = false;
}

/// 1 measurement (calls += 1). When disabled, it disappears completely.
pub inline fn note(comptime c: Counter) void {
    if (comptime !enabled) return;
    registerSelfIfNeeded();
    local[@intFromEnum(c)].calls += 1;
}

/// 1 measurement + bytes cumulative. When disabled, it disappears completely.
pub inline fn bump(comptime c: Counter, byte_count: u64) void {
    if (comptime !enabled) return;
    registerSelfIfNeeded();
    local[@intFromEnum(c)].calls += 1;
    local[@intFromEnum(c)].bytes += byte_count;
}

/// ns cumulative only (does not touch calls/bytes). For phase timer.
inline fn addNs(comptime c: Counter, ns_delta: u64) void {
    if (comptime !enabled) return;
    registerSelfIfNeeded();
    local[@intFromEnum(c)].ns += ns_delta;
}

/// Start of interval measurement. Only returns 0 when disabled.
pub inline fn timeBegin() i128 {
    if (comptime !enabled) return 0;
    // SAFETY: Filled by clock_gettime immediately below.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}

/// End of interval measurement. Pass the return value of `timeBegin`. No-op when disabled.
pub inline fn timeEnd(comptime c: Counter, start: i128) void {
    if (comptime !enabled) return;
    // SAFETY: Filled by clock_gettime immediately below.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return;
    const now: i128 = @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
    const delta = now - start;
    if (delta <= 0) return;
    addNs(c, @as(u64, @intCast(delta)));
}

/// One line for dump. Not called when disabled (dumpAll itself is a no-op).
const Aggregated = struct {
    tag: []const u8,
    slot: Slot,
};

/// Aggregate the counters of all threads and write them to `writer`. Output format:
///     zsass-perf <tag>                  calls=<N>   bytes=<N>   ns=<N>
/// The terms calls=0 and bytes=0 and ns=0 are omitted. calls descending (ties descending by ns).
pub fn dumpAll(writer: anytype) !void {
    if (comptime !enabled) return;

    var aggregated: [N]Slot = registry.finalized;
    {
        registryLock();
        defer registryUnlock();
        for (registry.live.items) |live_ptr| {
            for (live_ptr.*, 0..) |slot, i| {
                aggregated[i].calls += slot.calls;
                aggregated[i].bytes += slot.bytes;
                aggregated[i].ns += slot.ns;
            }
        }
    }

    const fields = @typeInfo(Counter).@"enum".fields;
    var entries: [N]Aggregated = undefined;
    var n: usize = 0;
    for (0..N) |i| {
        const s = aggregated[i];
        if (s.calls == 0 and s.bytes == 0 and s.ns == 0) continue;
        entries[n] = .{ .tag = fields[i].name, .slot = s };
        n += 1;
    }
    std.mem.sort(Aggregated, entries[0..n], {}, struct {
        fn lessThan(_: void, a: Aggregated, b: Aggregated) bool {
            if (a.slot.calls != b.slot.calls) return a.slot.calls > b.slot.calls;
            return a.slot.ns > b.slot.ns;
        }
    }.lessThan);

    try writer.print("zsass-perf entries={d}\n", .{n});
    for (entries[0..n]) |e| {
        try writer.print(
            "zsass-perf {s:<28} calls={d:>12}  bytes={d:>14}  ns={d:>14}\n",
            .{ e.tag, e.slot.calls, e.slot.bytes, e.slot.ns },
        );
    }
}

test "perf: disabled dumpAll is a no-op" {
    if (enabled) return error.SkipZigTest;
    note(.vm_step);
    bump(.value_clone, 64);
    addNs(.phase_parse_ns, 1234);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    try dumpAll(&aw.writer);
    buf = aw.toArrayList();
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "perf: enabled aggregates and dumps non-empty counters" {
    if (!enabled) return error.SkipZigTest;
    note(.vm_step);
    note(.vm_step);
    bump(.value_clone, 100);
    addNs(.phase_parse_ns, 50);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    try dumpAll(&aw.writer);
    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "vm_step") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "value_clone") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "phase_parse_ns") != null);
}
