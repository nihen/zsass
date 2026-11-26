//! Native stack guard for recursion whose depth the parser cannot bound,
//! such as walking values or selectors built at run time.
//!
//! The state is per thread because the stack it measures is per thread. A
//! compile entry point opens a `Scope`; recursive functions call `check()`,
//! which fails once the frame address moves more than `stack_bytes` below
//! the address recorded when the outermost scope opened. A nested scope (for
//! example a child VM on the same thread) never loosens the bound.
//!
//! `check()` returns `error.OutOfMemory`, which every recursive caller
//! already propagates, and marks the thread as tripped. The entry point
//! that opened the scope reports `error.NestingLimit` when `tripped()` is
//! set, whatever error or result reached it.

const std = @import("std");
const builtin = @import("builtin");

threadlocal var floor: usize = 0;
threadlocal var tripped_flag: bool = false;

pub const Scope = struct {
    prev_floor: usize,
    prev_tripped: bool,

    pub fn end(self: Scope) void {
        floor = self.prev_floor;
        tripped_flag = self.prev_tripped;
    }
};

/// Start guarding recursion below the caller's frame. Pair with `end`.
pub fn begin(stack_bytes: usize) Scope {
    const scope: Scope = .{ .prev_floor = floor, .prev_tripped = tripped_flag };
    const here = @frameAddress();
    const candidate = here -| stack_bytes;
    // The stack grows down on every supported target; keep the higher floor.
    if (floor == 0 or candidate > floor) floor = candidate;
    if (floor == 0) floor = 1;
    if (scope.prev_floor == 0) tripped_flag = false;
    return scope;
}

pub inline fn check() error{OutOfMemory}!void {
    if (@frameAddress() < floor) {
        @branchHint(.cold);
        tripped_flag = true;
        return error.OutOfMemory;
    }
}

/// `check()` for recursion that cannot return an error: true when the
/// caller must stop descending and return a fallback. The entry point still
/// fails the compilation, so the fallback never reaches the output.
pub inline fn overflowed() bool {
    if (@frameAddress() < floor) {
        @branchHint(.cold);
        tripped_flag = true;
        return true;
    }
    return false;
}

/// True when a `check()` failed since the outermost scope opened.
pub fn tripped() bool {
    return tripped_flag;
}

/// Replace `err` with the nesting error when the guard tripped.
pub fn mapError(err: anyerror) anyerror {
    if (tripped_flag) return error.NestingLimit;
    return err;
}

comptime {
    switch (builtin.cpu.arch) {
        .x86_64, .x86, .aarch64, .aarch64_be, .arm, .thumb, .riscv64, .riscv32, .wasm32, .wasm64 => {},
        else => @compileError("stack_guard assumes a downward-growing stack"),
    }
}

test "check fails below the floor and marks the thread" {
    const scope = begin(64 * 1024);
    defer scope.end();
    try check();
    try std.testing.expect(!tripped());
    const Recurse = struct {
        fn down(n: usize) error{OutOfMemory}!usize {
            try check();
            var pad: [256]u8 = undefined;
            pad[n % pad.len] = @truncate(n);
            const r = try down(n + 1);
            return r + pad[n % pad.len];
        }
    };
    try std.testing.expectError(error.OutOfMemory, Recurse.down(0));
    try std.testing.expect(tripped());
    try std.testing.expectEqual(error.NestingLimit, mapError(error.OutOfMemory));
}

test "a nested scope keeps the outer floor" {
    const outer = begin(64 * 1024);
    const outer_floor = floor;
    const inner = begin(1024 * 1024);
    try std.testing.expectEqual(outer_floor, floor);
    inner.end();
    outer.end();
    try std.testing.expectEqual(@as(usize, 0), floor);
}
