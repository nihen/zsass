const std = @import("std");
const ast_flat = @import("../frontend/ast_flat.zig");

const ExtraIndex = ast_flat.ExtraIndex;

fn readChildList(ast: *const ast_flat.Ast, extra_off: ExtraIndex) []const u32 {
    const count = ast.getExtraU32(extra_off);
    const ptr = ast.extra.items.ptr + extra_off + 1;
    return ptr[0..count];
}

pub fn hasBareImportedTopLevelDeclaration(ast: *const ast_flat.Ast, stmts: []const u32) bool {
    for (stmts) |u| {
        const node = ast.getNode(@enumFromInt(u));
        switch (node.tag) {
            .stmt_declaration => return true,
            .stmt_if => {
                const off: ExtraIndex = node.payload;
                const then_extra = ast.getExtraU32(off + 1);
                if (hasBareImportedTopLevelDeclaration(ast, readChildList(ast, then_extra))) return true;

                const elseif_count = ast.getExtraU32(off + 2);
                var q: ExtraIndex = off + 3;
                var i: u32 = 0;
                while (i < elseif_count) : (i += 1) {
                    _ = ast.getExtraU32(q);
                    const elseif_extra = ast.getExtraU32(q + 1);
                    if (hasBareImportedTopLevelDeclaration(ast, readChildList(ast, elseif_extra))) return true;
                    q += 2;
                }

                const else_extra = ast.getExtraU32(q);
                if (else_extra != std.math.maxInt(u32) and
                    hasBareImportedTopLevelDeclaration(ast, readChildList(ast, else_extra)))
                {
                    return true;
                }
            },
            .stmt_for => {
                const off: ExtraIndex = node.payload;
                const body_extra = ast.getExtraU32(off + 3);
                if (hasBareImportedTopLevelDeclaration(ast, readChildList(ast, body_extra))) return true;
            },
            .stmt_each => {
                const off: ExtraIndex = node.payload;
                const var_count = ast.getExtraU32(off);
                const body_extra = ast.getExtraU32(off + 2 + var_count);
                if (hasBareImportedTopLevelDeclaration(ast, readChildList(ast, body_extra))) return true;
            },
            .stmt_while => {
                const off: ExtraIndex = node.payload;
                const body_extra = ast.getExtraU32(off + 1);
                if (hasBareImportedTopLevelDeclaration(ast, readChildList(ast, body_extra))) return true;
            },
            else => {},
        }
    }
    return false;
}
