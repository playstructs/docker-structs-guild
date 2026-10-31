#!/usr/bin/env bash
set -euo pipefail

: "${NAT_HOST:?NAT_HOST is required}"
: "${PG_CONNECTION:?PG_CONNECTION is required}"
: "${PG_CHANNEL:?PG_CHANNEL is required}"

timeout_seconds="${HEALTH_TIMEOUT:-5}"
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "HEALTH_TIMEOUT must be a positive number of seconds"
  exit 1
fi

probe_directory=$(mktemp -d)
probe_subject="healthcheck.${probe_directory##*/}"
subscriber_pid=""
cleanup() {
  if [[ -n "$subscriber_pid" ]]; then
    kill "$subscriber_pid" 2>/dev/null || true
    wait "$subscriber_pid" 2>/dev/null || true
  fi
  rm -rf "$probe_directory"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# A regular file lets the subscriber start immediately. Opening a FIFO for
# writing before its reader exists prevents the command from starting at all.
NATS_URL="$NAT_HOST" nats --no-context sub "$probe_subject" --raw --count=1 \
  --wait="${timeout_seconds}s" > "$probe_directory/message" 2>/dev/null &
subscriber_pid=$!

# A subscription takes time to establish. Retry only this unique health message
# until it makes the complete PG NOTIFY -> GRASS -> NATS round trip. Never use a
# console banner or another probe's message as evidence that this bridge works.
deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
  if ! PGCONNECT_TIMEOUT=1 \
    PGOPTIONS='-c statement_timeout=1000' \
    psql -XqAt -d "$PG_CONNECTION" -v ON_ERROR_STOP=1 -v channel="$PG_CHANNEL" -v subject="$probe_subject" \
    > /dev/null 2>&1 <<'SQL'
SELECT pg_notify(:'channel', jsonb_build_object('subject', :'subject')::text);
SQL
  then
    echo "Failed to send GRASS health notification"
    exit 1
  fi

  if grep -Fq "\"$probe_subject\"" "$probe_directory/message"; then
    exit 0
  fi
  if ! kill -0 "$subscriber_pid" 2>/dev/null; then
    # The final message can arrive between the first read and process exit.
    if grep -Fq "\"$probe_subject\"" "$probe_directory/message"; then
      exit 0
    fi
    echo "GRASS health subscriber exited without its notification"
    exit 1
  fi
  sleep 0.1
done

if grep -Fq "\"$probe_subject\"" "$probe_directory/message"; then
  exit 0
fi
echo "GRASS health notification did not complete within ${timeout_seconds}s"
exit 1
