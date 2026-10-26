import Foundation

/// Compares the entries directly inside two folders, without recursing.
public struct DirectoryComparer: Sendable {
    public var options: ComparisonOptions

    public init(options: ComparisonOptions = ComparisonOptions()) {
        self.options = options
    }

    /// Compares two folders on a background thread. Cancelling the calling task
    /// stops the comparison, including partway through reading a large file.
    @concurrent
    public func compareAsync(
        _ left: URL,
        _ right: URL,
        progress: (@Sendable (ComparisonProgress) -> Void)? = nil
    ) async throws -> DirectoryComparison {
        try compare(left, right, progress: progress)
    }

    /// Compares two folders synchronously. Throws `CancellationError` if the current task is cancelled.
    public func compare(
        _ left: URL,
        _ right: URL,
        progress: (@Sendable (ComparisonProgress) -> Void)? = nil
    ) throws -> DirectoryComparison {
        let leftNames = try listing(of: left)
        let rightNames = try listing(of: right)
        let keys = Set(leftNames.keys).union(rightNames.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var rows: [ComparisonRow] = []
        rows.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
            try Task.checkCancellation()
            let leftEntry = leftNames[key].map { EntryInfo.read(name: $0, in: left) }
            let rightEntry = rightNames[key].map { EntryInfo.read(name: $0, in: right) }
            progress?(ComparisonProgress(
                completed: index,
                total: keys.count,
                currentName: leftEntry?.name ?? rightEntry?.name
            ))
            rows.append(try compareEntries(id: key, left: leftEntry, right: rightEntry))
        }
        progress?(ComparisonProgress(completed: keys.count, total: keys.count, currentName: nil))

        return DirectoryComparison(left: left, right: right, options: options, rows: rows)
    }

    /// Maps each normalized name to its name on disk. Normalizing makes names written
    /// in different Unicode forms (common across SMB or exFAT) pair up.
    func listing(of directory: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        let path = directory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ComparisonError.notADirectory(directory)
        }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            throw ComparisonError.unreadableDirectory(directory, error.localizedDescription)
        }

        var result: [String: String] = [:]
        for name in names where options.includes(name: name) {
            result[name.precomposedStringWithCanonicalMapping] = name
        }
        return result
    }

    func compareEntries(id: String, left: EntryInfo?, right: EntryInfo?) throws -> ComparisonRow {
        guard let left, let right else {
            let entry = left ?? right!
            return ComparisonRow(id: id, name: entry.name, left: left, right: right,
                                 status: left == nil ? .onlyRight : .onlyLeft,
                                 note: entry.readError)
        }

        var row = ComparisonRow(id: id, name: left.name, left: left, right: right, status: .identical,
                                newer: newerSide(left.modified, right.modified))

        if let error = left.readError ?? right.readError {
            row.status = .unreadable
            row.note = error
            return row
        }

        if left.kind != right.kind {
            row.status = .kindMismatch
            row.note = "\(left.kind.title) on the left, \(right.kind.title.lowercased()) on the right"
            return row
        }

        switch left.kind {
        case .directory:
            row.status = .folders

        case .symlink:
            let leftTarget = left.symlinkDestination ?? "?"
            let rightTarget = right.symlinkDestination ?? "?"
            row.status = leftTarget == rightTarget ? .identical : .different
            row.note = leftTarget == rightTarget
                ? "→ \(leftTarget)"
                : "→ \(leftTarget) on the left, → \(rightTarget) on the right"

        case .file:
            if left.size != right.size {
                row.status = .different
            } else if !options.compareContents {
                row.status = .unchecked
                row.note = "Same size; contents not compared"
            } else {
                do {
                    row.status = try Self.contentsEqual(left.url, right.url) ? .identical : .different
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    row.status = .unreadable
                    row.note = error.localizedDescription
                }
            }

        case .other:
            row.status = .unchecked
            row.note = "Special file; not compared"
        }
        return row
    }

    func newerSide(_ left: Date?, _ right: Date?) -> Side? {
        guard let left, let right else { return nil }
        let difference = left.timeIntervalSince(right)
        if abs(difference) <= options.dateTolerance {
            return nil
        }
        return difference > 0 ? .left : .right
    }

    /// Compares two files byte by byte, in chunks, checking for cancellation between chunks.
    public static func contentsEqual(_ a: URL, _ b: URL, chunkSize: Int = 1 << 20) throws -> Bool {
        let handleA = try FileHandle(forReadingFrom: a)
        defer { try? handleA.close() }
        let handleB = try FileHandle(forReadingFrom: b)
        defer { try? handleB.close() }

        while true {
            try Task.checkCancellation()
            let chunkA = try handleA.read(upToCount: chunkSize) ?? Data()
            let chunkB = try handleB.read(upToCount: chunkSize) ?? Data()
            if chunkA != chunkB {
                return false
            }
            if chunkA.isEmpty {
                return true
            }
        }
    }
}
