-- TC-120: local 추가조건 only — outer WHERE에 조인키 외 local 컬럼 조건 포함 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: outer WHERE 절에 조인키(l.id) 이외의 local 컬럼 조건(l.name IN ...)을 추가.
--   l.name IN ('local_1','local_3','local_5') → id=1,3,5만 처리, id=2,4는 outer 단계에서 제외.
--   서브쿼리는 조인키(r.id = l.id)만 사용 — remote 추가조건 없음.
--   push-down 적용 시 id=1,3,5에 대해서만 remote execute 3회 실행.
--   push-down 여부와 무관하게 결과 동일성이 보장되어야 함.
-- 기대:
--   id=1 → 'remote_a1'
--   id=3 → 'remote_c1'
--   id=5 → 'remote_e1'
-- 비고: local 필터가 push-down 실행 횟수를 자연스럽게 줄이는 케이스 (outer 행 감소).

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.name IN ('local_1', 'local_3', 'local_5')
ORDER BY l.id;
