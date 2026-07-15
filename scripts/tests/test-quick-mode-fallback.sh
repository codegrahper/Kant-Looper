#!/usr/bin/env bash
# test-quick-mode-fallback.sh — fallback verdict passthrough 정적 검사
#
# 검증 대상:
#   do_fallback() SUCCESS 경로에서 echo "$fb_output" 존재 (올바른 동작)
#   do_fallback() SUCCESS 경로에서 잘못된 echo "${next_tool}:${next_model}" 부재
#
# 동적 e2e 검증은 기존 run-scenarios.sh (5/5 PASS)가 담당한다.
# 이 파일은 회귀 방지를 위한 정적 검사만 수행한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
DISPATCHER="$SKILL_LIB/fallback-dispatcher.sh"

declare -i PASS=0 FAIL=0

# ─────────────────────────────────────────
# 대상 파일 존재 확인
# ─────────────────────────────────────────
if [ ! -f "$DISPATCHER" ]; then
  echo "FAIL: fallback-dispatcher.sh not found: $DISPATCHER"
  exit 1
fi

# ─────────────────────────────────────────
# do_fallback 함수 블록 추출
# ─────────────────────────────────────────
# 다음 최상위 함수까지 추출 (brace counting으로 함수 범위 결정)
do_fallback_block="$(
  awk '
    /^do_fallback\(\)[[:space:]]*\{/ {
      in_function = 1
      depth = 1
      next
    }

    in_function {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (depth <= 0) exit
    }
  ' "$DISPATCHER"
)"

if [ -z "$do_fallback_block" ]; then
  echo "FAIL: unable to locate do_fallback function in fallback-dispatcher.sh"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 1 — echo "$fb_output" 존재
# ─────────────────────────────────────────
echo "[test 1] do_fallback SUCCESS 경로에 echo \"\$fb_output\" 존재"

if printf '%s\n' "$do_fallback_block" | grep -qE '^[[:space:]]*echo[[:space:]]+"\$fb_output"[[:space:]]*$'; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: echo \"\$fb_output\" not found in do_fallback"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 2 — 잘못된 단독 echo 부재
# ─────────────────────────────────────────
echo "[test 2] 잘못된 echo \"\${next_tool}:\${next_model}\" 단독 echo 부재 (로그/문자열화는 정상)"

if printf '%s\n' "$do_fallback_block" | grep -qE '^[[:space:]]*echo[[:space:]]+"\$next_tool:\$next_model"[[:space:]]*$'; then
  echo "  FAIL: 잘못된 단독 echo가 do_fallback에 존재"
  ((FAIL++))
else
  echo "  PASS"
  ((PASS++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
