-- test_dblink_join_remote.sql
-- 원격 DB에서 실행. dblink 조인 테스트용 스키마 및 데이터.
-- 사용법: csql -S -u cubrid -p cubrid <원격DB명> -i test_dblink_join_remote.sql

-- 스키마: 로컬과 조인할 테이블 (id 기준)
DROP TABLE IF EXISTS remote_t;
CREATE TABLE remote_t (
    id INT,
    name VARCHAR(32)
);

-- 기준 데이터: 0건/1건/N건 매칭이 나오도록 구성
-- id=1: 1건
-- id=2: 2건 (1:N)
-- id=3: 1건
-- id=4: 0건 (로컬에만 있을 수 있음)
-- id=5: 3건 (1:N)
INSERT INTO remote_t VALUES (1, 'remote_a1');
INSERT INTO remote_t VALUES (2, 'remote_b1');
INSERT INTO remote_t VALUES (2, 'remote_b2');
INSERT INTO remote_t VALUES (3, 'remote_c1');
INSERT INTO remote_t VALUES (5, 'remote_e1');
INSERT INTO remote_t VALUES (5, 'remote_e2');
INSERT INTO remote_t VALUES (5, 'remote_e3');

COMMIT;

-- 확인
SELECT id, name FROM remote_t ORDER BY id, name;
