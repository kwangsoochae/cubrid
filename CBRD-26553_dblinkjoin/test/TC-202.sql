-- TC-202: 단일 dblink(조인 없음) 기존 동작 (FR-6, NFR-1, T5-2)
-- 기대: 원격 테이블 전체 7행. 1회 execute 후 fetch. regression 없음.

SELECT id, name
FROM remote_t@cubrid_conn
ORDER BY id, name;
