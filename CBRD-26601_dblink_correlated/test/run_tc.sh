#!/bin/bash
# TC 단위 실행 스크립트 (correlated 스칼라 서브쿼리 최적화)
# 전제: setup_remote.sql 을 원격 DB에, setup_local.sql 을 로컬 DB에 실행 완료.
# 사용법:
#   ./run_tc.sh all                   # TC 실행 후 각 정답지(TC-xxx.expected)와 비교
#   ./run_tc.sh TC-101 [TC-102]       # 지정 TC만 실행·비교
#   ./run_tc.sh --no-compare all      # 비교 없이 실행만
#   ./run_tc.sh --gen-expected all    # 실제 출력을 expected 파일로 저장(정답지 생성)
#   ./run_tc.sh --xasl TC-101         # XASL 구조 덤프 출력 (xasl_debug_dump=on)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DB="${CUBRID_DBLINK_LOCAL_DB:-testdb}"
CSQL_OPTS="${CSQL_OPTS:--u cubrid -p cubrid}"
NO_COMPARE=0
GEN_EXPECTED=0
XASL_DUMP=0

ARGS=()
for a in "$@"; do
  case "$a" in
    --no-compare)   NO_COMPARE=1 ;;
    --gen-expected) GEN_EXPECTED=1; NO_COMPARE=1 ;;
    --xasl)         XASL_DUMP=1 ;;
    --*)
      echo "알 수 없는 옵션: $a" >&2
      echo "사용법: $0 [--no-compare|--gen-expected|--xasl] all | TC-101 [TC-102 ...]" >&2
      exit 1
      ;;
    *)  ARGS+=("$a") ;;
  esac
done

# csql 출력에서 ERROR 줄만 추출 (오류 기대 TC용)
extract_errors() {
  grep "^ERROR:"
}

# csql 출력에서 SELECT Result 블록만 추출·정규화 (시간 정보 제거)
extract_result() {
  awk '
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

make_xasl_sql() {
  local sqlf="$1"
  local tmpf
  tmpf=$(mktemp /tmp/run_tc_XXXXXX.sql)
  printf "SET SYSTEM PARAMETERS 'xasl_debug_dump=on';\n" > "$tmpf"
  cat "$sqlf" >> "$tmpf"
  printf "\nSET SYSTEM PARAMETERS 'xasl_debug_dump=off';\n" >> "$tmpf"
  echo "$tmpf"
}

run_one() {
  local tc="${1%.*}"
  local sqlf="$SCRIPT_DIR/$1"
  local expf="$SCRIPT_DIR/$tc.expected"
  local run_sqlf="$sqlf"
  local tmpf=""
  local out
  local result
  local rc=0

  if [ ! -f "$sqlf" ]; then
    echo "건너뜀(파일 없음): $tc" >&2
    return 0
  fi

  if [ $XASL_DUMP -eq 1 ]; then
    tmpf=$(make_xasl_sql "$sqlf")
    run_sqlf="$tmpf"
  fi

  echo "=== $tc ==="
  if [ $NO_COMPARE -eq 1 ] && [ $GEN_EXPECTED -eq 0 ]; then
    echo "--- SQL ---"
    cat "$sqlf"
    echo "--- 출력 ---"
  fi
  out=$(csql $CSQL_OPTS "$LOCAL_DB" -i "$run_sqlf" 2>&1)
  echo "$out"

  [ -n "$tmpf" ] && rm -f "$tmpf"

  if [ $GEN_EXPECTED -eq 1 ]; then
    result=$(echo "$out" | extract_result)
    [ -z "$result" ] && result=$(echo "$out" | extract_errors)
    if [ -z "$result" ]; then
      echo "[WARN] $tc — Result/ERROR 블록을 추출하지 못함, expected 파일 생성 생략"
    else
      printf '%s\n' "$result" > "$expf"
      echo "[GEN] $tc.expected 생성 완료"
    fi
    echo ""
    return 0
  fi

  if [ $NO_COMPARE -eq 1 ] || [ $XASL_DUMP -eq 1 ]; then
    echo ""
    return 0
  fi

  if [ ! -f "$expf" ]; then
    echo "[정답지 없음] $tc.expected 없음, 비교 생략"
    echo ""
    return 0
  fi

  result=$(echo "$out" | extract_result)
  [ -z "$result" ] && result=$(echo "$out" | extract_errors)
  if [ -z "$result" ]; then
    echo "[FAIL] $tc — Result/ERROR 블록을 추출하지 못함"
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
  echo "사용법: $0 [--no-compare|--gen-expected|--xasl] all | TC-101 [TC-102 ...]" >&2
  exit 1
fi

if [ "${ARGS[0]}" = "all" ]; then
  for tc in $(ls "$SCRIPT_DIR"/TC-*.sql 2>/dev/null | xargs -n1 basename | sort); do
    if run_one "$tc"; then
      RESULT_LINES+=("  $tc: PASS")
    else
      RESULT_LINES+=("  $tc: FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
else
  for t in "${ARGS[@]}"; do
    if run_one "$t"; then
      RESULT_LINES+=("  $t: PASS")
    else
      RESULT_LINES+=("  $t: FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
fi

echo "=== 완료 ==="

if [ $NO_COMPARE -eq 0 ] && [ $XASL_DUMP -eq 0 ] && [ ${#RESULT_LINES[@]} -gt 0 ]; then
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

[ $FAIL_COUNT -gt 0 ] && exit 1
exit 0
