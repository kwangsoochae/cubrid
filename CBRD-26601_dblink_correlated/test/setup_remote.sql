-- setup_remote.sql
-- 원격 DB에서 실행. correlated 스칼라 서브쿼리 테스트용 remote_t 생성/데이터.
-- 사용법: csql -S -u cubrid -p cubrid <원격DB명> -i setup_remote.sql

call login('cubrid', 'cubrid') on CLASS db_user;

DROP TABLE IF EXISTS remote_t;
CREATE TABLE remote_t (
    id   INT,
    name VARCHAR(32)
);

-- 기준 데이터: 0건/1건/N건 매칭이 나오도록 구성
-- id=1: 1건 (1:1)
-- id=2: 2건 (1:N, LIMIT 1 ORDER BY → 'remote_b1')
-- id=3: 1건 (1:1)
-- id=4: 0건 → 로컬 outer에서 NULL 반환
-- id=5: 3건 (1:N, LIMIT 1 ORDER BY → 'remote_e1')
INSERT INTO remote_t VALUES (1, 'remote_a1');
INSERT INTO remote_t VALUES (2, 'remote_b1');
INSERT INTO remote_t VALUES (2, 'remote_b2');
INSERT INTO remote_t VALUES (3, 'remote_c1');
INSERT INTO remote_t VALUES (5, 'remote_e1');
INSERT INTO remote_t VALUES (5, 'remote_e2');
INSERT INTO remote_t VALUES (5, 'remote_e3');

COMMIT;

-- TC-119용: id에 UNIQUE 제약 — 스칼라 서브쿼리에 LIMIT 없어도 항상 0~1행 보장
DROP TABLE IF EXISTS remote_unique_t;
CREATE TABLE remote_unique_t (
    id   INT UNIQUE,
    name VARCHAR(32)
);
-- id=4 없음 → local_t의 id=4 조회 시 NULL 반환
INSERT INTO remote_unique_t VALUES (1, 'remote_ua1');
INSERT INTO remote_unique_t VALUES (2, 'remote_ub1');
INSERT INTO remote_unique_t VALUES (3, 'remote_uc1');
INSERT INTO remote_unique_t VALUES (5, 'remote_ue1');

COMMIT;

-- 확인
SELECT id, name FROM remote_t ORDER BY id, name;
SELECT id, name FROM remote_unique_t ORDER BY id;
