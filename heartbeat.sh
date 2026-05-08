#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dyndns/config.env"
DB_FILE="/var/lib/dyndns/history.db"
LOG_FILE="/var/log/dyndns/heartbeat.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

ROLE="${DYNDNS_ROLE:-single}"
PEER_URL="${DYNDNS_PEER_URL:-}"
PEER_TOKEN="${DYNDNS_PEER_TOKEN:-}"
NODE_NAME="${DYNDNS_NODE_NAME:-$(hostname)}"

if [[ "$ROLE" == "single" ]] || [[ -z "$PEER_URL" ]] || [[ -z "$PEER_TOKEN" ]]; then
    exit 0
fi

log_msg() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$timestamp | [$ROLE] | $1" >> "$LOG_FILE"
}

set_state() {
    local key="$1" value="$2"
    sqlite3 "$DB_FILE" "UPDATE node_state SET ${key}='$(echo "$value" | sed "s/'/''/g")' WHERE id=1;" 2>/dev/null || true
}

get_state() {
    sqlite3 "$DB_FILE" "SELECT COALESCE($1, '') FROM node_state WHERE id=1;" 2>/dev/null || echo ""
}

increment_fails() {
    sqlite3 "$DB_FILE" "UPDATE node_state SET peer_consecutive_fails = peer_consecutive_fails + 1 WHERE id=1;" 2>/dev/null || true
}

# --- Heartbeat-Aufruf ---

URL="${PEER_URL%/}/peer/heartbeat.py"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESPONSE=$(curl -s --max-time 5 \
    -H "X-DynDNS-Token: $PEER_TOKEN" \
    -H "X-DynDNS-Node: $NODE_NAME" \
    "$URL" 2>/dev/null || echo "")

if [[ -z "$RESPONSE" ]]; then
    increment_fails
    set_state "peer_healthy" "0"
    set_state "peer_last_error" "$NOW: connection failed"
    FAILS=$(get_state "peer_consecutive_fails")
    log_msg "FAIL: Peer $PEER_URL unreachable (consecutive=$FAILS)"
    exit 0
fi

# JSON parsen via Python (immer verfügbar auf System mit lighttpd-cgi)
PARSED=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('ok'):
        print('OK')
        print(d.get('role',''))
        print(d.get('current_ip',''))
        print(d.get('last_update',''))
        print(d.get('last_status',''))
        print(d.get('is_active','0'))
    else:
        print('ERROR')
        print(d.get('error',''))
except Exception as e:
    print('ERROR')
    print(f'parse: {e}')
" <<< "$RESPONSE" 2>/dev/null || echo "ERROR")

STATUS=$(echo "$PARSED" | sed -n '1p')

if [[ "$STATUS" == "OK" ]]; then
    PEER_ROLE=$(echo "$PARSED" | sed -n '2p')
    PEER_IP=$(echo "$PARSED" | sed -n '3p')
    PEER_LAST=$(echo "$PARSED" | sed -n '4p')
    PEER_LAST_STATUS=$(echo "$PARSED" | sed -n '5p')
    PEER_ACTIVE=$(echo "$PARSED" | sed -n '6p')

    set_state "peer_healthy" "1"
    set_state "peer_consecutive_fails" "0"
    set_state "peer_last_seen" "$NOW"
    set_state "peer_role" "$PEER_ROLE"
    set_state "peer_ip" "$PEER_IP"
    set_state "peer_last_update" "$PEER_LAST"
    set_state "peer_last_status" "$PEER_LAST_STATUS"
    set_state "peer_is_active" "$PEER_ACTIVE"
    set_state "peer_last_error" ""
    log_msg "OK: peer=$PEER_ROLE ip=$PEER_IP active=$PEER_ACTIVE"
else
    ERR=$(echo "$PARSED" | sed -n '2p')
    increment_fails
    set_state "peer_healthy" "0"
    set_state "peer_last_error" "$NOW: $ERR"
    FAILS=$(get_state "peer_consecutive_fails")
    log_msg "FAIL: $ERR (consecutive=$FAILS)"
fi
