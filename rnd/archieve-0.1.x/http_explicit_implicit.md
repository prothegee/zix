# HTTP: Explicit > Implicit (was: zix-gmod-1)

> **Superseded.** Renamed from `rnd/zix-gmod-1.md`. Content has been redistributed:
> - Resolved decisions -> [`docs/adr.md`](../docs/adr.md) (ADR-011, ADR-012)
> - Specification and open proposals -> [`rnd/http_specification.md`](http_specification.md)
>
> This file is kept for historical reference only.

---

This document outlines a path to move `zix` away from "framework magic" toward explicit configuration, without losing the "network backend library" ease of use.

---

## 1. Explicit Static Serving
### Current (Implicit)
Static serving is hardcoded as a fallback in `server.zig`. If a request doesn't match a route, the server "magically" checks the file system.
```zig
// config.zig
public_dir: []const u8 = "./public", // Magic starts here
```

### Proposed (Explicit)
Remove `public_dir` from `HttpServerConfig`. Instead, provide a `Static` module that the user registers like any other route.
```zig
// main.zig
// The user explicitly chooses WHERE and HOW static files are served.
server.registerPrefix("/", zix.Static.handler("./public"));
```
**Benefit:** No "hidden" logic. The user can see that the root path maps to the static server.

---

## 2. Top-Down Routing (Order is Truth)
### Current (Implicit)
The router uses a 3-pass priority system (Exact -> Param -> Prefix). This is "magic" because the order you register routes doesn't matter, the library decides who wins.

### Proposed (Explicit)
Change the router to **First-Match-Wins** (Top-Down).
```zig
// main.zig
server.registerHandler("/api/v2/user", v2Handler); // Matches first
server.registerPrefix("/api", v1Handler);          // Matches if above didn't
```
**Benefit:** Matches the behavior of Zig's `switch` statement. Priority is determined by the developer's registration order, making it 100% predictable.

---

## 3. The "Request-Scoped" Allocator
### Current (Implicit)
`ctx.allocator` is just an allocator. The fact that it is reset after every request is "hidden" in the documentation.

### Proposed (Explicit)
Rename the allocator field in `Context` to reflect its lifetime.
```zig
// Handler usage
pub fn myHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    // OLD: ctx.allocator
    // NEW:
    const data = try ctx.request_arena.alloc(u8, 100); 
}
```
**Benefit:** The name `request_arena` (or `temp`) explicitly warns the developer: "Do not expect this memory to live longer than this request."

---

## 4. Middleware-Driven Plumbing
### Current (Implicit)
The server handles things like timeouts and basic logging internally.

### Proposed (Explicit)
Move cross-cutting concerns into a "Default Middleware Pipeline."
```zig
// main.zig
const app = server.compose(.{
    zix.Middleware.Logger,
    zix.Middleware.Timeout(5000),
});

server.registerHandler("/", app(homeHandler));
```
**Benefit:** The "assembly" is visible. If the user wants to remove the logger or change the timeout, they do it in their own code, not in a hidden config file.

---

## Summary of the "zix-gmod-1" Look
Following these changes, a `main.zig` would look like this:

```zig
pub fn main() !void {
    var server = try zix.HttpServer.init(.{ .port = 9000 });

    // 1. Explicit static serving
    server.registerPrefix("/static", zix.Static.handler("./public"));

    // 2. Explicit order-based routing
    server.registerHandler("/about", aboutHandler);
    server.registerPrefix("/", homeHandler);

    try server.run();
}
```
**Verdict:** This is slightly more "assembly," but it is **zero magic**. Every line of code explains exactly what the server will do.
