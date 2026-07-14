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

version() {
  command -v claude >/dev/null 2>&1 && claude --version 2>&1 | head -1 || echo "claude not installed"
}

# ---------------------------------------------------------------------------
# 자동 모델 감지: MiniMax-M3가 요청되었을 때 실제 사용 가능한 모델로 교체
# ---------------------------------------------------------------------------

resolve_claude_model() {
  local requested_model="$1"
  # MiniMax-M3는 항상 fallback chain의 마지막이므로 이 함수가 호출됨
  # 구독계정: claude auth status → loggedIn=true → claude-sonnet-5
  # API 키: ANTHROPIC_API_KEY 설정 → MiniMax-M3
  if [ "$requested_model" = "MiniMax-M3" ]; then
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      echo "MiniMax-M3"
    else
      # 구독계정 체크
      local auth_json
      auth_json=$(claude auth status 2>/dev/null || echo '{"loggedIn":false}')
      if python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('loggedIn') else 1)" <<< "$auth_json" 2>/dev/null; then
        # Pro 구독은 claude-sonnet-5 사용 가능
        echo "claude-sonnet-5"
      else
        echo "MiniMax-M3"
      fi
    fi
  else
    echo "$requested_model"
  fi
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

  model="$(resolve_claude_model "$model")"

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
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}")"; then
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