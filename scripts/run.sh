#!/usr/bin/env bash
# 측정 1회. 사용: run.sh <c0|c1|c2|none> <L1|L2|L3> <회차 이름>
#   L1 immediate, stop_grace 10s / L2 graceful, stop_grace 10s (다운로드보다 짧음) / L3 graceful, stop_grace 60s (다운로드보다 김)
# 다운로드를 1초마다 1건 시작하고, 30초 뒤 배포 1회, 배포가 끝나고 30초 더 시작한 뒤 모두 끝나기를 기다린다.
mode="$1"; shut="$2"; name="$3"
export OUT="$(cd "$(dirname "$0")/.." && pwd)/results/raw/$name"
rm -rf "$OUT"; mkdir -p "$OUT"
source "$(dirname "$0")/lib.sh"
case "$shut" in
  L1) export SHUTDOWN=immediate STOP_GRACE=10s APP_GRACE=8;;
  L2) export SHUTDOWN=graceful STOP_GRACE=10s APP_GRACE=8;;
  L3) export SHUTDOWN=graceful STOP_GRACE=60s APP_GRACE=55;;
  *) echo "unknown level $shut"; exit 2;;
esac
SIZE=$((20 * 1024 * 1024)); RATE=$((1024 * 1024))

echo "mode=$mode shutdown=$shut name=$name" > "$OUT/meta.txt"
if ! reset_env "$mode"; then echo "reset failed" >> "$OUT/meta.txt"; exit 2; fi

docker events --filter type=container --format '{{.TimeNano}},{{.Action}},{{.Actor.Attributes.name}}' > "$OUT/docker-events.csv" &
EVPID=$!
echo "start,end,http,bytes,exit,version,host" > "$OUT/downloads.csv"

dl() {
  local s r
  s=$(now)
  r=$(curl -s -o /dev/null -m 120 -w '%{http_code},%{size_download},%{exitcode},%header{x-version},%header{x-host}' \
      "http://127.0.0.1:9080/download?size=$SIZE&rate=$RATE")
  echo "$s,$(now),$r" >> "$OUT/dl.$BASHPID"
}

# 배포와 상관없이 1초마다 1건 시작한다. stop 파일이 생기면 멈춘다
starter() {
  while [ ! -f "$OUT/stop" ]; do dl & sleep 1; done
  wait
}

ev window_start
starter &
STPID=$!
sleep 30
bash "$(dirname "$0")/deploy.sh" "$mode" > "$OUT/deploy.log" 2>&1
echo "deploy_exit=$?" >> "$OUT/meta.txt"
sleep 30
touch "$OUT/stop"; ev load_end
wait "$STPID"
ev window_end
kill "$EVPID" 2>/dev/null
cat "$OUT"/dl.* >> "$OUT/downloads.csv" 2>/dev/null; rm -f "$OUT"/dl.* "$OUT/stop"
docker compose logs --no-color > "$OUT/compose.log" 2>&1
echo "done $name"
