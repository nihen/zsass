const error_format = @import("../runtime/error_format.zig");
const data_mod = @import("data.zig");

const Span = data_mod.Span;

/// Update the current resolver error-stack frame to the statement span that triggered
/// loading another module. This is used by @use/@forward so imported-module errors
/// point back to the directive location in the caller.
pub fn setCurrentFrameSpan(span: Span) void {
    if (error_format.error_state.error_stack_len == 0) return;
    var frame = &error_format.error_state.error_stack[error_format.error_state.error_stack_len - 1];
    frame.span_start = span.start;
    frame.span_end = span.end;
    frame.has_span = true;
}
