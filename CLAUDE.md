# CLAUDE.md

DirCompare is a SwiftUI macOS app that compares two folders. See `README.md` for
what it does from a user's point of view.

## Commands

```sh
swift build                         # debug build
swift test                          # Swift Testing suite (core library only)
scripts/build-app.sh                # release build → build/DirCompare.app (ad-hoc signed) + build/dircmp
scripts/build-app.sh --install      # also copy the app to ~/Applications
scripts/build-app.sh --install-cli  # also copy dircmp to ~/.local/bin
scripts/build-app.sh --open         # also launch the app
.build/debug/dircmp L R             # try the CLI after `swift build`
```

Requires Xcode, not just the Command Line Tools: the code uses Swift 6.2
(`@concurrent`) and Swift Testing. The deployment target is macOS 14.

## Layout

- `Sources/DirCompareCore`: scanning and comparison, no UI. Everything testable
  lives here.
  - `DirectoryComparer` compares one level; `compare(_:_:under:)` takes the
    folder row being expanded so child rows get prefixed IDs and paths.
  - `FolderSummary.swift` has the recursive walker. `checkFolder(_:)` returns a
    summary plus the rows of every folder that differs (`levels`); folders whose
    contents all match aren't kept, to save memory. `walk(_:_:visit:)` streams
    every row instead, for the CLI.
  - `CommandLineReport.swift` is everything `dircmp` prints (text, JSON,
    Markdown), the limit, and the exit code.
- `Sources/dircmp`: the command-line tool. Argument parsing only
  (swift-argument-parser, the package's one dependency); logic goes in Core.
- `Sources/DirCompare`: the app. `CompareModel` is the per-window state; views
  are thin.
- `Tests/DirCompareCoreTests`: one file, grouped into suites. `Fixture` builds
  temporary left/right folder pairs.

## Concepts worth knowing

- **Row IDs are normalized relative paths** (`a/b/file`, Unicode NFC). `path` is
  the same path as named on disk, for display and export. Names are paired across
  sides by their normalized form, because SMB and exFAT volumes can use NFD.
- **The table is a tree.** The top level is `result.rows`; rows inside folders
  live in `CompareModel.childRows`, keyed by the folder row's ID. Expanded folders
  are in `expanded` and survive refreshes. `visibleChildren(of:)` applies the
  filter and search, keeping a folder visible if anything loaded inside matches.
- **Lazy by default.** Nothing recurses unless "Check folders recursively" is on;
  expanding a folder compares just that pair, one level deep.
- **Folder statuses.** Without the recursive check, a folder pair is `.folders`
  (dates only). The check replaces that with the summary's status via
  `ComparisonRow.apply(_:)`.
- **Stale async results are dropped with a generation counter.** Every comparison
  bumps `generation`; async work captures it and bails if it changed. Keep that
  pattern for new background work.

## Conventions

- Swift 6 language mode with strict concurrency. `CompareModel` is `@MainActor
  @Observable`. Core work is synchronous, throwing, and calls
  `Task.checkCancellation()` in loops; the app runs it through `@concurrent`
  async wrappers (`compareAsync`, `checkFolderAsync`), so Stop cancels it.
- Symlinks are never followed. That's also what keeps the recursive walk free of
  cycles.
- Sizes are shown as exact byte counts, so a 1-byte difference stays visible.
  Folder sizes are never shown: the file system's number isn't meaningful.
- Dates within 2 seconds count as equal (FAT/exFAT resolution).
- Add tests for core changes. Tests use real temporary folders, not mocks.
- Keep the README's "Using it" section in sync with user-visible changes.

## The CLI is for agents too

`dircmp`'s output is an interface that scripts and agents parse, so:

- `--help` is the documentation agents read first. Keep its status list,
  examples and exit codes accurate.
- Bump `CommandLineReport.schemaVersion` when a JSON change could break a
  reader (renamed or removed fields, changed meanings). Adding fields is fine.
- Keep output bounded by default (`--limit`) and streamed a line at a time.
- Status tokens (`only-left`, …) are shared by text and JSON; don't rename them.

## Checking the UI

Screen Recording isn't granted to the terminal, so `screencapture` only shows the
wallpaper. Debug builds can render their own window instead; see
`Sources/DirCompare/DebugTools.swift`:

```sh
swift build
DIRCOMPARE_SNAPSHOT=.build/out.png DIRCOMPARE_EXPAND="docs,docs/notes" \
  DIRCOMPARE_FILTER=differences .build/debug/DirCompare \
  -left /path/to/L -right /path/to/R -checkFoldersRecursively YES
```

- Build a small fixture with `mktemp -d` rather than pointing it at real folders,
  so the expected result is known.
- Run it in the background with a `sleep` watchdog (there's no `timeout` on
  macOS), then read the PNG.
- **Known artifact:** in scripted runs, toolbar buttons keep their first-render
  enabled state (e.g. Copy as Markdown looks disabled). The real app updates
  them correctly, so don't chase this from snapshots.
- Clicking, keyboard handling and Quick Look can't be checked this way; ask the
  user to try those.

## Gotchas

- Pass folders at launch as `-left PATH -right PATH`. Bare paths make AppKit treat
  them as documents to open, and then SwiftUI doesn't open a window.
- Foundation already has `ComparisonResult`; the comparison type is
  `DirectoryComparison` for that reason.
- The shell's `sed` is BSD `sed`: no `0,/re/` addresses, and `-i` needs `''`.
- `timeout` isn't installed.

## Workflow

- Build the app (`scripts/build-app.sh`) and let the user try UI changes before
  committing; commit and push once they confirm.
