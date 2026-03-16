-- TC-113: LIMIT 없는 correlated 서브쿼리 (1:1 매칭) — access_pred 없이 단일 행 정확 반환 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: LIMIT 없는 correlated 서브쿼리. outer id를 1:1 매칭(id=1, id=3)으로 제한.
--   remote가 정확히 1행만 반환하므로 스칼라 서브쿼리 오류 없이 동작.
--   access_pred 없이도 remote 필터만으로 단일 행을 정확히 반환하는지 확인.
-- 기대: id=1 → 'remote_a1', id=3 → 'remote_c1'.
-- 비고: id=2, id=5처럼 1:N 케이스는 스칼라 서브쿼리에서 에러이므로 제외.

SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id) AS remote_name
FROM local_t a
WHERE a.id IN (1, 3)
ORDER BY a.id;
