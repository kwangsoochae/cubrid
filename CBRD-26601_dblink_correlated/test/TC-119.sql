-- TC-119: LIMIT/집계 없는 스칼라 서브쿼리 — 원격 결과셋 정확히 1행 → 성공 확인
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 스칼라 서브쿼리에 LIMIT도 집계 함수도 없지만,
--   correlated 조건이 remote_t.id (PK/unique)와의 등치이므로 항상 최대 1행 반환.
-- 기대: 5행, TC-101과 동일 결과 (id=4 → NULL, 나머지 → 해당 remote name).
-- 비고:
--   - remote_t.id 가 unique key이면 WHERE r.id = a.id 는 0 또는 1행만 반환 → 스칼라 에러 없음.
--   - LIMIT 없이도 원격 키가 unique하면 정상 동작함을 확인.
--   - push-down 적용 시 conn_sql = 'SELECT name, id FROM remote_t WHERE id = ?' → 1행 반환.
--   - LIMIT append 최적화 미적용 상태에서도 데이터 보장으로 성공하는 경계 케이스.

SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id) AS remote_name
FROM local_t a
ORDER BY a.id;
