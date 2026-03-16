-- setup_large_remote.sql
-- 원격 DB에서 실행. T6-6 대용량 테스트용 remote_t 재구성 (100,000행).
-- 사용법: csql -S -u cubrid -p cubrid <원격DB명> -i setup_large_remote.sql
-- 주의: 소량 테스트(setup_remote.sql)와 동일 테이블 사용 — 덮어씀.
--       소량 테스트로 복원 시 setup_remote.sql 재실행.
-- 구성:
--   id 1~1000, 각 100행 → 총 100,000행.
--   local_t(id 1~100)와 조인 시:
--     AS-IS: 100,000행 전체 전송
--     TO-BE: id당 100행 × 100회 execute = 10,000행 전송 (1/10 절감)

call login('cubrid', 'cubrid') on CLASS db_user;

DROP TABLE IF EXISTS remote_t;
CREATE TABLE remote_t (
    id   INT,
    name VARCHAR(32)
);

CREATE OR REPLACE PROCEDURE fill_remote_t()
AS
  i INTEGER;
  j INTEGER;
BEGIN
  i := 1;
  WHILE i <= 1000 LOOP
    j := 1;
    WHILE j <= 100 LOOP
      INSERT INTO remote_t(id, name) VALUES (i, 'r' || TO_CHAR(i) || '_' || TO_CHAR(j));
      j := j + 1;
    END LOOP;
    IF MOD(i, 100) = 0 THEN
      COMMIT;
    END IF;
    i := i + 1;
  END LOOP;
  COMMIT;
END;
/

CALL fill_remote_t();
DROP PROCEDURE fill_remote_t;

-- 확인
SELECT COUNT(*) AS total_cnt FROM remote_t;
SELECT id, COUNT(*) AS cnt FROM remote_t GROUP BY id ORDER BY id LIMIT 5;
