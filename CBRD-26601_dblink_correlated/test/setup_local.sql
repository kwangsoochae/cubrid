-- setup_local.sql
-- 로컬 DB에서 실행. correlated 스칼라 서브쿼리 테스트용 local_t 생성/데이터.
-- 사용법: csql -S -u dba <로컬DB명> -i setup_local.sql
-- 전제: cubrid_conn 서버 오브젝트는 이 파일 마지막에서 생성 (원격 DB 선행 구동 필요).

call login('dba', '') on CLASS db_user;

DROP TABLE IF EXISTS local_t;
CREATE TABLE local_t (
    id   INT,
    name VARCHAR(32)
);

-- 기준 데이터 (소량): 0:1, 1:1 케이스 포함
-- id=1: 원격 1건 (1:1)
-- id=2: 원격 2건 (LIMIT 1 테스트용)
-- id=3: 원격 1건 (1:1)
-- id=4: 원격 0건 → 서브쿼리 NULL 반환 (T6-2)
-- id=5: 원격 3건 (LIMIT 1 테스트용)
INSERT INTO local_t VALUES (1, 'local_1');
INSERT INTO local_t VALUES (2, 'local_2');
INSERT INTO local_t VALUES (3, 'local_3');
INSERT INTO local_t VALUES (4, 'local_4');
INSERT INTO local_t VALUES (5, 'local_5');

COMMIT;

drop server if exists cubrid_conn;
create server cubrid_conn (HOST='localhost', PORT=33000, DBNAME='testdb4dblink_remote', USER='dba', PASSWORD='');
