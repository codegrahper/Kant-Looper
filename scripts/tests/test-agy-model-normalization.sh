#!/usr/bin/env bash
# test-agy-model-normalization.sh — adapter-agy.sh 모델 정규화 단위 테스트
#
# mock agy 바이너리로 실제 전달되는 --model 인자값을 검증한다.
# 검증 대상:
#   gemini-3.6-flash        → "Gemini 3.6 Flash (Medium)" (2026-07-24 신규)
#   gemini-3.5-flash        → "Gemini 3.5 Flash (Medium)" (회귀 방지)
#   gemini-3.1-pro-preview  → "Gemini 3.1 Pro (High)"     (회귀 방지)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER_AGY="$SKILL_ROOT/scripts/adapters/adapter-agy.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "${GREEN}PASS${NC}: $label"
    PASSED=$((PASSED + 1))
  else
    echo "${RED}FAIL${NC}: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAILED=$((FAILED + 1))
  fi
}

MOCK_BIN="$TMPDIR/bin"
WORKTREE="$TMPDIR/worktree"
PROMPT_FILE="$TMPDIR/prompt.txt"
MOCK_AGY_MODEL="$TMPDIR/agy-model"
mkdir -p "$MOCK_BIN" "$WORKTREE"
printf '%s\n' 'Return a PASS verdict.' > "$PROMPT_FILE"

cat > "$MOCK_BIN/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "agy test stub 1.1.5"
  exit 0
fi

while [ "$#" -gt 0 ]; do
  if [ "$1" = "--model" ]; then
    printf '%s' "${2:-}" > "$KANT_TEST_AGY_MODEL"
    break
  fi
  shift
done

printf '%s\n' '{"verdict":"PASS","summary":"ok","findings":[]}'
EOF
chmod +x "$MOCK_BIN/agy"

run_agy_normalization() {
  local model="$1"
  rm -f "$MOCK_AGY_MODEL"

  if ! PATH="$MOCK_BIN:$PATH" \
    KANT_TEST_AGY_MODEL="$MOCK_AGY_MODEL" \
    KANT_TIMEOUT_PLAN=1 \
    "$ADAPTER_AGY" call plan "$PROMPT_FILE" "$WORKTREE" "$model" \
    > "$TMPDIR/agy-output" 2> "$TMPDIR/agy-error"; then
    return 1
  fi

  [ -f "$MOCK_AGY_MODEL" ] || return 1
  printf '%s' "$(<"$MOCK_AGY_MODEL")"
}

echo "=== adapter-agy.sh model normalization tests ==="

if normalized="$(run_agy_normalization "gemini-3.6-flash")"; then
  assert_eq "gemini-3.6-flash normalizes to display name" "Gemini 3.6 Flash (Medium)" "$normalized"
else
  echo "${RED}FAIL${NC}: adapter-agy call failed for gemini-3.6-flash"
  cat "$TMPDIR/agy-error" >&2
  FAILED=$((FAILED + 1))
fi

if normalized="$(run_agy_normalization "gemini-3.5-flash")"; then
  assert_eq "gemini-3.5-flash normalizes to display name (regression)" "Gemini 3.5 Flash (Medium)" "$normalized"
else
  echo "${RED}FAIL${NC}: adapter-agy call failed for gemini-3.5-flash"
  cat "$TMPDIR/agy-error" >&2
  FAILED=$((FAILED + 1))
fi

if normalized="$(run_agy_normalization "gemini-3.1-pro-preview")"; then
  assert_eq "gemini-3.1-pro-preview normalizes to display name (regression)" "Gemini 3.1 Pro (High)" "$normalized"
else
  echo "${RED}FAIL${NC}: adapter-agy call failed for gemini-3.1-pro-preview"
  cat "$TMPDIR/agy-error" >&2
  FAILED=$((FAILED + 1))
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
