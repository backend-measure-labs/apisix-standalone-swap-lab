#!/usr/bin/env bash
# 전체 측정: 사전 관측 → 대조 회차(배포 없음) 2회 → 비교군 3 × 종료 3 × 5회를 무작위 순서로
set -uo pipefail
cd "$(dirname "$0")/.."
REPS="${REPS:-5}"
SEED="${SEED:-$(date +%s)}"
# 커밋된 이전 결과와 섞이지 않게 한다. 이전 결과는 옮기거나 지우고 실행한다
if ls results/raw/run-* >/dev/null 2>&1; then
  echo "results/raw 에 이전 회차가 있습니다. 옮기거나 지운 뒤 실행하세요"; exit 4
fi
mkdir -p results/raw
echo "seed=$SEED reps=$REPS" > results/raw/plan.txt

bash scripts/observe.sh

# 하네스 검증: 배포 없이 측정 창만. 끊김 · 시작 실패가 있으면 하네스 결함이라 멈춘다
for i in 1 2; do
  bash scripts/run.sh none L1 "run-control-$i"
done
python3 - <<'PY' || { echo "control run failed: harness defect"; exit 3; }
import csv, glob, sys
bad = 0
for f in glob.glob("results/raw/run-control-*/downloads.csv"):
    for r in csv.DictReader(open(f)):
        if not (r["http"] == "200" and r["bytes"] == str(20*1024*1024) and r["exit"] == "0"):
            bad += 1
print("control bad downloads:", bad)
sys.exit(1 if bad else 0)
PY

python3 -c "
import random
random.seed($SEED)
plan=[(m,l,r) for m in ('c0','c1','c2') for l in ('L1','L2','L3') for r in range(1,$REPS+1)]
random.shuffle(plan)
print('\n'.join(f'{m} {l} {r}' for m,l,r in plan))
" > results/raw/order.txt

while read -r m l r; do
  bash scripts/run.sh "$m" "$l" "run-$m-$l-$r"
done < results/raw/order.txt
python3 scripts/summarize.py
