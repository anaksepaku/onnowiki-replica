#!/bin/bash
# Replikasi OnnoWiki -> MediaWiki lokal. Cukup pakai Docker, tidak butuh AI.
set -euo pipefail
cd "$(dirname "$0")"

MW_VERSION="1.43.12"
MW_TAR="mediawiki-${MW_VERSION}.tar.gz"
MW_URL="https://releases.wikimedia.org/mediawiki/1.43/${MW_TAR}"
API="http://onnocenter.or.id/wiki/api.php"

mkdir -p wiki data state

if [ ! -f wiki/index.php ]; then
  echo ">> Mengunduh MediaWiki ${MW_VERSION} ..."
  curl -fsSL "$MW_URL" -o "$MW_TAR"
  mkdir -p wiki
  tar xzf "$MW_TAR"
  cp -a "mediawiki-${MW_VERSION}/." wiki/
  rm -rf "mediawiki-${MW_VERSION}" "$MW_TAR"
fi

echo ">> Menjalankan container ..."
docker compose up -d --build

until docker compose exec -T wiki php -r 'echo 1;' >/dev/null 2>&1; do sleep 2; done

if [ ! -f wiki/LocalSettings.php ]; then
  echo ">> Instalasi MediaWiki pertama kali ..."
  docker compose exec -T wiki php /var/www/html/wiki/maintenance/install.php \
    --dbname wikidb --dbuser wikiuser --dbpass wikipassword --dbserver db \
    --servername http://localhost:8080 --scriptpath /wiki --lang en \
    --pass '**************' 'OnnoWiki Lokal' 'Admin'
fi

EXTRA=""
[ -n "${PAGES:-}" ] && EXTRA="$EXTRA --pages $PAGES"
[ -n "${IMAGES:-}" ] && EXTRA="$EXTRA --images $IMAGES"

echo ">> Mengambil halaman + gambar dari OnnoWiki (bisa beberapa menit) ..."
# shellcheck disable=SC2086
docker compose exec -T wiki python3 /workspace/scripts/fetch_wiki.py \
  --api "$API" --out /workspace/data $EXTRA

echo ">> Menyalin gambar ke folder upload ..."
docker compose exec -T wiki bash -c \
  'mkdir -p /var/www/html/wiki/images && cp -a /workspace/data/images/. /var/www/html/wiki/images/ && chown -R www-data:www-data /var/www/html/wiki/images'

echo ">> Import XML ..."
XML=$(docker compose exec -T wiki sh -c 'ls -1 /workspace/data/xml/wiki-*.xml | tail -1' | tr -d '\r')
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importDump.php "$XML" || true

echo ">> Daftarkan gambar ke database ..."
docker compose exec -T wiki php /var/www/html/wiki/maintenance/importImages.php \
  --search-recursively --skip-dupes --user 'Maintenance script' /workspace/data/images || true

docker compose exec -T wiki php /var/www/html/wiki/maintenance/initSiteStats.php --update

echo
echo "SELESAI. Buka: http://localhost:8080/wiki/"
echo "Admin: lihat Special:ListUsers di wiki lokal (kata sandi: ***"
