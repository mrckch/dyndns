const API = "/cgi-bin/api.py";
let currentPage = 0;
const PAGE_SIZE = 20;
let autoRefreshId = null;
let currentRole = "single";
let domainsCache = [];
let editingDomainId = null;
let historyFilterDomain = "";

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

        const domainsTxt = (d.domains_enabled || 0) + " / " + (d.domains_total || 0) +
            " (" + (d.hosts_enabled || 0) + " Hosts)";
        document.getElementById("st-domains").textContent = domainsTxt;
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
        const extra = historyFilterDomain ? `&domain=${encodeURIComponent(historyFilterDomain)}` : "";
        const d = await api("history", "GET", null, extra);
        const tbody = document.getElementById("history-body");
        if (!d.entries || d.entries.length === 0) {
            tbody.innerHTML = '<tr><td colspan="7" class="empty">Keine Einträge vorhanden</td></tr>';
        } else {
            tbody.innerHTML = d.entries.map(e => {
                const domainCell = e.domain
                    ? escHtml(e.domain)
                    : '<span class="muted">(legacy)</span>';
                const hostCell = e.host ? escHtml(e.host) : "—";
                return `
                <tr class="row-${e.status}">
                    <td title="${e.timestamp}">${relTime(e.timestamp)}</td>
                    <td>${domainCell}</td>
                    <td class="mono">${hostCell}</td>
                    <td class="mono">${e.old_ip || "—"}</td>
                    <td class="mono">${e.new_ip || "—"}</td>
                    <td><span class="badge badge-${e.status}">${
                        { success: "OK", failure: "Fehler", skipped: "Übersprungen", error: "Fehler" }[e.status] || e.status
                    }</span></td>
                    <td>${escHtml(e.message || "")}</td>
                </tr>`;
            }).join("");
        }

        const totalPages = Math.max(1, Math.ceil(d.total / PAGE_SIZE));
        document.getElementById("page-info").textContent = `${currentPage + 1} / ${totalPages}`;
        document.getElementById("btn-prev").disabled = currentPage === 0;
        document.getElementById("btn-next").disabled = currentPage >= totalPages - 1;
    } catch (e) {
        console.error("History load failed:", e);
    }
}

function onHistoryFilterChange() {
    historyFilterDomain = document.getElementById("history-filter").value;
    currentPage = 0;
    loadHistory();
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

async function saveGeneral(event) {
    event.preventDefault();
    const data = {
        interval: parseInt(document.getElementById("cfg-interval").value, 10),
        node_name: document.getElementById("cfg-node-name").value,
    };
    await postConfig(data, "Einstellungen gespeichert");
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

// --- Domain management ---

async function loadDomains() {
    try {
        const d = await api("domains");
        domainsCache = d.domains || [];
        renderDomainsList();
        renderHistoryFilter();
    } catch (e) {
        console.error("Domains load failed:", e);
        document.getElementById("domains-list").innerHTML =
            '<div class="empty">Domains konnten nicht geladen werden.</div>';
    }
}

function renderDomainsList() {
    const container = document.getElementById("domains-list");
    if (!domainsCache.length) {
        container.innerHTML = '<div class="empty">Noch keine Domains konfiguriert. Klick auf "+ Neue Domain".</div>';
        return;
    }
    container.innerHTML = domainsCache.map(d => {
        const hosts = (d.hosts || []).map(h => `
            <li class="host-row ${h.enabled ? "" : "host-disabled"}">
                <label class="toggle">
                    <input type="checkbox" ${h.enabled ? "checked" : ""}
                        onchange="toggleHost('${d.id}', '${escAttr(h.host)}', this.checked)">
                    <span class="slider"></span>
                </label>
                <span class="mono host-name">${escHtml(h.host)}</span>
                <span class="host-fqdn muted">${h.host === "@" ? escHtml(d.domain) : escHtml(h.host + "." + d.domain)}</span>
            </li>`).join("");
        return `
        <div class="domain-card ${d.enabled ? "" : "domain-disabled"}">
            <div class="domain-head">
                <label class="toggle" title="Domain aktivieren/deaktivieren">
                    <input type="checkbox" ${d.enabled ? "checked" : ""}
                        onchange="toggleDomain('${d.id}', this.checked)">
                    <span class="slider"></span>
                </label>
                <span class="domain-name">${escHtml(d.domain)}</span>
                <span class="domain-meta muted">${(d.hosts || []).length} Host(s)${d.password_set ? "" : " · ⚠ kein Passwort"}</span>
                <div class="domain-actions">
                    <button class="btn btn-sm" onclick="openDomainEditor('${d.id}')">Bearbeiten</button>
                    <button class="btn btn-sm btn-danger" onclick="deleteDomain('${d.id}', '${escAttr(d.domain)}')">Löschen</button>
                </div>
            </div>
            <ul class="host-list">${hosts}</ul>
        </div>`;
    }).join("");
}

function renderHistoryFilter() {
    const sel = document.getElementById("history-filter");
    if (!sel) return;
    const current = sel.value;
    const opts = ['<option value="">Alle Domains</option>']
        .concat(domainsCache.map(d => `<option value="${escAttr(d.domain)}">${escHtml(d.domain)}</option>`));
    sel.innerHTML = opts.join("");
    if (current && domainsCache.some(d => d.domain === current)) {
        sel.value = current;
    } else {
        historyFilterDomain = "";
    }
}

function escAttr(s) {
    return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

async function toggleDomain(id, enabled) {
    try {
        const d = await api("domain-toggle", "POST", { id, target: "domain", enabled });
        if (d.success) {
            showToast(enabled ? "Domain aktiviert" : "Domain deaktiviert", "success");
            await loadDomains();
            await loadStatus();
        } else {
            showToast(d.error || "Fehler", "error");
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function toggleHost(id, host, enabled) {
    try {
        const d = await api("domain-toggle", "POST", { id, target: "host", host, enabled });
        if (d.success) {
            await loadDomains();
            await loadStatus();
        } else {
            showToast(d.error || "Fehler", "error");
            await loadDomains();
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

async function deleteDomain(id, name) {
    if (!confirm(`Domain "${name}" wirklich löschen?\n\nDas DynDNS-Passwort und alle Host-Einträge werden entfernt. Die Historie bleibt erhalten.`)) return;
    try {
        const d = await api("domain-delete", "POST", { id });
        if (d.success) {
            showToast("Domain gelöscht", "success");
            await loadDomains();
            await loadStatus();
        } else {
            showToast(d.error || "Fehler", "error");
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

function openDomainEditor(id) {
    editingDomainId = id || null;
    const existing = id ? domainsCache.find(d => d.id === id) : null;
    document.getElementById("domain-modal-title").textContent =
        existing ? "Domain bearbeiten" : "Neue Domain";

    const domainInput = document.getElementById("dm-domain");
    const pwInput = document.getElementById("dm-password");
    domainInput.value = existing ? existing.domain : "";
    domainInput.disabled = !!existing;
    pwInput.value = "";
    pwInput.placeholder = existing
        ? (existing.password_set ? "Leer = unverändert" : "Passwort eingeben")
        : "Passwort eingeben";
    pwInput.required = !existing;

    const hostsContainer = document.getElementById("dm-hosts");
    hostsContainer.innerHTML = "";
    const seedHosts = existing && existing.hosts && existing.hosts.length
        ? existing.hosts
        : [{ host: "@", enabled: true }];
    seedHosts.forEach(h => addHostRow(h.host, h.enabled));

    document.getElementById("domain-modal").classList.remove("hidden");
    setTimeout(() => domainInput.focus(), 50);
}

function closeDomainEditor() {
    document.getElementById("domain-modal").classList.add("hidden");
    editingDomainId = null;
}

function addHostRow(value = "", enabled = true) {
    const container = document.getElementById("dm-hosts");
    const row = document.createElement("div");
    row.className = "host-edit-row";
    row.innerHTML = `
        <input type="text" class="dm-host-input" value="${escAttr(value)}" placeholder="@ oder Subdomain" maxlength="63">
        <label class="check-label dm-host-enabled">
            <input type="checkbox" ${enabled ? "checked" : ""}> aktiv
        </label>
        <button type="button" class="btn btn-sm btn-ghost" onclick="this.parentNode.remove()">Entfernen</button>
    `;
    container.appendChild(row);
}

async function submitDomain(event) {
    event.preventDefault();
    const domain = document.getElementById("dm-domain").value.trim().toLowerCase();
    const password = document.getElementById("dm-password").value;
    const hosts = Array.from(document.querySelectorAll("#dm-hosts .host-edit-row")).map(row => ({
        host: row.querySelector(".dm-host-input").value.trim() || "@",
        enabled: row.querySelector(".dm-host-enabled input").checked,
    })).filter(h => h.host);

    if (!hosts.length) {
        showToast("Mindestens ein Host erforderlich", "error");
        return;
    }

    const payload = editingDomainId
        ? { id: editingDomainId, hosts }
        : { domain, password, enabled: true, hosts };

    if (editingDomainId && password) payload.password = password;
    if (!editingDomainId && !password) {
        showToast("Passwort erforderlich", "error");
        return;
    }

    const action = editingDomainId ? "domain-update" : "domain-add";
    try {
        const d = await api(action, "POST", payload);
        if (d.success) {
            showToast(editingDomainId ? "Domain aktualisiert" : "Domain hinzugefügt", "success");
            closeDomainEditor();
            await loadDomains();
            await loadStatus();
        } else {
            showToast(d.error || "Fehler", "error");
        }
    } catch (e) {
        showToast("Verbindung fehlgeschlagen", "error");
    }
}

function startAutoRefresh() {
    autoRefreshId = setInterval(() => {
        loadStatus();
        loadHistory();
        loadDomains();
    }, 60000);
}

document.addEventListener("DOMContentLoaded", () => {
    loadStatus();
    loadDomains();
    loadHistory();
    startAutoRefresh();
});
