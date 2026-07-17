#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

printf '%s\n' '# contract' '' '## Goal' 'verify mode selection' > "$TMP_DIR/TASK.md"

if output="$("$KANT_LOOP" run "$TMP_DIR/TASK.md" --dry-run 2>&1)" && printf '%s\n' "$output" | grep -q 'mode: quick'; then
  pass "mode omission defaults to quick"
else
  fail "mode omission must default to quick"
fi

if output="$("$KANT_LOOP" run "$TMP_DIR/TASK.md" --dry-run --quick --chain 'opencode:glm-5.2,codex:gpt-5.6-sol,codex:gpt-5.6-terra' 2>&1)" && printf '%s\n' "$output" | grep -q 'agent_chain:'; then
  pass "quick chain accepts implement-review-repair triplet"
else
  fail "quick chain triplet must be accepted"
fi

if "$KANT_LOOP" run "$TMP_DIR/TASK.md" --dry-run --quick --chain 'opencode:glm-5.2,codex:gpt-5.6-sol' >/dev/null 2>&1; then
  fail "quick chain with fewer than three stages must fail"
else
  pass "quick chain rejects incomplete stages"
fi

if "$KANT_LOOP" run "$TMP_DIR/TASK.md" --full >/dev/null 2>&1; then
  fail "retired full mode must fail"
else
  pass "retired full mode is rejected"
fi

if "$KANT_LOOP" run "$TMP_DIR/TASK.md" --strict-verify >/dev/null 2>&1; then
  fail "retired strict verify must fail"
else
  pass "retired strict verify is rejected"
fi

if "$KANT_LOOP" run "$TMP_DIR/TASK.md" --dry-run --parallel --chain 'codex:gpt-5.6-sol,codex:gpt-5.6-terra,codex:gpt-5.6-luna,codex:gpt-5.6-sol,codex:gpt-5.6-terra' >/dev/null 2>&1; then
  fail "parallel chain over four reviewers must fail"
else
  pass "parallel chain limits reviewers to four"
fi

echo "PASS: $PASS"
echo "FAIL: $FAIL"
test "$FAIL" -eq 0
