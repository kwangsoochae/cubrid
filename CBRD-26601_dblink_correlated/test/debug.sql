-- debug.sql: 개발 중 즉석 확인용 쿼리 모음. 커밋 불필요.
-- 사용법:
--   csql -S -u dba <로컬DB명> -i debug.sql
--   csql -S -u dba <로컬DB명> -c "SET SYSTEM PARAMETERS 'xasl_debug_dump=on'; SELECT ..."
--   ./run_tc.sh --xasl TC-101.sql   ← xasl_debug_dump 자동 래핑

-- ============================================================
-- Step 0: 사전 확인 (C-1 ~ C-5)
-- ============================================================

-- [C-2] 래퍼 재실행 시 scan_open_scan(S_DBLINK_SCAN) 호출 여부 확인용
-- gdb: break dblink_open_scan → outer 2번째 행 시 히트 여부
-- 아래 쿼리로 gdb 관찰 (outer 2행 이상 필요)
SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1)
FROM local_t a WHERE a.id IN (1, 2) ORDER BY a.id;

-- ============================================================
-- Step 1: 탐지 확인 (T1-1, T1-2)
-- ============================================================

-- [T1-1] 탐지 성공: conn_sql에 "WHERE r.id = ?" 포함 여부 → xasl_debug_dump 또는 gdb로 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1)
FROM local_t a WHERE a.id = 1;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';

-- [T1-1] 탐지 실패 — OR 조건: push-down 불가, 기존 방식 유지 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id OR r.id = -1 ORDER BY r.name LIMIT 1)
FROM local_t a WHERE a.id = 1;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';

-- [T1-1] 탐지 실패 — correlated 아님: 기존 방식 유지 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = 1 ORDER BY r.name LIMIT 1)
FROM local_t a WHERE a.id = 1;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';

-- ============================================================
-- Step 2: XASL 생성 확인 (T2-1)
-- ============================================================

-- [T2-1] dblink_spec_node.corr_key_count > 0, conn_sql에 WHERE 포함 여부
-- gdb: break pt_to_dblink_table_spec_list → 리턴 후 dblink_node 필드 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a ORDER BY a.id;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';

-- ============================================================
-- Step 3: 런타임 확인 (T3-1, T3-2, T3-3)
-- ============================================================

-- [T3-1] open 시 cci_execute 미호출 확인
-- gdb: break dblink_open_scan → corr_key_count > 0 분기에서 cci_execute 미호출 확인

-- [T3-2] 매 outer 행마다 rebind + execute 확인 (전체 5행)
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a ORDER BY a.id;

-- [T3-2] 2행만으로 rebind 순서 확인 (gdb 관찰 편의용)
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a WHERE a.id IN (1, 2) ORDER BY a.id;

-- [T3-3] NULL 키 — re-execute 스킵, NULL 반환 확인
INSERT INTO local_t VALUES (NULL, 'local_n');
COMMIT;

SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a WHERE a.id IS NULL OR a.id = 1 ORDER BY a.id;

DELETE FROM local_t WHERE id IS NULL AND name = 'local_n';
COMMIT;

-- ============================================================
-- Step 4: access_pred 제거 확인 (T4-1)
-- ============================================================

-- [T4-1] XASL 덤프에서 access pred 항목에 _dbl.id = a.id 없는지 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a ORDER BY a.id;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';

-- [T4-1] push-down 불가 케이스: access_pred 기존 유지 확인
SET SYSTEM PARAMETERS 'xasl_debug_dump=on';
SELECT a.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = a.id OR r.id = -1 ORDER BY r.name LIMIT 1)
FROM local_t a WHERE a.id = 1;
SET SYSTEM PARAMETERS 'xasl_debug_dump=off';
