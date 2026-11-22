#!/bin/bash
# Timpa halaman utama bawaan MediaWiki dengan Main Page dari OnnoWiki.
# Dijalankan di dalam container wiki.
set -euo pipefail

cd /var/www/html/wiki/maintenance

curl -fsSL --max-time 45 \
  'http://onnocenter.or.id/wiki/api.php?action=query&prop=revisions&titles=Main_Page&rvprop=content&rvslots=main&format=json&formatversion=2' \
  | php -r '$d=json_decode(file_get_contents("php://stdin"),true); echo $d["query"]["pages"][0]["revisions"][0]["slots"]["main"]["content"];' \
  > /tmp/mainpage.txt

if [ ! -s /tmp/mainpage.txt ]; then
  echo "Gagal mengambil Main Page dari sumber" >&2
  exit 1
fi

php edit.php --user 'Maintenance script' \
  --summary 'Import Main Page dari OnnoWiki' \
  'Main Page' < /tmp/mainpage.txt

rm -f /tmp/mainpage.txt
