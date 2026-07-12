#!/usr/bin/env bash
# test-timeout-runner-cwd.sh — timeout-runner.sh의 cwd 강제를 결정론적으로 검증
#
# 외부 모델 호출 없이 timeout-runner.sh만 직접 실행한다. run-scenarios.sh는
# dry-run 중심이라 이 계약(=cwd가 실제로 강제되는지)을 검증하지 못하므로 별도로 둔다.
#
# 검증 항목:
#   양성   : cwd로 넘긴 디렉터리가 실제 프로세스 작업 디렉터리가 되는지
#   음성 1 : cwd 인자 누락 시 실패하는지
#   음성 2 : 존재하지 않는 cwd 시 실패하는지
#   음성 3 : 상대경로로 만든 파일이 cwd(target) 밑에만 생기는지

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$SKILL_ROOT/scripts/lib/timeout-runner.sh"

PASS=0
FAIL=0

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

origin=""
target=""
log_file=""
response_file=""

setup() {
  origin="$(mktemp -d)"
  target="$(mktemp -d)"
  log_file="$(mktemp)"
  response_file="$(mktemp)"
}

cleanup() {
  [ -n "$origin" ] && rm -rf "$origin"
  [ -n "$target" ] && rm -rf "$target"
  [ -n "$log_file" ] && rm -f "$log_file"
  [ -n "$response_file" ] && rm -f "$response_file"
}

check() {
  local name="$1" condition="$2"
  if [ "$condition" = "0" ]; then
    log "  PASS: $name"
    PASS=$((PASS+1))
  else
    log "  FAIL: $name"
    FAIL=$((FAIL+1))
  fi
}

test_positive_cwd_enforced() {
  log "=== 양성: cwd가 target으로 강제되는지 ==="
  setup

  local rc=0
  ( cd "$origin" && "$RUNNER" run 5 "$log_file" "$response_file" "$target" sh -c 'pwd -P' ) || rc=$?

  local expected actual
  expected="$(cd "$target" && pwd -P)"
  actual="$(tr -d '\r\n' < "$response_file")"

  if [ "$rc" = "0" ] && [ "$actual" = "$expected" ]; then
    check "positive cwd match" 0
  else
    log "    rc=$rc expected=$expected actual=$actual"
    check "positive cwd match" 1
  fi

  cleanup
}

test_negative_missing_cwd_arg() {
  log "=== 음성 1: cwd 인자 누락 ==="
  setup

  local rc=0
  "$RUNNER" run 5 "$log_file" "$response_file" sh -c 'pwd -P' || rc=$?

  if [ "$rc" != "0" ]; then
    check "missing cwd arg fails" 0
  else
    check "missing cwd arg fails" 1
  fi

  cleanup
}

test_negative_nonexistent_cwd() {
  log "=== 음성 2: 존재하지 않는 cwd ==="
  setup

  local bogus="/tmp/kant-test-cwd-does-not-exist-$$-$RANDOM"
  local rc=0
  "$RUNNER" run 5 "$log_file" "$response_file" "$bogus" sh -c 'pwd -P' || rc=$?

  if [ "$rc" != "0" ]; then
    check "nonexistent cwd fails" 0
  else
    check "nonexistent cwd fails" 1
  fi

  cleanup
}

test_negative_relative_write_confined() {
  log "=== 음성 3: 상대경로 파일 생성이 target 안에만 생기는지 ==="
  setup

  ( cd "$origin" && "$RUNNER" run 5 "$log_file" "$response_file" "$target" sh -c 'touch cwd-marker' ) || true

  if [ -f "$target/cwd-marker" ] && [ ! -f "$origin/cwd-marker" ]; then
    check "relative write confined to target" 0
  else
    log "    target has marker: $([ -f "$target/cwd-marker" ] && echo yes || echo no)"
    log "    origin has marker: $([ -f "$origin/cwd-marker" ] && echo yes || echo no)"
    check "relative write confined to target" 1
  fi

  cleanup
}

main() {
  log "test-timeout-runner-cwd.sh 시작"
  test_positive_cwd_enforced
  test_negative_missing_cwd_arg
  test_negative_nonexistent_cwd
  test_negative_relative_write_confined

  log ""
  log "=== 결과 ==="
  log "PASS: $PASS"
  log "FAIL: $FAIL"

  exit $FAIL
}

main "$@"
