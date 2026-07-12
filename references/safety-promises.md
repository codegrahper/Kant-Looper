# safety-promises.md

> kant-looper가 자동으로 하지 않는 것 + 안전 약속 전체 목록. SKILL.md 본문에는 5줄 요약만, 상세는 이 문서에.

## 자동으로 하지 않는 것 (절대 금지)

### 1. 자동 push 금지

어떤 원격에도 push를 자동 실행하지 않습니다. 사용자가 명시적으로 `git push` 명령을 실행해야 합니다.

스크립트 내부 grep 검사:
```bash
# kant-loop.sh 안에서 다음 패턴이 나오면 즉시 빌드 실패
grep -E 'git push|git\\s+push' scripts/kant-loop.sh scripts/adapters/*.sh scripts/lib/*.sh && exit 1
```

### 2. 자동 merge commit 금지

오직 fast-forward merge만 허용. 사용자가 `kant-loop.sh promote` 명령으로 명시 실행.

merge commit (no-ff)이 발생하면 절대 안 됨. ff-only 강제.

### 3. rebase / reset --hard / branch -D 금지

이 명령들은 작업 브랜치를 망가뜨릴 수 있어 자동 실행 안 됨.

스크립트 grep 검사:
```bash
grep -E 'git rebase|git\\s+reset.*--hard|git branch -D' scripts/kant-loop.sh scripts/adapters/*.sh scripts/lib/*.sh && exit 1
```

### 4. main 브랜치 직접 커밋 금지

`BRANCH_PREFIX=agent/kant`로 시작하는 작업 브랜치에만 커밋. main/master/develop 어느 것도 직접 커밋 안 됨.

체크:
```bash
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] && echo "BLOCKED: main에 직접 커밋 불가" && exit 1
```

### 5. protected paths 변경 금지

`.env`, `*.pem`, `*.key`, `*credential*`, `*secret*` 변경 시 즉시 중단.

기본 PROTECTED_PATHS:
```
.git
node_modules
dist
build
__pycache__
.venv
.env
.env.local
.env.*.local
*.pem
*.key
*credential*
*secret*
*password*
```

### 6. forbidden patterns 검사

staged diff 내에서 다음 패턴 발견 시 중단:
- `AKIA[0-9A-Z]{16}` (AWS access key)
- `sk-[a-zA-Z0-9]{20,}` (API key prefix)
- `-----BEGIN .* PRIVATE KEY-----`
- Bearer 토큰, JWT 패턴 등

### 7. 작업 범위 외 변경 거부

`PROTECTED_PATHS` 외라도 TASK.md에 명시되지 않은 파일 변경은 경고 + 사용자 확인.

### 8. 단일 파일 크기 제한

`MAX_FILE_BYTES=10485760` (10MB). 초과 시 INVALID_OUTPUT + 즉시 중단.

### 9. destructive commands 거부

스크립트 안에서 다음 명령 절대 실행 안 됨:
```bash
rm -rf /
rm -rf *
mkfs
dd if=
chmod 777 /etc/*
iptables -F
```

### 10. 외부 API 키 입력 금지

`.env`, SSH 키, 클라우드 자격증명, 쿠키는 모델 입력에 절대 넣지 않음.

## 빈 hooksPath + gpgSign=false commit

`scripts/kant-loop.sh:commit_reviewed_diff`는 빈 hooksPath와 gpgSign 비활성화 commit:

```bash
EMPTY_HOOKS_DIR=$(mktemp -d)
touch "$EMPTY_HOOKS_DIR/.gitkeep"

git -c core.hooksPath="$EMPTY_HOOKS_DIR" \
    -c commit.gpgSign=false \
    -c user.name="kant-looper" \
    -c user.email="kant-looper@local" \
    commit -F "$RUN_STATE_DIR/commit-message.txt"

rm -rf "$EMPTY_HOOKS_DIR"
```

이는 시스템의 git hooks와 자동 서명을 우회해 commit 결과를 안전하게 통제.

## macOS notification 정책

`scripts/lib/notify.sh`:

```bash
notify_final() {
  local result="$1" detail="$2"
  if [ "$NOTIFY" = "1" ] && [ "$NOTIFY_OSASCRIPT" = "1" ]; then
    osascript -e "display notification \"$detail\" with title \"kant-looper: $result\" sound name \"Funk\""
  fi
  # dedup: 같은 detail은 1회만 발사 (.notification-${event}.sent marker)
}
```

- 시작/라운드 전환: `notify_phase` (선택)
- 완료: `notify_final "completed" "RUN_ID: $run_id, COMMIT: $commit_sha"`
- fallback 발생: `notify_final "fallback" "$tool → $next ($failure_mode)"`
- 실패: `notify_final "failed" "$failure_code - $message"`

## Claude 작업 범위 제한 (allowed-tools)

`SKILL.md` frontmatter의 `allowed-tools`:

```yaml
allowed-tools:
  - "Bash(scripts/kant-loop.sh:*)"   # script 자체 호출만
  - "Bash(git status:*)"
  - "Bash(git diff:*)"
  - "Bash(git log:*)"
  - "Bash(git rev-parse:*)"
  - "Read"
  - "Write"                           # state-summary.json 등
```

다음은 절대 호출 불가:
- `Bash(git push:*)`
- `Bash(git merge:*)`
- `Bash(git rebase:*)`
- `Bash(git reset:*)`
- `Bash(rm:*)` (자식 어댑터 안에서만 허용)
- `Bash(any destructive)`

3중 강제:
1. `allowed-tools` (Claude 세션 정책)
2. 스크립트 내부 grep 검사
3. `promote` 서브커맨드 분리로 사용자 명시 실행만 허용

## 안전 약속 검증 (CI)

```bash
# safety-check.sh 의 self-test 모드
bash scripts/lib/safety-check.sh self-test
# → 모든 금지 명령 grep
# → PROTECTED_PATHS / FORBIDDEN_PATTERNS 검사
# → exit 0 = 안전
```

자동으로 매 스크립트 수정 시 실행 권장. 실패 시 빌드 거부.
