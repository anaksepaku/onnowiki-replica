#!/bin/bash
# Update inkremental dari OnnoWiki ke wiki lokal.
set -euo pipefail
cd "$(dirname "$0")"

docker compose exec -T \
  -e WIKI_LOCAL_API=http://127.0.0.1/wiki/api.php \
  -e WIKI_STATE_DIR=/workspace/state \
  -e WIKI_MAINTENANCE_DIR=/var/www/html/wiki/maintenance \
  wiki python3 /workspace/scripts/nightly_sync.py
