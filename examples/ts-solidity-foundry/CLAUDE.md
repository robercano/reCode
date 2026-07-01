# acme-protocol

> Worked example `CLAUDE.md` for the [`ts-solidity-foundry`](./) adapter. Sanitized; adapt to your repo.
> Keep this file lean — project-WIDE context only. Task detail belongs in the task prompt.

## What this project is
On-chain lending protocol. Solidity contracts hold the logic; a TypeScript SDK wraps them and a web app
consumes the SDK. Users interact through the web app; integrators use the SDK.

## Stack & layout
- Language / runtime: TypeScript (Node 20) + Solidity 0.8.x
- Package manager: pnpm (workspace) for TS; Foundry (`forge`) for contracts
- Key directories (mirror `.claude/gates.json` → `modules`):
  - `packages/sdk/` — TS client SDK wrapping the contracts (consumes the generated ABI)
  - `packages/web/` — front-end app, consumes `sdk`
  - `contracts/` — Foundry project: `.sol` sources, `test/`, deploy scripts, `foundry.toml`

## Conventions
- Code style / lint: eslint + prettier for TS; `forge fmt` for Solidity (checked in CI via `forge fmt --check`).
- Testing: vitest per TS package (`test` script); `forge test` for contracts. Tests live beside sources
  (`*.test.ts`) and in `contracts/test/*.t.sol`.
- Definition of done: `build`, `lint`, `typecheck`, `test` all green; contract changes keep `forge coverage`
  ≥ threshold; reviewers approve (security lens required for `contracts`).

## Multi-agent orchestration
This repo is set up for orchestrated multi-agent development. See `docs/USAGE.md`.
- **Adapter:** `.claude/gates.json` — module map, gate commands, model routing. Keep it current.
- **Gates run via** `.claude/scripts/gate.sh <name>` and the hooks in `.claude/settings.json`.

### Module boundaries (hard rule)
A worker assigned to a module MUST NOT edit files outside that module's `path`.
- The **ABI** that `sdk` consumes is a *build artifact* of `contracts` — regenerate it via `build`, never by
  hand-editing across the boundary. If an SDK change needs a contract change, the orchestrator re-scopes it as
  two coordinated sub-tasks (contracts first, then sdk), not one worker reaching across.
- `web` depends on `sdk`'s published types; same rule — cross-package changes are re-scoped, never reached.

### Merge policy
`pr-per-agent` — base branch `main`.

## Don'ts
- Don't put secrets (RPC URLs, deployer keys, mnemonics) in the repo — use `.env` (gitignored).
- Don't bypass the gates.
- Don't commit build artifacts — see the example README for the gitignore split.
