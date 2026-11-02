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
        // Folders on both sides, whether or not their contents have been checked.
        case .folders: row.bothAreFolders
        }
    }
}

/// State for one comparison window.
///
/// The table is a tree. The top level comes from `result`; folders present on both
/// sides can be expanded, which compares that pair one level deep (lazily, the first
/// time) and stores the rows in `childRows`.
@MainActor
@Observable
final class CompareModel {
    private(set) var leftURL: URL?
    private(set) var rightURL: URL?

    var includeHidden: Bool
    var compareContents: Bool
    /// After the top-level comparison, check folders on both sides all the way down.
    var checkFoldersRecursively: Bool
    var ignoreText: String

    private(set) var result: DirectoryComparison?
    private(set) var isComparing = false
    private(set) var progress: ComparisonProgress?
    private(set) var errorMessage: String?
    /// Progress of the recursive folder checks, or `nil` when none are running.
    private(set) var folderCheck: FolderCheck?

    /// Rows inside expanded folders, keyed by the folder row's ID. Kept when a folder
    /// is collapsed, so expanding it again is instant.
    private(set) var childRows: [ComparisonRow.ID: [ComparisonRow]] = [:]
    /// Folder rows whose contents are being compared.
    private(set) var loadingFolders: Set<ComparisonRow.ID> = []
    /// Folder rows whose contents couldn't be compared, with the reason.
    private(set) var folderErrors: [ComparisonRow.ID: String] = [:]
    /// Expanded folder rows. Survives refreshes, so the tree stays open after ⌘R.
    private(set) var expanded: Set<ComparisonRow.ID> = []

    struct FolderCheck {
        /// Folder rows not yet checked, including the current one.
        var pending: Set<ComparisonRow.ID>
        var current: ComparisonRow.ID?
        var currentName = ""
        var completed = 0
        let total: Int
        /// Progress within the current folder pair.
        var progress: FolderProgress?
    }

    /// Whether anything is running that Stop would cancel.
    var isBusy: Bool {
        isComparing || folderCheck != nil || !loadingFolders.isEmpty
    }

    var filter: RowFilter = .all
    var searchText = ""
    var sortOrder = [KeyPathComparator(\ComparisonRow.name, comparator: .localizedStandard)]
    var selection = Set<ComparisonRow.ID>()

    /// Folder pairs to return to after opening subfolders side by side.
    private var history: [(left: URL, right: URL)] = []
    private var task: Task<Void, Never>?
    private var childTasks: [ComparisonRow.ID: Task<Void, Never>] = [:]
    /// Identifies the latest comparison, so a cancelled one can't overwrite its state.
    private var generation = 0
    /// The options of the latest comparison. Expanded folders use the same ones.
    private var activeOptions = ComparisonOptions()

    private let defaults = UserDefaults.standard

    init() {
        includeHidden = defaults.object(forKey: Keys.includeHidden) as? Bool ?? true
        compareContents = defaults.object(forKey: Keys.compareContents) as? Bool ?? true
        checkFoldersRecursively = defaults.bool(forKey: Keys.checkFoldersRecursively)
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

        #if DEBUG
        DebugTools.apply(to: self)
        #endif
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
        expanded.removeAll()
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

    /// Makes a pair of subfolders the folders being compared, remembering where we came from.
    func open(_ row: ComparisonRow) {
        guard row.bothAreFolders, let left = row.left?.url, let right = row.right?.url,
              let currentLeft = leftURL, let currentRight = rightURL else { return }
        history.append((currentLeft, currentRight))
        leftURL = left
        rightURL = right
        expanded.removeAll()
        compare()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        leftURL = previous.left
        rightURL = previous.right
        expanded.removeAll()
        compare()
    }

    // MARK: Comparing

    func compare() {
        guard let left = leftURL, let right = rightURL else { return }
        cancelTasks()
        generation += 1
        let current = generation

        let options = ComparisonOptions(
            includeHidden: includeHidden,
            compareContents: compareContents,
            ignorePatterns: ComparisonOptions.parsePatterns(ignoreText)
        )
        activeOptions = options
        isComparing = true
        errorMessage = nil
        progress = nil
        folderCheck = nil
        childRows.removeAll()
        loadingFolders.removeAll()
        folderErrors.removeAll()
        let checkFolders = checkFoldersRecursively

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
            case .failure(let error):
                result = nil
                errorMessage = error.localizedDescription
            }
            isComparing = false
            progress = nil
            guard case .success = outcome else { return }

            await reloadExpandedFolders(generation: current)
            guard generation == current else { return }
            selection = selection.filter { row(withID: $0) != nil }

            if checkFolders {
                await checkFoldersRecursively(options: options, generation: current)
                #if DEBUG
                if generation == current, DebugTools.expandsDifferences {
                    expandDifferences()
                }
                #endif
            }
        }
    }

    /// Checks each top-level folder pair, one at a time. The top-level results are already
    /// showing, so this fills in folder statuses and adds the rows of every folder that
    /// differs to the tree, so expanding those is instant and filters can see inside them.
    private func checkFoldersRecursively(options: ComparisonOptions, generation current: Int) async {
        guard let folders = result?.rows.filter(\.bothAreFolders), !folders.isEmpty else { return }
        folderCheck = FolderCheck(pending: Set(folders.map(\.id)), total: folders.count)
        let comparer = DirectoryComparer(options: options)

        for row in folders {
            guard generation == current else { return }
            folderCheck?.current = row.id
            folderCheck?.currentName = row.name
            folderCheck?.progress = nil

            let checked: FolderCheckResult
            do {
                checked = try await comparer.checkFolderAsync(row) { update in
                    Task { @MainActor in
                        if self.generation == current, self.folderCheck?.current == row.id {
                            self.folderCheck?.progress = update
                        }
                    }
                }
            } catch {
                // Only cancellation can get here: unreadable folders are counted, not thrown.
                return
            }

            guard generation == current else { return }
            if let index = result?.rows.firstIndex(where: { $0.id == row.id }) {
                result?.rows[index].apply(checked.summary)
            }
            // The check's rows replace any loaded by expanding, since they carry folder statuses.
            childRows.merge(checked.levels) { _, checkedRows in checkedRows }
            markMatchingFolders()
            folderCheck?.pending.remove(row.id)
            folderCheck?.completed += 1
        }
        folderCheck = nil
    }

    /// Inside a folder known to match, every subfolder matches too. Loading a folder by
    /// expanding it only compares dates for its subfolders, so mark them as matching.
    private func markMatchingFolders() {
        // Parents first, so a newly marked folder's own loaded contents get marked too.
        for parentID in childRows.keys.sorted(by: { $0.depth < $1.depth }) {
            guard row(withID: parentID)?.status == .identical else { continue }
            markSubfoldersIdentical(in: parentID)
        }
    }

    private func markSubfoldersIdentical(in parentID: ComparisonRow.ID) {
        guard var rows = childRows[parentID] else { return }
        for index in rows.indices where rows[index].status == .folders {
            rows[index].status = .identical
            rows[index].note = nil
        }
        childRows[parentID] = rows
    }

    func cancel() {
        cancelTasks()
        generation += 1
        isComparing = false
        progress = nil
        folderCheck = nil
        loadingFolders.removeAll()
    }

    private func cancelTasks() {
        task?.cancel()
        for childTask in childTasks.values {
            childTask.cancel()
        }
        childTasks.removeAll()
    }

    /// Saves the options and compares again.
    func optionsChanged() {
        defaults.set(includeHidden, forKey: Keys.includeHidden)
        defaults.set(compareContents, forKey: Keys.compareContents)
        defaults.set(checkFoldersRecursively, forKey: Keys.checkFoldersRecursively)
        defaults.set(ignoreText, forKey: Keys.ignore)
        compare()
    }

    // MARK: Expanding folders

    func isExpanded(_ id: ComparisonRow.ID) -> Bool {
        expanded.contains(id)
    }

    /// Expands or collapses a folder row, comparing its contents the first time it's expanded.
    func setExpanded(_ id: ComparisonRow.ID, _ isExpanded: Bool) {
        guard isExpanded else {
            expanded.remove(id)
            return
        }
        expanded.insert(id)
        guard childRows[id] == nil, !loadingFolders.contains(id), let row = row(withID: id) else { return }
        childTasks[id] = Task {
            await loadChildren(of: row)
            childTasks[id] = nil
        }
    }

    func toggleExpanded(_ id: ComparisonRow.ID) {
        setExpanded(id, !isExpanded(id))
    }

    /// Whether the recursive check has found differences inside any folder yet.
    var canExpandDifferences: Bool {
        result?.rows.contains(where: \.hasDifferencesInside) ?? false
    }

    /// Expands every checked folder that has differences inside, all the way down,
    /// so each difference is showing.
    func expandDifferences() {
        func expand(in parentID: ComparisonRow.ID) {
            for row in rows(in: parentID) ?? [] where row.hasDifferencesInside && childRows[row.id] != nil {
                expanded.insert(row.id)
                expand(in: row.id)
            }
        }
        expand(in: "")
    }

    func collapseAll() {
        expanded.removeAll()
    }

    private func loadChildren(of row: ComparisonRow) async {
        guard let left = row.left?.url, let right = row.right?.url else { return }
        let current = generation
        loadingFolders.insert(row.id)
        folderErrors[row.id] = nil

        do {
            let level = try await DirectoryComparer(options: activeOptions).compareAsync(left, right, under: row)
            guard generation == current else { return }
            childRows[row.id] = level.rows
            if row.status == .identical {
                markSubfoldersIdentical(in: row.id)
            }
        } catch is CancellationError {
            // Cancelled by a new comparison or Stop, which reset the loading state.
            return
        } catch {
            guard generation == current else { return }
            folderErrors[row.id] = error.localizedDescription
        }
        loadingFolders.remove(row.id)
    }

    /// After a refresh, compares the expanded folders again, parents before children.
    private func reloadExpandedFolders(generation current: Int) async {
        for id in expanded.sorted(by: { $0.depth < $1.depth }) {
            guard generation == current else { return }
            if let row = row(withID: id), row.bothAreFolders {
                await loadChildren(of: row)
            } else {
                // Gone, no longer a folder pair, or inside a collapsed folder.
                expanded.remove(id)
            }
        }
    }

    // MARK: Rows

    /// The loaded rows inside a folder row, or the top-level rows for `""`.
    func rows(in parentID: ComparisonRow.ID) -> [ComparisonRow]? {
        parentID.isEmpty ? result?.rows : childRows[parentID]
    }

    func row(withID id: ComparisonRow.ID) -> ComparisonRow? {
        rows(in: id.parentID)?.first { $0.id == id }
    }

    /// The rows to show inside a folder (or at the top level), filtered and sorted.
    /// A folder that doesn't match is kept if anything loaded inside it does, so the
    /// match stays reachable.
    func visibleChildren(of parentID: ComparisonRow.ID) -> [ComparisonRow] {
        guard let rows = rows(in: parentID) else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard filter != .all || !query.isEmpty else {
            return rows.sorted(using: sortOrder)
        }
        return rows.filter { isVisible($0, query: query) }.sorted(using: sortOrder)
    }

    private func isVisible(_ row: ComparisonRow, query: String) -> Bool {
        if filter.matches(row) && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query)) {
            return true
        }
        return childRows[row.id]?.contains { isVisible($0, query: query) } ?? false
    }

    /// Every row currently showing, in display order (expanded folders' contents included).
    var visibleRows: [ComparisonRow] {
        var rows: [ComparisonRow] = []
        func append(_ parentID: ComparisonRow.ID) {
            for row in visibleChildren(of: parentID) {
                rows.append(row)
                if expanded.contains(row.id) {
                    append(row.id)
                }
            }
        }
        append("")
        return rows
    }

    func rows(for ids: Set<ComparisonRow.ID>) -> [ComparisonRow] {
        visibleRows.filter { ids.contains($0.id) }
    }

    /// Double-click: expand or collapse folder pairs, otherwise show the entries in Finder.
    func activate(_ ids: Set<ComparisonRow.ID>) {
        let rows = rows(for: ids)
        if rows.count == 1, let row = rows.first, row.bothAreFolders {
            toggleExpanded(row.id)
        } else {
            revealInFinder(rows.flatMap { [$0.left?.url, $0.right?.url].compactMap { $0 } })
        }
    }

    // MARK: Quick Look

    /// The item showing in the Quick Look panel, or `nil` when it's closed.
    var quickLookURL: URL?
    /// Everything the panel can page through with the arrow keys.
    private(set) var quickLookItems: [URL] = []

    /// Previews the rows' files, left copy then right copy, so the arrow keys flip between versions.
    func quickLook(_ ids: Set<ComparisonRow.ID>) {
        let urls = rows(for: ids).flatMap { [$0.left?.url, $0.right?.url].compactMap { $0 } }
        quickLookItems = urls
        quickLookURL = urls.first
    }

    /// Space bar: opens Quick Look for the selection, or closes it if it's open.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLook(selection)
        }
    }

    /// Keeps an open panel in sync as the selection changes, like Finder.
    func selectionChanged() {
        if quickLookURL != nil {
            quickLook(selection)
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
        static let checkFoldersRecursively = "checkFoldersRecursively"
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

private extension ComparisonRow {
    /// A folder pair the recursive check found differences inside.
    var hasDifferencesInside: Bool {
        bothAreFolders && folderSummary.map { $0.status != .identical } == true
    }
}

private extension ComparisonRow.ID {
    /// The ID of the folder row containing this one, or `""` at the top level.
    var parentID: String {
        guard let slash = lastIndex(of: "/") else { return "" }
        return String(self[..<slash])
    }

    var depth: Int {
        count { $0 == "/" }
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
