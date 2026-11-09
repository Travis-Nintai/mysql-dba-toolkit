# MySQL replication: source/replica pair and status checks

`sql/replication_status.sql` answers the first question about any MySQL
replica: is it replicating, and if so, is it keeping up. It reads the
`performance_schema` replication tables, which are queryable as ordinary
tables on MySQL 8.0.22 and later, instead of parsing the text output of
`SHOW REPLICA STATUS`. The classic command is still the right tool when
you need the full field list, including the last error text and the lag
in seconds; this script is the quick status read that also handles the
standalone case gracefully instead of returning an empty result.

## What the script reports

Four views, in order:

1. Instance identity: hostname and port, server ID and UUID, read-only
   and super read-only flags. On a pair built on one host, the port is
   what tells the two instances apart.
2. Replication connection (receiver): one row per configured channel,
   with `service_state` and the last error number and message. No rows
   at all means this instance has no replication source configured.
3. Replication applier: the coordinator state per channel, with the
   same error columns. The receiver and the applier are separate
   threads, and they fail separately. A replica can be connected and
   receiving while its applier is stopped, which is exactly the state
   where it falls behind quietly.
4. Plain-language summary, plus a source-side view: any replicas
   currently attached to this instance, shown as `Binlog Dump` or
   `Binlog Dump GTID` rows in the processlist. On a source, that
   section is the confirmation that a replica is actually connected;
   on a replica it is normally empty.

The summary checks both sides of replication. It reports NOT CONFIGURED
when no channel exists, ATTENTION when any receiver or any applier is
not in `service_state` ON, and RECEIVING only when every configured
receiver and applier is ON. The both-sides check matters: an earlier
version of this script checked only the receiver, and lab testing
showed a stopped applier being reported as RECEIVING while the replica
fell 50 rows behind. That is fixed as of 2026-11-08; the lab run below
documents the before and after.

For lag in seconds, use `SHOW REPLICA STATUS` and read
`Seconds_Behind_Source`. The `performance_schema` tables do not expose
that value directly, and this script does not pretend otherwise.

## Building a local source/replica pair

The lab pair runs two `mysqld` instances on one host, so nothing about
the setup needs a second machine. The source is the package default
instance on port 3306; the replica is a second instance on port 3307
with its own data directory, socket, and error log. GTID-based
replication with auto-positioning keeps the setup simple: the replica
asks the source for every transaction it has not applied yet, and no
binlog file name or position has to be recorded by hand.

Source configuration, added to the server option file:

```ini
[mysqld]
gtid_mode = ON
enforce_gtid_consistency = ON
```

Binary logging was already on in the lab (the Ubuntu package enables
it), the server ID was already 1, and the binlog format was already
ROW. The replica needs the same GTID settings plus its own identity
and paths:

```ini
[mysqld]
server_id = 2
port = 3307
socket = /var/run/mysqld/mysqld-replica.sock
pid-file = /var/run/mysqld/mysqld-replica.pid
datadir = /var/lib/mysql-replica
log_error = /var/log/mysql/replica-error.log
log_bin = /var/lib/mysql-replica/mysql-bin.log
relay_log = /var/lib/mysql-replica/relay-bin.log
gtid_mode = ON
enforce_gtid_consistency = ON
read_only = ON
bind-address = 127.0.0.1
```

Initialize the replica data directory first, then start it as a
separate daemon:

```bash
sudo mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql-replica
sudo mysqld --defaults-file=/etc/mysql/replica.cnf --user=mysql --daemonize
```

Create the replication user on the source and grant only what
replication needs:

```sql
CREATE USER 'repl'@'127.0.0.1' IDENTIFIED BY '<REPL_PASSWORD>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'127.0.0.1';
```

Then point the replica at the source and start it:

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '127.0.0.1',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = '<REPL_PASSWORD>',
  SOURCE_AUTO_POSITION = 1,
  GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
```

`GET_SOURCE_PUBLIC_KEY = 1` is the lab shortcut for the authentication
error below; on a real pair, use TLS between source and replica
instead. `read_only = ON` on the replica keeps writes from landing
there directly, which is the usual replica posture. Note that the
replica also replicates the `mysql` system database by default, so
account changes made on the source flow to the replica; that is
expected in a lab pair and is worth knowing before creating accounts
on a source that already has replicas attached.

## Reading the output on each side

On the source, the script reports NOT CONFIGURED for its own channels,
which is the correct answer: a source has no replication source of its
own. The useful section there is the last one, which lists the attached
replica as a `Binlog Dump GTID` connection with how long it has been
attached and the state `Source has sent all binlog to replica; waiting
for more updates`.

On the replica, the connection and applier sections each show one row
for the default channel, both `service_state` ON, error number 0, and
the summary reads RECEIVING. Run the same script against a standalone
instance and every channel section comes back empty with the NOT
CONFIGURED summary, which is the result the script was first tested
against before a replica existed.

## Lab run

Executed on MySQL 8.0.46, Ubuntu 24.04, against a local source
(port 3306, server ID 1) and replica (port 3307, server ID 2) built
with GTID auto-positioning as described above. The lab table was
`labdb.lab_orders`, 2,000 rows (sum of amounts 516751.93) at the
start of the replication test.

- After `START REPLICA`, both threads reported running with zero
  seconds behind, and the replica matched the source exactly: 2,000
  rows, sum 516751.93, retrieved and executed GTID sets identical.
  The script on the source reported NOT CONFIGURED and listed the
  replica connection; on the replica it reported RECEIVING with both
  receiver and applier ON.
- 100 more rows were written on the source; the replica followed to
  2,100 rows on its own. Steady-state replication needed no further
  action.
- The applier was then stopped with `STOP REPLICA SQL_THREAD` while
  the receiver kept running, and 50 more rows were written on the
  source. The source advanced to 2,150 rows while the replica stayed
  at 2,100: the relay log was growing and nothing was being applied.
  The script showed the receiver ON and the applier OFF, but the
  original summary still read RECEIVING, because it only checked the
  receiver. That is the bug the lab run caught. After `START REPLICA
  SQL_THREAD`, the replica caught up to 2,150 rows with a matching
  sum (556740.80) on both sides.
- The summary was fixed to check both the receiver and the applier,
  and the fixed script was re-run in all three states: running (now
  RECEIVING with wording that names both sides), applier stopped
  (ATTENTION), and fully stopped with `STOP REPLICA` (ATTENTION).
  The source run was unchanged (NOT CONFIGURED, replica listed).
  Replication was left running with zero lag and 2,150 matching rows.

## Lab gotchas

Two setup issues are worth recording because they will recur on any
fresh Ubuntu lab host.

First, the replication user is created with `caching_sha2_password`
by default, and that plugin refuses to authenticate over an insecure
connection. The first `START REPLICA` failed with `Authentication
requires secure connection` while the SQL thread ran fine. The lab
fix is `GET_SOURCE_PUBLIC_KEY = 1` on the `CHANGE REPLICATION SOURCE
TO` statement, which lets the replica fetch the source RSA public key
over the plain connection. The production answer is TLS, not this
flag.

Second, `SHOW BINARY LOG STATUS` does not parse on this Ubuntu build
of MySQL 8.0.46; it fails with a syntax error near `LOG STATUS`. The
older `SHOW MASTER STATUS` works and returns the same file, position,
and executed GTID set, and the backup script in this repository
already uses it for that reason. The same quirk was seen in the
backup and PITR lab, so it is a property of this build rather than a
one-off error.

A third, smaller point: the recursive CTE used to load lab rows needs
`cte_max_recursion_depth` raised above its 1000 default for inserts
past 1,000 rows; set it per session before loading.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| IO thread `Connecting`, `Authentication requires secure connection` | `caching_sha2_password` over a plain connection | `GET_SOURCE_PUBLIC_KEY = 1`, or TLS |
| IO thread `Connecting`, access denied | Wrong replication user, host, or password | `SELECT user, host FROM mysql.user` on the source; the user must match the connection host |
| Replica applies nothing, applier OFF, no error | Applier stopped deliberately or after an error | `SHOW REPLICA STATUS`, last SQL error, then `START REPLICA` |
| Summary says RECEIVING but row counts diverge | Older script version that checked only the receiver | Update to the version that checks the applier too; compare row counts directly |
| `SHOW BINARY LOG STATUS` syntax error | Ubuntu 8.0.46 build quirk | Use `SHOW MASTER STATUS` |
| Replica will not start | Datadir or socket path wrong, or port in use | Replica error log, `SHOW VARIABLES LIKE 'datadir'` |

## Cleanup

The lab pair is torn down after testing: stop the replica instance,
drop the lab database and the replication user on the source, and
remove the replica data directory and option file. Nothing in this
repository depends on the pair still existing. No lab credentials,
hostnames, or data are included here; values in examples are
placeholders.
