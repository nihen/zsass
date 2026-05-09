//! sass:meta builtin metadata.
//!
//! Runtime-backed sass:meta implementations live in `runtime/vm_meta.zig` so
//! this builtin-layer file does not import VM, compiler, or resolver internals.

const meta_dispatch_abi = @import("meta_dispatch_abi.zig");

pub const meta_builtin_specs = meta_dispatch_abi.meta_builtin_specs;
pub const DispatchKind = meta_dispatch_abi.DispatchKind;
pub const meta_apply_mixin_id = meta_dispatch_abi.meta_apply_mixin_id;
pub const meta_load_css_mixin_id = meta_dispatch_abi.meta_load_css_mixin_id;
pub const meta_get_function_id = meta_dispatch_abi.meta_get_function_id;
pub const meta_get_mixin_id = meta_dispatch_abi.meta_get_mixin_id;
