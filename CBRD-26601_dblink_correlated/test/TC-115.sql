-- TC-115: SELECT 절 복수 correlated DBLink 서브쿼리 — 각 서브쿼리 독립 실행 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 같은 SELECT 절에 correlated DBLink 서브쿼리 두 개 사용.
--   각 서브쿼리마다 독립적으로 push-down 및 access_pred 제거가 적용되는지 확인.
--   서브쿼리 간 상태 오염(공유 리스트, 바인딩 혼선 등) 없이 각자 올바른 결과를 반환해야 함.
-- 기대:
--   id=1 → first_name='remote_a1', remote_cnt=1
--   id=2 → first_name='remote_b1', remote_cnt=2
--   id=3 → first_name='remote_c1', remote_cnt=1
--   id=4 → first_name=NULL,        remote_cnt=0
--   id=5 → first_name='remote_e1', remote_cnt=3

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS first_name,
  (SELECT COUNT(*) FROM remote_t@cubrid_conn r WHERE r.id = l.id) AS remote_cnt
FROM local_t l
ORDER BY l.id;
