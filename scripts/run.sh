#!/usr/bin/env bash
# 측정 1회. 사용: run.sh <c0|c1|c2|c3|c3w|e1|e3|none|idle> <L1|L2|L3|S3> <회차 이름>
#   L1 immediate, stop_grace 10s / L2 graceful, stop_grace 10s (다운로드보다 짧음) / L3 graceful, stop_grace 60s (다운로드보다 김)
#   S3 Spring Boot 앱, graceful, timeout-per-shutdown-phase 24h · stop_grace 24h (운영과 같은 값)
#   e3 은 c3 배포 뒤 5초 만에 c3 를 한 번 더 한다 (예외 3: 기존 컨테이너가 아직 전송 중)
# RES 가 결과 디렉토리(기본 results), PROBE=1 이면 /version 을 0.1초마다 따로 찍는다
# 다운로드를 1초마다 1건 시작하고, 30초 뒤 배포 1회, 배포가 끝나고 30초 더 시작한 뒤 모두 끝나기를 기다린다.
mode="$1"; shut="$2"; name="$3"
export OUT="$(cd "$(dirname "$0")/.." && pwd)/${RES:-results}/raw/$name"
rm -rf "$OUT"; mkdir -p "$OUT"
source "$(dirname "$0")/lib.sh"
case "$shut" in
  L1) export SHUTDOWN=immediate STOP_GRACE=10s APP_GRACE=8;;
  L2) export SHUTDOWN=graceful STOP_GRACE=10s APP_GRACE=8;;
  L3) export SHUTDOWN=graceful STOP_GRACE=60s APP_GRACE=55;;
  S3) export SHUTDOWN=graceful STOP_GRACE=24h SPRING_GRACE=24h COMPOSE_FILE=compose.yaml:compose.spring.yaml;;
  *) echo "unknown level $shut"; exit 2;;
esac
SIZE=$((20 * 1024 * 1024)); RATE=$((1024 * 1024))

echo "mode=$mode shutdown=$shut name=$name" > "$OUT/meta.txt"
if ! reset_env "$mode"; then echo "reset failed" >> "$OUT/meta.txt"; exit 2; fi

docker events --filter type=container --format '{{.TimeNano}},{{.Action}},{{.Actor.Attributes.name}},{{.Actor.Attributes.signal}}' > "$OUT/docker-events.csv" &
EVPID=$!
echo "start,end,http,bytes,exit,version,host" > "$OUT/downloads.csv"

dl() {
  local s r
  s=$(now)
  r=$(curl -s -o /dev/null -m 120 -w '%{http_code},%{size_download},%{exitcode},%header{x-version},%header{x-host}' \
      "http://127.0.0.1:9080/download?size=$SIZE&rate=$RATE")
  echo "$s,$(now),$r" >> "$OUT/dl.$BASHPID"
}

# 짧은 요청 프로브: 어느 버전이 응답했고 실패했는지 0.1초 간격으로 남긴다
prober() {
  while [ ! -f "$OUT/stop" ]; do
    echo "$(now),$(curl -s -o /dev/null -m 2 -w '%{http_code},%header{x-version}' http://127.0.0.1:9080/version)" >> "$OUT/probe.csv"
    sleep 0.1
  done
}

# 배포와 상관없이 1초마다 1건 시작한다. stop 파일이 생기면 멈춘다
starter() {
  while [ ! -f "$OUT/stop" ]; do dl & sleep 1; done
  wait
}

ev window_start
starter &
STPID=$!
PRPID=""
if [ "${PROBE:-0}" = 1 ]; then prober & PRPID=$!; fi
sleep 30
if [ "$mode" = e3 ]; then
  bash "$(dirname "$0")/deploy.sh" c3 > "$OUT/deploy.log" 2>&1
  echo "deploy_exit=$?" >> "$OUT/meta.txt"
  sleep 5
  bash "$(dirname "$0")/deploy.sh" c3 > "$OUT/deploy2.log" 2>&1
  echo "deploy2_exit=$?" >> "$OUT/meta.txt"
else
  bash "$(dirname "$0")/deploy.sh" "$mode" > "$OUT/deploy.log" 2>&1
  echo "deploy_exit=$?" >> "$OUT/meta.txt"
fi
sleep 30
touch "$OUT/stop"; ev load_end
wait "$STPID"
[ -n "$PRPID" ] && wait "$PRPID"
ev window_end
kill "$EVPID" 2>/dev/null
cat "$OUT"/dl.* >> "$OUT/downloads.csv" 2>/dev/null; rm -f "$OUT"/dl.* "$OUT/stop"
docker compose logs --no-color -t > "$OUT/compose.log" 2>&1
echo "done $name"
