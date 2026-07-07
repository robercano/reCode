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
#   GET  /api/worker/<role>/<task>
#                      Worker inspector (issue #70), backing the drawer that
#                      opens when a live-progress row is clicked. Returns
#                      JSON: { role, task, timeline, breadcrumbs, worktree }.
#                        - timeline: every events.jsonl record matching
#                          (role,task), NEWEST FIRST.
#                        - breadcrumbs: the most recent non-empty --detail
#                          values (subset of timeline), surfaced separately
#                          so the drawer can show them prominently.
#                        - worktree: forensics computed LIVE by shelling out
#                          to git (zero agent tokens) against the worker's
#                          worktree — located by directory name
#                          `.claude/worktrees/issue-<task>` or, failing that,
#                          a registered worktree whose branch matches
#                          `feat/issue-<task>-*`. { found, path, branch,
#                          status, commits, diffstat, mergeBase, error }; if
#                          no worktree matches, found:false with a plain
#                          "no worktree found" error string (never a crash).
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

# Worker-inspector forensics root (issue #70): the directory that CONTAINS
# .claude/worktrees/ and the git repo itself, so /api/worker/<role>/<task>
# can locate a worker's worktree by name or by branch. Defaults to $root
# (same consumer-project root everything else here uses); overridable so
# cockpit.test.sh can point it at a synthetic temp repo/worktree instead of
# the real one — no network/gh either way, just local git plumbing.
worktrees_root="${COCKPIT_SERVE_WORKTREES_ROOT:-$root}"

tmp_out="$(mktemp "${TMPDIR:-/tmp}/cockpit-serve.XXXXXX.html")"
# NOTE: deliberately NO bash `trap ... EXIT` here. `exec` below REPLACES this
# shell process image with node (same PID) — a bash-level EXIT trap
# registered before `exec` would sit there registered but never fire once
# node takes over, which used to leak one temp HTML file per invocation
# (3a-followup fix, issue #70). Node now owns TMP_OUT's entire lifecycle and
# removes it itself via its own 'exit' handler, below, which fires for every
# exit path (normal return, process.exit() from shutdown(), and uncaught
# exceptions alike).
#
# `exec` replaces this shell with node (same PID) so SIGTERM/SIGINT go
# straight to node's own handlers below — no bash signal-forwarding needed.
COCKPIT_SERVE_SELF="$cockpit" \
COCKPIT_SERVE_FIXTURES="$fixtures" \
COCKPIT_SERVE_PORT="$port" \
COCKPIT_SERVE_EVENTS_FILE="$events_file" \
COCKPIT_SERVE_GH_REFRESH="$gh_refresh" \
COCKPIT_SERVE_TMP_OUT="$tmp_out" \
COCKPIT_SERVE_WORKTREES_ROOT="$worktrees_root" \
exec node - <<'NODE_SERVE'
const http = require("http");
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const SELF = process.env.COCKPIT_SERVE_SELF;
const FIXTURES = process.env.COCKPIT_SERVE_FIXTURES || "";
const PORT = parseInt(process.env.COCKPIT_SERVE_PORT, 10) || 8090;
const EVENTS_FILE = process.env.COCKPIT_SERVE_EVENTS_FILE;
const GH_REFRESH_SECONDS = parseInt(process.env.COCKPIT_SERVE_GH_REFRESH, 10) || 60;
const GH_REFRESH_MS = GH_REFRESH_SECONDS * 1000;
const TMP_OUT = process.env.COCKPIT_SERVE_TMP_OUT;
const WORKTREES_ROOT = process.env.COCKPIT_SERVE_WORKTREES_ROOT || process.cwd();

// Fix (issue #70, 3a-followup): TMP_OUT cleanup moved here from the now-dead
// bash EXIT trap (see the shell comment above `exec node`, above) — this
// fires on every node exit path, so the temp HTML file cockpit.sh renders
// into no longer leaks one file per invocation.
process.on("exit", () => {
  try { fs.unlinkSync(TMP_OUT); } catch (e) { /* already gone, or never created */ }
});

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

    // Worker inspector drawer (issue #70): clicking a live-worker row fetches
    // GET /api/worker/<role>/<task> and shows its event timeline (newest
    // first), latest breadcrumbs, and worktree forensics in a side panel.
    // Every dynamic value lands via textContent only (never innerHTML),
    // mirroring upsertRow()'s XSS-safety contract above.
    var drawerStyle = document.createElement("style");
    drawerStyle.textContent = "#live tbody tr { cursor: pointer; } #live tbody tr:hover { outline: 1px solid currentColor; }";
    document.head.appendChild(drawerStyle);

    var drawer = null;
    function ensureDrawer() {
      if (drawer) return drawer;
      drawer = document.createElement("div");
      drawer.id = "worker-drawer";
      drawer.setAttribute("style", "position:fixed;top:0;right:0;bottom:0;width:min(480px,90vw);overflow-y:auto;" +
        "background:#161b22;color:#e6edf3;border-left:1px solid #30363d;padding:1rem;" +
        "box-shadow:-2px 0 8px rgba(0,0,0,0.4);display:none;z-index:1000;");

      var closeBtn = document.createElement("button");
      closeBtn.type = "button";
      closeBtn.textContent = "Close";
      closeBtn.addEventListener("click", function () { drawer.style.display = "none"; });

      var title = document.createElement("h2");
      title.id = "drawer-title";

      var breadcrumbsHeading = document.createElement("h3");
      breadcrumbsHeading.textContent = "Latest breadcrumbs";
      var breadcrumbsList = document.createElement("ul");
      breadcrumbsList.id = "drawer-breadcrumbs";

      var forensicsHeading = document.createElement("h3");
      forensicsHeading.textContent = "Worktree forensics";
      var forensicsBody = document.createElement("pre");
      forensicsBody.id = "drawer-forensics";
      forensicsBody.style.whiteSpace = "pre-wrap";
      forensicsBody.style.fontSize = "0.8rem";

      var timelineHeading = document.createElement("h3");
      timelineHeading.textContent = "Event timeline (newest first)";
      var timelineList = document.createElement("ul");
      timelineList.id = "drawer-timeline";

      drawer.appendChild(closeBtn);
      drawer.appendChild(title);
      drawer.appendChild(breadcrumbsHeading);
      drawer.appendChild(breadcrumbsList);
      drawer.appendChild(forensicsHeading);
      drawer.appendChild(forensicsBody);
      drawer.appendChild(timelineHeading);
      drawer.appendChild(timelineList);
      document.body.appendChild(drawer);
      return drawer;
    }

    function renderDrawer(role, task, data) {
      var d = ensureDrawer();
      d.querySelector("#drawer-title").textContent = "Worker: " + role + " / " + task;

      var breadcrumbsList = d.querySelector("#drawer-breadcrumbs");
      breadcrumbsList.textContent = "";
      var crumbs = (data && data.breadcrumbs) || [];
      if (crumbs.length === 0) {
        var noCrumb = document.createElement("li");
        noCrumb.textContent = "(no breadcrumbs yet)";
        breadcrumbsList.appendChild(noCrumb);
      } else {
        crumbs.forEach(function (c) {
          var li = document.createElement("li");
          li.textContent = "[" + (c.phase || "") + "] " + (c.detail || "") + " (" + (c.ts || "") + ")";
          breadcrumbsList.appendChild(li);
        });
      }

      var forensicsBody = d.querySelector("#drawer-forensics");
      var wt = (data && data.worktree) || { found: false };
      if (!wt.found) {
        forensicsBody.textContent = "no worktree found" + (wt.error ? " (" + wt.error + ")" : "");
      } else {
        var lines = [];
        lines.push("path: " + (wt.path || ""));
        lines.push("branch: " + (wt.branch || ""));
        lines.push("");
        lines.push("status --short:");
        lines.push(wt.status && wt.status.length ? wt.status : "(clean)");
        lines.push("last 5 commits:");
        (wt.commits && wt.commits.length ? wt.commits : ["(none)"]).forEach(function (c) { lines.push("  " + c); });
        lines.push("");
        lines.push("diffstat vs main:");
        lines.push(wt.diffstat && wt.diffstat.length ? wt.diffstat : "(no diff)");
        if (wt.error) lines.push("\n(note: " + wt.error + ")");
        forensicsBody.textContent = lines.join("\n");
      }

      var timelineList = d.querySelector("#drawer-timeline");
      timelineList.textContent = "";
      var tl = (data && data.timeline) || [];
      if (tl.length === 0) {
        var noEv = document.createElement("li");
        noEv.textContent = "(no events)";
        timelineList.appendChild(noEv);
      } else {
        tl.forEach(function (ev) {
          var li = document.createElement("li");
          var lensPart = ev.lens ? " (" + ev.lens + ")" : "";
          var detailPart = ev.detail ? ": " + ev.detail : "";
          li.textContent = (ev.ts || "") + " — " + (ev.phase || "") + lensPart + detailPart;
          timelineList.appendChild(li);
        });
      }

      d.style.display = "block";
    }

    // Server-rendered rows (cockpit.sh) carry role/task on a hidden trailing
    // <td class="wrow-meta">; SSE-created rows (upsertRow(), above) carry
    // them directly as data-role/data-task on the <tr> itself. Support both.
    function rowRoleTask(tr) {
      if (!tr) return null;
      var role = tr.getAttribute("data-role");
      var task = tr.getAttribute("data-task");
      if (role != null && task != null) return { role: role, task: task };
      var meta = tr.querySelector("td.wrow-meta");
      if (meta) return { role: meta.getAttribute("data-role") || "", task: meta.getAttribute("data-task") || "" };
      return null;
    }

    document.addEventListener("click", function (ev) {
      var tr = ev.target && ev.target.closest ? ev.target.closest("#live tbody tr") : null;
      if (!tr) return;
      var rt = rowRoleTask(tr);
      if (!rt) return;
      fetch("/api/worker/" + encodeURIComponent(rt.role) + "/" + encodeURIComponent(rt.task))
        .then(function (r) { return r.json(); })
        .then(function (data) { renderDrawer(rt.role, rt.task, data); })
        .catch(function () { /* inert on fetch failure -- drawer just doesn't open */ });
    });

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
      // Fix (issue #70, 3a-followup): log-event.sh rotates events.jsonl (caps
      // it to the last EVENTS_MAX_LINES lines via a temp-file + atomic mv —
      // see log-event.sh), which can shrink the file below our current read
      // offset. Left unhandled, every future stat.size <= offset check below
      // would stay permanently true and this subscriber would silently stop
      // tailing forever. If the file is now SMALLER than where we'd read to,
      // it rotated (or was truncated/replaced) -- reset to 0 and resume
      // tailing from the top of the new file.
      if (stat.size < offset) offset = 0;
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

// ---------------------------------------------------------------------------
// /api/worker/<role>/<task> — worker inspector (issue #70). Zero agent
// tokens: everything here is either read from the local events.jsonl or
// computed live by shelling out to git. See the route-table comment near the
// top of this file for the exact JSON shape.
// ---------------------------------------------------------------------------
function readEventsAll() {
  let text = "";
  try { text = fs.readFileSync(EVENTS_FILE, "utf8"); } catch (e) { return []; }
  const out = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const obj = JSON.parse(trimmed);
      // typeof [] === "object" too -- exclude arrays, mirroring cockpit.sh's
      // own readEvents() malformed/array-line tolerance.
      if (obj && typeof obj === "object" && !Array.isArray(obj)) out.push(obj);
    } catch (e) { /* skip malformed line */ }
  }
  return out;
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Locate the worker's worktree: prefer the conventional directory name, else
// fall back to scanning `git worktree list` for a branch matching
// feat/issue-<task>-*. Returns an absolute path, or null if neither matches
// (degrade path -- the caller renders a "no worktree found" marker instead
// of erroring).
function findWorktree(taskId) {
  const byName = path.join(WORKTREES_ROOT, ".claude", "worktrees", `issue-${taskId}`);
  try {
    if (fs.statSync(byName).isDirectory()) return byName;
  } catch (e) { /* not found by name -- fall through to the branch scan */ }

  try {
    const out = execFileSync("git", ["-C", WORKTREES_ROOT, "worktree", "list", "--porcelain"], {
      encoding: "utf8",
    });
    const branchRe = new RegExp("^refs/heads/feat/issue-" + escapeRegExp(taskId) + "-.*$");
    let candidatePath = null;
    let candidateBranch = null;
    for (const rawLine of out.split("\n")) {
      const line = rawLine.trim();
      if (line.startsWith("worktree ")) {
        candidatePath = line.slice("worktree ".length);
        candidateBranch = null;
      } else if (line.startsWith("branch ")) {
        candidateBranch = line.slice("branch ".length);
        if (candidatePath && candidateBranch && branchRe.test(candidateBranch)) return candidatePath;
      } else if (line === "") {
        candidatePath = null;
        candidateBranch = null;
      }
    }
  } catch (e) { /* WORKTREES_ROOT isn't a git repo, or git is unavailable */ }

  return null;
}

// Worktree forensics (issue #70): current branch, short status, last 5
// commits, and a diffstat vs main's merge-base. Every git call is wrapped
// individually so one missing ref (e.g. no local "main") degrades that ONE
// field rather than failing the whole endpoint.
function gatherForensics(wtPath) {
  const result = {
    found: true,
    path: wtPath,
    branch: null,
    status: "",
    commits: [],
    diffstat: "",
    mergeBase: null,
    error: null,
  };
  const errors = [];

  try {
    result.branch = execFileSync("git", ["-C", wtPath, "rev-parse", "--abbrev-ref", "HEAD"], {
      encoding: "utf8",
    }).trim();
  } catch (e) { errors.push("branch: " + String((e && e.message) || e)); }

  try {
    result.status = execFileSync("git", ["-C", wtPath, "status", "--short"], { encoding: "utf8" });
  } catch (e) { errors.push("status: " + String((e && e.message) || e)); }

  try {
    const log = execFileSync("git", ["-C", wtPath, "log", "--oneline", "-5"], { encoding: "utf8" });
    result.commits = log.split("\n").filter((l) => l.length > 0);
  } catch (e) { errors.push("log: " + String((e && e.message) || e)); }

  let mergeBaseOk = false;
  for (const base of ["main", "origin/main"]) {
    try {
      const mb = execFileSync("git", ["-C", wtPath, "merge-base", base, "HEAD"], { encoding: "utf8" }).trim();
      result.mergeBase = mb;
      result.diffstat = execFileSync("git", ["-C", wtPath, "diff", "--stat", `${mb}...HEAD`], {
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
      });
      mergeBaseOk = true;
      break;
    } catch (e) { /* try the next base candidate */ }
  }
  if (!mergeBaseOk) errors.push("diffstat: no merge-base found against main/origin main");

  if (errors.length) result.error = errors.join("; ");
  return result;
}

// Rejects role/task values that could escape their intended slot: a path
// separator or ".." would let `task` reach outside WORKTREES_ROOT/.claude/worktrees/
// in findWorktree()'s path.join(), and a NUL would truncate a C-string arg.
// All git calls already use execFileSync with arg arrays (no shell), so this
// is defense-in-depth, not the only guard -- but it closes the traversal note.
function isUnsafeIdentifier(s) {
  return /[/\\]|\.\.|\x00/.test(s);
}

function handleWorkerInspector(req, res, rawRole, rawTask) {
  let role, task;
  try {
    role = decodeURIComponent(rawRole);
    task = decodeURIComponent(rawTask);
  } catch (e) {
    res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "malformed URI component in worker path" }));
    return;
  }
  if (isUnsafeIdentifier(role) || isUnsafeIdentifier(task)) {
    res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "role/task must not contain path separators, \"..\", or NUL" }));
    return;
  }
  try {
    const allEvents = readEventsAll();
    const matching = allEvents.filter((ev) => {
      const evRole = ev.role != null ? String(ev.role) : "";
      const evTask = ev.task != null ? String(ev.task) : "";
      return evRole === role && evTask === task;
    });
    const timeline = matching.slice().reverse(); // NEWEST FIRST (file/append order reversed)
    const breadcrumbs = timeline
      .filter((ev) => ev.detail != null && String(ev.detail).trim() !== "")
      .slice(0, 10)
      .map((ev) => ({ ts: ev.ts || "", phase: ev.phase || "", detail: String(ev.detail) }));

    const wtPath = findWorktree(task);
    const worktree = wtPath
      ? gatherForensics(wtPath)
      : {
          found: false,
          path: null,
          branch: null,
          status: "",
          commits: [],
          diffstat: "",
          mergeBase: null,
          error: "no worktree found for task " + task,
        };

    const body = JSON.stringify({ role, task, timeline, breadcrumbs, worktree });
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end(body);
  } catch (e) {
    res.writeHead(500, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: String((e && e.message) || e) }));
  }
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
  const workerMatch = url.match(/^\/api\/worker\/([^/]+)\/([^/]+)$/);
  if (workerMatch) {
    return handleWorkerInspector(req, res, workerMatch[1], workerMatch[2]);
  }
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
