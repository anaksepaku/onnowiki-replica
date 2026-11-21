# Replikasi OnnoWiki — sekali tempel, langsung jadi

Repositori ini berisi cara mereplikasi **OnnoWiki** (onnocenter.or.id/wiki) ke MediaWiki lokal
tanpa perlu bantuan AI, tanpa dump SQL, dan tanpa akses ke server sumber.

Sumber: https://onnocenter.or.id/wiki/ · konten SpeedyWiki/OnnoWiki dinyatakan bebas diambil.
**Berikan atribusi ke OnnoWiki/SpeedyWiki di wiki lokal Anda.**

## Cara pakai (Debian / Ubuntu saja untuk sekarang)

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-onnowiki.sh?ref=main&cb=$(date +%s)" | sudo bash
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

## Login admin & izin edit

Saat instalasi pertama, script **membuat password admin secara acak** (16 karakter) dan:

- menampilkannya di layar saat instalasi,
- menyimpannya di `onnowiki-replica/ADMIN_CREDENTIALS.txt` (mode `0600`).

User admin: **`Admin`** (kalau tidak ada, cek `Special:ListUsers` di wiki lokal).
**Segera ganti password** lewat `Special:ChangePassword` setelah login.

Secara default MediaWiki **mengizinkan siapa saja mengedit**, termasuk pengunjung anonim.
Karena ini replika publik, installer menambahkan ke `LocalSettings.php`:

```php
$wgGroupPermissions['*']['edit'] = false;
$wgGroupPermissions['*']['createpage'] = false;
$wgGroupPermissions['*']['createtalk'] = false;
```

Jadi **pengunjung hanya bisa membaca**. User terdaftar tetap bisa edit (default MediaWiki).
Pengaturan ini **tidak ada di dashboard admin web** — harus disunting di file
`wiki/LocalSettings.php` di server (atau memakai ekstensi seperti ManageWiki kalau ingin lewat UI).
Untuk mengizinkan edit anonim lagi, hapus/ubah tiga baris itu lalu restart container.

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
curl -fsSL -H 'Accept: application/vnd.github.raw+json' "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-onnowiki.sh?ref=main&cb=$(date +%s)" | sudo -E bash
```

## Akses dari perangkat lain / bind ke IP tertentu

Secara default `docker-compose.yml` membuka port hanya di **loopback**:

```yaml
ports:
  - "127.0.0.1:8080:80"
```

Itu sengaja supaya replika tidak terekspos. Kalau mau diakses dari komputer lain di LAN
atau lewat IP Tailscale, ganti ke IP yang diinginkan:

```yaml
ports:
  - "192.0.2.73:8080:80"     # ganti dengan IP server Anda
  # - "0.0.0.0:8080:80"       # semua interface (hati-hati)
  # - "198.51.100.77:8080:80" # contoh IP Tailscale
```

Lalu **sesuaikan `$wgServer`** di `wiki/LocalSettings.php`, kalau tidak, redirect `/wiki/`
tetap mengarah ke `localhost`:

```php
$wgServer = "http://192.0.2.73:8080";
```

Terapkan perubahan:

```bash
cd onnowiki-replica
docker compose down && docker compose up -d
```

Buka `http://192.0.2.73:8080/wiki/`.

> `--servername` di `install.php` hanya dipakai saat instalasi pertama. Untuk wiki yang sudah
> jalan, yang berlaku adalah `$wgServer` di `LocalSettings.php`.
>
> Sebelum membuka ke LAN/internet: ganti password DB `wikipassword` di `docker-compose.yml`,
> dan ingat pengunjung anonim sudah tidak bisa edit. Port 8080 juga harus diizinkan di
> firewall server (mis. `ufw allow from 192.0.2.0/24 to any port 8080`).
> Untuk akses dari luar rumah, lebih aman lewat Tailscale/reverse proxy + HTTPS daripada
> port-forward langsung.

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
| `update.sh` | Update inkremental dari sumber |
| `KNOWN_GAPS.md` | Daftar halaman/gambar yang tidak bisa diambil |

> **Keamanan:** kompose hanya membuka port `127.0.0.1:8080` (tidak terekspos ke LAN/internet).
> Password database bawaan adalah `wikipassword` — ganti di `docker-compose.yml` sebelum
> membuka akses ke pihak lain. Password admin dibuat acak tiap instalasi.
