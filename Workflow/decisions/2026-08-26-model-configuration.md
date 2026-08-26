# Decision: Role model configuration (2026-08-26)

## Context

User correctly pointed out that the skill's mandatory First-run setup requires
asking the six configuration questions (Main/Chief/Worker/Reviewer models,
max Worker concurrency, default thinking depth) and persisting them to
`Workflow/config.json`. This was completed properly on 2026-08-26 after the
fresh start, with the model catalog discovered from `~/.dsh/settings.yaml`
(providers: `ollama`, `grok`, `opencode-go`).

## Answers (user-confirmed)

| Role | Model | Thinking depth |
|---|---|---|
| Main/Orchestrator | `current-main-conversation` (fixed; skill rule) | — |
| Chief | `ollama/glm-5.2` | `max` (user-specified) |
| Worker | `ollama/deepseek-v4-flash:0731` | `max` (delegated default) |
| Reviewer | `ollama/minimax-m2.7` | `max` (delegated default) |
| Max worker concurrency | `2` | — |

Rationale: Chief = high-intelligence planning (glm-5.2 @ max); Worker =
high-throughput implementation (flash:0731); Reviewer = independent diagnostic
(minimax-m2.7); concurrency 2 balances the shared worktree + AGENTS.md
single-writer rule against speed.

## Routing caveat

Model ids are declared as `provider/model` per the harness catalog. Actual
subagent routing in this DSH harness is verified at dispatch time; if the
harness rejects a configured model, Main stops and asks for reconfiguration
(no silent fallback), per skill.

## Artifacts

- `Workflow/config.json` — reconfigured at `2026-08-26T13:48:33+09:00`
  (schema v1.4).
- `AGENTS.md` / `MEMORY.md` — managed sections regenerated with the new values.
