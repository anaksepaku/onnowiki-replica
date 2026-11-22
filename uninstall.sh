#!/bin/bash
# Hapus instalasi OnnoWiki lokal beserta container, volume, dan network.
# Cara pakai: bash uninstall.sh /root/onnowiki-replica-full
set -euo pipefail

DIR="${1:-${ONNOWIKI_DIR:-/root/onnowiki-replica-full}}"
BASE=$(basename "$DIR")

echo "Target : $DIR"
echo "Project: $BASE"
read -r -p "Hapus folder + container + volume + network ini? [y/N] " jawab
if [ "$jawab" != "y" ] && [ "$jawab" != "Y" ]; then
  echo "Dibatalkan."
  exit 1
fi

if [ -f "$DIR/docker-compose.yml" ]; then
  echo ">> docker compose down -v"
  (cd "$DIR" && docker compose down -v) || true
fi

# Fallback kalau folder sudah terhapus lebih dulu / compose tidak bisa dijalankan.
IDS=$(docker ps -a --format '{{.ID}} {{.Names}}' | grep -F -- "$BASE" | awk '{print $1}' || true)
if [ -n "$IDS" ]; then
  echo ">> menghapus container yatim: $IDS"
  # shellcheck disable=SC2086
  docker rm -f $IDS || true
fi

VOLS=$(docker volume ls --format '{{.Name}}' | grep -F -- "$BASE" || true)
if [ -n "$VOLS" ]; then
  echo ">> menghapus volume: $VOLS"
  # shellcheck disable=SC2086
  docker volume rm $VOLS || true
fi

NETS=$(docker network ls --format '{{.Name}}' | grep -F -- "$BASE" || true)
if [ -n "$NETS" ]; then
  echo ">> menghapus network: $NETS"
  # shellcheck disable=SC2086
  docker network rm $NETS || true
fi

echo ">> menghapus folder $DIR"
rm -rf "$DIR"

echo "SELESAI."
docker ps -a --format '{{.Names}}' | grep -F -- "$BASE" || echo "container: tidak ada"
ss -ltn 2>/dev/null | grep 8080 || echo "port 8080: bebas"
