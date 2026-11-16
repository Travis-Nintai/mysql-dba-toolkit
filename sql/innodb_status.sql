-- ============================================================================
-- innodb_status.sql -- MySQL InnoDB storage engine status check
--
-- Purpose:
--   One-pass InnoDB health read for MySQL 8: buffer pool hit ratio and
--   page mix, redo log pressure, transaction history list length,
--   current transactions and lock waits, row operation counters, change
--   buffer activity, and adaptive hash index use. All sections read
--   performance_schema and information_schema, which are queryable as
--   ordinary tables, except the appendix: checkpoint age and the latest
--   deadlock detail live only in SHOW ENGINE INNODB STATUS, so the
--   script prints that output at the end for manual review and the
--   companion doc explains how to read it.
--
--   Counters are cumulative since server start, or since the last
--   reset of the status tables. A hit ratio of 99.9 percent on an
--   instance that has been up for a month says little about the last
--   hour, so read the ratio alongside uptime and the raw read counts
--   before acting on it. The same applies to the row operation
--   counters: they describe total work done, not current load.
--
-- Usage:
--   mysql -u dba -p < innodb_status.sql
--   mysql -h db.example.local -u dba -p < innodb_status.sql
--
-- Thresholds as session variables: override with SET before sourcing, or
-- edit the defaults here.
--   @warn_buffer_hit_pct  buffer pool hit ratio below this percent is
--                         flagged (default 99)
--   @warn_dirty_pct       modified (dirty) pages above this percent of
--                         the buffer pool database pages is flagged
--                         (default 75)
--   @warn_history_len     transaction history list length above this
--                         is flagged; a long list usually means a
--                         long-running transaction is holding back
--                         purge (default 1000)
--   @long_trx_sec         transactions open longer than this many
--                         seconds are listed (default 60)
--
-- Tested on MySQL 8.0 (Ubuntu 24.04 package) against a local instance:
-- executed successfully; see docs/innodb-status.md for the lab run and
-- what it showed.
--
-- Requires:
--   performance_schema enabled (default on MySQL 8). SELECT on
--   information_schema and performance_schema is enough; a monitoring
--   account is fine, root is not required. The redo log capacity line
--   needs MySQL 8.0.30 or later; on earlier 8.0 releases read
--   innodb_log_file_size instead.
--
-- Safety:
--   Read-only. SELECT and SHOW only.
-- ============================================================================

SET @warn_buffer_hit_pct = IFNULL(@warn_buffer_hit_pct, 99);
SET @warn_dirty_pct      = IFNULL(@warn_dirty_pct, 75);
SET @warn_history_len    = IFNULL(@warn_history_len, 1000);
SET @long_trx_sec        = IFNULL(@long_trx_sec, 60);

SELECT '===============================================================' AS '';
SELECT ' MySQL InnoDB status check' AS '';
SELECT CONCAT(' Version             : ', @@version) AS '';
SELECT CONCAT(' Uptime (hrs)        : ',
              ROUND((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                      WHERE VARIABLE_NAME = 'Uptime') / 3600, 1)) AS '';
SELECT CONCAT(' Buffer pool size    : ',
              ROUND(@@innodb_buffer_pool_size / 1024 / 1024, 0), ' MB, ',
              @@innodb_buffer_pool_instances, ' instance(s)') AS '';
SELECT CONCAT(' Redo log capacity   : ',
              ROUND(@@innodb_redo_log_capacity / 1024 / 1024, 0),
              ' MB (innodb_log_file_size ',
              ROUND(@@innodb_log_file_size / 1024 / 1024, 0), ' MB)') AS '';
SELECT CONCAT(' Flush log at commit : ', @@innodb_flush_log_at_trx_commit,
              ' (1 = flush and fsync every commit)') AS '';
SELECT CONCAT(' File per table      : ', @@innodb_file_per_table) AS '';
SELECT '===============================================================' AS '';

-- ---------------------------------------------------------------------------
-- Buffer pool efficiency: logical reads served from memory vs physical
-- reads from disk. The ratio is the headline number; the raw counts
-- tell whether it is based on enough traffic to mean anything.
-- ---------------------------------------------------------------------------
SELECT '--- Buffer pool hit ratio ---' AS '';

SET @bp_requests = CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                          WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS UNSIGNED);
SET @bp_reads = CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS UNSIGNED);

SELECT @bp_requests AS logical_read_requests,
       @bp_reads AS physical_reads,
       ROUND(100.0 * (1 - @bp_reads / NULLIF(@bp_requests, 0)), 2) AS buffer_hit_pct,
       CASE WHEN @bp_requests = 0 THEN 'no traffic yet'
            WHEN 100.0 * (1 - @bp_reads / @bp_requests) >= @warn_buffer_hit_pct THEN 'ok'
            ELSE 'WARNING: below threshold' END AS status;

-- ---------------------------------------------------------------------------
-- Buffer pool pages: how the pool is divided between free pages, data
-- pages, and modified (dirty) pages waiting to be flushed. A dirty
-- share that stays high means flushing is not keeping up with writes.
-- ---------------------------------------------------------------------------
SELECT '--- Buffer pool pages ---' AS '';

SELECT POOL_ID,
       POOL_SIZE,
       FREE_BUFFERS AS free_pages,
       DATABASE_PAGES AS data_pages,
       OLD_DATABASE_PAGES AS old_pages,
       MODIFIED_DATABASE_PAGES AS dirty_pages,
       ROUND(100.0 * MODIFIED_DATABASE_PAGES / NULLIF(DATABASE_PAGES, 0), 1) AS dirty_pct,
       CASE WHEN 100.0 * MODIFIED_DATABASE_PAGES / NULLIF(DATABASE_PAGES, 0)
                 >= @warn_dirty_pct
            THEN 'WARNING: high dirty page share' ELSE 'ok' END AS dirty_status,
       NUMBER_PAGES_READ AS pages_read,
       NUMBER_PAGES_CREATED AS pages_created,
       NUMBER_PAGES_WRITTEN AS pages_written,
       NUMBER_PAGES_GET AS pages_accessed,
       HIT_RATE AS buffer_pool_hit_rate,
       PAGES_MADE_YOUNG AS pages_made_young,
       PAGES_NOT_MADE_YOUNG AS pages_not_made_young
FROM information_schema.INNODB_BUFFER_POOL_STATS;

-- ---------------------------------------------------------------------------
-- Redo log: write volume and waits. Log waits above zero mean a
-- transaction had to wait for redo log space, which is the signal
-- that the redo log is too small for the write rate or that
-- checkpointing is falling behind.
-- ---------------------------------------------------------------------------
SELECT '--- Redo log ---' AS '';

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_log_waits', 'Innodb_log_write_requests',
                        'Innodb_log_writes', 'Innodb_os_log_written',
                        'Innodb_os_log_fsyncs', 'Innodb_os_log_pending_fsyncs',
                        'Innodb_os_log_pending_writes');

SELECT CASE WHEN (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                  WHERE VARIABLE_NAME = 'Innodb_log_waits') = 0
            THEN 'ok: no log waits recorded'
            ELSE 'WARNING: log waits recorded, see docs/innodb-status.md' END AS log_wait_status;

-- ---------------------------------------------------------------------------
-- Transactions: history list length and long-running transactions.
--   The history list is the undo log that purge has not yet cleared.
--   It grows when a long-running transaction, or a transaction that
--   never commits, holds back purge, and a long list is the usual
--   reason a table will not shrink after deletes.
-- ---------------------------------------------------------------------------
SELECT '--- Transaction history list ---' AS '';

SELECT COUNT AS history_list_length,
       CASE WHEN COUNT >= @warn_history_len
            THEN 'WARNING: above threshold, look for a long-running transaction'
            ELSE 'ok' END AS status
FROM information_schema.INNODB_METRICS
WHERE NAME = 'trx_rseg_history_len';

SELECT '--- Long-running transactions (over threshold) ---' AS '';

SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_seconds,
       trx_mysql_thread_id, trx_rows_locked, trx_rows_modified,
       trx_isolation_level, LEFT(trx_query, 120) AS current_statement
FROM information_schema.INNODB_TRX
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) >= @long_trx_sec
ORDER BY trx_started;

-- ---------------------------------------------------------------------------
-- Locks: current lock waits and the deadlock counter. A wait row names
-- the waiting transaction and the transaction holding the lock it
-- needs; the two together are the starting point for a blocking
-- investigation, not the whole answer. Row lock waits are counted
-- cumulatively since server start. There is no deadlock counter
-- exposed as a status variable on MySQL 8.0, so the latest deadlock
-- detail comes from the appendix instead.
--
-- Note: on MySQL 8.0, performance_schema.data_lock_waits carries only
-- the requesting and blocking lock IDs, not the locked object. The
-- object, lock type, and lock mode come from joining it to
-- performance_schema.data_locks on the requesting lock ID.
-- ---------------------------------------------------------------------------
SELECT '--- Lock waits ---' AS '';

SELECT COUNT(*) AS waiting_locks
FROM performance_schema.data_lock_waits;

SELECT w.REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx,
       l.OBJECT_SCHEMA, l.OBJECT_NAME, l.INDEX_NAME,
       l.LOCK_TYPE, l.LOCK_MODE, l.LOCK_STATUS,
       w.BLOCKING_ENGINE_TRANSACTION_ID AS blocking_trx
FROM performance_schema.data_lock_waits w
JOIN performance_schema.data_locks l
  ON l.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID;

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_row_lock_current_waits', 'Innodb_row_lock_waits',
                        'Innodb_row_lock_time', 'Innodb_row_lock_time_avg',
                        'Innodb_row_lock_time_max');

-- ---------------------------------------------------------------------------
-- Row operations: total rows read, inserted, updated, and deleted, and
-- total data read and written. Cumulative since server start; use
-- them to compare workload shape between two runs, not as a rate.
-- ---------------------------------------------------------------------------
SELECT '--- Row operations ---' AS '';

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_rows_read', 'Innodb_rows_inserted',
                        'Innodb_rows_updated', 'Innodb_rows_deleted',
                        'Innodb_data_reads', 'Innodb_data_writes',
                        'Innodb_data_read', 'Innodb_data_written',
                        'Innodb_data_fsyncs');

-- ---------------------------------------------------------------------------
-- Change buffer: secondary index changes merged from the change buffer
-- into the index. A growing change buffer size with few merges means
-- writes are being deferred; that is normal on write-heavy secondary
-- indexes and only a problem when it keeps growing without bound.
--
-- Note: the older Innodb_ibuf_* status variables do not exist on
-- MySQL 8.0, so these counters come from information_schema
-- .INNODB_METRICS instead.
-- ---------------------------------------------------------------------------
SELECT '--- Change buffer ---' AS '';

SELECT NAME AS metric, COUNT AS value
FROM information_schema.INNODB_METRICS
WHERE NAME IN ('ibuf_merges', 'ibuf_merges_insert',
               'ibuf_merges_delete_mark', 'ibuf_merges_delete',
               'ibuf_merges_discard_insert',
               'ibuf_merges_discard_delete_mark',
               'ibuf_merges_discard_delete', 'ibuf_size');

-- ---------------------------------------------------------------------------
-- Adaptive hash index: searches served by the hash index vs searches
-- that fell back to the B-tree. A high B-tree share means the hash
-- index is not earning its memory on this workload.
--
-- Note: the older Innodb_adaptive_hash_* status variables do not exist
-- on MySQL 8.0, so these counters come from information_schema
-- .INNODB_METRICS instead.
-- ---------------------------------------------------------------------------
SELECT '--- Adaptive hash index ---' AS '';

SET @ahi_searches = CAST((SELECT COUNT FROM information_schema.INNODB_METRICS
                           WHERE NAME = 'adaptive_hash_searches') AS UNSIGNED);
SET @ahi_btree = CAST((SELECT COUNT FROM information_schema.INNODB_METRICS
                        WHERE NAME = 'adaptive_hash_searches_btree') AS UNSIGNED);

SELECT @ahi_searches AS hash_searches,
       @ahi_btree AS btree_searches,
       ROUND(100.0 * @ahi_btree / NULLIF(@ahi_searches + @ahi_btree, 0), 1) AS btree_search_pct;

-- ---------------------------------------------------------------------------
-- Compression: one row per page size, only when compressed tables have
-- been used. Empty on an instance with no compressed tables, which is
-- the normal result here.
-- ---------------------------------------------------------------------------
SELECT '--- Compression (empty when no compressed tables exist) ---' AS '';

SELECT PAGE_SIZE, COMPRESS_OPS, COMPRESS_OPS_OK, COMPRESS_TIME,
       UNCOMPRESS_OPS, UNCOMPRESS_TIME
FROM information_schema.INNODB_CMP;

-- ---------------------------------------------------------------------------
-- Appendix: full engine status. Read the LOG section for checkpoint
-- age (Log sequence number minus Last checkpoint at) and the LATEST
-- DETECTED DEADLOCK section for the most recent deadlock detail.
-- ---------------------------------------------------------------------------
SELECT '--- Appendix: SHOW ENGINE INNODB STATUS ---' AS '';

SHOW ENGINE INNODB STATUS;

SELECT 'InnoDB status check complete.' AS '';
