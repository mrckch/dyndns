#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/dyndns"
CONFIG_DIR="/etc/dyndns"
CONFIG_FILE="$CONFIG_DIR/config.env"
DOMAINS_FILE="$CONFIG_DIR/domains.json"
DB_DIR="/var/lib/dyndns"
DB_FILE="$DB_DIR/history.db"
LOG_DIR="/var/log/dyndns"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Helpers ---

calc_size() {
    WT_HEIGHT=$(($(tput lines) - 4))
    WT_WIDTH=$(($(tput cols) - 10))
    [[ $WT_HEIGHT -gt 30 ]] && WT_HEIGHT=30
    [[ $WT_WIDTH -gt 80 ]] && WT_WIDTH=80
    WT_MENU_HEIGHT=$((WT_HEIGHT - 8))
}

msg() {
    whiptail --title "DynDNS Setup" --msgbox "$1" "$WT_HEIGHT" "$WT_WIDTH"
}

input() {
    local title="$1" default="$2"
    whiptail --title "DynDNS Setup" --inputbox "$title" "$WT_HEIGHT" "$WT_WIDTH" "$default" 3>&1 1>&2 2>&3
}

password() {
    whiptail --title "DynDNS Setup" --passwordbox "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3
}

yesno() {
    whiptail --title "DynDNS Setup" --yesno "$1" "$WT_HEIGHT" "$WT_WIDTH"
}

menu() {
    local title="$1"; shift
    whiptail --title "DynDNS Setup" --menu "$title" "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" "$@" 3>&1 1>&2 2>&3
}

# --- Root check ---

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Dieses Script muss als root ausgeführt werden." >&2
    exit 1
fi

calc_size

# --- Welcome ---

msg "Willkommen zum DynDNS Setup-Assistenten!\n\nDieses Script richtet einen automatischen DynDNS-Updater für NameCheap ein.\n\nDu kannst zwischen drei Betriebsarten wählen:\n\n  - Single: Nur ein einzelner Updater (kein Backup)\n  - Master: Hauptserver, der die DNS-Updates macht\n  - Failover: Backup-Server, der einspringt, wenn der Master ausfällt\n\nWenn du Master + Failover nutzt, brauchst du ZWEI LXCs auf zwei Proxmox-Hosts. Du installierst dieses Script dann auf beiden und wählst auf dem ersten 'Master' und auf dem zweiten 'Failover'.\n\nDrücke OK um fortzufahren."

# --- Role selection ---

ROLE=$(menu "Welche Rolle soll dieser Server übernehmen?\n\nFalls du nicht sicher bist: 'Single' ist der einfachste Modus." \
    "single"   "Einzelner Server (kein Backup)" \
    "master"   "Master (Hauptserver, macht die Updates)" \
    "failover" "Failover (Backup, springt bei Master-Ausfall ein)")

case "$ROLE" in
    master)
        msg "Du installierst den MASTER.\n\nDieser Server wird:\n  - Regelmäßig die öffentliche IP an NameCheap senden\n  - Vom Failover per Heartbeat überwacht\n\nNach dem Setup brauchst du:\n  1) Einen zweiten LXC auf einem anderen Proxmox-Host\n  2) Dort dieses Script erneut, mit Rolle 'Failover'\n  3) Den hier generierten Token auf dem Failover eintragen" ;;
    failover)
        msg "Du installierst den FAILOVER.\n\nDieser Server wird:\n  - Den Master regelmäßig per Heartbeat prüfen\n  - Nur DNS-Updates machen, wenn der Master ausfällt\n\nDu brauchst:\n  - Die IP/URL des Master-LXC (z.B. http://10.0.0.20:8080)\n  - Den Token, den du beim Master-Setup notiert hast" ;;
    single)
        msg "Du installierst einen EINZELNEN Server.\n\nKein Failover, kein Backup. Wenn dieser Server ausfällt, gibt es keine DNS-Updates mehr." ;;
esac

# --- Install dependencies ---

{
    echo 10; apt-get update -qq
    echo 40; apt-get install -y -qq lighttpd curl sqlite3 jq > /dev/null 2>&1
    echo 70; apt-get install -y -qq whiptail openssl > /dev/null 2>&1 || true
    echo 100
} | whiptail --title "DynDNS Setup" --gauge "Installiere Abhängigkeiten..." "$WT_HEIGHT" "$WT_WIDTH" 0

# --- Load existing config (for re-runs) ---

EXISTING_DOMAIN=""
EXISTING_HOST="@"
EXISTING_PASSWORD=""
EXISTING_INTERVAL="5"
EXISTING_PORT="8080"
EXISTING_NODE_NAME="$(hostname)"
EXISTING_PEER_URL=""
EXISTING_PEER_TOKEN=""
EXISTING_HB_INTERVAL="30"
EXISTING_FO_THRESHOLD="3"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    EXISTING_DOMAIN="${DYNDNS_DOMAIN:-}"
    EXISTING_HOST="${DYNDNS_HOST:-@}"
    EXISTING_PASSWORD="${DYNDNS_PASSWORD:-}"
    EXISTING_INTERVAL="${DYNDNS_INTERVAL:-5}"
    EXISTING_PORT="${DYNDNS_WEB_PORT:-8080}"
    EXISTING_NODE_NAME="${DYNDNS_NODE_NAME:-$(hostname)}"
    EXISTING_PEER_URL="${DYNDNS_PEER_URL:-}"
    EXISTING_PEER_TOKEN="${DYNDNS_PEER_TOKEN:-}"
    EXISTING_HB_INTERVAL="${DYNDNS_HEARTBEAT_INTERVAL:-30}"
    EXISTING_FO_THRESHOLD="${DYNDNS_FAILOVER_THRESHOLD:-3}"
fi

# If domains.json already exists, prefer its first entry for defaults.
if [[ -f "$DOMAINS_FILE" ]] && command -v jq >/dev/null 2>&1; then
    FIRST_DOMAIN=$(jq -r '.domains[0].domain // ""' "$DOMAINS_FILE" 2>/dev/null || echo "")
    FIRST_HOST=$(jq -r '.domains[0].hosts[0].host // "@"' "$DOMAINS_FILE" 2>/dev/null || echo "@")
    FIRST_PW=$(jq -r '.domains[0].password // ""' "$DOMAINS_FILE" 2>/dev/null || echo "")
    [[ -n "$FIRST_DOMAIN" ]] && EXISTING_DOMAIN="$FIRST_DOMAIN"
    [[ -n "$FIRST_HOST" ]] && EXISTING_HOST="$FIRST_HOST"
    [[ -n "$FIRST_PW" ]] && EXISTING_PASSWORD="$FIRST_PW"
fi

# --- Node name ---

NODE_NAME=$(input "Name dieses Servers (wird im Dashboard angezeigt, z.B. 'lxc-master-pve1'):" "$EXISTING_NODE_NAME")
[[ -z "$NODE_NAME" ]] && NODE_NAME="$(hostname)"

# --- Domain ---

while true; do
    DOMAIN=$(input "Domain-Name eingeben:\n\nBeispiel: meinedomain.de\n(Die Domain, die du bei NameCheap registriert hast.)" "$EXISTING_DOMAIN")
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
        break
    fi
    msg "Ungültiger Domain-Name. Bitte erneut eingeben."
done

# --- Host ---

HOST=$(input "Host-Record:\n\n  '@'  = Hauptdomain (also meinedomain.de)\n  'www' = www.meinedomain.de\n  'home' = home.meinedomain.de\n\nMeistens passt '@'." "$EXISTING_HOST")
[[ -z "$HOST" ]] && HOST="@"

# --- DynDNS Password ---

DDNS_PASS=""
if [[ -n "${EXISTING_PASSWORD:-}" ]]; then
    if yesno "Bestehendes NameCheap DynDNS-Passwort wiederverwenden?\n\nWähle 'Nein', um es neu einzugeben."; then
        DDNS_PASS="$EXISTING_PASSWORD"
    fi
fi

if [[ -z "$DDNS_PASS" ]]; then
    msg "Du brauchst jetzt das NameCheap DynDNS-Passwort.\n\nSo findest du es:\n  1) Auf namecheap.com einloggen\n  2) Domain-Liste -> 'Manage' bei deiner Domain\n  3) Tab 'Advanced DNS'\n  4) Abschnitt 'Dynamic DNS' -> aktivieren falls nicht aktiv\n  5) Das angezeigte Passwort kopieren (32 Zeichen, hex)\n\nWICHTIG: Beide Server (Master und Failover) brauchen das GLEICHE Passwort."
    while true; do
        DDNS_PASS=$(password "NameCheap DynDNS-Passwort eingeben:")
        if [[ -n "$DDNS_PASS" ]]; then
            break
        fi
        msg "Passwort darf nicht leer sein."
    done
fi

# --- Update interval ---

while true; do
    INTERVAL=$(input "Wie oft soll geprüft werden, ob sich die IP geändert hat?\n\nEingabe in Minuten (1-60). Empfohlen: 5" "$EXISTING_INTERVAL")
    if [[ "$INTERVAL" =~ ^[0-9]+$ ]] && [[ "$INTERVAL" -ge 1 ]] && [[ "$INTERVAL" -le 60 ]]; then
        break
    fi
    msg "Ungültiges Intervall. Bitte eine Zahl zwischen 1 und 60 eingeben."
done

# --- Web port ---

while true; do
    WEB_PORT=$(input "Auf welchem Port soll das Web-Dashboard erreichbar sein?\n\nStandard: 8080 (passt fast immer)" "$EXISTING_PORT")
    if [[ "$WEB_PORT" =~ ^[0-9]+$ ]] && [[ "$WEB_PORT" -ge 1024 ]] && [[ "$WEB_PORT" -le 65535 ]]; then
        break
    fi
    msg "Ungültiger Port. Bitte eine Zahl zwischen 1024 und 65535 eingeben."
done

# --- Failover-specific config ---

PEER_URL=""
PEER_TOKEN=""
HB_INTERVAL="$EXISTING_HB_INTERVAL"
FO_THRESHOLD="$EXISTING_FO_THRESHOLD"

if [[ "$ROLE" == "master" ]]; then
    msg "Failover-Token wird jetzt generiert.\n\nDieser Token sichert die Kommunikation zwischen Master und Failover ab. Du musst ihn auf dem Failover-Server eingeben.\n\nIm nächsten Schritt wird er angezeigt - bitte kopieren!"

    if [[ -n "$EXISTING_PEER_TOKEN" ]] && yesno "Es existiert bereits ein Token. Beibehalten?\n\n(Wähle 'Nein' für einen neuen Token. Achtung: Dann musst du den neuen Token auch auf dem Failover-Server eintragen.)"; then
        PEER_TOKEN="$EXISTING_PEER_TOKEN"
    else
        PEER_TOKEN=$(openssl rand -hex 32)
    fi

    msg "Dein Failover-Token:\n\n$PEER_TOKEN\n\nBitte JETZT kopieren und sicher aufbewahren!\n\nDu wirst ihn auf dem Failover-Server beim Setup eingeben müssen."

    if yesno "Kennst du schon die IP/URL des Failover-Servers?\n\n(Du kannst sie auch später im Dashboard nachtragen.)"; then
        while true; do
            PEER_URL=$(input "URL des Failover-Servers:\n\nBeispiel: http://10.0.0.21:8080" "$EXISTING_PEER_URL")
            if [[ -z "$PEER_URL" ]] || [[ "$PEER_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
                break
            fi
            msg "Ungültige URL. Format: http://IP:PORT"
        done
    fi

    HB_INTERVAL=$(input "Heartbeat-Intervall in Sekunden (10-300):\n\nWie oft beide Server gegenseitig pingen.\nEmpfohlen: 30" "$EXISTING_HB_INTERVAL")
    [[ "$HB_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$HB_INTERVAL" -ge 10 ]] && [[ "$HB_INTERVAL" -le 300 ]] || HB_INTERVAL=30

    FO_THRESHOLD=$(input "Failover-Schwelle (1-20):\n\nWie viele aufeinanderfolgende fehlgeschlagene Heartbeats, bis der Failover übernimmt?\nEmpfohlen: 3 (= ca. 90s Reaktionszeit bei 30s Heartbeat)" "$EXISTING_FO_THRESHOLD")
    [[ "$FO_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$FO_THRESHOLD" -ge 1 ]] && [[ "$FO_THRESHOLD" -le 20 ]] || FO_THRESHOLD=3

elif [[ "$ROLE" == "failover" ]]; then
    msg "Du brauchst jetzt:\n  1) Die URL des Master-Servers (z.B. http://10.0.0.20:8080)\n  2) Den Failover-Token, den du beim Master-Setup notiert hast"

    while true; do
        PEER_URL=$(input "URL des Master-Servers:\n\nBeispiel: http://10.0.0.20:8080" "$EXISTING_PEER_URL")
        if [[ "$PEER_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
            break
        fi
        msg "Ungültige URL. Format: http://IP:PORT"
    done

    while true; do
        PEER_TOKEN=$(input "Failover-Token (vom Master kopiert):" "$EXISTING_PEER_TOKEN")
        if [[ ${#PEER_TOKEN} -ge 16 ]]; then
            break
        fi
        msg "Token zu kurz oder leer (mind. 16 Zeichen)."
    done

    HB_INTERVAL=$(input "Heartbeat-Intervall in Sekunden (10-300):\n\nMuss zum Master passen. Empfohlen: 30" "$EXISTING_HB_INTERVAL")
    [[ "$HB_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$HB_INTERVAL" -ge 10 ]] && [[ "$HB_INTERVAL" -le 300 ]] || HB_INTERVAL=30

    FO_THRESHOLD=$(input "Failover-Schwelle (1-20):\n\nNach wie vielen fehlgeschlagenen Heartbeats übernimmt der Failover?\nEmpfohlen: 3" "$EXISTING_FO_THRESHOLD")
    [[ "$FO_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$FO_THRESHOLD" -ge 1 ]] && [[ "$FO_THRESHOLD" -le 20 ]] || FO_THRESHOLD=3
fi

# --- Web auth ---

WEB_AUTH_ENABLED="false"
WEB_AUTH_USER=""
WEB_AUTH_PASS=""
if yesno "Soll das Web-Dashboard mit einem Passwort geschützt werden?\n\nEmpfohlen: JA, wenn der LXC vom Internet erreichbar ist.\nNicht zwingend nötig im internen LAN."; then
    WEB_AUTH_ENABLED="true"
    WEB_AUTH_USER=$(input "Benutzername für das Web-Dashboard:" "admin")
    while true; do
        WEB_AUTH_PASS=$(password "Passwort für das Web-Dashboard:")
        if [[ -n "$WEB_AUTH_PASS" ]]; then
            break
        fi
        msg "Passwort darf nicht leer sein."
    done
fi

# --- Confirmation summary ---

SUMMARY="Bitte überprüfe die Einstellungen:\n\n"
SUMMARY+="Rolle:        $ROLE\n"
SUMMARY+="Servername:   $NODE_NAME\n"
SUMMARY+="Domain:       $HOST.$DOMAIN\n"
SUMMARY+="Intervall:    alle $INTERVAL Min.\n"
SUMMARY+="Web-Port:     $WEB_PORT\n"
SUMMARY+="Web-Auth:     $WEB_AUTH_ENABLED\n"
if [[ "$ROLE" != "single" ]]; then
    SUMMARY+="Peer-URL:     ${PEER_URL:-(später eintragen)}\n"
    SUMMARY+="Heartbeat:    alle ${HB_INTERVAL}s\n"
    SUMMARY+="FO-Schwelle:  $FO_THRESHOLD Fails\n"
fi
SUMMARY+="\nJetzt installieren?"

if ! yesno "$SUMMARY"; then
    msg "Abgebrochen. Es wurde nichts installiert."
    exit 1
fi

# --- Create directories ---

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DB_DIR" "$LOG_DIR"
mkdir -p "$INSTALL_DIR/web/cgi-bin" "$INSTALL_DIR/web/static" "$INSTALL_DIR/web/peer-cgi"

# --- Write config ---

cat > "$CONFIG_FILE" <<EOF
DYNDNS_ROLE=$ROLE
DYNDNS_NODE_NAME=$NODE_NAME
DYNDNS_INTERVAL=$INTERVAL
DYNDNS_WEB_PORT=$WEB_PORT
DYNDNS_WEB_AUTH_ENABLED=$WEB_AUTH_ENABLED
DYNDNS_WEB_AUTH_USER=$WEB_AUTH_USER
DYNDNS_PEER_URL=$PEER_URL
DYNDNS_PEER_TOKEN=$PEER_TOKEN
DYNDNS_HEARTBEAT_INTERVAL=$HB_INTERVAL
DYNDNS_FAILOVER_THRESHOLD=$FO_THRESHOLD
EOF

chmod 0640 "$CONFIG_FILE"
chown root:www-data "$CONFIG_FILE"

# --- Write/merge domains.json ---

DOMAIN_ID=$(openssl rand -hex 16)

if [[ -f "$DOMAINS_FILE" ]]; then
    # Preserve other domains; replace/insert the one the user just entered.
    TMP_DOM=$(mktemp)
    jq --arg id "$DOMAIN_ID" \
       --arg domain "$DOMAIN" \
       --arg host "$HOST" \
       --arg password "$DDNS_PASS" \
       '
       .domains = (.domains // []) |
       (.domains | map(.domain | ascii_downcase) | index($domain | ascii_downcase)) as $idx |
       if $idx == null then
           .domains += [{
               id: $id,
               domain: ($domain | ascii_downcase),
               password: $password,
               enabled: true,
               hosts: [{host: $host, enabled: true}]
           }]
       else
           .domains[$idx].password = $password |
           .domains[$idx].enabled = true |
           (.domains[$idx].hosts | map(.host) | index($host)) as $hidx |
           if $hidx == null then
               .domains[$idx].hosts += [{host: $host, enabled: true}]
           else
               .domains[$idx].hosts[$hidx].enabled = true
           end
       end
       ' "$DOMAINS_FILE" > "$TMP_DOM"
    mv "$TMP_DOM" "$DOMAINS_FILE"
else
    cat > "$DOMAINS_FILE" <<EOF
{
  "domains": [
    {
      "id": "$DOMAIN_ID",
      "domain": "$DOMAIN",
      "password": "$DDNS_PASS",
      "enabled": true,
      "hosts": [
        { "host": "$HOST", "enabled": true }
      ]
    }
  ]
}
EOF
fi

chmod 0640 "$DOMAINS_FILE"
chown root:www-data "$DOMAINS_FILE"

# --- Web auth setup ---

if [[ "$WEB_AUTH_ENABLED" == "true" ]]; then
    HTDIGEST_FILE="$CONFIG_DIR/htdigest"
    REALM="DynDNS Dashboard"
    HASH=$(printf '%s:%s:%s' "$WEB_AUTH_USER" "$REALM" "$WEB_AUTH_PASS" | md5sum | awk '{print $1}')
    echo "${WEB_AUTH_USER}:${REALM}:${HASH}" > "$HTDIGEST_FILE"
    chmod 0640 "$HTDIGEST_FILE"
    chown root:www-data "$HTDIGEST_FILE"
fi

# --- Initialize database ---

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS updates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    old_ip TEXT,
    new_ip TEXT,
    status TEXT NOT NULL CHECK(status IN ('success', 'failure', 'skipped', 'error')),
    response TEXT,
    message TEXT,
    domain TEXT,
    host TEXT
);
CREATE INDEX IF NOT EXISTS idx_updates_timestamp ON updates(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_updates_domain_host ON updates(domain, host, timestamp DESC);

CREATE TABLE IF NOT EXISTS node_state (
    id INTEGER PRIMARY KEY CHECK (id=1),
    is_active INTEGER DEFAULT 0,
    force_active INTEGER DEFAULT 0,
    peer_healthy INTEGER DEFAULT 0,
    peer_consecutive_fails INTEGER DEFAULT 0,
    peer_last_seen TEXT,
    peer_role TEXT,
    peer_ip TEXT,
    peer_last_update TEXT,
    peer_last_status TEXT,
    peer_is_active INTEGER DEFAULT 0,
    peer_last_error TEXT,
    last_takeover_at TEXT,
    last_release_at TEXT
);
INSERT OR IGNORE INTO node_state (id, is_active) VALUES (1, 0);
SQL

# Idempotent ALTER for upgrades from older installs that lack domain/host columns.
if ! sqlite3 "$DB_FILE" "PRAGMA table_info(updates);" | grep -q "|domain|"; then
    sqlite3 "$DB_FILE" "ALTER TABLE updates ADD COLUMN domain TEXT;"
fi
if ! sqlite3 "$DB_FILE" "PRAGMA table_info(updates);" | grep -q "|host|"; then
    sqlite3 "$DB_FILE" "ALTER TABLE updates ADD COLUMN host TEXT;"
fi
sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_updates_domain_host ON updates(domain, host, timestamp DESC);"

# Master is always active by default
if [[ "$ROLE" == "master" ]] || [[ "$ROLE" == "single" ]]; then
    sqlite3 "$DB_FILE" "UPDATE node_state SET is_active=1 WHERE id=1;"
fi

chmod 0664 "$DB_FILE"
chown root:www-data "$DB_FILE"
chown root:www-data "$DB_DIR"

# --- Install application files ---

cp "$SCRIPT_DIR/updater.sh" "$INSTALL_DIR/updater.sh"
chmod +x "$INSTALL_DIR/updater.sh"

cp "$SCRIPT_DIR/heartbeat.sh" "$INSTALL_DIR/heartbeat.sh"
chmod +x "$INSTALL_DIR/heartbeat.sh"

cp "$SCRIPT_DIR/web/cgi-bin/api.py" "$INSTALL_DIR/web/cgi-bin/api.py"
chmod +x "$INSTALL_DIR/web/cgi-bin/api.py"

cp "$SCRIPT_DIR/web/peer-cgi/heartbeat.py" "$INSTALL_DIR/web/peer-cgi/heartbeat.py"
chmod +x "$INSTALL_DIR/web/peer-cgi/heartbeat.py"

cp "$SCRIPT_DIR/web/static/"* "$INSTALL_DIR/web/static/"

# --- Configure lighttpd ---

LIGHTTPD_CONF="/etc/lighttpd/conf-available/90-dyndns.conf"
cp "$SCRIPT_DIR/config/90-dyndns.conf" "$LIGHTTPD_CONF"

sed -i "s/:8080/:${WEB_PORT}/" "$LIGHTTPD_CONF"

if [[ "$WEB_AUTH_ENABLED" == "true" ]]; then
    cat >> "$LIGHTTPD_CONF" <<EOF

server.modules += ("mod_auth", "mod_authn_file")
auth.backend = "htdigest"
auth.backend.htdigest.userfile = "$CONFIG_DIR/htdigest"
\$HTTP["url"] !~ "^/peer/" {
    auth.require = ("/" => (
        "method" => "digest",
        "realm" => "DynDNS Dashboard",
        "require" => "valid-user"
    ))
}
EOF
fi

lighty-enable-mod cgi 2>/dev/null || true
ln -sf "$LIGHTTPD_CONF" /etc/lighttpd/conf-enabled/90-dyndns.conf 2>/dev/null || true
systemctl restart lighttpd

# --- Install systemd units ---

cp "$SCRIPT_DIR/config/dyndns-update.service" /etc/systemd/system/
cp "$SCRIPT_DIR/config/dyndns-update.timer" /etc/systemd/system/
cp "$SCRIPT_DIR/config/dyndns-heartbeat.service" /etc/systemd/system/
cp "$SCRIPT_DIR/config/dyndns-heartbeat.timer" /etc/systemd/system/

sed -i "s/OnUnitActiveSec=5min/OnUnitActiveSec=${INTERVAL}min/" /etc/systemd/system/dyndns-update.timer
sed -i "s/OnUnitActiveSec=30s/OnUnitActiveSec=${HB_INTERVAL}s/" /etc/systemd/system/dyndns-heartbeat.timer
sed -i "s/OnBootSec=30s/OnBootSec=${HB_INTERVAL}s/" /etc/systemd/system/dyndns-heartbeat.timer

# Sudoers for www-data to control timers (needed for settings page changes)
cat > /etc/sudoers.d/dyndns <<'EOF'
Cmnd_Alias DYNDNS_CTL = /bin/systemctl daemon-reload, \
    /bin/systemctl restart dyndns-update.timer, \
    /bin/systemctl restart dyndns-heartbeat.timer, \
    /bin/systemctl enable dyndns-heartbeat.timer, \
    /bin/systemctl enable --now dyndns-heartbeat.timer, \
    /bin/systemctl disable dyndns-heartbeat.timer, \
    /bin/systemctl stop dyndns-heartbeat.timer, \
    /bin/systemctl restart lighttpd
www-data ALL=(root) NOPASSWD: DYNDNS_CTL
EOF
chmod 0440 /etc/sudoers.d/dyndns
visudo -cf /etc/sudoers.d/dyndns >/dev/null

systemctl daemon-reload
systemctl enable --now dyndns-update.timer

if [[ "$ROLE" != "single" ]]; then
    systemctl enable --now dyndns-heartbeat.timer
else
    systemctl disable dyndns-heartbeat.timer 2>/dev/null || true
    systemctl stop dyndns-heartbeat.timer 2>/dev/null || true
fi

# --- Install logrotate ---

cp "$SCRIPT_DIR/config/logrotate-dyndns" /etc/logrotate.d/dyndns

# --- Run initial test ---

msg "Konfiguration abgeschlossen!\n\nFühre jetzt einen ersten Test durch..."

TEST_OUTPUT=""
if "$INSTALL_DIR/updater.sh" 2>&1; then
    CURRENT_IP=$(sqlite3 "$DB_FILE" "SELECT new_ip FROM updates ORDER BY timestamp DESC LIMIT 1;")
    TEST_STATUS="ERFOLGREICH"
else
    CURRENT_IP="Unbekannt"
    TEST_STATUS="FEHLGESCHLAGEN"
    TEST_OUTPUT=$(sqlite3 "$DB_FILE" "SELECT message FROM updates ORDER BY timestamp DESC LIMIT 1;")
fi

# Optional peer test
PEER_TEST=""
if [[ "$ROLE" != "single" ]] && [[ -n "$PEER_URL" ]]; then
    if "$INSTALL_DIR/heartbeat.sh" 2>&1; then
        PEER_HEALTHY=$(sqlite3 "$DB_FILE" "SELECT peer_healthy FROM node_state WHERE id=1;")
        if [[ "$PEER_HEALTHY" == "1" ]]; then
            PEER_TEST="\nPeer:       Erreichbar"
        else
            PEER_TEST="\nPeer:       Nicht erreichbar (eventuell noch nicht installiert?)"
        fi
    fi
fi

# --- Summary ---

LXC_IP=$(hostname -I | awk '{print $1}')

NEXT_STEPS=""
case "$ROLE" in
    master)
        if [[ -z "$PEER_URL" ]]; then
            NEXT_STEPS="\n\nNächste Schritte:\n  1) Failover-LXC auf zweitem Proxmox-Host erstellen\n  2) Dort dieses Script erneut ausführen, Rolle 'Failover' wählen\n  3) Token eintragen: ${PEER_TOKEN}\n  4) Anschließend hier im Dashboard die Peer-URL nachtragen"
        else
            NEXT_STEPS="\n\nNächste Schritte:\n  - Failover-LXC einrichten falls noch nicht geschehen\n  - Token: ${PEER_TOKEN}"
        fi
        ;;
    failover)
        NEXT_STEPS="\n\nDieser Server steht jetzt im Standby. Er übernimmt automatisch, falls der Master ausfällt."
        ;;
esac

msg "Setup abgeschlossen!\n\n\
Status:     $TEST_STATUS\n\
Rolle:      $ROLE\n\
Domain:     $HOST.$DOMAIN\n\
Aktuelle IP: $CURRENT_IP\n\
Intervall:  alle $INTERVAL Minuten${PEER_TEST}\n\
\n\
Web-Dashboard: http://$LXC_IP:$WEB_PORT\n\
${TEST_OUTPUT:+\nFehler: $TEST_OUTPUT\n}\
${NEXT_STEPS}"
