-- TC-111: COUNT 집계 서브쿼리 — access_pred 없이 집계 결과 정확성 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: SELECT 절 스칼라 서브쿼리로 COUNT(*) 사용.
--   access_pred(r.id = a.id)를 제거한 상태에서 remote가 올바른 행만 수신하고
--   로컬에서 COUNT가 정확하게 집계되는지 확인.
--   (오매칭 행이 있으면 COUNT가 기대보다 커져 버그 감지 가능.)
-- 기대:
--   id=1 → remote_cnt=1
--   id=2 → remote_cnt=2
--   id=3 → remote_cnt=1
--   id=4 → remote_cnt=0 (remote 매칭 없음)
--   id=5 → remote_cnt=3

SELECT a.id, a.name,
  (SELECT COUNT(*) FROM remote_t@cubrid_conn r WHERE r.id = a.id) AS remote_cnt
FROM local_t a
ORDER BY a.id;
