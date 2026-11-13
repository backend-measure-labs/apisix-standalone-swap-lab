#!/usr/bin/env bash
# 2차 측정: 사전 관측 P7 · P8 → 대조 회차 2회 → 비교군 × 종료 8조합 × 5회를 무작위 순서로. 결과는 results/r2/
set -uo pipefail
cd "$(dirname "$0")/.."
export RES=results/r2 PROBE=1
REPS="${REPS:-5}"
SEED="${SEED:-$(date +%s)}"
if ls "$RES"/raw/run-* >/dev/null 2>&1; then
  echo "$RES/raw 에 이전 회차가 있습니다. 옮기거나 지운 뒤 실행하세요"; exit 4
fi
mkdir -p "$RES/raw"
echo "seed=$SEED reps=$REPS" > "$RES/raw/plan.txt"

bash scripts/observe-r2.sh

for i in 1 2; do
  bash scripts/run.sh none L1 "run-control-$i"
done
python3 - <<'PY' || { echo "control run failed: harness defect"; exit 3; }
import csv, glob, sys
bad = 0
for f in glob.glob("results/r2/raw/run-control-*/downloads.csv"):
    for r in csv.DictReader(open(f)):
        if not (r["http"] == "200" and r["bytes"] == str(20*1024*1024) and r["exit"] == "0"):
            bad += 1
for f in glob.glob("results/r2/raw/run-control-*/probe.csv"):
    for r in csv.reader(open(f)):
        if len(r) < 2 or r[1] != "200":
            bad += 1
print("control bad downloads+probes:", bad)
sys.exit(1 if bad else 0)
PY

python3 -c "
import random
random.seed($SEED)
combos=[('c3','L1'),('c3','L2'),('c3','L3'),('c3','S3'),('c3w','L3'),('c3w','S3'),('e3','L3'),('e1','L3')]
plan=[(m,l,r) for m,l in combos for r in range(1,$REPS+1)]
random.shuffle(plan)
print('\n'.join(f'{m} {l} {r}' for m,l,r in plan))
" > "$RES/raw/order.txt"

while read -r m l r; do
  bash scripts/run.sh "$m" "$l" "run-$m-$l-$r"
done < "$RES/raw/order.txt"
python3 scripts/summarize.py
