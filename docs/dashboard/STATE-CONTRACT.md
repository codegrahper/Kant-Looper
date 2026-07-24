# Kant Observability Contract (v1)

**문서 상태:** Phase 0 산출물 → Phase 1에서 구현
**목적:** Dashboard가 Bash 로그를 추측해서 상태를 알아내지 않게, 각 run에 machine-readable 상태 파일 2개를 추가한다.

---

## 0. 배경 — 현재 state directory (코드 확인 결과)

- **State root:** `$KANT_STATE_ROOT` (기본 `~/.claude/state/nomad-kant-looper`) — `kant-loop.sh:44`
- **repo hash:** `shasum -a 256(pwd)` 앞 12자 — `kant-loop.sh:72-76`
- **run_id:** `<slug>-<UTC yyyymmdd-HHMMSS>-<4hex>` — `kant-loop.sh:112-119`
- **state dir:** `$STATE_ROOT/<repo_hash>/<run_id>/` — `kant-loop.sh:824`

현재 존재하는 파일(발췌): `task.md`, `run-id.txt`, `branch.txt`, `worktree.txt`, `result.txt`, `failure-code.txt`, `failure-message.txt`, `commit-sha.txt`, `phase-events.log`, (detach 시) `detached.pid`. `run-state.json` / `events.jsonl`은 **아직 없다** — 이번에 신규 추가한다.

기존 `phase-events.log`(`[UTC] key=value` 자유형식, adapter stderr 노이즈 섞임)와 flat 파일은 **삭제하지 않는다.** 신규 파일은 Dashboard 전용 machine-readable 인터페이스다.

---

## 1. `run-state.json` — 현재 상태 스냅샷

주요 전이점(run 생성 / stage 변경 / 완료·실패)에서 갱신. 기존 `status --json`(`kant-loop.sh:1044-1059`) 형태에 `status` / `stage` / `agents[]` / 시각·task·mode를 더한다.

```json
{
  "schema_version": 1,
  "run_id": "login-20260722-214201-6d2b",
  "repo": "/Users/iva/AGENTS/kant-looper-dev",
  "task": "Implement authentication",
  "mode": "quick_chain",

  "status": "running",
  "stage": "review",

  "started_at": "2026-07-22T21:42:01Z",
  "updated_at": "2026-07-22T21:44:10Z",

  "branch": "agent/kant/login-...",
  "worktree": "/tmp/kant-worktree-...",

  "agents": [
    { "role": "implement", "tool": "codex",  "model": "gpt-5.6-sol", "status": "completed", "verdict": "PASS", "attempts": [] },
    { "role": "review",    "tool": "claude", "model": "...",         "status": "running",   "verdict": null,   "attempts": [] }
  ],

  "result": null,
  "failure": null,
  "commit": null
}
```

### status enum (Dashboard 전용, 제한된 집합)
`queued` · `preparing` · `running` · `waiting` · `completed` · `failed` · `cancelled`
(`orphaned`는 Phase 6에서 추가 — 지금은 넣지 않음)

기존 `result.txt` 값과의 매핑: 파일 없음→`running`, `completed`→`completed`, `pass_no_commit`→`completed`(commit=null), `failed`→`failed`.

### stage enum
`preflight` · `routing` · `worktree` · `plan` · `implement` · `gate` · `review` · `repair` · `verify` · `commit` · `done`

### agents[] 채우기 (★ 구현 핵심)
verdict·model 등 실제 값은 `status --json`에 없다. 원본은 각 role이 남기는
`<worktree>/.kant-looper/<tool>-<role>.json` (adapter가 기록).
`run_quick_chain`(`kant-loop.sh:520-543`)이 role 루프를 돌 때 완료된 role의 이 JSON을 읽어
`{role, tool, model, status, verdict}`로 요약한다. Findings/risks 전체는 Phase 5(Inspector 상세)에서 파일을 직접 참조.

**`tool`/`model`은 이 role을 실제로 완료(또는 최후 시도)한 도구를 가리킨다.**
fallback이 발생했으면 원래 실패한 도구가 아니라 최종 실행자로 갱신된다 (2026-07-24,
아래 §2.1 참고 — 이전에는 `QUICK_CALL`의 원본 tool/model이 끝까지 고정돼서, fallback으로
다른 도구가 실제로 처리했는데도 화면엔 원래 도구가 성공한 것처럼 보이는 오표기가 있었다).

### agents[].attempts[] — fallback 시도 이력

```json
{ "tool": "agy", "model": "gemini-3.6-flash", "outcome": "failed", "detail": "adapter failed mode=INVALID_OUTPUT rc=1" }
{ "tool": "opencode", "model": "glm-5.2", "outcome": "failed", "detail": "fallback attempt opencode:glm-5.2 failed (rc:1)" }
{ "tool": "codex", "model": "gpt-5.6-terra", "outcome": "succeeded" }
```

원본이 실패해서 fallback이 발생하지 않은 role은 `attempts: []`(빈 배열)이다.
`outcome`은 `failed` | `succeeded`. 순서대로 시도된 이력이라 마지막 항목이 대체로
현재 `tool`/`model`과 일치한다(단, 전부 실패한 채 run이 종료된 경우는 예외).

### Atomic write (필수)
`run-state.json`을 직접 덮어쓰지 않는다. `run-state.tmp` 작성 → `mv`(rename)로 원자 교체. Dashboard가 중간에 깨진 JSON을 읽지 못하게 한다.

---

## 2. `events.jsonl` — 이벤트 타임라인 (append-only, JSON Lines)

한 줄 = 이벤트 하나. 기존 `log_event()`(`kant-loop.sh:63-66`) 호출점에 병행 기록.

```json
{ "schema_version": 1, "seq": 32, "time": "2026-07-22T21:44:02Z", "type": "review_started", "stage": "review", "agent": "claude", "model": "...", "message": "Review started" }
```

- `seq`: 1부터 단조 증가.
- `type`: 아래 이벤트 종류.
- `stage`/`agent`/`model`/`message`: 해당 없으면 `null`.

### 이벤트 종류 (기존 log_event 8개 호출점 → 매핑)

| events.jsonl `type`         | 기존 log_event 소스 (`kant-loop.sh`) |
|-----------------------------|--------------------------------------|
| `run_created`               | run 생성 시 (신규 emit)              |
| `agent_started`             | `QUICK_CALL` (:399)                  |
| `agent_completed` / `agent_verdict` | `QUICK_VERDICT` (:480)      |
| `agent_failed`              | `ADAPTER_FAIL` (:462)                |
| `fallback_used`             | `FALLBACK_USED` (:469)               |
| `fallback_attempt_started` / `fallback_attempt_failed` / `fallback_attempt_succeeded` | `FALLBACK_ATTEMPT` (`fallback-dispatcher.sh` `do_fallback()`) |
| `fallback_exhausted`        | `FALLBACK_EXHAUSTED` (`fallback-dispatcher.sh` `do_fallback()`) |
| `changed_files_mismatch`    | `CHANGED_FILES_MISMATCH` (:492)      |
| `parallel_review`           | `PARALLEL_REVIEW` (:558)             |
| `commit_created`            | `COMMIT` (:298)                      |
| `run_failed`                | `FAIL <code>` (:101)                 |
| `run_completed`             | 성공 종료 시 (신규 emit)             |

> Gate/Safety는 현재 별도 `log_event`가 아니라 `fail_run` **코드**(`GATE_FAILED`/`SAFETY_VIOLATION`)로만 `FAIL` 라인에 나타난다. 이번엔 그대로 `run_failed`에 code로 담고, 세분화(gate_started/passed 등)는 후속 Phase에서.

> (2026-07-24 갱신) per-repo `fallback.log`의 attempt/SUCCESS/EXHAUSTED 상세는 이제
> `FALLBACK_ATTEMPT`/`FALLBACK_EXHAUSTED` 이벤트로 해당 run의 `phase-events.log`에도
> 함께 기록되고 `events.jsonl`/`agents[].attempts[]`에 반영된다 — 처음에 실패한
> 원본 도구가 성공한 것처럼 오표기되는 문제와, 어떤 도구가 왜 몇 번 실패했는지 Dashboard
> 밖에서는(fallback.log를 직접 열어야) 안 보이던 문제를 함께 해결했다. `fallback.log`
> 자체는 여전히 별도로 존재하며(여러 run에 걸친 전역 로그), per-run 요약이 목적인
> `events.jsonl`을 대체하지 않는다.

---

## 3. 완료 조건

`kant-loop.sh run TASK.md --detach` 실행 후 Dashboard 없이 `run-state.json` + `events.jsonl`만 보고 run의 전체 lifecycle(시작→각 stage→agent별 verdict→성공/실패)을 복원할 수 있어야 한다.
