import Foundation

extension ComparisonStatus {
    /// A short, stable name for command-line and JSON output, such as `only-left`.
    public var token: String {
        switch self {
        case .onlyLeft: "only-left"
        case .onlyRight: "only-right"
        case .different: "different"
        case .kindMismatch: "type-differs"
        case .unreadable: "unreadable"
        case .unchecked: "not-checked"
        case .folders: "folders"
        case .identical: "identical"
        }
    }
}

/// How far a report looks into the folders.
public enum ReportScope: String, Sendable, CaseIterable {
    /// Every item at every depth. Folder pairs are descended into, not listed.
    case recursive
    /// Only the items directly inside the folders. Folder pairs are always listed, since
    /// they haven't been compared, so they can be looked inside with `under`.
    case shallow
    /// The items directly inside the folders, with each folder pair checked all the way
    /// down and listed with its counts.
    case summary
}

public enum ReportFormat: String, Sendable, CaseIterable {
    case text
    /// One JSON object per line: a `row` record per item, then a `summary` record.
    case json
    case markdown
}

/// A comparison written out a line at a time, for the `dircmp` command-line tool.
///
/// Rows are written as they're found, so output that's cut short is still usable.
/// Only the first `limit` rows are listed; the rest are counted, and the last lines
/// say how many were left out.
public struct CommandLineReport {
    /// Bumped whenever the JSON output changes incompatibly.
    public static let schemaVersion = 1

    public var left: URL
    public var right: URL
    /// A subfolder path, present on both sides, to compare instead of the whole folders.
    /// Output paths stay relative to `left` and `right`.
    public var under: String?
    public var scope: ReportScope = .recursive
    public var format: ReportFormat = .text
    /// List identical items too, not only differences.
    public var showAll = false
    /// The most rows to list. `nil` lists them all.
    public var limit: Int? = 200
    /// Stop at the first item that differs, for when only the exit code matters.
    public var stopAtFirstDifference = false
    /// For dates in Markdown output. Text and JSON use UTC.
    public var timeZone: TimeZone = .current

    public init(left: URL, right: URL) {
        self.left = left
        self.right = right
    }

    public struct Outcome: Sendable, Hashable {
        public var summary: FolderSummary
        /// Folder pairs not looked inside, in the shallow scope.
        public var foldersNotCompared: Int
        public var listed: Int
        /// Rows that would have been listed but for the limit.
        public var omitted: Int
        /// Whether `stopAtFirstDifference` cut the comparison short, leaving the counts partial.
        public var stoppedEarly = false

        /// Like `diff`: 0 when nothing differs, 1 when something does, and 2 when
        /// something couldn't be read, so the answer may be incomplete.
        public var exitCode: Int32 {
            if summary.unreadable > 0 {
                2
            } else if summary.onlyLeft + summary.onlyRight + summary.different > 0 {
                1
            } else {
                0
            }
        }
    }

    /// Compares the folders, passing each line of output to `write`.
    ///
    /// Throws if either folder (or the `under` subfolder) can't be read.
    public func run(
        comparer: DirectoryComparer,
        progress: (@Sendable (FolderProgress) -> Void)? = nil,
        write: (String) -> Void
    ) throws -> Outcome {
        let (leftBase, rightBase, parent) = try base()
        var outcome = Outcome(summary: FolderSummary(), foldersNotCompared: 0, listed: 0, omitted: 0)
        var wroteMarkdownHeader = false

        // Written with the first row rather than up front, so a folder that can't be
        // read doesn't leave a table header behind.
        func writeMarkdownHeader() {
            guard format == .markdown, !wroteMarkdownHeader else { return }
            wroteMarkdownHeader = true
            MarkdownExport.header(left: left, right: right).forEach(write)
        }

        /// Lists `row` if it should be, then throws `StopComparing` if it's where to stop.
        func emit(_ row: ComparisonRow) throws {
            let unexplored = scope == .shallow && row.status == .folders
            if showAll || unexplored || row.isDifference {
                if let limit, outcome.listed >= limit {
                    outcome.omitted += 1
                } else {
                    outcome.listed += 1
                    switch format {
                    case .text: write(textLine(row))
                    case .json: write(jsonLine(row))
                    case .markdown:
                        writeMarkdownHeader()
                        write(MarkdownExport.line(for: row, timeZone: timeZone))
                    }
                }
            }
            if stopAtFirstDifference && Self.differs(row.status) {
                throw StopComparing()
            }
        }

        switch scope {
        case .recursive:
            // The walk only returns its counts if it finishes, so keep a tally for stopping early.
            var counted = FolderSummary()
            do {
                outcome.summary = try comparer.walk(leftBase, rightBase, under: parent, progress: progress) { row in
                    counted.add(row.status)
                    try emit(row)
                }
            } catch is StopComparing {
                outcome.summary = counted
                outcome.stoppedEarly = true
            }

        case .shallow, .summary:
            let comparison = try comparer.compare(leftBase, rightBase, under: parent)
            rows: for var row in comparison.rows {
                if row.status == .folders, let left = row.left?.url, let right = row.right?.url {
                    if scope == .shallow {
                        outcome.foldersNotCompared += 1
                    } else {
                        let prefix = row.path
                        let child = try comparer.summarizeFolders(left, right) { update in
                            var update = update
                            update.currentPath = update.currentPath.isEmpty
                                ? prefix : "\(prefix)/\(update.currentPath)"
                            progress?(update)
                        }
                        row.apply(child)
                        outcome.summary.merge(child)
                    }
                } else {
                    outcome.summary.add(row.status)
                }
                do {
                    try emit(row)
                } catch is StopComparing {
                    outcome.stoppedEarly = true
                    break rows
                }
            }
        }

        writeMarkdownHeader()
        for line in trailer(outcome) {
            write(line)
        }
        return outcome
    }

    private struct StopComparing: Error {}

    /// Whether a row's status makes the folders differ, as opposed to being unknown
    /// (`unreadable`, `not-checked`) or matching.
    static func differs(_ status: ComparisonStatus) -> Bool {
        switch status {
        case .onlyLeft, .onlyRight, .different, .kindMismatch: true
        case .unreadable, .unchecked, .folders, .identical: false
        }
    }

    /// The folders to compare, and the row to prefix paths with when comparing a subfolder.
    func base() throws -> (URL, URL, ComparisonRow?) {
        let path = (under ?? "").split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        guard !path.isEmpty else { return (left, right, nil) }
        let leftBase = left.appending(path: path, directoryHint: .isDirectory)
        let rightBase = right.appending(path: path, directoryHint: .isDirectory)
        let parent = ComparisonRow(
            id: path.precomposedStringWithCanonicalMapping,
            name: (path as NSString).lastPathComponent,
            path: path,
            left: nil,
            right: nil,
            status: .folders
        )
        return (leftBase, rightBase, parent)
    }

    // MARK: Text

    /// `different    src/main.swift  (1,204 → 1,310 bytes; right newer)`
    func textLine(_ row: ComparisonRow) -> String {
        let status = row.status.token.padding(toLength: 12, withPad: " ", startingAt: 0)
        let path = row.kind == .directory ? row.path + "/" : row.path
        var details: [String] = []
        switch (row.left?.displaySize, row.right?.displaySize) {
        case let (left?, right?) where left != right:
            details.append("\(Formatting.bytes(left)) → \(Formatting.bytes(right)) bytes")
        case let (size?, _), let (_, size?):
            details.append("\(Formatting.bytes(size)) byte\(size == 1 ? "" : "s")")
        case (nil, nil):
            break
        }
        if let newer = row.newer {
            details.append("\(newer.rawValue) newer")
        }
        if let note = row.note {
            details.append(note)
        }
        if details.isEmpty {
            return "\(status) \(path)"
        }
        return "\(status) \(path)  (\(details.joined(separator: "; ")))"
    }

    func trailer(_ outcome: Outcome) -> [String] {
        switch format {
        case .json:
            return [jsonSummary(outcome)]
        case .text, .markdown:
            var lines: [String] = []
            if format == .markdown {
                lines.append("")
            }
            if outcome.omitted > 0 {
                lines.append("… \(Formatting.bytes(Int64(outcome.omitted))) more not listed. "
                    + "Narrow with --under PATH, or raise --limit (0 lists everything).")
            }
            lines.append("Summary: \(summaryText(outcome))")
            return lines
        }
    }

    func summaryText(_ outcome: Outcome) -> String {
        if outcome.stoppedEarly {
            return "stopped at the first difference (--first)"
        }
        let folders = outcome.foldersNotCompared
        guard folders > 0 else { return outcome.summary.description }
        let notCompared = "\(folders) folder\(folders == 1 ? "" : "s") not compared; look inside with --under PATH"
        if outcome.summary.itemCount == 0 {
            return notCompared
        }
        return "\(outcome.summary.description), \(notCompared)"
    }

    // MARK: JSON

    struct RowRecord: Encodable {
        let type = "row"
        var path: String
        var status: String
        var kind: String
        var newer: String?
        var note: String?
        var left: SideRecord?
        var right: SideRecord?
        /// Counts for a folder pair checked all the way down.
        var counts: CountsRecord?
    }

    struct SideRecord: Encodable {
        /// The absolute path on this side.
        var path: String
        var kind: String
        /// Omitted for folders, whose sizes aren't meaningful.
        var size: Int64?
        var modified: String?
        var symlinkTarget: String?
        var error: String?
    }

    struct CountsRecord: Encodable {
        var onlyLeft: Int
        var onlyRight: Int
        var different: Int
        var unreadable: Int
        var notChecked: Int
        var identical: Int

        init(_ summary: FolderSummary) {
            onlyLeft = summary.onlyLeft
            onlyRight = summary.onlyRight
            different = summary.different
            unreadable = summary.unreadable
            notChecked = summary.unchecked
            identical = summary.identical
        }
    }

    struct SummaryRecord: Encodable {
        let type = "summary"
        let schema = CommandLineReport.schemaVersion
        var left: String
        var right: String
        var under: String?
        var scope: String
        var counts: CountsRecord
        var foldersNotCompared: Int
        var description: String
        var listed: Int
        var omitted: Int
        /// True when `--first` stopped the comparison, so the counts are partial.
        var stoppedEarly: Bool
        var exitCode: Int32
    }

    func jsonLine(_ row: ComparisonRow) -> String {
        encode(RowRecord(
            path: row.path,
            status: row.status.token,
            kind: row.kind.rawValue,
            newer: row.newer?.rawValue,
            note: row.note,
            left: row.left.map(sideRecord),
            right: row.right.map(sideRecord),
            counts: row.folderSummary.map(CountsRecord.init)
        ))
    }

    func sideRecord(_ entry: EntryInfo) -> SideRecord {
        SideRecord(
            path: absolutePath(entry.url),
            kind: entry.kind.rawValue,
            size: entry.displaySize,
            modified: entry.modified?.formatted(.iso8601),
            symlinkTarget: entry.symlinkDestination,
            error: entry.readError
        )
    }

    func jsonSummary(_ outcome: Outcome) -> String {
        encode(SummaryRecord(
            left: absolutePath(left),
            right: absolutePath(right),
            under: (try? base().2)?.path,
            scope: scope.rawValue,
            counts: CountsRecord(outcome.summary),
            foldersNotCompared: outcome.foldersNotCompared,
            description: summaryText(outcome),
            listed: outcome.listed,
            omitted: outcome.omitted,
            stoppedEarly: outcome.stoppedEarly,
            exitCode: outcome.exitCode
        ))
    }

    /// The path without the trailing slash folder URLs have.
    func absolutePath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain records can't fail.
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
