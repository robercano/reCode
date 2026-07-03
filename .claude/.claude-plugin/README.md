# `orchestrator` plugin

This repository IS the plugin. The plugin root is `.claude/` (where this manifest lives), and the
repo dogfoods its own harness: the same `.claude/agents`, `.claude/commands`, and `.claude/scripts`
that ship to downstream installs are what runs the live self-hosted PR loop here.

## Dual command invocation
- **In-repo (dogfooding):** commands run as project-level slash commands, e.g. `/pr-loop`,
  `/pr-loop-self`, `/harden`, `/setup-orchestrator`, `/test-pr`.
- **Installed as a plugin:** Claude Code auto-namespaces commands under the plugin `name`
  (`orchestrator`), so the same commands become `/orchestrator:pr-loop`,
  `/orchestrator:pr-loop-self`, etc. No file renames are needed for this — the namespace comes
  from `name` in `plugin.json`, not from filenames.

## The `${CLAUDE_PLUGIN_ROOT:-.claude}` fallback
Agent/command prompts invoke scripts as:

    bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/<name>.sh

When the plugin is installed, Claude Code sets `CLAUDE_PLUGIN_ROOT` to the install path and the
shipped `scripts/` resolve there. In-repo, the variable is unset, so the fallback expands to
`.claude`, giving the exact same `.claude/scripts/<name>.sh` path the harness has always used —
the live self-hosting loop is unaffected.

## What's plugin-distributable (phase 1 scope)
Auto-discovered from the plugin root: `commands/`, `agents/`, `hooks/hooks.json`, `scripts/`.

Not distributed by this plugin (repo-scaffolded, project-specific):
- `.claude/workflows/*.js` — deterministic fan-out workflows, not plugin-portable.
- `.claude/self/*` — this repo's OWN self-hosting adapter (gates, checks), not for downstream
  projects; downstream adopters get the placeholder `.claude/gates.json` instead.
