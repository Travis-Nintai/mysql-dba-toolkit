# MySQL InnoDB status checks

`sql/innodb_status.sql` is the dedicated InnoDB read for this toolkit.
The health check in `sql/db_health_check.sql` already reports buffer
pool size and the raw read counters; this script goes deeper into the
storage engine itself: how efficiently the buffer pool is serving
reads, how much of it is dirty, whether the redo log is under
pressure, what the transaction history list looks like, which
transactions are open and which locks are waiting, what the row
operation counters say about workload shape, and how the change
buffer and adaptive hash index are behaving.

## What the script reports

Nine views, in order:

1. Instance identity and configuration: version, uptime, buffer pool
   size and instance count, redo log capacity, flush-at-commit
   setting, file-per-table. The redo log capacity line needs MySQL
   8.0.30 or later; on earlier 8.0 releases read
   `innodb_log_file_size` instead, which is printed alongside it.
2. Buffer pool hit ratio: logical read requests vs physical reads,
   with a status against `@warn_buffer_hit_pct` (default 99). The
   raw counts matter as much as the ratio: a 99.9 percent ratio on
   an instance that has served a hundred reads says nothing.
3. Buffer pool pages: free pages, data pages, old pages, dirty
   pages and the dirty share against `@warn_dirty_pct` (default 75),
   plus pages read, created, written, and accessed, and the pool's
   own hit rate per thousand gets. A dirty share that stays high
   means flushing is not keeping up with writes; a share that
   spikes after a bulk load and drains again is normal.
4. Redo log: write requests, log writes, bytes written, fsyncs, and
   pending fsyncs and writes, with a status on `Innodb_log_waits`.
   Any log wait at all means a transaction had to wait for redo log
   space, which is the signal that the redo log is too small for
   the write rate or that checkpointing is falling behind. The fix
   is usually a larger redo log capacity, a faster checkpoint, or
   less write burst, in that order of suspicion.
5. Transaction history list: the undo log purge has not yet
   cleared, against `@warn_history_len` (default 1000), followed by
   transactions open longer than `@long_trx_sec` (default 60). A
   long history list almost always traces back to one long-running
   transaction holding back purge, and it is the usual reason a
   table does not shrink after deletes.
6. Lock waits: a count, then one row per waiting lock from
   `performance_schema.data_lock_waits` joined to
   `performance_schema.data_locks` on the requesting lock ID, which
   is where the locked object, lock type, and lock mode live on
   MySQL 8.0. The row names the waiting transaction and the
   blocking transaction. Row lock wait counts and times follow.
   There is no deadlock counter exposed as a status variable on
   MySQL 8.0; the latest deadlock detail is in the appendix.
7. Row operations: total rows read, inserted, updated, and deleted,
   and total data read and written. Cumulative since server start,
   so they describe workload shape between two runs, not a rate.
8. Change buffer: merges by operation type and current size, from
   `information_schema.INNODB_METRICS`. The older `Innodb_ibuf_*`
   status variables do not exist on MySQL 8.0, which is why this
   section reads the metrics table.
9. Adaptive hash index: hash searches vs B-tree fallback searches,
   also from `INNODB_METRICS`, for the same reason. A high B-tree
   share means the hash index is not earning its memory on this
   workload.
10. Compression: one row per page size, all zeros when no compressed
    tables exist, which is the normal result on a lab instance.
11. Appendix: the full `SHOW ENGINE INNODB STATUS` output. Read
    the LOG section for checkpoint age (log sequence number minus
    last checkpoint at) and the LATEST DETECTED DEADLOCK section
    for the most recent deadlock detail. Neither value is exposed
    as a queryable variable, which is why the appendix exists.

## Building the lab

The lab table is `labdb.innodb_lab`: 5,000 rows with a primary key
and two secondary indexes, loaded with a recursive CTE (raise
`cte_max_recursion_depth` above its 1000 default first, as in the
replication lab). Read traffic came from aggregate scans and
filtered lookups; dirty pages came from updating rows; the lock
wait came from a deliberate holder and waiter pair on the same row.

The holder, in one session:

```sql
START TRANSACTION;
UPDATE innodb_lab SET amount = 9999.00 WHERE id = 42;
SELECT SLEEP(40);
ROLLBACK;
```

The waiter, in a second session started a few seconds later:

```sql
SET SESSION lock_wait_timeout = 35;
START TRANSACTION;
UPDATE innodb_lab SET amount = 8888.00 WHERE id = 42;
COMMIT;
```

A long-running transaction was tested the same way, with the
holder sleeping inside its transaction while the script ran with
`@long_trx_sec = 1`.

## Lab run

Executed on MySQL 8.0.46, Ubuntu 24.04, against a local instance.
Lab table `labdb.innodb_lab`, 5,000 rows, sum of amounts
2,505,424.85.

- The script ran clean (exit 0) on a fresh instance and again after
  the lab workload. On the fresh instance the buffer pool hit ratio
  read 98.49 percent (829 physical reads of 54,921 requests) and
  correctly flagged WARNING against the default 99 percent
  threshold: a cold cache after a restart. After warm-up it read
  99.08 percent, then 99.22 percent, both `ok`.
- Buffer pool pages: 8,192 pages (128 MB), 1,046 data pages. Right
  after a 5,000 row update the pool held 33 dirty pages, 3.2
  percent, which flagged WARNING when the threshold was overridden
  to 1 percent, and drained to 0 after the flush caught up. The
  pool's own hit rate column read 1000 per 1000 gets.
- Redo log: 0 log waits throughout, with 22,354 write requests and
  1,988 log writes at the first read. The status line read `ok: no
  log waits recorded`.
- History list: 0 at idle, 1 after the update workload. Overriding
  `@warn_history_len` to 0 flipped the status to WARNING, which
  verified the threshold logic.
- Lock waits: the deliberate pair produced exactly one waiting
  lock. The script showed waiting transaction 2343, object
  `labdb.innodb_lab`, index PRIMARY, lock type RECORD, mode
  X,REC_NOT_GAP, status WAITING, blocking transaction 2342. The row
  lock counters agreed: 2 waits total, average wait 21,036 ms,
  maximum 42,073 ms, matching the holder's sleep. After both
  sessions finished, the count returned to 0.
- Long-running transactions: with `@long_trx_sec = 1`, the holder
  appeared as transaction 2349, RUNNING, 3 seconds old, 1 row
  locked, 1 row modified, isolation REPEATABLE READ, current
  statement `SELECT SLEEP(20)`. At the default 60 second threshold
  the section was empty, which is the correct result for a quiet
  lab instance.
- Row operations by the end of testing: 5,000 rows inserted,
  10,503 updated, 0 deleted, 21,524 read, matching the lab load
  plus the update and verification queries.
- Change buffer: `ibuf_size` 1, 0 merges of every type. No
  secondary index writes were deferred in this lab, so 0 merges is
  the expected result, not a gap.
- Adaptive hash index: 20,087 hash searches vs 4,518 B-tree
  searches, an 18.4 percent B-tree share. The hash index is doing
  most of the work on this point-lookup workload.
- Compression: one row per page size, all zeros. No compressed
  tables exist in the lab, so this is the expected result.
- Appendix: at the read, log sequence number and last checkpoint
  were both 20,186,472, so checkpoint age was 0. The LATEST
  DETECTED DEADLOCK section was empty, matching zero deadlocks.

## Lab gotchas

Three schema surprises, all caught by running the script against
the live instance before committing it:

First, `information_schema.INNODB_BUFFER_POOL_STATS` on MySQL
8.0.46 has no `NUMBER_PAGES_EVICTED` column, and no
`NUMBER_PAGES_READS`, `NUMBER_PAGES_WRITES`, or
`NUMBER_PAGES_FLUSHED` either. The first version of the script
failed on the evicted column. The section now uses the columns
that exist: `NUMBER_PAGES_GET`, `HIT_RATE`,
`PAGES_MADE_YOUNG`, and `PAGES_NOT_MADE_YOUNG`.

Second, `performance_schema.data_lock_waits` on MySQL 8.0 carries
only the requesting and blocking lock IDs. The locked object, lock
type, and lock mode live in `performance_schema.data_locks`, so
the script joins the two on the requesting lock ID. The first
version queried object columns that do not exist on the waits
table and failed.

Third, the `Innodb_ibuf_*` and `Innodb_adaptive_hash_*` status
variables do not exist on MySQL 8.0, and neither does
`Innodb_deadlocks`. The first version returned empty sections for
the change buffer and adaptive hash index, and silently dropped
the deadlock row. Both sections now read
`information_schema.INNODB_METRICS`, where the counters live, and
the deadlock detail is documented as appendix-only. The metrics
table also confirmed the fix: 15,503 hash searches and 4,102
B-tree searches at the first check, against NULLs from the status
variables.

A smaller point: `INNODB_CMP` on 8.0.46 has no
`COMPRESSION_FAILURES` column. The section lists the six columns
that exist.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Hit ratio below 99 percent | Cold cache after restart, or a working set larger than the pool | Raw read counts and uptime first; then pool size vs data size |
| Dirty page share stays high | Flushing not keeping up with writes | Redo log waits, checkpoint age in the appendix, write rate |
| Log waits above zero | Redo log too small for the write rate, or checkpointing behind | Redo log capacity, checkpoint age, then write bursts |
| History list keeps growing | Long-running transaction holding back purge | Long-running transactions section, then the transaction's owner |
| Lock wait rows that never clear | Blocking transaction holding a row lock | Waiting vs blocking transaction IDs, then the blocking session |
| High B-tree share on hash searches | Adaptive hash index not helping this workload | Query shape: point lookups benefit, range scans do not |
| Change buffer size keeps growing | Secondary index writes deferred faster than merged | Merge counts over time; usually normal on write-heavy indexes |

## Cleanup

The lab database is dropped after testing. Nothing in this
repository depends on it still existing. No lab credentials,
hostnames, or data are included here; values in examples are
placeholders.
