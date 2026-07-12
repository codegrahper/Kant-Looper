#!/usr/bin/env bash
# no-progress-detector.sh — 무진전 감지 (routing 가이드 10.2)
#
# 매 phase 끝마다 state 디렉터리를 검사해서 진척 없음 감지.
# 같은 diff 3회, 같은 테스트 실패 2회, 10회 도구 호출 동안 변화 없음 등.
#
# bash 3.2 호환.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 임계값 (env override 가능)
SAME_DIFF_LIMIT="${KANT_SAME_DIFF_LIMIT:-3}"
SAME_TEST_FAIL_LIMIT="${KANT_SAME_TEST_FAIL_LIMIT:-2}"
TOOL_CALLS_NO_PROGRESS_LIMIT="${KANT_TOOL_CALLS_NO_PROGRESS_LIMIT:-10}"
MAX_ELAPSED_SECONDS="${KANT_MAX_ELAPSED_SECONDS:-1800}"
MAX_TOKENS="${KANT_MAX_TOKENS:-500000}"
MAX_COST_USD="${KANT_MAX_COST_USD:-5.0}"

# ---------------------------------------------------------------------------
# 메인 감지 함수
# ---------------------------------------------------------------------------
# 인자: state_dir (RUN_ID의 디렉터리)
# 출력 (stdout): OK | NO_PROGRESS | SAFETY_BLOCK
# 종료 코드: 0 = OK, 1 = NO_PROGRESS, 2 = SAFETY_BLOCK

detect_no_progress() {
  local state_dir="$1"

  if [ ! -d "$state_dir" ]; then
    echo "OK"
    return 0
  fi

  # 1. 같은 diff 3회 (phase-events.log에 같은 hash 등장 횟수)
  local same_diff_count
  same_diff_count=$(grep -c 'diff_hash=' "$state_dir/phase-events.log" 2>/dev/null | head -1 || echo "0")
  if [ "${same_diff_count:-0}" -ge "$SAME_DIFF_LIMIT" ] 2>/dev/null; then
    echo "NO_PROGRESS:same_diff_count=$same_diff_count"
    return 1
  fi

  # 2. 같은 테스트 실패 2회 (gates-round-*/*.log에서 같은 FAIL 라인)
  local same_test_fail=0
  if compgen -G "$state_dir/gates-round-*/*.log" >/dev/null 2>&1; then
    local log_file
    while IFS= read -r log_file; do
      [ -z "$log_file" ] && continue
      local fails
      fails=$(grep -cE 'FAIL|ERROR|✘|test failed' "$log_file" 2>/dev/null || echo "0")
      same_test_fail=$((same_test_fail + fails))
    done < <(find "$state_dir" -path "$state_dir/gates-round-*/*.log" 2>/dev/null)
  fi
  if [ "${same_test_fail:-0}" -ge "$SAME_TEST_FAIL_LIMIT" ] 2>/dev/null; then
    echo "NO_PROGRESS:same_test_fail_count=$same_test_fail"
    return 1
  fi

  # 3. 10회 이상 도구 호출 동안 진척 없음
  local tool_call_count
  tool_call_count=$(grep -cE '^\[.*\] (call|invoke|attempt)' "$state_dir/phase-events.log" 2>/dev/null | head -1 || echo "0")
  if [ "${tool_call_count:-0}" -ge "$TOOL_CALLS_NO_PROGRESS_LIMIT" ] 2>/dev/null; then
    # 진척 체크: diff_hash 변화가 있어야 함
    local unique_diff_count
    unique_diff_count=$(grep -oE 'diff_hash=[a-f0-9]+' "$state_dir/phase-events.log" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo "0")
    if [ "${unique_diff_count:-0}" -le 1 ] 2>/dev/null; then
      echo "NO_PROGRESS:tool_calls=${tool_call_count},unique_diffs=${unique_diff_count}"
      return 1
    fi
  fi

  # 4. 허용 범위 밖 파일 접근 (state-summary.json의 files_out_of_scope 카운트)
  if [ -f "$state_dir/state-summary.json" ]; then
    local oos
    oos=$(jq -r '.out_of_scope_files // 0' "$state_dir/state-summary.json" 2>/dev/null || echo "0")
    if [ "${oos:-0}" -gt 0 ] 2>/dev/null; then
      echo "NO_PROGRESS:out_of_scope_files=$oos"
      return 1
    fi
  fi

  # 5. 요구 범위 임의 확대 (task.md에 없는 경로가 변경됨)
  # safety-check.sh가 검사하므로 여기선 단순 카운트만
  if [ -f "$state_dir/state-summary.json" ]; then
    local scope_expansion
    scope_expansion=$(jq -r '.scope_expansion_detected // false' "$state_dir/state-summary.json" 2>/dev/null || echo "false")
    if [ "$scope_expansion" = "true" ]; then
      echo "NO_PROGRESS:scope_expansion_detected"
      return 1
    fi
  fi

  # 6. 시간·토큰·비용 한도 80% 도달
  if [ -f "$state_dir/state-summary.json" ]; then
    local elapsed tokens cost
    elapsed=$(jq -r '.elapsed_seconds // 0' "$state_dir/state-summary.json" 2>/dev/null || echo "0")
    tokens=$(jq -r '.tokens_used // 0' "$state_dir/state-summary.json" 2>/dev/null || echo "0")
    cost=$(jq -r '.cost_usd // 0' "$state_dir/state-summary.json" 2>/dev/null || echo "0")

    if [ "${elapsed:-0}" -ge $((MAX_ELAPSED_SECONDS * 80 / 100)) ] 2>/dev/null; then
      echo "NO_PROGRESS:elapsed_seconds=$elapsed (limit=$MAX_ELAPSED_SECONDS)"
      return 1
    fi
    if [ "${tokens:-0}" -ge $((MAX_TOKENS * 80 / 100)) ] 2>/dev/null; then
      echo "NO_PROGRESS:tokens=$tokens (limit=$MAX_TOKENS)"
      return 1
    fi
    # cost 비교는 bc 필요할 수 있어 단순 산술 비교
    if awk "BEGIN {exit !($cost >= $MAX_COST_USD * 0.8)}" 2>/dev/null; then
      echo "NO_PROGRESS:cost_usd=$cost (limit=$MAX_COST_USD)"
      return 1
    fi
  fi

  # 7. 컨텍스트 압축 후 핵심 제약 누락 — 압축 이벤트 후 5 phase 안에 PASS 없으면 무진전
  local last_compress_phase last_pass_phase
  last_compress_phase=$(grep -nE 'context_compression' "$state_dir/phase-events.log" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")
  last_pass_phase=$(grep -nE 'verdict=PASS' "$state_dir/phase-events.log" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")
  if [ "${last_compress_phase:-0}" -gt 0 ] 2>/dev/null; then
    local phase_diff=$((last_pass_phase - last_compress_phase))
    if [ "$phase_diff" -lt 0 ] || [ "$phase_diff" -gt 5 ] 2>/dev/null; then
      echo "NO_PROGRESS:post_compression_no_pass_within_5_phases"
      return 1
    fi
  fi

  echo "OK"
  return 0
}

# ---------------------------------------------------------------------------
# state-summary 업데이트 헬퍼
# ---------------------------------------------------------------------------

record_phase_event() {
  local state_dir="$1" event_line="$2"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $event_line" >> "$state_dir/phase-events.log"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "detect" ]; then
  shift
  detect_no_progress "$@"
  exit $?
fi

if [ "${1:-}" = "record" ]; then
  shift
  record_phase_event "$@"
  exit 0
fi

cat <<EOF
no-progress-detector.sh — 무진전 감지 (routing 가이드 10.2)

사용법:
  no-progress-detector.sh detect <state_dir>    # OK | NO_PROGRESS:reason
  no-progress-detector.sh record <state_dir> <event_line>

임계값 (env):
  KANT_SAME_DIFF_LIMIT (default 3)
  KANT_SAME_TEST_FAIL_LIMIT (default 2)
  KANT_TOOL_CALLS_NO_PROGRESS_LIMIT (default 10)
  KANT_MAX_ELAPSED_SECONDS (default 1800)
  KANT_MAX_TOKENS (default 500000)
  KANT_MAX_COST_USD (default 5.0)
EOF
exit 0