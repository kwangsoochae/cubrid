-- [로컬 DB에서 실행] TC-501, TC-502, TC-503 대용량 데이터 셋업
-- 실행: csql -u cubrid -p cubrid <local_db> -i setup_large_data_local.sql

-- TC-501용: id 1-10 (remote_large_t id 1-10,000 중 10건만 매칭, 선택도 0.1%)
DROP TABLE IF EXISTS local_small_t;
CREATE TABLE local_small_t (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO local_small_t VALUES
  (1,'L_01'),(2,'L_02'),(3,'L_03'),(4,'L_04'),(5,'L_05'),
  (6,'L_06'),(7,'L_07'),(8,'L_08'),(9,'L_09'),(10,'L_10');

-- TC-502용: id 10001-10010 (remote_large_t에 없음 → 매칭 0건)
DROP TABLE IF EXISTS local_nomatch_t;
CREATE TABLE local_nomatch_t (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO local_nomatch_t VALUES
  (10001,'N_01'),(10002,'N_02'),(10003,'N_03'),(10004,'N_04'),(10005,'N_05'),
  (10006,'N_06'),(10007,'N_07'),(10008,'N_08'),(10009,'N_09'),(10010,'N_10');

-- 확인
SELECT COUNT(*) FROM local_small_t;   -- 기대: 10
SELECT COUNT(*) FROM local_nomatch_t; -- 기대: 10
