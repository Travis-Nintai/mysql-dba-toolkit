-- ============================================================================
-- slow_query_analysis.sql -- MySQL slow query analysis from statement digests
--
-- Purpose:
--   Find the queries that cost the most on a MySQL 8 instance, using
--   performance_schema.events_statements_summary_by_digest. Three views:
--   the queries with the highest total latency, the queries that examine
--   far more rows than they return (the usual full-scan / missing-index
--   shape), and the slow query log configuration as it stands now.
--
--   Digest statistics are cumulative since server start, or since the
--   last reset of the summary table. A digest that ran once a month ago
--   and a digest that ran a thousand times this morning are ranked on
--   the same totals, so read the call counts and the FIRST_SEEN and
--   LAST_SEEN columns alongside the totals before acting on a row.
--
-- Usage:
--   mysql -u dba -p < slow_query_analysis.sql
--   mysql -h db.example.local -u dba -p < slow_query_analysis.sql
--
-- Thresholds as session variables: override with SET before sourcing, or
-- edit the defaults here.
--   @min_avg_ms           digests averaging less than this many
--                         milliseconds are left out of the latency list
--                         (default 1)
--   @min_calls            digests executed fewer times than this are left
--                         out of the examined-vs-sent list, so a single
--                         odd query does not top it (default 5)
--   @min_examined_ratio   examined-per-sent ratio above this flags a
--                         digest in the examined-vs-sent list
--                         (default 100)
-- The latency list is fixed at the top 15 digests: LIMIT does not accept
-- a session variable in plain client SQL, so no variable is offered for
-- it rather than one that silently does nothing.
--
-- Tested on MySQL 8.0 (Ubuntu 24.04 package) against a local instance:
-- executed successfully; see docs/slow-query-analysis.md for the lab
-- run and what it showed.
--
-- Requires:
--   performance_schema enabled (default on MySQL 8). The digest table
--   is populated only when statement instrumentation is on, which is
--   also the default. SELECT on performance_schema is enough; a
--   monitoring account is fine, root is not required.
--
-- Safety:
--   Read-only. SELECT only. This script never resets the digest table
--   and never changes slow log settings; the configuration section
--   reports current values so the reader can decide separately.
-- ============================================================================

SET @min_avg_ms         = IFNULL(@min_avg_ms, 1);
SET @min_calls          = IFNULL(@min_calls, 5);
SET @min_examined_ratio = IFNULL(@min_examined_ratio, 100);

SELECT '===============================================================' AS '';
SELECT ' MySQL slow query analysis (statement digests)' AS '';
SELECT CONCAT(' Server version: ', @@version) AS '';
SELECT CONCAT(' Digest rows tracked: ',
              (SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest)) AS '';
SELECT CONCAT(' Statements summarized: ',
              (SELECT IFNULL(SUM(COUNT_STAR), 0) FROM performance_schema.events_statements_summary_by_digest)) AS '';
SELECT '===============================================================' AS '';

-- ---------------------------------------------------------------------------
-- Top queries by total latency
--   SUM_TIMER_WAIT is in picoseconds: divide by 1,000,000,000 for
--   milliseconds. COUNT_STAR is executions; AVG_TIMER_WAIT and
--   MAX_TIMER_WAIT are likewise picoseconds and use the same divisor.
-- ---------------------------------------------------------------------------
SELECT '--- Top queries by total latency ---' AS '';

SELECT SCHEMA_NAME AS schema_name,
       LEFT(DIGEST_TEXT, 200) AS digest_text,
       COUNT_STAR AS calls,
       ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_ms,
       ROUND(AVG_TIMER_WAIT / 1000000000, 3) AS avg_ms,
       ROUND(MAX_TIMER_WAIT / 1000000000, 3) AS max_ms,
       SUM_ROWS_EXAMINED AS rows_examined,
       SUM_ROWS_SENT AS rows_sent,
       FIRST_SEEN AS first_seen,
       LAST_SEEN AS last_seen
FROM performance_schema.events_statements_summary_by_digest
WHERE AVG_TIMER_WAIT / 1000000000 >= @min_avg_ms
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 15;

-- ---------------------------------------------------------------------------
-- Queries that examine far more rows than they return
--   A high examined-per-sent ratio is the classic missing-index or
--   unselective-predicate shape: the server reads a large part of a
--   table to return a handful of rows. SUM_NO_INDEX_USED counts
--   executions that used no index at all; SUM_NO_GOOD_INDEX_USED counts
--   executions where the chosen index did not narrow the scan enough.
--   Both are reported so the two cases stay distinguishable.
-- ---------------------------------------------------------------------------
SELECT '--- Queries examining far more rows than they return ---' AS '';

SELECT SCHEMA_NAME AS schema_name,
       LEFT(DIGEST_TEXT, 200) AS digest_text,
       COUNT_STAR AS calls,
       ROUND(AVG_TIMER_WAIT / 1000000000, 3) AS avg_ms,
       SUM_ROWS_EXAMINED AS rows_examined,
       SUM_ROWS_SENT AS rows_sent,
       ROUND(SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0), 1) AS examined_per_sent,
       SUM_NO_INDEX_USED AS no_index_used,
       SUM_NO_GOOD_INDEX_USED AS no_good_index_used,
       SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables
FROM performance_schema.events_statements_summary_by_digest
WHERE COUNT_STAR >= @min_calls
  AND SUM_ROWS_SENT > 0
  AND SUM_ROWS_EXAMINED / SUM_ROWS_SENT >= @min_examined_ratio
ORDER BY (SUM_ROWS_EXAMINED / SUM_ROWS_SENT) DESC
LIMIT 100;

-- ---------------------------------------------------------------------------
-- Slow query log configuration, as it stands now
--   slow_query_log says whether the log is on; long_query_time is the
--   threshold in seconds above which a statement is logged; log_output
--   says whether slow statements go to a file, a table, or both.
--   This section only reports. Changing any of these is a separate,
--   deliberate step (see docs/slow-query-analysis.md).
-- ---------------------------------------------------------------------------
SELECT '--- Slow query log configuration ---' AS '';

SELECT @@slow_query_log AS slow_query_log_enabled,
       @@long_query_time AS long_query_time_seconds,
       @@log_output AS log_output,
       @@slow_query_log_file AS slow_query_log_file,
       @@log_queries_not_using_indexes AS log_queries_not_using_indexes;

SELECT 'Slow query analysis complete.' AS '';
SELECT 'Digest totals are cumulative since server start or last reset;' AS '';
SELECT 'check calls, first_seen, and last_seen before acting on a row.' AS '';
