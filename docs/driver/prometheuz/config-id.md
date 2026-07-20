# Referensi Config prometheuz

Arti tiap field `ScrapeConfig`, `WriteConfig`, dan `QueryConfig`, dan bagaimana mengubahnya memengaruhi proses yang berjalan. Berbeda dengan `postgrez`/`rediz`, tidak ada satu config bersama: target scrape, receiver remote_write, dan endpoint API query adalah tiga server berbeda pada deployment nyata, sehingga tiap permukaan membawa struct flat-nya sendiri (lihat `hld-id.md` untuk alasannya). Setiap field punya default, tidak ada yang wajib.

## Cara membaca kolom

Sel dibiarkan kosong bila tidak berlaku.

| kolom | arti |
| :- | :- |
| field | nama field struct config |
| default | nilai yang dipakai bila field dihilangkan |
| kontrol | apa yang dilakukan field ini |
| dampak perf | di mana posisinya dan metrik apa yang dipengaruhi |
| jika lebih rendah | konsekuensi nilai yang lebih kecil |
| jika lebih tinggi | konsekuensi nilai yang lebih besar |

## ScrapeConfig

Dipakai oleh `scrapeOnce` dan `Scraper`.

| field | default | kontrol | dampak perf | jika lebih rendah | jika lebih tinggi |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | host target scrape, IP literal atau hostname | startup (hostname menambah lookup) | | hostname melewati lookup hosts dan DNS |
| port | `9100` | port target scrape | | | |
| path | `/metrics` | path target scrape | | | |
| scrape_interval_ms | `15000` | `Scraper` saja: jeda antar polling | cadence polling vs kebasian data | data lebih segar, beban scrape ke target lebih besar | hasil `latest()` lebih basi antar polling |
| conn_timeout_ms | `5000` | diterima demi kesamaan bentuk API, belum diberlakukan (lihat `hld-id.md`) | | | |
| max_response_body | `4194304` (4 MiB) | batas body response scrape dalam byte | batas memori per scrape | menolak body `/metrics` yang sah tapi besar dengan `error.BodyTooLarge` | lebih banyak memori dipegang per scrape yang sedang berjalan |

`scrape_interval_ms` hanya berarti untuk `Scraper`: panggilan `scrapeOnce` telanjang bersifat sekali jalan dan mengabaikannya.

## WriteConfig

Dipakai oleh `remoteWrite`.

| field | default | kontrol | dampak perf | jika lebih rendah | jika lebih tinggi |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | host receiver remote_write | | | |
| port | `9090` | port receiver remote_write | | | |
| path | `/api/v1/write` | path receiver remote_write | | | |
| conn_timeout_ms | `5000` | diterima demi kesamaan bentuk API, belum diberlakukan | | | |
| max_response_body | `1048576` (1 MiB) | batas body response receiver dalam byte | batas memori per push | menolak body error receiver yang besar dengan `error.BodyTooLarge` | lebih banyak memori dipegang per push yang sedang berjalan |

`max_response_body` di sini membatasi *balasan receiver*, bukan payload yang di-push: `WriteRequest` yang sudah di-encode dan terkompresi snappy yang dikirim driver berukuran sesuai berapa banyak sample yang diberikan pemanggil ke `remoteWrite`, tanpa batas.

## QueryConfig

Dipakai oleh `query` dan `queryRange`. Hanya membawa host dan port: path tetap per pemanggilan (`/api/v1/query`, `/api/v1/query_range`).

| field | default | kontrol | dampak perf | jika lebih rendah | jika lebih tinggi |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | host API query Prometheus | | | |
| port | `9090` | port API query Prometheus | | | |
| conn_timeout_ms | `5000` | diterima demi kesamaan bentuk API, belum diberlakukan | | | |
| max_response_body | `4194304` (4 MiB) | batas body response JSON dalam byte | batas memori per query | menolak result set besar dengan `error.BodyTooLarge` | lebih banyak memori dipegang per query yang sedang berjalan, dibutuhkan untuk panggilan `queryRange` dengan window lebar atau banyak series |

## Catatan

- Tidak ada field yang wajib: setiap field config punya default yang bisa dipakai, berbeda dengan `postgrez.Config.user`.
- Tidak ada field `tls` di ketiga config: `http_client.zig` cleartext saja untuk saat ini (lihat `hld-id.md`). URL target yang diawali `https://` ditolak oleh `parseScrapeUrl`/`parseWriteUrl`/`parseQueryUrl` dengan `error.UnsupportedScheme`.
- `conn_timeout_ms` disimpan di setiap config demi kesamaan bentuk API tapi belum diberlakukan oleh `http_client.zig` - lihat bagian "Client HTTP/1.1 sendiri" di `hld-id.md` untuk alasannya.
- Default `max_response_body` berbeda per permukaan karena bentuk body yang diharapkan berbeda: hasil scrape atau query bisa besar (banyak metric family, window `queryRange` yang lebar), balasan receiver remote_write biasanya berupa 2xx singkat atau pesan error.
