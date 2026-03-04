#!/bin/bash
# TC 단위 실행 스크립트 (PRD/TESTS 문서의 TC-101 ~ TC-401)
# 전제: test_setup_dblink_databases.sh 후 test_run_dblink_join.sh 로 원격·로컬 스키마/데이터 적재 완료.
# 사용법:
#   ./run_tc.sh all                   # TC 실행 후 각 정답지(TC-xxx.expected)와 비교
#   ./run_tc.sh TC-101 [TC-102]       # 지정 TC만 실행·비교
#   ./run_tc.sh --no-compare all      # 비교 없이 실행만
#   ./run_tc.sh --gen-expected all    # 실제 출력을 expected 파일로 저장(정답지 생성)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DB="${CUBRID_DBLINK_LOCAL_DB:-testdb}"
CSQL_OPTS="${CSQL_OPTS:--u cubrid -p cubrid}"
NO_COMPARE=0
GEN_EXPECTED=0

# 인자에서 플래그 제거
ARGS=()
for a in "$@"; do
  if [ "$a" = "--no-compare" ]; then
    NO_COMPARE=1
  elif [ "$a" = "--gen-expected" ]; then
    GEN_EXPECTED=1
    NO_COMPARE=1
  else
    ARGS+=("$a")
  fi
done

# csql 출력에서 Result 블록만 추출·정규화 (디버그 제거, "rows selected" 줄에서 시간 제거)
# "=== <Result...===" 다음 빈 줄은 제외 (정답지에는 빈 줄 없음)
extract_result() {
  awk '
    /\[KS_DBLINK_DEBUG\]/ { next }
    /=== <Result of SELECT/ { in_result=1; skip_blank=1; next }
    in_result {
      if (/row.* selected/) {
        sub(/[[:space:]]*\([0-9.]* sec\).*$/, "")
        print
        in_result=0
      } else if (skip_blank && /^[[:space:]]*$/) {
        skip_blank=0
        next
      } else {
        skip_blank=0
        print
      }
    }
  '
}

run_one() {
  local tc="$1"
  local sqlf="$SCRIPT_DIR/$tc.sql"
  local expf="$SCRIPT_DIR/$tc.expected"
  local out
  local result
  local rc=0

  if [ ! -f "$sqlf" ]; then
    echo "건너뜀(파일 없음): $tc" >&2
    return 0
  fi

  echo "=== $tc ==="
  out=$(csql $CSQL_OPTS "$LOCAL_DB" -i "$sqlf" 2>&1)
  echo "$out" | grep -v 'KS_DBLINK_DEBUG' || true

  if [ $GEN_EXPECTED -eq 1 ]; then
    result=$(echo "$out" | extract_result)
    if [ -z "$result" ]; then
      echo "[WARN] $tc — Result 블록을 추출하지 못함, expected 파일 생성 생략"
    else
      printf '%s\n' "$result" > "$expf"
      echo "[GEN] $tc.expected 생성 완료"
    fi
    echo ""
    return 0
  fi

  if [ $NO_COMPARE -eq 1 ]; then
    echo ""
    return 0
  fi

  if [ ! -f "$expf" ]; then
    echo "[정답지 없음] $tc.expected 없음, 비교 생략"
    echo ""
    return 0
  fi

  result=$(echo "$out" | extract_result)
  if [ -z "$result" ]; then
    echo "[FAIL] $tc — Result 블록을 추출하지 못함"
    echo ""
    return 1
  fi

  if diff -q <(printf '%s\n' "$result") "$expf" >/dev/null 2>&1; then
    echo "[PASS] $tc"
  else
    echo "[FAIL] $tc — 정답지와 불일치"
    diff <(printf '%s\n' "$result") "$expf" || true
    rc=1
  fi
  echo ""
  return $rc
}

FAIL_COUNT=0
RESULT_LINES=()

if [ ${#ARGS[@]} -eq 0 ]; then
  echo "사용법: $0 [--no-compare|--gen-expected] all | TC-101 [TC-102 ...]" >&2
  exit 1
fi

if [ "${ARGS[0]}" = "all" ]; then
  for tc in TC-101 TC-102 TC-103 TC-104 TC-201 TC-202 TC-203 TC-204 TC-205 TC-401; do
    if run_one "$tc"; then
      RESULT_LINES+=("  $tc: PASS")
    else
      RESULT_LINES+=("  $tc: FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
  if [ $NO_COMPARE -eq 0 ]; then
    echo "TC-301은 수동/스크립트 검증. test/TC-301.md 참고."
    echo ""
  fi
else
  for t in "${ARGS[@]}"; do
    if [ "$t" = "TC-301" ]; then
      echo "TC-301은 SQL이 아닌 수동/스크립트 검증. test/TC-301.md 참고."
      echo ""
    else
      if run_one "$t"; then
        RESULT_LINES+=("  $t: PASS")
      else
        RESULT_LINES+=("  $t: FAIL")
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    fi
  done
fi

echo "=== 완료 ==="

# 결과 종합 출력 (비교 모드일 때만)
if [ $NO_COMPARE -eq 0 ] && [ ${#RESULT_LINES[@]} -gt 0 ]; then
  echo ""
  echo "========== 결과 종합 =========="
  for line in "${RESULT_LINES[@]}"; do
    echo "$line"
  done
  PASS_COUNT=$((${#RESULT_LINES[@]} - FAIL_COUNT))
  echo ""
  echo "  통과: $PASS_COUNT, 실패: $FAIL_COUNT"
  echo "======================================"
fi

if [ $NO_COMPARE -eq 1 ]; then
  exit 0
fi
if [ $FAIL_COUNT -gt 0 ]; then
  exit 1
fi
exit 0
