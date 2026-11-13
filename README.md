# apisix-standalone-swap-lab

**APISIX standalone 뒤의 앱 컨테이너를 교체할 때 진행 중 다운로드가 끊기지 않는 방식이 있습니까?** 있습니다. blue/green 서비스 교대 + `apisix.yaml` 노드 교체 + drain(C2) 이 45회 측정 중 자기 몫 15회 모두에서 끊김 0건 · 시작 실패 0건이었습니다. 지금 방식(재생성)과 docker-rollout 은 종료 유예가 다운로드보다 짧으면 진행 중 다운로드를 끊고, 길어도 교체 중 새 다운로드를 실패시켰습니다.

- 연구 정의(손실 · 질문 · 가설 · 비교군 근거 · 측정 설계): [docs/research-definition.md](docs/research-definition.md)
- 막으려는 손실: 교체 중 진행 중 다운로드가 끊긴다 (대용량 · 저트래픽 서비스, 업로드는 청크 재개라 범위 밖)

## 결과

환경: GitHub Actions `ubuntu-24.04` (x86_64, 커널 7.0.0-azure, 4 CPU), Docker 29.2.0 / Compose v5.0.2 고정 설치, `apache/apisix:3.15.0-debian`. 다운로드는 20MB 를 1MB/s 로(약 20초) 1초마다 1건 시작했습니다.

| 비교군 | 종료 수준 | 회차 | 끊김 (회차 / 건) | 시작 실패 (회차 / 건) | 가설 |
|---|---|---|---|---|---|
| C0 재생성 (지금 방식) | L1 즉시 종료 | 5 | 5 / 100 | 0 / 0 | 맞음 |
| | L2 graceful, 유예 10초 < 다운로드 | 5 | 5 / 60 | 5 / 40 | 맞음 |
| | L3 graceful, 유예 60초 > 다운로드 | 5 | 0 / 0 | 5 / 100 | 맞음 |
| C1 docker-rollout v0.14 | L1 | 5 | 5 / 100 | 5 / 150 | 맞음 |
| | L2 | 5 | 5 / 60 | 5 / 190 | 맞음 |
| | L3 | 5 | 0 / 0 | 5 / 250 | 맞음 |
| **C2 blue/green + yaml + drain** | L1 · L2 · L3 | 15 | **0 / 0** | **0 / 0** | 맞음 |
| 대조 (배포 없음) | - | 2 | 0 / 0 | 0 / 0 | 하네스 정상 |

- 끊김: HTTP 200 으로 받기 시작했지만 20MB 를 다 받지 못한 다운로드. 시작 실패: HTTP 200 을 받지 못한 다운로드.
- org 이전 뒤 같은 워크플로를 조합마다 1회로 다시 실행해 같은 결과를 확인했습니다 (끊김 · 시작 실패 건수와 구간 시각 동일, C2 drain 끝 25.1초 → 25.6초).
- 회차별 표 [results/runs.csv](results/runs.csv), 조합별 표 [results/summary.md](results/summary.md), 원시 기록 [results/raw/](results/raw/). 제외 회차 0, 배포 롤백 0, drain 상한 도달 0.

### 끊김과 시작 실패가 난 구간 (배포 시작 = 0초, 회차마다 같은 모양)

```
C0 L1  0.1s 옛것 SIGTERM → 즉시 종료 ─▶ 진행 중 20건 끊김. 5.3s 새것 healthy
C0 L2  0.1s SIGTERM → 새 연결 거부(시작 실패) → 8.1s 앱 유예 끝 ─▶ 남은 12건 끊김
C0 L3  0.1s SIGTERM → 새 연결 거부 → 20.6s 진행 중 다 보내고 종료 → 그 뒤 새것 생성
       ─▶ 끊김 0, 그러나 SIGTERM 부터 새것 수신까지 약 25초 시작 실패
C1 L*  5.5s 새것 healthy → 5.7s 옛것 SIGTERM ─▶ 종료 수준대로 끊김(L1 20건 · L2 12건 · L3 0건)
       6.1s 이후 측정 창 끝까지 시작 실패: APISIX DNS 캐시가 지워진 옛 주소를 쥠 (TTL 600초, P1)
C2 L*  5.2s 새 색 healthy → 6.2s 노드 반영 확인 (새 요청은 새 색으로)
       → 25.1s 옛 색 진행 중 0 (drain) → 25.2s SIGTERM ─▶ 종료 수준과 상관없이 끊김 · 실패 0
```

### 사전 관측

| 번호 | 관측 | 결과 | 쓰임 |
|---|---|---|---|
| P1 | 내장 DNS TTL | 600초 | C1 시작 실패가 측정 창보다 오래 이어지는 근거 |
| P2 | scale 2 일 때 서비스명 주소 | 2개 | C1 전제 확인 |
| P3 | 새 컨테이너가 healthy 전에 DNS 에 나오는가 | 나옴 (0.5초, healthy 는 5.3초) | 노드가 여럿이면 healthy 전 컨테이너로 요청이 갈 수 있음 |
| P4 | 1초 안의 두 번 쓰기 | 1초 확인 타이머 위상 10개 중 2개에서 두 번째 쓰기를 놓침 | **yaml 을 연달아 쓸 때는 1초 넘게 간격을 둡니다** (APISIX 가 읽는 mtime(`lfs.attributes().modification`)은 해상도가 1초라, 1초 안의 두 번째 쓰기는 mtime 이 같아 변경으로 감지되지 않습니다) |
| P5 | 쓰기 방식 | 제자리 쓰기 5/5 반영, rename 0/5 반영 | **단일 파일 마운트에서는 제자리 쓰기(`cat >`)만 됩니다** |
| P6 | 노드를 바꿔도 옛 노드의 진행 중 다운로드가 끝나는가 | 5/5 완주 | C2 drain 의 전제 확인 |

## 결론

1. 앱 교체 중 진행 중 다운로드를 지키는 방식은 C2(blue/green + yaml 노드 교체 + drain)입니다. 새 요청은 yaml 반영 순간 한 번에 새 색으로 가고, 옛 색은 진행 중 다운로드가 0 이 된 뒤 멈추므로 앱의 종료 방식과 `stop_grace_period` 에 기대지 않습니다.
2. 재생성(C0)과 docker-rollout(C1)은 종료 유예가 최장 다운로드보다 길고 앱이 graceful 하게 종료해야만 끊김이 없고, 그때도 교체 중 새 다운로드가 실패합니다. C1 은 그 실패가 DNS TTL(600초) 동안 이어집니다.
3. 결론의 크기: 이 환경에서 조합마다 5회 측정해 위 구간이 매번 같은 시각에 나왔고, 원전 동작(연구 정의 E1 · E5 · E6, P1 · P6)과 맞습니다. 0/15 는 「끊김이 없다」의 증명이 아니라 「15회에서 나오지 않았다」입니다.

## 한계

| 항목 | 내용 |
|---|---|
| drain 상한 | C2 무중단은 최장 다운로드 < drain 상한(600초)일 때만입니다. 넘으면 옛 색은 진행 중 다운로드를 남긴 채 멈춥니다 |
| 다운로드 길이 | 랩은 20초입니다. 운영 최장 길이는 확인하지 않았습니다 |
| 라우트 플러그인 | 랩 라우트는 플러그인이 없습니다. 운영처럼 `api-breaker` 가 있으면 C0 · C1 의 시작 실패가 차단 구간으로 더 길어질 수 있습니다 |
| 클라이언트 위치 | 같은 호스트의 curl 입니다. 네트워크 지연은 끊김 판정에 영향이 없습니다 |
| APISIX 자체 교체 | 범위 밖입니다. 호스트 포트를 쥔 프로세스가 바뀌므로 앞에 다른 LB 가 필요합니다 |

## 재현

```bash
# GitHub Actions 에서 (조합마다 회차 수)
gh workflow run measure.yml -f reps=5
# 로컬 Linux x86_64 에서 Docker 29.2.0 / Compose v5.0.2, docker-rollout v0.14 를 갖춘 뒤
docker build -f Dockerfile.app -t lab-app:local .
REPS=5 bash scripts/all.sh
```

| 경로 | 내용 |
|---|---|
| `app/main.go` | 속도 조절 다운로드 · `/inflight` · 종료 방식을 가진 테스트 앱 |
| `compose.yaml` · `apisix/` | APISIX 3.15.0 standalone 과 앱 서비스 (C0 · C1 은 `app`, C2 는 `app_blue` · `app_green`) |
| `scripts/deploy.sh` | 비교군별 배포 1회 |
| `scripts/run.sh` · `all.sh` | 회차 1회 · 전체 측정 (사전 관측 → 대조 2회 → 무작위 순서 45회) |
| `scripts/observe.sh` | 사전 관측 P1 \~ P6 |
| `scripts/summarize.py` | 원시 기록 → 회차별 · 조합별 표 |
| `results/smoke/` | 본 측정 전 하네스 검증 실행 (조합마다 1회) |
