# Tests — zix

---

## Running Tests

```sh
# via build system (silent on success — no output means all passed)
zig build test

# direct — always prints each test name and result
zig test src/zix.zig
```

`zig build` alone does **not** run tests — the `test` step is a separate named step and is not wired into the default install step.

---

## Unit Tests

Defined in `src/zix.zig`. Each module is exercised via `std.testing.refAllDecls`, which verifies that every public declaration compiles and that any inline `test` blocks within the module pass.

| Module | Coverage |
| :- | :- |
| `tcp/http/method.zig` | `refAllDecls` |
| `tcp/http/status.zig` | `refAllDecls` |
| `tcp/http/content.zig` | `refAllDecls` |
| `tcp/http/request.zig` | `refAllDecls` |
| `tcp/http/response.zig` | `refAllDecls` |
| `tcp/http/router.zig` | `refAllDecls` + behavioral tests (matchParam, registration) |
| `tcp/http/static.zig` | `refAllDecls` + behavioral tests (mimeType, parseRangeHeader) |
| `tcp/http/upload.zig` | `refAllDecls` + behavioral test (MultipartParser parse + getField) |
| `tcp/http/websocket.zig` | `refAllDecls` + behavioral tests (acceptKey, frame, masked frame) |
| `utils/file.zig` | `refAllDecls` + behavioral tests (extension, saveFile) |

---

## Integration Tests

Not yet implemented.

---

###### end of tests
