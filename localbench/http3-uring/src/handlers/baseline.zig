//! GET /baseline2?a=..&b=.. : sum the query values. Answers the sum as
//! text/plain.
//!
//! Note:
//! - This engine's Request carries the query inside path, so the split happens
//!   here rather than being handed over already done.
//! - Query only, unlike the h1 and h2 baseline handlers which also add a POST
//!   body. The HTTP/3 dispatch path builds its Request from the method, path,
//!   and accept-encoding, and never fills body, so a request body cannot reach
//!   a handler on this engine yet. The baseline-h3 profile drives GET, so the
//!   profile is covered either way.

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

// --------------------------------------------------------- //

pub fn RESPONSE(req: *const zix.Http3.Request, res: *zix.Http3.Response, _: *zix.Http3.Context) !void {
    const query = if (std.mem.indexOfScalar(u8, req.path, '?')) |mark| req.path[mark + 1 ..] else "";

    const sum = sumQuery(query);

    // The engine copies the body out after this returns, so per-worker storage
    // outlives the call by enough.
    const out = std.fmt.bufPrint(&tl_body, "{d}", .{sum}) catch return;

    res.content_type = "text/plain";
    res.send(out);
}
