-- TC-121: remote 추가조건 only — 조인키 + remote 컬럼 추가필터, local 필터 없음 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 서브쿼리 WHERE 절에 조인키(r.id = l.id)와 remote 컬럼 추가조건(r.name LIKE 'remote_e%') 혼합.
--   outer 전체 5행에 대해 각각 remote execute 실행.
--   remote 추가조건이 push-down conn_sql에 포함되거나, access_pred로 남아 로컬에서 필터링되어야 함.
--   push-down 여부와 무관하게 결과 동일성이 보장되어야 함.
-- 기대:
--   id=1 → NULL ('remote_a1'은 'remote_e%' 불일치)
--   id=2 → NULL ('remote_b1','remote_b2'는 'remote_e%' 불일치)
--   id=3 → NULL ('remote_c1'은 'remote_e%' 불일치)
--   id=4 → NULL (remote 매칭 없음)
--   id=5 → 'remote_e1' (3행 수신, 모두 LIKE 통과, LIMIT 1 → 최솟값)
-- 비고: TC-110(LIKE 'remote_b%'), TC-116(r.id < 3) 과 보완 관계.
--   이 TC는 조인키(r.id=l.id)와 동일 컬럼이 아닌 별개 컬럼(r.name)에 필터가 있는 케이스.

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id AND r.name LIKE 'remote_e%'
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
