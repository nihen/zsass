//! Per-compilation resource limits and the counters charged against them.
//!
//! One `ResourceBudget` covers a whole compilation: the entry stylesheet,
//! every module it loads, `meta.load-css()` children, and output. Callers
//! pass a pointer to it explicitly; there is no global or thread-local copy,
//! so a child module or VM cannot start from fresh counters.

const std = @import("std");

pub const default_max_source_bytes: usize = 128 * 1024 * 1024;
pub const default_max_syntax_depth: u32 = 512;
pub const default_max_vm_steps: u64 = 500_000_000;
pub const default_max_selector_candidates: usize = 200_000;
pub const default_max_ir_nodes: usize = 5_000_000;
pub const default_max_output_bytes: usize = 128 * 1024 * 1024;
pub const default_stack_bytes: usize = 4 * 1024 * 1024;

/// Caller-tunable limits. The defaults are finite so that compiling
/// untrusted input fails with a diagnostic instead of exhausting the
/// process; `unlimited()` restores the unbounded behavior for trusted input.
pub const CompileLimits = struct {
    /// Bytes of a single stylesheet source (the entry or a loaded module).
    max_source_bytes: usize = default_max_source_bytes,
    /// Nesting of syntax: blocks, parentheses, brackets, interpolation,
    /// unary operators, and chains of binary operators.
    max_syntax_depth: u32 = default_max_syntax_depth,
    /// VM instructions executed by the whole compilation.
    max_vm_steps: u64 = default_max_vm_steps,
    /// Selectors produced while extending, intermediates included, each
    /// counted by its number of compounds and combinators.
    max_selector_candidates: usize = default_max_selector_candidates,
    /// Rule, declaration, and other output nodes the VM emits.
    max_ir_nodes: usize = default_max_ir_nodes,
    /// Bytes of generated CSS.
    max_output_bytes: usize = default_max_output_bytes,
    /// Native stack the compiler may use below the frame that calls it,
    /// for recursion over values and selectors built at run time. The
    /// calling thread needs this much stack and some more to spare; lower
    /// it, and `max_syntax_depth`, on a thread with a small stack.
    stack_bytes: usize = default_stack_bytes,

    /// No limit on work or output. Recursion stays bound to `stack_bytes`
    /// of native stack, so very deep input still fails instead of crashing.
    pub fn unlimited() CompileLimits {
        return .{
            .max_source_bytes = std.math.maxInt(usize),
            .max_syntax_depth = std.math.maxInt(u32),
            .max_vm_steps = std.math.maxInt(u64),
            .max_selector_candidates = std.math.maxInt(usize),
            .max_ir_nodes = std.math.maxInt(usize),
            .max_output_bytes = std.math.maxInt(usize),
            .stack_bytes = default_stack_bytes,
        };
    }
};

/// Returns true when the caller wants compilation to stop.
pub const CancellationCheck = *const fn (ctx: ?*anyopaque) bool;

pub const LimitError = error{
    SourceSizeLimit,
    SyntaxNestingLimit,
    /// Values or selectors nested deeper than the native stack allows.
    NestingLimit,
    ExecutionLimit,
    SelectorExpansionLimit,
    IrNodeLimit,
    OutputSizeLimit,
    CompilationCancelled,
};

/// True for an error that a resource limit or cancellation raised. Code that
/// converts errors into a generic failure must pass these through unchanged.
pub fn isLimitError(err: anyerror) bool {
    return switch (err) {
        error.SourceSizeLimit,
        error.SyntaxNestingLimit,
        error.NestingLimit,
        error.ExecutionLimit,
        error.SelectorExpansionLimit,
        error.IrNodeLimit,
        error.OutputSizeLimit,
        error.CompilationCancelled,
        => true,
        else => false,
    };
}

pub const source_size_message = "Source size limit exceeded.";
pub const syntax_nesting_message = "Syntax nesting limit exceeded.";
pub const nesting_message = "Nesting limit exceeded.";
pub const execution_message = "Execution step limit exceeded.";
pub const selector_expansion_message = "Selector expansion limit exceeded.";
pub const ir_node_message = "Generated output node limit exceeded.";
pub const output_size_message = "Output size limit exceeded.";
pub const cancelled_message = "Compilation cancelled.";

/// User-facing message for a limit error, or null for any other error.
pub fn limitMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SourceSizeLimit => source_size_message,
        error.SyntaxNestingLimit => syntax_nesting_message,
        error.NestingLimit => nesting_message,
        error.ExecutionLimit => execution_message,
        error.SelectorExpansionLimit => selector_expansion_message,
        error.IrNodeLimit => ir_node_message,
        error.OutputSizeLimit => output_size_message,
        error.CompilationCancelled => cancelled_message,
        else => null,
    };
}

/// Stable diagnostic code for a limit error, or null for any other error.
pub fn limitCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SourceSizeLimit => "ZSASS_LIMIT_SOURCE_BYTES",
        error.SyntaxNestingLimit => "ZSASS_LIMIT_SYNTAX_DEPTH",
        error.NestingLimit => "ZSASS_LIMIT_NESTING_DEPTH",
        error.ExecutionLimit => "ZSASS_LIMIT_VM_STEPS",
        error.SelectorExpansionLimit => "ZSASS_LIMIT_SELECTOR_CANDIDATES",
        error.IrNodeLimit => "ZSASS_LIMIT_IR_NODES",
        error.OutputSizeLimit => "ZSASS_LIMIT_OUTPUT_BYTES",
        error.CompilationCancelled => "ZSASS_CANCELLED",
        else => null,
    };
}

/// Instructions between two calls of the cancellation callback.
pub const cancellation_interval: u64 = 1024;

pub const ResourceBudget = struct {
    limits: CompileLimits = .{},
    cancellation_check: ?CancellationCheck = null,
    cancellation_ctx: ?*anyopaque = null,

    vm_steps: u64 = 0,
    selector_candidates: usize = 0,
    ir_nodes: usize = 0,
    output_bytes: usize = 0,
    /// Steps left before `chargeVmStep` next takes its slow path. Kept here
    /// so that the hot path is a single compare and decrement.
    vm_fuel: u64 = 0,
    /// The first limit that failed. An entry point reports it even when code
    /// between the failure and the entry point replaced the error.
    exceeded: ?LimitError = null,

    pub fn init(limits: CompileLimits, cancellation_check: ?CancellationCheck, cancellation_ctx: ?*anyopaque) ResourceBudget {
        var b: ResourceBudget = .{
            .limits = limits,
            .cancellation_check = cancellation_check,
            .cancellation_ctx = cancellation_ctx,
        };
        b.vm_fuel = b.nextFuel();
        return b;
    }

    fn fail(self: *ResourceBudget, err: LimitError) LimitError {
        if (self.exceeded == null) self.exceeded = err;
        return err;
    }

    /// The error to report for `err`: the recorded limit when one failed.
    pub fn mapError(self: *const ResourceBudget, err: anyerror) anyerror {
        if (isLimitError(err)) return err;
        if (self.exceeded) |e| return e;
        return err;
    }

    pub fn checkSourceBytes(self: *ResourceBudget, len: usize) LimitError!void {
        if (len > self.limits.max_source_bytes) return self.fail(error.SourceSizeLimit);
    }

    pub fn checkCancelled(self: *ResourceBudget) LimitError!void {
        if (self.cancellation_check) |check| {
            if (check(self.cancellation_ctx)) return self.fail(error.CompilationCancelled);
        }
    }

    /// Charge one VM instruction. The common case only decrements `vm_fuel`;
    /// the slow path settles the count, checks the limit, and polls
    /// cancellation, so the limit is exact and the callback runs at most once
    /// per `cancellation_interval` instructions.
    pub inline fn chargeVmStep(self: *ResourceBudget) LimitError!void {
        if (self.vm_fuel != 0) {
            self.vm_fuel -= 1;
            return;
        }
        return self.refuelVm();
    }

    fn refuelVm(self: *ResourceBudget) LimitError!void {
        @branchHint(.cold);
        // `vm_steps` counts instructions already granted by earlier fuel.
        if (self.vm_steps >= self.limits.max_vm_steps) return self.fail(error.ExecutionLimit);
        try self.checkCancelled();
        // This call consumes one step of the new slice.
        self.vm_fuel = self.nextFuel() - 1;
    }

    /// Grant the next slice of steps and account for it in `vm_steps`.
    fn nextFuel(self: *ResourceBudget) u64 {
        const remaining = self.limits.max_vm_steps -| self.vm_steps;
        const slice = @min(remaining, cancellation_interval);
        self.vm_steps += slice;
        return slice;
    }

    /// Instructions executed so far.
    pub fn vmStepsUsed(self: *const ResourceBudget) u64 {
        return self.vm_steps - self.vm_fuel;
    }

    pub fn chargeSelectorCandidates(self: *ResourceBudget, n: usize) LimitError!void {
        try self.ensureSelectorCandidates(n);
        self.selector_candidates += n;
    }

    /// Fail when `n` more candidates would not fit, without charging them.
    pub fn ensureSelectorCandidates(self: *ResourceBudget, n: usize) LimitError!void {
        const total = std.math.add(usize, self.selector_candidates, n) catch return self.fail(error.SelectorExpansionLimit);
        if (total > self.limits.max_selector_candidates) return self.fail(error.SelectorExpansionLimit);
    }

    pub fn chargeIrNodes(self: *ResourceBudget, n: usize) LimitError!void {
        const total = std.math.add(usize, self.ir_nodes, n) catch return self.fail(error.IrNodeLimit);
        if (total > self.limits.max_ir_nodes) return self.fail(error.IrNodeLimit);
        self.ir_nodes = total;
    }

    pub fn chargeOutputBytes(self: *ResourceBudget, n: usize) LimitError!void {
        const total = std.math.add(usize, self.output_bytes, n) catch return self.fail(error.OutputSizeLimit);
        if (total > self.limits.max_output_bytes) return self.fail(error.OutputSizeLimit);
        self.output_bytes = total;
    }
};

/// Forwards bytes to `child` and fails with `error.WriteFailed` once the
/// budget's output limit would be exceeded; `limit_hit` tells the caller
/// that the failure came from the limit rather than from `child`.
pub const LimitedWriter = struct {
    budget: *ResourceBudget,
    child: *std.Io.Writer,
    limit_hit: bool = false,
    interface: std.Io.Writer,

    pub fn init(budget: *ResourceBudget, child: *std.Io.Writer, buffer: []u8) LimitedWriter {
        return .{
            .budget = budget,
            .child = child,
            .interface = .{
                .vtable = &.{ .drain = drain, .flush = flush },
                .buffer = buffer,
            },
        };
    }

    fn forward(self: *LimitedWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        self.budget.chargeOutputBytes(bytes.len) catch {
            self.limit_hit = true;
            return error.WriteFailed;
        };
        try self.child.writeAll(bytes);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.forward(w.buffered());
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.forward(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.forward(pattern);
            written += pattern.len;
        }
        return written;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *LimitedWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.forward(w.buffered());
        w.end = 0;
        try self.child.flush();
    }

    /// Map a write failure to the limit error when the limit caused it.
    pub fn mapError(self: *const LimitedWriter, err: anyerror) anyerror {
        if (self.limit_hit) return error.OutputSizeLimit;
        return err;
    }
};

test "vm steps stop exactly at the limit" {
    var b = ResourceBudget.init(.{ .max_vm_steps = 2500 }, null, null);
    var n: u64 = 0;
    while (true) {
        b.chargeVmStep() catch |err| {
            try std.testing.expectEqual(error.ExecutionLimit, err);
            break;
        };
        n += 1;
    }
    try std.testing.expectEqual(@as(u64, 2500), n);
    try std.testing.expectEqual(@as(u64, 2500), b.vmStepsUsed());
}

test "vm steps with a zero limit fail on the first instruction" {
    var b = ResourceBudget.init(.{ .max_vm_steps = 0 }, null, null);
    try std.testing.expectError(error.ExecutionLimit, b.chargeVmStep());
}

test "unlimited vm steps do not overflow the counter" {
    var b = ResourceBudget.init(CompileLimits.unlimited(), null, null);
    for (0..5000) |_| try b.chargeVmStep();
    try std.testing.expectEqual(@as(u64, 5000), b.vmStepsUsed());
}

test "cancellation is polled between fuel slices" {
    const Ctx = struct {
        calls: usize = 0,
        cancel_after: usize,
        fn check(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return self.calls > self.cancel_after;
        }
    };
    var ctx: Ctx = .{ .cancel_after = 2 };
    var b = ResourceBudget.init(.{}, Ctx.check, &ctx);
    var n: u64 = 0;
    while (true) {
        b.chargeVmStep() catch |err| {
            try std.testing.expectEqual(error.CompilationCancelled, err);
            break;
        };
        n += 1;
    }
    try std.testing.expectEqual(@as(u64, 3 * cancellation_interval), n);
}

test "counters reject the charge that crosses the limit" {
    var b = ResourceBudget.init(.{ .max_selector_candidates = 10, .max_ir_nodes = 3, .max_output_bytes = 4 }, null, null);
    try b.chargeSelectorCandidates(10);
    try std.testing.expectError(error.SelectorExpansionLimit, b.chargeSelectorCandidates(1));
    try std.testing.expectError(error.SelectorExpansionLimit, b.ensureSelectorCandidates(std.math.maxInt(usize)));
    try b.chargeIrNodes(3);
    try std.testing.expectError(error.IrNodeLimit, b.chargeIrNodes(1));
    try b.chargeOutputBytes(4);
    try std.testing.expectError(error.OutputSizeLimit, b.chargeOutputBytes(1));
}

test "limited writer stops at the output limit" {
    var b = ResourceBudget.init(.{ .max_output_bytes = 8 }, null, null);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var buf: [4]u8 = undefined;
    var lw = LimitedWriter.init(&b, &out.writer, &buf);
    try lw.interface.writeAll("12345678");
    try lw.interface.flush();
    try std.testing.expectEqualStrings("12345678", out.written());
    try lw.interface.writeAll("9");
    try std.testing.expectError(error.WriteFailed, lw.interface.flush());
    try std.testing.expectEqual(@as(?LimitError, error.OutputSizeLimit), b.exceeded);
    try std.testing.expect(lw.limit_hit);
    try std.testing.expectEqual(error.OutputSizeLimit, lw.mapError(error.WriteFailed));
}
