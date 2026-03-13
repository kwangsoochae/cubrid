-- POC-E: 전송 행 수 동일 — round-trip overhead 케이스
-- 전제: setup_breakeven_remote.sql (원격), setup_breakeven_local.sql (로컬) 실행 완료
--
-- 시나리오: outer 10행 (id 1~10), remote 1,000행 (id 1~10, id당 100행)
--   → outer 1행당 100건 매칭, 총 매칭 1,000건 = remote 전체 행 수
--
-- Before (최적화 전):
--   1 execute → 1,000행 전송 (전체, 1회)
--   outer 10행 × cursor reset → 로컬 predicate 평가
--   round-trip: 1회
--
-- After (최적화 후):
--   10 executes × 100행 fetch = 1,000행 전송 (Before와 동일)
--   round-trip: 10회 (Before의 10배)
--
-- 기대:
--   전송 행 수는 동일하지만 After가 Before보다 느림
--   → execute round-trip overhead만 증가, 데이터 절약 효과 없음
--   → 이 지점이 break-even: 전송 행이 같으면 After가 항상 불리
--
-- 측정:
--   csql> ;time on
--   csql> ;read TC-POC-E.sql
--   csql> ;run
--   → Before/After 실행 시간 비교. 결과 1,000행 (정확성 확인).

SELECT count(*)
FROM local_breakeven_t l, remote_breakeven_t@cubrid_conn r
WHERE l.id = r.id
;
