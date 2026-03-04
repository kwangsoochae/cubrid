-- [로컬 DB에서 실행] TC-104, TC-205 셋업
-- 실행: csql -u cubrid -p cubrid <local_db> -i setup_edge_cases_local.sql

-- ============================================================
-- TC-104용: local_null_key_t
--   id가 nullable. NULL key 행이 포함된 경우 execute 스킵 검증.
--   기존 remote_t (remote DB) 재사용.
-- ============================================================
DROP TABLE IF EXISTS local_null_key_t;
CREATE TABLE local_null_key_t (id INT, name VARCHAR(50));
INSERT INTO local_null_key_t VALUES
  (1,    'lnk_1'),     -- remote_t: remote_a1 (1건 매칭)
  (2,    'lnk_2'),     -- remote_t: remote_b1, remote_b2 (2건 매칭)
  (NULL, 'lnk_null');  -- NULL key: execute 스킵 → 결과에 나타나지 않아야 함

-- ============================================================
-- TC-205용: local_compound_t
--   (id, code) 두 컬럼으로 조인. WHERE l.id = r.id AND l.code = r.code.
--   단일 등치만 지원하는 1차 범위에서 올바른 결과를 내는지 검증.
-- ============================================================
DROP TABLE IF EXISTS local_compound_t;
CREATE TABLE local_compound_t (id INT, code CHAR(1), name VARCHAR(50));
INSERT INTO local_compound_t VALUES
  (1, 'A', 'lc_1A'),  -- remote: (1,'A') 존재 → 매칭
  (1, 'B', 'lc_1B'),  -- remote: (1,'B') 없음 → 불일치
  (2, 'A', 'lc_2A'),  -- remote: (2,'A') 없음 → 불일치
  (2, 'B', 'lc_2B');  -- remote: (2,'B') 존재 → 매칭

-- 확인
SELECT COUNT(*) FROM local_null_key_t;  -- 기대: 3
SELECT COUNT(*) FROM local_compound_t;  -- 기대: 4
