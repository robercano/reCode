# Evaluation: emdash as an Optional Visual Cockpit

## Summary

[emdash](https://github.com/generalaction/emdash) (YC W26, Apache-2.0) is a desktop GUI for running
multiple coding agents in parallel git worktrees, with a diff/review/merge UI, ~27 model/provider
integrations, SSH/SFTP remote execution, scheduled automations, and surfacing of GitHub check status
in its interface. That overlaps with what this harness already does at the "run N agents in
worktrees, then review and merge" layer.

It does **not** overlap with the parts of this harness that are the actual engine: emdash has no
role-based orchestration (orchestrator / implementer / reviewer / test-runner), no local gate
enforcement (build/lint/typecheck/test/coverage as versioned, run-before-merge checks), no
adversarial multi-lens review, and no headless mode (it's a GUI you drive; there's no cron-poll /
unattended-wakeup path).

This note evaluates the overlap, the seam where the two would collide if run together, what a GUI
needs from *this* repo to show anything useful, and what the harness provides that a cockpit cannot
replace — then makes a recommendation.

## 1. Integration seam: worktree ownership

Both emdash and this harness create and drive **git worktrees** directly (emdash to isolate its
parallel agent sessions; the harness via its `implementer` agents, whose `isolation: worktree`
frontmatter (`.claude/agents/implementer.md`) places each worker in its own git worktree).
If both tools manage worktrees against the same repo at the same time, they can collide on the same
branch names, leave orphaned worktrees the other tool doesn't know about, or race on `git worktree
add`/`remove` for the same paths.

**Rule: pick one driver per session.** Either emdash owns worktree lifecycle for that working
session, or the harness does — never both at once against the same repo checkout. If you want to use
emdash's GUI to watch or steer a run, point it at a repo/session where the harness is *not*
concurrently spinning up its own worktrees, or vice versa. This is a coordination discipline, not a
code integration — there is no shared lock file between the two today.

## 2. CI-check surfacing: this depends on server-side gates, not the GUI

emdash can surface GitHub check status (the green/red checks on a PR) in its interface. That
capability is entirely dependent on something actually **publishing** those checks server-side —
i.e., a GitHub Actions workflow (or equivalent) that runs on push/PR and reports back through the
Checks API.

This harness's gates (`.claude/gates.json` → `gate.sh`) currently run **locally**, inside the
worker's worktree, before a PR is opened. A local gate pass is not the same thing as a GitHub check:
it doesn't post a check run, and it isn't visible to emdash, to `gh pr checks`, or to a branch
protection rule. For emdash (or any GUI) to show meaningful CI status for PRs this harness opens, the
project needs a CI workflow that re-runs the same gate commands server-side and reports status back
to GitHub — that is the scope of the separate CI-workflow effort (issue #25), not something this
evaluation solves. Until that workflow exists, "no checks shown" in any GUI is expected, not a bug in
the harness or in emdash.

## 3. What the harness keeps that a GUI can't replace

A visual cockpit like emdash improves the *experience* of watching and merging parallel agent
sessions, but it does not provide:

- **Gates-as-code.** `.claude/gates.json` is a versioned, per-project contract (build/lint/typecheck
  /test/coverage commands + thresholds) that is enforced programmatically before a worker can declare
  done. This is data checked into the repo and reviewed like any other config — not a setting living
  only in a desktop app's local state.
- **Defined roles.** Orchestrator, implementer, reviewer, and test-runner are distinct agents with
  distinct responsibilities and model routing (`.claude/agents/`). emdash runs agent *sessions* in
  parallel; it does not encode a division of labor between scoping, implementing, reviewing, and
  gating.
- **Adversarial multi-lens review.** Reviewers in this harness are spawned one-per-lens
  (correctness, tests, security, performance, ...) and a change must reach consensus across
  independent reviewers before it's considered approved (`review.consensus` in the adapter). This is
  a structured, repeatable check — not a human eyeballing a diff in a GUI panel, and not a single
  reviewer pass.
- **Headless autonomy.** The harness can run with no human and no GUI in the loop at all: cron-driven
  polling and scheduled wakeups drive the orchestrator to pick up work, implement, gate, and open PRs
  unattended (see `docs/HARDENING.md` for the guardrails that make that safe). emdash is a desktop
  application a human drives; it has no equivalent unattended mode.

## 4. Decision / recommendation

**Treat emdash as an optional cockpit (front-end), and this harness as the engine (the
orchestration + gating substrate). They are complementary, not substitutes — do not adopt emdash as
a replacement for any part of this harness.**

Justification:

- The overlap is real but shallow: both touch "worktrees + diff/review/merge UX." Everything that
  makes this harness trustworthy for unattended operation — versioned gates, defined roles,
  adversarial review, headless scheduling — lives entirely outside what emdash provides, so there is
  no substitution available even if emdash's worktree/UX layer looks similar on the surface.
  Conversely, this harness has no polished desktop GUI, no broad provider matrix, and no SSH/SFTP
  remote-execution story — areas where emdash is materially more capable today.
- Because both tools drive worktrees, they are not simply "compatible by default" — the coordination
  rule in Section 1 (one driver per session) is required to use them together safely.
  This is why emdash is scoped as *optional*: a team can run this harness entirely headless with no
  GUI at all, or add emdash later purely as a human-facing viewport, without either mode requiring
  changes to the other.
- CI-check visibility in any GUI (emdash included) is gated on separate, server-side work (issue
  #25). Adopting emdash does not change that dependency or accelerate it — it only becomes visibly
  useful once the CI workflow exists.

**Recommendation:** No code integration at this time. If/when a human-facing cockpit is desired,
evaluate wiring emdash as a viewer/driver for individual sessions, respecting the single-worktree-
driver rule above, and revisit CI-check surfacing once issue #25 ships. This harness's engine
(gates, roles, adversarial review, headless scheduling) remains the source of truth regardless of
which front-end, if any, is layered on top.
