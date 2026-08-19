"use strict";

const $ = (sel) => document.querySelector(sel);
let lastStatus = null;
let logsTimer = null;
let busy = false;

async function getJSON(path) {
  const resp = await fetch(path, { cache: "no-store" });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || ("HTTP " + resp.status));
  return data;
}

async function postJSON(path, body) {
  const resp = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || ("HTTP " + resp.status));
  return data;
}

function fmtMiB(mib) {
  if (mib == null) return "–";
  return mib >= 1024 ? (mib / 1024).toFixed(1) + " GiB" : Math.round(mib) + " MiB";
}

function fmtUptime(seconds) {
  if (seconds == null) return "–";
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const mm = String(m).padStart(2, "0"), ss = String(sec).padStart(2, "0");
  return h > 0 ? h + "h " + mm + "m" : m + "m " + ss + "s";
}

const PHASE_META = {
  running: { badge: "running", pill: "running", dot: "ok", label: "running" },
  ready: { badge: "running", pill: "running", dot: "ok", label: "running" },
  starting: { badge: "starting", pill: "starting", dot: "warn", label: "starting" },
  failed: { badge: "failed", pill: "failed", dot: "bad", label: "failed" },
  stopped: { badge: "stopped", pill: "stopped", dot: "bad", label: "stopped" },
};

function phaseMeta(phase) {
  return PHASE_META[phase] || PHASE_META.stopped;
}

function renderGpus(gpus, gpusError) {
  const list = $("#gpuList");
  if (gpusError) {
    list.innerHTML = '<div class="placeholder">nvidia-smi unavailable: ' + escapeHtml(gpusError) + "</div>";
  } else if (!gpus || !gpus.length) {
    list.innerHTML = '<div class="placeholder">no GPUs detected</div>';
  } else {
    list.innerHTML = gpus.map((g) => {
      const pct = g.total_mib > 0 ? (g.used_mib / g.total_mib) * 100 : 0;
      const cls = pct > 90 ? "hot" : pct > 50 ? "" : "cold";
      return '<div class="card">' +
        '<div class="gpu-stats"><span class="gpu-name">GPU ' + g.index + " · " + escapeHtml(g.name) + "</span>" +
        '<span>util ' + g.util_pct + "%</span></div>" +
        '<div class="bar ' + cls + '"><div style="width:' + pct.toFixed(1) + '%"></div></div>' +
        '<div class="gpu-stats"><span>' + fmtMiB(g.used_mib) + " used</span><span>" + fmtMiB(g.free_mib) + " free / " + fmtMiB(g.total_mib) + " total</span></div>" +
        "</div>";
    }).join("");
  }
  const hm = lastStatus && lastStatus.host_memory;
  $("#hostMem").textContent = hm && hm.memtotal
    ? "host RAM: " + fmtMiB(hm.memtotal) + " total · " + fmtMiB(hm.memavailable) + " available"
    : "";
}

function renderModels(models, backend) {
  const list = $("#modelList");
  list.innerHTML = models.map((m) => {
    const isCurrent = backend.model && backend.model.id === m.id;
    const phase = isCurrent ? backend.phase : "stopped";
    const meta = phaseMeta(phase);
    const badge = '<span class="badge ' + meta.badge + '">' + meta.label + "</span>";
    const dir = '<div class="meta">' + escapeHtml(m.model_dir) + "</div>";
    const served = '<div class="meta">served as: ' + escapeHtml(m.served_name) + "</div>";
    const note = m.note ? '<div class="note">' + escapeHtml(m.note) + "</div>" : "";
    const servingVision = isCurrent && backend.vision === true;
    const visionRow =
      '<label class="vision-row" title="restarts the backend when toggled on the running model">' +
      '<input type="checkbox" data-act="vision" data-model="' + escapeHtml(m.id) + '"' + (m.vision ? " checked" : "") + ">" +
      "<span>vision input" + (servingVision ? " · 👁 serving" : "") + "</span>" +
      "</label>";

    let actions;
    if (isCurrent && (phase === "running" || phase === "ready" || phase === "starting")) {
      actions = '<button class="danger" data-act="stop" data-model="' + escapeHtml(m.id) + '" ' + (phase === "starting" ? "disabled" : "") + ">Stop</button>" +
        '<button data-act="logs" data-model="' + escapeHtml(m.id) + '">Logs</button>';
    } else if (isCurrent && phase === "failed") {
      actions = '<button class="primary" data-act="start" data-model="' + escapeHtml(m.id) + '">Restart</button>' +
        '<button data-act="logs" data-model="' + escapeHtml(m.id) + '">Logs</button>';
    } else if (backend.model && backend.model.id !== m.id && backend.phase !== "stopped" && backend.phase !== "failed") {
      actions = '<button class="primary" data-act="switch" data-model="' + escapeHtml(m.id) + '">Switch to this model</button>' +
        '<button data-act="logs" data-model="' + escapeHtml(m.id) + '">Logs</button>';
    } else {
      actions = '<button class="primary" data-act="start" data-model="' + escapeHtml(m.id) + '">Start</button>' +
        '<button data-act="logs" data-model="' + escapeHtml(m.id) + '">Logs</button>';
    }

    const failure = isCurrent && phase === "failed" && backend.failure
      ? '<div class="failure-box">' + escapeHtml(backend.failure) + "</div>"
      : "";

    return '<div class="card' + (isCurrent ? " active" : "") + '">' +
      "<h3>" + escapeHtml(m.display_name) + " " + badge + "</h3>" +
      dir + served + note + visionRow +
      '<div class="actions">' + actions + "</div>" + failure +
      "</div>";
  }).join("");
}

function renderHeader(backend) {
  const phase = backend.phase || "stopped";
  const meta = phaseMeta(phase);
  const pill = $("#backendPill");
  const name = backend.model ? backend.model.served_name : "no model";
  pill.className = "pill " + meta.pill;
  pill.textContent = "backend: " + name + " · " + meta.label;
  $("#managerDot").className = "dot " + (backend.healthy || phase === "starting" ? (phase === "starting" ? "warn" : "ok") : "bad");
  $("#clockPill").textContent = phase === "running" || phase === "starting"
    ? "up " + fmtUptime(backend.uptime_s)
    : new Date().toLocaleTimeString();
}

function renderStatus(status) {
  lastStatus = status;
  const backend = status.backend;
  renderHeader(backend);
  renderGpus(status.gpus, status.gpus_error);
  renderModels(status.models, backend);
  const api = status.manager && status.manager.api_url;
  if (api) $("#apiUrl").textContent = api;
  if (status.host) $("#hostName").textContent = status.host;
  $("#lastUpdated").textContent = "updated " + new Date().toLocaleTimeString();
  if (!logsTimer && (backend.phase === "running" || backend.phase === "starting" || backend.phase === "ready")) {
    startLogs();
  } else if (logsTimer && backend.phase !== "running" && backend.phase !== "starting" && backend.phase !== "ready") {
    stopLogs();
  }
}

async function refreshLogs() {
  try {
    const data = await getJSON("api/logs?lines=150");
    $("#logView").textContent = data.log || "(empty log)";
    $("#logLabel").textContent = data.model ? "model: " + data.model : "no backend running";
  } catch (err) {
    $("#logView").textContent = "failed to read log: " + err.message;
  }
}

function startLogs() {
  if (logsTimer) return;
  refreshLogs();
  logsTimer = setInterval(refreshLogs, 4000);
}

function stopLogs() {
  if (logsTimer) { clearInterval(logsTimer); logsTimer = null; }
  $("#logLabel").textContent = "no backend running";
}

async function refresh() {
  try {
    const status = await getJSON("api/status");
    renderStatus(status);
  } catch (err) {
    $("#lastUpdated").textContent = "error: " + err.message;
  }
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

async function runAction(act, modelId) {
  if (busy) return;
  const label = {
    start: "Start " + modelId + "?",
    switch: "Switch to " + modelId + "? The running model will be stopped first (takes ~1 min to swap + model load).",
    stop: "Stop the running model?",
  }[act];
  if (!window.confirm(label)) return;
  busy = true;
  document.querySelectorAll("button[data-act]").forEach((b) => (b.disabled = true));
  try {
    if (act === "start") await postJSON("api/start", { model: modelId });
    else if (act === "switch") await postJSON("api/switch", { model: modelId });
    else if (act === "stop") await postJSON("api/stop", {});
    await refresh();
  } catch (err) {
    window.alert("action failed: " + err.message);
    await refresh();
  } finally {
    busy = false;
    document.querySelectorAll("button[data-act]").forEach((b) => (b.disabled = false));
  }
}

document.addEventListener("change", async (ev) => {
  const cb = ev.target.closest("input[data-act='vision']");
  if (!cb || busy) return;
  const modelId = cb.dataset.model;
  const enabled = cb.checked;
  const status = lastStatus || {};
  const backend = status.backend || {};
  const isCurrent = backend.model && backend.model.id === modelId;
  const running = isCurrent && (backend.phase === "ready" || backend.phase === "starting");
  const msg = running
    ? (enabled
        ? "Enable vision input for the running model? The backend will restart (~2-3 min)."
        : "Disable vision input for the running model? The backend will restart (~2-3 min).")
    : (enabled
        ? "Enable vision input for " + modelId + "? Applies the next time it starts."
        : "Disable vision input for " + modelId + "? Applies the next time it starts.");
  if (!window.confirm(msg)) { cb.checked = !enabled; return; }
  busy = true;
  document.querySelectorAll("button[data-act], input[data-act]").forEach((el) => (el.disabled = true));
  try {
    await postJSON("api/vision", { model: modelId, enabled });
    await refresh();
  } catch (err) {
    window.alert("vision toggle failed: " + err.message);
    cb.checked = !enabled;
    await refresh();
  } finally {
    busy = false;
    document.querySelectorAll("button[data-act], input[data-act]").forEach((el) => (el.disabled = false));
  }
});

document.addEventListener("click", (ev) => {
  const btn = ev.target.closest("button[data-act]");
  if (!btn) return;
  if (btn.dataset.act === "logs") {
    stopLogs();
    const modelId = btn.dataset.model;
    getJSON("api/logs?lines=200&model=" + encodeURIComponent(modelId))
      .then((data) => {
        $("#logView").textContent = data.log || "(no log for this model yet)";
        $("#logLabel").textContent = "model: " + (data.model || modelId);
      })
      .catch((err) => ($("#logView").textContent = "failed to read log: " + err.message));
    return;
  }
  runAction(btn.dataset.act, btn.dataset.model);
});

$("#logRefresh").addEventListener("click", () => {
  if (logsTimer) { refreshLogs(); } else { stopLogs(); refreshLogs(); }
});

refresh();
setInterval(refresh, 3000);
