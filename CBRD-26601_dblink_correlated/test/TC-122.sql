-- TC-122: local + remote 추가조건 모두 — outer WHERE와 서브쿼리 WHERE 동시 추가필터 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: outer WHERE 절에 local 추가조건(l.id >= 2) +
--           서브쿼리 WHERE 절에 remote 추가조건(r.name LIKE 'remote_b%') 동시 적용.
--   l.id >= 2 → id=1은 outer 단계에서 제외. id=2,3,4,5만 서브쿼리 실행 대상.
--   r.name LIKE 'remote_b%' → id=2만 remote 필터 통과. id=3,4,5는 NULL.
-- 기대:
--   id=2 → 'remote_b1' (2행 수신, 둘 다 LIKE 통과, LIMIT 1 → 최솟값)
--   id=3 → NULL ('remote_c1'은 LIKE 불일치)
--   id=4 → NULL (remote 매칭 없음)
--   id=5 → NULL ('remote_e*'는 LIKE 불일치)
-- 비고:
--   local 추가조건(TC-120)과 remote 추가조건(TC-121)이 동시에 존재하는 조합.
--   push-down 시 outer 4회 execute, 각 회차에서 remote 추가조건도 정확히 처리.
--   local 필터와 remote 필터가 독립적으로 올바르게 동작하는지 확인.

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id AND r.name LIKE 'remote_b%'
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.id >= 2
ORDER BY l.id;
