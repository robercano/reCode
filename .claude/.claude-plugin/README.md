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

**Known limitation:** Claude Code's documented `"source": "github"` marketplace source resolves
`marketplace.json` at the repo **root** (`.claude-plugin/marketplace.json`), with no documented
field to point it at a subdirectory. This repo's `marketplace.json` instead lives at
`.claude/.claude-plugin/marketplace.json`, matching the plugin-root-is-`.claude/` layout described
above. Until Claude Code supports a subdirectory marketplace source (or this repo additionally
publishes a repo-root alias), the snippet above is the intended shape but may require consumers to
add the marketplace from a local clone instead (e.g. `/plugin marketplace add
<path-to-clone>/.claude`) rather than the bare GitHub shorthand. Revisit this note if/when
subdirectory marketplace sources land upstream.
