---
description: Re-stamp MANAGED files after a plugin update — reconciles scaffolded workflow/CI files in an already-onboarded repo using the version markers `/orchestrator:setup` writes, without ever touching user-owned files.
---

This reconcile flow lives in the `/orchestrator:sync` skill (`.claude/skills/sync/SKILL.md`), which compares
the version markers already scaffolded by `/orchestrator:setup` against the versions the current plugin
ships, and re-stamps anything that's behind — while flagging local edits instead of clobbering them — via
`.claude/skills/sync/sync.sh`.

Run `/orchestrator:sync` after updating the orchestrator plugin, whenever you want managed files (like
`.claude/workflows/feature-fanout.js`) brought up to date with the version the plugin now carries. This file
is kept as a pointer so `/sync-orchestrator` still resolves for anyone used to the old name.
