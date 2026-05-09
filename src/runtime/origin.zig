const std = @import("std");

pub const OriginId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn isValid(self: OriginId) bool {
        return self != .invalid;
    }
};

pub const CssOriginKind = enum {
    root,
    module,
    import_stylesheet,
};

pub const CssOrigin = struct {
    kind: CssOriginKind,
    source_path: []const u8,
    module_id: u32,
    parent_import_origin: OriginId = .invalid,
    preamble_comment_ids: []const u32 = &.{},
};
