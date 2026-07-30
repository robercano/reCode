#!/usr/bin/env bash
# merge-ready.sh — merge every open PR the repo OWNER has approved and that is
# safe to merge, then delete the branch. The human Approve on GitHub is the ONLY
# gate; this script never approves anything — it just acts on approvals. Pair it
# with notify-poll.sh in a cron to close the loop: review → approve → auto-merge.
#
# A PR is merged iff ALL hold:
#   - base is the configured baseBranch (gates.json merge.baseBranch), not a draft
#   - latest review by the OWNER is APPROVED
#   - that approval was submitted at/after the PR's last commit (so it covers the
#     current head) — guards against commits pushed after an approval. A private
#     repo on a free plan has no branch protection to auto-dismiss stale
#     approvals, so we enforce "approval covers head" here instead.
#   - mergeable (no conflicts)
#   - every CI check is green (none failing, none still pending)
# Anything else is SKIPPED with a reason. Output is JSON lines a cron summarizes.
#
# Auth: ALL `gh` calls (listing, viewing, and the merge itself) run as the bot via
# bot-gh.sh — the bot is a write collaborator, so it can merge. The merge GATE is
# still the human OWNER's APPROVED review (detected below); running the merge as the
# bot does not change who authorized it. Repo is derived from the git remote;
# override with $1 (owner/repo).
# The approver defaults to the repo owner; override with $MERGE_APPROVER.
# Pre-approve `bash .claude/scripts/merge-ready.sh` in .claude/settings.json.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call (list/view/merge) through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# needs_human_flag/needs_human_clear (issue #99): the ONE shared label+notify
# seam for "PR ready-for-review" / "re-approve current head" -- see the
# per-PR loop below. Sourced AFTER the `gh` wrapper above so both functions
# call the bot identity; guarded (not a bare `&&`) so a missing file under
# `set -e` never aborts the script (see needs-human.sh's own header for why
# every statement in it is written the same defensive way).
# shellcheck source=needs-human.sh
if [ -f "$script_dir/needs-human.sh" ]; then . "$script_dir/needs-human.sh"; fi
owner="${MERGE_APPROVER:-${repo%%/*}}"   # the approver whose APPROVED review authorizes a merge

# Adapter file: honor GATES_FILE (the self-host loop points at self/gates.json),
# fall back to the shipped root adapter. Both merge.baseBranch and protectedPaths
# (issue #94 Layer 2) are read from it, so the self-adapter's permissive protectedPaths
# override applies when the loop runs self-hosted.
gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel";; *) gates="$root/$gates_rel";; esac
base="$(node -e "try{const g=require('$gates');process.stdout.write((g.merge&&g.merge.baseBranch)||'main')}catch(e){process.stdout.write('main')}")"

# Decide MERGE / SKIP:<reason> for one PR's JSON (read on stdin).
decide() {
  node -e '
    const base = process.argv[1], owner = process.argv[2];
    function verdict(p) {
      if (p.isDraft) return "SKIP:draft";
      if (p.baseRefName !== base) return "SKIP:base-is-"+p.baseRefName;
      if (p.mergeable !== "MERGEABLE") return "SKIP:mergeable="+p.mergeable;

      // CI: every check green; none failing or pending.
      for (const c of (p.statusCheckRollup||[])) {
        if (c.conclusion !== undefined && c.conclusion !== null && c.conclusion !== "") {   // CheckRun
          if (["FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE"].includes(c.conclusion))
            return "SKIP:check-failed:"+(c.name||"");
          if (c.status && c.status !== "COMPLETED") return "SKIP:check-pending:"+(c.name||"");
        } else if (c.state) {                                                                // legacy StatusContext
          if (["FAILURE","ERROR"].includes(c.state)) return "SKIP:status-failed:"+(c.context||"");
          if (c.state === "PENDING") return "SKIP:status-pending:"+(c.context||"");
        }
      }

      // Latest review by the owner must be APPROVED and cover the current head.
      const mine = (p.reviews||[]).filter(r => r.author && r.author.login === owner && r.submittedAt)
                                  .sort((a,b) => a.submittedAt.localeCompare(b.submittedAt));
      const last = mine[mine.length-1];
      if (!last) return "SKIP:no-owner-review";
      if (last.state !== "APPROVED") return "SKIP:owner-review="+last.state;
      const commits = p.commits||[];
      const head = commits.length ? commits[commits.length-1].committedDate : null;
      if (head && last.submittedAt < head) return "SKIP:approval-stale (re-approve current head)";
      return "MERGE";
    }
    let p; try { p = JSON.parse(require("fs").readFileSync(0,"utf8")); } catch(e){ console.log("SKIP:bad-json"); process.exit(0); }
    console.log(verdict(p));
  ' "$base" "$owner"
}

# protected_paths_check (issue #94 Layer 2): reads the adapter's protectedPaths
# globs and the PR's changed-file list (`.files[].path`, on stdin) and prints the
# protected path(s) the diff touches (comma-joined), or nothing. Empty/absent
# protectedPaths = disabled (prints nothing) — same empty-means-skip convention as
# `notify`. Deterministic (no LLM); "*" matches one path segment, "**" any depth.
protected_paths_check() {
  node -e '
    const gates = process.argv[1];
    let globs = [];
    try { const g = require(gates); if (Array.isArray(g.protectedPaths)) globs = g.protectedPaths; } catch (e) {}
    if (!globs.length) process.exit(0);
    let p; try { p = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (e) { process.exit(0); }
    const files = (p.files || []).map(f => f && f.path).filter(Boolean);
    function toRe(glob) {
      let re = "";
      for (let i = 0; i < glob.length; i++) {
        const c = glob[i];
        if (c === "*") {
          if (glob[i + 1] === "*") { re += ".*"; i++; if (glob[i + 1] === "/") i++; }
          else re += "[^/]*";
        } else if ("\\^$.|?+()[]{}".includes(c)) { re += "\\" + c; }
        else re += c;
      }
      return new RegExp("^" + re + "$");
    }
    const res = globs.map(toRe);
    const hits = files.filter(f => res.some(r => r.test(f)));
    if (hits.length) process.stdout.write([...new Set(hits)].join(", "));
  ' "$gates"
}

merged=0; skipped=0
for n in $(gh pr list -R "$repo" --base "$base" --state open --json number -q '.[].number'); do
  data="$(gh pr view "$n" -R "$repo" --json number,title,isDraft,baseRefName,headRefName,mergeable,reviews,statusCheckRollup,commits,files)"
  verdict="$(printf '%s' "$data" | decide)"
  title="$(printf '%s' "$data" | node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(0,"utf8")).title)||"")')"
  head_branch="$(printf '%s' "$data" | node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(0,"utf8")).headRefName)||"")')"

  # Protected-paths guard (issue #94 Layer 2): even an owner-approved, CI-green PR
  # must not auto-merge if its diff touches a path the adapter marks protected.
  protected_hit=""
  if [ "$verdict" = "MERGE" ]; then
    protected_hit="$(printf '%s' "$data" | protected_paths_check)"
    [ -n "$protected_hit" ] && verdict="SKIP:protected-paths"
  fi

  # needs-human (issue #99): a PR is genuinely blocked on the OWNER for
  # exactly two of decide()'s skip reasons -- no review submitted yet, or a
  # stale approval that no longer covers the current head (new commits
  # pushed since). Every other reason (draft/base mismatch/conflicts/CI
  # pending-or-failing, and owner-review=CHANGES_REQUESTED -- that one is
  # pr-feedback.sh's job to dispatch a bot fix for, not the owner's) is NOT
  # an owner-blocking wait, so any earlier "ready for review" flag on this PR
  # is cleared. Both calls are best-effort no-ops when the corresponding
  # helper function isn't defined (needs-human.sh missing from a fixture).
  case "$verdict" in
    SKIP:no-owner-review|SKIP:approval-stale*)
      if command -v needs_human_flag >/dev/null 2>&1; then
        # Human-readable reason, not the raw "SKIP:..." verdict token (non-
        # blocking re-review nit): only these two verdicts reach this branch,
        # so a simple case is enough -- no need to reformat the token itself.
        reason_text="not yet reviewed"
        case "$verdict" in
          SKIP:approval-stale*) reason_text="approval is stale -- please re-review the current head" ;;
        esac
        needs_human_flag "pr:$n" "pr-review" "low" \
          "PR #$n ready for your review" "$title ($reason_text)"
      fi
      ;;
    SKIP:protected-paths)
      if command -v needs_human_flag >/dev/null 2>&1; then
        needs_human_flag "pr:$n" "protected-paths" "high" \
          "PR #$n touches protected paths -- human review required" \
          "$title: this PR's diff touches protected path(s): $protected_hit. Auto-merge is blocked by the protected-paths guard (issue #94 Layer 2). A human must review and merge it manually."
      fi
      ;;
    *)
      if command -v needs_human_clear >/dev/null 2>&1; then
        needs_human_clear "pr:$n" "pr-review"
      fi
      ;;
  esac

  if [ "$verdict" = "MERGE" ]; then
    if gh pr merge "$n" -R "$repo" --merge --delete-branch >/dev/null 2>&1; then
      echo "{\"pr\":$n,\"action\":\"merged\",\"title\":\"$title\"}"; merged=$((merged+1))
      # needs-human (issue #99): the PR just merged -- the clearest possible
      # "this block-on-owner condition just resolved" signal. Clear any
      # needs-human flag on the PR itself (belt-and-suspenders; it's about to
      # be closed anyway) AND on the issue it was cut from (feat/issue-N-* or
      # fix/issue-N-*), since loop-tick.sh's attempt-budget/stall escalations
      # both flag the ISSUE, not the PR.
      if command -v needs_human_clear >/dev/null 2>&1; then
        needs_human_clear "pr:$n" "pr-review"
        needs_human_clear "pr:$n" "changes-requested"
        merged_issue_num="$(printf '%s\n' "$head_branch" | sed -n 's/.*issue-\([0-9][0-9]*\).*/\1/p')"
        if [ -n "$merged_issue_num" ]; then
          needs_human_clear "issue:$merged_issue_num" "attempt-budget"
          needs_human_clear "issue:$merged_issue_num" "stall"
        fi
      fi
      # Auto-cleanup (issue #91): the merged branch's local worktree + local
      # branch are now stale. worktree-cleanup.sh applies its OWN safety
      # rails (worker-path naming, clean tree, fully merged into $base) and
      # NEVER forces — a "skip" line from it is expected and fine, just
      # tag it with the PR number and pass it through.
      if [ -n "$head_branch" ]; then
        while IFS= read -r cleanup_line; do
          [ -z "$cleanup_line" ] && continue
          printf '%s\n' "$cleanup_line" | node -e '
            const pr = process.argv[1];
            const obj = JSON.parse(require("fs").readFileSync(0,"utf8"));
            obj.pr = Number(pr);
            console.log(JSON.stringify(obj));
          ' "$n"
        done < <(bash "$script_dir/worktree-cleanup.sh" "$base" "$head_branch")
      fi
    else
      echo "{\"pr\":$n,\"action\":\"merge-failed\",\"title\":\"$title\"}"
    fi
  else
    echo "{\"pr\":$n,\"action\":\"skip\",\"reason\":\"${verdict#SKIP:}\",\"title\":\"$title\"}"; skipped=$((skipped+1))
  fi
done

# Post-merge: fast-forward the LOCAL checkout to the freshly-merged base so the
# owner's terminal/IDE shows the latest code without a manual pull. Strictly safe:
# acts ONLY when the checkout is on the base branch with a clean tree, and only
# fast-forwards (never a merge commit, never a branch switch, never clobbers
# uncommitted work). Untracked sandbox device-node masks don't count as changes.
# Any obstacle -> skip with a reason; never force. See docs/HARDENING.md.
if [ "$merged" -gt 0 ]; then
  wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  cur="$(git -C "${wt:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
  # local_sync_ok (issue #175 review finding #1a): 1 iff the fast-forward
  # below actually landed, i.e. the checkout was on $base, the WHOLE working
  # tree was clean, and origin/$base fast-forwarded cleanly (so local $base
  # is now verified in sync with origin/$base). The post-merge roadmap
  # commit/push further below reuses this exact flag as its own precondition
  # instead of re-deriving a weaker, file-scoped check -- see that block.
  local_sync_ok=0
  if [ -z "$wt" ]; then
    :
  elif [ "$cur" != "$base" ]; then
    echo "{\"local_sync\":\"skip\",\"reason\":\"checkout on '$cur', not '$base'\"}"
  elif ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --cached --quiet; then
    echo "{\"local_sync\":\"skip\",\"reason\":\"working tree has tracked changes\"}"
  elif git -C "$wt" fetch --quiet origin "$base" 2>/dev/null \
       && git -C "$wt" merge --ff-only -q "origin/$base" 2>/dev/null; then
    echo "{\"local_sync\":\"ok\",\"branch\":\"$base\",\"head\":\"$(git -C "$wt" rev-parse --short HEAD)\"}"
    local_sync_ok=1
  else
    echo "{\"local_sync\":\"skip\",\"reason\":\"fetch or fast-forward failed (diverged/offline?)\"}"
  fi

  # Post-merge roadmap regen (issue #175): docs/ROADMAP.md is a GENERATED
  # snapshot of open milestones/issues/PRs (see roadmap.sh's own header +
  # docs/USAGE.md's "Roadmap" section) — regenerating it right after a merge
  # keeps it fresh without the owner remembering to re-run it by hand.
  #
  # STRICTLY best-effort and NON-FATAL: this whole block is wrapped in its own
  # subshell + `|| true` so ANY failure inside it (missing roadmap.sh, a
  # generator crash, no local git checkout, an unclean tree, an offline
  # push) degrades to a `"roadmap_regen":"skip"` line on STDERR — it must
  # NEVER cause merge-ready.sh to report a non-zero exit or unwind a merge
  # that already succeeded. `[ -f "$script_dir/roadmap.sh" ]` also makes this
  # a no-op when roadmap.sh isn't present at all (nothing to regenerate).
  #
  # Regeneration itself is invoked unconditionally (independent of the
  # local_sync outcome above) so a stubbed/failing roadmap.sh is always
  # exercised — see merge-ready.test.sh. The COMMIT+PUSH step, however, gates
  # on `local_sync_ok` -- the SAME precondition local_sync itself required
  # (checkout on $base, WHOLE working tree clean, origin/$base fast-forwarded
  # in sync) -- not just a docs/ROADMAP.md-only diff: committing on top of
  # unrelated WIP, or while $base is diverged/offline, would be unsafe.
  #
  # Change detection ignores the volatile footer line (issue #175 review
  # finding #3): roadmap.sh's own footer always changes (timestamp + the
  # generating commit SHA), so a raw file diff would treat every regen as a
  # change and commit no-op spam straight onto $base. Comparing the committed
  # vs regenerated content with that line stripped from both means a
  # semantically-identical roadmap is correctly treated as "no changes" and
  # never committed -- the footer itself is still written to disk unstripped.
  #
  # The commit/push themselves are plain `git` (the repo OWNER's auth, same
  # as every other git operation in this script) — only roadmap.sh's OWN gh
  # calls (issue/PR/milestone reads) go through bot-gh.sh. This is deliberate,
  # not an oversight: bot-gh.sh exists so PRs are bot-authored (the owner is
  # then free to approve them); a direct-to-$base commit has no PR and
  # nothing for the owner to approve, so that approvability concern doesn't
  # apply here -- using the owner's own git auth (already required for the
  # ff-only local_sync above) is the correct choice, not a shortcut.
  #
  # On push failure (issue #175 review finding #1b): roll back with
  # `git reset --hard origin/$base` so a rejected/offline push NEVER leaves a
  # dangling local commit diverging $base from origin (which would otherwise
  # wedge every future local_sync ff-only forever). Safe specifically because
  # local_sync_ok guarantees the tree was clean and $base was on origin/$base
  # immediately before this block ran, so resetting to origin/$base discards
  # at most the regen commit just made here -- never real owner work.
  if [ -f "$script_dir/roadmap.sh" ]; then
    (
      set +e
      regen_err="$(mktemp "${TMPDIR:-/tmp}/roadmap-regen.XXXXXX.err")"
      if ! GATES_FILE="$gates_rel" bash "$script_dir/roadmap.sh" --write >/dev/null 2>"$regen_err"; then
        echo "{\"roadmap_regen\":\"skip\",\"reason\":\"generator failed: $(tr '\n' ' ' <"$regen_err" | head -c 200)\"}" >&2
        rm -f "$regen_err"
        exit 0
      fi
      rm -f "$regen_err"
      if [ "$local_sync_ok" -ne 1 ]; then
        git -C "$wt" checkout -- docs/ROADMAP.md 2>/dev/null || true
        echo "{\"roadmap_regen\":\"generated\",\"committed\":false,\"reason\":\"local $base not verified in sync with origin (see local_sync)\"}"
        exit 0
      fi
      old_content="$(git -C "$wt" show "HEAD:docs/ROADMAP.md" 2>/dev/null | grep -v '^_Generated ' || true)"
      new_content="$(grep -v '^_Generated ' "$wt/docs/ROADMAP.md" 2>/dev/null || true)"
      if [ "$old_content" = "$new_content" ]; then
        # roadmap.sh --write still rewrote the file on disk (its footer
        # timestamp + commit SHA always change), so even though there's
        # nothing worth committing, the working tree must be restored to
        # clean here -- otherwise local_sync's own clean-tree precondition
        # (above) would trip on THIS file on the very next run and wedge
        # roadmap regeneration off forever (issue #175 review finding #1,
        # round 2).
        git -C "$wt" checkout -- docs/ROADMAP.md 2>/dev/null || true
        echo "{\"roadmap_regen\":\"generated\",\"committed\":false,\"reason\":\"no changes\"}"
        exit 0
      fi
      if git -C "$wt" add docs/ROADMAP.md \
         && git -C "$wt" commit -q -m "chore: regenerate docs/ROADMAP.md [skip ci]" \
         && git -C "$wt" push -q origin "HEAD:$base"; then
        echo "{\"roadmap_regen\":\"generated\",\"committed\":true,\"branch\":\"$base\"}"
      else
        git -C "$wt" reset --hard "origin/$base" >/dev/null 2>&1 || true
        echo "{\"roadmap_regen\":\"generated\",\"committed\":false,\"reason\":\"commit or push failed (rolled back)\"}" >&2
      fi
    ) || echo "{\"roadmap_regen\":\"skip\",\"reason\":\"unexpected error\"}" >&2
  fi
fi
echo "=== merge-ready: merged=$merged skipped=$skipped ==="
