## Design Considerations

Not active tasks: reminders for future decisions.

**AoS (Array of Structures):** remaining sites (`extra_buf`, `fields`, `conns`, ...). When any becomes a throughput bottleneck, a SoA layout is a candidate. `routes` was converted to `MultiArrayList` (SoA) so dispatch passes scan only the hot field slice.

**OoP (Object-oriented Patterns):** most structs (`Request`, `Response`, `Router`, `Context`, `ConnQueue`, `MultipartParser`, ...) follow this shape. Idiomatic in Zig and fine as the baseline.

**DoD (Data-Oriented Design):** the direction to move when data layout matters more than encapsulation. For the HTTP layer specifically, the idea is a dedicated *http engine*: a lower-level, data-oriented core sitting below `server.zig`. Not started. Revisit when the current baseline hits a real ceiling.
