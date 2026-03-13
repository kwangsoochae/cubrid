-- [원격 DB에서 실행] POC-E (break-even) 데이터 셋업
-- 전송 행 수가 Before와 After 동일한 케이스
-- remote: 1,000행 (id 1~10, id당 100행)
-- outer 10행 × 매칭 100건 = 1,000행 = remote 전체
-- 실행: csql testdb4dblink -i setup_breakeven_remote.sql

DROP TABLE IF EXISTS remote_breakeven_t;
CREATE TABLE remote_breakeven_t (
  seq INT PRIMARY KEY,
  id  INT,
  val VARCHAR(100)
);

CREATE OR REPLACE PROCEDURE sp_fill_breakeven_remote(p_n INT)
AS
  v_i INT;
BEGIN
  v_i := 1;
  WHILE v_i <= p_n LOOP
    INSERT INTO remote_breakeven_t(seq, id, val)
      VALUES(v_i, MOD(v_i - 1, 10) + 1, LPAD(TO_CHAR(v_i), 50, '0'));
    v_i := v_i + 1;
    IF MOD(v_i, 500) = 0 THEN COMMIT; END IF;
  END LOOP;
  COMMIT;
END;

CALL sp_fill_breakeven_remote(1000);
DROP PROCEDURE sp_fill_breakeven_remote;

-- 확인
SELECT COUNT(*) FROM remote_breakeven_t;               -- 기대: 1000
SELECT id, COUNT(*) FROM remote_breakeven_t GROUP BY id ORDER BY id; -- id당 100행
