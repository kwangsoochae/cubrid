-- [로컬 DB에서 실행] POC 대용량 데이터 셋업 (remote 100,000행 기준)
-- setup_large_data_local.sql 의 100,000행 버전 대응
-- 실행: csql -u cubrid -p cubrid <local_db> -i setup_large_data_local_100k.sql

-- TC-501용: id 1-10 (remote_large_t id 1-100,000 중 10건만 매칭, 선택도 0.01%)
DROP TABLE IF EXISTS local_small_t;
CREATE TABLE local_small_t (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO local_small_t VALUES
  (1,'L_01'),(2,'L_02'),(3,'L_03'),(4,'L_04'),(5,'L_05'),
  (6,'L_06'),(7,'L_07'),(8,'L_08'),(9,'L_09'),(10,'L_10');

-- TC-502용: id 100001-100010 (remote_large_t에 없음 → 매칭 0건)
DROP TABLE IF EXISTS local_nomatch_t;
CREATE TABLE local_nomatch_t (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO local_nomatch_t VALUES
  (100001,'N_01'),(100002,'N_02'),(100003,'N_03'),(100004,'N_04'),(100005,'N_05'),
  (100006,'N_06'),(100007,'N_07'),(100008,'N_08'),(100009,'N_09'),(100010,'N_10');

-- 확인
SELECT COUNT(*) FROM local_small_t;   -- 기대: 10
SELECT COUNT(*) FROM local_nomatch_t; -- 기대: 10
