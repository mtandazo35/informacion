#!/usr/bin/env python3
"""Analyze an M3U playlist file and produce a classification report.

Note: Originally requested at /tmp/m3u_analyze.py but on Windows the
working repo dir is writable. Logic is identical.
"""

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import urlparse

M3U_PATH = r"c:\Users\Manuel\Downloads\ececzzx26672new90824_lista.m3u"
OUT_JSON = r"c:\Users\Manuel\Documents\GitHub\informacion\.m3u_analysis.json"

# Patterns (uppercase for case-insensitive match). Order matters:
# 24/7 must be checked before MOVIES/SERIES because a 24/7 channel
# may also mention "PELICULAS" or "SERIES" in its group title.
BUCKETS_ORDER = [
    ("VOD_24_7", ["24/7", "24-7", "24 7"]),
    ("MOVIES",   ["PELICULA", "PELÍCULA", "CINE", "MOVIE", "FILME"]),
    ("SERIES",   ["SERIE", "SERIES"]),
    ("RADIO",    ["RADIO"]),
    ("EVENTS",   ["EVENTO", "PPV"]),
]

GROUP_RE = re.compile(r'group-title="([^"]*)"', re.IGNORECASE)
TVG_NAME_RE = re.compile(r'tvg-name="([^"]*)"', re.IGNORECASE)
TVG_ID_RE = re.compile(r'tvg-id="([^"]*)"', re.IGNORECASE)

URL_RE_STRICT = re.compile(
    r'^http://jfgh212cpppf6illo0\.com/[^/]+/[^/]+/[^/]+$'
)


def classify(group_title: str) -> str:
    g = group_title.upper()
    for bucket, keywords in BUCKETS_ORDER:
        for kw in keywords:
            if kw in g:
                return bucket
    return "LIVE_TV_OR_OTHER"


def main():
    p = Path(M3U_PATH)
    if not p.exists():
        print(f"ERROR: file not found: {M3U_PATH}", file=sys.stderr)
        sys.exit(1)

    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = p.read_text(encoding="latin-1")

    lines = text.splitlines()

    entries = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("#EXTINF"):
            gt_match = GROUP_RE.search(line)
            name_match = TVG_NAME_RE.search(line)
            id_match = TVG_ID_RE.search(line)
            group_title = gt_match.group(1) if gt_match else ""
            tvg_name = name_match.group(1) if name_match else ""
            tvg_id = id_match.group(1) if id_match else ""
            url = ""
            j = i + 1
            while j < len(lines):
                cand = lines[j].strip()
                if cand and not cand.startswith("#"):
                    url = cand
                    break
                j += 1
            entries.append({
                "group_title": group_title,
                "tvg_name": tvg_name,
                "tvg_id": tvg_id,
                "url": url,
            })
            i = j + 1 if j < len(lines) else j
        else:
            i += 1

    total_entries = len(entries)
    unique_categories = sorted({e["group_title"] for e in entries})

    bucket_counts = Counter()
    bucket_categories = defaultdict(set)

    for e in entries:
        gt = e["group_title"]
        b = classify(gt)
        if b == "LIVE_TV_OR_OTHER":
            if not gt.strip():
                b = "OTHER"
            else:
                b = "LIVE_TV"
        bucket_counts[b] += 1
        bucket_categories[b].add(gt)

    url_ok = 0
    url_exceptions = []
    url_host_counter = Counter()
    for e in entries:
        u = e["url"]
        try:
            host = urlparse(u).hostname or ""
        except Exception:
            host = ""
        url_host_counter[host] += 1
        if URL_RE_STRICT.match(u):
            url_ok += 1
        else:
            if len(url_exceptions) < 50:
                url_exceptions.append({
                    "tvg_name": e["tvg_name"],
                    "group_title": e["group_title"],
                    "url": u,
                })

    name_to_groups = defaultdict(set)
    for e in entries:
        if e["tvg_name"]:
            name_to_groups[e["tvg_name"]].add(e["group_title"])
    duplicates = {n: sorted(gs) for n, gs in name_to_groups.items() if len(gs) > 1}

    report = {
        "source_file": M3U_PATH,
        "total_entries": total_entries,
        "total_unique_categories": len(unique_categories),
        "bucket_counts": dict(bucket_counts),
        "bucket_categories": {
            b: sorted(cats) for b, cats in bucket_categories.items()
        },
        "bucket_categories_sample_20": {
            b: sorted(cats)[:20] for b, cats in bucket_categories.items()
        },
        "bucket_unique_category_counts": {
            b: len(cats) for b, cats in bucket_categories.items()
        },
        "url_format": {
            "pattern": r"^http://jfgh212cpppf6illo0\.com/<token>/<creds>/<id>$",
            "matching": url_ok,
            "exceptions_count": total_entries - url_ok,
            "exceptions_sample": url_exceptions[:25],
            "host_distribution": dict(url_host_counter),
        },
        "duplicates": {
            "count_tvg_names_with_multiple_groups": len(duplicates),
            "sample_50": dict(list(duplicates.items())[:50]),
        },
    }

    out = Path(OUT_JSON)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Total entries: {total_entries}")
    print(f"Total unique categories: {len(unique_categories)}")
    print("Bucket counts:")
    for b in ["LIVE_TV", "VOD_24_7", "MOVIES", "SERIES", "RADIO", "EVENTS", "OTHER"]:
        print(f"  {b}: {bucket_counts.get(b, 0)}  (unique categories: {len(bucket_categories.get(b, set()))})")
    print(f"URL format matching strict pattern: {url_ok}/{total_entries}")
    print(f"URL host distribution: {dict(url_host_counter)}")
    print(f"tvg-names appearing in multiple group-titles: {len(duplicates)}")
    print(f"Report saved to: {OUT_JSON}")


if __name__ == "__main__":
    main()
