-- [원격 DB에서 실행] TC-601, TC-602 worst case 데이터 셋업
-- 실행: csql -u cubrid -p cubrid <remote_db> -i setup_worst_case_remote.sql

-- ============================================================
-- TC-601용: remote_hiselectivity_t
--   1,000행, id 1-10 (id당 100행) → outer 1행당 100행 매칭 (고선택도)
-- ============================================================
DROP TABLE IF EXISTS remote_hiselectivity_t;
CREATE TABLE remote_hiselectivity_t (seq INT PRIMARY KEY, id INT, val VARCHAR(100));

CREATE OR REPLACE PROCEDURE sp_fill_hiselectivity_remote(p_n INT)
AS
  v_i INT;
BEGIN
  v_i := 1;
  WHILE v_i <= p_n LOOP
    INSERT INTO remote_hiselectivity_t(seq, id, val)
      VALUES(v_i, MOD(v_i - 1, 10) + 1, LPAD(TO_CHAR(v_i), 50, '0'));
    v_i := v_i + 1;
    IF MOD(v_i, 500) = 0 THEN COMMIT; END IF;
  END LOOP;
  COMMIT;
END;

CALL sp_fill_hiselectivity_remote(1000);
DROP PROCEDURE sp_fill_hiselectivity_remote;

-- ============================================================
-- TC-602용: remote_smalltable_t
--   5행 (id 1-5) — remote가 매우 작아 전체 fetch는 이미 빠름
-- ============================================================
DROP TABLE IF EXISTS remote_smalltable_t;
CREATE TABLE remote_smalltable_t (id INT PRIMARY KEY, val VARCHAR(100));
INSERT INTO remote_smalltable_t VALUES
  (1,'R_01'),(2,'R_02'),(3,'R_03'),(4,'R_04'),(5,'R_05');

-- 확인
SELECT COUNT(*) FROM remote_hiselectivity_t; -- 기대: 1000
SELECT COUNT(*) FROM remote_smalltable_t;    -- 기대: 5
