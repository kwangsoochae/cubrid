-- ============================================================================
-- Test Cases for DBLINK + Synonym Fix
-- Issue: Remote SQL should use unqualified class name (e.g., "emp") 
--        instead of schema-qualified name (e.g., "public.emp")
-- ============================================================================

-- Setup: Create test tables and server
-- ============================================================================

-- Test table on remote server (assumed to exist)
-- CREATE TABLE emp (id INT, name VARCHAR(100));

-- Create dblink server
CREATE SERVER cubrid_conn 
    HOST 'localhost' 
    PORT 33000 
    DBNAME 'testdb' 
    USER 'dba' 
    PASSWORD 'password';

-- ============================================================================
-- Test Case 1: Basic DBLINK Synonym - SELECT
-- Expected: Remote SQL should be "SELECT * FROM emp" (not "public.emp")
-- ============================================================================

-- Create synonym for remote table
CREATE SYNONYM synonym_cu FOR emp@cubrid_conn;

-- Test SELECT from synonym (should work without "public.emp" error)
SELECT * FROM synonym_cu;
-- Expected: No error, remote SQL uses "emp" only

-- Verify synonym was created correctly
SELECT target_name FROM db_synonym WHERE synonym_name = 'synonym_cu';
-- Expected: target_name = 'emp@cubrid_conn'

-- Cleanup
DROP SYNONYM synonym_cu;

-- ============================================================================
-- Test Case 2: Synonym with Schema-qualified Target Name
-- Expected: If target is specified with schema (e.g., "public.emp@cubrid_conn"),
--           remote SQL should use the schema-qualified name "public.emp"
--           (NOT stripped to "emp")
-- NOTE: This test case should FAIL with current implementation.
--       Current code always strips schema, but it should preserve schema
--       when user explicitly specifies it.
-- ============================================================================

CREATE SYNONYM synonym_cu2 FOR public.emp@cubrid_conn;

SELECT * FROM synonym_cu2;
-- Expected: Remote SQL should use "public.emp" (schema preserved)
--           If current implementation strips schema, this will fail
--           because remote server may not recognize "emp" without schema
--           or may use wrong schema.

DROP SYNONYM synonym_cu2;

-- ============================================================================
-- Test Case 3: Synonym with Alias
-- Expected: Alias should work correctly, remote SQL still uses unqualified name
-- ============================================================================

CREATE SYNONYM synonym_cu3 FOR emp@cubrid_conn;

SELECT e.id, e.name FROM synonym_cu3 e;
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu3;

-- ============================================================================
-- Test Case 4: SELECT with WHERE clause
-- Expected: Remote SQL should be "SELECT * FROM emp WHERE ..."
-- ============================================================================

CREATE SYNONYM synonym_cu4 FOR emp@cubrid_conn;

SELECT * FROM synonym_cu4 WHERE id = 1;
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu4;

-- ============================================================================
-- Test Case 5: SELECT with JOIN (synonym + local table)
-- Expected: Remote SQL for synonym should use unqualified name
-- ============================================================================

-- Assume local table exists: CREATE TABLE dept (id INT, name VARCHAR(100));

CREATE SYNONYM synonym_cu5 FOR emp@cubrid_conn;

SELECT e.id, e.name, d.name AS dept_name 
FROM synonym_cu5 e 
JOIN dept d ON e.dept_id = d.id;
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu5;

-- ============================================================================
-- Test Case 6: INSERT with Synonym
-- Expected: Remote SQL should use unqualified name
-- ============================================================================

CREATE SYNONYM synonym_cu6 FOR emp@cubrid_conn;

INSERT INTO synonym_cu6 (id, name) VALUES (1, 'test');
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu6;

-- ============================================================================
-- Test Case 7: UPDATE with Synonym
-- Expected: Remote SQL should use unqualified name
-- ============================================================================

CREATE SYNONYM synonym_cu7 FOR emp@cubrid_conn;

UPDATE synonym_cu7 SET name = 'updated' WHERE id = 1;
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu7;

-- ============================================================================
-- Test Case 8: DELETE with Synonym
-- Expected: Remote SQL should use unqualified name
-- ============================================================================

CREATE SYNONYM synonym_cu8 FOR emp@cubrid_conn;

DELETE FROM synonym_cu8 WHERE id = 1;
-- Expected: No error, remote SQL uses "emp" only

DROP SYNONYM synonym_cu8;

-- ============================================================================
-- Test Case 9: Multiple Synonyms for Different Remote Tables
-- Expected: Each synonym should resolve to unqualified name correctly
-- ============================================================================

-- Assume remote tables: emp, dept, project

CREATE SYNONYM syn_emp FOR emp@cubrid_conn;
CREATE SYNONYM syn_dept FOR dept@cubrid_conn;
CREATE SYNONYM syn_project FOR project@cubrid_conn;

SELECT * FROM syn_emp;
SELECT * FROM syn_dept;
SELECT * FROM syn_project;
-- Expected: All should work, each remote SQL uses unqualified name

DROP SYNONYM syn_emp;
DROP SYNONYM syn_dept;
DROP SYNONYM syn_project;

-- ============================================================================
-- Test Case 10: Synonym with Different Schema Names
-- Expected: Schema prefix should be stripped regardless of schema name
-- ============================================================================

-- Test with different schema names (if supported)
-- CREATE SYNONYM syn_test1 FOR dba.emp@cubrid_conn;
-- CREATE SYNONYM syn_test2 FOR user1.emp@cubrid_conn;

-- SELECT * FROM syn_test1;
-- SELECT * FROM syn_test2;
-- Expected: Both should use "emp" only in remote SQL

-- DROP SYNONYM syn_test1;
-- DROP SYNONYM syn_test2;

-- ============================================================================
-- Test Case 11: Error Case - Server Not Found
-- Expected: Should return appropriate error (not "public.emp" error)
-- ============================================================================

CREATE SYNONYM syn_error FOR emp@nonexistent_server;

SELECT * FROM syn_error;
-- Expected: Error about server not found, NOT "Unknown class public.emp"

DROP SYNONYM syn_error;

-- ============================================================================
-- Test Case 12: Error Case - Table Not Found on Remote
-- Expected: Should return error about table not found, not "public.emp" error
-- ============================================================================

CREATE SYNONYM syn_notfound FOR nonexistent_table@cubrid_conn;

SELECT * FROM syn_notfound;
-- Expected: Error about table not found on remote, NOT "Unknown class public.nonexistent_table"

DROP SYNONYM syn_notfound;

-- ============================================================================
-- Test Case 13: Verify db_synonym Catalog
-- Expected: target_name should store correctly as "emp@cubrid_conn"
-- ============================================================================

CREATE SYNONYM syn_catalog FOR emp@cubrid_conn;

SELECT synonym_name, target_name, target_unique_name 
FROM db_synonym 
WHERE synonym_name = 'syn_catalog';
-- Expected: 
--   synonym_name = 'syn_catalog'
--   target_name = 'emp@cubrid_conn' (or unqualified 'emp' for dblink)
--   target_unique_name = 'emp@cubrid_conn'

DROP SYNONYM syn_catalog;

-- ============================================================================
-- Test Case 14: ALTER SYNONYM
-- Expected: After ALTER, remote SQL should still use unqualified name
-- ============================================================================

CREATE SYNONYM syn_alter FOR emp@cubrid_conn;

-- Alter to point to different table
ALTER SYNONYM syn_alter FOR dept@cubrid_conn;

SELECT * FROM syn_alter;
-- Expected: No error, remote SQL uses "dept" only (not "public.dept")

DROP SYNONYM syn_alter;

-- ============================================================================
-- Test Case 15: Synonym with Owner Specification
-- Expected: Owner should not affect remote SQL table name (still unqualified)
-- ============================================================================

-- If owner specification is supported:
-- CREATE SYNONYM dba.syn_owner FOR emp@cubrid_conn;
-- SELECT * FROM dba.syn_owner;
-- Expected: Remote SQL uses "emp" only

-- DROP SYNONYM dba.syn_owner;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP SERVER cubrid_conn;

-- ============================================================================
-- Verification Notes:
-- ============================================================================
-- To verify the fix works correctly, check:
-- 1. No "Unknown class public.emp" errors occur
-- 2. Remote SQL logs show unqualified table names (e.g., "SELECT * FROM emp")
-- 3. db_synonym catalog stores target_name correctly
-- 4. All DML operations (SELECT, INSERT, UPDATE, DELETE) work with synonyms
-- ============================================================================
