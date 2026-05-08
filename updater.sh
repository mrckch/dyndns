#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dyndns/config.env"
DB_FILE="/var/lib/dyndns/history.db"
LOG_FILE="/var/log/dyndns/update.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file $CONFIG_FILE not found. Run setup.sh first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

ROLE="${DYNDNS_ROLE:-single}"
FAILOVER_THRESHOLD="${DYNDNS_FAILOVER_THRESHOLD:-3}"

log_msg() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$timestamp | [$ROLE] | $1 | $2" >> "$LOG_FILE"
}

db_insert() {
    local old_ip="$1" new_ip="$2" status="$3" response="$4" message="$5"
    sqlite3 "$DB_FILE" "INSERT INTO updates (old_ip, new_ip, status, response, message) VALUES ('$(echo "$old_ip" | tr -dc '0-9.')','$(echo "$new_ip" | tr -dc '0-9.')','$status','$(echo "$response" | sed "s/'/''/g")','$(echo "$message" | sed "s/'/''/g")');"
}

get_state() {
    sqlite3 "$DB_FILE" "SELECT COALESCE($1, '') FROM node_state WHERE id=1;" 2>/dev/null || echo ""
}

set_state() {
    local key="$1" value="$2"
    sqlite3 "$DB_FILE" "UPDATE node_state SET ${key}='$(echo "$value" | sed "s/'/''/g")' WHERE id=1;" 2>/dev/null || true
}

get_public_ip() {
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
    )
    for svc in "${services[@]}"; do
        ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -dc '0-9.' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

get_last_ip() {
    sqlite3 "$DB_FILE" "SELECT new_ip FROM updates WHERE status='success' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null || echo ""
}

do_update() {
    local NEW_IP OLD_IP RESPONSE ERR_MSG
    NEW_IP=$(get_public_ip) || {
        log_msg "ERROR" "Could not determine public IP"
        db_insert "" "" "error" "" "Could not determine public IP"
        return 1
    }

    OLD_IP=$(get_last_ip)

    if [[ "$NEW_IP" == "$OLD_IP" ]]; then
        log_msg "SKIPPED" "$NEW_IP unchanged | ${DYNDNS_DOMAIN}"
        db_insert "$OLD_IP" "$NEW_IP" "skipped" "" "IP unchanged"
        return 0
    fi

    RESPONSE=$(curl -s --max-time 10 \
        "https://dynamicdns.park-your-domain.com/update?host=${DYNDNS_HOST}&domain=${DYNDNS_DOMAIN}&password=${DYNDNS_PASSWORD}&ip=${NEW_IP}" \
        2>/dev/null || echo "CURL_FAILED")

    if echo "$RESPONSE" | grep -q '<ErrCount>0</ErrCount>'; then
        log_msg "SUCCESS" "$OLD_IP -> $NEW_IP | ${DYNDNS_DOMAIN}"
        db_insert "$OLD_IP" "$NEW_IP" "success" "$RESPONSE" "IP updated successfully"
        return 0
    else
        ERR_MSG=$(echo "$RESPONSE" | grep -oP '<Err1>\K[^<]*' || echo "Unknown error")
        log_msg "FAILURE" "$OLD_IP -> $NEW_IP | ${DYNDNS_DOMAIN} | $ERR_MSG"
        db_insert "$OLD_IP" "$NEW_IP" "failure" "$RESPONSE" "$ERR_MSG"
        return 1
    fi
}

# --- Rollen-Logik ---

case "$ROLE" in
    master|single)
        do_update
        exit $?
        ;;
    failover)
        FORCE_ACTIVE=$(get_state "force_active")
        PEER_FAILS=$(get_state "peer_consecutive_fails")
        PEER_FAILS=${PEER_FAILS:-0}

        if [[ "$FORCE_ACTIVE" == "1" ]]; then
            log_msg "TAKEOVER" "Manual override active, performing update"
            set_state "is_active" "1"
            do_update
            exit $?
        fi

        if [[ "$PEER_FAILS" -ge "$FAILOVER_THRESHOLD" ]]; then
            log_msg "TAKEOVER" "Master unreachable ($PEER_FAILS fails >= $FAILOVER_THRESHOLD), taking over"
            CURRENT_ACTIVE=$(get_state "is_active")
            if [[ "$CURRENT_ACTIVE" != "1" ]]; then
                set_state "is_active" "1"
                set_state "last_takeover_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            fi
            do_update
            exit $?
        else
            log_msg "STANDBY" "Master healthy (fails=$PEER_FAILS), no action"
            CURRENT_ACTIVE=$(get_state "is_active")
            if [[ "$CURRENT_ACTIVE" == "1" ]]; then
                set_state "is_active" "0"
                set_state "last_release_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            fi
            db_insert "" "" "skipped" "" "Master is active, failover on standby"
            exit 0
        fi
        ;;
    *)
        log_msg "ERROR" "Unknown role: $ROLE"
        db_insert "" "" "error" "" "Unknown DYNDNS_ROLE: $ROLE"
        exit 1
        ;;
esac
