#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dyndns/config.env"
DOMAINS_FILE="/etc/dyndns/domains.json"
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

sql_escape() {
    echo "$1" | sed "s/'/''/g"
}

db_insert() {
    local old_ip="$1" new_ip="$2" status="$3" response="$4" message="$5" domain="$6" host="$7"
    sqlite3 "$DB_FILE" "INSERT INTO updates (old_ip, new_ip, status, response, message, domain, host) VALUES ('$(echo "$old_ip" | tr -dc '0-9.')','$(echo "$new_ip" | tr -dc '0-9.')','$status','$(sql_escape "$response")','$(sql_escape "$message")','$(sql_escape "$domain")','$(sql_escape "$host")');"
}

get_state() {
    sqlite3 "$DB_FILE" "SELECT COALESCE($1, '') FROM node_state WHERE id=1;" 2>/dev/null || echo ""
}

set_state() {
    local key="$1" value="$2"
    sqlite3 "$DB_FILE" "UPDATE node_state SET ${key}='$(sql_escape "$value")' WHERE id=1;" 2>/dev/null || true
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

get_last_ip_for() {
    local domain="$1" host="$2"
    sqlite3 "$DB_FILE" "SELECT new_ip FROM updates WHERE status='success' AND domain='$(sql_escape "$domain")' AND host='$(sql_escape "$host")' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null || echo ""
}

# Update one (domain, host) pair. Returns 0 on success/skip, 1 on failure.
update_one() {
    local domain="$1" host="$2" password="$3" new_ip="$4"
    local old_ip response err_msg
    old_ip=$(get_last_ip_for "$domain" "$host")

    if [[ "$new_ip" == "$old_ip" ]]; then
        log_msg "SKIPPED" "$new_ip unchanged | ${host}.${domain}"
        db_insert "$old_ip" "$new_ip" "skipped" "" "IP unchanged" "$domain" "$host"
        return 0
    fi

    response=$(curl -s --max-time 10 \
        "https://dynamicdns.park-your-domain.com/update?host=${host}&domain=${domain}&password=${password}&ip=${new_ip}" \
        2>/dev/null || echo "CURL_FAILED")

    if echo "$response" | grep -q '<ErrCount>0</ErrCount>'; then
        log_msg "SUCCESS" "$old_ip -> $new_ip | ${host}.${domain}"
        db_insert "$old_ip" "$new_ip" "success" "$response" "IP updated successfully" "$domain" "$host"
        return 0
    else
        err_msg=$(echo "$response" | grep -oP '<Err1>\K[^<]*' || echo "Unknown error")
        log_msg "FAILURE" "$old_ip -> $new_ip | ${host}.${domain} | $err_msg"
        db_insert "$old_ip" "$new_ip" "failure" "$response" "$err_msg" "$domain" "$host"
        return 1
    fi
}

# Iterate over all enabled (domain, host) entries. Returns 0 if at least
# one entry succeeded or was skipped, 1 if every entry failed.
do_update() {
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        log_msg "ERROR" "Domain-Liste $DOMAINS_FILE fehlt (UI öffnen oder setup.sh erneut starten)"
        db_insert "" "" "error" "" "domains.json fehlt" "" ""
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_msg "ERROR" "jq nicht installiert (apt-get install jq)"
        db_insert "" "" "error" "" "jq fehlt" "" ""
        return 1
    fi

    local enabled_count
    enabled_count=$(jq '[.domains[] | select(.enabled != false) | .hosts[] | select(.enabled != false)] | length' "$DOMAINS_FILE")
    if [[ "$enabled_count" -eq 0 ]]; then
        log_msg "SKIPPED" "Keine aktiven Hosts in domains.json"
        db_insert "" "" "skipped" "" "Keine aktiven Einträge" "" ""
        return 0
    fi

    local new_ip
    new_ip=$(get_public_ip) || {
        log_msg "ERROR" "Could not determine public IP"
        db_insert "" "" "error" "" "Could not determine public IP" "" ""
        return 1
    }

    local total=0 ok=0 fail=0

    # Build TSV stream of (domain, host, password) for all enabled host entries.
    while IFS=$'\t' read -r domain host password; do
        [[ -z "$domain" || -z "$host" ]] && continue
        total=$((total + 1))
        if [[ -z "$password" ]]; then
            log_msg "FAILURE" "${host}.${domain} | kein Passwort gesetzt"
            db_insert "" "$new_ip" "failure" "" "Kein DynDNS-Passwort hinterlegt" "$domain" "$host"
            fail=$((fail + 1))
            continue
        fi
        if update_one "$domain" "$host" "$password" "$new_ip"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done < <(jq -r '.domains[]
        | select(.enabled != false)
        | . as $d
        | .hosts[]
        | select(.enabled != false)
        | [$d.domain, .host, $d.password] | @tsv' "$DOMAINS_FILE")

    log_msg "RUN" "Domains durchlaufen: ${ok}/${total} erfolgreich, ${fail} Fehler"

    if [[ "$total" -eq 0 ]]; then
        return 0
    fi
    if [[ "$ok" -eq 0 ]]; then
        return 1
    fi
    return 0
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
            db_insert "" "" "skipped" "" "Master is active, failover on standby" "" ""
            exit 0
        fi
        ;;
    *)
        log_msg "ERROR" "Unknown role: $ROLE"
        db_insert "" "" "error" "" "Unknown DYNDNS_ROLE: $ROLE" "" ""
        exit 1
        ;;
esac
