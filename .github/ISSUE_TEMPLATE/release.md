---
name: Release
about: Cut a release for a milestone once every other issue in it has merged.
title: 'Release vX.Y.Z'
labels: module:harness
---

## What
This issue is the release gate for milestone **<milestone title, e.g. "vX.Y.Z — <theme>">**. It reuses
issue 97's blocking-graph convention as the ENTIRE release gate — no new state machine: the field below,
once filled in, tells the loop's census this issue must wait until every other issue in the milestone is
closed.

**Blocked by #…, #…, #…** <!-- REPLACE the ellipses with the real, comma-separated issue numbers below -->

## Keeping that field current
Whenever an issue is added to (or removed from) this milestone, refresh the field above so it still lists
every OTHER open issue in the milestone (never this issue itself). A quick helper query:

```bash
bash .claude/scripts/bot-gh.sh issue list --milestone "<this milestone's exact title>" --state open --json number,title
```

Paste the resulting issue numbers into that field, comma-separated, prefixed with a literal `#` each — for
example, if the query returns issues AAA, BBB, and CCC, the field would read: "#AAA, #BBB, #CCC" (with
`#`, followed directly by each real number). An empty/absent field (all siblings closed) makes this issue
immediately eligible once it also carries `planned`.

## What happens once this issue is unblocked and advanced
Once every issue named in the field above is closed, this issue becomes a normal `planned` + `module:*`
candidate and the loop's ADVANCE step picks it up like any other issue. Its implementer runs the release
driver:

```bash
bash .claude/scripts/release.sh vX.Y.Z --issue <this-issue-number>
```

which:
1. bumps the `version` field in `.claude/.claude-plugin/plugin.json` and
   `.claude/.claude-plugin/marketplace.json`,
2. generates a dated CHANGELOG entry in `.claude/.claude-plugin/CHANGELOG.md` from merged PR titles since
   the last git tag (or the full history, on a first release),
3. tags `vX.Y.Z`, commits, and pushes,
4. prints the manual owner follow-up (`/plugin marketplace update recode` — this cannot be automated),
5. closes this milestone,
6. auto-files a `Rollout & feedback: vX.Y.Z` issue — deliberately outside any milestone and without the
   `planned` label (a census-invisible feedback inbox) — with a consumer-sync checklist for reDeploy and
   reDeFi (`/orchestrator:sync` v2, issue 141) and test-focus areas derived from this milestone's issue
   titles.

See `docs/USAGE.md` → "Release cycle" for the full convention, including the hotfix path. This
supersedes the ad-hoc release pattern from issue 136.

## Labels
- `module:harness` — routes this issue to the loop like any other harness issue.
- The owner still adds `planned` to move it into the work queue — same owner-only two-label workflow as
  every other issue (see docs/USAGE.md → "Autonomous loop & the issue queue").
