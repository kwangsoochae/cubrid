-- [로컬 DB에서 실행] TC-601, TC-602 worst case 데이터 셋업
-- 실행: csql -u cubrid -p cubrid <local_db> -i setup_worst_case_local.sql

-- ============================================================
-- TC-601용: local_hiselectivity_t
--   100행, id 1-10 (id당 10행) → outer 100행이 각각 100개 remote와 매칭
--   After: 100 executes × 100행 fetch = 10,000 fetch
--   Before: 1 execute × 1,000행 fetch
-- ============================================================
DROP TABLE IF EXISTS local_hiselectivity_t;
CREATE TABLE local_hiselectivity_t (seq INT PRIMARY KEY, id INT, name VARCHAR(50));

CREATE OR REPLACE PROCEDURE sp_fill_hiselectivity_local(p_n INT)
AS
  v_i INT;
BEGIN
  v_i := 1;
  WHILE v_i <= p_n LOOP
    INSERT INTO local_hiselectivity_t(seq, id, name)
      VALUES(v_i, MOD(v_i - 1, 10) + 1, LPAD(TO_CHAR(v_i), 10, '0'));
    v_i := v_i + 1;
  END LOOP;
  COMMIT;
END;

CALL sp_fill_hiselectivity_local(100);
DROP PROCEDURE sp_fill_hiselectivity_local;

-- ============================================================
-- TC-602용: local_manyouter_t
--   1,000행, id 1-1,000 → id 1-5만 remote와 매칭, 나머지 995행은 0건
--   After: 1,000 executes (outer행마다 1회) — remote가 작아도 execute가 1,000배
--   Before: 1 execute
-- ============================================================
DROP TABLE IF EXISTS local_manyouter_t;
CREATE TABLE local_manyouter_t (id INT PRIMARY KEY, name VARCHAR(50));

CREATE OR REPLACE PROCEDURE sp_fill_manyouter(p_n INT)
AS
  v_i INT;
BEGIN
  v_i := 1;
  WHILE v_i <= p_n LOOP
    INSERT INTO local_manyouter_t(id, name)
      VALUES(v_i, LPAD(TO_CHAR(v_i), 10, '0'));
    v_i := v_i + 1;
    IF MOD(v_i, 500) = 0 THEN COMMIT; END IF;
  END LOOP;
  COMMIT;
END;

CALL sp_fill_manyouter(1000);
DROP PROCEDURE sp_fill_manyouter;

-- 확인
SELECT COUNT(*) FROM local_hiselectivity_t; -- 기대: 100
SELECT COUNT(*) FROM local_manyouter_t;     -- 기대: 1000
