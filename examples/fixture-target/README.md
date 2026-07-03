# fixture-target (smoke-harness fixture — not a demo)

This is a tiny, self-contained "product" repo checked in so that `.claude/self/smoke.sh` has a **real,
filled adapter** to drive end-to-end, without the self-adapter testing itself (infinite regress).

It is **not** a runnable product demo and not a reference to copy an adapter shape from — see
[`../ts-solidity-foundry/`](../ts-solidity-foundry/) for that. This repo exists purely so the smoke harness
can `cd` into it, read its `.claude/gates.json`, and run real `build` / `lint` / `test` gate commands that
must pass.

## Why node/bash only
The smoke harness runs in an environment that may only have node + bash available (no package manager, no
external linters). This fixture's gates (`.claude/gates.json`) are deliberately written as plain `node
--check` / `node <file>` commands so they pass with zero extra tooling, while still exercising a real
adapter → real gate.sh → real gate-command contract.

## Layout
- `src/add.js` — trivial CommonJS module exporting `add(a, b)`.
- `test/add.test.js` — a plain `node` script that asserts `add` behaves correctly and exits non-zero on
  failure (no test runner needed).
- `.claude/gates.json` — a filled adapter (`project`, `modules`, `gates`) pointing at this directory.

## Running its gates directly
```bash
cd examples/fixture-target
node --check src/add.js                                  # build
node --check src/add.js && node --check test/add.test.js # lint
node test/add.test.js                                     # test
```
