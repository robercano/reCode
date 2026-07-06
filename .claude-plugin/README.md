# Repo-root marketplace alias

This `marketplace.json` exists ONLY so Claude Code's `"source": "github"` marketplace resolution can find it —
that resolution looks for `.claude-plugin/marketplace.json` at the repo **root**, with no documented way to
point it at a subdirectory (see [`plugin-marketplaces` docs](https://code.claude.com/docs/en/plugin-marketplaces#relative-paths)).

The actual plugin payload (`commands/`, `agents/`, `hooks/hooks.json`, `scripts/`) still lives under `.claude/`,
because the plugin root IS `.claude/` — this repo dogfoods its own harness (see `.claude/.claude-plugin/README.md`
for the full explanation). This file's single plugin entry points there via a relative path:
`"source": "./.claude"`, which the marketplace-source docs confirm is supported ("for plugins in the same
repository, use a path starting with `./`... paths resolve relative to the marketplace root").

**Two `marketplace.json` files, one payload:**
- `.claude/.claude-plugin/marketplace.json` — for the local-clone install method (`/plugin marketplace add
  <path-to-clone>/.claude`), where the plugin root IS the marketplace root (`"source": "./"`).
- `.claude-plugin/marketplace.json` (this file) — for the GitHub-source install method
  (`extraKnownMarketplaces` with `"source": "github", "repo": "robercano/ai-project-orchestrator"`), where the
  marketplace root is the repo root and the plugin lives one level down (`"source": "./.claude"`).

Deliberately omits `version`/`author` (present on the other manifest) — a `version` here would *pin* the
plugin to that string, so consumers using this file wouldn't see updates until this file's version is also
bumped. Omitting it lets the plugin track the git commit SHA instead, matching how the local-clone method
already behaves. If you add real content changes to the plugin (agents/commands/scripts/hooks), you don't need
to touch either `marketplace.json` — only `.claude/.claude-plugin/plugin.json`'s version, if you use pinned
versioning at all.
