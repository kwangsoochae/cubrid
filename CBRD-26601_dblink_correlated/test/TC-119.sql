-- TC-119: LIMIT/집계 없는 스칼라 서브쿼리 — 원격 결과셋 정확히 1행 → 성공 확인
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 스칼라 서브쿼리에 LIMIT도 집계 함수도 없지만,
--   remote_unique_t.id 가 UNIQUE 제약이므로 WHERE r.id = l.id 는 항상 0~1행 반환.
-- 기대: 5행 (id=4 → NULL, 나머지 → 해당 remote name).
-- 비고:
--   - remote_unique_t.id 가 UNIQUE이면 스칼라 서브쿼리에 LIMIT 불필요.
--   - LIMIT 없이도 원격 키가 unique하면 정상 동작함을 확인.
--   - push-down 적용 시 conn_sql = 'SELECT name, id FROM remote_unique_t WHERE id = ?' → 1행 반환.
--   - LIMIT append 최적화 미적용 상태에서도 데이터 보장으로 성공하는 경계 케이스.

SELECT l.id, l.name,
  (SELECT r.name FROM remote_unique_t@cubrid_conn r WHERE r.id = l.id) AS remote_name
FROM local_t l
ORDER BY l.id;
