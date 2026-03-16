-- TC-106: FROM 절 correlated dblink 서브쿼리 (2차 영역, 회귀/참고용)
-- 전제: test/setup_local.sql, test/setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- 시나리오:
--   FROM 절에 correlated derived 서브쿼리 안에 dblink 가 들어간 형태.
--   SELECT 절 스칼라 서브쿼리와 논리적으로 동등하지만, FROM 에 위치한다.
-- 기대:
--   - id=1,2,3,5 행에 대해 remote 쪽 매칭이 존재.
--   - id=4는 매칭 없음 → 해당 outer 행은 결과에 등장하지 않음.
--   - push-down 최적화 1차(SELECT 절 전용)에서는 이 쿼리는 AS-IS 동작 유지.

SELECT a.id, a.name, x.remote_name
FROM local_t a,
     (SELECT r.id, r.name AS remote_name
      FROM remote_t@cubrid_conn r
      WHERE r.id = a.id
      ORDER BY r.name
      LIMIT 1) AS x
ORDER BY a.id, x.remote_name;

