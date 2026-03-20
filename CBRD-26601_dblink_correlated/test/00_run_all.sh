#!/bin/bash
# run_all.sh: DB 준비 → 스키마 셋업 → 전체 TC 실행
#
# 사용법:
#   ./run_all.sh               # 기본 (DB 생성·스키마·TC 전체)
#   ./run_all.sh --skip-setup  # DB/스키마 셋업 생략, TC만 재실행
#   ./run_all.sh --large       # 대용량 데이터로 셋업
#
# 환경변수:
#   CUBRID_DBLINK_REMOTE_DB   원격 DB 이름 (기본: testdb_remote)
#   CUBRID_DBLINK_LOCAL_DB    로컬  DB 이름 (기본: testdb)
#   CSQL_OPTS                 csql 인증 옵션 (기본: -u cubrid -p cubrid)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_DB="${CUBRID_DBLINK_REMOTE_DB:-testdb_remote}"
LOCAL_DB="${CUBRID_DBLINK_LOCAL_DB:-testdb}"
CSQL_USER="${CSQL_USER:-cubrid}"
CSQL_PASS="${CSQL_PASS:-cubrid}"

SKIP_SETUP=0
LARGE_MODE=""

for a in "$@"; do
  case "$a" in
    --skip-setup) SKIP_SETUP=1 ;;
    --large)      LARGE_MODE="--large" ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션: $a" >&2
      echo "사용법: $0 [--skip-setup] [--large]" >&2
      exit 1
      ;;
  esac
done

step() { echo ""; echo "================================================================"; echo " $*"; echo "================================================================"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── 1단계: DB 생성 및 서버 시작 ──────────────────────────────────────────────
if [ $SKIP_SETUP -eq 0 ]; then
  step "1/3  DB 준비 (setup_databases.sh)"
  bash "$SCRIPT_DIR/setup_databases.sh" "$REMOTE_DB" "$LOCAL_DB" \
    || die "setup_databases.sh 실패"

  # ── 2단계: 스키마 및 데이터 셋업 ───────────────────────────────────────────
  step "2/3  스키마 셋업 (setup_schema.sh)"
  bash "$SCRIPT_DIR/setup_schema.sh" \
    -r "$REMOTE_DB" -l "$LOCAL_DB" \
    -u "$CSQL_USER" -p "$CSQL_PASS" \
    $LARGE_MODE \
    || die "setup_schema.sh 실패"
else
  echo "(--skip-setup: DB/스키마 셋업 생략)"
fi

# ── 3단계: TC 전체 실행 ────────────────────────────────────────────────────────
step "3/3  TC 실행 (run_tc.sh all)"
CUBRID_DBLINK_LOCAL_DB="$LOCAL_DB" \
CSQL_OPTS="-u $CSQL_USER -p $CSQL_PASS" \
  bash "$SCRIPT_DIR/run_tc.sh" all
TC_RC=$?

echo ""
if [ $TC_RC -eq 0 ]; then
  echo "================================================================"
  echo " 전체 완료: 모든 TC PASS"
  echo "================================================================"
else
  echo "================================================================"
  echo " 전체 완료: 일부 TC FAIL (exit code $TC_RC)"
  echo "================================================================"
  exit $TC_RC
fi
