# MySQL DBA Toolkit

Operational scripts for MySQL 8 administration: an instance health check,
a replication status check, a slow query analysis from statement
digests, and a mysqldump backup script with a binary
log point-in-time recovery lab, built and tested in a local lab.

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
├── sql/    -- MySQL diagnostic scripts (health check, replication status, slow query analysis)
└── docs/   -- script conventions, backup and recovery lab, slow query analysis, replication setup
```

## Scripts

| Script | What it does |
|---|---|
| `sql/db_health_check.sql` | Instance overview: version and uptime, connection utilization vs `max_connections` with a warning threshold, aborted connection counts, database and table sizes, InnoDB buffer pool counters, long-running queries from `performance_schema.processlist` |
| `sql/replication_status.sql` | Replication state from `performance_schema` replication tables: channel connection and applier state with error text, plus a plain-language summary that reports NOT CONFIGURED on a standalone instance, RECEIVING when receiver and applier are both running, and ATTENTION when either side stops (see `docs/replication-setup.md`) |
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
and replication state reported from the performance_schema replication
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
