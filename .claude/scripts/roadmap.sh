#!/usr/bin/env bash
# roadmap.sh — generates docs/ROADMAP.md, a read-only snapshot of the
# project's roadmap sourced ENTIRELY from GitHub metadata (open milestones,
# issues, PRs, and the blocking-graph edges parsed out of issue bodies) —
# issue #175.
#
# docs/ROADMAP.md is GENERATED, never hand-authored: the single source of
# truth is GitHub itself (milestones/labels/issue bodies/PR state). Re-run
# this script to refresh it; do not edit the file directly (see the marker
# this script prints at the very top of its own output, and docs/USAGE.md).
#
# Renders, per OPEN milestone (in version order — natural/`sort -V` semantics,
# same as loop-census.sh's own milestone ordering):
#   - every issue attached to it (open AND closed, so progress is visible),
#     each with a priority chip (same `priority:critical|high|medium|low`
#     label set the census/cockpit already use), a derived STATE, and its
#     "Blocked by" edges,
#   - a Mermaid graph of the "Blocked by" edges among that milestone's issues.
# Plus a trailing "Feedback inbox" section: open `feedback`-labeled issues
# that carry NO milestone yet (see docs/USAGE.md's "rollout & feedback
# companion" — that's exactly the census-invisible inbox state before owner
# triage assigns a milestone).
#
# STATE DERIVATION follows the SAME shape as loop-census.sh's own
# ADVANCE/in_flight logic (closed/PR-open/in_flight/open), re-applied here so
# an issue's roadmap state usually agrees with what the loop would report.
# NOTE (issue #175 review finding #4): this is a simplified re-application,
# not a byte-for-byte port -- it does NOT carry census's stale-merged-remote
# refinement (loop-census.sh ignores a remote-only branch whose PR already
# merged; see loop-census.sh's own header). A branch here is "existing" if
# ANY matching local/remote-tracking ref is present, full stop. In practice
# this can only over-report `in_flight` for an issue whose old PR merged but
# whose remote-tracking ref hasn't been pruned yet -- never under-report, and
# never affects census/loop-tick's own ADVANCE decisions (this script only
# renders a read-only snapshot, it never feeds back into the loop):
#   closed          — issue.state == CLOSED
#   PR#N open       — an OPEN PR's headRefName (or title "#N" mention)
#                     matches this issue number
#   in_flight       — a feat/fix/work/issue-<N>-* branch (local or
#                     remote-tracking) exists, but no open PR yet
#   open            — none of the above
#
# REUSE, not reimplementation: the "Blocked by #N"/"Blocks #N" parser is
# cockpit.sh's own `--parse-blocking` subcommand (shelled out to below, same
# as cockpit.sh's own render step does internally for its issue list) — there
# is exactly ONE implementation of that parser in this repo.
#
# gh 2.4.0 SAFE: every gh call here is a plain REST-backed `gh issue list` /
# `gh pr list` / `gh api` invocation — no `gh milestone` subcommand, no
# `gh api graphql`, no bracket-array `-f` syntax (see loop-census.sh's own
# header for the identical constraint/rationale). Always routed through
# bot-gh.sh (or $ROADMAP_GH_BIN in tests), never bare `gh`.
#
# Usage:
#   roadmap.sh [--fixtures <dir>] [--write] [output-path]
#     (default, no --write) prints the rendered Markdown to stdout — a dry
#       preview that touches no file on disk.
#     --write               persists the rendered Markdown to output-path
#       (default <root>/docs/ROADMAP.md) instead of printing it.
#     --fixtures <dir>      reads <dir>/milestones.json (raw REST milestones
#       array), <dir>/issues.json (gh issue list --json shape, plus a `state`
#       field), <dir>/prs.json (gh pr list --json shape), and
#       <dir>/branches.json (a flat array of branch short names) instead of
#       calling gh/git at all — missing files default to `[]`. This is the
#       offline seam roadmap.test.sh uses; no live gh/network/git in tests.
#
# Degrades gracefully: a failed/unavailable gh call for any of
# milestones/issues/PRs renders that section as
# "_unavailable (gh/network)_" instead of data, and the script still exits 0
# — it must never hard-crash a caller (e.g. merge-ready.sh's best-effort
# post-merge regen hook) on a missing network/auth.
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
cockpit="$script_dir/cockpit.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
fixtures=""
write=0
out_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fixtures) fixtures="$2"; shift 2 ;;
    --fixtures=*) fixtures="${1#--fixtures=}"; shift ;;
    --write) write=1; shift ;;
    *) out_arg="$1"; shift ;;
  esac
done
out="${out_arg:-$root/docs/ROADMAP.md}"
case "$out" in
  /*) : ;;
  *) out="$root/$out" ;;
esac

# gh entry point — overridable so tests can stub gh without touching real
# auth/network (same seam as cockpit.sh's COCKPIT_GH_BIN).
gh_bin="${ROADMAP_GH_BIN:-$script_dir/bot-gh.sh}"
gh() { "$gh_bin" "$@"; }

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/roadmap.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

valid_json() { node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' <"$1" >/dev/null 2>&1; }

repo=""
if [ -z "$fixtures" ]; then
  repo="${ROADMAP_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
fi

# ---- milestones (open, raw REST shape) --------------------------------------
milestones_unavailable=0
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/milestones.json" ]; then cp "$fixtures/milestones.json" "$tmpdir/milestones.json"; else echo "[]" >"$tmpdir/milestones.json"; fi
else
  if [ -n "$repo" ] && gh api --paginate "repos/$repo/milestones?state=open" >"$tmpdir/milestones.json" 2>"$tmpdir/milestones.err"; then
    :
  else
    milestones_unavailable=1
  fi
  if [ "$milestones_unavailable" -eq 0 ] && ! valid_json "$tmpdir/milestones.json"; then milestones_unavailable=1; fi
  [ "$milestones_unavailable" -eq 1 ] && echo "[]" >"$tmpdir/milestones.json"
fi

# ---- issues (ALL states — closed ones show milestone progress too) ---------
issues_unavailable=0
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/issues.json" ]; then cp "$fixtures/issues.json" "$tmpdir/issues.json"; else echo "[]" >"$tmpdir/issues.json"; fi
else
  if [ -n "$repo" ] && gh issue list -R "$repo" --state all --limit 500 \
       --json number,title,url,labels,body,milestone,state >"$tmpdir/issues.json" 2>"$tmpdir/issues.err"; then
    :
  else
    issues_unavailable=1
  fi
  if [ "$issues_unavailable" -eq 0 ] && ! valid_json "$tmpdir/issues.json"; then issues_unavailable=1; fi
  [ "$issues_unavailable" -eq 1 ] && echo "[]" >"$tmpdir/issues.json"
fi

# ---- PRs (open only — enough to derive "PR#N open") -------------------------
prs_unavailable=0
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/prs.json" ]; then cp "$fixtures/prs.json" "$tmpdir/prs.json"; else echo "[]" >"$tmpdir/prs.json"; fi
else
  if [ -n "$repo" ] && gh pr list -R "$repo" --state open --limit 200 \
       --json number,title,url,headRefName >"$tmpdir/prs.json" 2>"$tmpdir/prs.err"; then
    :
  else
    prs_unavailable=1
  fi
  if [ "$prs_unavailable" -eq 0 ] && ! valid_json "$tmpdir/prs.json"; then prs_unavailable=1; fi
  [ "$prs_unavailable" -eq 1 ] && echo "[]" >"$tmpdir/prs.json"
fi

# ---- branches (in_flight detection, issue #175 mirrors loop-census.sh) -----
if [ -n "$fixtures" ]; then
  if [ -f "$fixtures/branches.json" ]; then cp "$fixtures/branches.json" "$tmpdir/branches.json"; else echo "[]" >"$tmpdir/branches.json"; fi
else
  git -C "$root" branch -a --list 2>/dev/null | sed 's/^[+* ]*//' >"$tmpdir/branches.txt" || : >"$tmpdir/branches.txt"
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
    fs.writeFileSync(process.argv[2], JSON.stringify(lines));
  ' "$tmpdir/branches.txt" "$tmpdir/branches.json"
fi

# ---- footer facts: timestamp + generating commit SHA ------------------------
if [ -n "$fixtures" ]; then
  commit_sha="${ROADMAP_FIXTURE_SHA:-fixture}"
else
  commit_sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

# ---------------------------------------------------------------------------
# Render — one node process reads the gathered JSON and prints Markdown.
# ---------------------------------------------------------------------------
rendered="$(
ROADMAP_TMPDIR="$tmpdir" \
ROADMAP_COCKPIT="$cockpit" \
ROADMAP_SHA="$commit_sha" \
ROADMAP_NOW="${ROADMAP_NOW:-}" \
ROADMAP_MILESTONES_UNAVAILABLE="$milestones_unavailable" \
ROADMAP_ISSUES_UNAVAILABLE="$issues_unavailable" \
ROADMAP_PRS_UNAVAILABLE="$prs_unavailable" \
node - <<'NODE_RENDER'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const tmpdir = process.env.ROADMAP_TMPDIR;
const readJson = (name, fallback) => {
  try { return JSON.parse(fs.readFileSync(path.join(tmpdir, name), "utf8")); } catch (e) { return fallback; }
};

const rawMilestones = readJson("milestones.json", []);
const issues = readJson("issues.json", []);
const prs = readJson("prs.json", []);
const branches = readJson("branches.json", []);
const milestonesUnavailable = process.env.ROADMAP_MILESTONES_UNAVAILABLE === "1";
const issuesUnavailable = process.env.ROADMAP_ISSUES_UNAVAILABLE === "1";
const prsUnavailable = process.env.ROADMAP_PRS_UNAVAILABLE === "1";

function esc(s) {
  return String(s == null ? "" : s).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}
// Mermaid node labels: strip characters that break the `["..."]` shape
// (quotes/brackets), truncate so a long title doesn't blow up the graph.
function mermaidEsc(s) {
  const t = String(s == null ? "" : s).replace(/["\[\]]/g, "'").replace(/\r?\n/g, " ");
  return t.length > 48 ? t.slice(0, 45) + "..." : t;
}

// Natural/version compare (same intent as GNU `sort -V`, used by
// loop-census.sh's own milestone ordering): split into digit/non-digit runs,
// compare numeric runs numerically, everything else lexically.
function naturalCompare(a, b) {
  const re = /(\d+)|(\D+)/g;
  const as = String(a).match(re) || [];
  const bs = String(b).match(re) || [];
  const len = Math.max(as.length, bs.length);
  for (let i = 0; i < len; i++) {
    const x = as[i], y = bs[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
    if (xn && yn) {
      const diff = parseInt(x, 10) - parseInt(y, 10);
      if (diff !== 0) return diff;
    } else {
      const cmp = x.localeCompare(y);
      if (cmp !== 0) return cmp;
    }
  }
  return 0;
}

// ---- Priority chip (same label set/precedence as cockpit.sh's priorityOf) --
function hasLabel(obj, name) {
  return (obj.labels || []).some((l) => l && l.name === name);
}
const PRIORITY_LEVELS = [
  { name: "critical", chip: "🔴 critical" },
  { name: "high", chip: "🟠 high" },
  { name: "medium", chip: "🟡 medium" },
  { name: "low", chip: "⚪ low" },
];
function priorityOf(issue) {
  for (const level of PRIORITY_LEVELS) {
    if (hasLabel(issue, "priority:" + level.name)) return level;
  }
  return null;
}
// Rank for sort ordering within a milestone (issue #173's ordering, reused):
// critical=0 < high=1 < medium=2 < low=3 < unlabeled=4.
function priorityRank(issue) {
  const p = priorityOf(issue);
  if (!p) return 4;
  return PRIORITY_LEVELS.findIndex((l) => l.name === p.name);
}

// ---- Blocked-by/Blocks parsing: reuse cockpit.sh --parse-blocking ----------
function parseBlocking(body) {
  try {
    const stdout = execFileSync("bash", [process.env.ROADMAP_COCKPIT, "--parse-blocking"], {
      input: body || "",
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    });
    return JSON.parse(stdout);
  } catch (e) {
    return { blockedBy: [], blocks: [], taskRefs: [] };
  }
}

// ---- State derivation (same SHAPE as loop-census.sh's own ADVANCE/in_flight
// logic, re-applied here -- NOT the stale-merged-remote refinement, see this
// script's own header, issue #175 review finding #4) ------------------------
function findPRForIssue(n) {
  for (const pr of prs) {
    const branch = String(pr.headRefName || "");
    const m = branch.match(/issue-(\d+)(?:[-_]|$)/i);
    if (m && parseInt(m[1], 10) === n) return pr;
  }
  const titleRe = new RegExp("#" + n + "\\b");
  for (const pr of prs) {
    if (titleRe.test(String(pr.title || ""))) return pr;
  }
  return null;
}
// Any matching local OR remote-tracking ref counts as "existing" -- does NOT
// apply census's stale-merged-remote refinement (a remote-only ref whose PR
// already merged is still "existing" here), so this can over-report
// in_flight for a stale ref; see this script's header, issue #175 finding #4.
function branchExistsForIssue(n) {
  const re = /(?:^|\/)(?:remotes\/[^/]+\/)?(?:feat|fix|work)\/issue-(\d+)(?:[-_]|$)/i;
  return branches.some((b) => {
    const m = String(b).match(re);
    return m && parseInt(m[1], 10) === n;
  });
}
function stateOf(issue) {
  if (String(issue.state || "").toUpperCase() === "CLOSED") return { label: "closed", pr: null };
  const pr = findPRForIssue(issue.number);
  if (pr) return { label: `PR#${pr.number} open`, pr };
  if (branchExistsForIssue(issue.number)) return { label: "in_flight", pr: null };
  return { label: "open", pr: null };
}

// ---- Group issues by milestone title ---------------------------------------
const byMilestone = new Map(); // title -> issue[]
const unmilestoned = [];
for (const issue of issues) {
  const title = issue.milestone && issue.milestone.title;
  if (title) {
    if (!byMilestone.has(title)) byMilestone.set(title, []);
    byMilestone.get(title).push(issue);
  } else {
    unmilestoned.push(issue);
  }
}

// ---- Milestones, open, in version order ------------------------------------
const milestones = rawMilestones
  .filter((m) => m && m.state !== "closed")
  .slice()
  .sort((a, b) => naturalCompare(a.title, b.title));

const lines = [];
lines.push("<!-- GENERATED FILE — DO NOT EDIT BY HAND. -->");
lines.push("<!-- Source of truth: GitHub milestones/issues/PRs. Regenerate with `bash .claude/scripts/roadmap.sh --write`. -->");
lines.push("");
lines.push("# Roadmap");
lines.push("");
lines.push("> **Generated — do not hand-edit.** This file is produced by `.claude/scripts/roadmap.sh` from live");
lines.push("> GitHub metadata (open milestones, issues, PRs, and \"Blocked by\" edges parsed from issue bodies).");
lines.push("> The single source of truth is GitHub itself — change labels/milestones/issue bodies there, then");
lines.push("> re-run `bash .claude/scripts/roadmap.sh --write`. Manual edits here will be overwritten.");
lines.push("");

if (milestonesUnavailable || issuesUnavailable) {
  lines.push("_unavailable (gh/network)_");
} else if (milestones.length === 0) {
  lines.push("_No open milestones._");
} else {
  for (const ms of milestones) {
    const msIssues = (byMilestone.get(ms.title) || []).slice().sort((a, b) => {
      const r = priorityRank(a) - priorityRank(b);
      return r !== 0 ? r : a.number - b.number;
    });
    lines.push(`## ${esc(ms.title)} (#${ms.number} · ${ms.open_issues || 0} open / ${ms.closed_issues || 0} closed)`);
    lines.push("");
    if (msIssues.length === 0) {
      lines.push("_No issues assigned to this milestone yet._");
      lines.push("");
      continue;
    }
    lines.push("| Issue | Priority | State | Blocked by |");
    lines.push("|---|---|---|---|");
    const edges = []; // {from, to} = from blocks to (from must land before to)
    for (const issue of msIssues) {
      const priority = priorityOf(issue);
      const st = stateOf(issue);
      const parsed = parseBlocking(issue.body || "");
      const blockedByText = parsed.blockedBy.length ? parsed.blockedBy.map((n) => `#${n}`).join(", ") : "—";
      lines.push(`| [#${issue.number}](${esc(issue.url || "#")}) ${esc(issue.title)} | ${priority ? esc(priority.chip) : "—"} | ${esc(st.label)} | ${blockedByText} |`);
      for (const b of parsed.blockedBy) edges.push({ from: b, to: issue.number });
    }
    lines.push("");
    if (edges.length > 0) {
      // Node labels use whichever title we know (from this milestone's own
      // issue set — the blocker may be outside it, in which case we fall
      // back to a bare "#N" label).
      const titleOf = (n) => {
        const found = issues.find((i) => i.number === n);
        return found ? mermaidEsc(found.title) : "";
      };
      lines.push("```mermaid");
      lines.push("graph LR");
      const seen = new Set();
      for (const e of edges) {
        const key = `${e.from}->${e.to}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const fromLabel = titleOf(e.from) ? `#${e.from} ${titleOf(e.from)}` : `#${e.from}`;
        const toLabel = titleOf(e.to) ? `#${e.to} ${titleOf(e.to)}` : `#${e.to}`;
        lines.push(`  I${e.from}["${fromLabel}"] --> I${e.to}["${toLabel}"]`);
      }
      lines.push("```");
      lines.push("");
    }
  }
}

// ---- Feedback inbox: open `feedback`-labeled issues with NO milestone ------
lines.push("## Feedback inbox");
lines.push("");
lines.push("Open `feedback`-labeled issues not yet assigned a milestone (owner triage — see docs/USAGE.md's");
lines.push("\"rollout & feedback companion\" — turns into loop-eligible work once `planned` + a milestone land):");
lines.push("");
if (prsUnavailable) { /* PRs aren't needed for this section; no-op, kept for clarity */ }
if (issuesUnavailable) {
  lines.push("_unavailable (gh/network)_");
} else {
  const inbox = unmilestoned
    .filter((i) => String(i.state || "").toUpperCase() !== "CLOSED" && hasLabel(i, "feedback"))
    .sort((a, b) => a.number - b.number);
  if (inbox.length === 0) {
    lines.push("_No unmilestoned feedback issues._");
  } else {
    for (const issue of inbox) {
      lines.push(`- [#${issue.number}](${esc(issue.url || "#")}) ${esc(issue.title)}`);
    }
  }
}
lines.push("");

lines.push("---");
const now = process.env.ROADMAP_NOW || new Date().toISOString();
lines.push(`_Generated ${esc(now)} · commit \`${esc(process.env.ROADMAP_SHA || "unknown")}\`_`);
lines.push("");

process.stdout.write(lines.join("\n"));
NODE_RENDER
)"

if [ "$write" -eq 1 ]; then
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$rendered" >"$out"
else
  printf '%s\n' "$rendered"
fi
