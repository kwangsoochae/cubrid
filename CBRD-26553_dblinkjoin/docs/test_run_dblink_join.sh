#!/bin/bash
# dblink 조인 테스트 실행 스크립트
# - 원격 DB testdb4dblink 에 test_dblink_join_remote.sql 수행
# - 로컬 DB testdb 에 test_dblink_join_local.sql 수행
# 사용법: ./test_run_dblink_join.sh [옵션]
#   -u user  (기본: cubrid)
#   -p pass  (기본: cubrid)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER="${CUBRID_USER:-cubrid}"
PASS="${CUBRID_PASSWORD:-cubrid}"
REMOTE_DB="testdb4dblink"
LOCAL_DB="testdb"

while getopts u:p: opt; do
  case $opt in
    u) USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    *) exit 1 ;;
  esac
done

echo "=== 1) 원격 DB ($REMOTE_DB) 에 test_dblink_join_remote.sql 수행 ==="
csql -u "$USER" -p "$PASS" "$REMOTE_DB" -i "$SCRIPT_DIR/test_dblink_join_remote.sql"

echo ""
echo "=== 2) 로컬 DB ($LOCAL_DB) 에 test_dblink_join_local.sql 수행 ==="
csql -u "$USER" -p "$PASS" "$LOCAL_DB" -i "$SCRIPT_DIR/test_dblink_join_local.sql"

echo ""
echo "=== 완료 ==="
