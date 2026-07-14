#!/usr/bin/env bash
# test-fix-apply-guards.sh — fix-apply.sh 보안 가드 회귀 테스트
#
# 검증 대상:
# 1. guard_path_allowed: 경로 외부 거부
# 2. guard_path_allowed: .. 탈출 거부
# 3. guard_path_allowed: 외부 symlink 거부
# 4. guard_path_allowed: 정상 경로 허용
# 5. guard_no_reentry: marker 없는 경우 / 있는 경우
# 6. mark_applied: marker 파일 생성

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="/Users/drumqube/.claude/skills/kant-looper"
FIX_APPLY="$SKILL_DIR/scripts/lib/fix-apply.sh"

# bash -c 안에서 source하면 BASH_SOURCE[0]가 그대로 잡혀 호환됨
TEST_BODY=$(cat <<'BASHBODY'
set -uo pipefail
SKILL_DIR='SKILL_DIR_PLACEHOLDER'
SKILL_ROOT='SKILL_ROOT_PLACEHOLDER'
LIB_DIR='LIB_DIR_PLACEHOLDER'

FIX_APPLY='FIX_APPLY_PLACEHOLDER'
GUARDS_FILE='GUARDS_FILE_PLACEHOLDER'

source "$GUARDS_FILE"

PASS=0; FAIL=0

# Test 1: 외부 절대경로 거부
if ! guard_path_allowed "/tmp/foo.sh" 2>/dev/null; then
  echo "  PASS [1]: /tmp/foo.sh 거부"
  PASS=$((PASS+1))
else
  echo "  FAIL [1]: /tmp/foo.sh 허용됨"
  FAIL=$((FAIL+1))
fi

# Test 2: .. 탈출 거부
if ! guard_path_allowed "$SKILL_DIR/scripts/../../../etc/passwd" 2>/dev/null; then
  echo "  PASS [2]: .. 탈출 거부"
  PASS=$((PASS+1))
else
  echo "  FAIL [2]: .. 탈출 시 허용됨"
  FAIL=$((FAIL+1))
fi

# Test 3: 외부 symlink 거부
LINKDIR=$(mktemp -d -t kant-link-XXXXXX)
ln -s "/tmp/external-target" "$LINKDIR/external-link.sh" 2>/dev/null
if ! guard_path_allowed "$LINKDIR/external-link.sh" 2>/dev/null; then
  echo "  PASS [3]: 외부 symlink 거부"
  PASS=$((PASS+1))
else
  echo "  FAIL [3]: 외부 symlink 허용됨"
  FAIL=$((FAIL+1))
fi
rm -rf "$LINKDIR"

# Test 4: 정상 경로 허용
if guard_path_allowed "$SKILL_DIR/scripts/lib/health-check.sh" 2>/dev/null; then
  echo "  PASS [4a]: scripts/ 경로 허용"
  PASS=$((PASS+1))
else
  echo "  FAIL [4a]: scripts/ 경로 거부됨"
  FAIL=$((FAIL+1))
fi

if guard_path_allowed "$SKILL_DIR/agents/openai.yaml" 2>/dev/null; then
  echo "  PASS [4b]: agents/ 경로 허용"
  PASS=$((PASS+1))
else
  echo "  FAIL [4b]: agents/ 경로 거부됨"
  FAIL=$((FAIL+1))
fi

# Test 5: 재진입 방지
TEST_JSON="/tmp/test-reentry-$$.json"
rm -f "$TEST_JSON" "$TEST_JSON.applied"

if guard_no_reentry "$TEST_JSON" 2>/dev/null; then
  echo "  PASS [5a]: marker 없으면 통과"
  PASS=$((PASS+1))
else
  echo "  FAIL [5a]: marker 없는데 거부됨"
  FAIL=$((FAIL+1))
fi

touch "$TEST_JSON.applied"
if ! guard_no_reentry "$TEST_JSON" 2>/dev/null; then
  echo "  PASS [5b]: marker 있으면 거부"
  PASS=$((PASS+1))
else
  echo "  FAIL [5b]: marker 있는데 통과됨"
  FAIL=$((FAIL+1))
fi
rm -f "$TEST_JSON" "$TEST_JSON.applied"

# Test 6: mark_applied
TEST_JSON2="/tmp/test-mark-$$.json"
rm -f "$TEST_JSON2.applied"

mark_applied "$TEST_JSON2"

if [ -e "$TEST_JSON2.applied" ]; then
  echo "  PASS [6a]: marker 파일 생성"
  PASS=$((PASS+1))
else
  echo "  FAIL [6a]: marker 파일 미생성"
  FAIL=$((FAIL+1))
fi

if [ -s "$TEST_JSON2.applied" ]; then
  echo "  PASS [6b]: marker 내용이 비어있지 않음"
  PASS=$((PASS+1))
else
  echo "  FAIL [6b]: marker 비어있음"
  FAIL=$((FAIL+1))
fi
rm -f "$TEST_JSON2.applied"

echo "PASS_COUNT=$PASS"
echo "FAIL_COUNT=$FAIL"
BASHBODY
)

# SKILL_DIR, FIX_APLY 등을 heredoc 안에서 사용할 수 있도록 placeholder를 변환
TEST_BODY="${TEST_BODY//SKILL_DIR_PLACEHOLDER/$SKILL_DIR}"
TEST_BODY="${TEST_BODY//SKILL_ROOT_PLACEHOLDER/$SKILL_DIR}"
TEST_BODY="${TEST_BODY//LIB_DIR_PLACEHOLDER/$SKILL_DIR/scripts/lib}"
TEST_BODY="${TEST_BODY//FIX_APPLY_PLACEHOLDER/$FIX_APPLY}"

# guards 파일 생성
GUARDS_FILE="$(mktemp -t kant-guards-XXXXXX)"
TEST_BODY="${TEST_BODY//GUARDS_FILE_PLACEHOLDER/$GUARDS_FILE}"
{
  echo "SKILL_DIR='$SKILL_DIR'"
  echo "SKILL_ROOT='$SKILL_DIR'"
  echo "LIB_DIR='$SKILL_DIR/scripts/lib'"
  sed -n '1,/^apply_fix() {$/p' "$FIX_APPLY" | sed '$d'
} > "$GUARDS_FILE"

# 테스트 실행
echo "=== fix-apply.sh 보안 가드 회귀 테스트 ==="
eval "$TEST_BODY" 2>&1

# 결과 파싱
RESULT=$(eval "$TEST_BODY" 2>/dev/null | grep -E "^PASS_COUNT|^FAIL_COUNT" | tail -2)
echo "$RESULT"
PASS=$(echo "$RESULT" | awk -F= '/^PASS_COUNT/{print $2}')
FAIL=$(echo "$RESULT" | awk -F= '/^FAIL_COUNT/{print $2}')

# cleanup
rm -f "$GUARDS_FILE"

echo ""
echo "=== 결과 ==="
echo "PASS: ${PASS:-0}"
echo "FAIL: ${FAIL:-0}"
[ "${FAIL:-0}" -eq 0 ]
