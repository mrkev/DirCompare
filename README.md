# DirCompare

A small macOS app that compares two folders side by side, without recursing:
which names exist on only one side, and for names on both sides whether the
contents match and which copy is newer.

## Build and run

Requires Xcode (Swift 6.2) and macOS 14 or later.

```sh
scripts/build-app.sh            # builds build/DirCompare.app
scripts/build-app.sh --install  # also copies it to ~/Applications
scripts/build-app.sh --open     # also launches it
swift test                      # runs the comparison tests
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
  For now this fills in top-level folders only; folders inside an expanded
  folder show their date-only status.

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
- `Tests/DirCompareCoreTests`: Swift Testing suite
- `scripts/build-app.sh`: builds, bundles and signs the `.app`
- `scripts/make-icon.swift`: renders the app icon
