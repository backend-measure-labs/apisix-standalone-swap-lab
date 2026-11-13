#!/usr/bin/env bash
# 공통 함수. 다른 스크립트가 source 한다.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
YAML="$ROOT/apisix/apisix.yaml"
OUT="${OUT:-$ROOT/results/raw/adhoc}"
mkdir -p "$OUT"

now() { date +%s.%N; }
# 이벤트 타임라인: 시각,이름
ev() { echo "$(now),$1" >> "$OUT/events.csv"; }

# apisix.yaml 노드를 바꾼다. 같은 inode 를 유지하는 제자리 쓰기
set_node() { sed "s/__NODE__/$1/" apisix/route.tmpl > "$YAML.tmp" && cat "$YAML.tmp" > "$YAML" && rm -f "$YAML.tmp"; }
cur_node() { grep -o '"[a-z_]*:8080"' "$YAML" | tr -d '"' | cut -d: -f1; }

# apisix 를 거친 /version 응답 본문 (실패하면 빈 문자열)
probe() { curl -s -m 2 http://127.0.0.1:9080/version 2>/dev/null || true; }

# 같은 버전이 연속 n 번 나올 때까지 (최대 t 초). 반환 0=성공
wait_version() {
  local want="$1" n="${2:-5}" t="${3:-30}" ok=0 i
  for i in $(seq 1 $((t * 10))); do
    case "$(probe)" in "$want "*) ok=$((ok + 1));; *) ok=0;; esac
    [ "$ok" -ge "$n" ] && return 0
    sleep 0.1
  done
  return 1
}

# 컨테이너가 healthy 가 될 때까지 (최대 t 초)
wait_healthy() {
  local cid="$1" t="${2:-60}" i st
  for i in $(seq 1 $((t * 5))); do
    st=$(docker inspect -f '{{if .State.Running}}{{.State.Health.Status}}{{else}}exited{{end}}' "$cid" 2>/dev/null || echo gone)
    [ "$st" = healthy ] && return 0
    { [ "$st" = exited ] || [ "$st" = gone ]; } && return 1
    sleep 0.2
  done
  return 1
}

# 모든 컨테이너를 내리고 mode 에 맞는 v1 구성을 띄운다. 색 서비스를 쓰는 비교군(c2 · c3 · c3w · e1 · e3 · idle)은 blue 로 시작한다
reset_env() {
  local mode="$1"
  docker compose --profile observe down -t 0 --remove-orphans >/dev/null 2>&1
  if [ "$mode" != c0 ] && [ "$mode" != c1 ] && [ "$mode" != none ]; then
    set_node app_blue
    APP_VERSION=v1 docker compose up -d --wait app_blue apisix >/dev/null
  else
    set_node app
    APP_VERSION=v1 docker compose up -d --wait app apisix >/dev/null
  fi
  wait_version v1 10 60
}
