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
RES = os.path.join(ROOT, os.environ.get("RES", "results"))
RAW = os.path.join(RES, "raw")


def read_events(d):
    ev = {}
    p = os.path.join(d, "events.csv")
    if os.path.exists(p):
        for line in open(p):
            t, name = line.strip().split(",", 1)
            ev.setdefault(name, float(t))
    return ev


def docker_timeline(d, t0):
    """docker 이벤트에서 배포 뒤 첫 시각을 뽑는다: 새것 healthy, 옛것 SIGTERM · SIGKILL · die."""
    p = os.path.join(d, "docker-events.csv")
    out = {"ev_healthy": None, "ev_sigterm": None, "ev_sigkill": None, "ev_die": None}
    if t0 is None or not os.path.exists(p):
        return out
    for line in open(p):
        parts = line.strip().split(",")
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        t = int(parts[0]) / 1e9 - t0
        action, name = parts[1], parts[2]
        sig = parts[3] if len(parts) > 3 else ""
        if t < 0 or "app" not in name:
            continue
        key = None
        if action == "health_status: healthy":
            key = "ev_healthy"
        elif action == "kill" and sig == "15":
            key = "ev_sigterm"
        elif action == "kill" and sig == "9":
            key = "ev_sigkill"
        elif action == "die":
            key = "ev_die"
        if key and out[key] is None:
            out[key] = t
    return out


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
    for k in ("switched", "drained", "drain_timeout"):
        out[k] = f"{ev[k] - t0:.1f}" if t0 and k in ev else "-"
    for k, v in docker_timeline(d, t0).items():
        out[k] = f"{v:.1f}" if v is not None else "-"
    out["deploy2_exit"] = meta.get("deploy2_exit", "-")
    out.update(probe_stats(d, t0, ev))
    return out


def probe_stats(d, t0, ev):
    """2차 측정 프로브(/version 0.1초 간격): 실패 수 · 실패 시각 · 반영 확인 뒤 마지막 옛 버전 응답 시각."""
    p = os.path.join(d, "probe.csv")
    out = {"probe_n": "-", "probe_fail": "-", "probe_fail_at": "-", "old_after_switch": "-"}
    if t0 is None or not os.path.exists(p):
        return out
    rows = [r for r in csv.reader(open(p)) if len(r) >= 3]
    fails = [float(r[0]) - t0 for r in rows if r[1] != "200"]
    out["probe_n"], out["probe_fail"] = len(rows), len(fails)
    out["probe_fail_at"] = f"{min(fails):.1f}~{max(fails):.1f}" if fails else "-"
    sw = ev.get("switched")
    if sw is not None:
        old = [float(r[0]) - t0 for r in rows if r[2] == "v1" and float(r[0]) >= sw]
        out["old_after_switch"] = f"{max(old) - (sw - t0):.2f}" if old else "0"
    return out


def probe_cell(rs, f):
    vals = [r for r in rs if r["probe_fail"] != "-"]
    return sum(f(r) for r in vals) if vals else "-"


def excluded_reason(d):
    meta = open(os.path.join(d, "meta.txt")).read() if os.path.exists(os.path.join(d, "meta.txt")) else ""
    if "reset failed" in meta:
        return "reset failed"
    if not os.path.exists(os.path.join(d, "downloads.csv")):
        return "downloads.csv 없음"
    return None


def main():
    runs, excluded = [], []
    for d in sorted(glob.glob(os.path.join(RAW, "run-*"))):
        why = excluded_reason(d)
        if why:
            excluded.append((os.path.basename(d), why))
        else:
            runs.append(one(d))
    if not runs:
        sys.exit("no runs")
    cols = list(runs[0].keys())
    with open(os.path.join(RES, "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(runs)
    agg = defaultdict(list)
    for r in runs:
        agg[(r["mode"], r["level"])].append(r)
    lines = ["| 비교군 | 종료 | 회차 | 끊김 난 회차 | 끊김 합계 | 시작 실패 난 회차 | 시작 실패 합계 | 다운로드 합계 | 배포 실패(롤백) | drain 상한 도달 | 프로브 실패 난 회차 | 프로브 실패 합계 | 두 번째 배포 종료 코드 |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for (m, l), rs in sorted(agg.items()):
        lines.append(f"| {m} | {l} | {len(rs)} | {sum(r['cut'] > 0 for r in rs)} | {sum(r['cut'] for r in rs)} | "
                     f"{sum(r['start_fail'] > 0 for r in rs)} | {sum(r['start_fail'] for r in rs)} | {sum(r['n'] for r in rs)} | "
                     f"{sum(r['deploy_exit'] not in ('0', '?') for r in rs)} | {sum(r['drain_timeout'] != '-' for r in rs)} | "
                     f"{probe_cell(rs, lambda r: r['probe_fail'] > 0)} | {probe_cell(rs, lambda r: r['probe_fail'])} | "
                     f"{' '.join(sorted(set(r['deploy2_exit'] for r in rs)))} |")
    lines += ["", "제외 회차", "", "| 회차 | 사유 |", "|---|---|"]
    lines += [f"| {n} | {w} |" for n, w in excluded] or ["| 없음 | - |"]
    open(os.path.join(RES, "summary.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
