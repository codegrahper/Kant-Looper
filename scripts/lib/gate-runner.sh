#!/usr/bin/env bash
# gate-runner.sh — 자동 gate 감지 + 명시적 override
#
# worktree에서 package.json, pyproject.toml, Cargo.toml, go.mod 등을 감지해
# 적절한 gate 명령 실행. GATE_COMMANDS env로 override 가능.
#
# bash 3.2 호환.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 자동 감지
# ---------------------------------------------------------------------------
# 인자: worktree_dir
# 출력 (stdout): 감지된 gate 명령 (한 줄)
# 종료 코드: 0 = 감지, 1 = 감지 실패 (gate 없음)

detect_gates() {
  local worktree="$1"

  if [ ! -d "$worktree" ]; then
    return 1
  fi

  # 우선순위대로 검사 (가장 일반적인 것부터)
  # 1. JavaScript / TypeScript (package.json)
  if [ -f "$worktree/package.json" ]; then
    echo "npm test --if-present && npm run lint --if-present && npm run build --if-present"
    return 0
  fi

  # 2. Python (pyproject.toml)
  if [ -f "$worktree/pyproject.toml" ]; then
    # pytest 우선
    echo "python3 -m pytest -q --tb=short 2>&1 | tail -20"
    return 0
  fi

  # 3. Python (pytest.ini 또는 setup.cfg 또는 tox.ini)
  for marker in pytest.ini setup.cfg tox.ini; do
    if [ -f "$worktree/$marker" ]; then
      echo "python3 -m pytest -q --tb=short 2>&1 | tail -20"
      return 0
    fi
  done

  # 4. Rust (Cargo.toml)
  if [ -f "$worktree/Cargo.toml" ]; then
    echo "cargo test --quiet 2>&1 | tail -20"
    return 0
  fi

  # 5. Go (go.mod)
  if [ -f "$worktree/go.mod" ]; then
    echo "go test ./... 2>&1 | tail -20"
    return 0
  fi

  # 6. Ruby (Gemfile)
  if [ -f "$worktree/Gemfile" ]; then
    echo "bundle exec rspec --no-color 2>&1 | tail -20"
    return 0
  fi

  # 7. Makefile (Makefile)
  if [ -f "$worktree/Makefile" ]; then
    # Makefile에 'test' 타겟이 있으면 사용
    if grep -qE '^test:' "$worktree/Makefile" 2>/dev/null; then
      echo "make test 2>&1 | tail -20"
      return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Gate 실행
# ---------------------------------------------------------------------------
# 인자: worktree_dir, gate_output_dir, gate_idx (gate-01, gate-02, ...)
# 출력: 각 gate 명령의 exit code를 누적 평가
# 종료 코드: 0 = 모든 gate PASS, 1 = 하나라도 FAIL

run_gates() {
  local worktree="$1" output_dir="$2" gate_idx="${3:-01}"
  mkdir -p "$output_dir"

  # 명시적 GATE_COMMANDS가 있으면 사용 (newline 구분)
  local gate_cmd_log="$output_dir/gate-${gate_idx}.log"

  if [ -n "${GATE_COMMANDS:-}" ]; then
    # newline 분리
    local IFS_BAK="$IFS"
    IFS=$'\n'
    local lines=($GATE_COMMANDS)
    IFS="$IFS_BAK"

    local line cmd exit_code=0
    for line in "${lines[@]}"; do
      # 주석/빈 줄 무시
      [ -z "$line" ] && continue
      case "$line" in \#*) continue ;; esac

      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] gate: $line" >> "$gate_cmd_log"
      (cd "$worktree" && bash -c "$line") >> "$gate_cmd_log" 2>&1
      exit_code=$?

      if [ "$exit_code" != "0" ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FAIL exit=$exit_code: $line" >> "$gate_cmd_log"
        return 1
      fi
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] PASS: $line" >> "$gate_cmd_log"
    done
    return 0
  fi

  # 자동 감지
  local detected_cmd
  detected_cmd="$(detect_gates "$worktree" 2>/dev/null || true)"

  if [ -z "$detected_cmd" ]; then
    # gate 없음 → 자동 PASS (lint/compile만이라도 시도)
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] no gates detected, attempting compile check" >> "$gate_cmd_log"
    if [ -d "$worktree" ]; then
      # Python 컴파일 검사 (가벼움)
      if compgen -G "$worktree/**/*.py" >/dev/null 2>&1; then
        (cd "$worktree" && python3 -m compileall -q . 2>&1) >> "$gate_cmd_log"
        local rc=$?
        if [ "$rc" != "0" ]; then
          return 1
        fi
      fi
      # TypeScript 컴파일 검사 (있는 경우만)
      if [ -f "$worktree/tsconfig.json" ] && command -v npx >/dev/null 2>&1; then
        (cd "$worktree" && npx tsc --noEmit 2>&1) >> "$gate_cmd_log"
        local rc=$?
        if [ "$rc" != "0" ]; then
          return 1
        fi
      fi
    fi
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] no-op gate passed" >> "$gate_cmd_log"
    return 0
  fi

  # 자동 감지된 명령 실행
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] auto-detected gate: $detected_cmd" >> "$gate_cmd_log"
  (cd "$worktree" && bash -c "$detected_cmd") >> "$gate_cmd_log" 2>&1
  local exit_code=$?

  if [ "$exit_code" != "0" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FAIL exit=$exit_code" >> "$gate_cmd_log"
    return 1
  fi
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] PASS" >> "$gate_cmd_log"
  return 0
}

# ---------------------------------------------------------------------------
# Gate 결과 요약
# ---------------------------------------------------------------------------

summarize_gates() {
  local output_dir="$1"
  if [ ! -d "$output_dir" ]; then
    echo "no gates run"
    return 0
  fi

  local log_file
  for log_file in "$output_dir"/gate-*.log; do
    [ -f "$log_file" ] || continue
    local name
    name="$(basename "$log_file")"
    local status
    if grep -q 'PASS' "$log_file" 2>/dev/null && ! grep -qE 'FAIL|exit=[1-9]' "$log_file" 2>/dev/null; then
      status="PASS"
    else
      status="FAIL"
    fi
    echo "$name: $status"
  done
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "detect" ]; then
  shift
  detect_gates "$@"
  exit $?
fi

if [ "${1:-}" = "run" ]; then
  shift
  run_gates "$@"
  exit $?
fi

if [ "${1:-}" = "summarize" ]; then
  shift
  summarize_gates "$@"
  exit 0
fi

cat <<EOF
gate-runner.sh — 자동 gate 감지 + 실행

사용법:
  gate-runner.sh detect <worktree>      # gate 명령 자동 감지
  gate-runner.sh run <worktree> <output_dir> [gate_idx]
  gate-runner.sh summarize <output_dir>

env:
  GATE_COMMANDS: newline-separated 명시적 명령 (예: "npm test\nnpm run lint")
EOF
exit 0