//! GET/POST /baseline2?a=..&b=.. : sum the query values, plus the POST body
//! read as an integer. Answers the sum as text/plain.
//!
//! Note:
//! - This engine's Request carries the query inside path, so the split happens
//!   here rather than being handed over already done.
//! - A body the engine only received part of is refused with 413 rather than
//!   summed. Over QUIC a request can span packets, and a fragment parsed as a
//!   whole body answers a wrong number with a 200 on it.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/baseline2";

/// Longest decimal the sum can print, sign included.
const SUM_BUF: usize = 32;

// --------------------------------------------------------- //

threadlocal var tl_body: [SUM_BUF]u8 = undefined;

// --------------------------------------------------------- //

fn sumQuery(query: []const u8) i64 {
    var sum: i64 = 0;

    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |equals| {
            sum += std.fmt.parseInt(i64, pair[equals + 1 ..], 10) catch 0;
        }
    }

    return sum;
}

/// Read a leading integer out of `text`, skipping surrounding whitespace and
/// stopping at the first non-digit. A body with no digits reads as 0.
fn parseIntLoose(text: []const u8) i64 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n')) index += 1;

    var negative = false;
    if (index < text.len and text[index] == '-') {
        negative = true;
        index += 1;
    }

    var value: i64 = 0;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {
        value = value * 10 + (text[index] - '0');
    }

    return if (negative) -value else value;
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *const zix.Http3.Request, res: *zix.Http3.Response, _: *zix.Http3.Context) !void {
    if (!req.bodyComplete()) {
        res.setStatus(413);
        res.content_type = "text/plain";
        res.send("request body incomplete");

        return;
    }

    const query = if (std.mem.indexOfScalar(u8, req.path, '?')) |mark| req.path[mark + 1 ..] else "";

    var sum = sumQuery(query);
    if (req.body.len > 0) sum += parseIntLoose(req.body);

    // The engine copies the body out after this returns, so per-worker storage
    // outlives the call by enough.
    const out = std.fmt.bufPrint(&tl_body, "{d}", .{sum}) catch return;

    res.content_type = "text/plain";
    res.send(out);
}
