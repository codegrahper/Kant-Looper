# Meta Agent Host Contract v1

이 문서는 Claude Code, Codex, OpenCode 및 향후 추가될 런타임이 Nomad Kant
Looper의 **Meta Agent Host**가 되기 위해 보장해야 하는 최소 계약을 정의한다.
여기서 Host는 Meta Agent를 구동하는 런타임 축이며, 외부 Worker CLI의 호출 규약을
담는 Worker Provider 축(`scripts/adapters/*.sh`)과는 별개다. 이 구분의 기준은
`platform/README.md`의 **「두 축의 경계 (반드시 구분할 것)」** 절이다.

이 계약은 새 실행 엔진, 설정 파서 또는 상태 머신을 요구하지 않는다. 기존
`SKILL.md`와 셸 백엔드를 동일하게 발견하고 호출하며 그 결과를 관찰할 수 있는지를
검증 가능한 형태로 정리한다.

## 1. Skill 발견 (Skill Discovery)

### ① 계약 내용

Host 런타임은 설치된 `SKILL.md`를 발견하고 로드하여 Meta Agent의 지침으로 삼을
수 있어야 한다. 특히 Step 0부터 Step 3까지의 흐름과 **「Rules」** 절을 런타임의
실행 지침으로 적용해야 한다. 따라서 Meta Agent는 사용자의 의도를 Worker에게
전달하는 오케스트레이터이며 작업을 직접 구현하지 않는다.

### ② 실제 코드/문서 앵커

- `SKILL.md` — **「`/nomad-kant-looper` Meta Agent」**, **「Step 0」**~**「Step 3」**,
  **「Rules」**(“Meta Agent는 작업을 직접 구현하지 않는다”).
- 런타임별 설치 위치 — `platform/<runtime>.md`의 설치 관련 절. 현재 Claude Code의
  구체적인 예는 `platform/claude-runtime.md`의 **「설치 경로」** 절이다.

### ③ 확인 방법

해당 런타임의 문서화된 설치 위치에 Skill을 설치한 뒤, 런타임이 `SKILL.md`의
`name`과 `description`을 발견하고 호출 시 Step 0~3 및 Rules를 지침으로 로드하는지
확인한다. 작업 요청을 주었을 때 Host가 직접 구현하지 않고 선택과 작업지시 작성,
백엔드 호출로 이어지는지도 함께 확인한다.

## 2. Skill 루트 해석 (`$SKILL_DIR`)

### ① 계약 내용

Host 런타임은 현재 로드한 `SKILL.md`의 실제 설치 디렉터리를 절대경로로 해석하여
`$SKILL_DIR`로 사용할 수 있어야 한다. 이 값으로 현재 작업 디렉터리와 무관하게
`bash "$SKILL_DIR/scripts/kant-loop.sh" ...` 형태의 백엔드 호출이 가능해야 한다.

### ② 실제 코드/문서 앵커

- `SKILL.md` — **「Step 3」 > 「실행」**의 `$SKILL_DIR` 정의와 실행 명령.
- `platform/claude-runtime.md` — **「설치 경로」**(Claude Code의 기본 설치 경로
  `$HOME/.claude/skills/nomad-kant-looper`).

### ③ 확인 방법

런타임의 기본 설치 위치가 아닌 작업 디렉터리에서 Skill을 호출하고, 런타임이
해석한 절대경로의 `scripts/kant-loop.sh`가 실제 파일인지 확인한다. 이어서
`bash "$SKILL_DIR/scripts/kant-loop.sh" --help`가 성공하는지 확인한다.

## 3. 사용자 선택 (User Selection with graceful degradation)

### ① 계약 내용

Host는 도구와 모델을 사용자가 선택할 수 있게 해야 한다. 런타임에 구조화된 선택
UI가 있으면 이를 사용하고, 없으면 번호가 붙은 텍스트 선택지로, 그것도 지원되지
않으면 평문 질문으로 폴백한다. 어떤 Host든 최소한 평문 질문과 사용자 응답 수신은
가능해야 한다. `--agent`와 `--model`이 직접 주어진 비대화형 실행에서는 선택 UI를
건너뛰어야 한다.

### ② 실제 코드/문서 앵커

- `SKILL.md` — **「Step 2」 > 「선택형 UI 가용성」**(구조화된 선택 UI와 텍스트
  입력 폴백).
- `SKILL.md` — **「Step 2」 > 「비대화형 실행」**(`--agent`와 `--model` 직접 전달
  시 Step 3으로 진행).
- `scripts/kant-loop.sh` — `cmd_run`의 `--agent`, `--model` 인자 처리.

### ③ 확인 방법

구조화 UI가 있는 환경에서는 도구/모델 선택 컨트롤이 표시되는지 확인한다. 해당
UI를 끈 환경에서는 번호 목록 또는 평문 질문으로 같은 선택을 받을 수 있는지
확인한다. 별도로 `--agent <tool> --model <model>`을 모두 전달했을 때 추가 선택
질문 없이 Step 3 실행으로 이어지는지 확인한다.

## 4. 백엔드 실행 (Backend Invocation)

### ① 계약 내용

Host의 선택 방식이나 UI가 무엇이든 최종 실행은 다음과 같은 동일한 셸 호출로
귀결되어야 하며, Host는 이 명령을 실행하고 종료 상태와 출력을 받을 수 있어야 한다.

```bash
bash "$SKILL_DIR/scripts/kant-loop.sh" run "TASK.md" --quick --agent "$tool" --model "$model"
```

### ② 실제 코드/문서 앵커

- `SKILL.md` — **「Step 3」 > 「실행」**의 기본 foreground 실행 명령.
- `scripts/kant-loop.sh` — `cmd_run` 함수와 파일 끝의 **「메인 dispatch」** `run`
  서브커맨드 분기.

### ③ 확인 방법

유효한 `TASK.md`, 도구, 모델을 넣어 위 명령을 foreground로 실행하고 `cmd_run`으로
디스패치되는지 확인한다. `--dry-run`을 함께 사용하면 Worker 실행 없이 해석된 mode,
task, route, run ID를 확인할 수 있다.

## 5. 인간 주권 / 안전 경계 (Human Sovereignty)

### ① 계약 내용

Host는 자동 push, main 직접 커밋, 임의 merge, 파괴적 Git 연산(`reset --hard`,
`branch -D`, `push --force`)을 실행하지 않는다. 병합은 사용자가
`promote BRANCH --target TARGET`을 명시적으로 호출할 때만 가능하며, 백엔드는
`git merge --ff-only`만 사용한다. 또한 `.env`, `*.key`, `*credential*` 등 보호
경로가 포함되거나 secret 패턴이 발견된 변경은 커밋 전에 차단되어야 한다.

여기에는 서로 다른 두 보장 방식이 있다.

- **구조적 보장:** 자동 실행 경로에 `reset --hard`, `branch -D`, `push --force`
  같은 호출이 존재하지 않으며, merge의 유일한 실행 경로는 사용자 명시 호출인
  `cmd_promote`의 `git merge --ff-only`다. 이는 작업 변경을 실행 중 능동적으로
  탐지·차단하는 전용 destructive-op 가드가 있다는 뜻이 아니다.
- **능동 차단:** 보호 경로와 secret 패턴은 `check_protected_paths`와
  `check_forbidden_patterns`가 실제 변경 내용을 검사하고 위반 시 실패시킨다.

`scripts/lib/safety-check.sh`의 `self_test`는 백엔드 스크립트 안의 금지 명령을
정적으로 grep하는 자체 검사도 제공하지만, Worker의 작업 변경에서 destructive Git
연산을 실행 중 가로채는 전용 차단기는 아니다. 따라서 이 자체 검사를 보호 경로·
secret 패턴의 능동 차단과 동일한 보장으로 간주해서는 안 된다.

### ② 실제 코드/문서 앵커

- `scripts/kant-loop.sh` — 파일 머리의 **「안전 약속」** 주석.
- `scripts/kant-loop.sh` — `do_commit`의 main/master 직접 커밋 차단.
- `scripts/kant-loop.sh` — `cmd_promote`(사용자 명시 서브커맨드, 상태 및 tree 검증,
  `git merge --ff-only`).
- `scripts/lib/safety-check.sh` — `check_protected_paths`,
  `check_forbidden_patterns`, `run_all_checks`; 참고로 스크립트 정적 검사는 `self_test`.
- `scripts/kant-loop.sh` — `do_safety_check`에서 스테이징 후
  `safety-check.sh all`을 호출하는 경로.

### ③ 확인 방법

다음 두 종류의 검증을 구분하여 수행한다.

1. `scripts/kant-loop.sh`의 실제 Git 호출을 검색해 자동 push와 위 파괴적 연산이
   없고, 실행 가능한 merge가 `cmd_promote`의 `git merge --ff-only`뿐인지 확인한다.
   `promote`는 미완료 run을 거부하고 명시 호출 없이는 실행되지 않는지도 확인한다.
2. 격리된 테스트 worktree에서 보호 경로 변경과 금지 secret 패턴을 각각 만들고
   `scripts/lib/safety-check.sh paths <worktree>` 및 `patterns <worktree>`가 비영(非零)
   종료하는지 확인한다. 통합 경로는 `all <worktree>`로 확인한다.

## 6. 완료 확인 (Completion Observability)

### ① 계약 내용

Host는 foreground와 background 실행 모두에서 run의 최종 상태를 확인할 수 있어야
한다. 최소한 실행 중 여부와 `completed` 또는 `failed` 같은 최종 결과를 읽고,
Worker verdict가 기록된 실행 이벤트를 확인할 수 있어야 한다. Background 실행은
run ID를 보존한 뒤 상태 조회 또는 완료 대기를 수행해야 한다.

### ② 실제 코드/문서 앵커

- `scripts/kant-loop.sh` — `cmd_status`(상태와 최근 `phase-events.log` 출력).
- `scripts/kant-loop.sh` — `cmd_await`(`result.txt`가 종결 값을 가질 때까지 폴링한
  뒤 `cmd_status` 요약 출력).
- `scripts/kant-loop.sh` — 각 run의 `$state_dir/result.txt`; Worker verdict는
  `run_quick_mode`가 `QUICK_VERDICT` 이벤트로 `$state_dir/phase-events.log`에 기록.
- `SKILL.md` — **「Step 3」 > 「실행」**의 foreground 완료 의미와 `--detach`/`await`
  사용법.

### ③ 확인 방법

Foreground 실행에서는 셸 호출의 종료 코드와 마지막 결과 요약을 확인한다.
`--detach` 실행에서는 반환된 run ID로 `kant-loop.sh status <run_id>`를 호출하여
현재 결과를 조회하고, `kant-loop.sh await <run_id>`가 종결 상태에서 반환되는지
확인한다. 해당 run의 `result.txt`와 `phase-events.log`를 대조하여 최종 결과와
verdict 이벤트가 관찰 가능한지도 확인한다.

위 여섯 계약을 모두 만족하면 해당 런타임은 **Host Contract v1을 준수한다**고 말할
수 있다. 각 런타임의 실제 준수 현황(`native` / `degraded` / `unsupported`)은 이후
Stage에서 `platform/<runtime>.md`의 capability 표로 채운다. capability 표 작성은
이 문서의 범위에 포함하지 않는다.
