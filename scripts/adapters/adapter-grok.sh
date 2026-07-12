#!/usr/bin/env bash
# adapter-grok.sh — xAI Grok CLI 어댑터 (Grok Build / Grok Agent)
#
# 호출: grok -p "$(cat <prompt>)" --cwd <worktree> -m <model> \
#        --output-format json --json-schema <schema> --verbatim \
#        --disable-web-search --no-subagents --sandbox read-only \
#        --permission-mode dontAsk --allow Read --allow Grep \
#        --deny 'Bash(*)' --deny 'Edit(*)' --reasoning-effort <effort>
# 완료 감지: exit code + streaming-json 마지막 이벤트

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
  "$SKILL_LIB/health-check.sh" tool grok
}

version() {
  command -v grok >/dev/null 2>&1 && grok --version 2>&1 | head -1 || echo "grok not installed"
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

  if ! "$SKILL_LIB/health-check.sh" tool grok >/dev/null 2>&1; then
    echo "ERROR: grok unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-grok-${role}.json"
  local log_file="$io_dir/log-grok-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  local schema_file="$ADAPTER_DIR/../schemas/${role}-schema.json"

  # role에 따른 sandbox 모드 결정
  # - plan / review / verify: read-only
  # - implement / repair: workspace-write
  local sandbox_mode
  case "$role" in
    plan|review|verify)
      sandbox_mode="read-only"
      ;;
    implement|repair)
      sandbox_mode="workspace-write"
      ;;
    *)
      sandbox_mode="read-only"
      ;;
  esac

  # role에 따른 permission_mode 결정
  # - read-only 단계: dontAsk + Read/Grep만
  # - implement 단계: workspace-write에서는 Edit/Bash도 일부 허용 필요
  local permission_mode="dontAsk"
  local allow_extra=""
  case "$role" in
    implement|repair)
      permission_mode="acceptEdits"
      allow_extra="--allow Edit --allow Bash"
      ;;
  esac

  # Grok은 prompt를 -p 인자로 받음. 임시 파일에서 stdin 파이프도 가능.
  local cmd=(
    grok
    --no-auto-update
    -p "$(cat "$prompt_file")"
    --cwd "$worktree"
    -m "$model"
    --output-format json
    --verbatim
    --disable-web-search
    --no-subagents
    --sandbox "$sandbox_mode"
    --permission-mode "$permission_mode"
    --allow Read
    --allow Grep
  )

  # json-schema 추가 (옵션)
  if [ -f "$schema_file" ]; then
    cmd+=( --json-schema "$schema_file" )
  fi

  # implement/repair 단계에서 Edit/Bash 일부 허용
  if [ -n "$allow_extra" ]; then
    IFS=' ' read -ra extras <<< "$allow_extra"
    cmd+=( "${extras[@]}" )
  fi

  # reasoning effort (grok-4.5 이상에서 유효)
  local effort="${KANT_GROK_REASONING_EFFORT:-high}"
  if printf '%s' "$model" | grep -qE 'grok-4\.'; then
    cmd+=( --reasoning-effort "$effort" )
  fi

  # json-schema 추가 (옵션)
  if [ -f "$schema_file" ]; then
    cmd+=( --json-schema "$schema_file" )
  fi

  # reasoning effort (grok-4.5 이상에서 유효)
  local effort="${KANT_GROK_REASONING_EFFORT:-high}"
  if printf '%s' "$model" | grep -qE 'grok-4\.'; then
    cmd+=( --reasoning-effort "$effort" )
  fi

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
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "grok" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/grok-${role}.json"
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
    echo "adapter-grok.sh — xAI Grok CLI 어댑터"
    echo ""
    echo "사용법:"
    echo "  adapter-grok.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-grok.sh health"
    echo "  adapter-grok.sh version"
    exit 1
    ;;
esac