#!/usr/bin/env bash
# 2차 사전 관측 P7 · P8. 결과는 $RES/raw/observe/observe.log
#   P7 노드를 바꿔 쓴 뒤 워커마다 반영 시각이 얼마나 벌어지는가: 첫 「reloaded」 로그 · 첫 v2 응답 · 마지막 v1 응답
#   P8 쓰기 1번에 「apisix.yaml reloaded」 로그가 몇 줄 나오는가 (= 다시 읽은 워커 수)
export OUT="$(cd "$(dirname "$0")/.." && pwd)/${RES:-results}/raw/observe"
rm -rf "$OUT"; mkdir -p "$OUT"
source "$(dirname "$0")/lib.sh"
LOG="$OUT/observe.log"
log() { echo "$*" | tee -a "$LOG"; }

reset_env c3
APP_VERSION=v2 docker compose up -d --no-deps --wait app_green >/dev/null
apx=$(docker compose ps -q apisix)
log "## 워커 수 (nginx worker 프로세스)"
docker top "$apx" | grep -E 'nginx: (worker|privileged|master)' | tee -a "$LOG" >/dev/null
log "workers=$(docker top "$apx" | grep -c 'nginx: worker process')"
log "(아래 reload_lines 와 비교. 로그 줄의 pid 는 reload-<회>.log 에 남겨 워커 pid 와 대조한다)"
log "## P7 · P8 노드 교체 뒤 반영 시차 (blue v1 ↔ green v2 를 번갈아 10회, 시작 위상을 0.1초씩 바꿈)"
log "trial,write_to_first_new_s,write_to_last_old_s,reload_lines"
node=app_blue
for i in $(seq 0 9); do
  if [ "$node" = app_blue ]; then node=app_green; want=v2; old=v1; else node=app_blue; want=v1; old=v2; fi
  # 위상: 다음 정수 초 + i*0.1초에 쓴다
  python3 -c "import time; t=time.time(); time.sleep((int(t)+2+$i*0.1)-t)"
  since=$(date +%s)
  sed "s/__NODE__/$node/" apisix/route.tmpl > "$YAML.tmp"; t0=$(now); cat "$YAML.tmp" > "$YAML"; rm -f "$YAML.tmp"
  f="$OUT/p7-$i.csv"; : > "$f"
  end=$(python3 -c "print($t0+2.5)")
  while python3 -c "import sys,time; sys.exit(0 if time.time()<$end else 1)"; do
    echo "$(now),$(curl -s -o /dev/null -m 1 -w '%{http_code},%header{x-version}' http://127.0.0.1:9080/version)" >> "$f"
  done
  docker logs --since "$since" "$apx" 2>&1 | grep 'apisix.yaml reloaded' > "$OUT/reload-$i.log"
  lines=$(wc -l < "$OUT/reload-$i.log" | tr -d ' ')
  python3 - "$f" "$t0" "$want" "$old" "$i" "$lines" <<'PY' | tee -a "$LOG"
import csv, sys
f, t0, want, old, i, lines = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
rows = [r for r in csv.reader(open(f)) if len(r) == 3]
first_new = next((float(r[0]) - t0 for r in rows if r[2] == want), None)
last_old = max((float(r[0]) - t0 for r in rows if r[2] == old), default=None)
fmt = lambda v: f"{v:.2f}" if v is not None else "-"
print(f"{i},{fmt(first_new)},{fmt(last_old)},{lines}")
PY
done
