# Chef Decision Escalation Policy

## Decision
Chef remains `openai-codex/gpt-5.6-luna` with `high` thinking depth for normal planning, routing, and arbitration.

When Chef determines that a decision requires high-intelligence arbitration or may change execution direction, escalate that decision to the senior assistant:

- Provider: `openai-codex`
- Model: `gpt-5.6-sol`
- Thinking depth: `medium`

The senior assistant returns a recommendation and evidence; Chef retains final coordination authority and records the decision before execution continues.

## Scope
This escalation applies only to decision/arbitration turns. Worker and Reviewer remain `openai-codex/gpt-5.6-luna` at `high`.

## Configuration
`.workflow/config.json` → `decision_escalation`.
