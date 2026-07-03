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
  - `build` — every JSON config parses and each adapter (`gates.json`, `self/gates.json`, and the fixture's
    `examples/fixture-target/.claude/gates.json`) is well-shaped. Uses `ajv` for schema validation if
    installed; otherwise falls back to a plain node shape check — `ajv` is never required.
  - `lint` — `bash -n` every shell script (+ `shellcheck` if installed, else skipped with a clear message),
    a **wrap-based** syntax check on every `.claude/workflows/*.js` file (see `smoke.sh` below — plain
    `node --check` is wrong for these files and was the latent lint bug this increment fixes), and
    `markdownlint` on `docs/*.md` if installed (else skipped with a clear message).
  - `test` — runs `smoke.sh` (below): the real end-to-end smoke harness.
- **`smoke.sh`** — the real end-to-end smoke harness, invoked by `checks.sh test`. It:
  1. Syntax-checks every `.claude/workflows/*.js` DSL file. These are **not** plain JS modules — the
     Workflow engine wraps them and injects globals (`phase`, `agent`, `parallel`, `pipeline`, `log`,
     `args`), so `feature-fanout.js` legitimately uses `export const meta`, top-level `await`, and
     top-level `return`. Plain `node --check` fails on top-level await/return outside a function — that
     was the latent bug. The fix: strip leading `export ` keywords, wrap the result in
     `async function __wf(){...}`, write it to a temp `.mjs` file, and `node --check` *that* — mirroring
     how the engine actually executes it.
  2. Statically asserts `feature-fanout.js`'s `meta.phases` exposes the Scope → Implement → Review loop
     shape (checked against each phase's `title:` literal — robust without a real `import()`, which the
     top-level await/return would break anyway).
  3. Drives **`examples/fixture-target`**'s own `.claude/gates.json` — `cd`s into it and runs its real
     `build` / `lint` / `test` commands, asserting each exits 0. This is the real end-to-end check: a real
     filled adapter's gate contract, run for real, without the self-adapter testing itself (no regress).
- **`run.sh`** — a single CI-callable entrypoint (feeds issue #25) that runs `build` → `lint` → `test`
  against the self-adapter in order via the real `.claude/scripts/gate.sh` path, exiting non-zero on the
  first failure, with clear section headers.

## The fixture target — `examples/fixture-target/`
A tiny, checked-in "product" repo with its own **filled** `.claude/gates.json` (`project`, `modules`, and
node/bash-only `build`/`lint`/`test` commands that pass with zero extra tooling). It exists solely so
`smoke.sh` has a real adapter to drive end-to-end without infinite regress (the self-adapter testing
itself). See `examples/fixture-target/README.md` — it is a smoke-harness fixture, not a runnable demo or a
reference adapter to copy from (that's `examples/ts-solidity-foundry/`).

## Running the CI entrypoint
```bash
bash .claude/self/run.sh
```
Runs all three self gates in order against `.claude/self/gates.json`, stopping at the first failure.

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

> A dedicated self-host loop command that wires this automatically is a future increment; for now the
> mechanism above is explicit. The rest of issue #11 (fixture target, smoke harness, optional-tool
> probe-and-skip gates, CI runner) is done as of this increment.

> TODO (intentionally skipped, issue #11): a "pinned known-good engine" mechanism — recording/checking a
> known-good Workflow-engine version/commit the smoke harness was last verified against — is out of scope
> for this increment. Revisit if/when the engine gains a versioned release process.

## Self-hosting promotion (the one gotcha)
Agent-definition / `settings.json` / hook changes only take effect on a **fresh session**. So when the loop
changes the harness itself, treat it like a compiler compiling its successor: land the change on a branch,
then **restart** the session to adopt it. Worktree isolation means the *driving* session keeps the definitions
it loaded at start, so an in-flight change can't break the loop mid-run — but you must restart to run under it.
