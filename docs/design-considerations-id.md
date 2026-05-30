## Pertimbangan Desain

Bukan tugas aktif: pengingat untuk keputusan di masa depan.

**AoS (Array of Structures):** situs-situs yang tersisa (`extra_buf`, `fields`, `conns`, ...). Ketika salah satunya menjadi bottleneck throughput, layout SoA adalah kandidat pengganti. `routes` sudah dikonversi ke `MultiArrayList` (SoA) sehingga dispatch pass hanya memindai slice field yang sering diakses.

**OoP (Object-oriented Patterns):** sebagian besar struct (`Request`, `Response`, `Router`, `Context`, `ConnQueue`, `MultipartParser`, ...) mengikuti pola ini. Idiomatis di Zig dan baik-baik saja sebagai baseline.

**DoD (Data-Oriented Design):** arah yang akan dituju ketika layout data lebih penting daripada enkapsulasi. Khusus untuk lapisan HTTP, gagasannya adalah sebuah *http engine* tersendiri: inti bertingkat rendah yang berorientasi data, berada di bawah `server.zig`. Belum dimulai. Tinjau ulang ketika baseline saat ini benar-benar mencapai batasnya.
