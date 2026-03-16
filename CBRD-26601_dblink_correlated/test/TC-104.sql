-- TC-104: correlated 아닌 DBLink 단독 사용 — 기존 방식 유지 확인 (T6-4, regression)
-- 전제: setup_local.sql, setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- 서브쿼리 WHERE 절이 상수 조건 (r.id = 1) — outer 참조 없음 → correlated 아님 → push-down 불가.
-- 기존 방식(1회 전체 fetch 후 로컬 필터) 유지 확인. 에러 없음.
-- 기대: 5행. 모든 로컬 행에서 r.id=1 매칭 결과 'remote_a1' 반환.

SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = 1
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a
ORDER BY a.id;
