-- setup_large_local.sql
-- 로컬 DB에서 실행. T6-6 대용량 테스트용 local_t 재구성 (100행).
-- 사용법: csql -S -u dba <로컬DB명> -i setup_large_local.sql
-- 주의: 소량 테스트(setup_local.sql)와 동일 테이블 사용 — 덮어씀.
--       소량 테스트로 복원 시 setup_local.sql 재실행.
-- 구성:
--   id 1~100, 각 1행. remote_large_t와 조인 시 id 1~100만 매칭.
--   remote 100,000행 중 id 1~100 = 10,000행만 매칭 → push-down 효과 확인용.

call login('dba', '') on CLASS db_user;

DROP TABLE IF EXISTS local_t;
CREATE TABLE local_t (
    id   INT,
    name VARCHAR(32)
);

CREATE OR REPLACE PROCEDURE fill_local_t()
AS
  i INTEGER;
BEGIN
  i := 1;
  WHILE i <= 100 LOOP
    INSERT INTO local_t(id, name) VALUES (i, 'local_' || TO_CHAR(i));
    i := i + 1;
  END LOOP;
  COMMIT;
END;
/

CALL fill_local_t();
DROP PROCEDURE fill_local_t;

-- 확인
SELECT COUNT(*) AS cnt FROM local_t;
