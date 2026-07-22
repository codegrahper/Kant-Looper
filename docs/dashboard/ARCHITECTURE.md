# Kant Dashboard — Architecture (v1)

**문서 상태:** Phase 0 산출물 (Scope Freeze)
**목적:** "이 기능은 Kant Core가 담당하는가, Dashboard가 담당하는가"를 누구나 즉시 판단할 수 있게 한다.

---

## 1. 경계 (Brain / Bridge / Eyes)

```
┌───────────────────────────────┐
│         Kant Dashboard        │   Eyes + Controls
│   사람에게 보여준다            │   (dashboard/web — 단일 HTML+JS)
│   사람의 명령을 받는다         │
└───────────────┬───────────────┘
                │  REST + SSE (127.0.0.1)
┌───────────────▼───────────────┐
│        Kant Local Server       │   Bridge
│   상태를 읽고 명령을 전달       │   (dashboard/server — FastAPI, 읽기전용)
└───────────────┬───────────────┘
                │  파일 읽기 + subprocess (Phase 4~)
┌───────────────▼───────────────┐
│          Kant Core             │   Brain
│  routing / gate / review       │   (scripts/kant-loop.sh + lib + adapters)
│  repair / worktree / commit    │
└───────────────┬───────────────┘
        ┌───────┼───────┐
        ▼       ▼       ▼
     Codex   Claude  OpenCode ...
```

**핵심 원칙:** Kant Core는 UI 때문에 다시 작성하지 않는다. Dashboard는 `명령 전달 + 상태 관찰 + 결과 시각화`만 한다.

---

## 2. Core의 책임 (Dashboard가 절대 재구현하지 않음)

AI routing · adapter 호출 · fallback · worktree 생성 · Gate · safety check · review 판단 · repair · commit 판단 · 모든 orchestration 결정.

이 기능들은 계속 `scripts/kant-loop.sh`, `scripts/lib/`, `scripts/adapters/`가 담당한다.

## 3. Dashboard의 책임

Project 선택 · Task 작성(Phase 4~) · Kant 실행 트리거(Phase 4~) · 실행 목록 조회 · 현재 상태/단계/Agent/model 표시 · Event 표시 · Verdict/Findings/변경파일/테스트 표시 · 중지(Phase 4~) · 재실행(Phase 4~).

**이번 범위(Phase 0–3)는 읽기전용이다.** 실행 트리거·중지는 Phase 4 이후.

## 4. 범위 밖 (AO를 복제하지 않는다 — 별도 프로젝트로 취급)

GitHub PR/CI Dashboard · 브라우저 Preview · Web IDE · Full Terminal · 원격 orchestration · 다중 사용자 · 팀 협업 · Cloud Sync · Windows/Linux · Electron/Tauri. 아이디어 출처는 AgentWrapper/agent-orchestrator(AO) 리서치지만 **AO를 복제하지 않는다.**

---

## 5. 왜 이 순서인가 (State → API → UI)

UI를 먼저 만들면 "현재 Kant가 무슨 단계인지"를 로그 문자열 parsing으로 추측하게 되고 → 예외 증가 → Dashboard와 Core 강결합. 그래서 **Stable State Contract(Phase 1)를 먼저** 만들고 그 위에 API, 그 위에 UI를 얹는다. Phase 1만 완료돼도 Core에 구조화된 observability가 남으므로 **실패 비용이 낮다.**

## 6. 기술 스택

- **Server:** Python + FastAPI + Pydantic + SSE (Kant가 이미 python3를 부분 사용, 파일→JSON 변환·subprocess·SSE 구현이 간단)
- **Web:** 빌드 스텝 없는 단일 HTML + vanilla JS (`fetch` + `EventSource`). React/Vite는 v1에서 쓰지 않는다.
- **접속:** `http://127.0.0.1:7419` (localhost 전용 bind, `0.0.0.0` 금지)

## 7. 불변식 (v1 내내 유지)

- Dashboard가 없어도 Kant CLI가 정상 작동한다.
- Dashboard server가 죽어도 Kant run은 계속된다 (run은 detached 프로세스).
- Kant가 죽어도 Dashboard server는 죽지 않는다.
- malformed state가 있어도 Dashboard 전체가 죽지 않는다 (개별 run만 error 격리).
- 기존 safety/gate 정책을 우회하지 않는다.
- 기존 `phase-events.log` 및 flat state 파일은 삭제하지 않는다.
