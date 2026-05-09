//! Shared helpers for sass:meta compile-time and runtime paths.
const shared = @import("shared.zig");
const resolver = @import("../resolve/resolver.zig");

const InternPool = shared.InternPool;
const InternId = shared.InternId;

/// Finds the positional index (0-based within `0..argc`) of the meta control argument
/// (`$function`, `$mixin`, `$control`, etc.) for forwarded meta calls.
///
/// `arg_names` may be shorter than `argc`; missing entries are treated as anonymous.
pub fn findMetaControlArgOffset(
    pool: *InternPool,
    arg_names: []const InternId,
    argc: usize,
    control_name: []const u8,
) ?usize {
    var control_index: ?usize = null;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none and name_id != resolver.call_arg_splat_sentinel) {
            var raw = pool.get(name_id);
            if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
            if (shared.identifierEq(raw, control_name) and control_index == null) {
                control_index = i;
            }
            continue;
        }
        if (control_index == null) control_index = i;
    }
    return control_index;
}
