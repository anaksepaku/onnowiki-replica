#!/bin/bash
# Replikasi OnnoWiki dalam satu perintah:
#   curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh | sudo bash
#
# Opsi (export dulu sebelum pipe):
#   export PAGES=5 IMAGES=3   # smoke test cepat
#   export ONNOWIKI_DIR=/srv/onnowiki-replica
set -euo pipefail

DIR="${ONNOWIKI_DIR:-$HOME/onnowiki-replica}"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Script ini butuh root untuk memasang Docker."
  echo "Jalankan: curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh | sudo bash"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log "Docker belum ada -> memasang Docker + Compose plugin"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-plugin
    systemctl enable --now docker
  else
    echo "Distro tidak dikenali. Pasang Docker dulu, lalu ulangi."
    exit 1
  fi
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin tidak ditemukan. Pasang docker-compose-plugin."
  exit 1
fi

mkdir -p "$DIR/scripts" "$DIR/wiki" "$DIR/data" "$DIR/state"
cd "$DIR"
log "Menulis file ke $DIR"

cat > Dockerfile <<'__ONNOWIKI_EOF_1__'
FROM php:8.3-apache

# Versi di-pin supaya orang lain tidak perlu menebak-nebak.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip python3 \
        libzip-dev libicu-dev libpng-dev libjpeg62-turbo-dev \
        libfreetype6-dev libxml2-dev libonig-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" mysqli mbstring xml intl zip gd \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
__ONNOWIKI_EOF_1__

cat > docker-compose.yml <<'__ONNOWIKI_EOF_2__'
services:
  db:
    image: mariadb:10.11
    environment:
      MARIADB_ROOT_PASSWORD: wikipassword
      MARIADB_DATABASE: wikidb
      MARIADB_USER: wikiuser
      MARIADB_PASSWORD: wikipassword
    volumes:
      - dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 30

  wiki:
    build: .
    ports:
      - "8080:80"
    volumes:
      - ./wiki:/var/www/html/wiki
      - ./data:/workspace/data
      - ./scripts:/workspace/scripts
      - ./state:/workspace/state
    depends_on:
      db:
        condition: service_healthy

volumes:
  dbdata:
__ONNOWIKI_EOF_2__

cat > scripts/fetch_wiki.py <<'__ONNOWIKI_EOF_3__'
#!/usr/bin/env python3
"""MediaWiki API replication with resumable, per-batch page export.

Differences from the simple version:
  - each 50-title export batch is saved under xml/parts/ and skipped on rerun;
  - batch wrappers are removed before combining, so the final XML has ONE root;
  - more retries with capped backoff for wikis that intermittently report DB errors.

Usage:
  python3 fetch_wiki.py --api http://wiki.example/w/api.php --out /data/wiki
  python3 fetch_wiki.py --api ... --out /data/wiki --pages 5 --images 3
"""
import argparse
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API = ""
UA = "MediaWiki-replica/2.0"
XML_HEADER = ('<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/" '
              'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
              'xsi:schemaLocation="http://www.mediawiki.org/xml/export-0.11/ '
              'http://www.mediawiki.org/xml/export-0.11.xsd" version="0.11" xml:lang="en">')


def api(params, tries=10):
    url = API + "?" + urllib.parse.urlencode(params)
    last = "unknown"
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as response:
                body = response.read().decode("utf-8", "replace")
            if "technical difficulties" in body or "Cannot access the database" in body:
                raise RuntimeError("site DB error")
            if body.lstrip().startswith("{"):
                return json.loads(body)
            return body
        except Exception as exc:
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(min(30, 2 + 3 * attempt))
    raise RuntimeError(f"api failed after {tries}x: {last}")


def strip_wrapper(text):
    text = re.sub(r"<\?xml[^>]*\?>", "", text).strip()
    text = re.sub(r"<mediawiki[^>]*>", "", text, count=1)
    text = re.sub(r"</mediawiki>\s*$", "", text)
    return text.strip()


def export_pages(out_dir, limit):
    xml_dir = os.path.join(out_dir, "xml")
    parts_dir = os.path.join(xml_dir, "parts")
    os.makedirs(parts_dir, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(xml_dir, f"wiki-{stamp}.xml")

    titles, ns = [], 0
    while ns <= 15:
        cont = {}
        while True:
            params = {"action": "query", "list": "allpages", "apnamespace": ns,
                      "aplimit": "500", "format": "json"}
            params.update(cont)
            d = api(params)
            titles += [p["title"] for p in d.get("query", {}).get("allpages", [])]
            if limit and len(titles) >= limit:
                titles = titles[:limit]
                break
            if "continue" not in d:
                break
            cont = d["continue"]
        if limit and len(titles) >= limit:
            break
        ns += 1

    bad_titles = []
    for i in range(0, len(titles), 50):
        part = os.path.join(parts_dir, f"{i // 50:05d}.xml")
        if os.path.exists(part) and os.path.getsize(part) > 100:
            continue
        batch = titles[i:i + 50]
        try:
            d = api({"action": "query", "export": "1", "exportnowrap": "1",
                     "titles": "|".join(batch), "format": "json"}, tries=3)
            if isinstance(d, dict):
                raise RuntimeError(f"export failed: {str(d)[:200]}")
            body = d
        except Exception as exc:
            # Satu halaman racun bisa membuat seluruh batch gagal (LogicException).
            # Coba per judul, simpan yang gagal, lanjutkan sisinya.
            print(f"  batch {i // 50} gagal ({str(exc)[:90]}), coba per judul", flush=True)
            bodies = []
            for title in batch:
                try:
                    one = api({"action": "query", "export": "1", "exportnowrap": "1",
                               "titles": title, "format": "json"}, tries=3)
                    if isinstance(one, dict):
                        raise RuntimeError(str(one)[:100])
                    bodies.append(strip_wrapper(one))
                except Exception as one_exc:
                    bad_titles.append(title)
                    print(f"  SKIP halaman: {title} ({str(one_exc)[:60]})", flush=True)
            body = XML_HEADER + "\n" + "\n".join(bodies) + "\n</mediawiki>\n"
        with open(part, "w", encoding="utf-8") as fh:
            fh.write(body)
        print(f"  export {min(i + 50, len(titles))}/{len(titles)}", flush=True)

    with open(os.path.join(xml_dir, "skipped_pages.json"), "w", encoding="utf-8") as fh:
        json.dump(bad_titles, fh, indent=2)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(XML_HEADER + "\n")
        written = 0
        for name in sorted(n for n in os.listdir(parts_dir) if n.endswith(".xml")):
            with open(os.path.join(parts_dir, name), encoding="utf-8") as src:
                fh.write(strip_wrapper(src.read()) + "\n")
            written += 1
        fh.write("</mediawiki>\n")
    print(f"  combined {written} parts -> {path}", flush=True)
    return path, len(titles)


def download_images(out_dir, limit):
    img_root = os.path.join(out_dir, "images")
    os.makedirs(img_root, exist_ok=True)
    cont, downloaded, skipped, total_bytes = {}, 0, 0, 0
    failed = []
    while True:
        params = {"action": "query", "list": "allimages", "ailimit": "500",
                  "aiprop": "url|size", "format": "json"}
        params.update(cont)
        d = api(params)
        for im in d.get("query", {}).get("allimages", []):
            if limit and downloaded >= limit:
                break
            url = im["url"].replace("https://", "http://", 1)
            rel = urllib.parse.urlparse(url).path[len("/wiki/images/"):]
            target = os.path.join(img_root, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                if os.path.exists(target) and os.path.getsize(target) == int(im.get("size", 0)):
                    skipped += 1
                    continue
            except (TypeError, ValueError):
                pass
            for attempt in range(4):
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=60) as response:
                        data = response.read()
                    with open(target, "wb") as fh:
                        fh.write(data)
                    total_bytes += len(data)
                    downloaded += 1
                    break
                except urllib.error.HTTPError as http_exc:
                    if http_exc.code in (404, 410):
                        # File dihapus dari server tapi masih terdaftar di allimages.
                        failed.append(im["name"])
                        break
                    if attempt == 3:
                        failed.append(im["name"])
                        print(f"  FAILED {im['name']}: {http_exc}", flush=True)
                    time.sleep(2 + 2 * attempt)
                except Exception as exc:
                    if attempt == 3:
                        failed.append(im["name"])
                        print(f"  FAILED {im['name']}: {exc}", flush=True)
                    time.sleep(2 + 2 * attempt)
            if downloaded and downloaded % 200 == 0:
                print(f"  images {downloaded}", flush=True)
        if limit and downloaded + len(failed) >= limit:
            break
        if "continue" not in d:
            break
        cont = d["continue"]
    return downloaded, skipped, total_bytes, failed


def main():
    global API
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--pages", type=int, default=0)
    ap.add_argument("--images", type=int, default=0)
    ap.add_argument("--skip-images", action="store_true")
    args = ap.parse_args()
    API = args.api
    os.makedirs(args.out, exist_ok=True)

    print("Export halaman (checkpoint per 50 judul) ...", flush=True)
    xml_path, pages = export_pages(args.out, args.pages)
    print(f"XML: {xml_path} ({pages} halaman)", flush=True)

    downloaded = skipped = total_bytes = 0
    failed = []
    if not args.skip_images:
        print("Download gambar ...", flush=True)
        downloaded, skipped, total_bytes, failed = download_images(args.out, args.images)
    with open(os.path.join(args.out, "failed_images.json"), "w", encoding="utf-8") as fh:
        json.dump(failed, fh, indent=2)

    manifest = {
        "api": API,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "xml": xml_path,
        "pages": pages,
        "images_downloaded": downloaded,
        "images_skipped": skipped,
        "images_failed": len(failed),
        "image_bytes": total_bytes,
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
__ONNOWIKI_EOF_3__

cat > scripts/nightly_sync.py <<'__ONNOWIKI_EOF_4__'
#!/usr/bin/env python3
"""Nightly incremental sync of the local OnnoWiki replica via MediaWiki API.

Source has no working public SQL dump, so this uses recentchanges + upload logs:
  - changed pages: fetch wikitext, compare with local, edit only when different
  - uploaded files: download to a flat staging dir, importImages --overwrite
  - deletions: logged only (never deletes local content)

State lives on the mounted backupstore so it survives container rebuilds.
"""
import argparse
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

SOURCE = os.environ.get("WIKI_SOURCE_API", "http://onnocenter.or.id/wiki/api.php")
LOCAL = os.environ.get("WIKI_LOCAL_API", "http://127.0.0.1/wiki/api.php")
BACKUP = "/mnt/backupstore/wiki-replica"
STATE_DIR = os.environ.get("WIKI_STATE_DIR", "/var/lib/wiki-sync")
STATE = os.path.join(STATE_DIR, "state.json")
STAGE = os.path.join(STATE_DIR, "pending-images")
PHP = "php"
MW = os.environ.get("WIKI_MAINTENANCE_DIR", "/var/www/html/wiki/maintenance")
UA = "OnnoWiki-nightly-sync/1.0"


def fetch(url, tries=6, timeout=45, as_json=True):
    last = "unknown"
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read().decode("utf-8", "replace")
            if "technical difficulties" in body or "Cannot access the database" in body:
                raise RuntimeError("source DB error")
            return json.loads(body) if as_json else body
        except Exception as exc:
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(min(25, 2 + 3 * attempt))
    raise RuntimeError(last)


def api(base, params, **kwargs):
    return fetch(base + "?" + urllib.parse.urlencode(params), **kwargs)


def changes_since(since, until, kind):
    seen, cont = [], {}
    while True:
        if kind == "edit":
            params = {"action": "query", "list": "recentchanges", "rcstart": until,
                      "rcend": since, "rclimit": "500",
                      "rcprop": "title|timestamp|type", "format": "json"}
            key = "recentchanges"
        else:
            params = {"action": "query", "list": "logevents", "letype": "upload",
                      "lestart": until, "leend": since, "lelimit": "500",
                      "leprop": "title|timestamp", "format": "json"}
            key = "logevents"
        params.update(cont)
        data = api(SOURCE, params)
        for row in data.get("query", {}).get(key, []):
            seen.append((row["title"], row.get("timestamp", "")))
        if "continue" not in data:
            break
        cont = data["continue"]
    # uniq by title, keep newest timestamp
    out = {}
    for title, ts in seen:
        if title not in out or ts > out[title]:
            out[title] = ts
    return out


def source_wikitext(title):
    try:
        d = api(SOURCE, {"action": "query", "prop": "revisions", "titles": title,
                         "rvprop": "content", "rvslots": "main", "format": "json",
                         "formatversion": "2"}, tries=4)
        page = d.get("query", {}).get("pages", [{}])[0]
        if "error" in d or not page.get("revisions"):
            raise RuntimeError("no revisions")
        return page["revisions"][0]["slots"]["main"]["content"]
    except Exception:
        d = api(SOURCE, {"action": "query", "prop": "revisions", "titles": title,
                         "rvprop": "ids", "rvlimit": "1", "format": "json"}, tries=4)
        page = next(iter(d.get("query", {}).get("pages", {}).values()), {})
        revid = (page.get("revisions") or [{}])[0].get("revid")
        if not revid:
            return None
        d2 = api(SOURCE, {"action": "parse", "oldid": revid, "prop": "wikitext",
                          "format": "json"}, tries=4)
        return d2.get("parse", {}).get("wikitext", {}).get("*")


def local_wikitext(title):
    try:
        d = api(LOCAL, {"action": "query", "prop": "revisions", "titles": title,
                        "rvprop": "content", "rvslots": "main", "format": "json",
                        "formatversion": "2"}, tries=2)
        page = d.get("query", {}).get("pages", [{}])[0]
        if page.get("missing") or not page.get("revisions"):
            return None
        return page["revisions"][0]["slots"]["main"]["content"]
    except Exception:
        return None


def edit_page(title, text):
    cmd = [PHP, os.path.join(MW, "edit.php"), "--user", "Maintenance script",
           "--summary", "Auto-sync dari OnnoWiki", title]
    done = subprocess.run(cmd, input=text.encode("utf-8"),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if done.returncode != 0:
        raise RuntimeError(done.stdout.decode("utf-8", "replace")[-400:])
    return True


def sync_file(title):
    d = api(SOURCE, {"action": "query", "titles": title, "prop": "imageinfo",
                     "iiprop": "url|size", "format": "json", "formatversion": "2"}, tries=4)
    page = d.get("query", {}).get("pages", [{}])[0]
    info = (page.get("imageinfo") or [{}])[0]
    url = info.get("url")
    if not url:
        return False
    url = url.replace("https://", "http://", 1)
    name = os.path.basename(urllib.parse.urlparse(url).path)
    os.makedirs(STAGE, exist_ok=True)
    target = os.path.join(STAGE, name)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = response.read()
    with open(target, "wb") as fh:
        fh.write(data)
    subprocess.run([PHP, os.path.join(MW, "importImages.php"),
                    "--overwrite", "--user", "Maintenance script", STAGE],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    os.remove(target)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", help="override timestamp UTC, untuk uji coba")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    os.makedirs(STATE_DIR, exist_ok=True)

    state = {}
    if os.path.exists(STATE):
        try:
            state = json.load(open(STATE))
        except Exception:
            state = {}
    since = args.since or state.get("last_timestamp") or \
        (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    until = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{until}] sync sejak {since}", flush=True)

    edits = changes_since(since, until, "edit")
    uploads = changes_since(since, until, "upload")
    print(f"  halaman berubah: {len(edits)} | upload baru: {len(uploads)}", flush=True)

    updated, same, failed = [], [], []
    for title in edits:
        try:
            text = source_wikitext(title)
            if text is None:
                failed.append(title)
                continue
            if local_wikitext(title) == text:
                same.append(title)
                continue
            if not args.dry_run:
                edit_page(title, text)
            updated.append(title)
        except Exception as exc:
            failed.append(title)
            print(f"  GAGAL {title}: {str(exc)[:120]}", flush=True)

    for title in uploads:
        try:
            if not args.dry_run:
                sync_file(title)
            updated.append(title)
        except Exception as exc:
            failed.append(title)
            print(f"  GAGAL upload {title}: {str(exc)[:120]}", flush=True)

    if not args.dry_run:
        state = {"last_timestamp": until, "last_run": until,
                 "pages_updated": updated, "pages_unchanged": same,
                 "failed": failed, "uploads": list(uploads)}
        with open(STATE, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)
    print(f"  updated={len(updated)} unchanged={len(same)} failed={len(failed)}", flush=True)


if __name__ == "__main__":
    main()
__ONNOWIKI_EOF_4__

cat > KNOWN_GAPS.md <<'__ONNOWIKI_EOF_5__'
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
__ONNOWIKI_EOF_5__

cat > README.md <<'__ONNOWIKI_EOF_6__'
# Replikasi OnnoWiki — sekali tempel, langsung jadi

Repositori ini berisi cara mereplikasi **OnnoWiki** (onnocenter.or.id/wiki) ke MediaWiki lokal
tanpa perlu bantuan AI, tanpa dump SQL, dan tanpa akses ke server sumber.

Sumber: https://onnocenter.or.id/wiki/ · konten SpeedyWiki/OnnoWiki dinyatakan bebas diambil.
**Berikan atribusi ke OnnoWiki/SpeedyWiki di wiki lokal Anda.**

## Cara pakai (Debian/Ubuntu)

```bash
curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh | sudo bash
```

Selesai. Buka **http://localhost:8080/wiki/**.

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
curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh | sudo bash
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
__ONNOWIKI_EOF_6__

cat > update.sh <<'__ONNOWIKI_EOF_7__'
#!/bin/bash
# Update inkremental dari OnnoWiki ke wiki lokal.
set -euo pipefail
cd "$(dirname "$0")"

docker compose exec -T \
  -e WIKI_LOCAL_API=http://127.0.0.1/wiki/api.php \
  -e WIKI_STATE_DIR=/workspace/state \
  -e WIKI_MAINTENANCE_DIR=/var/www/html/wiki/maintenance \
  wiki python3 /workspace/scripts/nightly_sync.py
__ONNOWIKI_EOF_7__

chmod +x scripts/*.py

if [ ! -f wiki/index.php ]; then
  log "Mengunduh MediaWiki 1.43.12"
  curl -fsSL https://releases.wikimedia.org/mediawiki/1.43/mediawiki-1.43.12.tar.gz -o mw.tar.gz
  tar xzf mw.tar.gz
  cp -a mediawiki-1.43.12/. wiki/
  rm -rf mediawiki-1.43.12 mw.tar.gz
fi

log "Menjalankan container"
docker compose up -d --build
until docker compose exec -T wiki php -r 'echo 1;' >/dev/null 2>&1; do sleep 2; done

if [ ! -f wiki/LocalSettings.php ]; then
  log "Instalasi MediaWiki pertama kali"
  docker compose exec -T wiki php /var/www/html/wiki/maintenance/install.php \
    --dbname wikidb --dbuser wikiuser --dbpass wikipassword --dbserver db \
    --servername http://localhost:8080 --scriptpath /wiki --lang en \
    --pass '**************' 'OnnoWiki Lokal' 'Admin'
fi

EXTRA=""
[ -n "${PAGES:-}" ] && EXTRA="$EXTRA --pages $PAGES"
[ -n "${IMAGES:-}" ] && EXTRA="$EXTRA --images $IMAGES"

log "Mengambil halaman + gambar dari OnnoWiki"
# shellcheck disable=SC2086
docker compose exec -T wiki python3 /workspace/scripts/fetch_wiki.py \
  --api http://onnocenter.or.id/wiki/api.php --out /workspace/data $EXTRA

log "Menyalin gambar ke folder upload"
docker compose exec -T wiki bash -c \
  'mkdir -p /var/www/html/wiki/images && cp -a /workspace/data/images/. /var/www/html/wiki/images/ && chown -R www-data:www-data /var/www/html/wiki/images'

log "Import XML"
XML=$(docker compose exec -T wiki sh -c 'ls -1 /workspace/data/xml/wiki-*.xml | tail -1' | tr -d '\r')
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importDump.php "$XML" || true

log "Daftarkan gambar ke database"
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importImages.php \
  --search-recursively --skip-dupes --user 'Maintenance script' /workspace/data/images || true

docker compose exec -T wiki php /var/www/html/wiki/maintenance/initSiteStats.php --update

log "SELESAI"
echo "Buka       : http://localhost:8080/wiki/"
echo "Folder     : $DIR"
echo "Update     : cd $DIR && ./update.sh   (atau jalankan scripts/nightly_sync.py)"
echo "Catatan    : baca KNOWN_GAPS.md untuk halaman/gambar yang memang kosong di sumber."
