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

extension ComparisonRow {
    /// Replaces a folder row's date-only status with the result of checking its contents.
    public mutating func apply(_ summary: FolderSummary) {
        folderSummary = summary
        status = summary.status
        note = summary.description
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
        var walker = FolderWalker(comparer: self, progress: progress, interval: progressInterval)
        try walker.walk(left, right, path: "")
        walker.report(path: "", force: true)
        return walker.summary
    }

    /// Runs `summarizeFolders` on a background thread. Cancelling the calling task stops it.
    @concurrent
    public func summarizeFoldersAsync(
        _ left: URL,
        _ right: URL,
        progress: (@Sendable (FolderProgress) -> Void)? = nil
    ) async throws -> FolderSummary {
        try summarizeFolders(left, right, progress: progress)
    }
}

private struct FolderWalker {
    let comparer: DirectoryComparer
    let progress: (@Sendable (FolderProgress) -> Void)?
    let interval: Duration

    var summary = FolderSummary()
    var lastReport = ContinuousClock.now

    init(comparer: DirectoryComparer, progress: (@Sendable (FolderProgress) -> Void)?, interval: Duration) {
        self.comparer = comparer
        self.progress = progress
        self.interval = interval
    }

    mutating func walk(_ left: URL, _ right: URL, path: String) throws {
        let leftNames: [String: String]
        let rightNames: [String: String]
        do {
            leftNames = try comparer.listing(of: left)
            rightNames = try comparer.listing(of: right)
        } catch is ComparisonError {
            summary.unreadable += 1
            return
        }

        for key in Set(leftNames.keys).union(rightNames.keys) {
            try Task.checkCancellation()
            let leftEntry = leftNames[key].map { EntryInfo.read(name: $0, in: left) }
            let rightEntry = rightNames[key].map { EntryInfo.read(name: $0, in: right) }
            let row = try comparer.compareEntries(id: key, left: leftEntry, right: rightEntry)
            let childPath = path.isEmpty ? row.name : "\(path)/\(row.name)"

            if row.status == .folders, let leftEntry, let rightEntry {
                try walk(leftEntry.url, rightEntry.url, path: childPath)
            } else {
                summary.add(row.status)
                report(path: childPath, force: false)
            }
        }
    }

    mutating func report(path: String, force: Bool) {
        guard let progress else { return }
        let now = ContinuousClock.now
        guard force || now - lastReport >= interval else { return }
        lastReport = now
        progress(FolderProgress(itemsCompared: summary.itemCount, currentPath: path))
    }
}
