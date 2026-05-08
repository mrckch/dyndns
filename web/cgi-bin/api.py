#!/usr/bin/env python3
import os
import sys
import json
import sqlite3
import subprocess
import time
import re
import secrets
import hashlib
from urllib.parse import parse_qs

CONFIG_FILE = "/etc/dyndns/config.env"
CONFIG_DIR = "/etc/dyndns"
DB_FILE = "/var/lib/dyndns/history.db"
UPDATER_SCRIPT = "/opt/dyndns/updater.sh"
HEARTBEAT_SCRIPT = "/opt/dyndns/heartbeat.sh"
TIMER_UNIT = "dyndns-update.timer"
HEARTBEAT_TIMER = "dyndns-heartbeat.timer"
RATE_LIMIT_FILE = "/tmp/dyndns-test-last"
LIGHTTPD_CONF = "/etc/lighttpd/conf-available/90-dyndns.conf"
HTDIGEST_FILE = "/etc/dyndns/htdigest"
REALM = "DynDNS Dashboard"

PUBLIC_ACTIONS = {"heartbeat"}


def respond(status, data, extra_headers=None):
    print(f"Status: {status}")
    print("Content-Type: application/json")
    print("Access-Control-Allow-Origin: *")
    print("Access-Control-Allow-Methods: GET, POST, OPTIONS")
    print("Access-Control-Allow-Headers: Content-Type, Authorization, X-DynDNS-Token, X-DynDNS-Node")
    if extra_headers:
        for k, v in extra_headers.items():
            print(f"{k}: {v}")
    print()
    print(json.dumps(data, ensure_ascii=False))
    sys.exit(0)


def read_config():
    config = {}
    if not os.path.exists(CONFIG_FILE):
        return config
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                config[key.strip()] = val.strip()
    return config


def write_config(config):
    with open(CONFIG_FILE, "w") as f:
        for key, val in config.items():
            f.write(f"{key}={val}\n")
    os.chmod(CONFIG_FILE, 0o640)


def check_auth(config, action):
    if action in PUBLIC_ACTIONS:
        return True
    if config.get("DYNDNS_WEB_AUTH_ENABLED") != "true":
        return True
    # lighttpd handles digest auth at server level when enabled.
    # If the header is missing here, lighttpd would already have rejected it.
    return True


def get_db():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def get_node_state():
    try:
        db = get_db()
        cur = db.cursor()
        cur.execute("SELECT * FROM node_state WHERE id=1")
        row = cur.fetchone()
        db.close()
        return dict(row) if row else {}
    except Exception:
        return {}


def update_node_state(updates):
    if not updates:
        return
    db = get_db()
    cols = ", ".join(f"{k}=?" for k in updates.keys())
    db.execute(f"UPDATE node_state SET {cols} WHERE id=1", list(updates.values()))
    db.commit()
    db.close()


def systemctl(action, unit, timeout=10):
    try:
        return subprocess.run(
            ["systemctl", action, unit],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return None


# --- Handlers ---

def handle_status():
    config = read_config()
    db = get_db()

    cur = db.cursor()
    cur.execute("SELECT * FROM updates ORDER BY timestamp DESC LIMIT 1")
    last = cur.fetchone()

    timer_active = False
    r = systemctl("is-active", TIMER_UNIT)
    if r:
        timer_active = r.stdout.strip() == "active"

    next_run = ""
    try:
        result = subprocess.run(
            ["systemctl", "show", TIMER_UNIT, "--property=NextElapseUSecRealtime"],
            capture_output=True, text=True, timeout=5
        )
        next_run = result.stdout.strip().split("=", 1)[-1] if "=" in result.stdout else ""
    except Exception:
        pass

    total = db.execute("SELECT COUNT(*) FROM updates").fetchone()[0]
    successes = db.execute("SELECT COUNT(*) FROM updates WHERE status='success'").fetchone()[0]
    failures = db.execute("SELECT COUNT(*) FROM updates WHERE status='failure'").fetchone()[0]

    state = get_node_state()
    db.close()

    role = config.get("DYNDNS_ROLE", "single")
    is_active = "1"
    if role == "failover":
        is_active = state.get("is_active", "0") or "0"

    respond("200 OK", {
        "domain": config.get("DYNDNS_DOMAIN", ""),
        "host": config.get("DYNDNS_HOST", "@"),
        "interval": config.get("DYNDNS_INTERVAL", "5"),
        "current_ip": dict(last)["new_ip"] if last else "",
        "last_update": dict(last)["timestamp"] if last else "",
        "last_status": dict(last)["status"] if last else "",
        "last_message": dict(last)["message"] if last else "",
        "timer_active": timer_active,
        "next_run": next_run,
        "role": role,
        "node_name": config.get("DYNDNS_NODE_NAME", ""),
        "is_active": is_active,
        "stats": {
            "total": total,
            "successes": successes,
            "failures": failures,
        },
    })


def handle_history():
    qs = parse_qs(os.environ.get("QUERY_STRING", ""))
    limit = min(int(qs.get("limit", ["50"])[0]), 200)
    offset = int(qs.get("offset", ["0"])[0])

    db = get_db()
    cur = db.cursor()
    cur.execute(
        "SELECT id, timestamp, old_ip, new_ip, status, message FROM updates ORDER BY timestamp DESC LIMIT ? OFFSET ?",
        (limit, offset),
    )
    rows = [dict(r) for r in cur.fetchall()]
    total = db.execute("SELECT COUNT(*) FROM updates").fetchone()[0]
    db.close()

    try:
        db2 = get_db()
        db2.execute("DELETE FROM updates WHERE timestamp < datetime('now', '-90 days')")
        db2.commit()
        db2.close()
    except Exception:
        pass

    respond("200 OK", {"entries": rows, "total": total, "limit": limit, "offset": offset})


def handle_config_get():
    config = read_config()
    respond("200 OK", {
        "domain": config.get("DYNDNS_DOMAIN", ""),
        "host": config.get("DYNDNS_HOST", "@"),
        "password": "****" if config.get("DYNDNS_PASSWORD") else "",
        "interval": config.get("DYNDNS_INTERVAL", "5"),
        "web_port": config.get("DYNDNS_WEB_PORT", "8080"),
        "web_auth_enabled": config.get("DYNDNS_WEB_AUTH_ENABLED", "false") == "true",
        "web_auth_user": config.get("DYNDNS_WEB_AUTH_USER", ""),
        "role": config.get("DYNDNS_ROLE", "single"),
        "node_name": config.get("DYNDNS_NODE_NAME", ""),
        "peer_url": config.get("DYNDNS_PEER_URL", ""),
        "peer_token": "****" if config.get("DYNDNS_PEER_TOKEN") else "",
        "heartbeat_interval": config.get("DYNDNS_HEARTBEAT_INTERVAL", "30"),
        "failover_threshold": config.get("DYNDNS_FAILOVER_THRESHOLD", "3"),
    })


def update_lighttpd_auth(enabled, user, password):
    """Toggle digest-auth section in lighttpd config. Restart on change."""
    if not os.path.exists(LIGHTTPD_CONF):
        return False, "lighttpd config not found"

    with open(LIGHTTPD_CONF) as f:
        content = f.read()

    # Strip existing auth block (idempotent)
    content = re.sub(
        r"\nserver\.modules \+= \(\"mod_auth\".*?\)\)\n?",
        "",
        content,
        flags=re.DOTALL,
    )

    # Strip wrapped peer-exempt block too (idempotent)
    content = re.sub(
        r"\n\$HTTP\[\"url\"\] !~ \"\^/peer/\" \{.*?\n\}\n?",
        "",
        content,
        flags=re.DOTALL,
    )

    if enabled:
        if not user:
            return False, "User required when auth enabled"
        if password:
            digest = hashlib.md5(f"{user}:{REALM}:{password}".encode()).hexdigest()
            with open(HTDIGEST_FILE, "w") as f:
                f.write(f"{user}:{REALM}:{digest}\n")
            os.chmod(HTDIGEST_FILE, 0o640)
            try:
                import grp
                gid = grp.getgrnam("www-data").gr_gid
                os.chown(HTDIGEST_FILE, 0, gid)
            except Exception:
                pass

        if not os.path.exists(HTDIGEST_FILE):
            return False, "Password required to enable auth"

        content += (
            '\nserver.modules += ("mod_auth", "mod_authn_file")\n'
            'auth.backend = "htdigest"\n'
            f'auth.backend.htdigest.userfile = "{HTDIGEST_FILE}"\n'
            '$HTTP["url"] !~ "^/peer/" {\n'
            '    auth.require = ("/" => (\n'
            '        "method" => "digest",\n'
            f'        "realm" => "{REALM}",\n'
            '        "require" => "valid-user"\n'
            '    ))\n'
            '}\n'
        )

    with open(LIGHTTPD_CONF, "w") as f:
        f.write(content)

    return True, "ok"


def handle_config_post():
    content_length = int(os.environ.get("CONTENT_LENGTH", 0))
    if content_length == 0:
        respond("400 Bad Request", {"error": "No data provided"})

    body = sys.stdin.read(content_length)
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        respond("400 Bad Request", {"error": "Invalid JSON"})

    config = read_config()
    changed_interval = False
    changed_lighttpd = False
    changed_heartbeat = False

    if "domain" in data:
        domain = data["domain"]
        if not re.match(r"^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$", domain):
            respond("400 Bad Request", {"error": "Ungültige Domain"})
        config["DYNDNS_DOMAIN"] = domain

    if "host" in data:
        host = re.sub(r"[^a-zA-Z0-9@._-]", "", data["host"])
        config["DYNDNS_HOST"] = host or "@"

    if "password" in data and data["password"] and data["password"] != "****":
        config["DYNDNS_PASSWORD"] = data["password"]

    if "interval" in data:
        try:
            interval = int(data["interval"])
        except (ValueError, TypeError):
            respond("400 Bad Request", {"error": "Intervall muss eine Zahl sein"})
        if interval < 1 or interval > 60:
            respond("400 Bad Request", {"error": "Intervall muss 1-60 sein"})
        if config.get("DYNDNS_INTERVAL") != str(interval):
            changed_interval = True
        config["DYNDNS_INTERVAL"] = str(interval)

    if "node_name" in data:
        config["DYNDNS_NODE_NAME"] = re.sub(r"[^a-zA-Z0-9._-]", "", data["node_name"])[:64]

    if "role" in data:
        if data["role"] not in ("master", "failover", "single"):
            respond("400 Bad Request", {"error": "Ungültige Rolle"})
        if config.get("DYNDNS_ROLE") != data["role"]:
            changed_heartbeat = True
        config["DYNDNS_ROLE"] = data["role"]

    if "peer_url" in data:
        url = data["peer_url"].strip()
        if url and not re.match(r"^https?://[a-zA-Z0-9.\-]+(:\d+)?$", url):
            respond("400 Bad Request", {"error": "Peer-URL muss z.B. http://10.0.0.20:8080 sein"})
        config["DYNDNS_PEER_URL"] = url

    if "peer_token" in data and data["peer_token"] and data["peer_token"] != "****":
        config["DYNDNS_PEER_TOKEN"] = re.sub(r"[^a-zA-Z0-9_-]", "", data["peer_token"])

    if "heartbeat_interval" in data:
        try:
            hb = int(data["heartbeat_interval"])
        except (ValueError, TypeError):
            respond("400 Bad Request", {"error": "Heartbeat-Intervall muss Zahl sein"})
        if hb < 10 or hb > 300:
            respond("400 Bad Request", {"error": "Heartbeat-Intervall 10-300s"})
        if config.get("DYNDNS_HEARTBEAT_INTERVAL") != str(hb):
            changed_heartbeat = True
        config["DYNDNS_HEARTBEAT_INTERVAL"] = str(hb)

    if "failover_threshold" in data:
        try:
            th = int(data["failover_threshold"])
        except (ValueError, TypeError):
            respond("400 Bad Request", {"error": "Failover-Schwelle muss Zahl sein"})
        if th < 1 or th > 20:
            respond("400 Bad Request", {"error": "Failover-Schwelle 1-20"})
        config["DYNDNS_FAILOVER_THRESHOLD"] = str(th)

    if "web_auth_enabled" in data:
        new_enabled = "true" if data["web_auth_enabled"] else "false"
        if config.get("DYNDNS_WEB_AUTH_ENABLED", "false") != new_enabled:
            changed_lighttpd = True
        config["DYNDNS_WEB_AUTH_ENABLED"] = new_enabled
        if "web_auth_user" in data and data["web_auth_user"]:
            config["DYNDNS_WEB_AUTH_USER"] = re.sub(r"[^a-zA-Z0-9._-]", "", data["web_auth_user"])[:64]
        if data["web_auth_enabled"] and "web_auth_password" in data and data["web_auth_password"]:
            ok, err = update_lighttpd_auth(True, config.get("DYNDNS_WEB_AUTH_USER", "admin"), data["web_auth_password"])
            if not ok:
                respond("400 Bad Request", {"error": err})
            changed_lighttpd = True
        elif not data["web_auth_enabled"]:
            update_lighttpd_auth(False, "", "")
            changed_lighttpd = True

    write_config(config)

    if changed_interval:
        timer_file = f"/etc/systemd/system/{TIMER_UNIT}"
        try:
            with open(timer_file) as f:
                content = f.read()
            content = re.sub(
                r"OnUnitActiveSec=\d+min",
                f"OnUnitActiveSec={config['DYNDNS_INTERVAL']}min",
                content,
            )
            with open(timer_file, "w") as f:
                f.write(content)
            subprocess.run(["sudo", "-n", "/bin/systemctl", "daemon-reload"], timeout=10)
            subprocess.run(["sudo", "-n", "/bin/systemctl", "restart", TIMER_UNIT], timeout=10)
        except Exception as e:
            respond("500 Internal Server Error", {"error": f"Timer-Update fehlgeschlagen: {e}"})

    if changed_heartbeat:
        hb = config.get("DYNDNS_HEARTBEAT_INTERVAL", "30")
        timer_file = f"/etc/systemd/system/{HEARTBEAT_TIMER}"
        if os.path.exists(timer_file):
            try:
                with open(timer_file) as f:
                    content = f.read()
                content = re.sub(r"OnUnitActiveSec=\d+s?", f"OnUnitActiveSec={hb}s", content)
                content = re.sub(r"OnBootSec=\d+s?", f"OnBootSec={hb}s", content)
                with open(timer_file, "w") as f:
                    f.write(content)
                subprocess.run(["sudo", "-n", "/bin/systemctl", "daemon-reload"], timeout=10)
                role = config.get("DYNDNS_ROLE", "single")
                if role == "single":
                    subprocess.run(["sudo", "-n", "/bin/systemctl", "stop", HEARTBEAT_TIMER], timeout=10)
                    subprocess.run(["sudo", "-n", "/bin/systemctl", "disable", HEARTBEAT_TIMER], timeout=10)
                else:
                    subprocess.run(["sudo", "-n", "/bin/systemctl", "enable", "--now", HEARTBEAT_TIMER], timeout=10)
                    subprocess.run(["sudo", "-n", "/bin/systemctl", "restart", HEARTBEAT_TIMER], timeout=10)
            except Exception as e:
                respond("500 Internal Server Error", {"error": f"Heartbeat-Timer-Update fehlgeschlagen: {e}"})

    if changed_lighttpd:
        try:
            subprocess.run(["sudo", "-n", "/bin/systemctl", "restart", "lighttpd"], timeout=10)
        except Exception:
            pass

    respond("200 OK", {"success": True, "message": "Konfiguration gespeichert"})


def handle_test():
    if os.path.exists(RATE_LIMIT_FILE):
        try:
            last_test = os.path.getmtime(RATE_LIMIT_FILE)
            if time.time() - last_test < 30:
                respond("429 Too Many Requests", {"error": "Bitte 30 Sekunden zwischen Tests warten"})
        except Exception:
            pass

    with open(RATE_LIMIT_FILE, "w") as f:
        f.write(str(time.time()))

    try:
        result = subprocess.run(
            [UPDATER_SCRIPT],
            capture_output=True, text=True, timeout=30,
        )
        db = get_db()
        cur = db.cursor()
        cur.execute("SELECT * FROM updates ORDER BY timestamp DESC LIMIT 1")
        last = cur.fetchone()
        db.close()

        respond("200 OK", {
            "success": result.returncode == 0,
            "exit_code": result.returncode,
            "last_entry": dict(last) if last else None,
        })
    except subprocess.TimeoutExpired:
        respond("504 Gateway Timeout", {"error": "Update-Timeout"})
    except Exception as e:
        respond("500 Internal Server Error", {"error": str(e)})


def handle_heartbeat():
    """Public endpoint, token-secured. Called by peer node."""
    config = read_config()
    expected_token = config.get("DYNDNS_PEER_TOKEN", "")
    received_token = os.environ.get("HTTP_X_DYNDNS_TOKEN", "")

    if not expected_token or not received_token:
        respond("403 Forbidden", {"ok": False, "error": "missing token"})

    if not secrets.compare_digest(expected_token, received_token):
        respond("403 Forbidden", {"ok": False, "error": "invalid token"})

    db = get_db()
    cur = db.cursor()
    cur.execute("SELECT new_ip, timestamp, status FROM updates ORDER BY timestamp DESC LIMIT 1")
    last = cur.fetchone()
    db.close()

    state = get_node_state()
    role = config.get("DYNDNS_ROLE", "single")
    is_active = "1"
    if role == "failover":
        is_active = state.get("is_active", "0") or "0"

    respond("200 OK", {
        "ok": True,
        "role": role,
        "node_name": config.get("DYNDNS_NODE_NAME", ""),
        "current_ip": dict(last)["new_ip"] if last else "",
        "last_update": dict(last)["timestamp"] if last else "",
        "last_status": dict(last)["status"] if last else "",
        "is_active": is_active,
        "domain": config.get("DYNDNS_DOMAIN", ""),
        "host": config.get("DYNDNS_HOST", "@"),
    })


def handle_peer_status():
    config = read_config()
    role = config.get("DYNDNS_ROLE", "single")
    if role == "single":
        respond("200 OK", {"role": "single", "configured": False})

    state = get_node_state()
    threshold = int(config.get("DYNDNS_FAILOVER_THRESHOLD", "3"))
    fails = int(state.get("peer_consecutive_fails", 0) or 0)

    respond("200 OK", {
        "configured": True,
        "role": role,
        "peer_url": config.get("DYNDNS_PEER_URL", ""),
        "peer_healthy": str(state.get("peer_healthy", "0")) == "1",
        "peer_consecutive_fails": fails,
        "peer_last_seen": state.get("peer_last_seen", ""),
        "peer_role": state.get("peer_role", ""),
        "peer_ip": state.get("peer_ip", ""),
        "peer_last_update": state.get("peer_last_update", ""),
        "peer_last_status": state.get("peer_last_status", ""),
        "peer_is_active": str(state.get("peer_is_active", "0")) == "1",
        "peer_last_error": state.get("peer_last_error", ""),
        "is_active": str(state.get("is_active", "1" if role == "master" else "0")) == "1",
        "force_active": str(state.get("force_active", "0")) == "1",
        "last_takeover_at": state.get("last_takeover_at", ""),
        "last_release_at": state.get("last_release_at", ""),
        "threshold": threshold,
        "would_take_over": role == "failover" and fails >= threshold,
    })


def handle_failover_control():
    content_length = int(os.environ.get("CONTENT_LENGTH", 0))
    if content_length == 0:
        respond("400 Bad Request", {"error": "Keine Daten"})

    body = sys.stdin.read(content_length)
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        respond("400 Bad Request", {"error": "Ungültiges JSON"})

    cmd = data.get("command", "")

    if cmd == "force_takeover":
        update_node_state({"force_active": "1", "is_active": "1",
                          "last_takeover_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        respond("200 OK", {"success": True, "message": "Failover manuell aktiviert"})
    elif cmd == "release":
        update_node_state({"force_active": "0", "is_active": "0",
                          "last_release_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        respond("200 OK", {"success": True, "message": "Failover deaktiviert, Master übernimmt wieder"})
    elif cmd == "rotate_token":
        new_token = secrets.token_hex(32)
        config = read_config()
        config["DYNDNS_PEER_TOKEN"] = new_token
        write_config(config)
        respond("200 OK", {"success": True, "token": new_token,
                          "message": "Token rotiert. Bitte auf dem Peer eintragen."})
    elif cmd == "test_peer":
        try:
            result = subprocess.run([HEARTBEAT_SCRIPT], capture_output=True, text=True, timeout=10)
            state = get_node_state()
            respond("200 OK", {
                "success": result.returncode == 0,
                "peer_healthy": str(state.get("peer_healthy", "0")) == "1",
                "peer_last_error": state.get("peer_last_error", ""),
            })
        except Exception as e:
            respond("500 Internal Server Error", {"error": str(e)})
    else:
        respond("400 Bad Request", {"error": "Unbekannter Befehl"})


# --- Router ---

def main():
    method = os.environ.get("REQUEST_METHOD", "GET")

    if method == "OPTIONS":
        respond("200 OK", {})

    qs = parse_qs(os.environ.get("QUERY_STRING", ""))
    action = qs.get("action", [""])[0]

    config = read_config()
    check_auth(config, action)

    if method == "GET":
        if action == "status":
            handle_status()
        elif action == "history":
            handle_history()
        elif action == "config":
            handle_config_get()
        elif action == "peer-status":
            handle_peer_status()
        elif action == "heartbeat":
            handle_heartbeat()
        else:
            respond("400 Bad Request", {"error": "Unbekannte Aktion"})
    elif method == "POST":
        if action == "config":
            handle_config_post()
        elif action == "test":
            handle_test()
        elif action == "failover":
            handle_failover_control()
        elif action == "heartbeat":
            handle_heartbeat()
        else:
            respond("400 Bad Request", {"error": "Unbekannte Aktion"})
    else:
        respond("405 Method Not Allowed", {"error": "Methode nicht erlaubt"})


if __name__ == "__main__":
    main()
