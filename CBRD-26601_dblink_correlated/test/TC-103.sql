-- TC-103: push-down 불가 케이스 — 기존 방식(1회 전체 fetch) 유지 확인 (T6-3, regression)
-- 전제: setup_local.sql, setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- 비고: 앱 ?(PT_HOST_VAR) 혼합 케이스는 csql 스크립트에서 바인딩 불가이므로,
--       동일하게 push-down 불가 조건인 OR 조건으로 대체.
--       OR 조건 포함 시 탐지 실패 → 기존 방식 유지 → 결과는 TC-101과 동일해야 함.
-- 기대: 5행. TC-101과 동일 결과 (push-down 적용 여부와 무관하게 결과 동등성 확인).

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id OR r.id = -1
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
