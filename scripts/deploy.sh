#!/usr/bin/env bash
# 배포 1회. 사용: deploy.sh <c0|c1|c2|c3|c3w|e1|none>. 새 버전은 v2. 종료 수준은 SHUTDOWN · STOP_GRACE · APP_GRACE 환경변수
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
  c3|c3w)
    # 운영 swap-app.sh 와 같은 순서: 다음 자리가 실행 중이면 멈춤(예외 3) → 신규 기동 · healthy →
    # 노드 제자리 쓰기 → APISIX 로그 「apisix.yaml reloaded」 확인 → 기존 컨테이너에 SIGTERM 만 보내고 기다리지 않음.
    # c3w 는 reload 로그를 본 뒤 2초 더 기다린 다음 SIGTERM 을 보낸다 (워커마다 1초 타이머로 따로 읽으므로, E1)
    active=$(cur_node)
    if [ "$active" = app_blue ]; then idle=app_green; else idle=app_blue; fi
    icid=$(docker compose ps -aq "$idle")
    if [ -n "$icid" ] && [ "$(docker inspect -f '{{.State.Running}}' "$icid")" = true ]; then
      ev deploy_blocked; echo "next slot $idle still running"; exit 3
    fi
    docker compose rm -f "$idle" >/dev/null 2>&1
    docker compose up -d --no-deps "$idle"
    ev new_started
    if ! wait_healthy "$(docker compose ps -q "$idle")" 90; then
      ev deploy_failed; docker compose rm -sf "$idle"; exit 1
    fi
    ev new_healthy
    sed "s/__NODE__/$idle/" apisix/route.tmpl > "$YAML.tmp"
    if ! tail -n1 "$YAML.tmp" | grep -q '^#END'; then
      ev deploy_failed; rm -f "$YAML.tmp"; docker compose rm -sf "$idle"; exit 1
    fi
    # 직전 쓰기와 mtime(초 단위)이 달라질 때까지 기다린다
    while [ "$(stat -c %Y "$YAML")" = "$(date +%s)" ]; do sleep 0.1; done
    since=$(date +%s)
    cat "$YAML.tmp" > "$YAML"; rm -f "$YAML.tmp"
    ev yaml_written
    seen=""
    for i in $(seq 1 20); do
      n=$(docker logs --since "$since" "$(docker compose ps -q apisix)" 2>&1 | grep -c 'apisix.yaml reloaded' || true)
      [ "${n:-0}" -gt 0 ] && { seen=1; break; }
      sleep 0.5
    done
    if [ -z "$seen" ]; then
      set_node "$active"; ev deploy_failed; docker compose kill -s TERM "$idle"; exit 1
    fi
    ev switched
    [ "$mode" = c3w ] && { sleep 2; ev settle_end; }
    ocid=$(docker compose ps -q "$active")
    docker update --restart=no "$ocid" >/dev/null
    docker kill -s TERM "$ocid" >/dev/null
    ev old_sigterm
    ;;
  e1)
    # 예외 1: APISIX 재생성 (게이트웨이 이미지 · config.yaml 변경 배포)
    docker compose up -d --no-deps --force-recreate apisix
    ;;
esac
ev deploy_end
