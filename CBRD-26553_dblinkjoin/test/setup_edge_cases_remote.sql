-- [원격 DB에서 실행] TC-205 셋업
-- 실행: csql -u cubrid -p cubrid <remote_db> -i setup_edge_cases_remote.sql
-- (TC-104는 기존 remote_t 재사용, 추가 셋업 불필요)

-- ============================================================
-- TC-205용: remote_compound_t
--   (id, code) 두 컬럼으로 조인.
--   id만으로 조인하면 불필요한 행이 포함되므로 code 조건이 실제 필터 역할을 함.
--   단일 키 push만 적용될 경우 code 조건이 로컬에서 평가되어 결과는 동일해야 함.
-- ============================================================
DROP TABLE IF EXISTS remote_compound_t;
CREATE TABLE remote_compound_t (id INT, code CHAR(1), val VARCHAR(50));
INSERT INTO remote_compound_t VALUES
  (1, 'A', 'rc_1A'),  -- local (1,'A')와 매칭
  (1, 'C', 'rc_1C'),  -- local에 (1,'C') 없음 → 최종 결과에서 제외
  (2, 'B', 'rc_2B'),  -- local (2,'B')와 매칭
  (2, 'D', 'rc_2D');  -- local에 (2,'D') 없음 → 최종 결과에서 제외

-- 확인
SELECT COUNT(*) FROM remote_compound_t; -- 기대: 4
