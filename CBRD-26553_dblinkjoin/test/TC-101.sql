-- TC-101: 단일 등치 조인 결과 일치 (FR-7, T5-1)
-- 전제: test_dblink_join_remote.sql, test_dblink_join_local.sql 로 스키마·데이터 적재 완료. 서버 cubrid_conn 생성됨.
-- 기대: 결과 7행 (id=1:1, id=2:2, id=3:1, id=5:3). 푸시 적용 시에도 기존(전체 fetch 후 로컬 조인)과 동일한 행 수·값.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
