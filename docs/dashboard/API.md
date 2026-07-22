# Kant Local Server — API (v1 draft)

**문서 상태:** Phase 0 산출물 → Phase 2에서 구현
**범위:** Phase 0–3은 **읽기전용(GET만)**. 실행 생성(POST)·중지는 Phase 4 이후.

---

## 0. 원칙

- **Bind:** `127.0.0.1:7419` 전용. `0.0.0.0` 금지.
- Frontend는 shell/filesystem을 직접 만지지 않는다 — 반드시 이 API를 통한다.
- state 경로 규칙은 Core와 동일하게 재구현: `$STATE_ROOT/<repo_hash>/<run_id>/`, `repo_hash = shasum -a 256(pwd)[:12]`.
- malformed `run-state.json`은 해당 run만 error로 표시하고 서버·목록 전체는 살아있다.

---

## 1. 엔드포인트 (v1 — 읽기전용)

### Health
```http
GET /api/health
→ 200 { "status": "ok", "state_root": "...", "version": "0.1" }
```

### Runs 목록
```http
GET /api/runs
→ 200 [ { run_id, task, status, stage, started_at, updated_at }, ... ]
```
state dir를 mtime 내림차순 scan. run-state.json 없으면 기존 flat 파일(result.txt 등)로 degrade.

### Run 상세
```http
GET /api/runs/{run_id}
→ 200  run-state.json 전체
→ 404  없는 run
→ 200 + { "error": "malformed" }  깨진 상태 파일
```

### Events (전체)
```http
GET /api/runs/{run_id}/events
→ 200 [ {schema_version, seq, time, type, stage, agent, model, message}, ... ]
```
events.jsonl을 줄 단위 파싱, 깨진 줄은 skip.

### Live events (SSE)
```http
GET /api/runs/{run_id}/stream
→ text/event-stream  events.jsonl을 tail하며 새 이벤트를 push
```

---

## 2. Phase 4+ (이번 범위 밖 — 초안만)

```http
POST /api/runs        # 실행 생성 (임시 TASK.md → kant-loop.sh run --detach)
POST /api/runs/{id}/cancel   # 중지 (신규 엔진 기능 필요: detached.pid는 현재 아무도 안 읽음)
GET  /api/projects / POST /api/projects
```
POST 바디 예:
```json
{ "project": "/path", "task": "...", "mode": "chain",
  "agents": ["codex:gpt-5.6-sol", "claude:...", "opencode:glm-5.2"], "auto_commit": false }
```

---

## 3. 완료 조건 (Phase 2)

Frontend 없이 `curl`만으로 실행 상태·이벤트·결과 확인이 가능해야 한다.
