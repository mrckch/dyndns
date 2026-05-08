const API = "/cgi-bin/api.py";
let currentPage = 0;
const PAGE_SIZE = 20;
let autoRefreshId = null;
let currentRole = "single";

async function api(action, method = "GET", body = null, extraQs = "") {
    const opts = { method };
    if (body) {
        opts.headers = { "Content-Type": "application/json" };
        opts.body = JSON.stringify(body);
    }
    const url = method === "GET" && body === null
        ? `${API}?action=${action}&limit=${PAGE_SIZE}&offset=${currentPage * PAGE_SIZE}${extraQs}`
        : `${API}?action=${action}${extraQs}`;
    const res = await fetch(url, opts);
    return res.json();
}

function relTime(iso) {
    if (!iso) return "—";
    const d = new Date(iso.endsWith("Z") ? iso : iso + "Z");
    const diff = Math.floor((Date.now() - d.getTime()) / 1000);
    if (diff < 60) return "gerade eben";
    if (diff < 3600) return `vor ${Math.floor(diff / 60)} Min.`;
    if (diff < 86400) return `vor ${Math.floor(diff / 3600)} Std.`;
    return d.toLocaleString("de-DE");
}

function setBadge(el, status, labels) {
    el.className = "badge";
    const def = { success: "OK", failure: "Fehler", skipped: "Übersprungen", error: "Fehler" };
    const map = labels || def;
    el.textContent = map[status] || status || "—";
    if (status) el.classList.add(`badge-${status}`);
}

function showToast(msg, type = "success") {
    const t = document.getElementById("toast");
    t.textContent = msg;
    t.className = `toast toast-${type} show`;
    clearTimeout(t._timer);
    t._timer = setTimeout(() => { t.className = "toast hidden"; }, 3500);
}

function escHtml(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
}

async function loadStatus() {
    try {
        const d = await api("status");
        currentRole = d.role || "single";

        const pill = document.getElementById("role-pill");
        pill.textContent = ({master:"Master",failover:"Failover",single:"Single"}[currentRole]) || currentRole;
        pill.className = "role-pill role-" + currentRole;

        document.getElementById("st-domain").textContent = d.domain || "—";
        document.getElementById("st-host").textContent = d.host || "—";
        document.getElementById("st-ip").textContent = d.current_ip || "—";
        document.getElementById("st-time").textContent = relTime(d.last_update);
        document.getElementById("st-time").title = d.last_update || "";
        setBadge(document.getElementById("st-badge"), d.last_status);
        document.getElementById("st-timer").textContent =
            d.timer_active ? `Aktiv (alle ${d.interval} Min.)` : "Inaktiv";
        document.getElementById("stat-total").textContent = d.stats.total;
        document.getElementById("stat-ok").textContent = d.stats.successes;
        document.getElementById("stat-fail").textContent = d.stats.failures;

        const foCard = document.getElementById("failover-card");
        if (currentRole === "single") {
            foCard.classList.add("hidden");
        } else {
            foCard.classList.remove("hidden");
            loadPeerStatus();
        }
    } catch (e) {
        console.error("Status load failed:", e);
    }
}

async function loadPeerStatus() {
    try {
        const d = await api("peer-status", "GET", null, "");
        if (!d.configured) return;

        document.getElementById("fo-self-role").textContent =
            ({master:"Master",failover:"Failover"}[d.role]) || d.role;

        const selfActive = document.getElementById("fo-self-active");
        if (d.role === "master") {
            setBadge(selfActive, d.is_active ? "active" : "standby",
                {active: "Aktiv", standby: "Inaktiv"});
        } else {
            const status = d.force_active ? "active" : (d.is_active ? "active" : "standby");
            setBadge(selfActive, status,
                {active: d.force_active ? "Aktiv (manuell)" : "Aktiv (Master down)", standby: "Standby"});
        }

        document.getElementById("fo-peer-url").textContent = d.peer_url || "—";

        setBadge(document.getElementById("fo-peer-health"),
            d.peer_healthy ? "healthy" : "unhealthy",
            {healthy: "Online", unhealthy: "Offline"});

        document.getElementById("fo-peer-seen").textContent = relTime(d.peer_last_seen);
        document.getElementById("fo-peer-seen").title = d.peer_last_seen || "";

        const fails = document.getElementById("fo-peer-fails");
        fails.textContent = `${d.peer_consecutive_fails} / ${d.threshold}`;
        if (d.peer_consecutive_fails >= d.threshold) {
            fails.style.color = "var(--failure)";
        } else if (d.peer_consecutive_fails > 0) {
            fails.style.color = "var(--error)";
        } else {
            fails.style.color = "";
        }

        const errBox = document.getElementById("fo-error");
        if (d.peer_last_error && !d.peer_healthy) {
            errBox.textContent = d.peer_last_error;
            errBox.classList.remove("hidden");
        } else {
            errBox.classList.add("hidden");
        }

        const takeoverBtn = document.getElementById("fo-takeover-btn");
        const releaseBtn = document.getElementById("fo-release-btn");
        if (d.role === "failover") {
            takeoverBtn.style.display = "";
            releaseBtn.style.display = d.force_active ? "" : "none";
        } else {
            takeoverBtn.style.display = "none";
            releaseBtn.style.display = "none";
        }
    } catch (e) {
        console.error("Peer status load failed:", e);
    }
}

async function loadHistory() {
    try {
        const d = await api("history");
        const tbody = document.getElementById("history-body");
        if (!d.entries || d.entries.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="empty">Keine Einträge vorhanden</td></tr>';
        } else {
            tbody.innerHTML = d.entries.map(e => `
                <tr class="row-${e.status}">
                    <td title="${e.timestamp}">${relTime(e.timestamp)}</td>
                    <td class="mono">${e.old_ip || "—"}</td>
                    <td class="mono">${e.new_ip || "—"}</td>
                    <td><span class="badge badge-${e.status}">${
                        { success: "OK", failure: "Fehler", skipped: "Übersprungen", error: "Fehler" }[e.status] || e.status
                    }</span></td>
                    <td>${escHtml(e.message || "")}</td>
                </tr>
            `).join("");
        }

        const totalPages = Math.max(1, Math.ceil(d.total / PAGE_SIZE));
        document.getElementById("page-info").textContent = `${currentPage + 1} / ${totalPages}`;
        document.getElementById("btn-prev").disabled = currentPage === 0;
        document.getElementById("btn-next").disabled = currentPage >= totalPages - 1;
    } catch (e) {
        console.error("History load failed:", e);
    }
}

function prevPage() {
    if (currentPage > 0) { currentPage--; loadHistory(); }
}
function nextPage() {
    currentPage++;
    loadHistory();
}

async function runTest() {
    const btn = document.getElementById("btn-test");
    btn.classList.add("loading");
    btn.disabled = true;

    try {
        const d = await api("test", "POST");
        if (d.success) {
            showToast("Update erfolgreich durchgeführt!", "success");
        } else if (d.error) {
            showToast(d.error, "error");
        } else {
            showToast("Update fehlgeschlagen", "error");
        }
        await loadStatus();
        await loadHistory();
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }

    setTimeout(() => {
        btn.classList.remove("loading");
        btn.disabled = false;
    }, 30000);
}

async function loadConfig() {
    try {
        const d = await api("config");

        document.getElementById("cfg-domain").value = d.domain || "";
        document.getElementById("cfg-host").value = d.host || "";
        document.getElementById("cfg-password").value = "";
        document.getElementById("cfg-password").placeholder = d.password ? "Unverändert lassen = ****" : "Passwort eingeben";
        document.getElementById("cfg-interval").value = d.interval || "5";
        document.getElementById("cfg-node-name").value = d.node_name || "";

        document.getElementById("cfg-role").value = d.role || "single";
        document.getElementById("cfg-peer-url").value = d.peer_url || "";
        document.getElementById("cfg-peer-token").value = "";
        document.getElementById("cfg-peer-token").placeholder = d.peer_token ? "Unverändert lassen = ****" : "Token eintragen";
        document.getElementById("cfg-hb-interval").value = d.heartbeat_interval || "30";
        document.getElementById("cfg-fo-threshold").value = d.failover_threshold || "3";

        document.getElementById("cfg-auth-enabled").checked = !!d.web_auth_enabled;
        document.getElementById("cfg-auth-user").value = d.web_auth_user || "admin";
        toggleAuthFields();
    } catch (e) {
        console.error("Config load failed:", e);
    }
}

function toggleAuthFields() {
    const enabled = document.getElementById("cfg-auth-enabled").checked;
    document.getElementById("cfg-auth-user").disabled = !enabled;
    document.getElementById("cfg-auth-password").disabled = !enabled;
}

async function saveDyndns(event) {
    event.preventDefault();
    const data = {
        domain: document.getElementById("cfg-domain").value,
        host: document.getElementById("cfg-host").value || "@",
        interval: parseInt(document.getElementById("cfg-interval").value, 10),
        node_name: document.getElementById("cfg-node-name").value,
    };
    const pw = document.getElementById("cfg-password").value;
    if (pw) data.password = pw;
    await postConfig(data, "DynDNS-Einstellungen gespeichert");
}

async function saveFailover(event) {
    event.preventDefault();
    const data = {
        role: document.getElementById("cfg-role").value,
        peer_url: document.getElementById("cfg-peer-url").value.trim(),
        heartbeat_interval: parseInt(document.getElementById("cfg-hb-interval").value, 10),
        failover_threshold: parseInt(document.getElementById("cfg-fo-threshold").value, 10),
    };
    const tok = document.getElementById("cfg-peer-token").value;
    if (tok) data.peer_token = tok;
    await postConfig(data, "Failover-Einstellungen gespeichert");
}

async function saveAuth(event) {
    event.preventDefault();
    const enabled = document.getElementById("cfg-auth-enabled").checked;
    const data = {
        web_auth_enabled: enabled,
        web_auth_user: document.getElementById("cfg-auth-user").value || "admin",
    };
    const pw = document.getElementById("cfg-auth-password").value;
    if (pw) data.web_auth_password = pw;
    await postConfig(data, "Web-Auth gespeichert (Seite neu laden)");
}

async function postConfig(data, successMsg) {
    try {
        const d = await api("config", "POST", data);
        if (d.success) {
            showToast(successMsg, "success");
            await loadStatus();
            await loadConfig();
        } else {
            showToast(d.error || "Fehler beim Speichern", "error");
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function testPeer() {
    try {
        const d = await api("failover", "POST", {command: "test_peer"});
        if (d.success && d.peer_healthy) {
            showToast("Peer erreichbar", "success");
        } else {
            showToast(d.peer_last_error || "Peer nicht erreichbar", "error");
        }
        await loadPeerStatus();
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function forceTakeover() {
    if (!confirm("Failover manuell aktivieren? Dieser Knoten wird ab sofort die DNS-Updates machen, auch wenn der Master noch erreichbar ist.")) return;
    try {
        const d = await api("failover", "POST", {command: "force_takeover"});
        showToast(d.message || "Aktiviert", d.success ? "success" : "error");
        await loadPeerStatus();
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function releaseFailover() {
    if (!confirm("Manuelle Übernahme zurücknehmen? Der Master übernimmt dann wieder, sofern er erreichbar ist.")) return;
    try {
        const d = await api("failover", "POST", {command: "release"});
        showToast(d.message || "Freigegeben", d.success ? "success" : "error");
        await loadPeerStatus();
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function rotateToken() {
    if (!confirm("Neuen Failover-Token erzeugen?\n\nWichtig: Der neue Token muss DANACH auf dem Peer eingetragen werden, sonst funktioniert der Heartbeat nicht mehr.")) return;
    try {
        const d = await api("failover", "POST", {command: "rotate_token"});
        if (d.success) {
            prompt("Neuer Token (jetzt kopieren!):", d.token);
            showToast("Token rotiert", "success");
        } else {
            showToast(d.error || "Fehler", "error");
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

function toggleSettings() {
    const body = document.getElementById("settings-body");
    const arrow = document.getElementById("settings-arrow");
    const isHidden = body.classList.contains("hidden");
    body.classList.toggle("hidden");
    arrow.classList.toggle("open");
    if (isHidden) loadConfig();
}

function startAutoRefresh() {
    autoRefreshId = setInterval(() => {
        loadStatus();
        loadHistory();
    }, 60000);
}

document.addEventListener("DOMContentLoaded", () => {
    loadStatus();
    loadHistory();
    startAutoRefresh();
});
