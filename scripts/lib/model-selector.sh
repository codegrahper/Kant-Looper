#!/usr/bin/env bash
# model-selector.sh — 모델 선택 인터페이스
#
# 사용법:
#   model-selector.sh auto TASK.md          # 자동 라우팅
#   model-selector.sh list-agents          # 사용 가능한 agent 목록
#   model-selector.sh list-models <agent>  # agent가 지원하는 모델 목록
#   model-selector.sh validate <tool> <model>  # 모델 유효성 검증
#   model-selector.sh select <agent> <model>   # 선택 확정

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
ROUTING_PARSER="$LIB_DIR/routing-parser.sh"

# ---------------------------------------------------------------------------
# 사용 가능한 agent 목록
# ---------------------------------------------------------------------------

list_agents() {
  cat <<EOF
codex
opencode
grok
agy
claude
EOF
}

# ---------------------------------------------------------------------------
# agent별 지원 모델 목록
# ---------------------------------------------------------------------------
# 주의: 이 목록은 routing-guide.md와 실제 어댑터调研 결과 기반.
# 실제 모델 가용성은 health-check로 별도 검증 필요.

list_models() {
  local agent="$1"
  case "$agent" in
    codex)
      cat <<EOF
gpt-5.6-sol
gpt-5.6-terra
gpt-5.6-luna
EOF
      ;;
    opencode)
      cat <<EOF
glm-5.2
glm-4.7
MiniMax-M3
MiniMax-M2.7
MiniMax-M2.7-highspeed
EOF
      ;;
    grok)
      cat <<EOF
grok-4.5
grok-4.3
grok-build-0.1
EOF
      ;;
    agy)
      cat <<EOF
gemini-3.5-flash
gemini-3.1-pro-preview
gemini-3.1-flash-lite
EOF
      ;;
    claude)
      cat <<EOF
default
EOF
      ;;
    *)
      echo "ERROR: unknown agent: $agent" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 자동 라우팅
# ---------------------------------------------------------------------------
# routing-parser.sh를 이용해서 TASK 내용에서 적절한 tool:model 결정

auto_select() {
  local task_file="$1"

  if [ ! -f "$task_file" ]; then
    echo "ERROR: task file not found: $task_file" >&2
    return 1
  fi

  local result
  result="$("$ROUTING_PARSER" match "$task_file" 2>/dev/null || true)"

  if [ -z "$result" ]; then
    # 폴백: 기본값
    echo "codex:gpt-5.6-terra"
    return 0
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# 모델 유효성 검증
# ---------------------------------------------------------------------------

validate() {
  local tool="$1" model="$2"

  if [ -z "$tool" ] || [ -z "$model" ]; then
    echo "ERROR: tool and model required" >&2
    return 1
  fi

  local supported_models
  supported_models="$(list_models "$tool")"

  if ! echo "$supported_models" | grep -qx "$model"; then
    echo "ERROR: model '$model' not supported for agent '$tool'" >&2
    echo "支持的模型:" >&2
    echo "$supported_models" >&2
    return 1
  fi

  echo "OK"
}

# ---------------------------------------------------------------------------
# 선택 확정
# ---------------------------------------------------------------------------

confirm() {
  local tool="$1" model="$2"

  # 유효성 검증
  if ! validate "$tool" "$model" >/dev/null 2>&1; then
    return 1
  fi

  echo "${tool}:${model}"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
model-selector.sh — 모델 선택 인터페이스

사용법:
  model-selector.sh auto TASK.md          # 자동 라우팅 (routing-parser.sh 사용)
  model-selector.sh list-agents           # 사용 가능한 agent 목록
  model-selector.sh list-models <agent>   # agent가 지원하는 모델 목록
  model-selector.sh validate <tool> <model>  # 모델 유효성 검증
  model-selector.sh select <tool> <model>    # 선택 확정

예시:
  # 자동 라우팅
  model-selector.sh auto /tmp/task.md

  # agent 목록
  model-selector.sh list-agents

  # opencode가 지원하는 모델
  model-selector.sh list-models opencode

  # 모델 검증
  model-selector.sh validate opencode glm-5.2

  # 선택 확정
  model-selector.sh select codex gpt-5.6-sol
EOF
}

case "${1:-}" in
  auto)
    shift
    auto_select "$@"
    ;;
  list-agents)
    list_agents
    ;;
  list-models)
    shift
    list_models "$@"
    ;;
  validate)
    shift
    validate "$@"
    ;;
  select)
    shift
    confirm "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
