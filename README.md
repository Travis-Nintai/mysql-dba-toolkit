# MySQL DBA Toolkit

Operational scripts for MySQL 8 administration: an instance health check,
a replication status check, and a mysqldump backup script with a binary
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
├── sql/    -- MySQL diagnostic scripts (health check, replication status)
└── docs/   -- script conventions, backup and recovery lab
```

## Scripts

| Script | What it does |
|---|---|
| `sql/db_health_check.sql` | Instance overview: version and uptime, connection utilization vs `max_connections` with a warning threshold, aborted connection counts, database and table sizes, InnoDB buffer pool counters, long-running queries from `performance_schema.processlist` |
| `sql/replication_status.sql` | Replication state from `performance_schema` replication tables: channel connection and applier state with error text, plus a plain-language summary that reports NOT CONFIGURED on a standalone instance instead of an empty result |
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

Replication status:

```
mysql -h db.example.local -u dba -p < sql/replication_status.sql
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
- `replication_status.sql` ran clean (exit 0) against the same instance,
  which is standalone, and correctly reported NOT CONFIGURED. The
  replica-side query paths have not been run against a live replica in
  this lab; they are logic-reviewed against the documented
  performance_schema replication tables, and the script header says the
  same.
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
tables with the standalone case handled explicitly, plus a verified
logical backup workflow and a binary log point-in-time recovery
procedure that was actually run, not just described.

## Background

Independent portfolio lab project, developed and tested locally with
fictional data. Not taken from any production system or employer.
