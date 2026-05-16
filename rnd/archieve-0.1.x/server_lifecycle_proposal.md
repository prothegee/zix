# Server Lifecycle & Signal Control (was: zix-gmod-2)

This document addresses the risks of infinite `while (true)` loops in the core network stack and proposes a controlled lifecycle model for the `zix`.

---

## 1. The Problem: Infinite Loops
Currently, `zix` utilizes `while (true)` in three critical areas:
*   **Accept Loop**: Impossible to stop without killing the process.
*   **Keep-Alive Loop**: Vulnerable to "zombie" connections that never time out.
*   **WebSocket Frame Loop**: Can be trapped in high-CPU spin cycles by malformed peers.

In a production environment, this leads to **resource leaks** and **unreliable restarts**.

---

## 2. Proposed Solution: The Atomic State Machine

Every server component should transition through a formal lifecycle.

### Server States
1.  **IDLE**: Initialized but not listening.
2.  **RUNNING**: Actively accepting/processing data.
3.  **STOPPING**: No longer accepting new work, finishing active tasks (Graceful).
4.  **STOPPED**: All resources released then loops exited.

### Atomic Flag Implementation
Replace `while (true)` with a check against an atomic `status`:

```zig
const ServerStatus = enum(u8) { idle, running, stopping, stopped };
status: std.atomic.Value(ServerStatus) = .init(.idle),

// In the loop
while (self.status.load(.acquire) == .running) {
    // ...
}
```

---

## 3. Graceful vs. Forced Shutdown

### Graceful Shutdown (The "Soft" Stop)
*   **Action**: Set status to `.stopping`.
*   **Behavior**: The **Accept Loop** exits immediately (no new connections). The **Keep-Alive Loops** finish their current HTTP request, set `Connection: close`, and then exit.
*   **Result**: Zero dropped requests for active users.

### Forced Shutdown (The "Hard" Stop)
*   **Action**: Set status to `.stopped` and close the underlying socket.
*   **Behavior**: All loops break immediately due to socket errors or status checks.
*   **Result**: Instant termination.Aactive connections are dropped.

---

## 4. Timeout Guards
To prevent the library from hanging during a shutdown, every loop must have a "Heartbeat" or "Read Timeout".

*   **Logic**: If no data is received within `config.response_timeout_ms`, the loop must check the `status` flag again.
*   **Library Duty**: `zix` must provide a consistent way to handle these "Interrupted" states so the user doesn't have to write the boilerplate.

---

## 5. Benefits for the Library
1.  **Unit Testable**: We can start a server in a test, send one packet, and call `server.stop()`.
2.  **Cloud-Native**: Properly handles `SIGTERM` from Docker/Kubernetes.
3.  **Reliability**: Prevents the "Leaky Thread" problem where threads stay alive after the main process thinks they are gone.
