#!/usr/bin/env bash
# 사전 관측 P1~P6. 결과는 results/raw/observe/observe.log 에 사람이 읽는 형태로 남긴다
export OUT="$(cd "$(dirname "$0")/.." && pwd)/results/raw/observe"
rm -rf "$OUT"; mkdir -p "$OUT"
source "$(dirname "$0")/lib.sh"
LOG="$OUT/observe.log"
log() { echo "$*" | tee -a "$LOG"; }
dig_app() { docker compose --profile observe exec -T dnsutil dig +noall +answer "$1" 2>/dev/null; }
start_dnsutil() {
  docker compose --profile observe up -d dnsutil >/dev/null
  for i in $(seq 1 60); do docker compose --profile observe exec -T dnsutil which dig >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

# P1 · P2 · P3 (C1 의 전제)
reset_env c0; start_dnsutil
log "## P1 내장 DNS TTL"
dig_app app | tee -a "$LOG"
log "## P2 scale 2 일 때 서비스명 주소 수"
APP_VERSION=v1 docker compose up -d --no-deps --scale app=2 --no-recreate --wait app >/dev/null
log "addresses=$(dig_app app | wc -l)"; dig_app app | tee -a "$LOG"
log "## P3 새 컨테이너가 healthy 전에 DNS 에 나오는가 (기동 지연 5초)"
APP_VERSION=v1 docker compose up -d --no-deps --scale app=1 --wait app >/dev/null
t0=$(now)
STARTUP_DELAY=5 APP_VERSION=v2 docker compose up -d --no-deps --scale app=2 --no-recreate app >/dev/null
new=$(docker compose ps -q app | tail -n1)
first_dns=""; first_healthy=""
for i in $(seq 1 100); do
  n=$(dig_app app | wc -l)
  st=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q app | xargs -n1 docker inspect -f '{{.Created}} {{.Id}}' | sort | tail -n1 | cut -d' ' -f2)" 2>/dev/null)
  t=$(python3 -c "print(round($(now)-$t0,1))")
  [ -z "$first_dns" ] && [ "$n" -ge 2 ] && first_dns=$t
  [ -z "$first_healthy" ] && [ "$st" = healthy ] && first_healthy=$t
  [ -n "$first_dns" ] && [ -n "$first_healthy" ] && break
  sleep 0.2
done
log "dns_two_addresses_at=${first_dns}s healthy_at=${first_healthy}s (배포 명령 기준)"

# P4 · P5 · P6 (C2 의 전제)
reset_env c2
APP_VERSION=v2 docker compose up -d --no-deps --wait app_green >/dev/null
log "## P4 1초 안의 두 번 쓰기 (mtime 해상도 1초, blue→green→blue, 0.3초 간격). 최종이 v1 이어야 정상"
log "# 시도마다 초 경계에서 0.1초씩 늦게 시작해 1초 확인 타이머와의 위상을 바꾼다"
for i in $(seq 0 9); do
  set_node app_blue; sleep 2.5; wait_version v1 3 10
  # 초 경계 + i*0.1초에서 시작
  python3 -c "import time; t=time.time(); time.sleep((1 - t % 1) + $i * 0.1)"
  set_node app_green; sleep 0.3; set_node app_blue
  sleep 3
  log "offset=0.${i}s final=$(probe | cut -d' ' -f1)"
done
log "## P5 쓰기 방식별 반영 (blue→green, 5초 안에 v2 가 보이면 반영)"
for i in $(seq 1 5); do
  set_node app_blue; wait_version v1 3 10; sleep 1.2   # 직전 쓰기와 다른 초에 쓴다 (P4 와 분리)
  set_node app_green
  if wait_version v2 3 5; then r=yes; else r=no; fi
  log "inplace trial=$i reflected=$r"
done
for i in $(seq 1 5); do
  set_node app_blue; docker compose restart apisix >/dev/null; wait_version v1 3 30
  sed 's/__NODE__/app_green/' apisix/route.tmpl > "$YAML.new" && mv "$YAML.new" "$YAML"
  if wait_version v2 3 5; then r=yes; else r=no; fi
  log "rename trial=$i reflected=$r"
done
# rename 뒤에는 마운트가 옛 inode 를 본다. 컨테이너를 다시 만들어 되돌린다
log "## P6 노드를 바꿔도 옛 노드의 진행 중 다운로드가 끝나는가 (옛 컨테이너는 계속 실행)"
for i in $(seq 1 5); do
  reset_env c2
  APP_VERSION=v2 docker compose up -d --no-deps --wait app_green >/dev/null
  r=$(mktemp)
  curl -s -o /dev/null -m 60 -w '%{http_code},%{size_download},%{exitcode},%header{x-version}' \
    "http://127.0.0.1:9080/download?size=$((10*1024*1024))&rate=$((1024*1024))" > "$r" &
  cp=$!
  sleep 3; set_node app_green; wait_version v2 3 10; wait "$cp"
  log "trial=$i result=$(cat "$r") (http,bytes,exit,version; 완주는 200,10485760,0,v1)"
  rm -f "$r"
done
docker compose --profile observe down -t 0 --remove-orphans >/dev/null 2>&1
log "observe done"
