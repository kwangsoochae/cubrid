#!/bin/bash
# setup_databases.sh: CBRD-26601 테스트용 CUBRID 데이터베이스 생성 및 서버 시작
#
# 사용법:
#   ./setup_databases.sh [원격DB명] [로컬DB명]
#   인자 없음: testdb_remote, testdb (기본값)
#   인자 1개: 원격 DB만 처리
#   인자 2개: 원격·로컬 DB 모두 처리
#
# 설명:
#   CUBRID 서비스 상태를 확인하고, 지정한 DB가 없으면 생성한다.
#   각 DB 서버를 시작한다.
#   DBLink는 브로커(CAS)를 통해 원격 DB에 접속하므로 브로커도 함께 시작한다.

DEFAULT_REMOTE="testdb_remote"
DEFAULT_LOCAL="testdb"

if [ $# -eq 0 ]; then
    DB_LIST=("$DEFAULT_REMOTE" "$DEFAULT_LOCAL")
elif [ $# -eq 1 ]; then
    DB_LIST=("$1")
elif [ $# -eq 2 ]; then
    DB_LIST=("$1" "$2")
else
    echo "오류: 최대 2개의 DB 이름을 지정할 수 있습니다." >&2
    echo "사용법: $0 [원격DB명] [로컬DB명]" >&2
    exit 1
fi

echo "=== CUBRID 서비스 상태 확인 ==="
if ! cubrid service status >/dev/null 2>&1; then
    echo "CUBRID 서비스가 실행 중이 아닙니다. 서비스를 시작합니다..."
    cubrid service start
    sleep 2
else
    echo "CUBRID 서비스가 이미 실행 중입니다."
fi

check_and_create_database() {
    local dbname=$1
    echo "데이터베이스 '$dbname' 확인 중..."
    local output
    output=$(cubrid createdb "$dbname" en_US -F "$CUBRID_DATABASES" 2>&1)
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "데이터베이스 '$dbname' 생성 완료."
    else
        if echo "$output" | grep -qi "already exists\|exists"; then
            echo "데이터베이스 '$dbname'가 이미 존재합니다."
        else
            echo "경고: 데이터베이스 '$dbname' 생성 중 오류 발생" >&2
            echo "$output" >&2
            return 1
        fi
    fi
}

start_database_server() {
    local dbname=$1
    if cubrid server status 2>/dev/null | grep -q "Server $dbname "; then
        echo "데이터베이스 서버 '$dbname'가 이미 실행 중입니다."
        return 0
    fi
    echo "데이터베이스 서버 '$dbname'를 시작합니다..."
    cubrid server start "$dbname"
    sleep 1
    if cubrid server status 2>/dev/null | grep -q "Server $dbname "; then
        echo "데이터베이스 서버 '$dbname' 시작 완료."
    else
        echo "경고: '$dbname' 서버 시작 확인 실패."
    fi
}

for db in "${DB_LIST[@]}"; do
    echo ""
    echo "=== DB ($db) 처리 ==="
    check_and_create_database "$db" || true
    start_database_server "$db"
done

echo ""
echo "=== 브로커 상태 확인 ==="
if cubrid broker status 2>/dev/null | grep -q "is running"; then
    echo "브로커가 이미 실행 중입니다."
else
    echo "브로커가 실행 중이 아닙니다. 시작합니다..."
    cubrid broker start
    sleep 1
    if cubrid broker status 2>/dev/null | grep -q "is running"; then
        echo "브로커 시작 완료."
    else
        echo "경고: 브로커 시작 확인 실패." >&2
    fi
fi

echo ""
echo "=== 최종 상태 확인 ==="
cubrid service status
echo ""
echo "=== 완료 ==="
