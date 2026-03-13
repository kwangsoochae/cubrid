#!/bin/bash
# setup_all.sh: CBRD-26553 dblink 조인 테스트에 필요한 모든 스키마/데이터를 생성한다.
#
# 사용법:
#   ./setup_all.sh [옵션]
#
# 옵션:
#   -r <db>   원격 DB 이름 (기본: testdb4dblink)
#   -l <db>   로컬 DB 이름  (기본: testdb)
#   -u <user> DB 사용자    (기본: cubrid)
#   -p <pass> 비밀번호     (기본: cubrid)
#   -h        도움말
#
# 실행 순서:
#   1) 원격 DB: 기본 스키마 → edge case → 대용량 → worst case → break-even
#   2) 로컬  DB: 기본 스키마 → edge case → 대용량 → worst case → break-even

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_DB="testdb4dblink"
LOCAL_DB="testdb"
DB_USER="cubrid"
DB_PASS="cubrid"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while getopts "r:l:u:p:h" opt; do
  case $opt in
    r) REMOTE_DB="$OPTARG" ;;
    l) LOCAL_DB="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    p) DB_PASS="$OPTARG" ;;
    h) usage ;;
    *) echo "알 수 없는 옵션. -h 로 도움말 확인." >&2; exit 1 ;;
  esac
done

CSQL_REMOTE="csql -u $DB_USER -p $DB_PASS $REMOTE_DB"
CSQL_LOCAL="csql  -u $DB_USER -p $DB_PASS $LOCAL_DB"

FAIL=0

run_sql() {
  local label="$1"
  local csql_cmd="$2"
  local sql_file="$SCRIPT_DIR/$3"

  if [ ! -f "$sql_file" ]; then
    echo "[SKIP] $label — 파일 없음: $3"
    return 0
  fi

  echo -n "  $label ... "
  if $csql_cmd -i "$sql_file" > /tmp/setup_all_out.txt 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/setup_all_out.txt
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================"
echo " CBRD-26553 dblink 조인 테스트 셋업"
echo "  원격 DB : $REMOTE_DB"
echo "  로컬 DB  : $LOCAL_DB"
echo "  사용자   : $DB_USER"
echo "========================================"

echo ""
echo "[원격 DB: $REMOTE_DB]"
run_sql "기본 스키마    (remote_t 7행)"                     "$CSQL_REMOTE" "test_dblink_join_remote.sql"
run_sql "edge case     (remote_compound_t 4행)"             "$CSQL_REMOTE" "setup_edge_cases_remote.sql"
run_sql "대용량        (remote_large_t 10,000행)"           "$CSQL_REMOTE" "setup_large_data_remote.sql"
run_sql "worst case    (remote_hiselectivity_t 1,000행)"   "$CSQL_REMOTE" "setup_worst_case_remote.sql"
run_sql "break-even    (remote_breakeven_t 1,000행)"        "$CSQL_REMOTE" "setup_breakeven_remote.sql"

echo ""
echo "[로컬 DB: $LOCAL_DB]"
run_sql "기본 스키마    (local_t 5행, cubrid_conn 서버 등록)" "$CSQL_LOCAL" "test_dblink_join_local.sql"
run_sql "edge case     (local_null_key_t 3행, local_compound_t 4행)" "$CSQL_LOCAL" "setup_edge_cases_local.sql"
run_sql "대용량        (local_small_t 10행, local_nomatch_t 10행)" "$CSQL_LOCAL" "setup_large_data_local.sql"
run_sql "worst case    (local_hiselectivity_t 100행, local_manyouter_t 1,000행)" "$CSQL_LOCAL" "setup_worst_case_local.sql"
run_sql "break-even    (local_breakeven_t 10행)"             "$CSQL_LOCAL" "setup_breakeven_local.sql"

echo ""
echo "========================================"
if [ $FAIL -eq 0 ]; then
  echo " 완료: 모든 셋업 성공"
else
  echo " 완료: 실패 $FAIL 건"
  exit 1
fi
echo "========================================"
