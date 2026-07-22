# Kant Dashboard Server (읽기전용)

`run-state.json` / `events.jsonl` 계약(`docs/dashboard/STATE-CONTRACT.md`)을 기반으로 한
로컬 전용 관측 서버. **127.0.0.1:7419 에만 bind** 한다 (`0.0.0.0` 금지).

## 기동

저장소 루트에서 실행한다 (repo_hash 가 `pwd` 기준이므로).

```bash
# 1) 의존성 설치 (venv 권장)
python3 -m venv .venv && source .venv/bin/activate
pip install -r dashboard/server/requirements.txt

# 2) 기동 — 저장소 루트에서
uvicorn dashboard.server.main:app --host 127.0.0.1 --port 7419

# 또는 모듈 직접 실행
python3 -m dashboard.server.main
```

> `KANT_STATE_ROOT` 환경변수로 state 루트를 오버라이드 할 수 있다
> (기본 `~/.claude/state/nomad-kant-looper`). `kant-loop.sh:44` 와 동일.

## 엔드포인트 (전부 읽기전용 GET)

| Method | Path                          | 설명                                            |
|--------|-------------------------------|-------------------------------------------------|
| GET    | `/api/health`                 | `{status, state_root, version}`                 |
| GET    | `/api/runs`                   | run 목록 (mtime 내림차순). run-state.json 없으면 flat 파일로 degrade |
| GET    | `/api/runs/{run_id}`          | run-state.json 전체 (없으면 404, 깨졌으면 `error: malformed`) |
| GET    | `/api/runs/{run_id}/events`   | events.jsonl 파싱 배열 (깨진 줄 skip)            |
| GET    | `/api/runs/{run_id}/stream`   | SSE `text/event-stream` — events.jsonl tail     |

## curl 예시

```bash
# health
curl -s http://127.0.0.1:7419/api/health

# run 목록
curl -s http://127.0.0.1:7419/api/runs | jq .

# run 상세
curl -s http://127.0.0.1:7419/api/runs/<run_id> | jq .

# 이벤트
curl -s http://127.0.0.1:7419/api/runs/<run_id>/events | jq '.[].type'

# SSE 스트림 (종료는 Ctrl-C)
curl -N http://127.0.0.1:7419/api/runs/<run_id>/stream
```

## 안전 정책

- 서버는 `127.0.0.1` 에만 bind. `config.HOST` 가 고정되어 CLI 인자로도 `0.0.0.0` 으로 바꿀 수 없다.
- 모든 파일은 **읽기만** 한다. run 생성(POST)·cancel 등은 제공하지 않는다.
- malformed `run-state.json` / `events.jsonl` 이 있어도 서버·목록 응답이 죽지 않는다
  (해당 run 만 error 로 격리).
- state 경로·repo_hash 규칙은 `kant-loop.sh:44,84-88` 과 100% 동일.
