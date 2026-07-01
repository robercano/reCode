# Self-adapter — the template dogfooding itself (issue #11)

This directory lets **this repo run its own PR loop against its own harness/docs**, without touching the
shipped placeholder `.claude/gates.json` (which stays pristine for downstream adopters).

## Why a separate adapter
`.claude/gates.json` is the file a *new project* fills in. If we filled it with this repo's own modules and
gates, every clone of the template would inherit our self-config. So the self-config lives here instead, and
the tooling reads it only when explicitly pointed at it.

## Files
- **`gates.json`** — the real adapter for THIS repo: modules (`docs`, `harness`→`.claude`, `examples`, `ci`)
  and node/bash-only gate commands, so they run with no extra linters installed.
- **`checks.sh`** — implements `build` / `lint` / `test`:
  - `build` — every JSON config parses and each adapter (`gates.json` + `self/gates.json`) is well-shaped.
  - `lint` — `bash -n` every shell script + `node --check` every workflow.
  - `test` — `build` + `lint` smoke (validates the harness end-to-end on itself).

## Running gates against the self-adapter
`gate.sh` honors a `GATES_FILE` env override (defaults to `.claude/gates.json`):

```bash
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh build
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh lint
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh test
```

## Running the loop self-hosted
To have the autonomous loop work this repo's own `module:*` backlog:
1. Label the target issue with a self module — `module:docs`, `module:harness`, `module:examples`, or `module:ci`.
2. Drive the tick with `GATES_FILE=.claude/self/gates.json` exported, and tell the orchestrator to read
   **`.claude/self/gates.json`** as its adapter (module map + gates) for this repo. The generic agents/scripts
   otherwise behave identically — worker boundaries come from this file's `modules`, gates from its `gates`.

> A dedicated self-host loop command that wires this automatically is the next increment on issue #11; for now
> the mechanism above is explicit.

## Self-hosting promotion (the one gotcha)
Agent-definition / `settings.json` / hook changes only take effect on a **fresh session**. So when the loop
changes the harness itself, treat it like a compiler compiling its successor: land the change on a branch,
then **restart** the session to adopt it. Worktree isolation means the *driving* session keeps the definitions
it loaded at start, so an in-flight change can't break the loop mid-run — but you must restart to run under it.
