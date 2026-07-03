---
description: Interactive full onboarding — interview the user, then write .claude/gates.json + CLAUDE.md, fix gitignore, create module:* labels, verify the bot, confirm CI gates, and offer to arm the PR loop and hardening. Brings a fresh project to a working autonomous state.
---

This onboarding flow now lives in the `/orchestrator:setup` skill (`.claude/skills/setup/SKILL.md`), which
also scaffolds the files a plugin can't carry into the repo for you (`.claude/gates.json`, `CLAUDE.md`,
`.claude/workflows/feature-fanout.js`, and the CI gate workflow) via `.claude/skills/setup/scaffold.sh`.

Run `/orchestrator:setup` — it does everything this command used to do, plus the scaffolding step. This
file is kept as a pointer so `/setup-orchestrator` still resolves for anyone used to the old name.
