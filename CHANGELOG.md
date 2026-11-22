# Changelog

Semua perubahan penting dicatat di sini. Format mengikuti
[Keep a Changelog](https://keepachangelog.com/id/1.1.0/).

## [1.0.0] - 2026-11-22

### Ditambahkan
- Installer satu perintah `install-onnowiki.sh` (self-contained, Docker + MediaWiki + import).
- `install-full.sh` untuk uji bersih sampai full import + verifikasi `FULL_IMPORT=PASS`.
- `uninstall.sh` untuk menghapus instalasi beserta container/volume/network.
- `update.sh` + `scripts/nightly_sync.py` untuk update inkremental lewat `recentchanges`.
- Log permanen `$ONNOWIKI_DIR/install.log` via `tee`.
- Env `ONNOWIKI_DIR`, `WG_BIND_IP`, `WG_PORT`, `WG_SERVER_URL` untuk bind IP/hostname.
- Hak edit anonim dimatikan secara default di `LocalSettings.php`.
- Password admin acak 16 karakter disimpan di `ADMIN_CREDENTIALS.txt` (0600).
- `LICENSE` (MIT untuk script) dan catatan atribusi konten OnnoWiki/SpeedyWiki.
- Tutorial manual, troubleshooting, dan cara uninstall di README.
- Panduan install ke folder khusus lewat `ONNOWIKI_DIR` (mis. `/srv`) tanpa paste script ke folder.
- Bagian **Pengamanan untuk server produksi**: ganti password DB, admin, bind/firewall, backup.
- Tutorial ganti password DB diperbaiki: include backup, `sed` otomatis untuk compose +
  `LocalSettings.php`, dan penyimpanan password acak ke file `0600`.

### Verifikasi
- Full import di server `.58`: **FULL_IMPORT=PASS**, `pages=18185`, `articles=6890`,
  `images=6457`, `edits=24593`.
- Waktu terukur: **59 menit 37 detik** (Docker build ±61 detik).
- Akses `http://192.0.2.58:8080/wiki/` → 200 dari host lain (prau, rinjani).

### Fixed
- `Main Page` bawaan MediaWiki ("MediaWiki has been installed") kini ditimpa otomatis dengan
  Main Page dari OnnoWiki via `scripts/fix_mainpage.sh` setelah import XML.
- Parser cache dibersihkan (`purgeParserCache.php --age 0`) setelah import agar gambar tidak
  tampil sebagai `mw-broken-media`.
- Urutan argumen `install.php` diperbaiki: user admin sekarang benar-benar `Admin` sesuai
  `ADMIN_CREDENTIALS.txt` (sebelumnya `OnnoWiki Lokal`).
- README memberi peringatan eksplisit + FAQ untuk instalasi lama yang user admin-nya masih
  `OnnoWiki Lokal`, lengkap dengan perintah reset password.

### Catatan
- Spesifikasi minimum: 1 vCPU / 2 GB RAM / 5 GB disk bebas (disarankan 2 vCPU / 4 GB / 10 GB).
- Hanya mendukung **Debian / Ubuntu**; Windows/macOS belum.
- 14 halaman dan 111 gambar memang kosong/404 di server sumber — lihat `KNOWN_GAPS.md`.
- Root `/` sengaja 403; halaman ada di `/wiki/`.
