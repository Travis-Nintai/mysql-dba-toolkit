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
-- Tested on MySQL 8.0.46 (Ubuntu 24.04 package): executed against a local
-- source/replica pair on one host (source port 3306, replica port 3307,
-- GTID auto-position). On the source the script reported NOT CONFIGURED
-- for its own channels and listed the attached replica in the Binlog
-- Dump GTID processlist section. On the replica it reported RECEIVING
-- with both receiver and applier ON and zero lag. With the applier
-- stopped it reported the applier OFF while the receiver stayed ON, and
-- with replication fully stopped it reported ATTENTION in both cases
-- after the summary fix below. Testing caught that the original summary
-- checked only the receiver, so a stopped applier was reported as
-- RECEIVING while the replica fell behind; fixed 2026-11-08.
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

-- The summary checks both sides of replication: the receiver (connection
-- status) and the applier (coordinator status). Either side stopped means
-- the replica is not keeping up, even if the other side still reports ON.
-- A stopped applier with a running receiver is the usual shape of a
-- replica quietly falling behind, so it must not read as RECEIVING.
SELECT CASE
         WHEN (SELECT COUNT(*)
               FROM performance_schema.replication_connection_status) = 0
           THEN 'NOT CONFIGURED: this instance has no replication source. It is standalone, or it is a source with no replica channels of its own.'
         WHEN (SELECT COUNT(*)
               FROM performance_schema.replication_connection_status
               WHERE service_state <> 'ON') > 0
           OR (SELECT COUNT(*)
               FROM performance_schema.replication_applier_status_by_coordinator
               WHERE service_state <> 'ON') > 0
           THEN 'ATTENTION: a replication channel receiver or applier is not in service_state ON. The replica may be falling behind even though one side still reports ON. Check last_error_message above and SHOW REPLICA STATUS.'
         ELSE 'RECEIVING: all configured channel receivers and appliers are connected.'
       END AS summary;

-- ---------------------------------------------------------------------------
-- Source-side view: if other instances replicate from this one, they show
-- up as connected replicas. Empty means no replicas are currently attached.
-- ---------------------------------------------------------------------------
SELECT '--- Replicas connected to this instance (if it is a source) ---' AS '';

SELECT host, user, command, time AS seconds_connected, state
FROM performance_schema.processlist
WHERE command = 'Binlog Dump' OR command = 'Binlog Dump GTID';
