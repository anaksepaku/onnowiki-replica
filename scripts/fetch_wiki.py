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
