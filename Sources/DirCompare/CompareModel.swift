import AppKit
import DirCompareCore
import Observation

/// Which rows the table shows.
enum RowFilter: String, CaseIterable, Identifiable {
    case all
    case differences
    case onlyLeft
    case onlyRight
    case different
    case identical
    case folders

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .differences: "Differences"
        case .onlyLeft: "Only Left"
        case .onlyRight: "Only Right"
        case .different: "Different"
        case .identical: "Identical"
        case .folders: "Folders"
        }
    }

    func matches(_ row: ComparisonRow) -> Bool {
        switch self {
        case .all: true
        case .differences: row.isDifference
        case .onlyLeft: row.status == .onlyLeft
        case .onlyRight: row.status == .onlyRight
        case .different: row.status == .different || row.status == .kindMismatch
        case .identical: row.status == .identical
        case .folders: row.status == .folders
        }
    }
}

/// State for one comparison window.
@MainActor
@Observable
final class CompareModel {
    private(set) var leftURL: URL?
    private(set) var rightURL: URL?

    var includeHidden: Bool
    var compareContents: Bool
    var ignoreText: String

    private(set) var result: DirectoryComparison?
    private(set) var isComparing = false
    private(set) var progress: ComparisonProgress?
    private(set) var errorMessage: String?

    var filter: RowFilter = .all
    var searchText = ""
    var sortOrder = [KeyPathComparator(\ComparisonRow.name, comparator: .localizedStandard)]
    var selection = Set<ComparisonRow.ID>()

    /// Folder pairs to return to after opening subfolders side by side.
    private var history: [(left: URL, right: URL)] = []
    private var task: Task<Void, Never>?
    /// Identifies the latest comparison, so a cancelled one can't overwrite its state.
    private var generation = 0

    private let defaults = UserDefaults.standard

    init() {
        includeHidden = defaults.object(forKey: Keys.includeHidden) as? Bool ?? true
        compareContents = defaults.object(forKey: Keys.compareContents) as? Bool ?? true
        ignoreText = defaults.string(forKey: Keys.ignore) ?? ""

        // Folders passed at launch (`open DirCompare.app --args -left A -right B`) take priority.
        // They arrive as dash-prefixed arguments because AppKit treats bare paths as
        // files to open, and then SwiftUI doesn't open a window.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let launchFolder = { (key: String) in
            (arguments[key] as? String).flatMap { Self.isDirectory($0) ? URL(filePath: $0) : nil }
        }
        leftURL = launchFolder("left")
            ?? defaults.string(forKey: Keys.left).map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        rightURL = launchFolder("right")
            ?? defaults.string(forKey: Keys.right).map { URL(filePath: $0) }
    }

    // MARK: Folders

    var canCompare: Bool {
        leftURL != nil && rightURL != nil
    }

    var canGoBack: Bool {
        !history.isEmpty
    }

    func setFolder(_ url: URL, side: Side) {
        history.removeAll()
        switch side {
        case .left: leftURL = url
        case .right: rightURL = url
        }
        saveFolders()
        compare()
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        history = history.map { ($0.right, $0.left) }
        saveFolders()
        compare()
    }

    /// Opens a pair of subfolders side by side, remembering where we came from.
    func open(_ row: ComparisonRow) {
        guard row.bothAreFolders, let left = row.left?.url, let right = row.right?.url,
              let currentLeft = leftURL, let currentRight = rightURL else { return }
        history.append((currentLeft, currentRight))
        leftURL = left
        rightURL = right
        compare()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        leftURL = previous.left
        rightURL = previous.right
        compare()
    }

    // MARK: Comparing

    func compare() {
        guard let left = leftURL, let right = rightURL else { return }
        task?.cancel()
        generation += 1
        let current = generation

        let options = ComparisonOptions(
            includeHidden: includeHidden,
            compareContents: compareContents,
            ignorePatterns: ComparisonOptions.parsePatterns(ignoreText)
        )
        isComparing = true
        errorMessage = nil
        progress = nil

        // The task runs on the main actor; the comparison itself runs in the background.
        task = Task {
            let outcome: Result<DirectoryComparison, any Error>
            do {
                outcome = .success(try await DirectoryComparer(options: options).compareAsync(left, right) { update in
                    Task { @MainActor in
                        if self.generation == current {
                            self.progress = update
                        }
                    }
                })
            } catch {
                outcome = .failure(error)
            }

            // A newer comparison (or a cancel) owns the state now.
            guard generation == current else { return }
            switch outcome {
            case .success(let result):
                self.result = result
                selection.formIntersection(result.rows.map(\.id))
            case .failure(let error):
                result = nil
                errorMessage = error.localizedDescription
            }
            isComparing = false
            progress = nil
        }
    }

    func cancel() {
        task?.cancel()
        generation += 1
        isComparing = false
        progress = nil
    }

    /// Saves the options and compares again.
    func optionsChanged() {
        defaults.set(includeHidden, forKey: Keys.includeHidden)
        defaults.set(compareContents, forKey: Keys.compareContents)
        defaults.set(ignoreText, forKey: Keys.ignore)
        compare()
    }

    // MARK: Rows

    var visibleRows: [ComparisonRow] {
        guard let result else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return result.rows
            .filter { filter.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted(using: sortOrder)
    }

    func rows(for ids: Set<ComparisonRow.ID>) -> [ComparisonRow] {
        visibleRows.filter { ids.contains($0.id) }
    }

    /// Double-click: open folder pairs side by side, otherwise show the entries in Finder.
    func activate(_ ids: Set<ComparisonRow.ID>) {
        let rows = rows(for: ids)
        if rows.count == 1, let row = rows.first, row.bothAreFolders {
            open(row)
        } else {
            revealInFinder(rows.flatMap { [$0.left?.url, $0.right?.url].compactMap { $0 } })
        }
    }

    func copyMarkdown() {
        guard let result else { return }
        copyToPasteboard(MarkdownExport.render(rows: visibleRows, left: result.left, right: result.right))
    }

    // MARK: Persistence

    private enum Keys {
        static let left = "leftFolder"
        static let right = "rightFolder"
        static let includeHidden = "includeHidden"
        static let compareContents = "compareContents"
        static let ignore = "ignorePatterns"
    }

    private func saveFolders() {
        defaults.set(leftURL?.path(percentEncoded: false), forKey: Keys.left)
        defaults.set(rightURL?.path(percentEncoded: false), forKey: Keys.right)
    }

    private nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - System helpers

@MainActor
func revealInFinder(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Opens two files in FileMerge, which comes with Xcode.
enum FileMerge {
    static let isAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["--find", "opendiff"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()

    static func open(_ left: URL, _ right: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/opendiff")
        process.arguments = [left.path(percentEncoded: false), right.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
