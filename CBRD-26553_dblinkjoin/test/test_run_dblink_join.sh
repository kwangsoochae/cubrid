#!/bin/bash
# dblink 조인 테스트 실행 스크립트
# - 원격 DB testdb4dblink 에 test_dblink_join_remote.sql 수행
# - 로컬 DB testdb 에 test_dblink_join_local.sql 수행
# 사용법: ./test_run_dblink_join.sh [옵션]
#   -u user  (인자 없으면 -u/-p 옵션 생략)
#   -p pass  (인자 없으면 -u/-p 옵션 생략)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DB="testdb4dblink"
LOCAL_DB="testdb"

USER=""
PASS=""
USER_PROVIDED=0
PASS_PROVIDED=0

while getopts u:p: opt; do
  case $opt in
    u) USER="$OPTARG"; USER_PROVIDED=1 ;;
    p) PASS="$OPTARG"; PASS_PROVIDED=1 ;;
    *) exit 1 ;;
  esac
done

# csql 옵션 구성
CSQL_OPTS=""
if [ $USER_PROVIDED -eq 1 ]; then
  CSQL_OPTS="$CSQL_OPTS -u $USER"
fi
if [ $PASS_PROVIDED -eq 1 ]; then
  CSQL_OPTS="$CSQL_OPTS -p $PASS"
fi

echo "=== 1) 원격 DB ($REMOTE_DB) 에 test_dblink_join_remote.sql 수행 ==="
csql $CSQL_OPTS "$REMOTE_DB" -i "$SCRIPT_DIR/test_dblink_join_remote.sql"

echo ""
echo "=== 2) 로컬 DB ($LOCAL_DB) 에 test_dblink_join_local.sql 수행 ==="
csql $CSQL_OPTS "$LOCAL_DB" -i "$SCRIPT_DIR/test_dblink_join_local.sql"

echo ""
echo "=== 완료 ==="
