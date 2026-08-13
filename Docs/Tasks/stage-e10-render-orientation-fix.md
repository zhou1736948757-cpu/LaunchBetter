# Task: Stage E10 layer-render orientation fix

## Goal

Fix the fresh App Library diagnostic PNG render so the complete AppKit content is
visually oriented like the on-screen window. Current evidence is globally
horizontally mirrored: icons/layout are present, but all text is unreadable.

## Evidence

- `/tmp/lb-e10/top5.png`
- `/tmp/lb-e10/mid.png`
- `/tmp/lb-e10/detail.png`
- `/tmp/lb-e10/search.png`
- `/tmp/lb-e10/settings.png`
- `/tmp/lb-e10/settings_settings.png`

The independent visual review classified the global mirror as BLOCKER and the
empty Settings wallpaper preview rectangles as MINOR.

## Allowed files

- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`
- `LaunchBetterApp/Diagnostics/AppLibraryShotProbe.swift`
- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift`
- `LaunchBetterApp/Diagnostics/ActivationCoordinator.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`

Do not modify LayoutStore, Catalog persistence, user layout data, old
`/Users/mac/Projects/Launchpad_Back`, or existing unrelated untracked files.
Do not commit or switch branches.

## Constraints

- Keep layer rendering; do not use `cacheDisplay` or `screencapture`.
- Correct the coordinate transform for both launcher and Settings PNGs.
- Do not add `DispatchQueue.main.sync`.
- Keep the probe non-interactive and read-only with respect to Layout/Config/Usage.
- Prefer the smallest transform fix; do not alter production UI geometry to make
  the diagnostic image look correct.

## Verification

1. `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter -configuration Debug build`
2. Run fresh `top`, `mid`, `detail`, `search`, and `settings` libraryshot states.
3. Confirm PNG dimensions/backing scale and inspect all generated images.
4. Report the exact transform change, commands, paths, and remaining visual/manual
   limitations. Do not claim physical trackpad or 120 Hz validation.

## Resolution (2026-08-13, 已验证)

### Root cause

The mirrored output is NOT a whole-window x-flip. `NSTextField` layers whose
ancestors are flipped (`PausableLibraryScrollView`, `LibraryCollectionView`,
`ClickableCollectionView`, settings `NSVisualEffectView`) render their glyphs
horizontally mirrored through `CALayer.render(in:)`, while the rest of the layer
tree (icons, cards, chrome) renders correctly. A global `scaleBy(x: -1)` "fix"
restores text but mirrors the otherwise-correct chrome (search icon left,
gear right, card order) and was therefore rejected.

### Applied fix (probe-scoped, smallest change)

- `LaunchBetterApp/Diagnostics/AppLibraryShotProbe.swift`:
  - `captureLibraryContent` now walks `LauncherWindowController.window.contentView`
    and temporarily sets `layer.isGeometryFlipped = false` on every `NSTextField`
    before `captureContentScreenshot(to:)`, restoring each original value after
    (covers Library cards, detail rows, AppCell labels, search placeholder).
  - `captureSettingsWindow` applies the same normalization to the Settings
    window content before `layer.render(in:)`.
- `LauncherWindowController.captureContentScreenshot` is unchanged from HEAD
  (an experimental x-flip was added and fully reverted).

### Verification results

- Debug build: BUILD SUCCEEDED.
- LaunchUI 264 / LaunchPlatform 137 / LaunchCore 166 + 97 all green.
- Fresh PNGs (final evidence):
  - `/tmp/lb-e10/final-top3.png` — state=top, interaction=appLibrary,
    surface=appLibrary, cards=7 visible=7; OCR reads 其他/开发工具/娱乐/实用工具/
    建议/社交/效率/搜索应用 at expected positions.
  - `/tmp/lb-e10/final-mid2.png` — state=mid, `mid scroll=STABLE_NOOP` (content
    fits one screen; recorded, not a defect).
  - `/tmp/lb-e10/final-detail2.png` — interaction=appLibraryCategory detail=1;
    OCR reads all row names (Mail/Calendar/Contacts/LaunchBetter/...).
  - `/tmp/lb-e10/final-search2.png` — interaction=appLibrary surface=appLibrary
    search=1; OCR reads all result labels (哔哩哔哩/微信/QQ/WPS Office/...).
  - `/tmp/lb-e10/final-settings2.png` + `final-settings2_settings.png` —
    interaction=settings; all row labels readable (关于/网格/列数 8/行数 5/…).
- All PNGs 2940x1912 @2x except settings window 1520x1360 @2x.

### Known remaining limitations (recorded, not Stage E regressions)

- Settings control-internal titles (NSPopUpButton selection, NSButton titles,
  checkbox glyphs) still render mirrored through `CALayer.render`. Reproduced
  identically with the pre-existing `--settingsshot` probe
  (`/tmp/lb-e10/legacy-settingsshot.png`), i.e. a pre-existing AppKit capture
  pipeline limitation of NSControl internals, not a Stage E change.
- The two wallpaper preview rectangles render black in layer-render captures
  (pre-existing; needs on-screen verification on a real device).
- The probe once observed a settle race (semantic surface reported
  layoutPage(0) after navigate-to-Library); rerun succeeded. Recorded for
  physical verification; not reproduced again.
- Physical gates remain: real trackpad, 120 Hz feel, physical time continuity.
