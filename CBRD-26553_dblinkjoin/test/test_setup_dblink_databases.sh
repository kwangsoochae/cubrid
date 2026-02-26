#!/bin/bash
# dblink 테스트용 데이터베이스 서버 확인 및 자동 설정 스크립트
# - CUBRID 서비스 상태 확인 및 시작
# - 지정된 데이터베이스 존재 여부 확인 및 생성
# - 각 데이터베이스 서버 상태 확인 및 시작
# 사용법: ./test_setup_dblink_databases.sh [DB명1] [DB명2]
#   인자 없음: testdb4dblink, testdb (기본값)
#   인자 1개: 지정된 DB만 처리
#   인자 2개: 두 DB 모두 처리

# set -e는 주석 처리 (createdb 실패 시에도 계속 진행하기 위해)
# set -e

# 기본값 설정
DEFAULT_DB1="testdb4dblink"
DEFAULT_DB2="testdb"

# 인자 처리
if [ $# -eq 0 ]; then
    DB_LIST=("$DEFAULT_DB1" "$DEFAULT_DB2")
elif [ $# -eq 1 ]; then
    DB_LIST=("$1")
elif [ $# -eq 2 ]; then
    DB_LIST=("$1" "$2")
else
    echo "오류: 최대 2개의 DB 이름을 지정할 수 있습니다." >&2
    echo "사용법: $0 [DB명1] [DB명2]" >&2
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

# 데이터베이스 존재 여부 확인 및 생성 함수
# cubrid createdb를 실제로 실행해서 확인 (이미 존재하면 에러, 없으면 생성)
check_and_create_database() {
    local dbname=$1
    local locale="${2:-en_US}"
    
    echo "데이터베이스 '$dbname' 확인 중..."
    
    # cubrid createdb 실행 결과를 캡처
    local output
    output=$(cubrid createdb "$dbname" "$locale" -F "$CUBRID_DATABASES" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # 성공: DB 생성됨
        echo "데이터베이스 '$dbname' 생성 완료."
        return 0
    else
        # 실패: 에러 메시지 확인
        if echo "$output" | grep -qi "already exists\|exists"; then
            echo "데이터베이스 '$dbname'가 이미 존재합니다."
            return 0
        else
            echo "경고: 데이터베이스 '$dbname' 생성 중 오류 발생" >&2
            echo "$output" >&2
            return 1
        fi
    fi
}

# 데이터베이스 서버 시작 함수
start_database_server() {
    local dbname=$1
    echo "데이터베이스 서버 '$dbname'를 시작합니다..."
    cubrid server start "$dbname"
    sleep 1
    if cubrid server status "$dbname" >/dev/null 2>&1; then
        echo "데이터베이스 서버 '$dbname' 시작 완료."
    else
        echo "경고: 데이터베이스 서버 '$dbname' 시작 확인 실패. 잠시 후 다시 확인하세요."
    fi
}

# 데이터베이스 처리 함수 (존재 확인, 생성, 서버 시작)
process_database() {
    cubrid service start
    sleep 2 
    local dbname=$1
    echo ""
    echo "=== DB ($dbname) 확인 ==="
    
    # DB 존재 확인 및 생성 (없으면 생성, 있으면 스킵)
    check_and_create_database "$dbname" "en_US" || true

    start_database_server "$dbname"
}

# 각 DB 처리
for db in "${DB_LIST[@]}"; do
    process_database "$db"
done

echo ""
echo "=== 최종 상태 확인 ==="
cubrid service status
echo ""
echo "=== 완료 ==="
