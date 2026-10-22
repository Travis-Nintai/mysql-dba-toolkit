-- ============================================================================
-- replication_status.sql -- MySQL replication status
--
-- Purpose:
--   Report whether this instance is replicating, and if so, whether the
--   replication threads are running and how far behind the source the
--   instance is. On an instance that is not a replica, report that plainly
--   instead of erroring or returning a confusing empty result.
--
-- Usage:
--   mysql -u root -p < replication_status.sql
--   mysql -h db.example.local -u dba -p < replication_status.sql
--
-- How it works:
--   MySQL 8.0.22 and later expose replication state in
--   performance_schema.replication_connection_status and
--   performance_schema.replication_applier_status_by_worker, which are
--   queryable as tables (the older SHOW REPLICA STATUS output is not).
--   This script queries those tables. The classic command remains:
--       SHOW REPLICA STATUS\G
--   Run it alongside this script when you need the full field list,
--   including last error text.
--
-- Tested on MySQL 8.0 (Ubuntu 24.04 package): executed against a local
-- standalone instance that is not a replica; the script reported
-- NOT CONFIGURED for every channel, which is the correct result for that
-- topology. The replica-path queries were logic-reviewed against the
-- documented performance_schema replication tables; they have not been
-- run against a live replica in this lab yet, and this header says so.
--
-- Requires:
--   SELECT on performance_schema. A monitoring account is fine.
--
-- Safety:
--   Read-only.
-- ============================================================================

SELECT '===============================================================' AS '';
SELECT ' MySQL replication status' AS '';
SELECT CONCAT(' Instance: ', @@hostname, ':', @@port) AS '';
SELECT CONCAT(' Server ID: ', @@server_id, '   UUID: ', @@server_uuid) AS '';
SELECT CONCAT(' Read only: ', IF(@@read_only = 1, 'ON', 'OFF'),
              '   Super read only: ',
              IF(@@super_read_only = 1, 'ON', 'OFF')) AS '';
SELECT '===============================================================' AS '';

-- ---------------------------------------------------------------------------
-- Connection status: one row per replication channel.
-- No rows at all means this instance has no replication source configured.
-- ---------------------------------------------------------------------------
SELECT '--- Replication connection (receiver) ---' AS '';

SELECT channel_name,
       service_state,
       last_error_number,
       last_error_message
FROM performance_schema.replication_connection_status;

-- ---------------------------------------------------------------------------
-- Applier status: whether the SQL/applier side is running and erroring.
-- For lag in seconds, use SHOW REPLICA STATUS (Seconds_Behind_Source);
-- the performance_schema tables do not expose that value directly.
-- ---------------------------------------------------------------------------
SELECT '--- Replication applier ---' AS '';

SELECT channel_name,
       service_state,
       last_error_number,
       last_error_message
FROM performance_schema.replication_applier_status_by_coordinator;

SELECT '--- Plain-language summary ---' AS '';

SELECT CASE
         WHEN COUNT(*) = 0
           THEN 'NOT CONFIGURED: this instance has no replication source. It is standalone, or it is a source with no replica channels of its own.'
         WHEN SUM(service_state = 'ON') = COUNT(*)
           THEN 'RECEIVING: all configured channels are connected.'
         ELSE 'ATTENTION: at least one channel is not in service_state ON. Check last_error_message above and SHOW REPLICA STATUS.'
       END AS summary
FROM performance_schema.replication_connection_status;

-- ---------------------------------------------------------------------------
-- Source-side view: if other instances replicate from this one, they show
-- up as connected replicas. Empty means no replicas are currently attached.
-- ---------------------------------------------------------------------------
SELECT '--- Replicas connected to this instance (if it is a source) ---' AS '';

SELECT host, user, command, time AS seconds_connected, state
FROM performance_schema.processlist
WHERE command = 'Binlog Dump' OR command = 'Binlog Dump GTID';
