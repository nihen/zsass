//! zsass entry point (module root).
//! Placed in `src/` so `@import("intern_pool.zig")` etc. resolves normally.

const std = @import("std");
const driver = @import("runtime/driver.zig");

comptime {
    _ = @import("runtime/vm_meta.zig");
}

/// CLI binary entry point. Delegates to `runtime/driver.zig::main`.
pub fn main(init: std.process.Init) !void {
    try driver.main(init);
}

/// In-process embedding API (memory-only compile entry points).
/// Use `api.compileSourceToCss` / `api.compileSourceToCssWithSourceMap`.
pub const api = @import("api.zig");

test {
    _ = driver;
    _ = @import("ir/rule_ir.zig");
    _ = @import("runtime/observe.zig");
    _ = @import("runtime/perf.zig");
    _ = @import("resolve/resolver.zig");
    _ = @import("ir/compiler.zig");
    _ = @import("runtime/vm.zig");
    _ = @import("builtin/mod.zig");
    _ = @import("api.zig");
    _ = @import("ir/source_map.zig");
    _ = @import("runtime/value_format.zig");
    _ = @import("selector/extend_tests.zig");
}
