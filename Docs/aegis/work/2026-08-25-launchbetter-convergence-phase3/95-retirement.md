# Phase 3 — Retirement Record

## Anti-Entropy Declaration

- Deletion Class: code-retirement
- Old Path/Object: `applyMetadataSnapshot` → `bumpRevision()` + `notifyDataChange()`
- New Canonical Owner: `applyMetadataSnapshot` → `notifyLibraryDataChange()`
- Expected Preserved Behavior: metadata snapshot update, idempotency guard, `libraryModelDirty = true`, Library live refresh via dataObservers
- Expected Retired Behavior: unnecessary `displayRevision` bump + grid `onDataChange` (full grid refresh + PageVisual shutdown) for Library-only changes (launch usage, category override)
- External Boundary Touched: no
- Source-of-Truth Data Risk: none
- User Confirmation Required: no

## Retirement Decision

- Path: delete-first
- Why: internal code retirement; old path was over-broad publication confirmed by spec review
- Non-edits: no protocol changes, no external API changes, no persistence/schema changes

## Verification Plan

- Main-path check: `applyMetadataSnapshot` now calls `notifyLibraryDataChange()` (LauncherStore.swift:336); Library host receives dataObserver notification and calls `refreshModel()` (GridViewController.swift:539)
- Lingering-reference check: grep confirms no remaining call to `bumpRevision` or `notifyDataChange` in `applyMetadataSnapshot` or its call chain
- Negative check: `PublicationDecouplingTests` test 1 asserts `displayRevision` unchanged + `onDataChange` NOT fired for metadata-only notification
- Boundary check: grid-visible paths (`commitLayoutChange`, `drainExternalCatalogRefreshes`, `save()` gridDataChanged) still call `bumpRevision()` + `notifyDataChange()` — confirmed by spec reviewer

## Retired items

1. `bumpRevision()` call in `applyMetadataSnapshot` — removed
2. `notifyDataChange()` call in `applyMetadataSnapshot` — replaced with `notifyLibraryDataChange()`
3. Stale comment "仅标记 dirty + bump + notify" — updated to "仅标记 dirty + notify"
4. Stale comment "applyMetadataSnapshot → rebuildLibraryModel → notify 链路" — updated to "applyMetadataSnapshot → libraryModelDirty → notifyLibraryDataChange 链路"

## Not retired (correctly preserved)

- `hostItem.refreshModel()` at `GridViewController.refresh()` line 665 — kept as defense-in-depth (observer may not be registered yet)
- `notifyDataChange()` in `commitLayoutChange`, `drainExternalCatalogRefreshes`, `save()` gridDataChanged branch — these are grid-visible changes that correctly bump `displayRevision`
- `dataObservers` in `notifyDataChange()` — existing behavior preserved; FolderViewController and other observers still receive all data change notifications

## Gap Closure

- Gap Found: none post-implementation
- Gap Type: N/A
- Reintroduced Compat: no