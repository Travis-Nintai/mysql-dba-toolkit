# MySQL DBA Toolkit

Operational scripts for MySQL 8 administration: an instance health check,
a replication status check, an InnoDB storage engine status check, a
slow query analysis from statement digests, and a mysqldump backup
script with a binary log point-in-time recovery lab, built and tested
in a local lab.

An honest note on scope: this repository is a portfolio lab and reference
implementation. The scripts are real and were executed against a live MySQL
8 instance during development. They are presented as lab work demonstrating
MySQL-native administration technique, not as tooling taken from a
production environment.

## Who it is for

DBAs and engineers who work with MySQL, or who administer several platforms
and want the MySQL version of familiar checks (instance health, replication
state) written the MySQL way: `performance_schema` and `information_schema`,
not translated syntax from another platform.

## Layout

```
mysql-dba-toolkit/
├── bash/   -- mysqldump backup script
├── sql/    -- MySQL diagnostic scripts (health check, replication status, InnoDB status, slow query analysis)
└── docs/   -- script conventions, backup and recovery lab, slow query analysis, replication setup, InnoDB status
```

## Scripts

| Script | What it does |
|---|---|
| `sql/db_health_check.sql` | Instance overview: version and uptime, connection utilization vs `max_connections` with a warning threshold, aborted connection counts, database and table sizes, InnoDB buffer pool counters, long-running queries from `performance_schema.processlist` |
| `sql/replication_status.sql` | Replication state from `performance_schema` replication tables: channel connection and applier state with error text, plus a plain-language summary that reports NOT CONFIGURED on a standalone instance, RECEIVING when receiver and applier are both running, and ATTENTION when either side stops (see `docs/replication-setup.md`) |
| `sql/innodb_status.sql` | InnoDB storage engine status: buffer pool hit ratio and page mix with dirty page share, redo log pressure and log waits, transaction history list length, long-running transactions, current lock waits with waiting and blocking transaction IDs, row operation counters, change buffer activity, and adaptive hash index use, with the full `SHOW ENGINE INNODB STATUS` output as an appendix for checkpoint age and deadlock detail (see `docs/innodb-status.md`) |
| `sql/slow_query_analysis.sql` | Slow query analysis from `performance_schema` statement digests: top queries by total latency, queries that examine far more rows than they return with no-index counts, and current slow query log configuration (see `docs/slow-query-analysis.md`) |
| `bash/backup_database.sh` | Logical backup of one database with `mysqldump`: consistent InnoDB snapshot, read-back verification, and the binary log file and position the dump is consistent with, for point-in-time recovery (see `docs/backup-recovery-lab.md`) |

Health check:

```
mysql -h db.example.local -u dba -p < sql/db_health_check.sql
```

Tune thresholds for one run by setting the session variables first:

```
mysql -u dba -p -e "SET @warn_conn_pct = 90; SET @long_query_sec = 120; \
  SOURCE sql/db_health_check.sql;"
```

Replication status (see `docs/replication-setup.md` for the source and
replica pair lab, including how to read the output on each side):

```
mysql -h db.example.local -u dba -p < sql/replication_status.sql
```

InnoDB status (see `docs/innodb-status.md` for the lab run and how to
read the output):

```
mysql -h db.example.local -u dba -p < sql/innodb_status.sql
```

Tune thresholds for one run by setting the session variables first:

```
mysql -u dba -p -e "SET @warn_buffer_hit_pct = 99.5; SET @warn_dirty_pct = 50; \
  SET @long_trx_sec = 30; SOURCE sql/innodb_status.sql;"
```

Slow query analysis (see `docs/slow-query-analysis.md` for the lab run
and how to read the output):

```
mysql -h db.example.local -u dba -p < sql/slow_query_analysis.sql
```

Tune thresholds for one run by setting the session variables first:

```
mysql -u dba -p -e "SET @min_avg_ms = 5; SET @min_examined_ratio = 500; \
  SOURCE sql/slow_query_analysis.sql;"
```

Backup (see `docs/backup-recovery-lab.md` for the full walkthrough):

```
bash/backup_database.sh -d <database> -o ./backups
```

## Assumptions

- MySQL 8.0 or later, with `performance_schema` enabled (the default).
  The replication script's performance_schema tables require 8.0.22 or
  later for the channel queries as written.
- Run as a user who can read `information_schema` and `performance_schema`.
  A monitoring account is fine; root is not required.
- Hostnames and values in examples are fictional.

## Testing

Executed against MySQL 8.0.46 on Ubuntu 24.04 in a local lab:

- `db_health_check.sql` ran clean (exit 0) against an instance holding a
  5,000 row test table. All sections produced correct output, and the
  connection warning was verified by setting `@warn_conn_pct = 0` and
  confirming the status flipped to WARNING. One real bug was found and
  fixed during testing: uptime is a status variable, not a system
  variable, and the script now reads it from
  `performance_schema.global_status`.
- `replication_status.sql` ran clean (exit 0) against a local
  source/replica pair built for this session (source port 3306,
  replica port 3307, GTID auto-positioning), as documented in
  `docs/replication-setup.md`. On the source it reported NOT
  CONFIGURED for its own channels and listed the attached replica
  in the Binlog Dump GTID processlist section. On the replica it
  reported RECEIVING with both receiver and applier ON and zero lag,
  and the replica matched the source exactly at 2,150 rows after a
  100 row write followed by a 50 row write with the applier stopped.
  With the applier stopped, the replica stayed 50 rows behind while
  the receiver stayed ON, and the original summary still read
  RECEIVING: testing caught that the summary checked only the
  receiver. The summary now checks both receiver and applier, and
  the fixed script was re-run in all three states (running:
  RECEIVING, applier stopped: ATTENTION, fully stopped: ATTENTION)
  with the source run unchanged.
- `innodb_status.sql` ran clean (exit 0) against a 5,000 row lab table
  on the same instance, as documented in `docs/innodb-status.md`. The
  buffer pool hit ratio read 98.49 percent on the cold cache after a
  restart (correctly WARNING at the default 99 percent threshold) and
  99.08 percent after warm-up. A 5,000 row update left 33 dirty pages
  (3.2 percent), flagged WARNING when the dirty threshold was
  overridden to 1 percent. A deliberate holder and waiter pair on one
  row produced exactly one lock wait, reported with the waiting
  transaction, the locked table and index, the lock mode, and the
  blocking transaction. A long-running transaction appeared in its
  section with `@long_trx_sec = 1`. Threshold overrides were verified
  for the hit ratio, dirty share, and history list. Testing caught
  four real schema errors before commit: the buffer pool stats table
  has no `NUMBER_PAGES_EVICTED` column, the lock waits table carries
  no object columns (they come from a join to `data_locks`), the
  `Innodb_ibuf_*` and `Innodb_adaptive_hash_*` status variables do
  not exist on MySQL 8.0 (those counters now come from
  `INNODB_METRICS`), and `Innodb_deadlocks` is not exposed as a
  status variable on MySQL 8.0 (deadlock detail is appendix-only).
  The redo log showed 0 log waits, the change buffer 0 merges with
  size 1, and the adaptive hash index 20,087 hash searches against
  4,518 B-tree searches (18.4 percent B-tree share).
- `slow_query_analysis.sql` ran clean (exit 0) against a 5,000 row lab
  table with three statements run 20 times each. The whole-table
  aggregation topped the latency list (118.8 ms total, 5.942 ms
  average, 100,000 rows examined, 80 sent, ratio 1250.0); the
  unindexed filter showed the missing-index shape (ratio 250.0, no
  index used on every execution); the primary key lookup showed a
  ratio of 1.0 and correctly appeared in neither flagged list.
  Threshold overrides were verified (strict thresholds return headers
  only), as was the configuration section reflecting a real slow log
  setting change. Testing caught a real bug before commit: average
  and maximum latency were divided by 1,000,000 instead of
  1,000,000,000, inflating them 1000x; all timer columns now share
  one divisor.
- `backup_database.sh` and the PITR lab in `docs/backup-recovery-lab.md`
  were executed end to end on the same instance: a 2,000 row lab table
  backed up clean (exit 0) with its binary log position recorded, then
  50 rows inserted, one row updated, and one row deleted after the
  backup. After the table was dropped, restoring the dump alone returned
  the 2,000 row baseline, and replaying the binary log from the dump's
  position to the pre-drop position restored the exact pre-disaster
  state (2,049 rows, matching sums, updated and deleted rows correct).
  Exit codes 1 (usage), 2 (unreachable server), and 3 (failed
  verification) were each verified. One real bug was found by testing:
  mysqldump 8.0.46 writes the position comment in the older
  `CHANGE MASTER TO` form, so the script now accepts either wording.

## Safety notes

- Everything here is read-only. The scripts run SELECT and SHOW-style
  queries against the data dictionary and performance schema.
- Never commit credentials, hostnames, or environment-specific details
  alongside these scripts. Client option files (`.my.cnf`) are gitignored
  here on purpose.

## What this demonstrates

MySQL-native operational checks: connection pressure against
`max_connections`, InnoDB buffer pool counters read as logical vs physical
reads, long-running query detection from `performance_schema.processlist`,
InnoDB engine status read as buffer pool hit ratio and dirty page share,
redo log waits, history list length, lock waits with waiting and blocking
transactions, and change buffer and adaptive hash index counters from
`INNODB_METRICS`, and replication state reported from the performance_schema replication
tables with the standalone case handled explicitly and the summary
checking both the receiver and the applier, verified against a real
local source/replica pair, plus a verified
logical backup workflow and a binary log point-in-time recovery
procedure that was actually run, not just described, and slow query
analysis from statement digests that ranks queries by total latency
and flags the high examined-per-sent, no-index shape for EXPLAIN
follow-up.

## Background

Independent portfolio lab project, developed and tested locally with
fictional data. Not taken from any production system or employer.
