-- test_dblink_join_local.sql
-- 로컬 DB에서 실행. dblink 조인 테스트용 스키마, 데이터 및 질의문.
-- 사용법: csql -S -u cubrid -p cubrid <로컬DB명> -i test_dblink_join_local.sql
-- 전제: 원격 DB는 test_dblink_join_remote.sql 로 생성해 두고, cubrid_conn 등 dblink 연결 설정됨.

-- 스키마: 원격 remote_t 와 조인할 로컬 테이블
DROP TABLE IF EXISTS local_t;
CREATE TABLE local_t (
    id INT,
    name VARCHAR(32)
);

-- 기준 데이터 (소량): 0:1, 1:1, 1:N 케이스 포함
-- id=1: 원격 1건 (1:1)
-- id=2: 원격 2건 (1:N)
-- id=3: 원격 1건 (1:1)
-- id=4: 원격 0건 (0:1)
-- id=5: 원격 3건 (1:N)
INSERT INTO local_t VALUES (1, 'local_1');
INSERT INTO local_t VALUES (2, 'local_2');
INSERT INTO local_t VALUES (3, 'local_3');
INSERT INTO local_t VALUES (4, 'local_4');
INSERT INTO local_t VALUES (5, 'local_5');

COMMIT;

drop server if exists cubrid_conn;
create server cubrid_conn (HOST='localhost',PORT=33000,DBNAME='testdb4dblink',USER='cubrid',PASSWORD='cubrid');


-- ========== 테스트 질의문 ==========
-- 아래에서 @cubrid_conn 을 실제 dblink 연결 이름으로 바꿔서 실행.

-- 1) 푸시 가능 조인 (WHERE): 조인 조건 만족 행만 원격에서 가져오는지 검증
-- SELECT l.id, l.name, r.name FROM local_t l, remote_t@cubrid_conn r WHERE l.id = r.id ORDER BY l.id, r.name;

-- 2) 0건 매칭 포함 (id=4는 원격에 없음) → 결과에 id=4는 안 나옴 (inner join)
-- SELECT l.id, l.name, r.name FROM local_t l, remote_t@cubrid_conn r WHERE l.id = r.id ORDER BY l.id, r.name;

-- 3) 1:N 매칭 (id=2, id=5는 원격에 여러 건) → 행 수: id=1(1), id=2(2), id=3(1), id=5(3) = 7행
-- SELECT l.id, l.name, r.name FROM local_t l, remote_t@cubrid_conn r WHERE l.id = r.id ORDER BY l.id, r.name;

-- 4) LEFT JOIN (ON 조건): 현재 푸시 미적용, 기존 동작 검증
-- SELECT l.id, l.name, r.name FROM local_t l LEFT JOIN remote_t@cubrid_conn r ON l.id = r.id ORDER BY l.id, r.name;

-- 5) 로컬만 조인 결과 (기준 비교용): 원격 테이블을 로컬에 복사해 둔 경우 동일 결과인지 비교
-- SELECT l.id, l.name, r.name FROM local_t l, remote_t r WHERE l.id = r.id ORDER BY l.id, r.name;

-- 실행용 (cubrid_conn 사용 시 주석 해제 후 사용)
SELECT l.id, l.name, r.name FROM local_t l, remote_t@cubrid_conn r WHERE l.id = r.id ORDER BY l.id, r.name;
