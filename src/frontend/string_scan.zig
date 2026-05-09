const std = @import("std");

/// Handles escapes inside quotes, closing quotes, and opening quotes. Returns true if consumed.
pub fn consumeStringQuoting(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
    i: *usize,
    in_string: *u8,
) !bool {
    const c = text[i.*];
    if (in_string.* != 0) {
        if (c == '\\' and i.* + 1 < text.len) {
            try buf.append(allocator, c);
            i.* += 1;
            try buf.append(allocator, text[i.*]);
            i.* += 1;
            return true;
        }
        if (c == in_string.*) in_string.* = 0;
        try buf.append(allocator, c);
        i.* += 1;
        return true;
    }
    if (c == '"' or c == '\'') {
        in_string.* = c;
        try buf.append(allocator, c);
        i.* += 1;
        return true;
    }
    return false;
}
