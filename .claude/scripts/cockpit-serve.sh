#!/usr/bin/env bash
# cockpit-serve.sh — Phase 3a (issue #69) live HTTP serve mode for cockpit.sh.
#
# Wraps the EXISTING one-shot renderer (cockpit.sh) behind a tiny node
# `http` server: no new dependencies (node built-ins only), bound to
# 127.0.0.1 only. Rendering itself is never reimplemented here — every
# request shells back into `cockpit.sh` so there is exactly ONE HTML
# generator to keep in sync (mirrors cockpit.sh's own --parse-blocking seam).
#
# Usage:
#   cockpit-serve.sh [port] [--fixtures <dir>]
#     port          optional positional arg, default 8090
#     --fixtures    same offline seam as cockpit.sh: read <dir>/issues.json,
#                   <dir>/prs.json, <dir>/events.jsonl instead of gh/network
#                   and the real event log. Used by cockpit.test.sh's serve
#                   smoke case — no network/gh in tests.
#
# Routes:
#   GET  /            the dashboard (cockpit.sh's HTML with the SSE/theme
#                      client script injected before </body>). Served from a
#                      short-lived cache (COCKPIT_GH_REFRESH seconds, default
#                      60) so gh-backed sections aren't re-rendered on every
#                      request; the client's own timer/button call
#                      /api/refresh to force an immediate re-render.
#   GET  /events       SSE stream of the live-progress event log (JSONL).
#                      Replays whatever is already in the file on connect
#                      (so a client that connects right after an append still
#                      sees it), then streams every subsequent appended line
#                      as its own `data:` event, plus a `: ping` heartbeat
#                      every 15s. Watches via fs.watch AND a polling fallback
#                      (fs.watch is unreliable on some filesystems/OSes).
#   GET  /api/refresh  forces an immediate re-render (bypassing the cache)
#                      and returns 200 {"ok":true} (or {"ok":false,"error"}
#                      on failure). The injected client calls this from its
#                      refresh timer and its manual "Refresh now" button.
#
# Foreground process — SIGTERM/SIGINT close the server cleanly (via `exec`,
# below, node receives signals directly; no bash wrapper indirection).
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
cockpit="$script_dir/cockpit.sh"

# ---------------------------------------------------------------------------
# Args: [port] [--fixtures <dir>]
# ---------------------------------------------------------------------------
port=""
fixtures=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fixtures) fixtures="$2"; shift 2 ;;
    --fixtures=*) fixtures="${1#--fixtures=}"; shift ;;
    *) port="$1"; shift ;;
  esac
done
port="${port:-8090}"

# Same offline seam as cockpit.sh: in --fixtures mode, watch the fixture's
# events.jsonl, never the real (gitignored) event log.
if [ -n "$fixtures" ]; then
  events_file="$fixtures/events.jsonl"
else
  events_file="${CLAUDE_EVENTS_FILE:-$root/.claude/state/events.jsonl}"
fi

gh_refresh="${COCKPIT_GH_REFRESH:-60}"

tmp_out="$(mktemp "${TMPDIR:-/tmp}/cockpit-serve.XXXXXX.html")"
trap 'rm -f "$tmp_out"' EXIT

# `exec` replaces this shell with node (same PID) so SIGTERM/SIGINT go
# straight to node's own handlers below — no bash signal-forwarding needed.
COCKPIT_SERVE_SELF="$cockpit" \
COCKPIT_SERVE_FIXTURES="$fixtures" \
COCKPIT_SERVE_PORT="$port" \
COCKPIT_SERVE_EVENTS_FILE="$events_file" \
COCKPIT_SERVE_GH_REFRESH="$gh_refresh" \
COCKPIT_SERVE_TMP_OUT="$tmp_out" \
exec node - <<'NODE_SERVE'
const http = require("http");
const fs = require("fs");
const { execFileSync } = require("child_process");

const SELF = process.env.COCKPIT_SERVE_SELF;
const FIXTURES = process.env.COCKPIT_SERVE_FIXTURES || "";
const PORT = parseInt(process.env.COCKPIT_SERVE_PORT, 10) || 8090;
const EVENTS_FILE = process.env.COCKPIT_SERVE_EVENTS_FILE;
const GH_REFRESH_SECONDS = parseInt(process.env.COCKPIT_SERVE_GH_REFRESH, 10) || 60;
const GH_REFRESH_MS = GH_REFRESH_SECONDS * 1000;
const TMP_OUT = process.env.COCKPIT_SERVE_TMP_OUT;

// ---------------------------------------------------------------------------
// Render cache: re-run cockpit.sh (the ONE renderer) at most once per
// GH_REFRESH_MS, unless a caller forces it (GET /api/refresh, or the very
// first request). This is what keeps serve mode from shelling out to gh on
// every single page load while still staying live.
// ---------------------------------------------------------------------------
let cache = { html: null, ts: 0, err: null };

function render() {
  const args = [SELF];
  if (FIXTURES) args.push("--fixtures", FIXTURES);
  args.push(TMP_OUT);
  execFileSync("bash", args, { stdio: ["ignore", "ignore", "inherit"] });
  const html = fs.readFileSync(TMP_OUT, "utf8");
  cache = { html, ts: Date.now(), err: null };
  return html;
}

function getHtml(force) {
  const stale = !cache.html || Date.now() - cache.ts > GH_REFRESH_MS;
  if (force || stale) {
    try {
      return render();
    } catch (e) {
      cache.err = e;
      if (cache.html) return cache.html; // degrade to last-good render
      throw e;
    }
  }
  return cache.html;
}

// ---------------------------------------------------------------------------
// Client script injected into GET / only (never shipped in cockpit.sh's own
// static output) — SSE live-updates + a "stale since ..." badge + a manual
// refresh button that also drives the timed gh-backed refresh. Vanilla JS,
// no frameworks/external assets; every dynamic value from the server lands
// via textContent, never innerHTML.
// ---------------------------------------------------------------------------
function clientScript() {
  return `
<script>
(function () {
  try {
    var h1 = document.querySelector("h1");
    var statusBadge = document.createElement("span");
    statusBadge.id = "stream-status";
    statusBadge.style.marginLeft = "0.5rem";
    statusBadge.style.fontSize = "0.8rem";
    statusBadge.style.padding = "0.15rem 0.6rem";
    statusBadge.style.borderRadius = "4px";
    statusBadge.style.display = "none";
    var refreshBtn = document.createElement("button");
    refreshBtn.id = "manual-refresh";
    refreshBtn.type = "button";
    refreshBtn.textContent = "Refresh now";
    refreshBtn.style.marginLeft = "0.5rem";
    if (h1) { h1.appendChild(refreshBtn); h1.appendChild(statusBadge); }

    function setStale(isStale) {
      if (!statusBadge) return;
      if (isStale) {
        statusBadge.textContent = "stale since " + new Date().toLocaleTimeString();
        statusBadge.style.background = "#3d330f";
        statusBadge.style.color = "#ffd873";
        statusBadge.style.display = "inline-block";
      } else {
        statusBadge.style.display = "none";
      }
    }

    function ensureLiveTable() {
      var section = document.getElementById("live");
      if (!section) return null;
      var table = section.querySelector("table.routing");
      if (table) return table.querySelector("tbody");
      var placeholders = section.querySelectorAll("p");
      placeholders.forEach(function (p) { p.remove(); });
      table = document.createElement("table");
      table.className = "routing";
      var thead = document.createElement("thead");
      var headRow = document.createElement("tr");
      ["Role", "Task", "Model", "Phase", "Lens", "Updated"].forEach(function (label) {
        var th = document.createElement("th");
        th.textContent = label;
        headRow.appendChild(th);
      });
      thead.appendChild(headRow);
      table.appendChild(thead);
      var tbody = document.createElement("tbody");
      table.appendChild(tbody);
      section.appendChild(table);
      return tbody;
    }

    // In-place row upsert keyed by (role,task), mirroring cockpit.sh's own
    // dedup-to-latest-phase semantics -- every field lands via textContent
    // only, so an event payload can never execute as markup.
    function upsertRow(ev) {
      var tbody = ensureLiveTable();
      if (!tbody) return;
      var role = ev.role != null ? String(ev.role) : "";
      var task = ev.task != null ? String(ev.task) : "";
      var id = "live-row-" + encodeURIComponent(role) + "--" + encodeURIComponent(task);
      var row = document.getElementById(id);
      if (!row) {
        row = document.createElement("tr");
        row.id = id;
        for (var i = 0; i < 6; i++) row.appendChild(document.createElement("td"));
        tbody.appendChild(row);
      }
      row.setAttribute("data-role", role);
      row.setAttribute("data-task", task);
      var cells = row.children;
      cells[0].textContent = role;
      cells[1].textContent = task;
      cells[2].textContent = ev.model || "(none)";
      cells[3].textContent = ev.phase || "(unknown)";
      cells[4].textContent = ev.lens || "";
      cells[5].textContent = ev.ts || "";
    }

    function connect() {
      var es = new EventSource("/events");
      es.onopen = function () { setStale(false); };
      es.onerror = function () { setStale(true); };
      es.onmessage = function (ev) {
        setStale(false);
        var payload;
        try { payload = JSON.parse(ev.data); } catch (e) { return; }
        if (payload && typeof payload === "object" && !Array.isArray(payload)) upsertRow(payload);
      };
    }

    function doRefresh() {
      fetch("/api/refresh").then(function () { location.reload(); }).catch(function () { location.reload(); });
    }
    refreshBtn.addEventListener("click", doRefresh);
    setInterval(doRefresh, ${GH_REFRESH_MS});

    connect();
  } catch (e) { /* inert on any DOM/EventSource-less environment */ }
})();
</script>`;
}

function injectClientScript(html) {
  const script = clientScript();
  if (html.includes("</body>")) return html.replace("</body>", script + "\n</body>");
  return html + script;
}

// ---------------------------------------------------------------------------
// /events — SSE. Replays whatever is already in EVENTS_FILE on connect (so a
// line appended just before the client connects is still delivered), then
// streams each newly appended line as its own event. fs.watch is
// unreliable on some platforms/filesystems, so a size/mtime poll runs
// alongside it as a fallback -- both funnel through the same "read from
// offset" step, so neither path can double-deliver a line.
// ---------------------------------------------------------------------------
function handleEvents(req, res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  let offset = 0;
  let closed = false;

  function pump() {
    if (closed) return;
    fs.stat(EVENTS_FILE, (err, stat) => {
      if (closed) return;
      if (err) return; // file missing yet -- nothing to send
      if (stat.size <= offset) return; // no new bytes
      fs.open(EVENTS_FILE, "r", (openErr, fd) => {
        if (closed) return;
        if (openErr) return;
        const len = stat.size - offset;
        const buf = Buffer.alloc(len);
        fs.read(fd, buf, 0, len, offset, (readErr, bytesRead) => {
          fs.close(fd, () => {});
          if (closed || readErr) return;
          offset += bytesRead;
          const text = buf.toString("utf8", 0, bytesRead);
          for (const line of text.split("\n")) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            // One JSONL line -> one SSE `data:` line; the payload itself is
            // JSON (never multi-line here), so no need to fold newlines.
            res.write(`data: ${trimmed}\n\n`);
          }
        });
      });
    });
  }

  const heartbeat = setInterval(() => {
    if (!closed) res.write(": ping\n\n");
  }, 15000);

  const poll = setInterval(pump, 1000);

  let watcher = null;
  try {
    watcher = fs.watch(EVENTS_FILE, { persistent: false }, () => pump());
  } catch (e) {
    // ENOENT (file doesn't exist yet) or platform without fs.watch support
    // on this path -- the poll interval above still covers it.
    watcher = null;
  }

  // Initial replay of whatever's already on disk.
  pump();

  req.on("close", () => {
    closed = true;
    clearInterval(heartbeat);
    clearInterval(poll);
    if (watcher) watcher.close();
  });
}

function handleRefresh(req, res) {
  try {
    getHtml(true);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  } catch (e) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
  }
}

function handleIndex(req, res) {
  try {
    const html = injectClientScript(getHtml(false));
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(html);
  } catch (e) {
    res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("cockpit-serve: render failed — " + String((e && e.message) || e));
  }
}

const server = http.createServer((req, res) => {
  const url = (req.url || "/").split("?")[0];
  if (req.method !== "GET") {
    res.writeHead(405, { "Content-Type": "text/plain" });
    res.end("method not allowed");
    return;
  }
  if (url === "/" || url === "/index.html") return handleIndex(req, res);
  if (url === "/events") return handleEvents(req, res);
  if (url === "/api/refresh") return handleRefresh(req, res);
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
});

// Best-effort warm cache so the first real request doesn't pay the initial
// render latency; failure here is not fatal -- getHtml() will retry lazily.
try { render(); } catch (e) { /* surfaces again on first request */ }

server.listen(PORT, "127.0.0.1", () => {
  console.log(`cockpit serving on http://127.0.0.1:${PORT}`);
});

function shutdown() {
  server.close(() => process.exit(0));
  // Force-exit if close() hangs on a slow keep-alive connection.
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
NODE_SERVE
