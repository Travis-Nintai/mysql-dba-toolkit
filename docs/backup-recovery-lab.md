# Backup and recovery lab: mysqldump plus binary log point-in-time recovery

A logical backup on its own restores a database to the moment the dump was
taken. Everything written after that moment is lost unless the binary logs
survive to replay it. This lab works through both halves: a mysqldump taken
with `bash/backup_database.sh`, then a point-in-time recovery that replays
the binary log from the dump's recorded position up to just before a
simulated disaster.

## Prerequisites

- MySQL 8.0 with binary logging enabled (`log_bin = ON`). Check with
  `SHOW VARIABLES LIKE 'log_bin'`.
- The `--source-data` option needs mysqldump 8.0.26 or later. The lab below
  ran on MySQL 8.0.46, Ubuntu 24.04.
- InnoDB tables. `--single-transaction` gives one consistent snapshot for
  InnoDB; it does not snapshot MyISAM tables.
- A throwaway lab database. Nothing here should be run against a database
  anyone cares about: the disaster step deliberately drops a table.

## The backup script

```bash
bash/backup_database.sh -d <database> [-h <host>] [-P <port>] [-u <user>] [-o <output_dir>]
```

It probes the connection first (exit 2 if unreachable), dumps with
`--single-transaction --routines --source-data=2`, then reads the dump back:
the file must be non-empty, must end with mysqldump's completion marker, and
must carry the binary log position comment that PITR depends on. Any failed
check is exit 3. The script prints that position so it can be used in the
recovery step. No password is ever passed on the command line; use a client
option file or socket auth.

One quirk worth knowing: mysqldump 8.0.46 still writes the position comment
in the older form, `CHANGE MASTER TO MASTER_LOG_FILE='...',
MASTER_LOG_POS=...`, even though the server-side statement was renamed to
`CHANGE REPLICATION SOURCE TO`. The script accepts either wording. The
position is what matters, not the keyword.

## The lab, as executed

Setup: a lab database with one InnoDB table, `lab_orders`, loaded with
2,000 fictional rows.

```sql
CREATE DATABASE labdb;
CREATE TABLE labdb.lab_orders (
  order_id INT PRIMARY KEY,
  amount   DECIMAL(10,2) NOT NULL,
  status   VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
-- 2,000 rows inserted, order_id 1 through 2000
```

Baseline check: 2,000 rows, sum of `amount` 500989.50.

### Step 1: take the backup

```bash
bash/backup_database.sh -d labdb -o /tmp/mysql-lab/backups
```

Result: exit 0, 48 KB dump, and the printed position:

```
PITR position recorded in dump header:
  CHANGE MASTER TO MASTER_LOG_FILE='binlog.000003', MASTER_LOG_POS=37927;
```

### Step 2: keep writing after the backup

Fifty more rows inserted (order_id 2001 through 2050), one row updated
(order_id 100 set to 999.99), one row deleted (order_id 200). State after
these writes: 2,049 rows, sum 503769.40. These are the transactions the
binary log has to recover; the dump alone does not contain them.

### Step 3: record the position before the disaster, then cause it

```sql
SHOW MASTER STATUS;
-- File: binlog.000003, Position: 39758

DROP TABLE labdb.lab_orders;
```

The position captured before the drop is the recovery target: replay must
stop there, so the drop itself is never replayed. (On this 8.0.46 Ubuntu
build, `SHOW BINARY LOG STATUS` did not parse; `SHOW MASTER STATUS`
returned the same file and position, so the lab uses that spelling.)

### Step 4: restore the dump, and see what it alone recovers

```bash
mysql labdb < /tmp/mysql-lab/backups/labdb_20261026_000606.sql
```

Result: 2,000 rows, sum 500989.50. Exactly the baseline, which confirms
both that the dump is good and that it cannot recover post-backup work.
That gap is the whole reason for the next step.

### Step 5: replay the binary log to the pre-disaster position

```bash
mysqlbinlog --start-position=37927 --stop-position=39758 \
  /var/lib/mysql/binlog.000003 | mysql labdb
```

The start position comes from the dump header; the stop position from
step 3. With row-based binary logging (the default), the replay file
contains encoded row events rather than readable INSERT or UPDATE text,
so do not expect to grep it for statement text. Verify by the data, not
by reading the replay file.

Result after replay: 2,049 rows, sum 503769.40, matching the pre-disaster
state exactly. Spot checks: order_id 100 is 999.99 (the post-backup update
recovered), order_id 200 is absent (the post-backup delete honored), and
order_id 2050 is present (a post-backup insert recovered). The dropped
table is back with everything the log covered.

## What this lab does not prove

- Restore speed or dump size at production scale. 2,000 rows and 48 KB say
  nothing about a terabyte database; mysqldump is a logical backup and
  restores one row at a time.
- Physical backup tooling. Percona XtraBackup or a storage snapshot is a
  different answer for large databases, with its own restore procedure.
- Binary log availability. PITR only works if every binary log file from
  the backup's position onward still exists. Check
  `binlog_expire_logs_seconds` (30 days by default) and confirm log
  archiving before relying on this for anything real. A backup whose
  binary logs have expired is a backup to the dump's timestamp only.
- Cross-version restores. Dumps restore cleanly into the same major
  version; moving across major versions needs a compatibility check first.

## Habits this lab is meant to build

Take the backup, read it back, record its position, and test the restore
before it is needed. The most expensive time to discover a broken backup
procedure is during an actual outage. A restore test that ends with
verified row counts is worth more than a backup job that has only ever
reported success.
