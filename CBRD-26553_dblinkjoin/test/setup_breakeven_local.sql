-- [로컬 DB에서 실행] POC-E (break-even) 데이터 셋업
-- local: 10행 (id 1~10)
-- outer 10행 × 매칭 100건 = 1,000행 = remote_breakeven_t 전체
-- 실행: csql testdb -i setup_breakeven_local.sql

DROP TABLE IF EXISTS local_breakeven_t;
CREATE TABLE local_breakeven_t (
  id   INT PRIMARY KEY,
  name VARCHAR(50)
);
INSERT INTO local_breakeven_t VALUES
  (1,'L_01'),(2,'L_02'),(3,'L_03'),(4,'L_04'),(5,'L_05'),
  (6,'L_06'),(7,'L_07'),(8,'L_08'),(9,'L_09'),(10,'L_10');

-- 확인
SELECT COUNT(*) FROM local_breakeven_t; -- 기대: 10
