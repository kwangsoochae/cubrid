-- TC-123: corr eq(=) + 부등호 outer ref 혼합 → push-down 미적용 확인 (FR-7, T6-9)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 서브쿼리 WHERE에 corr eq(r.id = l.id)와
--           outer ref를 포함한 부등호 조건(r.id > l.id)이 함께 존재.
--   mq_detect_dblink_corr_eq: term2(r.id > l.id)에서
--     corr_eq_count=0, total_outer_cnt=1(l.id) → -1 반환.
--   결과: push-down 미적용, AS-IS(전체 fetch 후 로컬 필터).
-- 기대: r.id = l.id AND r.id > l.id 는 항상 false → 전 행 NULL.
-- 비고: push-down 적용 여부와 무관하게 결과가 동일함을 확인.

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id AND r.id > l.id
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
