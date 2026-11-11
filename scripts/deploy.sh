#!/usr/bin/env bash
# 배포 1회. 사용: deploy.sh <c0|c1|c2|none>. 새 버전은 v2. 종료 수준은 SHUTDOWN · STOP_GRACE · APP_GRACE 환경변수
source "$(dirname "$0")/lib.sh"
mode="$1"
export APP_VERSION=v2
ev deploy_start
case "$mode" in
  none)
    ;;
  c0)
    # 지금 운영 방식: 재생성 (옛것 정지 · 제거 → 새것 생성)
    docker compose up -d --no-deps app
    ;;
  c1)
    # docker-rollout v0.14: scale 2 → 새것 healthy → 옛것 docker stop · rm
    docker rollout app
    ;;
  c2)
    active=$(cur_node)
    if [ "$active" = app_blue ]; then idle=app_green; else idle=app_blue; fi
    docker compose up -d --no-deps "$idle"
    ev new_started
    if ! wait_healthy "$(docker compose ps -q "$idle")" 60; then
      ev deploy_failed; docker compose rm -sf "$idle"; exit 1
    fi
    ev new_healthy
    # 쓰기 전에 검증: YAML 문법과 #END
    sed "s/__NODE__/$idle/" apisix/route.tmpl > "$YAML.tmp"
    if ! python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$YAML.tmp" || ! tail -n1 "$YAML.tmp" | grep -q '^#END'; then
      ev deploy_failed; rm -f "$YAML.tmp"; docker compose rm -sf "$idle"; exit 1
    fi
    cat "$YAML.tmp" > "$YAML"; rm -f "$YAML.tmp"
    ev yaml_written
    if ! wait_version v2 5 10; then
      set_node "$active"; ev deploy_failed; docker compose rm -sf "$idle"; exit 1
    fi
    ev switched
    # 옛 색으로 가는 진행 중 다운로드가 0 이 될 때까지 기다린 뒤 멈춘다 (최대 DRAIN_MAX 초)
    oldip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(docker compose ps -q "$active")")
    drain=timeout; qfail=0
    for i in $(seq 1 $(( ${DRAIN_MAX:-600} * 2 ))); do
      n=$(curl -s -m 1 "http://$oldip:8080/inflight") || n=""
      [ -z "$n" ] && qfail=$((qfail + 1))
      [ "$n" = 0 ] && { drain=done; break; }
      sleep 0.5
    done
    echo "drain=$drain inflight_query_failures=$qfail" >> "$OUT/meta.txt"
    if [ "$drain" = done ]; then ev drained; else ev drain_timeout; fi
    ev old_stop
    docker compose stop "$active"   # SIGTERM, stop_grace_period 뒤 SIGKILL
    ev old_stopped
    docker compose rm -f "$active"
    ;;
esac
ev deploy_end
