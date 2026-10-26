# Script conventions

Conventions used by every script in this repository.

## SQL scripts

- Read-only against the database. The SQL scripts query
  `information_schema`, `performance_schema`, and status variables.
  Nothing here writes to a database. The Bash backup script is the one
  exception to "nothing writes" in the narrowest sense: it writes a dump
  file to local disk and nothing else; it never issues a write against
  MySQL itself.
- A header comment states the purpose, the exact invocation, thresholds,
  the MySQL version tested against, and the permissions required.
- Tunables are session variables with defaults set through `IFNULL` at the
  top of the script, so a caller can `SET @warn_conn_pct = 90;` before
  sourcing the file and the caller's value wins. Nobody has to edit the
  script to tune a threshold.
- Sections are separated with banner output so captured logs stay
  scannable, and each section heading says what it reports.
- Replication and other state checks report a plain-language result for
  the not-configured case. An empty result set is a confusing answer to
  "is replication running"; a sentence is not.
- Never embed credentials, hostnames, or environment-specific values.
  Connections come from the `mysql` client invocation or its option files,
  which stay outside the repository.

## Testing honesty

- Scripts are labeled in their headers with exactly what was executed and
  against what. A query path that could not be exercised in the lab (the
  replica branch of the replication script, for example) is labeled as
  logic-reviewed, not tested.
- When lab topology grows (a real replica pair, for instance), re-run the
  affected script, update the header, and say what changed in the commit
  message.
