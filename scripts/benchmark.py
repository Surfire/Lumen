#!/usr/bin/env python3
"""Synthetic workload for Lumen's warm CLI/launcher transport; no private data read."""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entries", type=int, default=20000, choices=range(1000, 250001), metavar="1000–250000")
    ap.add_argument("--bin", type=Path, default=Path("target/release/lumen"))
    ns = ap.parse_args()
    binary = str(ns.bin.resolve())
    with tempfile.TemporaryDirectory(prefix="lumen-bench-", dir="/tmp") as tmp:
        root = Path(tmp) / "corpus"
        root.mkdir()
        cohorts = ["代谢研究", "房颤入组", "心脏影像", "循证规则", "随访安排", "合作分工", "药物监测"]
        folders = [root / "section-{:03d}".format(i) for i in range(100)]
        for folder in folders:
            folder.mkdir()
        for i in range(ns.entries):
            folder = folders[i % len(folders)]
            name = ("case-{:06d}" if i % 4 else cohorts[i % len(cohorts)] + "-{:06d}").format(i)
            (folder / (name + ".txt")).touch()
        argv = [binary, "--db", tmp + "/index.sqlite"]
        start = time.perf_counter()
        scan = json.loads(subprocess.check_output(argv + ["index", "--root", str(root)]))
        total_scan = (time.perf_counter() - start) * 1000
        p = subprocess.Popen(argv + ["serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        counter = 0
        def query(q):
            nonlocal counter
            counter += 1
            t = time.perf_counter_ns()
            p.stdin.write(json.dumps({"id": counter, "query": q, "limit": 20}) + "\n")
            p.stdin.flush()
            result = json.loads(p.stdout.readline())
            elapsed = (time.perf_counter_ns() - t) / 1_000_000
            assert result["id"] == counter and "hits" in result
            return elapsed, len(result["hits"])
        workloads = {
            "indexed_specific": ["000111", "000409", "000112", "000726", "000137", "000856"],
            "indexed_common": ["case-", "section", "循证规则", "随访安排", "房颤入组", "fangchanruzu"],
            "short_broad": ["a", "01", "方", "案", "ya", "心"],
            "indexed_no_match": ["qzzqzz", "无此结果", "never-found", "123no", "aaa909", "google-lumen"],
        }
        rows = {}
        try:
            for name, queries in workloads.items():
                for q in queries:
                    query(q)
                measurements = [query(q) for _ in range(12) for q in queries]
                values = sorted(t for t, _ in measurements)
                rows[name] = {"samples": len(values), "p50_ms": round(statistics.median(values), 3),
                    "p95_ms": round(values[(95 * len(values) + 99) // 100 - 1], 3),
                    "max_ms": round(values[-1],3), "samples_with_hits": sum(n > 0 for _,n in measurements)}
        finally:
            p.stdin.close()
            p.wait(timeout=5)
            p.stdout.close()
        print(json.dumps({"platform": platform.platform(), "entries": scan["items"],
            "files": ns.entries, "bulk_directories": scan["bulk_directories"],
            "fallback_directories": scan["fallback_directories"], "scan_wall_ms": round(total_scan, 2),
            "index_file_bytes": os.stat(tmp + "/index.sqlite").st_size,
            "engine_transport_query_limit": 20, "queries": rows}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
