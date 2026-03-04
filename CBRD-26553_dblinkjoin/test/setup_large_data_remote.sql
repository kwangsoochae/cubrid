-- [원격 DB에서 실행] TC-501, TC-502, TC-503 대용량 데이터 셋업
-- 실행: csql -u cubrid -p cubrid <remote_db> -i setup_large_data_remote.sql

DROP TABLE IF EXISTS remote_large_t;
CREATE TABLE remote_large_t (
  id  INT PRIMARY KEY,
  val VARCHAR(100)
);

-- PL/CSQL 루프로 10,000행 삽입
CREATE OR REPLACE PROCEDURE sp_fill_remote_large(p_n INT)
AS
  v_i INT;
BEGIN
  v_i := 1;
  WHILE v_i <= p_n LOOP
    INSERT INTO remote_large_t(id, val)
      VALUES(v_i, LPAD(TO_CHAR(v_i), 50, '0'));
    v_i := v_i + 1;
    IF MOD(v_i, 500) = 0 THEN
      COMMIT;
    END IF;
  END LOOP;
  COMMIT;
END;

CALL sp_fill_remote_large(10000);
DROP PROCEDURE sp_fill_remote_large;

-- 확인
SELECT COUNT(*) FROM remote_large_t;
-- 기대: 10000
