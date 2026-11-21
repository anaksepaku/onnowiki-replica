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
