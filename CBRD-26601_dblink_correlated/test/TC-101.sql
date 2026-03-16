-- TC-101: 기본 correlated 스칼라 서브쿼리 — 매칭·NULL 혼합 (FR-1~FR-5, FR-8, T6-1, T6-2)
-- 전제: setup_local.sql, setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- 기대: 5행. id=4는 원격 매칭 없음 → NULL 반환. 나머지는 LIMIT 1 ORDER BY r.name 최솟값.
-- push-down 적용 시에도 기존(전체 fetch 후 access_pred 필터)과 동일 결과.

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
