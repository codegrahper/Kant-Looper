# Kant Dashboard — UI Scope (v1)

**문서 상태:** Phase 0 산출물 → Phase 3에서 구현
**핵심:** 이 문서는 **담을 데이터(정보 구조)**를 고정한다. **시각 디자인(레이아웃/색/타이포)은 여기서 확정하지 않는다.**

---

## 0. 디자인 확정 절차

- 첨부된 목업은 **참고용**일 뿐 확정 시안이 아니다.
- 실제 시안은 **agy Stitch에서 최소 3개**를 뽑아 이바가 보고 확정한 뒤 구현한다.
- **dark mode 지원 필수** (light/dark 둘 다). 상태 색상은 두 테마에서 각각 검증한다.

---

## 1. 화면 4개 (읽기전용 MVP)

### 화면 1 — Run List
run별: 이름/task, status(색상), 현재 stage, 경과/결과.
데이터: `GET /api/runs`.

### 화면 2 — Run Detail
Task · Status · Elapsed · Branch · Worktree · Current Stage · Current Agent · Result.
데이터: `GET /api/runs/{id}` (run-state.json).

### 화면 3 — Pipeline
단계 진행 표시: preflight → worktree → implement → gate → review → repair → verify → commit.
각 단계에 상태 아이콘 + 담당 tool. **가짜 % 금지** — `N/7 stages` 방식.
데이터: run-state.json의 `stage` + `agents[]`.

### 화면 4 — Activity
`events.jsonl`을 SSE로 실시간 표시 (시각 · type · agent).
데이터: `GET /api/runs/{id}/stream`.

### 우측 Inspector (Phase 3는 요약만)
stage/agent 클릭 시 verdict · Findings 개수 · Risks. 상세 Findings/Changed Files/Tests는 Phase 5.
데이터: `agents[]` (verdict), 상세는 `<worktree>/.kant-looper/<tool>-<role>.json`.

---

## 2. 상태 색상 semantic (light·dark 각각 정의)

`Waiting` · `Running` · `Success` · `Warning` · `Failed` · `Blocked` · `Cancelled`.

## 3. 완료 조건

터미널에서 `kant-loop.sh run` 실행 시 Dashboard가 새 run을 자동 감지하고, 진행 상태·현재 Agent·성공/실패를 실시간으로 보여준다. (아직 Dashboard에서 실행 트리거는 하지 않는다.)
