-- TC-118: LIMIT/집계 없는 스칼라 서브쿼리 — 원격 결과셋 다중 행 → 오류 확인
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: 스칼라 서브쿼리에 LIMIT도 집계 함수도 없는 상태에서,
--   correlated 조건이 없거나 비선택적이어서 원격에서 여러 행이 반환되는 경우.
-- 기대: 런타임 오류 — 스칼라 서브쿼리가 2개 이상 행을 반환하면 에러.
-- 비고:
--   - AS-IS: 원격 전체 fetch 후 로컬 리스트에 여러 행 → 스칼라 반환 시 에러.
--   - TO-BE: push-down 적용 시에도 WHERE 없이 여러 행 반환 → 동일 에러.
--   - LIMIT 1 또는 집계 함수 없이 스칼라 서브쿼리를 쓰는 것이 위험함을 확인.

-- 1. correlated 조건 없음 — remote_t 전체 반환 (remote_t 행 수 > 1이면 에러)
-- 기대: ERROR (more than 1 row returned by a subquery used as an expression)
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r) AS remote_name
FROM local_t a
WHERE a.id = 1;

-- 2. 비선택적 correlated 조건 — 범위 조건으로 여러 행 반환
-- 기대: ERROR (id=3 이상인 remote 행이 여러 개)
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id >= a.id) AS remote_name
FROM local_t a
WHERE a.id = 1;
