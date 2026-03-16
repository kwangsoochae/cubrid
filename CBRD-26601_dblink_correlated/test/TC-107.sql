-- TC-107: WHERE 절 correlated dblink 서브쿼리 (EXISTS) — 2차 확장 영역
-- 전제: test/setup_local.sql, test/setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- 시나리오:
--   WHERE 절에 correlated EXISTS 서브쿼리 안에 dblink 가 있는 형태.
--   현재 1차 최적화 범위(SELECT 절 스칼라) 밖이므로, AS-IS 동작을 회귀 테스트용으로만 확인.
-- 기대:
--   - remote_t 에 매칭이 있는 id = 1,2,3,5 만 반환.
--   - id = 4 (remote 매칭 없음)는 결과에 포함되지 않음.

SELECT a.id, a.name
FROM local_t a
WHERE EXISTS (
  SELECT 1
  FROM remote_t@cubrid_conn r
  WHERE r.id = a.id
)
ORDER BY a.id;

