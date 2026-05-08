# DynDNS Updater für NameCheap (mit Failover)

Automatischer Dynamic-DNS-Updater für NameCheap-Domains, läuft in einem Debian/Ubuntu-LXC auf Proxmox. Aktualisiert regelmäßig den A-Record auf die aktuelle öffentliche IP und bietet ein Web-Dashboard zur Überwachung und Konfiguration.

Optional als **Master/Failover**-Pärchen über zwei LXCs auf zwei Proxmox-Hosts: fällt der Master aus, übernimmt der Failover automatisch.

## Features

- Update an NameCheap DynDNS API in einstellbarem Intervall (1–60 Min.)
- IP-Auflösung über mehrere öffentliche Services (Fallback)
- SQLite-basierte History (90 Tage Aufbewahrung)
- Web-Dashboard mit Status, Verlauf und Live-Test-Knopf
- Optionales Web-Dashboard-Passwort (HTTP Digest Auth)
- Failover-Modus: zwei Knoten überwachen sich gegenseitig per Heartbeat
- Alle Einstellungen direkt im Dashboard änderbar (kein erneuter Setup-Lauf nötig)
- Geführter, vollständig deutscher Setup-Assistent (whiptail)

## Architektur (Failover)

```
                  ┌──────────────┐         ┌──────────────┐
                  │   LXC #1     │  HTTP   │   LXC #2     │
                  │ Proxmox A    │◄───────►│ Proxmox B    │
                  │              │ Heart-  │              │
                  │  MASTER      │ beat    │  FAILOVER    │
                  │  (aktiv)     │  /peer  │  (Standby)   │
                  └──────┬───────┘         └──────┬───────┘
                         │                        │
                         │ NameCheap DynDNS API   │ (nur wenn Master down)
                         ▼                        ▼
                   ┌─────────────────────────────────┐
                   │    NameCheap DNS A-Record       │
                   └─────────────────────────────────┘
```

Beide LXCs hängen am selben Internetanschluss (gleiche WAN-IP). Der Failover macht selbst keine Updates, solange der Master gesund ist – er springt nur ein, wenn der Master nach mehreren Heartbeat-Versuchen nicht antwortet. Sobald der Master wieder online ist, übergibt der Failover automatisch zurück.

## Voraussetzungen

- Debian 12 / 13 oder Ubuntu 22.04+ (LXC oder VM)
- Root-Zugriff
- NameCheap-Domain mit aktiviertem Dynamic DNS (Advanced DNS → Dynamic DNS Record)
- Für Failover: zwei LXCs, die sich gegenseitig per HTTP erreichen können

## Schnellstart auf Proxmox (empfohlen)

Auf dem **Proxmox-Host** (als root) – erstellt einen LXC mit komfortablen Specs (1 vCPU, 256 MB RAM, 128 MB Swap, 4 GB Disk) und startet danach den DynDNS-Setup-Assistenten direkt im Container:

```bash
bash <(curl -sL https://raw.githubusercontent.com/mrckch/dyndns/main/proxmox/create-lxc.sh)
```

Der Assistent fragt nur nach Rolle, IP-Adresse und Root-Passwort. Alles andere (VMID, Storage, Bridge, Template-Download, LXC-Erstellung, Repo-Klon, DynDNS-Setup) läuft automatisch.

Für ein Master/Failover-Pärchen führst du das Skript einmal auf jedem Proxmox-Host aus und wählst dort die jeweilige Rolle.

## Schnellstart manuell (Single-Mode)

```bash
git clone https://github.com/mrckch/dyndns.git
cd dyndns
sudo ./setup.sh
```

Der Assistent fragt alles ab, was nötig ist. Wähle als Rolle **"Single"** für einen einzelnen Server ohne Backup.

## Schnellstart manuell (Master + Failover)

### Schritt 1: Master einrichten (LXC #1 auf Proxmox A)

```bash
git clone https://github.com/mrckch/dyndns.git
cd dyndns
sudo ./setup.sh
```

Im Assistenten:
- Rolle: **"Master"**
- Domain, Host, NameCheap-Passwort wie üblich
- **Failover-Token notieren** (wird angezeigt – kopieren!)
- Failover-URL kann übersprungen und später eingetragen werden

### Schritt 2: Failover einrichten (LXC #2 auf Proxmox B)

```bash
git clone https://github.com/mrckch/dyndns.git
cd dyndns
sudo ./setup.sh
```

Im Assistenten:
- Rolle: **"Failover"**
- Gleiche Domain, gleicher Host, **gleiches** NameCheap-Passwort
- Master-URL: `http://<IP-des-Masters>:8080`
- Token: den vom Master kopierten Wert eintragen

### Schritt 3: Master nachkonfigurieren

Im Master-Dashboard unter **Einstellungen → Failover** die Peer-URL des Failovers eintragen (`http://<IP-des-Failovers>:8080`).

## Konfiguration im Dashboard

Das Dashboard ist nach dem Setup unter `http://<lxc-ip>:8080` erreichbar (Port änderbar). Alle Einstellungen lassen sich dort anpassen, ohne `setup.sh` erneut zu starten:

| Bereich  | Was du ändern kannst |
|---|---|
| DynDNS   | Domain, Host, Passwort, Update-Intervall, Servername |
| Failover | Rolle, Peer-URL, Peer-Token, Heartbeat-Intervall, Failover-Schwelle |
| Web-Auth | Passwort-Schutz aktivieren/deaktivieren, User/Passwort ändern |

Im **Failover-Bereich** zusätzlich:
- Peer-Status live (Online/Offline, letzter Heartbeat, Fehlversuche)
- "Peer jetzt prüfen" – einmaliger Heartbeat zum Test
- "Failover erzwingen" – manuelle Übernahme (z. B. für Master-Wartung)
- "Zurück zum Master" – manuelle Übernahme zurücknehmen
- "Token rotieren" – neuen gemeinsamen Token erzeugen

## Wie der Failover entscheidet

1. Beide Knoten laufen einen `heartbeat.sh`-Timer (Default 30 s).
2. Failover ruft `http://<master>:8080/peer/heartbeat.py` mit `X-DynDNS-Token`-Header auf.
3. Bei Erfolg: Zähler `peer_consecutive_fails` zurückgesetzt.
4. Bei N Fehlversuchen in Folge (Default 3 → ca. 90 s): Failover markiert sich als aktiv und fängt mit Updates an.
5. Sobald der Master wieder antwortet: Failover gibt frei (`is_active=0`), Master übernimmt wieder.

Manuell erzwungene Übernahme (`force_active=1`) wird vom automatischen Mechanismus nicht überschrieben – sie muss explizit zurückgenommen werden.

## Datei- und Verzeichnisstruktur

```
/opt/dyndns/                  Anwendung
  updater.sh                  Update-Script
  heartbeat.sh                Heartbeat-Script
  web/static/                 Dashboard (HTML/JS/CSS)
  web/cgi-bin/api.py          API (geschützt durch optionale Web-Auth)
  web/peer-cgi/heartbeat.py   Peer-Endpunkt (Token-geschützt, ohne Web-Auth)
/etc/dyndns/
  config.env                  Konfiguration
  htdigest                    Optionale Web-Auth-Datei
/var/lib/dyndns/
  history.db                  SQLite-DB (Updates + Node-State)
/var/log/dyndns/
  update.log                  Update-Log
  heartbeat.log               Heartbeat-Log
/etc/systemd/system/
  dyndns-update.{service,timer}
  dyndns-heartbeat.{service,timer}
/etc/lighttpd/conf-available/90-dyndns.conf
/etc/sudoers.d/dyndns         erlaubt www-data, ausgewählte systemctl-Calls
/etc/logrotate.d/dyndns
```

## Sicherheit

- Konfigurationsdatei (inkl. NameCheap-Passwort und Peer-Token) liegt unter `/etc/dyndns/config.env` mit `0640 root:www-data`.
- Heartbeat-Endpunkt (`/peer/heartbeat.py`) ist nur per geheimem Token erreichbar (Konstantzeit-Vergleich, `secrets.compare_digest`).
- Web-Dashboard kann optional mit HTTP Digest Auth abgesichert werden.
- Der Heartbeat-Pfad ist auch bei aktivierter Web-Auth ohne Browser-Login erreichbar (sonst könnte der Failover den Master nicht prüfen) – die Absicherung erfolgt allein über den Token.
- HTTP zwischen den Knoten ist akzeptabel, wenn beide LXCs in einem privaten LAN/VLAN/VPN liegen. Im offenen Internet wäre HTTPS sinnvoll.

## Troubleshooting

```bash
# Logs anschauen
journalctl -u dyndns-update.service -f
journalctl -u dyndns-heartbeat.service -f
tail -f /var/log/dyndns/update.log
tail -f /var/log/dyndns/heartbeat.log

# Update manuell ausführen
sudo /opt/dyndns/updater.sh

# Heartbeat manuell ausführen
sudo /opt/dyndns/heartbeat.sh

# DB-Status
sqlite3 /var/lib/dyndns/history.db "SELECT * FROM node_state;"
sqlite3 /var/lib/dyndns/history.db "SELECT * FROM updates ORDER BY id DESC LIMIT 5;"
```

## Lizenz

MIT – siehe [LICENSE](LICENSE).
