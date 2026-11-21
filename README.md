# Replikasi OnnoWiki — sekali tempel, langsung jadi

Repositori ini berisi cara mereplikasi **OnnoWiki** (onnocenter.or.id/wiki) ke MediaWiki lokal
tanpa perlu bantuan AI, tanpa dump SQL, dan tanpa akses ke server sumber.

Sumber: https://onnocenter.or.id/wiki/ · konten SpeedyWiki/OnnoWiki dinyatakan bebas diambil.
**Berikan atribusi ke OnnoWiki/SpeedyWiki di wiki lokal Anda.**

## Cara pakai (Debian / Ubuntu saja untuk sekarang)

```bash
curl -fsSL 'https://cdn.jsdelivr.net/gh/anaksepaku/onnowiki-replica@main/install-onnowiki.sh' | sudo bash
```

Selesai. Buka **http://localhost:8080/wiki/**.

> **Dukungan OS:** saat ini hanya **Debian / Ubuntu** (script memakai `apt-get` untuk memasang
> Docker). Dukungan **Windows dan macOS** menyusul berikutnya — untuk sekarang silakan pakai VM/Linux
> atau Docker Desktop dengan distro Debian/Ubuntu di dalamnya.

Script di atas otomatis:
1. Memasang Docker + Compose plugin bila belum ada.
2. Mengunduh MediaWiki 1.43.12 (versi di-pin).
3. Menjalankan MariaDB + PHP/Apache lewat `docker compose`.
4. Mengambil semua halaman dan gambar lewat MediaWiki API (dengan retry).
5. Import XML + gambar, lalu menghitung ulang statistik.

## Update halaman dari sumber

```bash
cd onnowiki-replica
./update.sh
```

Ini memakai `recentchanges` + log upload: hanya halaman yang berubah yang ditulis ulang.
Jalankan harian lewat cron/host bila mau.

## Mode uji cepat

```bash
export PAGES=5 IMAGES=3
curl -fsSL https://cdn.jsdelivr.net/gh/anaksepaku/onnowiki-replica@main/install-onnowiki.sh | sudo bash
```

## Port & path

- Web: `http://localhost:8080/wiki/` — ubah `ports:` di `docker-compose.yml` kalau 8080 bentrok.
- Data hasil unduhan: `onnowiki-replica/data/`
- MediaWiki: `onnowiki-replica/wiki/`
- State sinkron: `onnowiki-replica/state/`

## Yang tidak ikut (baca dulu)

Lihat [KNOWN_GAPS.md](KNOWN_GAPS.md): 14 judul dan 111 gambar memang kosong/404 di sumber,
bukan kesalahan instalasi.

## Isi repo

| File | Fungsi |
|---|---|
| `install-onnowiki.sh` | Bootstrap satu perintah (self-contained) |
| `Dockerfile` | PHP 8.3 + Apache + ekstensi MediaWiki + Python 3 |
| `docker-compose.yml` | MariaDB 10.11 + wiki |
| `scripts/fetch_wiki.py` | Export halaman + unduh gambar (checkpoint, retry, resume) |
| `scripts/nightly_sync.py` | Update inkremental lewat API |
| `KNOWN_GAPS.md` | Daftar halaman/gambar yang tidak bisa diambil |
