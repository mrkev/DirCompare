import Foundation

public enum Side: String, Sendable, Hashable {
    case left
    case right
}

/// The outcome of comparing one name across the two folders.
public enum ComparisonStatus: String, Sendable, Hashable, CaseIterable {
    case onlyLeft
    case onlyRight
    /// Files whose sizes or bytes differ, or symlinks pointing to different targets.
    case different
    /// The same name is a different kind of thing on each side, such as a file and a folder.
    case kindMismatch
    /// Attributes or contents could not be read on at least one side.
    case unreadable
    /// Same-size files with content checking turned off, or special files that aren't compared.
    case unchecked
    /// Both sides are folders. Only their dates are compared, since there's no recursion.
    case folders
    /// Files with identical bytes, or symlinks with the same target.
    case identical

    public var title: String {
        switch self {
        case .onlyLeft: "Only left"
        case .onlyRight: "Only right"
        case .different: "Different"
        case .kindMismatch: "Type differs"
        case .unreadable: "Unreadable"
        case .unchecked: "Not checked"
        case .folders: "Folders"
        case .identical: "Identical"
        }
    }

    /// Sort order for the status column: most actionable first.
    public var rank: Int {
        Self.allCases.firstIndex(of: self)!
    }
}

/// One name that exists in either or both folders.
public struct ComparisonRow: Sendable, Hashable, Identifiable {
    /// The Unicode-normalized name used to pair entries across folders.
    public var id: String
    public var name: String
    public var left: EntryInfo?
    public var right: EntryInfo?
    public var status: ComparisonStatus
    /// Which side was modified later, or `nil` when the dates match within tolerance
    /// or the entry exists on only one side.
    public var newer: Side?
    /// Extra detail, such as symlink targets or a read error.
    public var note: String?

    public init(
        id: String,
        name: String,
        left: EntryInfo?,
        right: EntryInfo?,
        status: ComparisonStatus,
        newer: Side? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.left = left
        self.right = right
        self.status = status
        self.newer = newer
        self.note = note
    }

    public var kind: EntryKind {
        (left ?? right)?.kind ?? .other
    }

    /// Whether the row is worth a look: anything except identical files
    /// and folders or unchecked files whose dates match.
    public var isDifference: Bool {
        switch status {
        case .identical: false
        case .folders, .unchecked: newer != nil
        default: true
        }
    }

    public var bothAreFolders: Bool {
        left?.kind == .directory && right?.kind == .directory
    }

    public var bothAreFiles: Bool {
        left?.kind == .file && right?.kind == .file
    }
}

// Comparable keys for table sorting. Missing values sort first.
extension ComparisonRow {
    public var statusRank: Int { status.rank }
    public var leftSizeKey: Int64 { left?.displaySize ?? -1 }
    public var rightSizeKey: Int64 { right?.displaySize ?? -1 }
    public var leftDateKey: Date { left?.modified ?? .distantPast }
    public var rightDateKey: Date { right?.modified ?? .distantPast }
    public var newerRank: Int {
        switch newer {
        case .left?: 0
        case .right?: 1
        case nil: 2
        }
    }
}

public struct ComparisonOptions: Sendable, Hashable {
    /// Include names that start with a dot.
    public var includeHidden: Bool
    /// Compare same-size files byte by byte. When off, they're reported as `unchecked`.
    public var compareContents: Bool
    /// Glob patterns (as in `fnmatch`) for names to leave out, such as `.DS_Store` or `*.swp`.
    public var ignorePatterns: [String]
    /// Modification dates closer than this count as equal. Two seconds covers
    /// FAT/exFAT volumes, which store times at 2-second resolution.
    public var dateTolerance: TimeInterval

    public init(
        includeHidden: Bool = true,
        compareContents: Bool = true,
        ignorePatterns: [String] = [],
        dateTolerance: TimeInterval = 2
    ) {
        self.includeHidden = includeHidden
        self.compareContents = compareContents
        self.ignorePatterns = ignorePatterns
        self.dateTolerance = dateTolerance
    }

    /// Parses a comma- or newline-separated list of patterns.
    public static func parsePatterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func includes(name: String) -> Bool {
        if !includeHidden && name.hasPrefix(".") {
            return false
        }
        return !ignorePatterns.contains { fnmatch($0, name, 0) == 0 }
    }
}

public struct ComparisonProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int
    public var currentName: String?

    public init(completed: Int, total: Int, currentName: String?) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

public struct DirectoryComparison: Sendable {
    public var left: URL
    public var right: URL
    public var options: ComparisonOptions
    public var rows: [ComparisonRow]
    public var date: Date

    public init(left: URL, right: URL, options: ComparisonOptions, rows: [ComparisonRow], date: Date = .now) {
        self.left = left
        self.right = right
        self.options = options
        self.rows = rows
        self.date = date
    }

    public func count(_ status: ComparisonStatus) -> Int {
        rows.count { $0.status == status }
    }

    public var differenceCount: Int {
        rows.count(where: \.isDifference)
    }
}

public enum ComparisonError: LocalizedError, Equatable {
    case notADirectory(URL)
    case unreadableDirectory(URL, String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            "“\(url.path(percentEncoded: false))” isn’t a folder, or doesn’t exist."
        case .unreadableDirectory(let url, let reason):
            "Couldn’t read “\(url.path(percentEncoded: false))”: \(reason)"
        }
    }
}
