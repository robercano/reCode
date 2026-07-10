#!/usr/bin/env bash
# cockpit.sh — Phase 1 read-only dashboard (issue #51), extended in Phase 2
# (issue #52) with a live per-worker progress panel: a single static HTML
# snapshot of open issues (grouped by module label, with a parsed blocking
# graph), open PRs (review + CI state), model/skill routing (agent frontmatter
# + adapter config), active worker worktrees, and — from the local progress
# event log (see log-event.sh) — the CURRENT phase of every in-flight worker
# (scoped/implementing/gate-running/reviewing/done). Regenerated on demand —
# no persistent server, no watch daemon (re-run this script, or wrap it in
# `watch -n 30 bash .claude/scripts/cockpit.sh`).
#
# Issue #85 adds a "Loop health" panel, sourced from loop-tick.sh's tick
# record log (see loop-tick.sh's write_tick_record): the last tick's verdict,
# the current cadence (FAST/WATCH/IDLE), the full verdict history (newest
# first), and a STALLED banner if no tick has landed in over 2x the cadence's
# expected interval (FAST=60s -> 120s, WATCH=300s -> 600s, IDLE=900s -> 1800s).
#
# Usage:
#   cockpit.sh [--fixtures <dir>] [output-path]
#   cockpit.sh --parse-blocking
#     Reads one issue body on stdin, prints its parsed blocking edges as JSON:
#     {"blockedBy":[...],"blocks":[...],"taskRefs":[...]}. Used internally
#     (the render step below shells back into this same script per issue) AND
#     directly by cockpit.test.sh, so there is exactly ONE implementation of
#     the parser to keep in sync.
#
# --fixtures <dir>: read <dir>/issues.json and <dir>/prs.json (arrays shaped
# like `gh issue|pr list --json ...` output) instead of calling gh at all.
# This is the offline seam cockpit.test.sh uses — no live gh/network in tests.
# In this mode, the live-progress panel also reads <dir>/events.jsonl (if
# present; missing = "no active workers") instead of the real event log, and
# the loop-health panel likewise reads <dir>/loop-ticks.jsonl (if present;
# missing = "loop not armed"), so tests never touch .claude/state/.
#
# Degrades gracefully: if a bot-gh.sh call fails (no network / no gh auth),
# that section renders an "unavailable (gh/network)" placeholder instead of
# data, and the script still exits 0 — reviewers/CI may run with no network,
# and this must never hard-crash on that.
#
# Output: self-contained HTML (inline CSS, no external CDN/JS/fonts), default
# .claude/state/cockpit.html (that dir is gitignored — never commit the
# generated artifact). Pass a second positional arg to write elsewhere.
#
# Phase 3a (issue #69): dark theme by default (with a light-theme toggle,
# persisted client-side in localStorage — inert/harmless if run in a
# file:// context with no localStorage), plus a client-side module-header
# click filter over the issue list. Both are small inline <script> blocks
# appended near the end of <body>; cockpit-serve.sh (serve mode) injects
# ITS OWN separate SSE/refresh client script by string-replacing </body>,
# so the live-stream code never ships in this static output.
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
self="$script_dir/cockpit.sh"
# Agent definitions ship with the PLUGIN, not the consumer repo: prefer the
# project's own .claude/agents (repo/worktree layout, or a consumer override),
# else the plugin-cache layout where agents/ sits beside scripts/.
agents_dir="$root/.claude/agents"
[ -d "$agents_dir" ] || agents_dir="$script_dir/../agents"

# ---------------------------------------------------------------------------
# Hidden seam: the blocking-graph parser as its own subcommand, so it has
# exactly one implementation. Recognizes, case-insensitively:
#   "Blocked by #N[, #M ...]"   → blockedBy
#   "Blocks #N[, #M ...]"       → blocks
#   "- [ ] #N ..." / "- [x] #N ..." task-list lines → taskRefs
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--parse-blocking" ]; then
  node -e '
    const fs = require("fs");
    const body = fs.readFileSync(0, "utf8");

    // Collect every "#N" found in a bounded window right after each match of
    // phraseRe — up to the next newline or sentence end — so e.g.
    // "blocked by #12. This blocks #99." does not bleed numbers across the
    // two different phrases.
    function extractAfterPhrase(text, phraseRe) {
      const nums = new Set();
      const flags = phraseRe.flags.includes("g") ? phraseRe.flags : phraseRe.flags + "g";
      const re = new RegExp(phraseRe.source, flags);
      let m;
      while ((m = re.exec(text))) {
        const rest = text.slice(m.index + m[0].length);
        const cut = rest.search(/[\n]|\.(?!\d)/);
        const window = cut === -1 ? rest.slice(0, 200) : rest.slice(0, cut);
        (window.match(/#(\d+)/g) || []).forEach((t) => nums.add(parseInt(t.slice(1), 10)));
      }
      return [...nums].sort((a, b) => a - b);
    }

    const blockedBy = extractAfterPhrase(body, /blocked\s+by\b/i);
    const blocks = extractAfterPhrase(body, /\bblocks\b/i);

    const taskRefs = new Set();
    const taskRe = /^[ \t]*-[ \t]*\[[ xX]\][ \t]*#(\d+)/gm;
    let tm;
    while ((tm = taskRe.exec(body))) taskRefs.add(parseInt(tm[1], 10));

    process.stdout.write(JSON.stringify({
      blockedBy,
      blocks,
      taskRefs: [...taskRefs].sort((a, b) => a - b),
    }));
  '
  exit $?
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
fixtures=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fixtures) fixtures="$2"; shift 2 ;;
    --fixtures=*) fixtures="${1#--fixtures=}"; shift ;;
    *) out="$1"; shift ;;
  esac
done
out="${out:-$root/.claude/state/cockpit.html}"
case "$out" in
  /*) : ;;
  *) out="$root/$out" ;;
esac
mkdir -p "$(dirname "$out")"

# gh entry point — overridable so tests can stub a failing "gh" without
# touching real auth/network (see cockpit.test.sh's degrade-path case).
gh_bin="${COCKPIT_GH_BIN:-$script_dir/bot-gh.sh}"
gh() { "$gh_bin" "$@"; }

# Adapter to read for model/skill routing — same override contract as
# gate.sh/worktree.sh (GATES_FILE env, relative paths resolve from repo root),
# so self-hosting this repo can point it at .claude/self/gates.json.
gates_ref="${GATES_FILE:-.claude/gates.json}"
case "$gates_ref" in
  /*) gates="$gates_ref" ;;
  *) gates="$root/$gates_ref" ;;
esac

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cockpit.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

valid_json() { node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' <"$1" >/dev/null 2>&1; }

# ---- issues -----------------------------------------------------------------
issues_unavailable=0
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/issues.json" ]; then cp "$fixtures/issues.json" "$tmpdir/issues.json"; else echo "[]" >"$tmpdir/issues.json"; fi
else
  if ! gh issue list --state open --limit 200 --json number,title,url,labels,body >"$tmpdir/issues.json" 2>"$tmpdir/issues.err"; then
    issues_unavailable=1
  fi
  if [ "$issues_unavailable" -eq 0 ] && ! valid_json "$tmpdir/issues.json"; then issues_unavailable=1; fi
  [ "$issues_unavailable" -eq 1 ] && echo "[]" >"$tmpdir/issues.json"
fi

# ---- PRs ----------------------------------------------------------------------
prs_unavailable=0
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/prs.json" ]; then cp "$fixtures/prs.json" "$tmpdir/prs.json"; else echo "[]" >"$tmpdir/prs.json"; fi
else
  if ! gh pr list --state open --limit 200 --json number,title,url,headRefName,reviewDecision,statusCheckRollup >"$tmpdir/prs.json" 2>"$tmpdir/prs.err"; then
    prs_unavailable=1
  fi
  if [ "$prs_unavailable" -eq 0 ] && ! valid_json "$tmpdir/prs.json"; then prs_unavailable=1; fi
  [ "$prs_unavailable" -eq 1 ] && echo "[]" >"$tmpdir/prs.json"
fi

# ---- agent model/skill routing (static config, always read locally) -----------
node -e '
  const fs = require("fs"), path = require("path");
  const dir = process.argv[1];
  const out = [];
  let files = [];
  try { files = fs.readdirSync(dir).filter((f) => f.endsWith(".md")).sort(); } catch (e) {}
  for (const f of files) {
    let text = "";
    try { text = fs.readFileSync(path.join(dir, f), "utf8"); } catch (e) { continue; }
    const fm = text.match(/^---\n([\s\S]*?)\n---/);
    let role = f.replace(/\.md$/, ""), model = "", description = "";
    if (fm) {
      const body = fm[1];
      const nm = body.match(/^name:\s*(.+)$/m); if (nm) role = nm[1].trim();
      const mm = body.match(/^model:\s*(.+)$/m); if (mm) model = mm[1].trim();
      const dm = body.match(/^description:\s*(.+)$/m); if (dm) description = dm[1].trim();
    }
    out.push({ role, model, description });
  }
  fs.writeFileSync(process.argv[2], JSON.stringify(out));
' "$agents_dir" "$tmpdir/agents.json"

# ---- adapter (review lenses/skills, budget) ------------------------------------
node -e '
  const fs = require("fs");
  let g = null;
  try { g = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { g = null; }
  const out = {
    path: process.argv[2],
    available: g !== null,
    lenses: (g && g.review && g.review.lenses) || [],
    skills: (g && g.review && g.review.skills) || [],
    budget: (g && g.budget) || {},
  };
  fs.writeFileSync(process.argv[3], JSON.stringify(out));
' "$gates" "$gates_ref" "$tmpdir/adapter.json"

# ---- live worker progress events (issue #52) -------------------------------
# Never reads the real event log in --fixtures mode (offline seam for tests).
# Otherwise honors CLAUDE_EVENTS_FILE for parity with log-event.sh, defaulting
# to the same gitignored .claude/state/events.jsonl. Missing/empty log is not
# an error — it just means no workers are currently in flight.
if [ -n "$fixtures" ]; then
  events_file="$fixtures/events.jsonl"
else
  events_file="${CLAUDE_EVENTS_FILE:-$root/.claude/state/events.jsonl}"
fi
if [ -f "$events_file" ]; then cp "$events_file" "$tmpdir/events.jsonl"; else : >"$tmpdir/events.jsonl"; fi

# ---- loop tick records (issue #85, "Loop health" panel) --------------------
# Same offline seam as the events.jsonl block above: fixtures mode reads
# <dir>/loop-ticks.jsonl (if present); otherwise honors CLAUDE_TICKS_FILE for
# parity with loop-tick.sh's own override, defaulting to the same gitignored
# .claude/state/loop-ticks.jsonl. A missing/empty log just means the loop has
# never ticked (or isn't armed yet) — rendered as a placeholder below, never
# an error.
if [ -n "$fixtures" ]; then
  ticks_file="$fixtures/loop-ticks.jsonl"
else
  ticks_file="${CLAUDE_TICKS_FILE:-$root/.claude/state/loop-ticks.jsonl}"
fi
if [ -f "$ticks_file" ]; then cp "$ticks_file" "$tmpdir/loop-ticks.jsonl"; else : >"$tmpdir/loop-ticks.jsonl"; fi

# ---- active worktrees -----------------------------------------------------------
node -e '
  const fs = require("fs");
  const dir = process.argv[1];
  let names = [];
  try {
    names = fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  } catch (e) {}
  fs.writeFileSync(process.argv[2], JSON.stringify(names));
' "$root/.claude/worktrees" "$tmpdir/worktrees.json"

# ---------------------------------------------------------------------------
# Render — one node process reads all the gathered JSON + flags and writes the
# final self-contained HTML file.
# ---------------------------------------------------------------------------
COCKPIT_TMPDIR="$tmpdir" \
COCKPIT_SELF="$self" \
COCKPIT_OUT="$out" \
COCKPIT_ISSUES_UNAVAILABLE="$issues_unavailable" \
COCKPIT_PRS_UNAVAILABLE="$prs_unavailable" \
COCKPIT_GATES_REF="$gates_ref" \
COCKPIT_NOW="${COCKPIT_NOW:-}" \
COCKPIT_VERDICT_HISTORY_N="${COCKPIT_VERDICT_HISTORY_N:-10}" \
node - <<'NODE_RENDER'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const tmpdir = process.env.COCKPIT_TMPDIR;
const readJson = (name, fallback) => {
  try { return JSON.parse(fs.readFileSync(path.join(tmpdir, name), "utf8")); } catch (e) { return fallback; }
};

const issues = readJson("issues.json", []);
const prs = readJson("prs.json", []);
const agents = readJson("agents.json", []);
const adapter = readJson("adapter.json", { path: process.env.COCKPIT_GATES_REF, available: false, lenses: [], skills: [], budget: {} });
const worktrees = readJson("worktrees.json", []);
const issuesUnavailable = process.env.COCKPIT_ISSUES_UNAVAILABLE === "1";
const prsUnavailable = process.env.COCKPIT_PRS_UNAVAILABLE === "1";

// Live progress events (issue #52): JSONL, one object per line. Tolerate
// blank/malformed lines — skip them, never crash the whole render.
function readEvents() {
  let text = "";
  try { text = fs.readFileSync(path.join(tmpdir, "events.jsonl"), "utf8"); } catch (e) { return []; }
  const events = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const obj = JSON.parse(trimmed);
      // typeof [] === "object" too, so exclude arrays explicitly -- otherwise
      // a stray JSON-array line would produce a phantom worker row below.
      if (obj && typeof obj === "object" && !Array.isArray(obj)) events.push(obj);
    } catch (e) { /* skip malformed line */ }
  }
  return events;
}
const events = readEvents();

// Loop tick records (issue #85): JSONL, one object per line, appended by
// loop-tick.sh's write_tick_record — schema {ts, verdict, cadence, action,
// issue, pr}. Same tolerate-and-skip contract as readEvents() above: a
// blank/malformed line must never crash the whole render.
function readTicks() {
  let text = "";
  try { text = fs.readFileSync(path.join(tmpdir, "loop-ticks.jsonl"), "utf8"); } catch (e) { return []; }
  const ticks = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const obj = JSON.parse(trimmed);
      if (obj && typeof obj === "object" && !Array.isArray(obj)) ticks.push(obj);
    } catch (e) { /* skip malformed line */ }
  }
  return ticks;
}
const ticks = readTicks();

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Shell back into cockpit.sh's own --parse-blocking so the blocking-graph
// parser has exactly one implementation (also exercised directly by
// cockpit.test.sh).
function parseBlocking(body) {
  try {
    const stdout = execFileSync("bash", [process.env.COCKPIT_SELF, "--parse-blocking"], {
      input: body || "",
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    });
    return JSON.parse(stdout);
  } catch (e) {
    return { blockedBy: [], blocks: [], taskRefs: [] };
  }
}

const knownIssueNumbers = new Set(issues.map((i) => i.number));
function refLink(n) {
  return knownIssueNumbers.has(n) ? `<a href="#issue-${n}">#${n}</a>` : `#${n}`;
}
function refList(nums) {
  return nums.map(refLink).join(", ");
}

function moduleLabelsOf(issue) {
  return (issue.labels || []).map((l) => l.name).filter((n) => typeof n === "string" && n.startsWith("module:"));
}

// ---- Live worker progress section (issue #52) -----------------------------
// Derive the CURRENT state per worker keyed by (role, task): keep the LATEST
// event (by file order, i.e. append order) per key. No event log, or an
// empty one, renders a muted "no active workers" placeholder — never a
// crash, matching Phase 1's degrade contract.
function phaseBadge(phase) {
  switch (phase) {
    case "done": return { cls: "good" };
    case "gate-running":
    case "reviewing":
    case "implementing":
    case "scoped": return { cls: "warn" };
    default: return { cls: "muted" };
  }
}
function renderLiveProgress() {
  const latest = new Map(); // "role\u0000task" -> event
  for (const ev of events) {
    const role = ev.role != null ? String(ev.role) : "";
    const task = ev.task != null ? String(ev.task) : "";
    const key = role + "\u0000" + task;
    latest.set(key, ev); // later lines overwrite earlier ones for the same key
  }
  const workers = [...latest.values()];
  let html = `<section id="live"><h2>Live worker progress</h2>`;
  if (workers.length === 0) {
    html += `<p class="muted">no active workers</p>`;
  } else {
    html += `<table class="routing"><thead><tr><th>Role</th><th>Task</th><th>Model</th><th>Phase</th><th>Lens</th><th>Updated</th><th hidden></th></tr></thead><tbody>`;
    for (const w of workers) {
      const badge = phaseBadge(w.phase);
      html += `<tr><td>${esc(w.role)}</td><td>${esc(w.task)}</td><td><code>${esc(w.model || "(none)")}</code></td>`;
      html += `<td><span class="badge ${badge.cls}">${esc(w.phase || "(unknown)")}</span></td>`;
      html += `<td>${esc(w.lens || "")}</td><td>${esc(w.ts)}</td>`;
      // Hidden trailing cell: stable data-role/data-task hook for a FUTURE
      // worker inspector (issue 3b). Appended AFTER every column the
      // existing tests exact-match, so it never disturbs them.
      html += `<td class="wrow-meta" data-role="${esc(w.role)}" data-task="${esc(w.task)}" hidden></td></tr>`;
    }
    html += `</tbody></table>`;
  }
  html += `</section>`;
  return html;
}

// ---- Loop health section (issue #85) ---------------------------------------
// Sourced from loop-tick.sh's tick record log (loop-ticks.jsonl, one line per
// firing, file order == append order == chronological). No records at all
// (missing file, or a file with zero valid lines) means the loop has never
// ticked in this environment -- rendered as "loop not armed", never a crash.
// Otherwise: the last tick's ts/verdict, the current cadence, a STALLED
// banner when now - lastTick exceeds 2x the cadence's expected interval, and
// the last N verdict lines, newest-first (N is bounded, NOT the full
// potentially ~2000-row retained log -- see COCKPIT_VERDICT_HISTORY_N below).
const CADENCE_INTERVAL_SECONDS = { FAST: 60, WATCH: 300, IDLE: 900 };
const nowMs = process.env.COCKPIT_NOW ? Date.parse(process.env.COCKPIT_NOW) : Date.now();
// Verdict-history table depth: "the last N verdict lines, newest first"
// (issue #85). Overridable for testability, consistent with the
// COCKPIT_NOW/CLAUDE_TICKS_FILE override style used elsewhere in this file.
// Falls back to 10 if unset/non-numeric/non-positive.
const VERDICT_HISTORY_N = (() => {
  const n = parseInt(process.env.COCKPIT_VERDICT_HISTORY_N, 10);
  return Number.isFinite(n) && n > 0 ? n : 10;
})();
function renderLoopHealth() {
  let html = `<section id="loop-health"><h2>Loop health</h2>`;
  if (ticks.length === 0) {
    html += `<p class="muted">loop not armed</p></section>`;
    return html;
  }
  const last = ticks[ticks.length - 1]; // file order = append order -> last line = most recent tick
  const cadence = last.cadence != null ? String(last.cadence) : "";
  const intervalSec = CADENCE_INTERVAL_SECONDS[cadence];

  html += `<p>Last tick: <code>${esc(last.ts)}</code> &middot; verdict <code>${esc(last.verdict)}</code></p>`;
  html += `<p>Cadence: <span class="badge muted">${esc(cadence || "(unknown)")}</span>`;
  if (intervalSec) html += ` <span class="muted">(every ${intervalSec}s)</span>`;
  html += `</p>`;

  const lastMs = Date.parse(last.ts);
  let stalled = false;
  if (intervalSec && Number.isFinite(lastMs) && Number.isFinite(nowMs)) {
    stalled = nowMs - lastMs > intervalSec * 2 * 1000;
  }
  if (stalled) {
    html += `<p class="unavailable">STALLED — no tick in over ${intervalSec * 2}s (cadence ${esc(cadence)})</p>`;
  }

  html += `<table class="routing"><thead><tr><th>Time</th><th>Verdict</th><th>Cadence</th></tr></thead><tbody>`;
  const historyStop = Math.max(0, ticks.length - VERDICT_HISTORY_N);
  for (let i = ticks.length - 1; i >= historyStop; i--) {
    const t = ticks[i];
    html += `<tr><td>${esc(t.ts)}</td><td><code>${esc(t.verdict)}</code></td><td>${esc(t.cadence)}</td></tr>`;
  }
  html += `</tbody></table>`;

  html += `</section>`;
  return html;
}

// ---- Issues section: group by module label, parse blocking graph per issue ----
function renderIssues() {
  if (issuesUnavailable) {
    return `<section id="issues"><h2>Open issues</h2><p class="unavailable">unavailable (gh/network)</p></section>`;
  }
  const groups = new Map(); // moduleName -> issue[]
  for (const issue of issues) {
    const mods = moduleLabelsOf(issue);
    const key = mods.length ? mods[0] : "unlabeled";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(issue);
  }
  const keys = [...groups.keys()].sort((a, b) => {
    if (a === "unlabeled") return 1;
    if (b === "unlabeled") return -1;
    return a.localeCompare(b);
  });

  let html = `<section id="issues"><h2>Open issues (${issues.length})</h2>`;
  if (keys.length === 0) {
    html += `<p class="muted">No open issues.</p>`;
  }
  for (const key of keys) {
    const list = groups.get(key).sort((a, b) => a.number - b.number);
    html += `<h3>${esc(key)}</h3><ul class="issue-list">`;
    for (const issue of list) {
      const edges = parseBlocking(issue.body || "");
      html += `<li id="issue-${issue.number}" data-module="${esc(key)}"><a href="${esc(issue.url || "#")}">#${issue.number}</a> ${esc(issue.title)}`;
      const rel = [];
      if (edges.blockedBy.length) rel.push(`Blocked by ${refList(edges.blockedBy)}`);
      if (edges.blocks.length) rel.push(`Blocks ${refList(edges.blocks)}`);
      if (edges.taskRefs.length) rel.push(`Subtasks ${refList(edges.taskRefs)}`);
      if (rel.length) html += `<div class="rel">${rel.join(" &middot; ")}</div>`;
      html += `</li>`;
    }
    html += `</ul>`;
  }
  html += `</section>`;
  return html;
}

// ---- PRs section: review decision + CI rollup ----------------------------------
function reviewBadge(rd) {
  switch (rd) {
    case "APPROVED": return { label: "approved", cls: "good" };
    case "CHANGES_REQUESTED": return { label: "changes requested", cls: "bad" };
    case "REVIEW_REQUIRED": return { label: "review required", cls: "warn" };
    default: return { label: "pending", cls: "warn" };
  }
}
function ciBadge(rollup) {
  if (!rollup || rollup.length === 0) return { label: "no checks", cls: "muted" };
  let hasFailure = false, hasPending = false;
  for (const c of rollup) {
    if (c.conclusion !== undefined && c.conclusion !== null && c.conclusion !== "") {
      if (["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"].includes(c.conclusion)) hasFailure = true;
      if (c.status && c.status !== "COMPLETED") hasPending = true;
    } else if (c.state) {
      if (["FAILURE", "ERROR"].includes(c.state)) hasFailure = true;
      if (c.state === "PENDING") hasPending = true;
    }
  }
  if (hasFailure) return { label: "failing", cls: "bad" };
  if (hasPending) return { label: "pending", cls: "warn" };
  return { label: "passing", cls: "good" };
}
function renderPRs() {
  if (prsUnavailable) {
    return `<section id="prs"><h2>Open PRs</h2><p class="unavailable">unavailable (gh/network)</p></section>`;
  }
  let html = `<section id="prs"><h2>Open PRs (${prs.length})</h2>`;
  if (prs.length === 0) {
    html += `<p class="muted">No open PRs.</p>`;
  } else {
    html += `<ul class="pr-list">`;
    for (const pr of prs.sort((a, b) => a.number - b.number)) {
      const review = reviewBadge(pr.reviewDecision);
      const ci = ciBadge(pr.statusCheckRollup);
      html += `<li><a href="${esc(pr.url || "#")}">#${pr.number}</a> ${esc(pr.title)}`;
      html += ` <span class="badge ${review.cls}">review: ${review.label}</span>`;
      html += ` <span class="badge ${ci.cls}">CI: ${ci.label}</span>`;
      if (pr.headRefName) html += ` <span class="muted">(${esc(pr.headRefName)})</span>`;
      html += `</li>`;
    }
    html += `</ul>`;
  }
  html += `</section>`;
  return html;
}

// ---- Routing section: per-role model + adapter review/budget config ------------
function renderRouting() {
  let html = `<section id="routing"><h2>Model / skill routing</h2>`;
  html += `<table class="routing"><thead><tr><th>Role</th><th>model:</th><th>Description</th></tr></thead><tbody>`;
  if (agents.length === 0) {
    html += `<tr><td colspan="3" class="muted">No agent frontmatter found under .claude/agents/.</td></tr>`;
  }
  for (const a of agents) {
    html += `<tr><td>${esc(a.role)}</td><td><code>${esc(a.model || "(none)")}</code></td><td>${esc(a.description)}</td></tr>`;
  }
  html += `</tbody></table>`;
  html += `<p class="muted">Adapter: <code>${esc(adapter.path)}</code>${adapter.available ? "" : " (not found — showing defaults)"}</p>`;
  html += `<p>review.lenses: ${adapter.lenses.length ? adapter.lenses.map(esc).join(", ") : "<span class=\"muted\">(none)</span>"}</p>`;
  html += `<p>review.skills: ${adapter.skills.length ? adapter.skills.map(esc).join(", ") : "<span class=\"muted\">(none)</span>"}</p>`;
  const b = adapter.budget || {};
  html += `<table class="routing"><thead><tr><th>Budget key</th><th>Value</th></tr></thead><tbody>`;
  const budgetKeys = ["orchestrator_model", "worker_model", "explorer_model", "reviewer_model", "max_parallel_workers"];
  for (const k of budgetKeys) {
    html += `<tr><td>${esc(k)}</td><td><code>${esc(b[k] != null ? b[k] : "(unset)")}</code></td></tr>`;
  }
  html += `</tbody></table></section>`;
  return html;
}

// ---- Active worktrees section ---------------------------------------------------
function renderWorktrees() {
  let html = `<section id="worktrees"><h2>Active worktrees</h2>`;
  if (worktrees.length === 0) {
    html += `<p class="muted">none active</p>`;
  } else {
    html += `<ul>` + worktrees.map((w) => `<li><code>${esc(w)}</code></li>`).join("") + `</ul>`;
  }
  html += `</section>`;
  return html;
}

const generatedAt = Number.isFinite(nowMs) ? new Date(nowMs).toISOString() : new Date().toISOString();
// Dark-theme stable marker (issue #69): the `data-theme="dark"` attribute
// below is the CONTRACT a test/consumer can grep for to confirm the default
// theme. The tiny <script> right after it restores a saved light-theme
// preference (localStorage) BEFORE <style> is applied, to avoid a flash;
// it is wrapped in try/catch so it is inert/harmless under file:// (some
// browsers restrict localStorage there) or any other odd environment.
const html = `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<title>Cockpit — reCode</title>
<script>(function(){try{var t=localStorage.getItem("cockpit-theme");if(t==="light"||t==="dark"){document.documentElement.setAttribute("data-theme",t);}}catch(e){}})();</script>
<style>
  :root {
    --bg: #0d1117;
    --bg-elevated: #161b22;
    --border: #30363d;
    --text: #e6edf3;
    --text-dim: #8b949e;
    --link: #6ea8fe;
    --code-bg: #21262d;
    --good-bg: #113626; --good-fg: #7ee2a8;
    --bad-bg: #3d1616; --bad-fg: #ff9b9b;
    --warn-bg: #3d330f; --warn-fg: #ffd873;
    --muted-bg: #21262d; --muted-fg: #8b949e;
    --shadow: rgba(0, 0, 0, 0.4);
  }
  html[data-theme="light"] {
    --bg: #fafafa;
    --bg-elevated: #fff;
    --border: #ddd;
    --text: #1a1a1a;
    --text-dim: #666;
    --link: #1a56db;
    --code-bg: #f2f2f2;
    --good-bg: #d7f7dd; --good-fg: #1a6b2c;
    --bad-bg: #fbdada; --bad-fg: #9b1c1c;
    --warn-bg: #fff3cd; --warn-fg: #8a6100;
    --muted-bg: #eee; --muted-fg: #888;
    --shadow: rgba(0, 0, 0, 0.08);
  }
  body { font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 2rem; color: var(--text); background: var(--bg); }
  h1 { margin-bottom: 0.2rem; display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
  #theme-toggle { font: inherit; font-size: 0.75rem; padding: 0.25rem 0.6rem; border-radius: 6px; border: 1px solid var(--border); background: var(--bg-elevated); color: var(--text); cursor: pointer; }
  #theme-toggle:hover { border-color: var(--link); }
  .meta { color: var(--text-dim); font-size: 0.85rem; margin-bottom: 1.5rem; }
  section { background: var(--bg-elevated); border: 1px solid var(--border); border-radius: 8px; padding: 1rem 1.5rem; margin-bottom: 1.5rem; box-shadow: 0 1px 3px var(--shadow); }
  h2 { margin-top: 0; border-bottom: 1px solid var(--border); padding-bottom: 0.4rem; }
  h3 { margin-bottom: 0.3rem; color: var(--text-dim); cursor: pointer; user-select: none; }
  #issues h3:hover { color: var(--link); }
  ul.issue-list, ul.pr-list { list-style: none; padding-left: 0; }
  ul.issue-list li, ul.pr-list li { padding: 0.4rem 0; border-bottom: 1px dashed var(--border); }
  .rel { font-size: 0.85rem; color: var(--text-dim); margin-top: 0.2rem; }
  .badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 4px; font-size: 0.8rem; margin-left: 0.3rem; }
  .badge.good { background: var(--good-bg); color: var(--good-fg); }
  .badge.bad { background: var(--bad-bg); color: var(--bad-fg); }
  .badge.warn { background: var(--warn-bg); color: var(--warn-fg); }
  .badge.muted { background: var(--muted-bg); color: var(--muted-fg); }
  .muted { color: var(--text-dim); }
  .unavailable { color: var(--bad-fg); font-style: italic; }
  table.routing { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1rem; }
  table.routing th, table.routing td { border: 1px solid var(--border); padding: 0.3rem 0.6rem; text-align: left; font-size: 0.9rem; }
  code { background: var(--code-bg); padding: 0.05rem 0.3rem; border-radius: 3px; }
  a { color: var(--link); }
</style>
</head>
<body>
<h1>Cockpit <button id="theme-toggle" type="button">Toggle theme</button></h1>
<p class="meta">Generated ${esc(generatedAt)} &middot; read-only Phase 1 snapshot (issue #51) + Phase 2 live progress (issue #52) + Phase 3a serve/theme/filter (issue #69) + loop health panel (issue #85) &middot; re-run <code>cockpit.sh</code> to refresh (or run <code>cockpit-serve.sh</code> for live auto-update)</p>
${renderLiveProgress()}
${renderLoopHealth()}
${renderIssues()}
${renderPRs()}
${renderRouting()}
${renderWorktrees()}
<script>
// Light/dark theme toggle (issue #69): flips html[data-theme] and persists
// the choice to localStorage. Wrapped in try/catch so a file:// context (or
// any environment without localStorage) never throws — purely cosmetic, so
// it is safe to no-op.
(function () {
  try {
    var KEY = "cockpit-theme";
    var root = document.documentElement;
    var btn = document.getElementById("theme-toggle");
    if (btn) {
      btn.addEventListener("click", function () {
        var current = root.getAttribute("data-theme") === "light" ? "light" : "dark";
        var next = current === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        try { localStorage.setItem(KEY, next); } catch (e) { /* ignore */ }
      });
    }
  } catch (e) { /* inert if the DOM/localStorage is unavailable */ }
})();
// Module-header click filter (issue #69): clicking a module <h3> in the
// issues section shows only that module's <li data-module="..."> rows;
// clicking the same header again (or filtering was already active) restores
// all rows. Pure client-side, no server round-trip, inert if #issues is
// absent (e.g. the gh-unavailable degrade path renders no list at all).
(function () {
  try {
    var headers = document.querySelectorAll("#issues h3");
    var items = document.querySelectorAll("#issues li[data-module]");
    headers.forEach(function (h) {
      h.addEventListener("click", function () {
        var mod = h.textContent;
        var wasActive = h.getAttribute("data-active") === "1";
        headers.forEach(function (hh) { hh.removeAttribute("data-active"); });
        items.forEach(function (li) {
          if (wasActive) {
            li.style.display = "";
          } else {
            li.style.display = li.getAttribute("data-module") === mod ? "" : "none";
          }
        });
        if (!wasActive) h.setAttribute("data-active", "1");
      });
    });
  } catch (e) { /* inert if the DOM is unavailable */ }
})();
</script>
</body>
</html>
`;

fs.writeFileSync(process.env.COCKPIT_OUT, html);
NODE_RENDER

echo "$out"
