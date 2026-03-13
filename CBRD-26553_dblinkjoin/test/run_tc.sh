#!/bin/bash
# TC 단위 실행 스크립트 (PRD/TESTS 문서의 TC-101 ~ TC-401)
# 전제: test_setup_dblink_databases.sh 후 test_run_dblink_join.sh 로 원격·로컬 스키마/데이터 적재 완료.
# 사용법:
#   ./run_tc.sh all                   # TC 실행 후 각 정답지(TC-xxx.expected)와 비교
#   ./run_tc.sh TC-101 [TC-102]       # 지정 TC만 실행·비교
#   ./run_tc.sh --no-compare all      # 비교 없이 실행만
#   ./run_tc.sh --gen-expected all    # 실제 출력을 expected 파일로 저장(정답지 생성)
#   ./run_tc.sh --plan all            # join order 포함 실행 계획 출력 (SET TRACE ON / SHOW TRACE)
#   ./run_tc.sh --xasl TC-101        # XASL 구조 덤프 출력 (xasl_debug_dump=on)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DB="${CUBRID_DBLINK_LOCAL_DB:-testdb}"
CSQL_OPTS="${CSQL_OPTS:--u cubrid -p cubrid}"
NO_COMPARE=0
GEN_EXPECTED=0
PLAN_LEVEL=""   # "" = off, "on"
XASL_DUMP=0

# 인자에서 플래그 제거
ARGS=()
for a in "$@"; do
  if [ "$a" = "--no-compare" ]; then
    NO_COMPARE=1
  elif [ "$a" = "--gen-expected" ]; then
    GEN_EXPECTED=1
    NO_COMPARE=1
  elif [ "$a" = "--plan" ]; then
    PLAN_LEVEL="on"
  elif [ "$a" = "--xasl" ]; then
    XASL_DUMP=1
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

# SQL 파일을 xasl_debug_dump=on/off 로 감싼 임시 파일 생성
make_xasl_sql() {
  local sqlf="$1"
  local tmpf
  tmpf=$(mktemp /tmp/run_tc_XXXXXX.sql)
  printf "SET SYSTEM PARAMETERS 'xasl_debug_dump=on';\n" > "$tmpf"
  cat "$sqlf" >> "$tmpf"
  printf "\nSET SYSTEM PARAMETERS 'xasl_debug_dump=off';\n" >> "$tmpf"
  echo "$tmpf"
}


# SQL 파일을 SET TRACE ON / SHOW TRACE 로 감싼 임시 파일 생성
# CS 모드에서는 ;plan이 서버→클라이언트 전달이 안 되므로 TRACE 방식 사용
# 반환: 임시 파일 경로 (호출자가 rm 책임)
make_plan_sql() {
  local sqlf="$1"
  local tmpf
  tmpf=$(mktemp /tmp/run_tc_XXXXXX.sql)
  printf 'SET TRACE ON;\n' > "$tmpf"
  cat "$sqlf" >> "$tmpf"
  printf '\nSHOW TRACE;\n' >> "$tmpf"
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
  elif [ -n "$PLAN_LEVEL" ]; then
    tmpf=$(make_plan_sql "$sqlf")
    run_sqlf="$tmpf"
  fi

  echo "=== $tc ==="
  if [ $XASL_DUMP -eq 1 ]; then
    out=$(csql -S $CSQL_OPTS "$LOCAL_DB" -i "$run_sqlf" 2>&1)
  else
    out=$(csql $CSQL_OPTS "$LOCAL_DB" -i "$run_sqlf" 2>&1)
  fi
  echo "$out" | grep -v 'KS_DBLINK_DEBUG' || true

  [ -n "$tmpf" ] && rm -f "$tmpf"

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

  if [ $NO_COMPARE -eq 1 ] || [ -n "$PLAN_LEVEL" ] || [ $XASL_DUMP -eq 1 ]; then
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
  echo "사용법: $0 [--no-compare|--gen-expected|--plan|--xasl] all | TC-101 [TC-102 ...]" >&2
  exit 1
fi

if [ "${ARGS[0]}" = "all" ]; then
  for tc in TC-101.sql TC-102.sql TC-103.sql TC-104.sql \
            TC-201.sql TC-202.sql TC-203.sql TC-204.sql TC-205.sql \
            TC-401.sql \
            TC-501.sql TC-502.sql TC-503.sql \
            TC-601.sql TC-602.sql \
            TC-POC-E.sql; do
    if run_one "$tc"; then
      RESULT_LINES+=("  $tc: PASS")
    else
      RESULT_LINES+=("  $tc: FAIL")
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
  if [ $NO_COMPARE -eq 0 ] && [ -z "$PLAN_LEVEL" ]; then
    echo "TC-301은 수동/스크립트 검증. test/TC-301.md 참고."
    echo ""
  fi
else
  for t in "${ARGS[@]}"; do
    if [ "$t" = "TC-301" ] || [ "$t" = "TC-301.md" ]; then
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

# 결과 종합 출력 (비교 모드이고 plan 출력 아닐 때만)
if [ $NO_COMPARE -eq 0 ] && [ -z "$PLAN_LEVEL" ] && [ $XASL_DUMP -eq 0 ] && [ ${#RESULT_LINES[@]} -gt 0 ]; then
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

if [ $NO_COMPARE -eq 1 ] || [ -n "$PLAN_LEVEL" ] || [ $XASL_DUMP -eq 1 ]; then
  exit 0
fi
if [ $FAIL_COUNT -gt 0 ]; then
  exit 1
fi
exit 0
