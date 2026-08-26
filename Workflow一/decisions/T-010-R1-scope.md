# T-010-R1 Scope and Baseline Decision

## Decision
Accept only a test-evidence repair. The T-010-R1 implementation scope is limited to `PageCompositorGridIntegrationTests.swift` plus Workflow evidence files.

## Baseline justification
The working tree contains production hunks from the already reviewed T-005/T-006 repair line (coordinate alignment, compositor activation/reuse/fallback wiring, deterministic probes, telemetry lifecycle, and diagnostics). Those baseline changes were independently accepted in:

- `Workflow/reviews/T-006-final-r1.md`
- `Workflow/decisions/T-006-sol-acceptance.md`
- `Workflow/results/T-007.md` (reopened only for the new telemetry/evidence requirements)

T-010-R1 must not add or alter production behavior. Any production diff attributed to T-010-R1 is a failure. The repair may use already-existing internal diagnostic seams; no public API or second motion writer is permitted.

## Required evidence
The covered reverse test must explicitly expose/assert the resolved target Page 1 and exact final event deltas: one new `finishedSettle`, zero new `aborted`, zero new `shutdown` after the reverse gesture. It must also assert target membership in the active `[1,2]` placement set and stable layer identity.
