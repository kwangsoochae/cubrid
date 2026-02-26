-- TC-201: 푸시 불가 쿼리 기존 동작 (FR-6, NFR-1, T5-2)
-- 조건이 "원격 컬럼 = 로컬 컬럼" 단일 등치가 아닌 형태(예: 한쪽에 식 사용)로 푸시되지 않는 쿼리.
-- 기대: 기존과 동일하게 7행. regression 없음.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE (l.id = r.id) AND (LENGTH(r.name) > 0)
ORDER BY l.id, r.name;
