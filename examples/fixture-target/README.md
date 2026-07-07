# fixture-target — smoke-test fixture for the fan-out scaffold

A deliberately tiny, consumer-shaped target repo used by the self-host smoke harness
(`.claude/self/smoke-fanout.sh`, issue #64 — Phase 2 of #11). It is **not** a worked example to copy
(see `ts-solidity-foundry/` for that); it exists so every PR to this repo can validate the
deterministic fan-out scaffolding end-to-end **on a fixture, not on the harness itself** (no
bootstrap regress) and **without live agents** (no tokens, no nondeterminism — CI-safe).

What the smoke harness does with it:

1. Stages `src/`, `test/`, and `gates.json` (as `.claude/gates.json`) plus the **real**
   `gate.sh` into a temp git repo — the same layout a consumer repo has.
2. Plays a *recorded implementer*: isolated worktree → applies a canned diff
   (`.claude/self/smoke/implementer.patch`) → asserts the diff stays inside the `fixture-core`
   module boundary (`src/`).
3. Runs the fixture's `build`/`lint`/`test` gates through `gate.sh` in the worktree (plus an
   empty gate to prove the skip path), merges the branch, and asserts the change landed on `main`.
4. Proves the failure path: a broken canned diff (`smoke/broken.patch`) must make the build gate
   exit non-zero.

Keep it minimal: one module (`src/`), node-only gates, no dependencies.
