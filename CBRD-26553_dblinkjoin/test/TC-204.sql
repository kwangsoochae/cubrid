-- TC-204: LEFT JOIN(ON 조건) 푸시 미적용·기존 동작 (FR-6, T5-2)
-- ON 조건만 있고 WHERE에 동일 등치가 없음. 현재 ON 푸시 미지원.
-- 기대: 8행 (id=1:1, id=2:2, id=3:1, id=4:1 with r NULL, id=5:3). 기존 동작 유지.

SELECT l.id, l.name, r.name
FROM local_t l
LEFT JOIN remote_t@cubrid_conn r ON l.id = r.id
ORDER BY l.id, r.name;
