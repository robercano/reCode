# Template → destination map

Read by humans (and `scaffold.sh`, informally) to see where each template lands in a
consumer repo. None of these paths are distributable inside the plugin package itself
(workflows and CI YAML aren't carried by a Claude Code plugin), so `/orchestrator:setup`
materializes them into the consumer repo on first run.

| Template file    | Destination in consumer repo         | Ownership | Re-run behavior                          |
|-------------------|---------------------------------------|-----------|-------------------------------------------|
| `gates.json`       | `.claude/gates.json`                  | user      | created only if absent; never overwritten |
| `CLAUDE.md`         | `CLAUDE.md`                            | user      | created only if absent; never overwritten |
| `feature-fanout.js` | `.claude/workflows/feature-fanout.js` | managed   | re-stamped when the `@orchestrator-managed feature-fanout vN` marker is older than the version scaffold.sh ships; left alone if same/newer |
| `gates.yml`         | `.github/workflows/gates.yml`         | ci        | created only if absent; never overwritten |
| `action.yml`        | `.github/actions/setup/action.yml`    | ci        | created only if absent; never overwritten |

See `.claude/skills/setup/scaffold.sh` for the implementation, and `.claude/skills/setup/SKILL.md`
for the full onboarding flow this scaffold step is one part of.
