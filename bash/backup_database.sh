#!/usr/bin/env bash
# =============================================================================
# backup_database.sh -- logical backup of one MySQL database
#
# Purpose:
#   Produce a verified mysqldump backup of a single database and report the
#   binary log file and position the dump is consistent with, so the dump
#   can be combined with binary logs for point-in-time recovery. A backup
#   that has never been read back is a hope, not a backup; this script
#   treats the read-back checks as part of the backup.
#
# Usage:
#   ./backup_database.sh -d <database> [-h <host>] [-P <port>] [-u <user>]
#                        [-o <output_dir>]
#
# Options:
#   -d   Database to back up (required)
#   -h   Host (default: the local socket)
#   -P   Port (default: 3306 when -h is given, otherwise the socket)
#   -u   User (default: the OS user)
#   -o   Output directory (default: ./backups, created if missing)
#   -?   Print this usage
#
# Credentials:
#   None are accepted on the command line or stored anywhere. Authentication
#   is the mysql client's business: use a client option file (.my.cnf), the
#   MYSQL_PWD environment variable, or socket auth on the local socket.
#   Never pass a password as an argument; it would show up in ps output.
#
# How the dump stays consistent:
#   --single-transaction takes one consistent InnoDB snapshot without
#   locking tables, so the dump reflects a single point in time for InnoDB
#   tables. MyISAM tables are not covered by that snapshot; they are dumped
#   as read, which is one reason this script is aimed at InnoDB workloads.
#   --source-data=2 (MySQL 8.0.26 and later) records the binary log file
#   and position matching the snapshot as a comment in the dump header.
#   When binary logging is off, the script dumps without it and says so:
#   there is no PITR position to report in that case.
#
# Exit codes (stable, see docs/script-conventions.md):
#   0  backup written and read-back checks passed
#   1  usage error
#   2  could not connect to MySQL
#   3  mysqldump or a verification check failed
#
# Tested on MySQL 8.0, Ubuntu 24.04.
# =============================================================================

set -u

DB=""
HOST=""
PORT=""
USER_NAME=""
OUT_DIR="./backups"

usage() {
    sed -n '2,40p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

while getopts ":d:h:P:u:o:?" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        u) USER_NAME="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        \?) usage; exit 0 ;;
        :) echo "ERROR: option -$OPTARG requires a value" >&2; exit 1 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: -d <database> is required" >&2
    usage >&2
    exit 1
fi

# Build a connection argument array. Empty host/user means "mysql default"
# (local socket, OS user), which is the normal lab setup.
CONN=()
[ -n "$HOST" ] && CONN+=(-h "$HOST")
[ -n "$PORT" ] && CONN+=(-P "$PORT")
[ -n "$USER_NAME" ] && CONN+=(-u "$USER_NAME")

# Connectivity probe first, so an unreachable server is exit 2, not a
# mysqldump error that looks like a data problem.
if ! mysql "${CONN[@]}" -NBe "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: could not connect to MySQL" >&2
    exit 2
fi

# Binary logging decides whether a PITR position exists to record.
LOG_BIN="$(mysql "${CONN[@]}" -NBe "SELECT @@log_bin" 2>/dev/null)"
DUMP_OPTS=(--single-transaction --routines)
if [ "$LOG_BIN" = "1" ]; then
    DUMP_OPTS+=(--source-data=2)
else
    echo "NOTE: binary logging is off on this server; dump will carry no PITR position" >&2
fi

mkdir -p "$OUT_DIR" || { echo "ERROR: cannot create $OUT_DIR" >&2; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="$OUT_DIR/${DB}_${STAMP}.sql"

echo "Backing up '$DB' to $OUT_FILE"
if ! mysqldump "${CONN[@]}" "${DUMP_OPTS[@]}" "$DB" > "$OUT_FILE" 2>"$OUT_FILE.err"; then
    echo "ERROR: mysqldump failed (see $OUT_FILE.err)" >&2
    exit 3
fi
rm -f "$OUT_FILE.err"

# Read-back checks: the file must be non-empty, must end with mysqldump's
# completion marker, and when binary logging is on it must carry the
# source-data comment that PITR depends on.
[ -s "$OUT_FILE" ] || { echo "ERROR: backup file is empty" >&2; exit 3; }
grep -q "Dump completed" "$OUT_FILE" || { echo "ERROR: dump footer missing, file may be truncated" >&2; exit 3; }

if [ "$LOG_BIN" = "1" ]; then
    # mysqldump 8.0 writes the older CHANGE MASTER TO form here; accept
    # either wording so the check survives a mysqldump that uses the newer
    # CHANGE REPLICATION SOURCE TO form.
    PITR_LINE="$(grep -m1 -E "MASTER_LOG_FILE|SOURCE_LOG_FILE" "$OUT_FILE" || true)"
    [ -n "$PITR_LINE" ] || { echo "ERROR: source-data comment missing from dump" >&2; exit 3; }
    echo "PITR position recorded in dump header:"
    echo "  $(echo "$PITR_LINE" | sed 's/^-- //')"
else
    echo "No PITR position: binary logging is off on this server"
fi

SIZE="$(du -h "$OUT_FILE" | cut -f1)"
echo "Backup complete: $OUT_FILE ($SIZE)"
exit 0
