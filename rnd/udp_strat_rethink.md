# Strategic Rethink: UDP Architecture

> **Superseded.** Concerns addressed in [`rnd/udp_specification.md`](udp_specification.md):
> - Zombie risk -> `poll_timeout_ms` + `disconnect_timeout_ms` config fields
> - Timeout strategy -> `receiveTimeout` in receive loop (implemented)
> - Worker pool -> `io.concurrent(processPacket)` per packet (implemented)
>
> This file is kept for historical reference only.

---

UDP is connectionless, which creates unique problems for the "infinite loop" pattern found in TCP. This document outlines the transition to a safer UDP model for `zix`.

---

## 1. The "Zombie" Risk in UDP
In TCP, if a client disconnects, the kernel sends a `FIN` or `RST` packet. The `accept()` or `read()` call returns 0 or an error, and the loop naturally breaks.

**In UDP, there is no such signal.**
If you have a `while (true)` loop calling `socket.receive()`, and no packets arrive, the thread is blocked forever. During a server shutdown, this thread becomes a "Zombie"—it won't exit because it's waiting for a packet that may never come.

---

## 2. Solution: Windowed Polling vs. Timeouts

To maintain the "Explicit over Implicit" philosophy, `zix` UDP should implement one of two strategies:

### A. The Timeout Strategy (Explicit)
Every `receive()` call must have a mandatory timeout (e.g., 500ms).
*   **Logic**: If no packet arrives within 500ms, the call returns `error.WouldBlock`.
*   **Lifecycle Integration**: The loop catches `error.WouldBlock`, checks if `server.is_running` is still true, and if so, starts the next `receive()` call.
*   **Benefit**: Guaranteed exit during shutdown within the timeout window.

### B. The "Drip-Feed" Buffer (Framework Level)
Instead of the user calling `receive()` directly, the framework manages a background task that pumps packets into a queue.
*   **Logic**: The `while` loop belongs to `zix`, not the user.
*   **User API**: `server.onPacket(myHandler)`.
*   **Benefit**: `zix` can perfectly manage the cleanup of the background thread, while the user only writes the logic for a single packet.

---

## 3. Flow Control & Backpressure
Unlike TCP, UDP has no built-in flow control. If the `while (true)` loop is too slow, the kernel buffer will overflow and packets will be dropped silently.

**Proposed rethink for `zix`:**
Implement a **Worker Pool** for UDP processing.
1.  **One Fast Loop**: A high-priority thread that does nothing but `receive()` and put packets into a ring-buffer.
2.  **N Worker Threads**: Pull from the ring-buffer and run the `HandlerFn`.
3.  **Result**: Lowers the chance of packet loss during high-intensity bursts.

---

## 4. Implementation Guidelines
*   **Never** use `while (true)` in UDP without a `std.atomic` check.
*   **Always** set `SO_RCVTIMEO` on the UDP socket so the loop can "breathe" and check its exit status.
*   **Explicitly** document that `ctx.allocator` in a UDP handler is for a **Single Packet Lifecycle**.
