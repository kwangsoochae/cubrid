-- TC-108: dblink uncorrelated (단독 사용) — 기존 동작 유지 확인
-- 전제: test/setup_remote.sql 로 원격 DB에 remote_t 스키마·데이터 적재 완료.
-- 시나리오:
--   로컬 테이블을 전혀 사용하지 않고, dblink 테이블만 조회하는 단순 SELECT.
--   correlated 최적화(outer-dependent rebind)와 무관해야 하며, AS-IS 동작이 그대로 유지되어야 한다.
-- 기대:
--   - remote_t 의 전체 7행이 id, name 순으로 반환.
--   - 최적화 전/후 XASL에서 dblink 부분 구조에 변화가 없거나, 결과·실행 패턴에 영향이 없어야 한다.

SELECT id, name
FROM remote_t@cubrid_conn
ORDER BY id, name;

