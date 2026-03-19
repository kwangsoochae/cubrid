#!/bin/bash
# setup_schema.sh: CBRD-26601 correlated 서브쿼리 테스트에 필요한 스키마/데이터를 생성한다.
#
# 사용법:
#   ./setup_schema.sh [옵션]
#
# 옵션:
#   -r <db>     원격 DB 이름 (기본: testdb_remote)
#   -l <db>     로컬 DB 이름  (기본: testdb)
#   -u <user>   DB 사용자    (기본: cubrid)
#   -p <pass>   비밀번호     (기본: cubrid)
#   --large     대용량 데이터 셋업 추가 실행 (TC-105/T6-6용)
#   --restore   소량 데이터로 복원 (대용량 셋업 후 기본 데이터 복원)
#   -h          도움말
#
# 실행 순서 (기본):
#   1) 원격 DB: setup_remote.sql (remote_t 7행)
#   2) 로컬  DB: setup_local.sql (local_t 5행, cubrid_conn 등록)
#
# 실행 순서 (--large):
#   1) 원격 DB: setup_large_remote.sql (remote_t 100,000행)
#   2) 로컬  DB: setup_large_local.sql (local_t 100행)
#
# 실행 순서 (--restore):
#   --large 후 기본 데이터로 되돌리기. --large 없이 기본 셋업 재실행.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_DB="testdb_remote"
LOCAL_DB="testdb"
DB_USER="cubrid"
DB_PASS="cubrid"
MODE="basic"   # basic | large | restore

# DB에 cubrid 사용자가 없으면 생성 (dba 권한으로 실행, 실패 무시)
ensure_cubrid_user() {
    local dbname=$1
    local user=$2
    local pass=$3
    csql -u dba "$dbname" -c "CREATE USER $user PASSWORD '$pass';" >/dev/null 2>&1 || true
}

# DB 서버가 실행 중인지 확인하고, 없으면 생성 후 시작
ensure_db_server() {
    local dbname=$1
    if cubrid server status 2>/dev/null | grep -q "Server $dbname "; then
        return 0
    fi
    echo "  '$dbname' 서버가 실행 중이 아닙니다. 시작합니다..."
    # DB가 없으면 생성
    local out
    out=$(cubrid createdb "$dbname" en_US -F "$CUBRID_DATABASES" 2>&1)
    if [ $? -ne 0 ] && ! echo "$out" | grep -qi "already exists\|exists"; then
        echo "  경고: '$dbname' 생성 실패 — $out" >&2
    fi
    cubrid server start "$dbname"
    sleep 1
}

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -r) REMOTE_DB="$2"; shift 2 ;;
        -l) LOCAL_DB="$2";  shift 2 ;;
        -u) DB_USER="$2";   shift 2 ;;
        -p) DB_PASS="$2";   shift 2 ;;
        --large)   MODE="large";   shift ;;
        --restore) MODE="restore"; shift ;;
        -h) usage ;;
        *) echo "알 수 없는 옵션: $1 (-h 로 도움말 확인)" >&2; exit 1 ;;
    esac
done

if [ -n "$DB_PASS" ]; then
    CSQL_REMOTE="csql -u $DB_USER -p $DB_PASS $REMOTE_DB"
    CSQL_LOCAL="csql  -u $DB_USER -p $DB_PASS $LOCAL_DB"
else
    CSQL_REMOTE="csql -u $DB_USER $REMOTE_DB"
    CSQL_LOCAL="csql  -u $DB_USER $LOCAL_DB"
fi

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
    if $csql_cmd -i "$sql_file" > /tmp/setup_schema_out.txt 2>&1; then
        echo "OK"
    else
        echo "FAIL"
        cat /tmp/setup_schema_out.txt
        FAIL=$((FAIL + 1))
    fi
}

echo "========================================"
echo " CBRD-26601 correlated 서브쿼리 테스트 셋업"
echo "  원격 DB : $REMOTE_DB"
echo "  로컬 DB  : $LOCAL_DB"
echo "  사용자   : $DB_USER"
echo "  모드     : $MODE"
echo "========================================"

# CUBRID 서비스 및 DB 서버 준비
if ! cubrid service status >/dev/null 2>&1; then
    echo "CUBRID 서비스 시작 중..."
    cubrid service start
    sleep 2
fi
ensure_db_server "$REMOTE_DB"
ensure_db_server "$LOCAL_DB"
ensure_cubrid_user "$REMOTE_DB" "$DB_USER" "$DB_PASS"
ensure_cubrid_user "$LOCAL_DB"  "$DB_USER" "$DB_PASS"
echo ""

case $MODE in
    basic|restore)
        echo ""
        echo "[원격 DB: $REMOTE_DB]"
        run_sql "기본 스키마  (remote_t 7행: id=1/2/3/5 포함)" \
            "$CSQL_REMOTE" "setup_remote.sql"

        echo ""
        echo "[로컬 DB: $LOCAL_DB]"
        run_sql "기본 스키마  (local_t 5행, cubrid_conn 서버 등록)" \
            "$CSQL_LOCAL" "setup_local.sql"
        ;;

    large)
        echo ""
        echo "[원격 DB: $REMOTE_DB]"
        run_sql "대용량 스키마 (remote_t 100,000행: id 1~1000, id당 100행)" \
            "$CSQL_REMOTE" "setup_large_remote.sql"

        echo ""
        echo "[로컬 DB: $LOCAL_DB]"
        run_sql "대용량 스키마 (local_t 100행: id 1~100)" \
            "$CSQL_LOCAL" "setup_large_local.sql"

        echo ""
        echo "※ 소량 데이터로 복원하려면: ./setup_schema.sh --restore"
        ;;
esac

echo ""
echo "========================================"
if [ $FAIL -eq 0 ]; then
    echo " 완료: 모든 셋업 성공"
else
    echo " 완료: 실패 $FAIL 건"
    exit 1
fi
echo "========================================"

# 셋업 완료 후 동작 확인 — correlated 서브쿼리 실행
echo ""
echo "========================================"
echo " [검증] DBLink correlated 서브쿼리 동작 확인"
echo "========================================"

case $MODE in
    basic|restore)
        echo "  쿼리: SELECT local_t + (scalar subquery → remote_t@cubrid_conn WHERE id=?) LIMIT 1"
        echo ""
        $CSQL_LOCAL -c "
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a ORDER BY a.id;"

        echo ""
        echo "========================================"
        echo " [검증] presentation 예제: orders × customer@cubrid_conn"
        echo "========================================"
        echo "  쿼리: SELECT order_id, amount, (SELECT c.name FROM customer@cubrid_conn WHERE cust_id=? LIMIT 1)"
        echo ""
        $CSQL_LOCAL -c "
SELECT o.order_id,
       o.amount,
       (SELECT c.name
          FROM customer@cubrid_conn c
         WHERE c.cust_id = o.cust_id
         LIMIT 1) AS cust_name
  FROM orders o
 ORDER BY o.order_id;"
        ;;
    large)
        echo "  행 수 확인"
        echo -n "  [원격 DB] remote_t: "
        $CSQL_REMOTE -c "SELECT COUNT(*) AS total FROM remote_t;"
        echo -n "  [로컬  DB] local_t : "
        $CSQL_LOCAL  -c "SELECT COUNT(*) AS total FROM local_t;"
        echo ""
        echo "  샘플 (id <= 3, 각 1행씩):"
        $CSQL_LOCAL -c "
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a WHERE a.id <= 3 ORDER BY a.id;"
        ;;
esac
