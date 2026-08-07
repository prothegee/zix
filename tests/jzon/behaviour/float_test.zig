//! Behaviour tests: zix.jzon.float, the JSON number form of a float.
//! Verifies the rendered form against std.json.Stringify, that a narrow float
//! comes out as the f64 nearest it, and that the result parses back as a number.

const std = @import("std");
const zix = @import("zix");

const Sink = zix.jzon.Sink;
const float = zix.jzon.float;

/// The same value through std.json.Stringify, which jzon's output must match.
fn stdRendered(buf: []u8, value: anytype) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(value, .{}, &writer) catch unreachable;

    return writer.buffered();
}

/// Values a record realistically carries: money, ratios, measurements.
const SAMPLES = [_]f64{
    0.0,
    1.0,
    -1.0,
    0.5,
    2.5,
    -12.75,
    0.1,
    99.99,
    12345.6789,
    -0.000125,
    1e10,
    1e-10,
};

test "zix behaviour: float renders every sample the way std.json.Stringify does" {
    for (SAMPLES) |sample| {
        var ours: [512]u8 = undefined;
        var sink: Sink = .init(&ours);
        try float.append(&sink, sample);

        var theirs: [512]u8 = undefined;
        try std.testing.expectEqualStrings(stdRendered(&theirs, sample), sink.filled());
    }
}

test "zix behaviour: float renders values that read back as themselves" {
    for (SAMPLES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try float.append(&sink, sample);

        try std.testing.expectEqual(sample, try std.fmt.parseFloat(f64, sink.filled()));
    }
}

test "zix behaviour: float renders a narrow width as the f64 nearest it" {
    var buf: [512]u8 = undefined;

    var half: Sink = .init(&buf);
    try float.append(&half, @as(f16, 1.5));
    try std.testing.expectEqualStrings("1.5", half.filled());

    var single: Sink = .init(&buf);
    try float.append(&single, @as(f32, 1.5));
    try std.testing.expectEqualStrings("1.5", single.filled());

    // 0.1 has no exact f32, so the f64 it widens to is what gets written, which
    // is what std writes for the same value.
    var inexact: Sink = .init(&buf);
    try float.append(&inexact, @as(f32, 0.1));
    try std.testing.expectEqualStrings("0.10000000149011612", inexact.filled());
}

test "zix behaviour: float renders a whole number without a fraction" {
    var buf: [64]u8 = undefined;

    var whole: Sink = .init(&buf);
    try float.append(&whole, @as(f64, 42.0));
    try std.testing.expectEqualStrings("42", whole.filled());

    var negative: Sink = .init(&buf);
    try float.append(&negative, @as(f64, -42.0));
    try std.testing.expectEqualStrings("-42", negative.filled());
}

test "zix behaviour: float writes after what the sink already holds" {
    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.literal("{\"ratio\":");
    try float.append(&sink, @as(f64, 2.5));
    try sink.byte('}');

    try std.testing.expectEqualStrings("{\"ratio\":2.5}", sink.filled());
}

test "zix behaviour: float output parses back through std.json as a number" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    for (SAMPLES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try float.append(&sink, sample);

        const parsed = try std.json.parseFromSliceLeaky(
            f64,
            arena.allocator(),
            sink.filled(),
            .{},
        );

        try std.testing.expectEqual(sample, parsed);
    }
}
