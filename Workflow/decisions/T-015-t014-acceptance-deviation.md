# Chief Decision Delta — T-014 Acceptance Deviation (T-015)

- **Date**: 2026-08-26
- **Role**: Chief (independent, persistent planning & decision subagent)
- **Decision type**: Decision Delta (plan-level acceptance of a recorded deviation in T-014's acceptance wording; T-015 prerequisite)
- **Status**: FINAL

---

## 1. Context

### 1.1 T-014 AC2 requirement vs actual recorded chain

`Workflow/tasks/T-014.md` line 81 (Acceptance Criterion 2) requires:

> T-014 生命周期事件齐全且真实（task_created → worker_dispatched → worker_completed → review_started → review_passed → task_closed）

The actual chain recorded in `Workflow/events.jsonl` for T-014 (lines 7–12, seq 7–12) is:

`task_created(seq 7) → state_changed(seq 8) → worker_completed(seq 9) → review_passed(seq 10) → state_changed(seq 11) → task_closed(seq 12)`

Missing from the recorded chain: **`worker_dispatched`** and **`review_started`**.

The two `state_changed` events are honest and explicit about the gap:
- seq 8 (events.jsonl line 8): "T-013's worker_dispatched/review_started were never recorded at the time and are NOT retroactively claimed" (about T-013 attempts rebuild);
- seq 11 (events.jsonl line 11): "T-014 worker_dispatched / review_started were not recorded at the time (dispatch/start happened before this note); attempts rebuilt 0->1 at close FROM EXISTING completion evidence (worker_completed seq 9, review_passed seq 10); no backfilled fake dispatch/start events".

So: **timeline honesty is satisfied** (the gap is declared, nothing fabricated), but **lifecycle completeness as AC-2 literally requires is NOT satisfied** (the two scheduling events do not exist in the event stream).

### 1.2 P-1 / P-2 facts (verified by Chief against primary sources)

- **P-1 (AC2 not strictly met)**: confirmed by `Workflow/events.jsonl` lines 7–12 (seq 7–12) vs `Workflow/tasks/T-014.md` line 81. `Workflow/reviews/T-014-r1.md` lines 66–75 (CT02 note) and lines 188–194 (Finding 2, MINOR) explicitly record the same gap and instruct: append real close-time events plus an honest `state_changed` note, and **do NOT backfill a forged dispatch event**. The Reviewer's close-time repair was executed exactly that way (events seq 11–12, lines 11–12).
- **P-2 (line-number drift again)**: `Workflow一/reviews/T-012-r2.md` Addendum 2 (lines 46–83) recorded snapshot line numbers (e.g. T-007 row = 545, work-log:start = 553, work-log:end = 624) that were accurate at Worker/Reviewer check time (`Workflow/reviews/T-014-r1.md` lines 83–103 verified them against live `nl -ba`). After Main closed T-014, `MEMORY.md` gained the T-014 ledger row and closure work-log entry; current `MEMORY.md` now shows T-014 row at line 545, T-007 row at 546, work-log:start at 554, and work-log:end at 632 (MEMORY.md lines 545–546, 554, 632) — drift occurred again (T-007 545→546, start 553→554, end 624→632). This is normal content evolution, not evidence invalidation; it proves absolute line numbers are an unstable reference and the stable-anchor policy is required.

### 1.3 State at decision time

- `Workflow/STATE.json` lines 33–45: T-014 status `PASSED`, `worker_attempts 1`, `review_attempts 1`; lines 46–58: T-015 `EXECUTING`; `active_agent_jobs []`, `blockers []` (lines 60–61).
- `Workflow/reviews/T-014-r1.md` line 3: VERDICT: PASS (2 MINOR findings, none blocking).
- `Workflow/results/T-014.md` lines 47–55: P2 honesty note recorded by Main.

---

## 2. Decision body

### DECISION: ACCEPT_RECORDED_DEVIATION

The deviation between T-014 AC-2's required event chain and the actually recorded chain is **accepted at plan level** as a recorded deviation. Rationale:

1. The gap is a **record-keeping gap**, not a deliverable failure: T-014's substantive record-reconciliation work was performed and independently verified PASS (`Workflow/reviews/T-014-r1.md` line 3, 200–207).
2. The missing events **cannot be legitimately restored**: `Workflow/tasks/T-014.md` line 31 forbids inserting/modifying old JSONL lines and forbids fabricating a past timeline; `Workflow/tasks/T-015.md` lines 47–49 repeat the prohibition. A REPLAN to "complete" AC-2 would require forging `worker_dispatched`/`review_started`, which is dishonest and prohibited.
3. The recorded chain is **honest**: the `state_changed` events (seq 8, seq 11) disclose exactly what was not recorded and what was rebuilt from completion evidence. Honesty over completeness is the correct priority for historical records.
4. The same pattern was independently flagged by the Reviewer as MINOR (not blocking) with the explicit "no backfill" instruction — the acceptance of this deviation is consistent with the independent review evidence.

### The six-point meaning of this acceptance (per T-015 §3, lines 127–141)

1. **No backfill / no fabrication**: T-014's missing historical scheduling events (`worker_dispatched`, `review_started`) will NOT be retroactively inserted into `Workflow/events.jsonl`, and no past timestamps will be invented. The event log remains append-only (T-014 task line 74; T-015 §4, events append-only).
2. **AC-2 recorded assessment**: T-014 AC-2 is recorded as — timeline honesty: **PASS**; lifecycle completeness: **NOT MET**; accepted record deviation: **YES**.
3. **T-014 status wording**: T-014 retains task status `PASSED`, but only expressible as **`PASSED WITH RECORDED DEVIATION`**. It must NOT be expressed as "7/7 criteria all satisfied" or "lifecycle events complete".
4. **This acceptance is a Chief plan-level decision**: it does not claim that the original AC-2 was met; it formally acknowledges the deviation and keeps the record truthful.
5. **Scope limited to T-014 history**: this acceptance applies only to T-014's historical record; it does not change event requirements for future tasks.
6. **Forward discipline from T-015**: starting with T-015, Main must append the full lifecycle chain — `task_created → worker_dispatched → worker_completed → review_started → review_passed → task_closed` — at the real times the scheduling actions occur, and must not substitute explanatory events for scheduling events after the fact.

---

## 3. Decision basis (evidence cited, files actually read)

| Evidence | Location | What it establishes |
|---|---|---|
| `Workflow/tasks/T-014.md` line 81 | read | AC-2's required full lifecycle chain. |
| `Workflow/tasks/T-014.md` lines 30–34 | read | P-2: no insertion/modification of old JSONL lines; honest `state_changed`; T-014's own events to be appended in real time. |
| `Workflow/tasks/T-015.md` lines 59–62, 78–95 | read | Snapshot of actual T-014 chain; P-1 statement; forbidden phrasings ("7/7 无条件 PASS"). |
| `Workflow/tasks/T-015.md` lines 47–49, 146–168 | read | Backfill prohibition + T-015's own required complete real chain. |
| `Workflow/events.jsonl` lines 7–12 (seq 7–12), 13 (seq 13) | read | Actual T-014 chain; missing `worker_dispatched`/`review_started`; honest seq 8 & 11 notes; T-015 `task_created` present. |
| `Workflow/results/T-014.md` lines 47–58 | read | Main's P-2 honesty note (worker_dispatched/review_started "never recorded at the time ... NOT retroactively claimed"). |
| `Workflow/reviews/T-014-r1.md` lines 3, 66–75, 188–194 | read | VERDICT: PASS; CT02 note and Finding 2 (MINOR): do NOT backfill forged dispatch; close-time honest note executed. |
| `Workflow/STATE.json` lines 33–45 | read | T-014 terminal `PASSED` attempts 1/1 (consistent with this decision's wording constraint). |
| `Workflow一/reviews/T-012-r2.md` lines 46–83 | read | Addendum 2's 2026-08-26 line-number snapshot (T-007=545, work-log:start=553, end=624). |
| `MEMORY.md` lines 526, 534–546, 554, 626–632 | read | Current line numbers after T-014 closure (T-014 row 545, T-007 546, start 554, end 632) — drift vs Addendum 2 snapshot, proving P-2. |

No fabricated line numbers or events are cited; every referenced line was read from the actual files listed above.

---

## 4. Impact scope and follow-up constraints

- **Impacted records (wording only)**: T-014 result and any canonical statement about T-014 must use `PASSED WITH RECORDED DEVIATION`; expressions "T-014 生命周期齐全" / "7/7 无条件 PASS" / "所有 Acceptance Criteria 全部满足" are forbidden (T-015 §1.1).
- **Unchanged**: T-014 task status `PASSED` (STATE lines 33–45); T-014 attempts 1/1; T-013 conclusions; MANUAL_PHYSICAL_GATE stays `OPEN / REQUIRED`; no commit/push/tag/release.
- **P-2 follow-up**: MEMORY references must use stable anchors — section heading (`### Current state`, `### Task ledger`, `### Work log`), Task ID rows, work-log entry headings, and the managed `work-log:start`/`work-log:end` markers. Do not chase live line numbers; `nl -ba` output is only a debugging aid, never a long-term identifier.
- **T-015 must itself**: append the complete real chain `task_created → worker_dispatched → worker_completed → review_started → review_passed → task_closed` at real times (worker_dispatched before Worker begins, review_started before Reviewer begins); never write post-hoc substitute events; keep seq strictly increasing, timestamps non-decreasing, JSONL append-only. If any of these events is missed at runtime, T-015 may not claim a full PASS.
- **Recorded deviation must be visible** in T-014's result Addendum (per T-015 §6) and confirmed or rejected by the Reviewer in a Reviewer-owned Addendum.

---

DECISION: ACCEPT_RECORDED_DEVIATION
