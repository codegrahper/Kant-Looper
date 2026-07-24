#!/usr/bin/env bash
# test-tier-fallback-chain.sh — T0~T3 티어 기반 fallback 체인 + Dashboard 관측성 테스트
#
# 검증 대상:
# 1. 정상 primary 8종의 체인이 모두 claude:default로 끝난다
# 2. 같은 티어 동료가 legacy(glm-4.7/MiniMax-M2.7)보다 먼저, 기본값(legacy=0)에는 legacy가 없다
# 3. 특수 케이스(claude self-loop, glm-4.7/MiniMax-M2.7 명시 호출, gemini-3.5-flash 호환) 체인
# 4. do_fallback()이 실제로 실패→성공 흐름을 state_dir/phase-events.log에
#    FALLBACK_ATTEMPT 이벤트로 남기는지 (Dashboard가 읽는 원본)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER="$SKILL_ROOT/scripts/lib/fallback-dispatcher.sh"
STATE_WRITER="$SKILL_ROOT/scripts/lib/state_writer.py"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

pass() { echo "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }

chain_of() { "$DISPATCHER" chain "$1" "$2"; }

assert_ends_with_claude() {
  local label="$1" tool="$2" model="$3"
  local c; c="$(chain_of "$tool" "$model")"
  if [ "$c" = "claude:default" ] || [[ "$c" == *",claude:default" ]]; then
    pass "$label: chain ends in claude:default ($c)"
  else
    fail "$label: chain does NOT end in claude:default — got: $c"
  fi
}

assert_no_legacy_by_default() {
  local label="$1" tool="$2" model="$3"
  local c; c="$(chain_of "$tool" "$model")"
  case ",$c," in
    *,opencode:glm-4.7,*|*,opencode:MiniMax-M2.7,*)
      fail "$label: legacy model present without KANT_ENABLE_LEGACY_FALLBACK=1 — $c" ;;
    *)
      pass "$label: no legacy model in default chain" ;;
  esac
}

echo "=== Part A: 정상 primary 8종 — 체인 생성 ==="

for pair in "codex gpt-5.6-luna" "codex gpt-5.6-terra" "codex gpt-5.6-sol" \
            "opencode glm-5.2" "opencode MiniMax-M3" "agy gemini-3.6-flash" "grok grok-4.5"; do
  read -r t m <<< "$pair"
  assert_ends_with_claude "$t:$m" "$t" "$m"
  assert_no_legacy_by_default "$t:$m" "$t" "$m"
done

echo ""
echo "=== Part A-2: 같은 티어 우선순위 (glm-5.2 실패 → T1 동료가 codex-sol/grok보다 먼저) ==="

GLM52_CHAIN="$(chain_of opencode glm-5.2)"
IDX_TERRA=$(printf '%s' "$GLM52_CHAIN" | tr ',' '\n' | grep -n '^codex:gpt-5.6-terra$' | cut -d: -f1)
IDX_SOL=$(printf '%s' "$GLM52_CHAIN" | tr ',' '\n' | grep -n '^codex:gpt-5.6-sol$' | cut -d: -f1)
if [ -n "$IDX_TERRA" ] && [ -n "$IDX_SOL" ] && [ "$IDX_TERRA" -lt "$IDX_SOL" ]; then
  pass "glm-5.2 fallback: T1 동료(gpt-5.6-terra)가 T3(gpt-5.6-sol)보다 먼저 온다"
else
  fail "glm-5.2 fallback: 티어 우선순위 위반 (terra idx=$IDX_TERRA, sol idx=$IDX_SOL)"
fi

echo ""
echo "=== Part B: 특수 케이스 (legacy 명시 호출 / claude self / 구버전 호환) ==="

CLAUDE_CHAIN="$(chain_of claude default)"
if [ "$CLAUDE_CHAIN" = "claude:default" ]; then
  pass "claude:default self-loop"
else
  fail "claude:default should self-loop — got: $CLAUDE_CHAIN"
fi

GLM47_CHAIN="$(chain_of opencode glm-4.7)"
case ",$GLM47_CHAIN," in
  *,opencode:glm-4.7,*) fail "glm-4.7 own chain must not retry itself — got: $GLM47_CHAIN" ;;
  *) pass "glm-4.7 own chain does not retry itself" ;;
esac
if [[ "$GLM47_CHAIN" == *",claude:default" ]]; then
  pass "glm-4.7 explicit-fail chain still reaches claude:default"
else
  fail "glm-4.7 explicit-fail chain does not reach claude:default — got: $GLM47_CHAIN"
fi

GEMINI35_CHAIN="$(chain_of agy gemini-3.5-flash)"
case ",$GEMINI35_CHAIN," in
  *,agy:gemini-3.6-flash,*) pass "gemini-3.5-flash 명시 호출 실패 시 gemini-3.6-flash로 이어짐" ;;
  *) fail "gemini-3.5-flash chain missing gemini-3.6-flash — got: $GEMINI35_CHAIN" ;;
esac

echo ""
echo "=== Part B-2: KANT_ENABLE_LEGACY_FALLBACK=1 emergency 편입 ==="

LEGACY_ON_CHAIN="$(KANT_ENABLE_LEGACY_FALLBACK=1 "$DISPATCHER" chain opencode glm-5.2)"
case ",$LEGACY_ON_CHAIN," in
  *,opencode:glm-4.7,*) pass "legacy=1: glm-4.7 emergency 후보로 편입" ;;
  *) fail "legacy=1: glm-4.7 not found in $LEGACY_ON_CHAIN" ;;
esac

echo ""
echo "=== Part C: do_fallback() — 실제 실패→성공 흐름이 phase-events.log에 기록되는지 ==="

MOCK_BIN="$TMPDIR/bin"
WORKTREE="$TMPDIR/worktree"
STATE_DIR="$TMPDIR/state"
PROMPT_FILE="$TMPDIR/prompt.txt"
mkdir -p "$MOCK_BIN" "$WORKTREE" "$STATE_DIR"
printf '%s\n' 'Return a PASS verdict.' > "$PROMPT_FILE"

# codex 모의 실행: 항상 실패 (exec 시 아무것도 안 쓰고 exit 1)
cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex test stub"; exit 0 ;;
  --help) echo "codex test stub help"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$MOCK_BIN/codex"

# opencode 모의 실행: -m 뒤 모델 무시하고 항상 PASS verdict 반환
cat > "$MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo "opencode test stub"; exit 0 ;;
  run)
    printf '%s\n' '{"type":"text","part":{"text":"{\"verdict\":\"PASS\"}"}}'
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$MOCK_BIN/opencode"

# agy:gemini-3.6-flash 체인의 첫 후보는 codex:gpt-5.6-luna(실패하게 mock),
# 두 번째는 opencode:MiniMax-M3(성공하게 mock) — 실제 chain 순서를 그대로 사용.
FALLBACK_OUT="$TMPDIR/fallback-out"
if PATH="$MOCK_BIN:$PATH" \
  KANT_TIMEOUT_PLAN=1 KANT_TIMEOUT_IMPLEMENT=5 \
  KANT_OPENCODE_GLM_PROVIDER="zai-coding-plan" KANT_OPENCODE_MINIMAX_PROVIDER="opencode-go" \
  "$DISPATCHER" run agy gemini-3.6-flash INVALID_OUTPUT "$PROMPT_FILE" "$WORKTREE" implement "$STATE_DIR" \
  > "$FALLBACK_OUT" 2> "$TMPDIR/fallback-err"; then
  fb_result="$(<"$FALLBACK_OUT")"
  if [[ "$fb_result" == PASS\|* ]]; then
    pass "do_fallback() succeeds via mocked fallback chain (result=$fb_result)"
  else
    fail "do_fallback() succeeded but unexpected result: $fb_result"
  fi
else
  fail "do_fallback() failed unexpectedly"
  echo "  stderr: $(cat "$TMPDIR/fallback-err")"
fi

EVENTS_LOG="$STATE_DIR/phase-events.log"
if [ -f "$EVENTS_LOG" ]; then
  if grep -q "FALLBACK_ATTEMPT role=implement tool=codex model=gpt-5.6-luna status=trying" "$EVENTS_LOG"; then
    pass "phase-events.log: 첫 후보(codex:gpt-5.6-luna) 시도 기록됨"
  else
    fail "phase-events.log: 첫 후보 시도 기록 없음"
  fi
  if grep -q "FALLBACK_ATTEMPT role=implement tool=codex model=gpt-5.6-luna status=failed" "$EVENTS_LOG"; then
    pass "phase-events.log: 첫 후보 실패 기록됨"
  else
    fail "phase-events.log: 첫 후보 실패 기록 없음"
  fi
  if grep -q "FALLBACK_ATTEMPT role=implement tool=opencode model=MiniMax-M3 status=success" "$EVENTS_LOG"; then
    pass "phase-events.log: 성공한 후보(opencode:MiniMax-M3) 기록됨"
  else
    fail "phase-events.log: 성공 기록 없음 — 로그: $(cat "$EVENTS_LOG")"
  fi
else
  fail "phase-events.log가 생성되지 않음"
fi

echo ""
echo "=== Part D: state_writer.py — agents[]가 실제 실행자로 갱신되는지 (합성 이벤트) ==="

SYN_DIR="$TMPDIR/synthetic"
mkdir -p "$SYN_DIR"
cat > "$SYN_DIR/phase-events.log" <<'EOF'
[2026-07-24T01:00:00Z] RUN_CREATED
[2026-07-24T01:00:01Z] QUICK_CALL role=implement tool=agy model=gemini-3.6-flash
[2026-07-24T01:00:05Z] ADAPTER_FAIL role=implement tool=agy model=gemini-3.6-flash mode=INVALID_OUTPUT rc=1
[2026-07-24T01:00:06Z] FALLBACK_ATTEMPT role=implement tool=opencode model=glm-5.2 status=trying attempt=1 from=agy:gemini-3.6-flash
[2026-07-24T01:00:09Z] FALLBACK_ATTEMPT role=implement tool=opencode model=glm-5.2 status=failed mode=rc:1
[2026-07-24T01:00:10Z] FALLBACK_ATTEMPT role=implement tool=codex model=gpt-5.6-terra status=trying attempt=1 from=agy:gemini-3.6-flash
[2026-07-24T01:00:20Z] FALLBACK_ATTEMPT role=implement tool=codex model=gpt-5.6-terra status=success
[2026-07-24T01:00:21Z] FALLBACK_USED result=PASS|/tmp/foo.json
[2026-07-24T01:00:22Z] QUICK_VERDICT verdict=PASS
EOF
echo "completed" > "$SYN_DIR/result.txt"
python3 "$STATE_WRITER" "$SYN_DIR" >/dev/null 2>&1

TOOL_FIELD="$(python3 -c "import json; print(json.load(open('$SYN_DIR/run-state.json'))['agents'][0]['tool'])")"
MODEL_FIELD="$(python3 -c "import json; print(json.load(open('$SYN_DIR/run-state.json'))['agents'][0]['model'])")"
ATTEMPTS_LEN="$(python3 -c "import json; print(len(json.load(open('$SYN_DIR/run-state.json'))['agents'][0]['attempts']))")"

if [ "$TOOL_FIELD" = "codex" ] && [ "$MODEL_FIELD" = "gpt-5.6-terra" ]; then
  pass "agents[0].tool/model이 원래 실패한 agy가 아니라 실제 성공한 codex:gpt-5.6-terra로 갱신됨"
else
  fail "agents[0].tool/model 오표기 — got tool=$TOOL_FIELD model=$MODEL_FIELD (expected codex/gpt-5.6-terra)"
fi

if [ "$ATTEMPTS_LEN" = "3" ]; then
  pass "agents[0].attempts에 시도 3건(agy 실패, opencode 실패, codex 성공) 전부 기록됨"
else
  fail "agents[0].attempts 길이 불일치 — got $ATTEMPTS_LEN (expected 3)"
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
