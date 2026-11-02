# Slow query analysis from statement digests

`sql/slow_query_analysis.sql` answers a practical question: which queries
actually cost the most on this instance, and which ones read far more rows
than they return. It reads
`performance_schema.events_statements_summary_by_digest`, the per-statement
summary MySQL maintains, rather than parsing a log file. That makes it
usable on any MySQL 8 instance with `performance_schema` on, with no log
rotation or file access to arrange first.

## What the script reports

Three views, in order:

1. Top queries by total latency. Total time first, because a query that
   runs a thousand times at 2 ms costs more than a query that runs once
   at 500 ms. Each row carries calls, total, average, and maximum latency,
   rows examined, rows sent, and first and last seen timestamps, so a
   total can be judged against how often and how recently the statement
   ran.
2. Queries that examine far more rows than they return. A high
   examined-per-sent ratio is the classic missing-index or
   unselective-predicate shape: the server reads a large part of a table
   to hand back a handful of rows. Two extra columns keep two cases
   apart: `no_index_used` counts executions that used no index at all,
   and `no_good_index_used` counts executions where the chosen index did
   not narrow the scan enough. A third column, on-disk temporary tables,
   flags sorts and groupings that spilled out of memory.
3. Slow query log configuration as it stands now: whether the slow log
   is on, the `long_query_time` threshold in seconds, whether output
   goes to a file or a table, and whether statements that use no index
   are logged regardless of time. This section only reports. Changing
   any of these values is a separate, deliberate step, described below.

## Reading the output honestly

Digest statistics are cumulative since server start, or since the last
reset of the summary table. A digest that ran once a month ago and a
digest that ran a thousand times this morning are ranked on the same
totals. Read calls, first seen, and last seen alongside every total
before acting on a row.

Digest rows are instance-wide, not per database. Lab and client
statements appear in the same list as application statements: setup
statements, the `mysql` client's own version probes, and the script's
own queries on later runs all show up. In real use, filter by digest
text or by schema to focus the list. One quirk found in the lab: a
statement run without `USE`, even one that names its table with a
fully qualified `labdb.lab_orders`, records a NULL schema name. The
schema column describes the session's current database, not the tables
a statement touches, so schema filtering alone can miss statements.

A high examined-per-sent ratio does not by itself prove a missing
index. An aggregation over a whole table legitimately examines every
row and returns a few grouped rows; that is a scan by design, and the
fix, if one is needed, is usually to narrow the aggregation or
pre-aggregate, not to add an index. The ratio earns its keep on the
other shape: a filtered lookup that examines the whole table to return
a few rows. That is the row to take to `EXPLAIN` first.

## The slow query log, separately

The digest table and the slow query log answer different questions.
Digests summarize everything and rank it; the slow log records
individual slow statements with full text and timing, which is what you
want when a single execution needs investigation rather than a ranking.
To turn the log on for a session of investigation:

```sql
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;
```

`long_query_time` is in seconds, and the default of 10 seconds is too
coarse for most investigation; 1 second is a common starting point.
Setting `log_queries_not_using_indexes = ON` additionally logs
statements that use no index even when they run fast, which is useful
for finding full scans but noisy on a busy instance. These settings
take effect for new connections and do not survive a restart unless
they are also written to the server option file, which is a server
administration change, not something this script does.

Resetting the digest table is also a separate step. `TRUNCATE TABLE
performance_schema.events_statements_summary_by_digest` clears the
cumulative totals so a new measurement window starts clean. The script
never does this on its own: resetting destroys the history the reader
may still need, so it stays a deliberate operator action.

## Lab run

Executed on MySQL 8.0.46, Ubuntu 24.04, against a local instance. A
`labdb.lab_orders` table held 5,000 rows (sum of amounts 2200475.00),
with an index only on the primary key. Three statements ran 20 times
each: a `GROUP BY status` aggregation over the whole table, a filtered
lookup on the unindexed `customer_id` column, and a primary key lookup
on `order_id`. The script ran clean (exit 0), and the results matched
the workload exactly:

- The aggregation topped the latency list: 20 calls, 118.8 ms total,
  5.942 ms average, 100,000 rows examined, 80 rows sent, an
  examined-per-sent ratio of 1250.0, with `no_index_used` counted on
  all 20 executions. A scan by design, as discussed above.
- The unindexed filter came second in the examined-per-sent list: 20
  calls, 1.374 ms average, 100,000 rows examined, 400 rows sent, a
  ratio of 250.0, again with `no_index_used` on every execution. This
  is the row to take to `EXPLAIN`: an index on the filter column is
  the obvious first experiment.
- The primary key lookup did not appear in either flagged list: 20
  calls, 0.198 ms average, 20 rows examined, 20 rows sent, a ratio of
  1.0. It also fell below the script's default 1 ms average-latency
  threshold for the latency list, which is the threshold working as
  designed rather than a missing result.

Threshold overrides were verified separately. With
`@min_avg_ms = 100` and `@min_examined_ratio = 2000`, both lists came
back with headers only, and with `@min_calls = 100` the
examined-per-sent list came back empty, since the workload ran 20
times. The configuration section was verified to reflect a real change:
with the slow log enabled and `long_query_time` set to 1 in the lab,
it reported enabled and 1 second; the lab defaults were off and 10
seconds.

Testing also caught a real bug before anything was committed. The
average and maximum latency columns initially divided the picosecond
timer values by 1,000,000 instead of 1,000,000,000, which inflated them
exactly 1000x: the aggregation showed an average of 5942 ms against a
total of 118.8 ms over 20 calls, which cannot both be true. All timer
columns now use the same divisor, and the corrected run shows 5.942 ms
average against the 118.8 ms total. A related design point is recorded
in the script header: `LIMIT` does not accept a session variable in
plain client SQL, so the latency list is fixed at the top 15 rather
than offering a threshold variable that would silently do nothing.

The lab database was dropped after testing. No lab data, credentials,
or host-specific values are included in this repository.
