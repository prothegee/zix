# uuidz high-level design

## Scope

`uuidz` is a UUID library in pure Zig, standard library only. It generates and parses the three UUID versions that cover the common cases: v1 for legacy time-based identifiers, v4 for random identifiers, and v7 for time-ordered identifiers.

This document covers the shape of the library: the layers, the components, the three flows, and the shared substrate. The bit-level detail is in `lld-en.md`.

The design holds to one idea: every version exposes the same four calls, so a caller that swaps one version for another changes what the identifier carries and nothing else about how it is used.

<br>

## Layers

```mermaid
flowchart TB
    app[Consumer code]
    subgraph api [Public API]
        v1[v1.init / v1.initFromString]
        v4[v4.init / v4.initFromString]
        v7[v7.init / v7.initFromString]
    end
    subgraph substrate [Substrate]
        hex[hex charset]
        mutex[mutex]
        clock[clock access]
        random[secure random]
    end
    buf[Caller buffer]

    app --> api
    v1 --> mutex
    v1 --> clock
    v1 --> random
    v4 --> random
    v7 --> mutex
    v7 --> clock
    v7 --> random
    v1 --> hex
    v4 --> hex
    v7 --> hex
    api --> buf
```

- The API layer is three structs, one per version. Each owns the same four calls and the version-specific bit layout.
- The substrate owns the mechanics: the hex alphabet, the mutex that makes v1 and v7 safe under concurrency, the clock read, and the secure random fill.
- The buffer belongs to the caller. `uuidz` holds neither a buffer nor an allocator.

<br>

## Components

| Component | Responsibility |
| :- | :- |
| `lib.zig` | The public surface: exports `v1`, `v4`, `v7`, and the shared version constants |
| `hex.zig` | The one hex alphabet: `0123456789abcdef` |
| `v1.zig` | Version 1: timestamp, clock sequence, node, mutex, and epoch offset |
| `v4.zig` | Version 4: secure random fill and version/variant masking |
| `v7.zig` | Version 7: millisecond timestamp, monotonicity handling, version/variant masking |

<br>

## The generate flow

```mermaid
sequenceDiagram
    participant C as Caller
    participant V as version struct
    participant R as Secure random
    participant K as Clock

    C->>V: init(io)
    alt v1
        V->>V: lock mutex
        V->>R: randomSecure(node) (once)
        V->>R: randomSecure(clock_seq) (once)
        V->>K: now()
        V->>V: build timestamp, clock sequence, node
        V->>V: unlock mutex
    else v4
        V->>R: randomSecure(data[0..16])
        V->>V: mask version to 4
        V->>V: mask variant to RFC 4122
    else v7
        V->>V: lock mutex
        V->>K: now()
        V->>V: build 48-bit millisecond timestamp
        V->>R: randomSecure(random part)
        V->>V: handle same-millisecond and clock-backward cases
        V->>V: mask version to 7
        V->>V: mask variant to RFC 4122
        V->>V: unlock mutex
    end
    V-->>C: Self
```

Nothing allocates. A generated UUID is 16 bytes in the version struct's `data` field.

<br>

## The parse flow

```mermaid
sequenceDiagram
    participant C as Caller
    participant V as version struct

    C->>V: initFromString(str)
    V->>V: check length is 36 or 32
    V->>V: walk 16 bytes, skipping hyphens in the 36-char form
    V->>V: decode two hex characters per byte
    V->>V: check version bits
    V->>V: check variant bits
    V-->>C: Self, or an error
```

No allocation. The parsed value owns its 16 bytes inline.

<br>

## The format flow

```mermaid
sequenceDiagram
    participant C as Caller
    participant V as version struct
    participant B as Caller buffer

    C->>V: asString(buf) or asReffID(buf)
    V->>B: write hex characters
    alt asString
        V->>B: insert hyphens at 8, 13, 18, 23
    else asReffID
        V->>B: no hyphens
    end
    V-->>C: the filled slice
```

No allocation. The caller supplies the buffer: `[36]u8` for `asString`, `[32]u8` for `asReffID`.

<br>

## Allocation model

| Direction | What is allocated | Who owns it |
| :- | :- | :- |
| Generate | nothing | the returned struct holds the 16 bytes inline |
| Parse | nothing | the returned struct holds the 16 bytes inline |
| Format | nothing | the caller's fixed buffer holds the whole string |

<br>

## Error model

Two error sets, one for generation and one for parsing.

- `init` reports only errors from the IO layer (random fill or clock read). It does not allocate and does not validate the result.
- `initFromString` reports the parse set: `InvalidUuidLength`, `InvalidUuidFormat`, `InvalidHexCharacter`, `InvalidUuidVersion`, `InvalidUuidVariant`. Every version uses the same set.

Swapping a version never changes what a caller has to handle on the parse side. The generation side inherits the IO error set from the standard library.
