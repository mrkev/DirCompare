#if DEBUG
import AppKit

/// Debug-build hooks for checking the UI from a script, without Screen Recording permission:
///
///     DIRCOMPARE_SNAPSHOT=/tmp/out.png      render the window to a PNG, then quit
///     DIRCOMPARE_SNAPSHOT_DELAY=4           seconds to wait first (default 3)
///     DIRCOMPARE_EXPAND="Documents,a/b"     folder row IDs to expand at launch
///     DIRCOMPARE_FILTER=differences         a RowFilter raw value
///     DIRCOMPARE_SEARCH=todo                text for the search field
///     DIRCOMPARE_EXPAND_DIFFERENCES=1       run Expand Differences after the recursive check
///
/// For example:
///
///     swift build && DIRCOMPARE_SNAPSHOT=/tmp/out.png .build/debug/DirCompare -left ~/a -right ~/b
enum DebugTools {
    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var expandsDifferences: Bool {
        environment["DIRCOMPARE_EXPAND_DIFFERENCES"] == "1"
    }

    private static var initiallyExpanded: Set<String> {
        guard let list = environment["DIRCOMPARE_EXPAND"] else { return [] }
        return Set(list.split(separator: ",").map { String($0).precomposedStringWithCanonicalMapping })
    }

    @MainActor
    static func apply(to model: CompareModel) {
        for id in initiallyExpanded {
            model.setExpanded(id, true)
        }
        if let filter = environment["DIRCOMPARE_FILTER"].flatMap(RowFilter.init(rawValue:)) {
            model.filter = filter
        }
        if let search = environment["DIRCOMPARE_SEARCH"] {
            model.searchText = search
        }
    }

    @MainActor
    static func scheduleSnapshotIfRequested() {
        guard let path = environment["DIRCOMPARE_SNAPSHOT"] else { return }
        let delay = Double(environment["DIRCOMPARE_SNAPSHOT_DELAY"] ?? "") ?? 3

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            defer { NSApp.terminate(nil) }
            // The window's frame view, so the title bar and toolbar are included.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 }),
                  let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                FileHandle.standardError.write(Data("snapshot: no window to capture\n".utf8))
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
#endif
