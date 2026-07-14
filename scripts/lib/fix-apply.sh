#!/usr/bin/env bash
# fix-apply.sh — 메타 에이전트가 제안한 패치를 fix/ 브랜치에 적용 + 테스트 + 커밋
#
# 1. 메타 에이전트의 JSON 제안 (root_cause, fix_summary, branch_name, changes[], commands_to_run[]) 수신
# 2. 안전 검사: main 브랜치가 아닌 곳에서만 작업, 보호된 파일 변경 금지
# 3. fix/<name> 브랜치 생성 (없으면)
# 4. changes[] 적용
# 5. commands_to_run[] 실행 (회귀 테스트 등)
# 6. 통과 시에만 커밋
# 실패 시 메타 에이전트에 다시 알림 (또는 abort)

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILL_ROOT="$(cd "$SKILL_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 가드: main 브랜치 보호
# ---------------------------------------------------------------------------

guard_main_branch() {
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "main" ]; then
    echo "FATAL: meta-agent fix-apply는 main 브랜치에서 실행할 수 없습니다" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 가드: 허용된 경로만 변경 — symlink / 상위참조 / 절대경로 모두 차단
# ---------------------------------------------------------------------------

guard_path_allowed() {
  local file="$1"

  # 1) 절대경로 + .. 포함 + SKILL_ROOT 외부 거부
  case "$file" in
    "$SKILL_DIR"/scripts/*) ;;
    "$SKILL_DIR"/agents/*) ;;
    "$SKILL_DIR"/references/*.md) ;;
    *)
      echo "ERROR: meta-agent 변경 시도가 허용 영역 밖: $file" >&2
      return 1
      ;;
  esac

  # 2) 상위참조 (..)로 SKILL_ROOT 탈출 시도 거부
  local rel="${file#$SKILL_DIR/}"
  if echo "$rel" | grep -q "/\.\.\|^\.\.\|/\.\./"; then
    echo "ERROR: 경로에 상위참조 (..) 발견: $file" >&2
    return 1
  fi

  # 3) symlink로 영역 탈출 차단
  if [ -L "$file" ]; then
    local resolved
    resolved="$(cd "$(dirname "$file")" && readlink "$(basename "$file")" || echo "")"
    # SKILL_ROOT/ 접두 검사 후 거부
    case "$resolved" in
      "$SKILL_DIR"/*|"$SKILL_DIR") ;;
      *)
        echo "ERROR: symlink가 SKILL_ROOT 외부로 연결됨: $file -> $resolved" >&2
        return 1
        ;;
    esac
  fi

  return 0
}

# ---------------------------------------------------------------------------
# 가드: 재진입 방지 (idempotency marker)
# ---------------------------------------------------------------------------
# review critique: 메타 에이전트 루프가 실패 → 재분석 → 재시도 무한루프 방지.
# 동일 JSON proposal이 이미 적용되었거나 진행 중이면 즉시 거부한다.
# marker는 영구적으로 남는다 (run 단위 유일성). unlock은 하지 않는다.

guard_no_reentry() {
  local json_file="$1"
  local marker="${json_file}.applied"

  if [ -e "$marker" ]; then
    echo "FATAL: 동일 fix 제안이 이미 적용됨 ($marker) — 재진입 차단" >&2
    return 1
  fi

  # partial commit 감지 (.git/index에 staged 가 있는데 fix-commit은 안 된 상태)
  if [ -n "$(cd "$SKILL_ROOT" && git diff --cached --name-only 2>/dev/null || true)" ]; then
    echo "FATAL: staged 변경이 남아 있어 안전을 위해 재시도 차단. 수동 정리 후 다시 시도." >&2
    return 1
  fi

  return 0
}

mark_applied() {
  local json_file="$1"
  local marker="${json_file}.applied"
  # 메타 정보 기록 (SHA + timestamp) — 운영 디버깅 용도
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker"
  cd "$SKILL_ROOT" && git rev-parse HEAD >> "$marker" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# apply_fix
# ---------------------------------------------------------------------------
# 인자: JSON 파일 경로 (failure-analyzer가 출력한 fix 제안)
# 출력 (stdout): 적용된 커밋 SHA

apply_fix() {
  local json_file="$1"

  if [ ! -f "$json_file" ]; then
    echo "ERROR: json_file not found: $json_file" >&2
    return 1
  fi

  cd "$SKILL_ROOT"

  guard_main_branch || return 1
  guard_no_reentry "$json_file" || return 1

  # Python으로 JSON 파싱
  local branch_name
  branch_name=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['branch_name'])" 2>/dev/null || true)
  if [ -z "$branch_name" ]; then
    echo "ERROR: branch_name 없음" >&2
    return 1
  fi

  local fix_summary
  fix_summary=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['fix_summary'])" 2>/dev/null || echo "meta-agent fix")

  # 브랜치 생성/전환
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    git checkout "$branch_name" >/dev/null 2>&1 || return 1
  else
    # 베이스 브랜치에서 새 브랜치 생성
    local base_branch
    base_branch="$(git rev-parse --abbrev-ref HEAD)"
    git checkout -b "$branch_name" "$base_branch" >/dev/null 2>&1 || return 1
  fi

  # changes[] 적용
  local num_changes
  num_changes=$(python3 -c "import json,sys; print(len(json.load(open('$json_file')).get('changes',[])))" 2>/dev/null || echo 0)

  for ((i=0; i<num_changes; i++)); do
    local file old new
    file=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['changes'][$i]['file'])" 2>/dev/null)
    old=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['changes'][$i]['old_string'])" 2>/dev/null)
    new=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['changes'][$i]['new_string'])" 2>/dev/null)

    guard_path_allowed "$file" || return 1

    if [ -z "$file" ]; then
      echo "ERROR: changes[$i] file 없음" >&2
      return 1
    fi

    # 단일 파일 patch (file 내 old_string → new_string 교체)
    python3 -c "
import sys
with open('$file', 'r') as f:
    content = f.read()
old = '''$old'''
new = '''$new'''
if old not in content:
    print('ERROR: old_string not found in $file', file=sys.stderr)
    sys.exit(1)
content = content.replace(old, new, 1)
with open('$file', 'w') as f:
    f.write(content)
print('patched $file')
" || return 1
  done

  # 회귀 테스트 실행
  local commands_count
  commands_count=$(python3 -c "import json,sys; print(len(json.load(open('$json_file')).get('commands_to_run',[])))" 2>/dev/null || echo 0)

  for ((i=0; i<commands_count; i++)); do
    local cmd
    cmd=$(python3 -c "import json,sys; print(json.load(open('$json_file'))['commands_to_run'][$i])" 2>/dev/null)
    if [ -n "$cmd" ]; then
      echo "=== Running regression: $cmd ==="
      if ! bash -c "$cmd"; then
        echo "ERROR: regression failed for command: $cmd" >&2
        echo "메타 에이전트 fix가 회귀 테스트를 통과하지 못했습니다 — abort" >&2
        git checkout -- . >/dev/null 2>&1 || true
        return 1
      fi
    fi
  done

  # 커밋
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "fix(meta): $fix_summary" >/dev/null 2>&1 || {
      echo "ERROR: commit failed" >&2
      return 1
    }
  fi

  # idempotency marker — 동일 json_file로 재시도 차단
  mark_applied "$json_file"

  local commit_sha
  commit_sha="$(git rev-parse HEAD)"
  echo "$commit_sha"
}

case "${1:-}" in
  apply)
    shift
    apply_fix "$@"
    ;;
  *)
    echo "fix-apply.sh — 메타 에이전트 패치 적용"
    echo ""
    echo "사용법:"
    echo "  fix-apply.sh apply <json_file>"
    exit 1
    ;;
esac
