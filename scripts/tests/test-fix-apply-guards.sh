#!/usr/bin/env bash
# test-fix-apply-guards.sh — fix-apply.sh 보안 가드 회귀 테스트
#
# 검증 대상:
# 1. guard_path_in_repo: 경로 외부 거부
# 2. guard_path_in_repo: .. 탈출 거부
# 3. guard_path_in_repo: 정상 경로 허용
# 4. guard_no_reentry: marker 없는 / 있는 경우
# 5. mark_applied: marker 파일 생성

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX_APPLY="$SKILL_ROOT/scripts/lib/fix-apply.sh"

declare -i PASS=0 FAIL=0

# 가드 함수 정의 영역 (line 24-160)만 추출 (BSD sed 멀티라인 {} 회피)
# 헤더의 set + LIB_DIR/SKILL_DIR/SKILL_ROOT 설정도 skip (덮어쓰는 게드 환경 명시 override)
GUARDS_FILE="$(mktemp -t kant-guards-XXXXXX)"
{
  printf 'export LIB_DIR=%s\n'        "\"$SKILL_ROOT/scripts/lib\""
  printf 'export SKILL_DIR=%s\n'       "\"$SKILL_ROOT/scripts\""
  printf 'export SKILL_ROOT=%s\n'      "\"$SKILL_ROOT\""
  sed -n '24,160p' "$FIX_APPLY"
} > "$GUARDS_FILE"

source "$GUARDS_FILE"
rm -f "$GUARDS_FILE"

# ─────────────────────────────────────────
# Test 1: 외부 절대경로 거부
# ─────────────────────────────────────────
if ! guard_path_in_repo "/tmp/foo.sh" "$SKILL_ROOT" 2>/dev/null; then
  echo "  PASS [1]: /tmp/foo.sh 거부"
  ((PASS++))
else
  echo "  FAIL [1]: /tmp/foo.sh 허용됨"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 2: .. 탈출 거부
# ─────────────────────────────────────────
if ! guard_path_in_repo "$SKILL_ROOT/scripts/../../../etc/passwd" "$SKILL_ROOT" 2>/dev/null; then
  echo "  PASS [2]: .. 탈출 거부"
  ((PASS++))
else
  echo "  FAIL [2]: .. 탈출 시 허용됨"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 3: 정상 경로 허용
# ─────────────────────────────────────────
if guard_path_in_repo "$SKILL_ROOT/scripts/lib/health-check.sh" "$SKILL_ROOT" 2>/dev/null; then
  echo "  PASS [3a]: scripts/ 경로 허용"
  ((PASS++))
else
  echo "  FAIL [3a]: scripts/ 경로 거부됨"
  ((FAIL++))
fi

if guard_path_in_repo "$SKILL_ROOT/agents/openai.yaml" "$SKILL_ROOT" 2>/dev/null; then
  echo "  PASS [3b]: agents/ 경로 허용"
  ((PASS++))
else
  echo "  FAIL [3b]: agents/ 경로 거부됨"
  ((FAIL++))
fi

# ─────────────────────────────────────────
# Test 4: 재진입 방지
# ─────────────────────────────────────────
TEST_JSON="/tmp/test-reentry-$$.json"
rm -f "$TEST_JSON" "$TEST_JSON.applied"

if guard_no_reentry "$TEST_JSON" 2>/dev/null; then
  echo "  PASS [4a]: marker 없으면 통과"
  ((PASS++))
else
  echo "  FAIL [4a]: marker 없는데 거부됨"
  ((FAIL++))
fi

touch "$TEST_JSON.applied"
if ! guard_no_reentry "$TEST_JSON" 2>/dev/null; then
  echo "  PASS [4b]: marker 있으면 거부"
  ((PASS++))
else
  echo "  FAIL [4b]: marker 있는데 통과됨"
  ((FAIL++))
fi
rm -f "$TEST_JSON" "$TEST_JSON.applied"

# ─────────────────────────────────────────
# Test 5: mark_applied
# ─────────────────────────────────────────
TEST_JSON2="/tmp/test-mark-$$.json"
rm -f "$TEST_JSON2.applied"

mark_applied "$TEST_JSON2"

if [ -e "$TEST_JSON2.applied" ]; then
  echo "  PASS [5a]: marker 파일 생성"
  ((PASS++))
else
  echo "  FAIL [5a]: marker 파일 미생성"
  ((FAIL++))
fi

if [ -s "$TEST_JSON2.applied" ]; then
  echo "  PASS [5b]: marker 내용이 비어있지 않음"
  ((PASS++))
else
  echo "  FAIL [5b]: marker 비어있음"
  ((FAIL++))
fi
rm -f "$TEST_JSON2.applied"

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
