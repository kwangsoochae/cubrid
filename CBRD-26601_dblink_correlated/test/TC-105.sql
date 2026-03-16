-- TC-105: 대용량 remote/local 조합 — 전송 행 수·성능 확인 (T6-6)
-- 전제:
--   1) 원격 DB에 setup_large_remote.sql 실행 (remote_t 100,000행)
--   2) 로컬 DB에 setup_large_local.sql 실행 (local_t 100행)
--   3) cubrid_conn 서버 생성 완료 (setup_local.sql 또는 별도 스크립트 참고)
-- 기대:
--   - 결과 행 수: 100행 (id 1~100)
--   - AS-IS: remote_t 전체 100,000행 전송 + 리스트 스캔
--   - TO-BE: id당 100행 × 100회 execute = 10,000행 전송 (1/10 수준)
--   - ./run_tc.sh --no-compare TC-105 로 실행 시간/전송량을 관찰용으로 사용 (expected 비교 없음)

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;

