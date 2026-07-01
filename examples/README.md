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
