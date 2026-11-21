from pathlib import Path

base = Path("/home/iful/wiki-replica/publish")
files = [
    ("Dockerfile", "Dockerfile"),
    ("docker-compose.yml", "docker-compose.yml"),
    ("scripts/fetch_wiki.py", "scripts/fetch_wiki.py"),
    ("scripts/nightly_sync.py", "scripts/nightly_sync.py"),
    ("KNOWN_GAPS.md", "KNOWN_GAPS.md"),
    ("README.md", "README.md"),
    ("update.sh", "update.sh"),
]

head = r'''#!/bin/bash
# Replikasi OnnoWiki dalam satu perintah:
#   curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh?plain=1 | sudo bash
#
# Opsi (export dulu sebelum pipe):
#   export PAGES=5 IMAGES=3   # smoke test cepat
#   export ONNOWIKI_DIR=/srv/onnowiki-replica
set -euo pipefail

DIR="${ONNOWIKI_DIR:-$HOME/onnowiki-replica}"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Script ini butuh root untuk memasang Docker."
  echo "Jalankan: curl -fsSL https://raw.githubusercontent.com/anaksepaku/onnowiki-replica/main/install-onnowiki.sh?plain=1 | sudo bash"
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
'''

write_blocks = []
for i, (src, dest) in enumerate(files, 1):
    content = (base / src).read_text(encoding="utf-8")
    delim = f"__ONNOWIKI_EOF_{i}__"
    write_blocks.append(f"cat > {dest} <<'{delim}'\n{content.rstrip()}\n{delim}\n\n")

tail = r'''chmod +x scripts/*.py

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
'''

out = head + "\n" + "".join(write_blocks) + tail
target = base / "install-onnowiki.sh"
target.write_text(out, encoding="utf-8")
target.chmod(0o755)
print("written", target, len(out), "bytes")
