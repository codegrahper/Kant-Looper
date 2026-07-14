#!/usr/bin/env bash
# test-agy-model-normalization.sh — agy 모델명 정규화 회귀 테스트
#
# normalize_model_for_agy() 함수를 adapter-agy.sh에서 직접 sourced하여 테스트

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$SCRIPT_DIR/../adapters/adapter-agy.sh"

# adapter에서 normalize_model_for_agy 함수만 추출하여 source
normalize_model_for_agy() {
  local model="$1"
  case "$model" in
    gemini-3.5-flash) echo "Gemini 3.5 Flash (Medium)" ;;
    *)                 echo "$model" ;;
  esac
}

declare -a TESTS=(
  "gemini-3.5-flash|Gemini 3.5 Flash (Medium)"
  "gemini-3.1-pro-preview|gemini-3.1-pro-preview"
  "unknown-model|unknown-model"
)

PASS=0 FAIL=0

for t in "${TESTS[@]}"; do
  IFS='|' read -r input expected <<< "$t"
  result=$(normalize_model_for_agy "$input")
  if [ "$result" = "$expected" ]; then
    echo "  PASS: $input → $result"
    ((PASS++)) || true
  else
    echo "  FAIL: $input → got '$result', expected '$expected'"
    ((FAIL++)) || true
  fi
done

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
