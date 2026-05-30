# LLD: zix.Udp

Detail implementasi internal untuk lapisan UDP. Untuk dasar keputusan desain lihat [`docs/hld-udp-id.md`](hld-udp-id.md).

---

## server.zig: UdpServer(Packet)

### Assert ukuran comptime

Di bagian atas `UdpServer(Packet)`:
```zig
// RFC 768: max UDP payload = 65,535 - 8 (UDP header) - 20 (min IPv4 header) = 65,507 bytes.
if (@sizeOf(Packet) > 65_507) @compileError("Packet size exceeds maximum UDP payload of 65,507 bytes (RFC 768)");
```

Dijalankan saat build, bukan saat runtime.

### ClientRecord

```zig
const ClientRecord = struct {
    from:      std.Io.net.IpAddress,   // alamat remote yang digunakan sebagai identitas client
    last_seen: std.Io.Clock.Timestamp, // untuk deteksi disconnect berbasis timeout
    index:     usize,                  // counter monoton: hanya untuk keluaran log
};
```

Identitas client adalah alamat remote. Index bersifat informatif, tidak stabil lintas reconnect, dan tidak digunakan untuk routing.

### Receive loop

```
1. Bind: IpAddress.parse(ip, port) -> addr.bind(io, .dgram .udp) -> Socket
2. poll_timeout = Io.Timeout { .duration = fromMilliseconds(poll_timeout_ms) }
3. Loop:
      msg = socket.receiveTimeout(io, buf, poll_timeout)
      if Timeout:
        now = Timestamp.now(io, .awake)
        checkDisconnections(clients, now, disconnect_timeout_ms)
        last_check = now
        continue
      if msg.flags.trunc or msg.data.len != @sizeOf(Packet):
        if error_report: socket.send(io, &msg.from, &[_]u8{0x15})
        continue
      now = Timestamp.now(io, .awake)
      upsert ClientRecord for msg.from
      rate-limited checkDisconnections (if elapsed >= poll_timeout_ms since last_check)
      if broadcast: heap-alloc peer snapshot []IpAddress from clients
      io.concurrent(processPacket, Task{ ... })
```

### Task

```zig
const Task = struct {
    buf:          [@sizeOf(Packet)]u8,  // salinan byte datagram yang diterima
    from:         std.Io.net.IpAddress, // alamat pengirim
    socket:       std.Io.net.Socket,    // shared: UDP send bersifat kernel-atomic per datagram
    io:           std.Io,
    config:       UdpServerConfig,
    peers:        []std.Io.net.IpAddress, // snapshot heap-allocated, dibebaskan di processPacket
    sender_index: usize,
};
```

`Task` diteruskan sebagai nilai ke `io.concurrent()`. Semua field adalah tipe nilai atau handle yang aman untuk disalin (tidak ada shared mutable state kecuali `socket`, yang aman karena UDP `send()` bersifat kernel-atomic per datagram).

### processPacket()

```
defer: if peers.len > 0 -> task.config.allocator.free(peers)

if auto_ack:   socket.send(io, &from, &[_]u8{0x06})
if auto_echo:  socket.send(io, &from, &buf)
if broadcast:
    for each peer in peers:
        socket.send(io, peer, &buf)
        // SECURITY: tidak ada validasi pengirim, IP palsu dapat memicu broadcast
        // PERF: N pemanggilan send() syscall secara berurutan, sendmmsg dapat menguranginya menjadi 1
```

### checkDisconnections()

```
i = 0
while i < clients.items.len:
    elapsed = durationTo(clients.items[i].last_seen, now).raw.toMilliseconds()
    if elapsed >= timeout_ms:
        clients.swapRemove(i)  // O(1), urutan tidak dijaga tetapi tidak relevan
    else:
        i += 1
```

`swapRemove` mengganti entri yang dihapus dengan entri terakhir. Urutan daftar client tidak signifikan.

---

## client.zig: UdpClient(Packet)

### Assert ukuran comptime

Sama seperti server, dijalankan saat build.

### init()

```
1. if bind_port == 0 or server_port == 0: return error.PortNotConfigured
2. bind_addr = IpAddress.parse("127.0.0.1", bind_port)
3. socket = bind_addr.bind(io, .dgram .udp)  // satu socket untuk kirim dan terima
4. dest = IpAddress.parse(server_ip, server_port)
5. return Self { config, socket, dest, io }
```

Satu socket digunakan untuk `send()` dan `receiveFeedback()`. Server membalas ke alamat bind milik client.

### send()

```
wire = toEndian(Packet, packet_data, config.endianness)
socket.send(io, &dest, std.mem.asBytes(&wire))
```

### receiveFeedback()

```
buf: [@sizeOf(Packet)]u8 = undefined
msg = socket.receive(io, &buf)         // blocking
if msg.data.len == 1:
    if data[0] == 0x06: return .ack
    else:               return .nack
if msg.data.len == @sizeOf(Packet):
    wire_pkt: Packet = @bitCast(buf)
    return .{ .packet = fromEndian(Packet, wire_pkt, config.endianness) }
return error.UnexpectedPacketSize
```

Dispatch berdasarkan panjang adalah mekanisme decoding. ACK/NACK adalah respons satu byte, echo packet penuh atau broadcast relay memiliki tepat `@sizeOf(Packet)` byte.

---

## packet.zig: Helper Endianness

### swapFields() / swapField()

```
swapFields(T, ptr):
    inline for fields of T:
        swapField(field.type, &field_ptr)

swapField(T, ptr):
    switch typeInfo(T):
        .int   -> ptr.* = @byteSwap(ptr.*)
        .float -> Int = meta.Int(.unsigned, bits)
                  ptr.* = @bitCast(@byteSwap(@as(Int, @bitCast(ptr.*))))
        .array -> if @sizeOf(child) > 1:   // lewati array u8
                      for each element: swapField(child, &elem)
        else   -> no-op
```

`inline for` atas field struct dievaluasi pada comptime: isi loop di-unroll menjadi operasi per-field tanpa overhead cabang runtime.

Swap float menggunakan `@bitCast` untuk menginterpretasi ulang float sebagai integer unsigned dengan lebar bit yang sama, menerapkan `@byteSwap`, lalu menginterpretasi kembali. Ini benar untuk pembalikan byte IEEE 754.

### toEndian() / fromEndian()

```
toEndian(Packet, pkt, endianness):
    if endianness == .NATIVE: return pkt    // no-op
    native = builtin.cpu.arch.endian()
    target = if endianness == .LITTLE: .little else .big
    if native == target: return pkt         // sudah benar, no-op
    result = pkt
    swapFields(Packet, &result)
    return result

fromEndian = toEndian   // swap adalah inversnya sendiri
```

Kedua fungsi mengembalikan nilai baru sementara nilai aslinya tidak dimodifikasi.

---

## config.zig: PortMode / Endianness / Config

### Nilai backing enum

`PortMode` dan `Endianness` adalah `enum(u8)`. Nilai integer-nya bersifat stabil dan diuji secara eksplisit untuk mendeteksi pengurutan ulang yang tidak disengaja.

```
PortMode:   CONFIGURABLE=0, REQUIRED=1
Endianness: NATIVE=0, LITTLE=1, BIG=2
```

Stabilitas penting karena enum ini dapat muncul dalam config yang diserialisasi atau dibandingkan lintas versi build.

---

###### end of lld-udp
