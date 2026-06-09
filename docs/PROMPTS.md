# Prompts

Copy-paste these into Claude Code. The first two populate the files you must fill; the rest drive day-to-day work.

---

## 1. Draft `CLAUDE.md`
```
Read this repository — package manifests, directory structure, CI config, and any existing README — and draft
a CLAUDE.md using the template already at ./CLAUDE.md. Fill: what the project is, stack & layout, the module
list (with paths), conventions, testing approach, and definition of done. Keep it lean and project-WIDE only;
do not include task-specific detail. Show me the draft for approval before writing.
```

## 2. Fill `.claude/gates.json` (the adapter)
```
Inspect this repo's package.json / Makefile / turbo.json / CI workflows and propose values for
.claude/gates.json:
- project: name, language, package manager
- modules: each independent area with its path and a one-line description (these become worker boundaries)
- gates: exact shell commands for install, build, lint, typecheck, test, test_affected, coverage, e2e,
  security. Use "" for anything that doesn't exist. Set a sensible coverage_threshold.
- budget: confirm model routing and a starting max_parallel_workers of 2
- merge.policy and baseBranch
Then RUN each non-empty gate via `bash .claude/scripts/gate.sh <name>` to verify it works, and fix any
command that fails. Show me the final file.
```

## 3. Add or refine a module boundary
```
We're adding work in <area>. Update .claude/gates.json "modules" to add { name, path, description, owner } for
it so workers get a clean, non-overlapping boundary. Check it doesn't overlap existing module paths.
```

## 4. Kick off an orchestrated task (conversational)
```
Use the orchestrator agent. Task: <goal>.
Decompose into independent, non-overlapping sub-tasks by module (read .claude/gates.json). Present the plan
and WAIT for my approval before any code is written. Use at most `max_parallel_workers` at once.
```

## 5. Run the fan-out workflow (deterministic, token-heavy)
```
ultracode run the feature-fanout workflow, args.task = "<self-contained task description>".
```

## 6. Standup / status
```
Status report: for each sub-task give done/in-progress/blocked, branch/PR, gate results, and any decision you
need from me. Then stop.
```

## 7. Force a review pass on a branch
```
Use the reviewer agent on branch <name>, once per lens in gates.json (correctness, tests, security,
performance). Each reviewer is adversarial and returns approve/reject with concrete findings. Summarize the
verdicts and whether it meets the configured consensus.
```

## 8. Onboard a brand-new project type (extend the framework)
```
This repo is <language/framework> — different from what the template assumed. Keep the generic agents and
workflow as-is. Update ONLY .claude/gates.json and CLAUDE.md for this stack: new module map, new gate
commands, appropriate model routing and review lenses. Verify the gates run. Don't touch the agent prompts
unless a stack-specific instruction is genuinely required — if so, explain why.
```

## 9. Tune after a run (retro)
```
Run `npx ccusage` and summarize token/cost by model for this session. Given the run we just did, recommend
changes to: max_parallel_workers, model routing, the module map, and any agent prompt that caused rework or
overlap. Propose concrete edits to gates.json.
```
