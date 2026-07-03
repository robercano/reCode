# Worked adapter examples

Concrete, sanitized `.claude/gates.json` + `CLAUDE.md` pairs for real stacks, to copy from when you
[fill in your own adapter](../docs/GETTING_STARTED.md#step-3--fill-in-claudegatesjson-the-adapter--the-important-one).
Each subdirectory is one stack; the `gates.json` there is what you'd drop into your repo's `.claude/gates.json`.

| Example | Stack | Highlights |
|---|---|---|
| [`ts-solidity-foundry/`](ts-solidity-foundry/) | TypeScript (pnpm workspace) **+** Solidity (Foundry) monorepo | Gates that span two toolchains; a module map mixing `packages/*` (TS) and `contracts/` (Foundry); mixed-stack `test_affected`; which artifacts to gitignore vs track. |

> These are **references, not runnable projects** — they show the adapter shape and the decisions a mixed
> stack forces, not a buildable tree. Adapt the paths and commands to your repo, then verify each gate runs
> (`bash .claude/scripts/gate.sh build`, etc.).

## `fixture-target/` — smoke-harness fixture (not a reference)

[`fixture-target/`](fixture-target/) is different from the table above: it is a **real, tiny, runnable**
repo (not a reference to copy from) checked in so `.claude/self/smoke.sh` has a genuine filled adapter to
drive end-to-end — exercising the harness's own gate machinery without the self-adapter testing itself. Its
`.claude/gates.json` is deliberately node/bash-only so it passes with no extra tooling installed. See
[`fixture-target/README.md`](fixture-target/README.md) and [`.claude/self/README.md`](../.claude/self/README.md).
