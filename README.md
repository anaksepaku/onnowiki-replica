# Replikasi OnnoWiki — sekali tempel, langsung jadi

Repositori ini berisi cara mereplikasi **OnnoWiki** (onnocenter.or.id/wiki) ke MediaWiki lokal
tanpa perlu bantuan AI, tanpa dump SQL, dan tanpa akses ke server sumber.

Sumber: https://onnocenter.or.id/wiki/ · konten SpeedyWiki/OnnoWiki dinyatakan bebas diambil.
**Berikan atribusi ke OnnoWiki/SpeedyWiki di wiki lokal Anda.**

## Status terverifikasi

| Item | Hasil |
|---|---|
| Full import | **FULL_IMPORT=PASS** (22 Nov 2026, server `.58`) |
| Halaman | 18.185 · artikel 6.890 · gambar 6.457 · edit 24.593 |
| Waktu | 59 menit 37 detik (±1 jam) |
| Web | `http://IP:8080/wiki/` → 200 (diakses dari host lain) |
| OS | Debian / Ubuntu |

> **Halaman utama kosong atau gambar tidak tampil?** Itu dua masalah yang sudah terkenal dan
> punya solusi di [Troubleshooting / FAQ](#troubleshooting--faq). Installer terbaru sudah
> menangani keduanya otomatis.

## Prasyarat

- Debian / Ubuntu dengan akses `root` atau `sudo`.
- Koneksi internet (unduh ±600 MB) dan ruang disk bebas sesuai tabel di bawah.
- Port 8080 bebas (atau set `WG_PORT` ke port lain).
- Docker akan dipasang otomatis oleh script bila belum ada.

### Spesifikasi server minimum

| Komponen | Minimum | Disarankan |
|---|---|---|
| CPU | **1 vCPU** | 2 vCPU |
| RAM | **2 GB** | 4 GB |
| Disk bebas | **5 GB** | 10 GB |
| OS | Debian 12/13 atau Ubuntu 22.04/24.04 | versi LTS terbaru |
| Network | unduh ±600 MB, stabil | — |

Catatan: teruji sukses di VM **2 GB RAM / 30 GB disk (saat itu sisa 3,9 GB)** dengan full import.
Pemakaian idle setelah jalan: wiki ±78 MB, MariaDB ±260 MB. Saat import RAM bisa naik —
2 GB masih cukup, tapi **4 GB lebih aman** kalau server dipakai untuk layanan lain.
Kebutuhan disk aktual: `data/` ±671 MB + `wiki/` ±1,6 GB + database; 5 GB memberi ruang aman.

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

### Opsi lewat environment (wajib dengan `sudo -E`)

```bash
export ONNOWIKI_DIR=/srv/onnowiki-replica   # default: $HOME/onnowiki-replica (sering /root/...)
export WG_BIND_IP=192.0.2.73               # default: 127.0.0.1
export WG_PORT=8080                         # default: 8080
export WG_SERVER_URL=http://192.0.2.73:8080 # default: http://$WG_BIND_IP:$WG_PORT
```

`WG_BIND_IP`/`WG_PORT` mengubah `docker-compose.yml`; `WG_SERVER_URL` menulis `$wgServer`
di `LocalSettings.php` (install.php sering mengabaikan `--servername`, jadi script memaksanya).

### Install ke folder khusus (mis. `/srv`)

**Tidak perlu** masuk/paste script ke folder tujuan. Script dijalankan dari mana saja, lalu
`ONNOWIKI_DIR` menentukan di mana semua file dibuat — folder akan dibuat otomatis.

```bash
export ONNOWIKI_DIR=/srv/onnowiki-replica-prau
export WG_BIND_IP=192.0.2.73
export WG_PORT=8080
export WG_SERVER_URL=http://192.0.2.73:8080

curl -fsSL -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-full.sh?ref=main&cb=$(date +%s)" \
  -o /tmp/install-full.sh

bash /tmp/install-full.sh
```

Kalau tidak root, gunakan `sudo -E bash /tmp/install-full.sh` supaya variabel `export` ikut.

Kenapa `/srv`? Root `/` sering mepet (butuh ±2,3–3 GB saat import). Gunakan mount dengan
ruang lega. Cek dulu: `df -h /srv`.

Setelah selesai:
```bash
ls -d /srv/onnowiki-replica-prau
curl -s -o /dev/null -w '%{http_code}\n' http://192.0.2.73:8080/wiki/
```

### Tahapan yang dijalankan script

1. **Curl installer** — satu perintah di atas (self-contained, tidak perlu `git clone`).
2. **Docker** — install Docker + Compose plugin bila belum ada, lalu `docker compose up -d --build`.
3. **Install MediaWiki** — `install.php`, password admin acak, hak edit anonim dimatikan.
4. **Import** — halaman (XML) + gambar lewat API, lalu `initSiteStats.php --update`.
5. **Go live** — verifikasi statistik lewat API, cetak URL + lokasi kredensial.

Jika salah satu import gagal, script tetap melanjutkan tapi mencetak peringatan `!!` — jangan
abaikan pesan itu.

## Uji install bersih sampai FULL import

Script `install-full.sh` menghapus mode smoke (`PAGES`/`IMAGES`), menjalankan installer dari GitHub,
lalu memverifikasi jumlah halaman/gambar. Untuk uji dari nol:

```bash
sudo rm -rf /root/onnowiki-replica-full
curl -fsSL -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-full.sh?ref=main&cb=$(date +%s)" \
  -o /tmp/install-full.sh
sudo bash /tmp/install-full.sh
```

Output akhir harus `FULL_IMPORT=PASS` (minimal 18.000 halaman dan 6.400 gambar).
Kalau port 8080 bentrok, set dulu `WG_PORT` dan jalankan dengan `sudo -E`.

Log seluruh proses tersimpan di `$ONNOWIKI_DIR/install.log` — gunakan ini kalau sesi terputus.

## Coba manual sebagai pengguna (disarankan)

Kalau ingin memahami alurnya, jalankan langkah demi langkah (asal sudah `root`):

```bash
# 0. Pastikan bersih
docker ps -a | grep -i onnowiki || echo "container: bersih"
ss -ltnp | grep 8080 || echo "port 8080: bebas"

# 1. Unduh script full-install
curl -fsSL -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-full.sh?ref=main&cb=$(date +%s)" \
  -o /tmp/install-full.sh
head -5 /tmp/install-full.sh

# 2. Jalankan (± 60 menit pada 6.500 gambar, ±600 MB)
bash /tmp/install-full.sh

# 3. Pantau dari terminal lain bila perlu
tail -f /root/onnowiki-replica-full/install.log
```

Waktu terukur pada server `.58`: **59 menit 37 detik** (log dibuat 00:44:15 UTC, selesai
01:43:52 UTC). Docker build ±61 detik; sisanya fetch + import. Jadi siapkan waktu ±1 jam,
bukan 20–30 menit.

Tahap yang lewat: unduh installer → Docker/Compose → `install.php` → **fetch halaman+gambar**
(paling lama) → import XML+gambar → statistik → `FULL_IMPORT=PASS`.

Verifikasi akhir:

```bash
grep wgServer /root/onnowiki-replica-full/wiki/LocalSettings.php
grep -A2 'ports:' /root/onnowiki-replica-full/docker-compose.yml
curl -s 'http://127.0.0.1:8080/wiki/api.php?action=query&meta=siteinfo&siprop=statistics&format=json'
curl -s -o /dev/null -w 'web=%{http_code}\n' http://127.0.0.1:8080/wiki/
cat /root/onnowiki-replica-full/ADMIN_CREDENTIALS.txt   # jangan tempel password ke chat
```

Kalau ada `!!` atau `FULL_IMPORT=FAIL`, baca `install.log` lalu **jalankan ulang perintah yang sama** —
script aman diulang (resume download, tidak mengimpor ulang yang sudah ada).

## Uninstall / hapus instalasi

**Paling aman** — pakai script yang disediakan:

```bash
bash /root/onnowiki-replica-full/uninstall.sh /root/onnowiki-replica-full
```

Script ini: `docker compose down -v` dulu, lalu menghapus container/volume/network yatim
(kalau folder sudah terhapus duluan), baru `rm -rf` folder. Diminta konfirmasi `y` sebelum hapus.

Manual (urutan penting — `down -v` **sebelum** folder dihapus):

```bash
cd /root/onnowiki-replica-full && docker compose down -v
cd /
rm -rf /root/onnowiki-replica-full

# Fallback kalau folder terlanjur hilang:
docker rm -f onnowiki-replica-full-wiki-1 onnowiki-replica-full-db-1 2>/dev/null || true
docker volume rm onnowiki-replica-full_dbdata 2>/dev/null || true
docker network rm onnowiki-replica-full_default 2>/dev/null || true

docker ps -a | grep -i onnowiki || echo "container: tidak ada"
ss -ltnp | grep 8080 || echo "port 8080: bebas"
```

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

Halaman utama **tidak** lagi berisi "MediaWiki has been installed" — installer menimpa
`Main Page` dengan isi dari OnnoWiki lewat `scripts/fix_mainpage.sh` setelah import XML.

## Troubleshooting / FAQ

**`Forbidden — You don't have permission to access this resource`**
Anda membuka root `/`. Docroot kosong dan directory listing mati. Buka **`/wiki/`**.

**`LocalSettings.php` tidak ada**
`install.php` belum jalan — kemungkinan sesi terputus setelah `docker compose up`. Jalankan ulang
one-liner/`install-full.sh` (resume, aman) atau cek `$ONNOWIKI_DIR/install.log`.

**Folder tidak ketemu setelah `sudo bash`**
Karena `sudo`, `$HOME` jadi `/root`. Cek `/root/onnowiki-replica/` atau set `ONNOWIKI_DIR`.

**Port 8080 sudah dipakai**
Set `WG_PORT=8081` lalu jalankan dengan `sudo -E`.

**Ada baris `!!` atau `FULL_IMPORT=FAIL`**
Baca `install.log`, lalu ulangi perintah yang sama. Download gambar di-resume by size.

**Halaman utama masih kosong / "MediaWiki has been installed"**
`importDump.php` tidak menimpa halaman yang sudah ada. Installer terbaru sudah menjalankan
`scripts/fix_mainpage.sh`. Kalau wiki lama masih begini:

```bash
cd /srv/onnowiki-replica-prau          # sesuaikan folder Anda
docker compose exec -T wiki bash /workspace/scripts/fix_mainpage.sh
```

Cek:
```bash
curl -s "http://IP:8080/wiki/api.php?action=query&prop=revisions&titles=Main_Page&rvprop=content&rvslots=main&format=json&formatversion=2" | grep -o 'SpeedyWiki'
```

**Gambar tidak tampil / `mw-broken-media` / ikon gambar rusak**
File dan DB biasanya sudah benar — yang salah adalah **parser cache** yang masih menyimpan
halaman dari sebelum gambar di-import. Installer terbaru sudah menjalankan
`maintenance/purgeParserCache.php --age 0`. Kalau masih terjadi:

```bash
cd /srv/onnowiki-replica-prau          # sesuaikan folder Anda
docker compose exec -T wiki php /var/www/html/wiki/maintenance/purgeParserCache.php --age 0
```

Cek dulu apakah file aslinya bisa diakses (harus `200`):
```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://IP:8080/wiki/images/5/5c/0.0buka_case.jpg
```

Setelah purge, artikel yang tadinya broken harus menampilkan `<img>` (bukan `mw-broken-media`).

**`127.0.0.1:8080` tidak jalan setelah ganti bind**
Wajar — port hanya di-bind ke IP yang Anda set. Pakai IP tersebut.

## Lisensi

Script di repo ini berlisensi **MIT** — lihat [LICENSE](LICENSE).
Konten wiki berasal dari OnnoWiki/SpeedyWiki dan tetap butuh atribusi.

## Isi repo

| File | Fungsi |
|---|---|
| `install-onnowiki.sh` | Bootstrap satu perintah (self-contained) |
| `Dockerfile` | PHP 8.3 + Apache + ekstensi MediaWiki + Python 3 |
| `docker-compose.yml` | MariaDB 10.11 + wiki |
| `scripts/fetch_wiki.py` | Export halaman + unduh gambar (checkpoint, retry, resume) |
| `scripts/nightly_sync.py` | Update inkremental lewat API |
| `scripts/fix_mainpage.sh` | Timpa Main Page bawaan dengan isi OnnoWiki |
| `update.sh` | Update inkremental dari sumber |
| `install-full.sh` | Uji install bersih + full import + verifikasi |
| `uninstall.sh` | Hapus instalasi beserta container/volume/network |
| `KNOWN_GAPS.md` | Daftar halaman/gambar yang tidak bisa diambil |
| `CHANGELOG.md` | Riwayat versi |
| `LICENSE` | MIT untuk script + catatan atribusi konten |

> **Keamanan:** kompose hanya membuka port `127.0.0.1:8080` (tidak terekspos ke LAN/internet).
> Password database bawaan adalah `wikipassword` — ganti di `docker-compose.yml` sebelum
> membuka akses ke pihak lain. Password admin dibuat acak tiap instalasi.
