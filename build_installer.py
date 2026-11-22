from pathlib import Path

base = Path("/home/iful/wiki-replica/publish")
files = [
    ("Dockerfile", "Dockerfile"),
    ("docker-compose.yml", "docker-compose.yml"),
    ("scripts/fetch_wiki.py", "scripts/fetch_wiki.py"),
    ("scripts/nightly_sync.py", "scripts/nightly_sync.py"),
    ("scripts/fix_mainpage.sh", "scripts/fix_mainpage.sh"),
    ("KNOWN_GAPS.md", "KNOWN_GAPS.md"),
    ("README.md", "README.md"),
    ("update.sh", "update.sh"),
    ("install-full.sh", "install-full.sh"),
    ("uninstall.sh", "uninstall.sh"),
    ("CHANGELOG.md", "CHANGELOG.md"),
    ("LICENSE", "LICENSE"),
]

head = r'''#!/bin/bash
# Replikasi OnnoWiki dalam satu perintah:
#   curl -fsSL -H 'Accept: application/vnd.github.raw+json' "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-onnowiki.sh?ref=main&cb=$(date +%s)" | sudo bash
#
# Opsi (export dulu sebelum pipe):
#   export PAGES=5 IMAGES=3   # smoke test cepat (pakai sudo -E agar env ikut)
#   export ONNOWIKI_DIR=/srv/onnowiki-replica
set -euo pipefail

DIR="${ONNOWIKI_DIR:-$HOME/onnowiki-replica}"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Script ini butuh root untuk memasang Docker."
  echo "Jalankan: curl -fsSL -H 'Accept: application/vnd.github.raw+json' "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-onnowiki.sh?ref=main&cb=$(date +%s)" | sudo bash"
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

LOG_FILE="$DIR/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Menulis file ke $DIR"
'''

write_blocks = []
for i, (src, dest) in enumerate(files, 1):
    content = (base / src).read_text(encoding="utf-8")
    delim = f"__ONNOWIKI_EOF_{i}__"
    write_blocks.append(f"cat > {dest} <<'{delim}'\n{content.rstrip()}\n{delim}\n\n")

tail = r'''chmod +x *.sh scripts/*.sh scripts/*.py

WG_BIND_IP="${WG_BIND_IP:-127.0.0.1}"
WG_PORT="${WG_PORT:-8080}"
WG_SERVER_URL="${WG_SERVER_URL:-http://${WG_BIND_IP}:${WG_PORT}}"
sed -i "s|127.0.0.1:8080:80|${WG_BIND_IP}:${WG_PORT}:80|" docker-compose.yml
sed -i "s|192.0.2.73:8080:80|${WG_BIND_IP}:${WG_PORT}:80|" docker-compose.yml

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
  ADMIN_PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-16)
  [ -n "$ADMIN_PASS" ] || ADMIN_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
  docker compose exec -T wiki php /var/www/html/wiki/maintenance/install.php \
    --dbname wikidb --dbuser wikiuser --dbpass wikipassword --dbserver db \
    --servername "$WG_SERVER_URL" --scriptpath /wiki --lang en \
    --pass "$ADMIN_PASS" 'Admin' 'OnnoWiki Lokal'
  # install.php sering mengabaikan --servername; paksa di LocalSettings.php
  sed -i "s|^\$wgServer = .*|\$wgServer = \"$WG_SERVER_URL\";|" wiki/LocalSettings.php
  cat >> wiki/LocalSettings.php <<'PERMS'

# Replika OnnoWiki: pengunjung anonim hanya boleh membaca.
$wgGroupPermissions['*']['edit'] = false;
$wgGroupPermissions['*']['createpage'] = false;
$wgGroupPermissions['*']['createtalk'] = false;
PERMS
  cat > ADMIN_CREDENTIALS.txt <<EOF
Wiki     : $WG_SERVER_URL/wiki/
User     : Admin
Password : $ADMIN_PASS
EOF
  chmod 600 ADMIN_CREDENTIALS.txt
  echo ">> Login admin : Admin / $ADMIN_PASS"
  echo ">> Tersimpan juga di $DIR/ADMIN_CREDENTIALS.txt (0600)"
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
IMPORT_RC=0
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importDump.php "$XML" || IMPORT_RC=$?
if [ "$IMPORT_RC" -ne 0 ]; then echo "!! importDump gagal (rc=$IMPORT_RC) — cek log di dalam container" >&2; fi

log "Timpa Main Page bawaan dengan Main Page OnnoWiki"
MP_RC=0
docker compose exec -T wiki bash /workspace/scripts/fix_mainpage.sh || MP_RC=$?
if [ "$MP_RC" -ne 0 ]; then echo "!! Main Page gagal ditimpa (rc=$MP_RC)" >&2; fi

log "Daftarkan gambar ke database"
IMG_RC=0
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importImages.php \
  --search-recursively --skip-dupes --user 'Maintenance script' /workspace/data/images || IMG_RC=$?
if [ "$IMG_RC" -ne 0 ]; then echo "!! importImages gagal (rc=$IMG_RC)" >&2; fi

docker compose exec -T wiki php /var/www/html/wiki/maintenance/initSiteStats.php --update

log "Bersihkan parser cache (agar gambar tidak broken)"
PC_RC=0
docker compose exec -T wiki php /var/www/html/wiki/maintenance/purgeParserCache.php --age 0 >/dev/null 2>&1 || PC_RC=$?
if [ "$PC_RC" -ne 0 ]; then echo "!! purgeParserCache gagal (rc=$PC_RC)" >&2; fi

STATS=$(curl -fsS --max-time 20 "$WG_SERVER_URL/wiki/api.php?action=query&meta=siteinfo&siprop=statistics&format=json" \
  | python3 -c 'import json,sys; s=json.load(sys.stdin)["query"]["statistics"]; print(f"pages={s[chr(112)+chr(97)+chr(103)+chr(101)+chr(115)]} articles={s[chr(97)+chr(114)+chr(116)+chr(105)+chr(99)+chr(108)+chr(101)+chr(115)]} images={s[chr(105)+chr(109)+chr(97)+chr(103)+chr(101)+chr(115)]}")' 2>/dev/null || echo 'statistik tidak terbaca')

log "SELESAI — GO LIVE"
echo "Buka       : $WG_SERVER_URL/wiki/"
echo "Statistik  : $STATS"
echo "Folder     : $DIR"
echo "Update     : cd $DIR && ./update.sh"
echo "Login      : $DIR/ADMIN_CREDENTIALS.txt (0600)"
echo "Catatan    : baca KNOWN_GAPS.md untuk halaman/gambar yang memang kosong di sumber."
'''

out = head + "\n" + "".join(write_blocks) + tail
target = base / "install-onnowiki.sh"
target.write_text(out, encoding="utf-8")
target.chmod(0o755)
print("written", target, len(out), "bytes")
