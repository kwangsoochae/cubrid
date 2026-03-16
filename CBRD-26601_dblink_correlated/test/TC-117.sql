-- TC-117: use_dblink_corr_pushdown=no — push-down 미적용, AS-IS 유지 확인 (FR-9, T1-3, T6-7)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 세션 파라미터 use_dblink_corr_pushdown=no 설정 후 correlated 서브쿼리 실행.
--   push-down이 적용되지 않아야 하며 (conn_sql에 WHERE id = ? 없음, 1회 전체 fetch 경로),
--   결과는 TC-101과 완전히 동일해야 함.
-- 기대: 5행, TC-101과 동일 결과. push-down 여부와 무관하게 정확성 유지 확인.
-- 비고:
--   - push-down 적용 여부는 gdb/XASL 덤프로 확인 (conn_sql에 WHERE 유무, corr_key_count=0).
--   - 파라미터 복원 후 재실행 시 push-down이 다시 적용되는지도 확인.

-- 1. push-down OFF 설정
SET SYSTEM PARAMETERS 'use_dblink_corr_pushdown=no';

-- 2. correlated 서브쿼리 실행 (TC-101과 동일 쿼리)
-- 기대: push-down 미적용 (AS-IS: 1회 전체 fetch + 로컬 필터), 결과는 TC-101과 동일.
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a
ORDER BY a.id;

-- 3. push-down 다시 ON (복원)
SET SYSTEM PARAMETERS 'use_dblink_corr_pushdown=yes';

-- 4. 동일 쿼리 재실행 — push-down 재적용 확인 (결과 동일, 실행 경로 복원)
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a
ORDER BY a.id;
