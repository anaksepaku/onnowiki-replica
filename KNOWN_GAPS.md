# Yang tidak ikut ter-replikasi (dan kenapa)

Replika ini dibuat lewat **MediaWiki API**, bukan dump SQL, karena tautan unduhan lama
(`lms.onnocenter.or.id/pustaka/datawiki/wikidb.sql.gz` dan `images.tar.gz`) sudah **404**.

## 1. Halaman yang kosong di sumber

14 judul berikut tidak bisa diekspor karena server OnnoWiki mengembalikan
`LogicException` / HTTP 500, atau memang **tidak punya revisi sama sekali**:

- `Blog` dan `SDM: Virtualization` — berhasil dipulihkan lewat jalur `oldid`.
- `Nokis`, `Subekti Pranoto`, `ZAYBAJOTZ`
- `Talk:Nokis`, `Talk:Onno W. Purbo`
- `User:Onowpurbo`, `User:Wienswiki`, `User talk:Wienswiki`
- `File:Bajo40tz.jpg`, `File:Id.png-id.png`, `File:Image - Copy.jpg`, `File:Logo Kevin Motor.gif`

Kalau halaman itu kosong di wiki Anda, **itu bukan kesalahan instalasi**. Isinya memang tidak
ada di sumber saat replikasi dibuat (21 Nov 2026).

## 2. Gambar 404 di sumber

111 nama gambar masih terdaftar di `allimages` tetapi file aslinya sudah dihapus dari server.
Daftarnya ada di `failed_images.json` di folder `data/`.

## 3. Sumber sering error

`api.telegram...` bukan — tapi `onnocenter.or.id` sesekali menjawab
"Cannot access the database". Skrip sudah retry dengan backoff. Kalau gagal total, jalankan
ulang `replicate.sh`; berkas yang sudah terunduh tidak diunduh lagi (resume by size).

## 4. HTTPS sumber expired

API dan gambar diambil lewat **`http://`**, bukan `https://`. Ini disengaja.

## 5. Atribusi

Konten OnnoWiki/SpeedyWiki dinyatakan bebas diambil. Tetap cantumkan sumber:
**OnnoWiki — onnocenter.or.id/wiki** dan **SpeedyWiki** di halaman About wiki lokal Anda.
