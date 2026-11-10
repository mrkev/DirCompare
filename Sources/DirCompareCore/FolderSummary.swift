import Foundation

/// Counts from comparing two folders all the way down. Folders present on both
/// sides are descended into, not counted; everything else counts once, at the
/// level where it differs (a folder that exists on one side only counts as one item).
public struct FolderSummary: Sendable, Hashable {
    public var onlyLeft = 0
    public var onlyRight = 0
    /// Different files or symlinks, plus names that are a different kind on each side.
    public var different = 0
    /// Entries or subfolders that couldn't be read.
    public var unreadable = 0
    /// Same-size files that weren't compared (content checking off), or special files.
    public var unchecked = 0
    public var identical = 0

    public init() {}

    public var itemCount: Int {
        onlyLeft + onlyRight + different + unreadable + unchecked + identical
    }

    /// The status a folder row should show once its contents are known.
    public var status: ComparisonStatus {
        if onlyLeft + onlyRight + different > 0 {
            .different
        } else if unreadable > 0 {
            .unreadable
        } else {
            .identical
        }
    }

    public var description: String {
        var parts: [String] = []
        if onlyLeft > 0 { parts.append("\(onlyLeft) only left") }
        if onlyRight > 0 { parts.append("\(onlyRight) only right") }
        if different > 0 { parts.append("\(different) different") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        if parts.isEmpty {
            let matching = switch itemCount {
            case 0: "Both empty"
            case 1: "The 1 item matches"
            default: "All \(itemCount) items match"
            }
            parts.append(matching)
        }
        if unchecked > 0 { parts.append("\(unchecked) not checked") }
        return parts.joined(separator: ", ")
    }

    mutating func add(_ status: ComparisonStatus) {
        switch status {
        case .onlyLeft: onlyLeft += 1
        case .onlyRight: onlyRight += 1
        case .different, .kindMismatch: different += 1
        case .unreadable: unreadable += 1
        case .unchecked: unchecked += 1
        case .identical: identical += 1
        case .folders: break // Descended into instead.
        }
    }
}

public struct FolderProgress: Sendable, Hashable {
    /// Items compared so far.
    public var itemsCompared: Int
    /// Path of the item being compared, relative to the folders being checked.
    public var currentPath: String

    public init(itemsCompared: Int, currentPath: String) {
        self.itemsCompared = itemsCompared
        self.currentPath = currentPath
    }
}

/// What a recursive check of one folder row found, at every level.
public struct FolderCheckResult: Sendable {
    /// Counts for the whole folder pair.
    public var summary: FolderSummary
    /// The rows directly inside each folder that contains a difference, keyed by that
    /// folder's row ID (the checked row itself included, when it differs). Subfolder rows
    /// have their own summaries applied. Folders whose contents all match aren't kept, to
    /// save memory; their rows still carry a summary.
    public var levels: [ComparisonRow.ID: [ComparisonRow]]
}

extension ComparisonRow {
    /// Replaces a folder row's date-only status with the result of checking its contents.
    public mutating func apply(_ summary: FolderSummary) {
        folderSummary = summary
        status = summary.status
        note = summary.description
    }
}

extension FolderSummary {
    mutating func merge(_ other: FolderSummary) {
        onlyLeft += other.onlyLeft
        onlyRight += other.onlyRight
        different += other.different
        unreadable += other.unreadable
        unchecked += other.unchecked
        identical += other.identical
    }
}

extension DirectoryComparer {
    /// Compares two folders recursively, using the same options as the top-level comparison.
    /// Symlinks aren't followed, so cycles can't happen.
    ///
    /// - Parameters:
    ///   - progress: Called at most every `progressInterval`, and once at the end.
    public func summarizeFolders(
        _ left: URL,
        _ right: URL,
        progressInterval: Duration = .milliseconds(100),
        progress: (@Sendable (FolderProgress) -> Void)? = nil
    ) throws -> FolderSummary {
        var walker = FolderWalker(comparer: self, keepLevels: false, progress: progress, interval: progressInterval)
        let summary = try walker.walk(left, right, under: nil, path: "")
        walker.report(path: "", force: true)
        return summary
    }

    /// Compares two folders recursively, calling `visit` with each row as it's found, in
    /// path order. Folder pairs are descended into rather than visited, unless one couldn't
    /// be read; then it's visited as `unreadable`, with the reason as its note. An error
    /// thrown by `visit` stops the walk and is rethrown.
    ///
    /// Unlike `summarizeFolders`, throws if `left` or `right` itself can't be read.
    ///
    /// - Parameters:
    ///   - parent: The folder row `left` and `right` belong to, if they're a subfolder pair.
    ///     Row IDs and paths are prefixed with its own, as with `compare(_:_:under:)`.
    ///   - progress: Called at most every `progressInterval`, and once at the end.
    public func walk(
        _ left: URL,
        _ right: URL,
        under parent: ComparisonRow? = nil,
        progressInterval: Duration = .milliseconds(100),
        progress: (@Sendable (FolderProgress) -> Void)? = nil,
        visit: (ComparisonRow) throws -> Void
    ) throws -> FolderSummary {
        // The walker keeps the visitor only until it returns.
        try withoutActuallyEscaping(visit) { visit in
            var walker = FolderWalker(comparer: self, keepLevels: false, progress: progress, interval: progressInterval)
            walker.visit = visit
            let summary = try walker.walkContents(left, right, under: parent, path: "")
            walker.report(path: "", force: true)
            return summary
        }
    }

    /// Checks a folder row's contents recursively, keeping the rows of every folder that
    /// differs so they can be shown without reading the disk again. Row IDs and paths are
    /// relative to the top level, like those from `compare(_:_:under:)`.
    public func checkFolder(
        _ row: ComparisonRow,
        progressInterval: Duration = .milliseconds(100),
        progress: (@Sendable (FolderProgress) -> Void)? = nil
    ) throws -> FolderCheckResult {
        guard let left = row.left?.url, let right = row.right?.url else {
            return FolderCheckResult(summary: FolderSummary(), levels: [:])
        }
        var walker = FolderWalker(comparer: self, keepLevels: true, progress: progress, interval: progressInterval)
        let summary = try walker.walk(left, right, under: row, path: "")
        walker.report(path: "", force: true)
        return FolderCheckResult(summary: summary, levels: walker.levels)
    }

    /// Runs `checkFolder` on a background thread. Cancelling the calling task stops it.
    @concurrent
    public func checkFolderAsync(
        _ row: ComparisonRow,
        progress: (@Sendable (FolderProgress) -> Void)? = nil
    ) async throws -> FolderCheckResult {
        try checkFolder(row, progress: progress)
    }
}

private struct FolderWalker {
    let comparer: DirectoryComparer
    let keepLevels: Bool
    let progress: (@Sendable (FolderProgress) -> Void)?
    let interval: Duration

    var visit: ((ComparisonRow) throws -> Void)?
    var levels: [ComparisonRow.ID: [ComparisonRow]] = [:]
    var itemsCompared = 0
    var lastReport = ContinuousClock.now

    init(
        comparer: DirectoryComparer,
        keepLevels: Bool,
        progress: (@Sendable (FolderProgress) -> Void)?,
        interval: Duration
    ) {
        self.comparer = comparer
        self.keepLevels = keepLevels
        self.progress = progress
        self.interval = interval
    }

    /// Compares one folder pair and everything below it, returning its counts.
    /// A pair that can't be listed counts as one unreadable item.
    ///
    /// - Parameters:
    ///   - parent: The folder row for this pair, used to prefix child IDs and paths.
    ///   - path: This pair's path relative to the folders being checked, for progress.
    mutating func walk(_ left: URL, _ right: URL, under parent: ComparisonRow?, path: String) throws -> FolderSummary {
        do {
            return try walkContents(left, right, under: parent, path: path)
        } catch is ComparisonError {
            var summary = FolderSummary()
            summary.unreadable += 1
            return summary
        }
    }

    /// Like `walk`, but throws `ComparisonError` if this pair can't be listed.
    /// Subfolders that can't be listed are still counted, not thrown.
    mutating func walkContents(
        _ left: URL,
        _ right: URL,
        under parent: ComparisonRow?,
        path: String
    ) throws -> FolderSummary {
        var summary = FolderSummary()
        let leftNames = try comparer.listing(of: left)
        let rightNames = try comparer.listing(of: right)

        let keys = Set(leftNames.keys).union(rightNames.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var rows: [ComparisonRow] = []
        for key in keys {
            try Task.checkCancellation()
            let leftEntry = leftNames[key].map { EntryInfo.read(name: $0, in: left) }
            let rightEntry = rightNames[key].map { EntryInfo.read(name: $0, in: right) }
            var row = try comparer.compareEntries(id: key, left: leftEntry, right: rightEntry)
            let childPath = path.isEmpty ? row.name : "\(path)/\(row.name)"
            if let parent {
                row.id = "\(parent.id)/\(row.id)"
                row.path = "\(parent.path)/\(row.path)"
            }

            if row.status == .folders, let leftEntry, let rightEntry {
                do {
                    let child = try walkContents(leftEntry.url, rightEntry.url, under: row, path: childPath)
                    row.apply(child)
                    summary.merge(child)
                } catch let error as ComparisonError {
                    var child = FolderSummary()
                    child.unreadable = 1
                    row.apply(child)
                    row.note = error.localizedDescription
                    summary.merge(child)
                    try visit?(row)
                }
            } else {
                summary.add(row.status)
                itemsCompared += 1
                try visit?(row)
                report(path: childPath, force: false)
            }
            if keepLevels {
                rows.append(row)
            }
        }

        if keepLevels, let parent, summary.status != .identical {
            levels[parent.id] = rows
        }
        return summary
    }

    mutating func report(path: String, force: Bool) {
        guard let progress else { return }
        let now = ContinuousClock.now
        guard force || now - lastReport >= interval else { return }
        lastReport = now
        progress(FolderProgress(itemsCompared: itemsCompared, currentPath: path))
    }
}
