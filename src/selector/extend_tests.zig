const std = @import("std");
const selector_mod = @import("selector.zig");
const extend_mod = @import("extend.zig");
const ApplyState = extend_mod.ApplyState;

/// Extend `selector` (a rule that `snapshot` of the `@extend`s precede) with
/// `extends`, pairs of extender and target in the order they are written.
fn expectExtended(expected: []const u8, selector: []const u8, snapshot: u32, extends: []const [2][]const u8) !void {
    const allocator = std.testing.allocator;
    var store = ApplyState.init(allocator);
    defer store.deinit();
    for (extends, 0..) |pair, order| {
        var extender = try selector_mod.parse(allocator, pair[0]);
        errdefer extender.deinit();
        var target_list = try selector_mod.parse(allocator, pair[1]);
        defer target_list.deinit();
        var target = try target_list.selectors.items[0].components.items[0].compound.clone(allocator);
        errdefer target.deinit();
        try store.addExtension(.{
            .extender = extender,
            .target = target,
            .optional = false,
            .span = null,
            .eval_order = @intCast(order),
        });
    }
    var list = try selector_mod.parse(allocator, selector);
    defer list.deinit();
    var extended = try store.applySelectorExtensionsWithContext(&list, .{ .target_extend_order_snapshot = snapshot });
    defer extended.deinit();
    const css = try selector_mod.toCss(allocator, &extended);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(expected, css);
}

// Every expectation below is what the official CLI (1.108.2) prints.

test "extend: a rule after the @extends takes every combination, the first position fastest" {
    try expectExtended(".a.b, .b.x, .a.y, .x.y", ".a.b", 2, &.{ .{ ".x", ".a" }, .{ ".y", ".b" } });
    try expectExtended(".a .b, .x .b, .a .y, .x .y", ".a .b", 2, &.{ .{ ".x", ".a" }, .{ ".y", ".b" } });
}

test "extend: a rule before the @extends is extended by each as it comes" {
    try expectExtended(".a.b, .a.y, .b.x, .x.y", ".a.b", 0, &.{ .{ ".x", ".a" }, .{ ".y", ".b" } });
    try expectExtended(".a, .z, .x, .y", ".a", 0, &.{ .{ ".x, .y", ".a" }, .{ ".z", ".a" } });
}

test "extend: an extender is extended by the @extends before and after it" {
    try expectExtended(".a, .x, .y", ".a", 2, &.{ .{ ".y", ".x" }, .{ ".x", ".a" } });
    try expectExtended(".f, .d, .d.g", ".f", 0, &.{ .{ ".d", ".f" }, .{ ".d.g", ".d" } });
}

test "extend: a generated selector goes when one at least as specific as its extenders covers it" {
    try expectExtended(".a.y, .a, .x", ".a.y, .a", 1, &.{.{ ".x", ".a" }});
    try expectExtended(".x, .a, .x.y", ".x, .a", 1, &.{.{ ".x.y", ".a" }});
    try expectExtended(".a.k, .k.x.y.z, .x.k", ".a.k, .x.k", 1, &.{.{ ".x.y.z", ".a" }});
}

test "extend: an extender as written is never trimmed" {
    try expectExtended(".a, :is(.z, .y), .z", ".a", 2, &.{ .{ ":is(.z, .y)", ".a" }, .{ ".z", ".a" } });
    try expectExtended(".a, .c.b, .b.c", ".a, .b.c", 1, &.{.{ ".c.b", ".a" }});
}

test "extend: parents are woven by their combinators" {
    try expectExtended(".a > .d, .a > .i ~ .k + .x", ".a > .d", 1, &.{.{ ".i ~ .k + .x", ".d" }});
    try expectExtended(".a ~ .d, .a ~ .k ~ .x, .k ~ .a ~ .x, .a.k ~ .x", ".a ~ .d", 1, &.{.{ ".k ~ .x", ".d" }});
    try expectExtended(".a .b .d, .a .j .b .x, .j .a .b .x", ".a .b .d", 1, &.{.{ ".j .b .x", ".d" }});
    try expectExtended("#i.a .d, #i.k.a .x", "#i.a .d", 1, &.{.{ "#i.k .x", ".d" }});
}

test "extend: the simple selectors of an extender go where the specification puts them" {
    try expectExtended(".a:hover.t.z, .a.q.r:hover.z:focus::after", ".a:hover.t.z", 1, &.{.{ ".q:focus.r::after", ".t" }});
    try expectExtended(".a.t, b.a", ".a.t", 1, &.{.{ "b", ".t" }});
}

test "extend: a pseudo-class argument is extended in place" {
    try expectExtended(":not(.a):not(.b)", ":not(.a)", 1, &.{.{ ".b", ".a" }});
    try expectExtended(":is(.a, .b)", ":is(.a)", 1, &.{.{ ".b", ".a" }});
}
