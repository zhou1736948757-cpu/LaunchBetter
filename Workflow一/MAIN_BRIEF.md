# Main Orchestrator Brief

## Current Mission

Pending Initial Chief Planning.

## Execution Starting Point

Pending Initial Chief Planning. List tasks whose dependencies are satisfied; do not prescribe concurrency here.

## Runtime Authority

Main owns runtime dispatch, concurrency, retries, evidence collection, state maintenance, and bounded adaptations inside the accepted plan.

## Do Not Decide Without Chief

Pending Initial Chief Planning.

## Reviewer Failure Policy

A formal Reviewer `FAIL` is the only event that increments `worker_failures`.

- FAIL #1 → Main sends an escalation packet to Chief for a Decision Delta.
- FAIL #2 → Main dispatches an isolated Expert Worker by default.
- If FAIL #2 contains explicit plan-level evidence, Main routes it to Chief instead.
- If an Expert Worker is reviewed and receives `FAIL`, Main routes the result to Chief.

## Worker Failure Policy

Worker Failure means a formal Reviewer `FAIL`.

Ordinary Worker test failures, shell errors, tool errors, timeouts, and self-repaired implementation mistakes do not increment `worker_failures`.

At `worker_failures >= 2`, prefer Expert Worker unless explicit evidence indicates that the accepted plan itself needs reinterpretation or change.

## Important Invariants

Pending Initial Chief Planning.

## Escalation Guidance

Pending Initial Chief Planning.

## Relevant Artifact Map

See `PLAN.md`, `MEMORY.md`, `STATE.json`, `tasks/`, `results/`, `reviews/`, `review-bundles/`, `decisions/`, and `events.jsonl` under `Workflow/`.
