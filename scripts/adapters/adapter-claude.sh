#!/usr/bin/env bash
# adapter-claude.sh — Claude 자체 호출 (subagent 모드)
#
# 호출: claude -p "$(cat <prompt>)" --model <model> --permission-mode <mode> \
#        --tools <tools> --effort <effort>
# 완료 감지: exit code + stdout JSON

# kant-looper의 "최종 폴백"이자 "사용자가 명시적으로 claude 호출" 케이스용.
# 이 어댑터가 마지막 폴백이므로 실패 시 더 이상 fallback 없음.

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

health() {
  "$SKILL_LIB/health-check.sh" tool claude
}

# ---------------------------------------------------------------------------
# settings.json의 ANTHROPIC_* env를 매 호출마다 다시 읽어서 강제 적용
# ---------------------------------------------------------------------------
# 실측 확인된 문제: kant-looper를 실행 중인 Claude Code 세션(부모 프로세스)이
# 이미 ANTHROPIC_BASE_URL 등을 자기 값(예: https://api.anthropic.com)으로
# export해둔 상태라, ~/.claude/settings.json에 다른 엔드포인트(예: MiniMax)를
# 설정해놔도 자식 프로세스(claude CLI)는 부모의 값을 그대로 물려받아 키와
# 엔드포인트가 어긋나 401이 났다. settings.json은 사용자가 언제든 바꿀 수 있으므로
# 값을 하드코딩하지 않고, 호출할 때마다 그 시점의 settings.json을 다시 읽어서
# `env KEY=VALUE ...` 형태로 명시적으로 덮어쓴다.
#
# 출력 (stdout): "KEY=VALUE" 형태, 줄바꿈 구분. settings.json이 없거나
# env 섹션이 없으면 아무것도 출력하지 않는다 (그러면 claude는 평소처럼
# 부모 프로세스 환경을 그대로 물려받는다).

claude_settings_env_overrides() {
  local settings_file="${KANT_CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
  [ -f "$settings_file" ] || return 0

  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    env = d.get("env", {})
    for k, v in env.items():
        if k.startswith("ANTHROPIC_") and isinstance(v, str):
            print(f"{k}={v}")
except Exception:
    pass
' "$settings_file" 2>/dev/null
}

version() {
  command -v claude >/dev/null 2>&1 && claude --version 2>&1 | head -1 || echo "claude not installed"
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  if ! "$SKILL_LIB/health-check.sh" tool claude >/dev/null 2>&1; then
    echo "ERROR: claude unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-claude-${role}.json"
  local log_file="$io_dir/log-claude-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  local permission_mode="${KANT_CLAUDE_PERMISSION_MODE:-acceptEdits}"
  local tools="${KANT_CLAUDE_TOOLS:-Read,Write,Edit,Bash}"
  local effort="${KANT_CLAUDE_EFFORT:-medium}"

  # role별 tools/permission 조정
  case "$role" in
    plan|review|verify)
      permission_mode="dontAsk"
      tools="Read,Grep,Glob"
      effort="${KANT_CLAUDE_EFFORT:-high}"
      ;;
    implement|repair)
      permission_mode="acceptEdits"
      tools="Read,Write,Edit,Glob,Grep,Bash"
      effort="${KANT_CLAUDE_EFFORT:-medium}"
      ;;
  esac

  local cmd=(
    claude
    -p "$(cat "$prompt_file")"
    --model "$model"
    --permission-mode "$permission_mode"
    --tools "$tools"
    --effort "$effort"
    --output-format json
  )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  #
  # settings.json의 ANTHROPIC_* 값은 서브셸 안에서만 export한다 (커맨드라인
  # 인자로 넘기면 ps로 키가 노출되므로 절대 안 됨 — 일반 환경변수 상속 경로만 사용).
  local rc=0
  local runner_output
  if runner_output="$(
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      export "$line"
    done < <(claude_settings_env_overrides)
    "$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}"
  )"; then
    rc=0
  else
    rc=$?
  fi

  local json_text
  json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  if [ -z "$json_text" ]; then
    # claude는 마지막 폴백. 실패 시 fallback 없음 → 명시적 실패 보고
    echo "FAIL:FINAL_FALLBACK_FAILED"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/claude-${role}.json"
  printf '%s' "$json_text" > "$json_path"

  echo "$verdict|$json_path"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

case "${1:-}" in
  call)
    shift
    call "$@"
    exit $?
    ;;
  health)
    health
    exit $?
    ;;
  version)
    version
    exit 0
    ;;
  *)
    echo "adapter-claude.sh — Claude 자체 호출 어댑터 (subagent 모드)"
    echo ""
    echo "사용법:"
    echo "  adapter-claude.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-claude.sh health"
    echo "  adapter-claude.sh version"
    echo ""
    echo "주의: claude는 마지막 폴백. 실패 시 더 이상 fallback 없음."
    exit 1
    ;;
esac