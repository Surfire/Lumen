#!/usr/bin/env python3
"""Real-filesystem, name-only persistent-serve benchmark; synthetic data only."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import threading
import time


COHORTS = [("代谢研究", "daixieyanjiu"), ("房颤入组", "fangchanruzu"),
           ("心脏影像", "xinzangyingxiang"), ("循证规则", "xunzhengguize"),
           ("随访安排", "suifanganpai"), ("合作分工", "hezuofengong"),
           ("药物监测", "yaowujiance")]


def relative_name(i):
    prefix = COHORTS[i % len(COHORTS)][0] if i % 4 == 0 else "case"
    return Path(f"section-{i % 100:03d}") / f"{prefix}-{i:07d}-alpha report.txt"


def prepare(work, entries):
    root = work / "corpus"
    marker = work / "corpus.json"
    if marker.exists():
        assert json.loads(marker.read_text()) == {"version": 2, "files": entries}
        return root, None
    start = time.perf_counter()
    root.mkdir(parents=True)
    for i in range(100):
        (root / f"section-{i:03d}").mkdir()
    for i in range(entries):
        (root / relative_name(i)).touch()
    elapsed = (time.perf_counter() - start) * 1000
    marker.write_text(json.dumps({"version": 2, "files": entries}))
    return root, elapsed


def summary(values):
    values = sorted(values)
    return {"samples": len(values), "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(values[math.ceil(.95 * len(values)) - 1], 3),
            "p99_ms": round(values[math.ceil(.99 * len(values)) - 1], 3),
            "max_ms": round(values[-1], 3)}


def rss_kib(pid):
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip())


class Session:
    def __init__(self, argv):
        self.process = subprocess.Popen(argv + ["serve"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True, bufsize=1)
        self.counter = 0

    def query(self, text, expected=None):
        self.counter += 1
        start = time.perf_counter_ns()
        self.process.stdin.write(json.dumps({"id": self.counter, "query": text,
                                           "mode": "name", "limit": 20}) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"serve exited: {self.process.poll()}")
        result = json.loads(line)
        elapsed = (time.perf_counter_ns() - start) / 1_000_000
        assert result["id"] == self.counter and "hits" in result, result
        if expected is not None:
            assert str(expected) in [h["path"] for h in result["hits"]], (text, result)
        return elapsed, result["hits"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()


def benchmark(ns, work):
    root, generation_ms = prepare(work, ns.entries)
    if ns.prepare_only:
        return {"files": ns.entries, "generation_ms": generation_ms, "prepared": str(work)}
    # Restore only the known synthetic update batch for reproducible reruns.
    mutated = (root / "update-created-000.txt").exists()
    if mutated:
        assert not ns.reuse_index, "updated corpus requires a fresh scan (omit --reuse-index)"
        for i in range(100):
            old = root / relative_name(ns.entries - 1 - i)
            renamed = old.with_suffix(".renamed")
            if renamed.exists():
                renamed.rename(old)
            (root / f"update-created-{i:03d}.txt").unlink(missing_ok=True)
        for i in range(100, 200):
            (root / relative_name(ns.entries - 1 - i)).touch()
    # Two uncounted control files prove asynchronous RAM readiness: the SQL
    # fallback orders by width, whereas SoA puts the longer, newer prefix first.
    controls = [root / "soa-readiness-a.txt", root / "soa-readiness-longer-new.txt"]
    for path, timestamp in zip(controls, [946684800, 1735689600]):
        path.touch()
        os.utime(path, (timestamp, timestamp))
    binary = ns.bin.resolve()
    argv = [str(binary), "--db", str(work / "index.sqlite")]
    scan_command = argv + ["index", "--root", str(root), "--separate-content"]
    if ns.reuse_index:
        scan_result = json.loads((work / "scan.json").read_text())
    else:
        start = time.perf_counter()
        scan = json.loads(subprocess.check_output(scan_command))
        scan_result = {"scan_wall_ms": round((time.perf_counter() - start) * 1000, 2),
                       "scan": scan}
        (work / "scan.json").write_text(json.dumps(scan_result))
    result = {"platform": platform.platform(), "machine": platform.machine(),
              "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
              "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"])),
              "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "files": ns.entries, "readiness_control_files": 2,
              "generation_ms": generation_ms, **scan_result,
              "index_file_bytes": (work / "index.sqlite").stat().st_size,
              "transport": "persistent serve JSONL, mode=name, limit=20", "seed": 404,
              "distinct_queries_per_class": 50, "repeats": ns.repeats}
    if ns.scan_only:
        return result
    workloads = {name: [] for name in ("name", "chinese", "pinyin", "multiword")}
    for j in range(50):
        latin = 101 + j * 8
        chinese = j * 4
        for kind, text, i in [
            ("name", f"case-{latin:07d}", latin),
            ("chinese", f"{COHORTS[chinese % 7][0]}-{chinese:07d}", chinese),
            ("pinyin", f"{COHORTS[chinese % 7][1]}{chinese:07d}", chinese),
            ("multiword", f"{latin:07d} report", latin),
        ]:
            workloads[kind].append((text, root / relative_name(i)))
    session = Session(argv)
    try:
        start = time.perf_counter()
        session.query(*workloads["name"][0])
        result["serve_start_to_first_reply_ms"] = round((time.perf_counter() - start) * 1000, 2)
        ready_start = time.perf_counter()
        deadline = time.monotonic() + 180
        readiness_probes = 0
        while True:
            _, hits = session.query("soa-readiness-")
            readiness_probes += 1
            if hits and hits[0]["path"] == str(controls[1]):
                break
            assert time.monotonic() < deadline, "SoA never became ready (SQL ranks shorter control first)"
            time.sleep(.05)
        result["soa_readiness"] = {"longer_newer_control_ranked_first": True,
                                   "probes": readiness_probes,
                                   "wait_ms": round((time.perf_counter() - ready_start) * 1000, 2)}
        for queries in workloads.values():
            for text, expected in queries:
                session.query(text, expected)
        # The SoA index builds asynchronously. Sample one-second windows until
        # both RSS and probe latency plateau, rather than timing the SQL fallback.
        warmup = []
        deadline = time.monotonic() + 180
        while True:
            probes = [session.query(text, expected)[0]
                      for text, expected in workloads["name"][:10]]
            warmup.append({"rss_kib": rss_kib(session.process.pid),
                           "probe_median_ms": round(statistics.median(probes), 3)})
            if len(warmup) >= 4:
                recent = warmup[-4:]
                memory = [sample["rss_kib"] for sample in recent]
                latency = [sample["probe_median_ms"] for sample in recent]
                if (max(memory) - min(memory) < 1024
                        and max(latency) - min(latency) <= max(1, min(latency) * .2)):
                    break
            assert time.monotonic() < deadline, ("serve did not stabilize", warmup)
            time.sleep(1)
        result["warmup_one_second_samples"] = warmup
        result["serve_rss_warm_kib"] = rss_kib(session.process.pid)
        schedule = [(kind, query) for _ in range(ns.repeats)
                    for kind, queries in workloads.items() for query in queries]
        random.Random(404).shuffle(schedule)
        rows = {kind: [] for kind in workloads}
        for kind, (text, expected) in schedule:
            elapsed, _ = session.query(text, expected)
            rows[kind].append(elapsed)
        result["queries"] = {kind: {**summary(values), "expected_top20": len(values)}
                             for kind, values in rows.items()}
        result["serve_rss_after_queries_kib"] = rss_kib(session.process.pid)

        # Exercise the filesystem walker and SQLite writer, not direct SQL inserts.
        # A full metadata rescan is deliberately explicit: this is not a watcher SLA.
        update = {}
        started = threading.Event()
        def writer():
            try:
                start = time.perf_counter()
                for i in range(100):
                    old = root / relative_name(ns.entries - 1 - i)
                    old.rename(old.with_suffix(".renamed"))
                    (root / f"update-created-{i:03d}.txt").touch()
                for i in range(100, 200):
                    (root / relative_name(ns.entries - 1 - i)).unlink()
                started.set()
                update["scan"] = json.loads(subprocess.check_output(scan_command))
                update["wall_ms"] = round((time.perf_counter() - start) * 1000, 2)
            except BaseException as error:
                update["error"] = repr(error)
                started.set()
        thread = threading.Thread(target=writer)
        thread.start()
        started.wait()
        concurrent = {kind: [] for kind in workloads}
        n = 0
        rss_samples = [rss_kib(session.process.pid)]
        while thread.is_alive():
            kind, (text, expected) = schedule[n % len(schedule)]
            elapsed, _ = session.query(text, expected)
            concurrent[kind].append(elapsed)
            n += 1
            if n % 1000 == 0:
                rss_samples.append(rss_kib(session.process.pid))
        thread.join()
        assert "error" not in update, update
        # Check live serve refresh, including removal of cached paths.
        old = root / relative_name(ns.entries - 1)
        new = old.with_suffix(".renamed")
        deadline = time.monotonic() + 30
        while True:
            _, created = session.query("update-created-000")
            _, renamed = session.query(f"{ns.entries - 1:07d}")
            _, deleted = session.query(f"{ns.entries - 101:07d}")
            if (any(h["path"] == str(root / "update-created-000.txt") for h in created)
                    and any(h["path"] == str(new) for h in renamed)
                    and all(h["path"] != str(old) for h in renamed)
                    and not deleted):
                break
            assert time.monotonic() < deadline, (created, renamed, deleted)
        result["concurrent_updates"] = {
            "method": "100 creates + 100 renames + 100 deletes; one full name-only filesystem rescan",
            **update, "live_create_rename_delete_verified": True,
            "queries": {kind: {**summary(values), "expected_top20": len(values)}
                        for kind, values in concurrent.items()},
            "serve_rss_sampled_max_kib": max(rss_samples),
            "rss_sampling": "ps RSS at start and every 1000 foreground queries; not a peak profiler",
            "serve_rss_final_kib": rss_kib(session.process.pid)}
    finally:
        session.close()
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--entries", type=int, default=100000, choices=range(1000, 1000001), metavar="1000–1000000")
    ap.add_argument("--bin", type=Path, default=Path("target/release/lumen"))
    ap.add_argument("--work-dir", type=Path, help="retain isolated synthetic corpus/index for staged runs")
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument("--scan-only", action="store_true")
    ap.add_argument("--reuse-index", action="store_true", help="reuse scan.json and index from --scan-only")
    ap.add_argument("--repeats", type=int, default=20)
    ns = ap.parse_args()
    if ns.repeats < 1:
        ap.error("--repeats must be positive")
    if ns.work_dir:
        work = ns.work_dir.resolve()
        work.mkdir(parents=True, exist_ok=True)
        result = benchmark(ns, work)
    else:
        with tempfile.TemporaryDirectory(prefix="lumen-bench-", dir="/tmp") as tmp:
            result = benchmark(ns, Path(tmp).resolve())
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
