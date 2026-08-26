# Workflow — chef-worker-reviewer-workflow artifacts (LaunchBetter)

Canonical runtime artifacts for the `chef-worker-reviewer-workflow` v1.4 run
(initialized 2026-08-26). This directory is the **canonical** artifact root.

## Layout

| Path | Purpose |
|---|---|
| `Workflow/` | Canonical artifacts (this directory; `artifact_root`). |
| `Workflow/tasks/` | Task packages (authoritative per-task specs). |
| `Workflow/results/` | Worker result records (canonical). |
| `Workflow/reviews/` | Independent Reviewer records (canonical). |
| `Workflow/decisions/` | Chief/Main decisions. |
| `Workflow/review-bundles/` | Review evidence bundles. |
| `Workflow/STATE.json` | Runtime state (Main-owned). |
| `Workflow/events.jsonl` | Append-only event log. |
| `Workflow一/` | **Legacy backup** (read-only archive of the previous run, incl. `ARCHIVE-NOTE.md`). |

## Version fields (C5, 2026-08-26)

Three version fields exist; all currently read `1.4`. They are recorded
independently and happen to be equal; do not force them to stay equal:

- `Workflow/manifest.json` → `version`: workflow contract version of this
  artifact set (1.4).
- `Workflow/config.json` → `version`: runtime configuration schema version
  (1.4).
- `Workflow/STATE.json` → `version`: state schema version (1.4).

`Workflow/manifest.json` additionally records `artifact_root` (`Workflow`),
`legacy_backup` (`Workflow一`), and `legacy_backup_read_only` (`true`).

## Historical acceptance records

- Archived records in `Workflow一/` are **historical**: they are retained for
  audit history and are not current acceptance results. Where an archived record
  conflicts with a canonical record, the canonical record (or the archive's own
  HISTORICAL/SUPERSEDED annotation) takes precedence.
- T-010: canonical acceptance = `Workflow/results/T-010-R2.md` +
  `Workflow/reviews/T-010-R2-r1.md` (PASS). `Workflow/results/T-010.md` and
  `Workflow/reviews/T-010-r1.md` are historical pointer files; the archived
  originals are annotated SUPERSEDED/HISTORICAL.
- T-013: `Workflow/results/T-013.md` (this task's result) and
  `Workflow/reviews/T-013-r1.md` (Reviewer verdict).

## Rules

- Do not delete history or overwrite unmanaged files.
- `Workflow一/` is read-only for normal operation; only explicit archive
  maintenance (e.g. T-013 C1–C3 annotations) may touch it, and only by
  appending/prepending annotation blocks, never rewriting originals.
- No secrets, tokens, keys, or personal data in Workflow artifacts.
