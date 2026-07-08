# `orchestrator` plugin

This repository IS the plugin. The plugin root is `.claude/` (where this manifest lives), and the
repo dogfoods its own harness: the same `.claude/agents`, `.claude/commands`, and `.claude/scripts`
that ship to downstream installs are what runs the live self-hosted PR loop here.

## Dual command invocation
- **In-repo (dogfooding):** commands run as project-level slash commands, e.g. `/pr-loop`,
  `/harden`, `/setup-orchestrator`, `/sync-orchestrator`, `/test-pr`.
- **Installed as a plugin:** Claude Code auto-namespaces commands under the plugin `name`
  (`orchestrator`), so the same commands become `/orchestrator:pr-loop`,
  `/orchestrator:harden`, etc. No file renames are needed for this — the namespace comes
  from `name` in `plugin.json`, not from filenames.
- `plugin.json` carries an explicit `commands` allowlist (issue #76) so only consumer-facing
  commands ship downstream. `.claude/self/pr-loop-self.md` — this repo's own self-hosting loop
  prompt — is deliberately excluded: it lives under `.claude/self/` (not `.claude/commands/`), so
  it is never auto-discovered as a project slash command either. See `.claude/self/README.md` for
  how to run it in-repo.

## The `${CLAUDE_PLUGIN_ROOT:-.claude}` fallback
Agent/command prompts invoke scripts as:

    bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/<name>.sh

When the plugin is installed, Claude Code sets `CLAUDE_PLUGIN_ROOT` to the install path and the
shipped `scripts/` resolve there. In-repo, the variable is unset, so the fallback expands to
`.claude`, giving the exact same `.claude/scripts/<name>.sh` path the harness has always used —
the live self-hosting loop is unaffected.

## What's plugin-distributable (phase 1 scope)
Auto-discovered from the plugin root: `agents/`, `hooks/hooks.json`, `scripts/`. `commands/` is
instead scoped by `plugin.json`'s explicit `commands` allowlist, which lists only the
consumer-facing command files — this disables the default directory-wide auto-discovery for
`commands/` so an in-repo-only file added under `.claude/commands/` wouldn't ship by accident.

Not distributed by this plugin (repo-scaffolded, project-specific):
- `.claude/workflows/*.js` — deterministic fan-out workflows, not plugin-portable.
- `.claude/self/*` — this repo's OWN self-hosting adapter (gates, checks, and the
  `pr-loop-self.md` loop prompt), not for downstream projects; downstream adopters get the
  placeholder `.claude/gates.json` instead.

## Enabling in a consuming project

`marketplace.json` lives alongside `plugin.json`, at `.claude/.claude-plugin/marketplace.json` —
so its "marketplace root" is `.claude/`, the same directory the plugin itself is rooted at. It
lists a single plugin entry, `orchestrator`, with `"source": "./"` (relative to that marketplace
root, i.e. the plugin payload is the marketplace root itself).

A consuming project registers this repo as a marketplace source and enables the plugin from it in
its own `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ai-project-orchestrator": {
      "source": {
        "source": "github",
        "repo": "robercano/ai-project-orchestrator"
      }
    }
  },
  "enabledPlugins": {
    "orchestrator@ai-project-orchestrator": true
  }
}
```

`extraKnownMarketplaces` registers `robercano/ai-project-orchestrator` (a GitHub repo) as a
marketplace named `ai-project-orchestrator`; `enabledPlugins` then enables the `orchestrator`
plugin from it, addressed as `<plugin-name>@<marketplace-name>`.

**Resolved via a repo-root alias:** Claude Code's `"source": "github"` marketplace source resolves
`marketplace.json` at the repo **root** (`.claude-plugin/marketplace.json`), not a subdirectory.
Since this repo's plugin root is `.claude/`, there's a second, thin manifest at the actual repo root
(`.claude-plugin/marketplace.json`, sibling to this one) whose single plugin entry points back down
via a relative path — `"source": "./.claude"` — which the marketplace-source docs confirm is
supported for same-repo plugins. That root file is what makes the bare GitHub snippet above resolve;
see its own `.claude-plugin/README.md` (at repo root) for the two-manifest rationale. It carries no
`version`/`author` so it never needs to be kept in sync with this file — it just points at this
directory's payload.
