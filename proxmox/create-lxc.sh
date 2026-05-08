#!/usr/bin/env bash
#
# DynDNS LXC Installer für Proxmox VE
#
# Erstellt einen unprivilegierten LXC-Container mit komfortablen Specs
# (1 vCPU, 256 MB RAM, 128 MB Swap, 4 GB Disk) und installiert darin den
# DynDNS-Updater für NameCheap.
#
# Aufruf auf dem Proxmox-Host (als root):
#   bash <(curl -sL https://raw.githubusercontent.com/mrckch/dyndns/main/proxmox/create-lxc.sh)
#

set -euo pipefail

REPO_URL="https://github.com/mrckch/dyndns.git"

# --- Specs (komfortabel) ---
LXC_CORES=1
LXC_MEMORY=256
LXC_SWAP=128
LXC_DISK=4

# --- whiptail helpers ---

WT_HEIGHT=20
WT_WIDTH=72
WT_MENU_HEIGHT=12

msg()      { whiptail --title "DynDNS LXC Installer" --msgbox "$1" "$WT_HEIGHT" "$WT_WIDTH"; }
input()    { whiptail --title "DynDNS LXC Installer" --inputbox "$1" "$WT_HEIGHT" "$WT_WIDTH" "$2" 3>&1 1>&2 2>&3; }
password() { whiptail --title "DynDNS LXC Installer" --passwordbox "$1" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3; }
yesno()    { whiptail --title "DynDNS LXC Installer" --yesno "$1" "$WT_HEIGHT" "$WT_WIDTH"; }
menu()     { local title="$1"; shift; whiptail --title "DynDNS LXC Installer" --menu "$title" "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" "$@" 3>&1 1>&2 2>&3; }

cancel() { echo "Abgebrochen."; exit 0; }

# --- Pre-checks ---

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Bitte als root ausführen." >&2
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    echo "ERROR: 'pct' nicht gefunden. Dieses Script läuft nur auf einem Proxmox VE Host." >&2
    exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq whiptail
fi

# --- Welcome ---

msg "DynDNS LXC Installer für Proxmox VE\n\nDieses Script erstellt einen unprivilegierten LXC-Container und installiert darin den DynDNS-Updater für NameCheap.\n\nVoreingestellt:\n  - $LXC_CORES vCPU, $LXC_MEMORY MB RAM, $LXC_SWAP MB Swap, $LXC_DISK GB Disk\n  - Debian Standard (13 bevorzugt, 12 als Fallback), unprivileged, Auto-Start\n\nDu wirst nur nach dem Wesentlichen gefragt:\n  - Rolle (Master / Failover / Single)\n  - IP-Adresse\n  - Root-Passwort"

# --- Role ---

ROLE=$(menu "Welche Rolle soll der LXC haben?" \
    "single"   "Single (einzelner Updater, kein Backup)" \
    "master"   "Master (Hauptserver)" \
    "failover" "Failover (Backup-Server)") || cancel

case "$ROLE" in
    master)   DEFAULT_HOSTNAME="dyndns-master" ;;
    failover) DEFAULT_HOSTNAME="dyndns-failover" ;;
    single)   DEFAULT_HOSTNAME="dyndns" ;;
esac

# --- VMID ---

NEXT_VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
while true; do
    VMID=$(input "Container-ID (VMID):\n\nVorschlag: nächste freie ID auf diesem Host." "$NEXT_VMID") || cancel
    if [[ "$VMID" =~ ^[0-9]+$ ]] && [[ "$VMID" -ge 100 ]]; then
        if pct status "$VMID" >/dev/null 2>&1 || qm status "$VMID" >/dev/null 2>&1; then
            msg "VMID $VMID ist bereits vergeben. Bitte eine andere wählen."
            continue
        fi
        break
    fi
    msg "Ungültige VMID (muss >=100 sein)."
done

# --- Hostname ---

HOSTNAME=$(input "Hostname für den LXC:" "$DEFAULT_HOSTNAME") || cancel
HOSTNAME=$(echo "$HOSTNAME" | tr -dc 'a-zA-Z0-9-')
[[ -z "$HOSTNAME" ]] && HOSTNAME="$DEFAULT_HOSTNAME"

# --- Storage (Container-Disk) ---

STORAGE_OPTIONS=()
while IFS= read -r s; do
    [[ -n "$s" ]] && STORAGE_OPTIONS+=("$s" "")
done < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')

if [[ ${#STORAGE_OPTIONS[@]} -eq 0 ]]; then
    msg "Kein Storage mit Container-Support gefunden.\n\nBitte konfiguriere zuerst einen Storage in Proxmox\n(Datacenter -> Storage -> Add)\nund stelle sicher, dass 'Container' als Content aktiviert ist."
    exit 1
elif [[ ${#STORAGE_OPTIONS[@]} -eq 2 ]]; then
    STORAGE="${STORAGE_OPTIONS[0]}"
else
    STORAGE=$(menu "Storage für die Container-Disk:" "${STORAGE_OPTIONS[@]}") || cancel
fi

# --- Bridge ---

BRIDGE_OPTIONS=()
while IFS= read -r b; do
    [[ -n "$b" ]] && BRIDGE_OPTIONS+=("$b" "")
done < <(awk '/^iface vmbr/ {print $2}' /etc/network/interfaces 2>/dev/null)

if [[ ${#BRIDGE_OPTIONS[@]} -eq 0 ]]; then
    BRIDGE="vmbr0"
elif [[ ${#BRIDGE_OPTIONS[@]} -eq 2 ]]; then
    BRIDGE="${BRIDGE_OPTIONS[0]}"
else
    BRIDGE=$(menu "Netzwerk-Bridge:" "${BRIDGE_OPTIONS[@]}") || cancel
fi

# --- Network ---

USE_DHCP=false
IP_CIDR=""
GATEWAY=""

if yesno "Statische IP-Adresse zuweisen?\n\nWähle 'Nein' für DHCP."; then
    while true; do
        IP_CIDR=$(input "IP-Adresse mit Subnetz-Präfix:\n\nBeispiel: 10.0.0.20/24" "") || cancel
        if [[ "$IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            break
        fi
        msg "Ungültiges Format. Beispiel: 10.0.0.20/24"
    done

    DEFAULT_GW=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}' || true)
    while true; do
        GATEWAY=$(input "Gateway:" "$DEFAULT_GW") || cancel
        if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        msg "Ungültige Gateway-IP."
    done
else
    USE_DHCP=true
fi

# --- Password ---

while true; do
    PASS=$(password "Root-Passwort für den LXC (mind. 8 Zeichen):") || cancel
    if [[ ${#PASS} -lt 8 ]]; then
        msg "Passwort zu kurz (mindestens 8 Zeichen)."
        continue
    fi
    PASS_CONFIRM=$(password "Passwort wiederholen:") || cancel
    if [[ "$PASS" == "$PASS_CONFIRM" ]]; then
        break
    fi
    msg "Passwörter stimmen nicht überein."
done

# --- Template (Storage + Auswahl/Download) ---

TPL_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')
[[ -z "$TPL_STORAGE" ]] && TPL_STORAGE="local"

# Prefer Debian 13, fall back to Debian 12
EXISTING=$(pvesm list "$TPL_STORAGE" 2>/dev/null | awk '/debian-13-standard.*\.tar\./ {print $1}' | sort -V | tail -1)
if [[ -z "$EXISTING" ]]; then
    EXISTING=$(pvesm list "$TPL_STORAGE" 2>/dev/null | awk '/debian-12-standard.*\.tar\./ {print $1}' | sort -V | tail -1)
fi

if [[ -n "$EXISTING" ]]; then
    TEMPLATE_REF="$EXISTING"
    TEMPLATE_NAME=$(basename "${EXISTING#*:vztmpl/}")
else
    echo
    echo "Kein Debian-Standard-Template gefunden, suche online..."
    pveam update >/dev/null 2>&1 || true
    TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
        | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)
    if [[ -z "$TEMPLATE_NAME" ]]; then
        TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
            | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)
    fi

    if [[ -z "$TEMPLATE_NAME" ]]; then
        msg "Konnte kein debian-13-standard oder debian-12-standard Template finden.\n\nBitte manuell laden:\n  pveam update\n  pveam available --section system\n  pveam download $TPL_STORAGE <template-name>"
        exit 1
    fi

    echo "Lade Template: $TEMPLATE_NAME"
    pveam download "$TPL_STORAGE" "$TEMPLATE_NAME" || {
        msg "Template-Download fehlgeschlagen."
        exit 1
    }
    TEMPLATE_REF="$TPL_STORAGE:vztmpl/$TEMPLATE_NAME"
fi

# --- Confirm ---

SUMMARY="LXC wird jetzt erstellt:\n\n"
SUMMARY+="VMID:      $VMID\n"
SUMMARY+="Rolle:     $ROLE\n"
SUMMARY+="Hostname:  $HOSTNAME\n"
SUMMARY+="Template:  $TEMPLATE_NAME\n"
SUMMARY+="Storage:   $STORAGE\n"
SUMMARY+="Bridge:    $BRIDGE\n"
if $USE_DHCP; then
    SUMMARY+="Netzwerk:  DHCP\n"
else
    SUMMARY+="IP:        $IP_CIDR\n"
    SUMMARY+="Gateway:   $GATEWAY\n"
fi
SUMMARY+="Specs:     $LXC_CORES vCPU, $LXC_MEMORY MB RAM, $LXC_SWAP MB Swap, $LXC_DISK GB Disk\n\n"
SUMMARY+="Fortfahren?"

yesno "$SUMMARY" || cancel

# --- Create LXC ---

if $USE_DHCP; then
    NET_ARG="name=eth0,bridge=$BRIDGE,ip=dhcp"
else
    NET_ARG="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY"
fi

echo
echo "==> Erstelle LXC $VMID..."
pct create "$VMID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --cores "$LXC_CORES" \
    --memory "$LXC_MEMORY" \
    --swap "$LXC_SWAP" \
    --rootfs "$STORAGE:$LXC_DISK" \
    --net0 "$NET_ARG" \
    --password "$PASS" \
    --unprivileged 1 \
    --onboot 1 \
    --features "nesting=0" \
    --start 1

# --- Wait for boot ---

echo "==> Warte auf Container-Start..."
for i in $(seq 1 60); do
    if pct exec "$VMID" -- true 2>/dev/null; then
        break
    fi
    sleep 1
done

echo "==> Warte auf Netzwerk..."
for i in $(seq 1 60); do
    if pct exec "$VMID" -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# --- Install dependencies and clone repo ---

msg "Container läuft.\n\nIm nächsten Schritt:\n  1) git wird im Container installiert\n  2) Das DynDNS-Repo wird geklont\n  3) Der DynDNS-Setup-Assistent startet im Container\n\nDu klickst dort durch denselben Assistenten und gibst Domain, NameCheap-Passwort, Failover-Token usw. ein.\n\nWeiter mit OK."

echo "==> Installiere Pakete im LXC..."
pct exec "$VMID" -- bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git ca-certificates whiptail
    if [[ -d /root/dyndns/.git ]]; then
        cd /root/dyndns && git pull --ff-only
    else
        rm -rf /root/dyndns
        git clone $REPO_URL /root/dyndns
    fi
    chmod +x /root/dyndns/setup.sh /root/dyndns/updater.sh /root/dyndns/heartbeat.sh
"

# --- Run inner setup interactively ---

echo
echo "================================================"
echo "Starte DynDNS-Setup im Container $VMID..."
echo "================================================"
echo

set +e
pct exec "$VMID" -- bash -c "cd /root/dyndns && ./setup.sh"
SETUP_RC=$?
set -e

# --- Final summary ---

echo
if [[ $SETUP_RC -eq 0 ]]; then
    if $USE_DHCP; then
        LXC_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')
    else
        LXC_IP="${IP_CIDR%/*}"
    fi

    NEXT_HINT=""
    case "$ROLE" in
        master)
            NEXT_HINT="Notiere den im LXC angezeigten Failover-Token.\nFür den Failover-LXC:\n  - dieses Script auf dem zweiten Proxmox-Host ausführen\n  - Rolle 'Failover' wählen\n  - Token + Master-URL eingeben"
            ;;
        failover)
            NEXT_HINT="Standby aktiv. Springt automatisch ein, wenn der Master ausfällt."
            ;;
    esac

    msg "Fertig!\n\nVMID:       $VMID\nIP:         $LXC_IP\nRolle:      $ROLE\n\nDashboard:  http://$LXC_IP:8080\n\n${NEXT_HINT}\n\nNützliche Befehle:\n  pct enter $VMID          # Shell im LXC\n  pct stop/start $VMID     # Container steuern"
else
    msg "Das DynDNS-Setup im Container wurde abgebrochen oder ist fehlgeschlagen.\n\nDer Container existiert (VMID $VMID), das Setup ist aber unvollständig.\n\nDu kannst es manuell nachholen:\n  pct enter $VMID\n  cd /root/dyndns && ./setup.sh"
    exit 1
fi
