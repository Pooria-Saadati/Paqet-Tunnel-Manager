#!/usr/bin/env bash
set -u

# Paqet resource leak guard
#
# Detects the failure mode observed on long-running/reconnecting Paqet clients:
# PACKET sockets, ~8 MiB packet mappings, file descriptors, threads and RSS grow
# together until the host enters memory pressure.
#
# Manual usage (report only by default):
#   sudo ./paqet-resource-guard.sh paqet-example.service
#
# Automatic mitigation:
#   PAQET_GUARD_ACTION=restart sudo ./paqet-resource-guard.sh paqet-example.service

SERVICE="${1:-}"

if [[ -z "$SERVICE" ]]; then
    echo "usage: $0 <paqet-systemd-service>" >&2
    exit 2
fi

# A manual run is non-destructive by default. The systemd template explicitly
# sets ACTION=restart, so enabling the timer is an explicit opt-in to restarts.
ACTION="${PAQET_GUARD_ACTION:-report}"
PACKET_SOCKET_THRESHOLD="${PAQET_GUARD_PACKET_SOCKET_THRESHOLD:-32}"
RSS_KB_THRESHOLD="${PAQET_GUARD_RSS_KB_THRESHOLD:-524288}" # 512 MiB
THREAD_THRESHOLD="${PAQET_GUARD_THREAD_THRESHOLD:-64}"
FD_THRESHOLD="${PAQET_GUARD_FD_THRESHOLD:-128}"
COOLDOWN_SECONDS="${PAQET_GUARD_COOLDOWN_SECONDS:-600}"
LOG_DIR="${PAQET_GUARD_LOG_DIR:-/var/log/paqet-resource-guard}"
STATE_DIR="${PAQET_GUARD_STATE_DIR:-/run/paqet-resource-guard}"

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

for value in \
    "$PACKET_SOCKET_THRESHOLD" \
    "$RSS_KB_THRESHOLD" \
    "$THREAD_THRESHOLD" \
    "$FD_THRESHOLD" \
    "$COOLDOWN_SECONDS"; do
    if ! is_uint "$value"; then
        log "ERROR invalid numeric guard setting: $value" >&2
        exit 2
    fi
done

if [[ "$ACTION" != "report" && "$ACTION" != "restart" ]]; then
    log "ERROR PAQET_GUARD_ACTION must be 'report' or 'restart'" >&2
    exit 2
fi

if ! command -v systemctl >/dev/null 2>&1; then
    log "ERROR systemctl is required" >&2
    exit 2
fi

PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
if [[ -z "$PID" || "$PID" == "0" || ! -d "/proc/$PID" ]]; then
    log "INFO service=$SERVICE is not running; nothing to inspect"
    exit 0
fi

STATUS_FILE="/proc/$PID/status"
if [[ ! -r "$STATUS_FILE" ]]; then
    log "ERROR cannot read $STATUS_FILE" >&2
    exit 1
fi

RSS_KB="$(awk '/^VmRSS:/ {print $2; exit}' "$STATUS_FILE")"
THREADS="$(awk '/^Threads:/ {print $2; exit}' "$STATUS_FILE")"
RSS_KB="${RSS_KB:-0}"
THREADS="${THREADS:-0}"

FD_COUNT=0
if [[ -d "/proc/$PID/fd" ]]; then
    FD_COUNT="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
fi

# ss -0 lists PACKET sockets. These sockets were the strongest process-level
# signal in the reproduced leak and correlated 1:1 with ~8 MiB mappings.
PACKET_SOCKETS=0
if command -v ss >/dev/null 2>&1; then
    PACKET_SOCKETS="$(ss -0ap 2>/dev/null | grep -F "pid=$PID," | wc -l)"
fi

MAPPINGS_8M=0
MAPPINGS_8M_RSS_KB=0
if command -v pmap >/dev/null 2>&1; then
    read -r MAPPINGS_8M MAPPINGS_8M_RSS_KB < <(
        pmap -x "$PID" 2>/dev/null | awk '
            $2 >= 8000 && $2 <= 8100 { count++; rss += $3 }
            END { print count+0, rss+0 }
        '
    )
fi

# The optimized Paqet build used during the reproduced incident logs
# "reconnected successfully" after a successful health-triggered reconnect.
# Recording this alongside resource counts lets us correlate reconnect churn
# with packet-resource growth without changing the Paqet process itself.
ACTIVE_ENTER_TIMESTAMP="$(systemctl show "$SERVICE" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
RECONNECTS=0
if command -v journalctl >/dev/null 2>&1 && [[ -n "$ACTIVE_ENTER_TIMESTAMP" ]]; then
    RECONNECTS="$(journalctl -u "$SERVICE" --since "$ACTIVE_ENTER_TIMESTAMP" --no-pager 2>/dev/null | grep -c 'reconnected successfully' || true)"
    RECONNECTS="${RECONNECTS:-0}"
fi

BREACH_REASONS=()
(( PACKET_SOCKETS >= PACKET_SOCKET_THRESHOLD )) && BREACH_REASONS+=("packet_sockets=$PACKET_SOCKETS>=$PACKET_SOCKET_THRESHOLD")
(( RSS_KB >= RSS_KB_THRESHOLD )) && BREACH_REASONS+=("rss_kb=$RSS_KB>=$RSS_KB_THRESHOLD")
(( THREADS >= THREAD_THRESHOLD )) && BREACH_REASONS+=("threads=$THREADS>=$THREAD_THRESHOLD")
(( FD_COUNT >= FD_THRESHOLD )) && BREACH_REASONS+=("fds=$FD_COUNT>=$FD_THRESHOLD")

log "METRICS service=$SERVICE pid=$PID reconnects=$RECONNECTS packet_sockets=$PACKET_SOCKETS mappings_8m=$MAPPINGS_8M mappings_8m_rss_kb=$MAPPINGS_8M_RSS_KB fds=$FD_COUNT threads=$THREADS rss_kb=$RSS_KB action=$ACTION"

if (( ${#BREACH_REASONS[@]} == 0 )); then
    exit 0
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 0750 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

SAFE_SERVICE="${SERVICE//[^[:alnum:]._-]/_}"
STAMP="$(date +%Y%m%dT%H%M%S%z)"
SNAPSHOT="$LOG_DIR/${SAFE_SERVICE}-${STAMP}.log"

{
    echo "Paqet resource-guard diagnostic snapshot"
    echo "timestamp=$(date --iso-8601=seconds)"
    echo "service=$SERVICE"
    echo "pid=$PID"
    echo "active_enter_timestamp=$ACTIVE_ENTER_TIMESTAMP"
    echo "reconnects=$RECONNECTS"
    echo "breach=${BREACH_REASONS[*]}"
    echo "packet_sockets=$PACKET_SOCKETS"
    echo "mappings_8m=$MAPPINGS_8M"
    echo "mappings_8m_rss_kb=$MAPPINGS_8M_RSS_KB"
    echo "fds=$FD_COUNT"
    echo "threads=$THREADS"
    echo "rss_kb=$RSS_KB"
    echo
    echo "===== free -h ====="
    free -h 2>&1 || true
    echo
    echo "===== /proc/$PID/status memory/thread fields ====="
    grep -E '^(Name|State|FDSize|VmPeak|VmSize|VmHWM|VmRSS|RssAnon|RssFile|RssShmem|VmSwap|Threads):' "$STATUS_FILE" 2>&1 || true
    echo
    echo "===== smaps_rollup ====="
    cat "/proc/$PID/smaps_rollup" 2>&1 || true
    echo
    echo "===== ss -s ====="
    ss -s 2>&1 || true
    echo
    echo "===== PACKET sockets for PID ====="
    ss -0ap 2>&1 | grep -F "pid=$PID," || true
    echo
    echo "===== top mappings ====="
    pmap -x "$PID" 2>&1 | sort -k3 -nr | head -40 || true
    echo
    echo "===== recent service journal ====="
    journalctl -u "$SERVICE" --since '-15 minutes' --no-pager 2>&1 | tail -400 || true
} >"$SNAPSHOT" 2>&1

log "WARN resource threshold breached: ${BREACH_REASONS[*]} snapshot=$SNAPSHOT"
logger -t paqet-resource-guard "service=$SERVICE breach=${BREACH_REASONS[*]} snapshot=$SNAPSHOT" 2>/dev/null || true

if [[ "$ACTION" != "restart" ]]; then
    log "INFO report-only mode; service was not restarted"
    exit 1
fi

STATE_FILE="$STATE_DIR/${SAFE_SERVICE}.last-restart"
NOW="$(date +%s)"
LAST=0
if [[ -r "$STATE_FILE" ]]; then
    LAST="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
    is_uint "$LAST" || LAST=0
fi

if (( NOW - LAST < COOLDOWN_SECONDS )); then
    log "WARN restart suppressed by cooldown (${COOLDOWN_SECONDS}s)"
    exit 1
fi

printf '%s\n' "$NOW" >"$STATE_FILE"
log "WARN restarting $SERVICE to release leaked packet resources"

if systemctl restart "$SERVICE"; then
    sleep 2
    NEW_PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
    log "INFO restart successful old_pid=$PID new_pid=${NEW_PID:-unknown}"
    exit 0
fi

log "ERROR restart failed for $SERVICE" >&2
exit 1
