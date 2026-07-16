#!/usr/bin/env bash
# test-ssot-stress-simulation.sh — 2주간의 안정성 확인을 시뮬레이션 및 스트레스 테스트로 압축
#
# 검증 항목:
#   1. 무작위 시나리오 500회 대조 (Hardcode 모드 vs SSOT 모드 결과 100% 일치성)
#   2. YAML 손상/삭제 상황에서의 Fail-safe 동작 검증 (기존 하드코딩 Fallback)
#   3. Loader 스크립트 크래시 유발 시 Fail-safe 동작 검증
#   4. 비정상적이거나 극단적인 입력(초대형 입력) 처리 검증

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_LIB="$SKILL_ROOT/scripts/lib"
ROUTING_PARSER="$SKILL_LIB/routing-parser.sh"
SSOT_YAML="$SKILL_ROOT/routing-ssot/routing-ssot.yaml"
SSOT_LOADER="$SKILL_LIB/ssot_loader.py"

# 테스트용 임시 디렉터리 생성
TEST_DIR=$(mktemp -d -t kant-stress-XXXXXX)
TASK_FILE="$TEST_DIR/TASK.md"

# 원래 파일 백업 및 복구를 위한 백업 경로 설정
YAML_BAK="$TEST_DIR/routing-ssot.yaml.bak"
LOADER_BAK="$TEST_DIR/ssot_loader.py.bak"

# 청소(Clean up) 및 원본 복구 트랩 설정
cleanup() {
  echo "🧹 임시 파일 정리 및 복구 중..."
  if [ -f "$YAML_BAK" ]; then
    mv "$YAML_BAK" "$SSOT_YAML"
  fi
  if [ -f "$LOADER_BAK" ]; then
    mv "$LOADER_BAK" "$SSOT_LOADER"
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

declare -i PASS=0 FAIL=0

# 필요한 리소스 체크
for f in "$ROUTING_PARSER" "$SSOT_YAML" "$SSOT_LOADER"; do
  [ -f "$f" ] || { echo "❌ 필수 파일 누락: $f"; exit 1; }
done

echo "=========================================================="
echo "      🚀 SSOT 2주 검증 압축: 스트레스 & 카오스 시뮬레이션"
echo "=========================================================="

# ─────────────────────────────────────────────────────────
# Test 1: 무작위 시나리오 500회 대조 테스트
# ─────────────────────────────────────────────────────────
echo "🧪 [테스트 1] 무작위 작업 시나리오 500회 교차 검증 (Hardcode vs SSOT)"

# 테스트용 랜덤 키워드 세트
keywords=(
  "접근성" "a11y" "accessibility" "screenshot" "visual regression" "css" "layout"
  "frontend" "backend" "sandbox" "database" "performance" "memory leak" "refactor"
  "test" "security" "docker" "oauth" "token" "login" "parser" "yaml" "json"
  "modify" "delete" "add" "fix" "hotfix" "improve" "optimize" "clean" "check"
)

complexities=("T1" "T2" "T3" "tiny" "standard" "hard" "huge" "visual" "review" "쉽게" "어렵게")

for i in {1..500}; do
  # 랜덤 텍스트 생성
  num_kw=$((RANDOM % 5 + 2))
  text="## 작업 목표\n"
  for ((j=0; j<num_kw; j++)); do
    rand_kw=${keywords[$((RANDOM % ${#keywords[@]}))]}
    text="$text - $rand_kw 관련 작업을 수행합니다.\n"
  done
  
  rand_comp=${complexities[$((RANDOM % ${#complexities[@]}))]}
  text="$text\n난이도 및 복잡도 수준은 $rand_comp 입니다."
  
  printf "$text" > "$TASK_FILE"
  
  # 1) Hardcode 결과
  res_hard=$(KANT_ROUTING_SOURCE=hardcode bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep -E '^(judged_route|effective_route|primary)=' | sort | tr '\n' ' ')
  
  # 2) SSOT 결과
  res_ssot=$(KANT_ROUTING_SOURCE=ssot bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep -E '^(judged_route|effective_route|primary)=' | sort | tr '\n' ' ')
  
  if [ "$res_hard" != "$res_ssot" ]; then
    echo "  ❌ 불일치 발견 (시나리오 #$i):"
    echo "    입력 텍스트:"
    cat "$TASK_FILE" | sed 's/^/      /'
    echo "    Hardcode 결과: $res_hard"
    echo "    SSOT 결과:     $res_ssot"
    ((FAIL++))
    exit 1
  fi
done

echo "  ✅ 500회 교차 검증 성공 (결과 100% 일치)"
((PASS++))

# ─────────────────────────────────────────────────────────
# Test 2: YAML 손상/삭제 상황 (카오스 테스트 1)
# ─────────────────────────────────────────────────────────
echo "🧪 [테스트 2] YAML 파일 유실/손상 시 Fail-safe 동작 확인"

cat > "$TASK_FILE" <<'EOF'
# UI layout 변경 작업
CSS 스타일을 고치고 화면 배치를 바꿉니다.
EOF

# 기대값은 하드코딩 로직 자체를 그때그때 물어서 정한다 (고정 문자열 금지 —
# judge_task_routing()의 분류 규칙이 바뀌면 기대값도 자동으로 따라오게 하기
# 위함. 이 텍스트가 실제로 ui로 분류되는지 여부와 무관하게, "카오스 상황에서도
# hardcode 모드와 같은 결과가 나오는가"만 검증한다.)
expected=$(KANT_ROUTING_SOURCE=hardcode bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)

# 1) YAML 백업 및 삭제
mv "$SSOT_YAML" "$YAML_BAK"

# 2) SSOT 모드 상태에서 라우팅 요청 (YAML이 없으므로 에러가 나야 하지만, 하드코딩으로 무사히 Fallback 되어야 함)
result=$(KANT_ROUTING_SOURCE=ssot bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)

if [ -n "$result" ] && [ "$result" = "$expected" ]; then
  echo "  ✅ YAML 유실 시 기존 하드코딩($expected)으로 안전하게 자동 전환됨"
  ((PASS++))
else
  echo "  ❌ YAML 유실 시 오작동 발생. 기대: '$expected', 결과: '$result'"
  ((FAIL++))
fi

# YAML 복구
mv "$YAML_BAK" "$SSOT_YAML"

# ─────────────────────────────────────────────────────────
# Test 3: SSOT Loader 스크립트 크래시 상황 (카오스 테스트 2)
# ─────────────────────────────────────────────────────────
echo "🧪 [테스트 3] SSOT Loader 파이썬 스크립트 강제 크래시 시 Fail-safe 확인"

# 1) 파이썬 로더 백업 및 에러를 유발하는 잘못된 스크립트로 대체
mv "$SSOT_LOADER" "$LOADER_BAK"
cat > "$SSOT_LOADER" <<'EOF'
import sys
# 강제 SyntaxError 유발 또는 예외 발생
raise RuntimeError("강제 시스템 크래시 시뮬레이션")
EOF
chmod +x "$SSOT_LOADER"

# 2) SSOT 모드 상태에서 라우팅 요청 (로더가 완전히 죽었으므로 기존 하드코딩으로 즉각 롤백되어야 함)
result_crash=$(KANT_ROUTING_SOURCE=ssot bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)

if [ -n "$result_crash" ] && [ "$result_crash" = "$expected" ]; then
  echo "  ✅ 로더 크래시 발생 시 에러가 조용히 무시되며, 기존 하드코딩($expected)으로 안전하게 Fallback 완료"
  ((PASS++))
else
  echo "  ❌ 로더 크래시 상황 제어 실패. 기대: '$expected', 결과: '$result_crash'"
  ((FAIL++))
fi

# 로더 복구
mv "$LOADER_BAK" "$SSOT_LOADER"

# ─────────────────────────────────────────────────────────
# Test 4: 초대형(비정상) 입력 테스트 (스트레스 테스트 2)
# ─────────────────────────────────────────────────────────
echo "🧪 [테스트 4] 초대형 입력값(10,000라인의 비정상 텍스트) 처리 및 메모리/성능 검사"

# 1만 줄짜리 거대 파일 생성
for i in {1..10000}; do
  echo "이 줄은 대용량 파일 파이프라인 성능을 테스트하기 위한 덤프 데이터입니다. line $i" >> "$TASK_FILE"
done
echo "마지막 줄에 a11y UI 접근성 요소를 추가합니다." >> "$TASK_FILE"

# 타임아웃 3초 이내에 완료되는지 성능 및 안정성 체크 (macOS timeout 미지원 대응 우회책)
KANT_ROUTING_SOURCE=ssot bash "$ROUTING_PARSER" match "$TASK_FILE" &>/dev/null &
PID=$!

# 3초 동안 대기 후 아직 살아있다면 강제 종료하는 감시 프로세스
(sleep 3; kill -0 $PID 2>/dev/null && kill -9 $PID) &
WATCHER_PID=$!

if wait $PID 2>/dev/null; then
  # 3초 내 정상 종료 시 감시 프로세스도 함께 종료
  kill $WATCHER_PID 2>/dev/null || true
  wait $WATCHER_PID 2>/dev/null || true

  result_large=$(KANT_ROUTING_SOURCE=ssot bash "$ROUTING_PARSER" match "$TASK_FILE" 2>/dev/null | grep '^judged_route=' | cut -d= -f2)
  if [ "$result_large" = "agy:gemini-3.5-flash" ]; then
    echo "  ✅ 초대형 입력도 3초 내에 빠르고 안전하게 파싱하여 올바른 경로(agy:gemini-3.5-flash) 판정 성공"
    ((PASS++))
  else
    echo "  ❌ 초대형 입력 결과 불일치. 결과: '$result_large'"
    ((FAIL++))
  fi
else
  # 3초가 지나 감시 프로세스에 의해 강제 종료되었거나 에러 발생 시
  echo "  ❌ 초대형 입력 처리 중 타임아웃(3초 초과) 또는 프로그램 중단 발생"
  ((FAIL++))
fi

# ─────────────────────────────────────────────────────────
# 최종 리포트
# ─────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
echo "🏁 시뮬레이션 테스트 최종 결과"
echo "  - 성공(PASS): $PASS / 4"
echo "  - 실패(FAIL): $FAIL / 4"
echo "=========================================================="

[ "$FAIL" -eq 0 ]
