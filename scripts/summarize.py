#!/usr/bin/env python3
"""원시 기록(results/raw/<회차>/)에서 회차별 표와 조합별 표를 만든다.

다운로드 분류 (연구 정의 3.5):
  완주      HTTP 200, 받은 바이트 = 20MB, curl 종료 코드 0
  끊김      HTTP 200 으로 응답을 받기 시작했지만 완주하지 못함 (손실)
  시작 실패 HTTP 200 을 받지 못함 (연결 오류 · 5xx)
시각은 배포 시작(deploy_start) 기준 초로 바꾼다.
"""
import csv
import glob
import os
import sys
from collections import defaultdict

SIZE = 20 * 1024 * 1024
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RAW = os.path.join(ROOT, "results", "raw")


def read_events(d):
    ev = {}
    p = os.path.join(d, "events.csv")
    if os.path.exists(p):
        for line in open(p):
            t, name = line.strip().split(",", 1)
            ev.setdefault(name, float(t))
    return ev


def classify(row):
    try:
        http, size, code = int(row["http"]), int(row["bytes"]), int(row["exit"])
    except ValueError:
        return "start_fail"
    if http != 200:
        return "start_fail"
    if size == SIZE and code == 0:
        return "ok"
    return "cut"


def one(d):
    meta = dict(l.strip().split("=", 1) for l in open(os.path.join(d, "meta.txt")) if "=" in l and " " not in l.split("=")[0])
    head = open(os.path.join(d, "meta.txt")).readline().split()
    info = dict(x.split("=", 1) for x in head)
    ev = read_events(d)
    t0 = ev.get("deploy_start")
    rows = list(csv.DictReader(open(os.path.join(d, "downloads.csv"))))
    out = {"run": os.path.basename(d), "mode": info["mode"], "level": info["shutdown"],
           "deploy_exit": meta.get("deploy_exit", "?"), "n": len(rows), "ok": 0, "cut": 0, "start_fail": 0}
    cut_end, fail_start = [], []
    for r in rows:
        c = classify(r)
        out[c] += 1
        if t0 is None:
            continue
        if c == "cut":
            cut_end.append(float(r["end"]) - t0)
        if c == "start_fail":
            fail_start.append(float(r["start"]) - t0)
    rng = lambda xs: f"{min(xs):.1f}~{max(xs):.1f}" if xs else "-"
    out["cut_at"] = rng(cut_end)
    out["fail_at"] = rng(fail_start)
    out["deploy_s"] = f"{ev['deploy_end'] - t0:.1f}" if t0 and "deploy_end" in ev else "-"
    for k in ("new_healthy", "switched", "drained", "old_stop", "old_stopped"):
        out[k] = f"{ev[k] - t0:.1f}" if t0 and k in ev else "-"
    return out


def main():
    runs = [one(d) for d in sorted(glob.glob(os.path.join(RAW, "run-*")))]
    if not runs:
        sys.exit("no runs")
    cols = list(runs[0].keys())
    with open(os.path.join(ROOT, "results", "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(runs)
    agg = defaultdict(list)
    for r in runs:
        agg[(r["mode"], r["level"])].append(r)
    lines = ["| 비교군 | 종료 | 회차 | 끊김 난 회차 | 끊김 합계 | 시작 실패 난 회차 | 시작 실패 합계 | 다운로드 합계 |",
             "|---|---|---|---|---|---|---|---|"]
    for (m, l), rs in sorted(agg.items()):
        lines.append(f"| {m} | {l} | {len(rs)} | {sum(r['cut'] > 0 for r in rs)} | {sum(r['cut'] for r in rs)} | "
                     f"{sum(r['start_fail'] > 0 for r in rs)} | {sum(r['start_fail'] for r in rs)} | {sum(r['n'] for r in rs)} |")
    open(os.path.join(ROOT, "results", "summary.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
