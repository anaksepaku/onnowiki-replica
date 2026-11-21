#!/bin/bash
# Install bersih + FULL import (tanpa mode smoke).
# Dipakai untuk menguji alur lengkap dari nol sampai wiki siap dipakai.
set -euo pipefail

unset PAGES IMAGES   # pastikan tidak ada mode smoke yang tertinggal

export ONNOWIKI_DIR="${ONNOWIKI_DIR:-/root/onnowiki-replica-full}"
export WG_BIND_IP="${WG_BIND_IP:-127.0.0.1}"
export WG_PORT="${WG_PORT:-8080}"
export WG_SERVER_URL="${WG_SERVER_URL:-http://${WG_BIND_IP}:${WG_PORT}}"

TMP=$(mktemp /tmp/onnowiki-full-XXXXXX.sh)
trap 'rm -f "$TMP"' EXIT

printf '\n==> Mengunduh installer terbaru dari GitHub\n'
curl -fsSL -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/anaksepaku/onnowiki-replica/contents/install-onnowiki.sh?ref=main&cb=$(date +%s)" \
  -o "$TMP"
chmod +x "$TMP"

printf '\n==> Menjalankan install + full import ke %s\n' "$ONNOWIKI_DIR"
bash "$TMP"

printf '\n==> Verifikasi akhir\n'
STATS=$(curl -fsS --max-time 20 \
  "$WG_SERVER_URL/wiki/api.php?action=query&meta=siteinfo&siprop=statistics&format=json" \
  | python3 -c 'import json,sys; s=json.load(sys.stdin)["query"]["statistics"]; print(s["pages"], s["images"])')
PAGES_FINAL=${STATS%% *}
IMAGES_FINAL=${STATS##* }
printf 'pages=%s images=%s\n' "$PAGES_FINAL" "$IMAGES_FINAL"

if [ "$PAGES_FINAL" -ge 18000 ] && [ "$IMAGES_FINAL" -ge 6400 ]; then
  printf 'FULL_IMPORT=PASS\n'
else
  printf 'FULL_IMPORT=FAIL (expected pages>=18000 images>=6400)\n' >&2
  exit 1
fi

printf 'LOG      : %s/install.log\n' "$ONNOWIKI_DIR"
printf 'CREDS    : %s/ADMIN_CREDENTIALS.txt (0600)\n' "$ONNOWIKI_DIR"
printf 'URL      : %s/wiki/\n' "$WG_SERVER_URL"
