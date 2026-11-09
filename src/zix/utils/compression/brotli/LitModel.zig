//! ZIX utils compression brotli LitModel
//!
//! ### file: src/zix/utils/compression/brotli/LitModel.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Literal coding plan of one meta-block: one flat tree, or UTF8 context trees
//! picked per literal through a context map (RFC 7932 sec 7.1).
//! 
//! ### note:
//! 
//! Meant for an arena. The trees are not freed one by one.
//! 
//! ---------------------------------------------------------
//! 
//! ### licenses:
//! 
//! - BSD-3-Clause
//! 
//! ### copyright:
//! 
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const Command = @import("Command.zig");
const TreeCode = @import("TreeCode.zig");
const context = @import("context.zig");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Fields:

/// True when the plan uses context trees.
contexts: bool,
/// Context mode, written into the stream.
mode: context.ContextMode = .LSB6,
/// Number of literal trees.
ntrees: u32 = 1,
/// Tree index per literal context.
cmap: [context.LITERAL_CONTEXTS]u8 = @splat(0),
/// Context trees, used when contexts is true.
trees: []TreeCode = &.{},
/// The single tree, used when contexts is false.
flat: TreeCode = undefined,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// A context needs this many literals before it earns its own tree.
const CONTEXT_THRESHOLD: u32 = 256;

const Histogram = [tables.LITERAL_ALPHABET]u32;

const Inner = Error || std.mem.Allocator.Error || huffman.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliLitModel_OutOfMemory => Error.ZixUtils_BrotliLitModel_OutOfMemory,
        error.OutOfMemory => Error.ZixUtils_BrotliLitModel_OutOfMemory,
        error.ZixUtils_BrotliHuffman_OutOfMemory => Error.ZixUtils_BrotliLitModel_OutOfMemory,
    };
}

/// Context of the literal at input position index, from the two bytes before it.
fn contextAt(mode: context.ContextMode, input: []const u8, index: usize) u8 {
    const last_byte: u8 = if (index >= 1) input[index - 1] else 0;
    const prior_byte: u8 = if (index >= 2) input[index - 2] else 0;

    return context.literalContextId(mode, last_byte, prior_byte);
}

fn buildFlat(scratch: std.mem.Allocator, input: []const u8, commands: []const Command) Inner!Self {
    var freq: Histogram = @splat(0);
    for (commands) |command| {
        for (input[command.lit_off .. command.lit_off + command.insert_len]) |byte| {
            freq[byte] += 1;
        }
    }

    return .{
        .contexts = false,
        .flat = try huffman.buildOptimalTree(scratch, &freq),
    };
}

fn buildInner(
    scratch: std.mem.Allocator,
    input: []const u8,
    commands: []const Command,
    use_contexts: bool,
) Inner!Self {
    if (!use_contexts) return buildFlat(scratch, input, commands);

    const mode: context.ContextMode = .UTF8;

    const context_freq = try scratch.alloc(Histogram, context.LITERAL_CONTEXTS);
    for (context_freq) |*row| row.* = @splat(0);
    var context_count: [context.LITERAL_CONTEXTS]u32 = @splat(0);

    for (commands) |command| {
        for (command.lit_off..command.lit_off + command.insert_len) |index| {
            const context_id = contextAt(mode, input, index);

            context_freq[context_id][input[index]] += 1;
            context_count[context_id] += 1;
        }
    }

    // A busy context gets its own tree. The rest fold into tree 0.
    const tree_freq = try scratch.alloc(Histogram, context.LITERAL_CONTEXTS);
    for (tree_freq) |*row| row.* = @splat(0);
    var cmap: [context.LITERAL_CONTEXTS]u8 = @splat(0);
    var ntrees: u32 = 1;
    for (0..context.LITERAL_CONTEXTS) |context_id| {
        if (context_count[context_id] >= CONTEXT_THRESHOLD) {
            cmap[context_id] = @intCast(ntrees);
            tree_freq[ntrees] = context_freq[context_id];
            ntrees += 1;
        } else {
            for (0..tables.LITERAL_ALPHABET) |byte| {
                tree_freq[0][byte] += context_freq[context_id][byte];
            }
        }
    }

    if (ntrees == 1) {
        return .{
            .contexts = false,
            .flat = try huffman.buildOptimalTree(scratch, &tree_freq[0]),
        };
    }

    const trees = try scratch.alloc(TreeCode, ntrees);
    for (trees, 0..) |*tree, tree_index| {
        tree.* = try huffman.buildOptimalTree(scratch, &tree_freq[tree_index]);
    }

    return .{
        .contexts = true,
        .mode = mode,
        .ntrees = ntrees,
        .cmap = cmap,
        .trees = trees,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliLitModel_OutOfMemory,
};

/// Build the literal plan from the commands.
///
/// Param:
/// scratch - std.mem.Allocator (arena, owns the trees)
/// input - []const u8 (encoder input)
/// commands - []const Command (parsed commands)
/// use_contexts - bool (try per-context trees)
///
/// Return:
/// - Self
/// - Error.ZixUtils_BrotliLitModel_OutOfMemory
pub fn build(
    scratch: std.mem.Allocator,
    input: []const u8,
    commands: []const Command,
    use_contexts: bool,
) Error!Self {
    return buildInner(scratch, input, commands, use_contexts) catch |err| innerError(err);
}

/// The tree for the literal at input position index. The decoder derives the same
/// context from its last two output bytes, which equal the input prefix.
///
/// Param:
/// input - []const u8 (encoder input)
/// index - usize (literal position)
///
/// Return:
/// - *const TreeCode
pub fn treeFor(self: *const Self, input: []const u8, index: usize) *const TreeCode {
    if (!self.contexts) return &self.flat;

    return &self.trees[self.cmap[contextAt(self.mode, input, index)]];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: LitModel, without contexts is flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = "abcabc";
    const commands = [_]Command{Command.insertOnly(0, input.len)};
    const model = try build(arena.allocator(), input, &commands, false);

    try std.testing.expect(!model.contexts);
    try std.testing.expectEqual(&model.flat, model.treeFor(input, 3));
}

test "zix utils compression brotli: LitModel, sparse contexts fall back to flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = "short text";
    const commands = [_]Command{Command.insertOnly(0, input.len)};
    const model = try build(arena.allocator(), input, &commands, true);

    try std.testing.expect(!model.contexts);
}

test "zix utils compression brotli: LitModel, busy contexts get their own trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input: [4096]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'a' else ' ';
    const commands = [_]Command{Command.insertOnly(0, input.len)};
    const model = try build(arena.allocator(), &input, &commands, true);

    try std.testing.expect(model.contexts);
    try std.testing.expect(model.ntrees >= 2);
    try std.testing.expectEqual(@as(usize, model.ntrees), model.trees.len);
}

test "zix utils compression brotli: LitModel, failing allocator is out of memory" {
    const input = "abc";
    const commands = [_]Command{Command.insertOnly(0, input.len)};

    try std.testing.expectError(
        Error.ZixUtils_BrotliLitModel_OutOfMemory,
        build(std.testing.failing_allocator, input, &commands, false),
    );
}

