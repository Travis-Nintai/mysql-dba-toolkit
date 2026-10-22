-- ============================================================================
-- db_health_check.sql -- MySQL instance health check
--
-- Purpose:
--   One-pass instance overview for MySQL 8: version and uptime, connection
--   utilization against max_connections, database sizes, largest tables,
--   InnoDB buffer pool hit indicators, aborted connection counts, and
--   long-running queries from performance_schema.
--
-- Usage:
--   mysql -u root -p < db_health_check.sql
--   mysql -h db.example.local -u dba -p < db_health_check.sql
--
-- Thresholds as session variables: override with SET before sourcing, or
-- edit the defaults here.
--   @warn_conn_pct   flag when Threads_connected exceeds this percent of
--                    max_connections (default 80)
--   @long_query_sec  processlist entries running longer than this many
--                    seconds are listed (default 60)
--
-- Tested on MySQL 8.0 (Ubuntu 24.04 package) against a local instance:
-- executed successfully; on a fresh instance the activity sections return
-- headers with no rows, which is the correct result.
--
-- Requires:
--   performance_schema enabled (default on MySQL 8) for the processlist
--   section; SELECT on information_schema and performance_schema.
--   A monitoring account is fine; root is not required.
--
-- Safety:
--   Read-only. SELECT and SHOW only.
-- ============================================================================

SET @warn_conn_pct  = IFNULL(@warn_conn_pct, 80);
SET @long_query_sec = IFNULL(@long_query_sec, 60);

SELECT '===============================================================' AS '';
SELECT ' MySQL health check' AS '';
SELECT CONCAT(' Version       : ', @@version) AS '';
SELECT CONCAT(' Hostname      : ', @@hostname) AS '';
SELECT CONCAT(' Port          : ', @@port) AS '';
SELECT CONCAT(' Uptime (hrs)  : ',
              ROUND((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                      WHERE VARIABLE_NAME = 'Uptime') / 3600, 1)) AS '';
SELECT CONCAT(' Started approx: ',
              DATE_SUB(NOW(), INTERVAL (SELECT VARIABLE_VALUE
                      FROM performance_schema.global_status
                      WHERE VARIABLE_NAME = 'Uptime') SECOND)) AS '';
SELECT '===============================================================' AS '';

-- ---------------------------------------------------------------------------
-- Connections: current vs ceiling, plus lifetime aborted attempts
-- ---------------------------------------------------------------------------
SELECT '--- Connections ---' AS '';

SELECT @@max_connections AS max_connections,
       (SELECT VARIABLE_VALUE FROM performance_schema.global_status
         WHERE VARIABLE_NAME = 'Threads_connected') AS threads_connected,
       ROUND(100.0 * (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                       WHERE VARIABLE_NAME = 'Threads_connected')
             / @@max_connections, 1) AS pct_used,
       CASE WHEN 100.0 * (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                           WHERE VARIABLE_NAME = 'Threads_connected')
                 / @@max_connections >= @warn_conn_pct
            THEN 'WARNING: over threshold' ELSE 'ok' END AS status;

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Aborted_connects', 'Aborted_clients',
                        'Max_used_connections', 'Connections');

-- ---------------------------------------------------------------------------
-- Storage: database sizes and largest tables
-- ---------------------------------------------------------------------------
SELECT '--- Database sizes (MB), largest first ---' AS '';

SELECT table_schema AS database_name,
       ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS total_mb,
       ROUND(SUM(data_length) / 1024 / 1024, 1) AS data_mb,
       ROUND(SUM(index_length) / 1024 / 1024, 1) AS index_mb,
       COUNT(*) AS tables_count
FROM information_schema.tables
WHERE table_schema NOT IN ('performance_schema', 'information_schema')
GROUP BY table_schema
ORDER BY total_mb DESC;

SELECT '--- Largest tables (top 15) ---' AS '';

SELECT table_schema, table_name, engine, table_rows,
       ROUND((data_length + index_length) / 1024 / 1024, 1) AS total_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('performance_schema', 'information_schema', 'mysql', 'sys')
ORDER BY (data_length + index_length) DESC
LIMIT 15;

-- ---------------------------------------------------------------------------
-- InnoDB: buffer pool size and read efficiency
--   Logical reads vs physical reads. A buffer pool that serves nearly all
--   reads from memory shows physical reads far below read requests.
-- ---------------------------------------------------------------------------
SELECT '--- InnoDB buffer pool ---' AS '';

SELECT CONCAT(' Buffer pool size (MB): ',
              ROUND(@@innodb_buffer_pool_size / 1024 / 1024, 0)) AS '';
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_buffer_pool_read_requests',
                        'Innodb_buffer_pool_reads',
                        'Innodb_data_reads',
                        'Innodb_data_writes',
                        'Innodb_log_waits');

-- ---------------------------------------------------------------------------
-- Activity: queries running longer than the threshold
--   Uses performance_schema.processlist (the MySQL 8 replacement for the
--   legacy SHOW PROCESSLIST / information_schema.processlist).
-- ---------------------------------------------------------------------------
SELECT '--- Long-running queries (over threshold) ---' AS '';

SELECT id, user, host, db, command, time AS seconds_running, state,
       LEFT(info, 200) AS statement_text
FROM performance_schema.processlist
WHERE command <> 'Sleep'
  AND time >= @long_query_sec
  AND id <> CONNECTION_ID()
ORDER BY time DESC;

SELECT 'Health check complete.' AS '';
