# DirCompare

A small macOS app that compares two folders side by side, without recursing:
which names exist on only one side, and for names on both sides whether the
contents match and which copy is newer. A command-line tool, `dircmp`, does the
same comparison all the way down, for scripts and agents.

## Build and run

Requires Xcode (Swift 6.2) and macOS 14 or later.

```sh
scripts/build-app.sh                # builds build/DirCompare.app and build/dircmp
scripts/build-app.sh --install      # also copies the app to ~/Applications
scripts/build-app.sh --install-cli  # also copies dircmp to ~/.local/bin
scripts/build-app.sh --open         # also launches the app
swift test                          # runs the comparison tests
```

To open the app on two folders from a terminal:

```sh
open -a DirCompare --args -left ~ -right /Volumes/kevin
```

(Paths must be passed as `-left` and `-right`; bare paths are treated by AppKit
as files to open.)

## Using it

- Choose a folder for each side, or drag folders in from Finder. The comparison
  reruns whenever a folder or option changes; ⌘R reruns it by hand.
- **Status** for each name:
  - *Only left* / *Only right*: exists on one side.
  - *Identical*: same bytes (files) or same target (symlinks).
  - *Different*: sizes or bytes differ, or symlinks point elsewhere.
  - *Type differs*: e.g. a file on one side, a folder on the other.
  - *Folders*: both sides are folders; only their dates are compared.
  - *Not checked*: same size with **Compare contents** off, or a special file.
  - *Unreadable*: permissions or I/O errors; hover the name for details.
- The newer modification date is shown in bold. Dates within 2 seconds count as
  equal, because FAT/exFAT volumes store times at 2-second resolution.
- Click the counts in the bottom bar to filter the table; click again to clear.
- Folders that exist on both sides can be expanded in place, like Finder's list
  view: click the triangle or double-click the row. Their contents are compared
  the first time you expand them, and stay open when you refresh. The filter
  and search keep a folder visible when something loaded inside it matches.
- Double-clicking anything else shows it in Finder.
- Right-click a row to show either copy in Finder, copy paths, or (for files)
  open both in FileMerge. For folders, *Open Folders Side by Side* makes that
  pair the folders being compared; ⌘[ goes back.
- Press Space to Quick Look the selection. For a name on both sides, the left
  copy shows first; use the arrow keys to flip to the right copy.
- ⇧⌘C copies the visible rows as a Markdown table.
- **Ignore** takes comma-separated names or wildcards, like `.DS_Store, *.swp`.
- **Check folders recursively** (off by default): after the top-level results
  appear, each folder that exists on both sides is compared all the way down,
  one at a time in the background. Its row turns *Identical* or *Different*,
  with a summary such as "3 only left, 2 different" next to the name. A folder
  that exists on only one side counts as one item, however much it contains.
  ⌘. stops the check; folders not yet checked keep their date-only status.
  The check fills in the whole tree: every folder at every depth gets a status,
  expanding a checked folder is instant, and filters and search see inside
  folders you haven't expanded. **Expand Differences** (⌘E) opens the tree down
  to every difference; **Collapse All** is ⇧⌘E. To save memory, folders whose
  contents all match keep only their summary and are re-read if you expand them.

## Command line

`dircmp LEFT RIGHT` lists what differs, one line per item, all the way down,
and exits like `diff`: 0 if nothing differs, 1 if something does, 2 if
something couldn't be read. `dircmp --help` explains every status and option.

```sh
dircmp ~/Photos /Volumes/Backup/Photos
different    2024/trip/IMG_0412.HEIC  (2,811,904 → 2,811,520 bytes; right newer)
only-left    2024/trip/IMG_0413.HEIC  (3,102,208 bytes)
Summary: 1 only left, 1 different
```

- It compares the same way as the app (same statuses, ignore patterns, date
  tolerance and Unicode name matching), but recursively by default. `--shallow`
  compares one level, like the app without the recursive check. It always lists
  folder pairs, so you can look inside one with `--under PATH --shallow`, like
  expanding a row in the app.
- Only differences are listed; `--all` adds identical items. `--first` stops at
  the first difference, for when you only need to know whether two folders
  match (`dircmp a b --first > /dev/null && echo same`).
- Output stops after 200 items (`--limit`, 0 for no limit) and says how many
  more there were. For a big tree, survey it with `--summary` (one line per
  top-level item, with counts for each folder), then look inside one folder
  with `--under PATH`. Paths stay relative to the folders you passed.
- `--json` writes one object per line: a `row` record per item, with absolute
  paths, exact sizes and ISO 8601 dates for each side, then a `summary` record.
  `--format markdown` writes the same table as the app's Copy as Markdown.
- Lines are written as they're found, so output cut short is still usable.
  Progress shows on stderr when it's a terminal.

## Notes

- Symlinks are never followed. A symlink is compared by its target path.
- Folder sizes aren't shown: the number the file system reports for a folder
  isn't its contents' size, and varies between volumes.
- Names are matched after Unicode normalization, so `café` written in NFC on one
  volume and NFD on another still pair up.
- The app is ad-hoc signed. macOS will ask for access to Desktop, Documents,
  Downloads and external volumes the first time it reads them, and may ask
  again after a rebuild, since each build has a new signature.

## Checking the UI from a script

Debug builds can render their window to a PNG, which doesn't need Screen
Recording permission. See `Sources/DirCompare/DebugTools.swift` for all options.

```sh
swift build
DIRCOMPARE_SNAPSHOT=/tmp/out.png DIRCOMPARE_EXPAND="docs,docs/notes" \
  .build/debug/DirCompare -left ~/a -right ~/b
```

## Layout

- `Sources/DirCompareCore`: scanning and comparison (no UI; covered by tests)
- `Sources/DirCompare`: the SwiftUI app
- `Sources/dircmp`: the command-line tool
- `Tests/DirCompareCoreTests`: Swift Testing suite
- `scripts/build-app.sh`: builds, bundles and signs the `.app`, and builds `dircmp`
- `scripts/make-icon.swift`: renders the app icon
