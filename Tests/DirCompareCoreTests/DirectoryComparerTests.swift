import Foundation
import Testing
@testable import DirCompareCore

/// A pair of temporary folders, removed on deinit.
final class Fixture {
    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirCompareTests-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions changed by tests so cleanup can't fail.
        if let names = try? FileManager.default.subpathsOfDirectory(atPath: root.path) {
            for name in names {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: root.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ name: String, in side: Side, contents: String = "", modified: Date? = nil) throws -> URL {
        let url = folder(side).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func directory(_ name: String, in side: Side, modified: Date? = nil) throws -> URL {
        let url = folder(side).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func symlink(_ name: String, in side: Side, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: folder(side).appendingPathComponent(name).path,
            withDestinationPath: destination
        )
    }

    func folder(_ side: Side) -> URL {
        side == .left ? left : right
    }

    func compare(_ options: ComparisonOptions = ComparisonOptions()) throws -> DirectoryComparison {
        try DirectoryComparer(options: options).compare(left, right)
    }
}

extension DirectoryComparison {
    func row(_ name: String) -> ComparisonRow? {
        rows.first { $0.name == name }
    }
}

private let jan1 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
private let feb1 = Date(timeIntervalSince1970: 1_769_904_000) // 2026-02-01 00:00 UTC

@Suite("Pairing names")
struct PairingTests {
    @Test func entriesOnOneSideOnly() throws {
        let fixture = try Fixture()
        try fixture.file("left-only.txt", in: .left)
        try fixture.directory("right-only", in: .right)

        let result = try fixture.compare()

        #expect(result.rows.map(\.name) == ["left-only.txt", "right-only"])
        #expect(result.row("left-only.txt")?.status == .onlyLeft)
        #expect(result.row("left-only.txt")?.right == nil)
        #expect(result.row("right-only")?.status == .onlyRight)
        #expect(result.row("right-only")?.left == nil)
        #expect(result.row("right-only")?.newer == nil)
    }

    @Test func rowsAreSortedNaturally() throws {
        let fixture = try Fixture()
        for name in ["b", "file10", "A", "file2"] {
            try fixture.file(name, in: .left)
        }

        let result = try fixture.compare()

        #expect(result.rows.map(\.name) == ["A", "b", "file2", "file10"])
    }

    @Test func unicodeFormsArePaired() throws {
        let fixture = try Fixture()
        // "é" precomposed (NFC) on one side and decomposed (NFD) on the other.
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        try fixture.file(composed, in: .left, contents: "same")
        try fixture.file(decomposed, in: .right, contents: "same")

        let result = try fixture.compare()

        #expect(result.rows.count == 1)
        #expect(result.rows.first?.status == .identical)
    }

    @Test func missingFolderThrows() throws {
        let fixture = try Fixture()
        let missing = fixture.root.appendingPathComponent("nope")

        #expect(throws: ComparisonError.notADirectory(missing)) {
            try DirectoryComparer().compare(fixture.left, missing)
        }
    }

    @Test func fileInsteadOfFolderThrows() throws {
        let fixture = try Fixture()
        let file = try fixture.file("plain.txt", in: .left)

        #expect(throws: ComparisonError.notADirectory(file)) {
            try DirectoryComparer().compare(file, fixture.right)
        }
    }

    @Test func doesNotRecurse() throws {
        let fixture = try Fixture()
        let leftSub = try fixture.directory("sub", in: .left, modified: jan1)
        let rightSub = try fixture.directory("sub", in: .right, modified: jan1)
        try Data("a".utf8).write(to: leftSub.appendingPathComponent("inner.txt"))
        try Data("b".utf8).write(to: rightSub.appendingPathComponent("other.txt"))
        // Writing inside the folders bumps their dates; reset them.
        for url in [leftSub, rightSub] {
            try FileManager.default.setAttributes([.modificationDate: jan1], ofItemAtPath: url.path)
        }

        let result = try fixture.compare()

        #expect(result.rows.map(\.name) == ["sub"])
        #expect(result.row("sub")?.status == .folders)
        #expect(result.row("sub")?.isDifference == false)
    }
}

@Suite("Comparing files")
struct FileTests {
    @Test func identicalContents() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", in: .left, contents: "hello", modified: jan1)
        try fixture.file("a.txt", in: .right, contents: "hello", modified: feb1)

        let row = try #require(try fixture.compare().row("a.txt"))

        #expect(row.status == .identical)
        #expect(row.newer == .right)
        // Same bytes with different dates isn't a difference worth flagging.
        #expect(row.isDifference == false)
    }

    @Test func differentSizes() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", in: .left, contents: "hello")
        try fixture.file("a.txt", in: .right, contents: "hello!")

        let row = try #require(try fixture.compare().row("a.txt"))

        #expect(row.status == .different)
        #expect(row.left?.size == 5)
        #expect(row.right?.size == 6)
        #expect(row.isDifference)
    }

    @Test func sameSizeDifferentBytes() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", in: .left, contents: "hello")
        try fixture.file("a.txt", in: .right, contents: "jello")

        #expect(try fixture.compare().row("a.txt")?.status == .different)
    }

    @Test func emptyFilesAreIdentical() throws {
        let fixture = try Fixture()
        try fixture.file("empty", in: .left)
        try fixture.file("empty", in: .right)

        #expect(try fixture.compare().row("empty")?.status == .identical)
    }

    @Test func contentCheckingOff() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", in: .left, contents: "hello", modified: jan1)
        try fixture.file("a.txt", in: .right, contents: "jello", modified: jan1)
        try fixture.file("b.txt", in: .left, contents: "short")
        try fixture.file("b.txt", in: .right, contents: "longer")

        let result = try fixture.compare(ComparisonOptions(compareContents: false))

        #expect(result.row("a.txt")?.status == .unchecked)
        #expect(result.row("a.txt")?.isDifference == false)
        // A size difference is still caught without reading contents.
        #expect(result.row("b.txt")?.status == .different)
    }

    @Test func unreadableFile() throws {
        let fixture = try Fixture()
        try fixture.file("secret", in: .left, contents: "aaa")
        let locked = try fixture.file("secret", in: .right, contents: "bbb")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let row = try #require(try fixture.compare().row("secret"))

        #expect(row.status == .unreadable)
        #expect(row.note != nil)
        #expect(row.isDifference)
    }

    @Test func multiChunkFiles() throws {
        let fixture = try Fixture()
        let size = 3 * 1024 * 1024 + 17
        var bytes = Data(repeating: 7, count: size)
        try bytes.write(to: fixture.left.appendingPathComponent("big.bin"))
        try bytes.write(to: fixture.right.appendingPathComponent("same.bin"))
        try bytes.write(to: fixture.left.appendingPathComponent("same.bin"))
        bytes[size - 1] = 8
        try bytes.write(to: fixture.right.appendingPathComponent("big.bin"))

        let result = try fixture.compare()

        #expect(result.row("big.bin")?.status == .different)
        #expect(result.row("same.bin")?.status == .identical)
    }

    @Test func contentsEqualWithSmallChunks() throws {
        let fixture = try Fixture()
        let a = try fixture.file("a", in: .left, contents: "abcdefghij")
        let b = try fixture.file("a", in: .right, contents: "abcdefghiX")
        let c = try fixture.file("c", in: .right, contents: "abcdefghij")

        #expect(try DirectoryComparer.contentsEqual(a, b, chunkSize: 3) == false)
        #expect(try DirectoryComparer.contentsEqual(a, c, chunkSize: 3) == true)
    }
}

@Suite("Folders, symlinks and kinds")
struct KindTests {
    @Test func folderDates() throws {
        let fixture = try Fixture()
        try fixture.directory("newer-left", in: .left, modified: feb1)
        try fixture.directory("newer-left", in: .right, modified: jan1)
        try fixture.directory("same", in: .left, modified: jan1)
        try fixture.directory("same", in: .right, modified: jan1)

        let result = try fixture.compare()

        #expect(result.row("newer-left")?.status == .folders)
        #expect(result.row("newer-left")?.newer == .left)
        #expect(result.row("newer-left")?.isDifference == true)
        #expect(result.row("same")?.newer == nil)
        #expect(result.row("same")?.isDifference == false)
        #expect(result.row("same")?.bothAreFolders == true)
    }

    @Test func dateTolerance() throws {
        let fixture = try Fixture()
        try fixture.file("close", in: .left, contents: "x", modified: jan1)
        try fixture.file("close", in: .right, contents: "x", modified: jan1.addingTimeInterval(2))
        try fixture.file("far", in: .left, contents: "x", modified: jan1)
        try fixture.file("far", in: .right, contents: "x", modified: jan1.addingTimeInterval(3))

        let result = try fixture.compare()

        #expect(result.row("close")?.newer == nil)
        #expect(result.row("far")?.newer == .right)
    }

    @Test func kindMismatch() throws {
        let fixture = try Fixture()
        try fixture.file("thing", in: .left)
        try fixture.directory("thing", in: .right)

        let row = try #require(try fixture.compare().row("thing"))

        #expect(row.status == .kindMismatch)
        #expect(row.note == "File on the left, folder on the right")
    }

    @Test func symlinksAreNotFollowed() throws {
        let fixture = try Fixture()
        try fixture.directory("target", in: .left)
        try fixture.symlink("link", in: .left, to: "target")
        try fixture.symlink("link", in: .right, to: "target")
        try fixture.symlink("other", in: .left, to: "/tmp")
        try fixture.symlink("other", in: .right, to: "/var")

        let result = try fixture.compare()

        let same = try #require(result.row("link"))
        #expect(same.left?.kind == .symlink)
        #expect(same.status == .identical)
        #expect(same.note == "→ target")

        let different = try #require(result.row("other"))
        #expect(different.status == .different)
        #expect(different.note == "→ /tmp on the left, → /var on the right")
    }

    @Test func brokenSymlinkIsStillListed() throws {
        let fixture = try Fixture()
        try fixture.symlink("dangling", in: .left, to: "does-not-exist")

        let row = try #require(try fixture.compare().row("dangling"))

        #expect(row.status == .onlyLeft)
        #expect(row.left?.kind == .symlink)
    }
}

@Suite("Options")
struct OptionsTests {
    @Test func hiddenFiles() throws {
        let fixture = try Fixture()
        try fixture.file(".hidden", in: .left)
        try fixture.file("shown", in: .left)

        #expect(try fixture.compare().rows.map(\.name) == [".hidden", "shown"])
        #expect(try fixture.compare(ComparisonOptions(includeHidden: false)).rows.map(\.name) == ["shown"])
    }

    @Test func ignorePatterns() throws {
        let fixture = try Fixture()
        for name in [".DS_Store", "notes.swp", "keep.txt", "Thumbs.db"] {
            try fixture.file(name, in: .left)
        }

        let options = ComparisonOptions(ignorePatterns: [".DS_Store", "*.swp", "Thumbs.*"])
        #expect(try fixture.compare(options).rows.map(\.name) == ["keep.txt"])
    }

    @Test func parsePatterns() {
        #expect(ComparisonOptions.parsePatterns(" .DS_Store, *.swp ,,\n.Trash ") == [".DS_Store", "*.swp", ".Trash"])
        #expect(ComparisonOptions.parsePatterns("   ") == [])
    }
}

@Suite("Progress and cancellation")
struct ProgressTests {
    @Test func reportsProgress() throws {
        let fixture = try Fixture()
        try fixture.file("a", in: .left)
        try fixture.file("b", in: .right)

        let updates = Updates()
        _ = try DirectoryComparer().compare(fixture.left, fixture.right) { updates.append($0) }

        let all = updates.all
        #expect(all.map(\.completed) == [0, 1, 2])
        #expect(all.allSatisfy { $0.total == 2 })
        #expect(all.map(\.currentName) == ["a", "b", nil])
    }

    @Test func cancellationStopsComparison() async throws {
        let fixture = try Fixture()
        for index in 0..<50 {
            try fixture.file("file\(index)", in: .left)
        }
        let (left, right) = (fixture.left, fixture.right)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectoryComparer().compareAsync(left, right)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func asyncMatchesSync() async throws {
        let fixture = try Fixture()
        try fixture.file("a", in: .left, contents: "1")
        try fixture.file("a", in: .right, contents: "2")

        let result = try await DirectoryComparer().compareAsync(fixture.left, fixture.right)

        #expect(result.rows.map(\.status) == [.different])
    }
}

final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ComparisonProgress] = []

    func append(_ update: ComparisonProgress) {
        lock.withLock { updates.append(update) }
    }

    var all: [ComparisonProgress] {
        lock.withLock { updates }
    }
}

@Suite("Formatting and export")
struct FormattingTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func bytes() {
        #expect(Formatting.bytes(nil) == "—")
        #expect(Formatting.bytes(0) == "0")
        #expect(Formatting.bytes(11_088).contains("088"))
    }

    @Test func dates() {
        #expect(Formatting.date(feb1, timeZone: utc) == "2026-02-01 00:00")
        #expect(Formatting.date(nil) == "—")
    }

    @Test func homePathIsAbbreviated() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(Formatting.path(home.appendingPathComponent("Documents")) == "~/Documents")
        #expect(Formatting.path(URL(filePath: "/Volumes/kevin")) == "/Volumes/kevin")
    }

    @Test func markdownTable() {
        let left = URL(filePath: "/a")
        let right = URL(filePath: "/b")
        let rows = [
            ComparisonRow(
                id: "x|y", name: "x|y",
                left: EntryInfo(name: "x|y", url: left, kind: .file, size: 5, modified: jan1),
                right: EntryInfo(name: "x|y", url: right, kind: .file, size: 6, modified: feb1),
                status: .different, newer: .right
            ),
            ComparisonRow(
                id: "dir", name: "dir",
                left: EntryInfo(name: "dir", url: left, kind: .directory, size: 16384, modified: jan1),
                right: nil,
                status: .onlyLeft
            ),
        ]

        let markdown = MarkdownExport.render(rows: rows, left: left, right: right, timeZone: utc)

        #expect(markdown == """
            - **Left:** `/a`
            - **Right:** `/b`

            | Path | Status | Left size | Right size | Left modified | Right modified | Newer |
            |---|---|---:|---:|---|---|---|
            | x\\|y | Different | 5 | 6 | 2026-01-01 00:00 | 2026-02-01 00:00 | Right |
            | dir | Only left | — | — | 2026-01-01 00:00 | — | — |

            """)
    }

    @Test func statusRanks() {
        #expect(ComparisonStatus.onlyLeft.rank < ComparisonStatus.identical.rank)
        #expect(Set(ComparisonStatus.allCases.map(\.rank)).count == ComparisonStatus.allCases.count)
    }
}

@Suite("Recursive folder checks")
struct FolderSummaryTests {
    /// Builds the same small tree on both sides: a/x.txt, a/b/y.txt, z.txt
    func mirroredTree(_ fixture: Fixture) throws {
        for side in [Side.left, .right] {
            try fixture.directory("a/b", in: side)
            try fixture.file("a/x.txt", in: side, contents: "x")
            try fixture.file("a/b/y.txt", in: side, contents: "y")
            try fixture.file("z.txt", in: side, contents: "z")
        }
    }

    @Test func identicalTrees() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.identical == 3)
        #expect(summary.itemCount == 3)
        #expect(summary.status == .identical)
        #expect(summary.description == "All 3 items match")
    }

    @Test func differencesDeepInTheTree() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)
        try fixture.file("a/b/y.txt", in: .right, contents: "changed")
        try fixture.file("a/b/left-only.txt", in: .left)
        try fixture.directory("a/right-only-folder/inner", in: .right)
        try fixture.file("a/thing", in: .left)
        try fixture.directory("a/thing", in: .right)

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.onlyLeft == 1)
        // A folder on one side counts once, however much is inside it.
        #expect(summary.onlyRight == 1)
        // y.txt, plus "thing" being a file on one side and a folder on the other.
        #expect(summary.different == 2)
        #expect(summary.identical == 2)
        #expect(summary.status == .different)
        #expect(summary.description == "1 only left, 1 only right, 2 different")
    }

    @Test func emptyFolders() throws {
        let fixture = try Fixture()

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.itemCount == 0)
        #expect(summary.status == .identical)
        #expect(summary.description == "Both empty")
    }

    @Test func singleItemWording() throws {
        let fixture = try Fixture()
        try fixture.file("only", in: .left, contents: "1")
        try fixture.file("only", in: .right, contents: "1")

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.description == "The 1 item matches")
    }

    @Test func respectsOptions() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)
        try fixture.file("a/.DS_Store", in: .left, contents: "junk")
        try fixture.file("a/b/notes.swp", in: .right)
        try fixture.file("a/same-size.txt", in: .left, contents: "aaa")
        try fixture.file("a/same-size.txt", in: .right, contents: "bbb")

        let options = ComparisonOptions(compareContents: false, ignorePatterns: [".DS_Store", "*.swp"])
        let summary = try DirectoryComparer(options: options).summarizeFolders(fixture.left, fixture.right)

        #expect(summary.onlyLeft == 0)
        #expect(summary.onlyRight == 0)
        #expect(summary.unchecked == 4)
        #expect(summary.status == .identical)
        #expect(summary.description == "All 4 items match, 4 not checked")
    }

    @Test func symlinkedFoldersAreNotFollowed() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)
        // A link back up the tree would loop forever if followed.
        try fixture.symlink("a/b/loop", in: .left, to: "../..")
        try fixture.symlink("a/b/loop", in: .right, to: "../..")

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.identical == 4)
        #expect(summary.status == .identical)
    }

    @Test func unreadableSubfolder() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)
        let locked = try fixture.directory("a/b", in: .right)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let summary = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right)

        #expect(summary.unreadable == 1)
        #expect(summary.identical == 2)
        #expect(summary.status == .unreadable)
    }

    @Test func reportsFinalProgress() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)

        let updates = FolderUpdates()
        _ = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right, progressInterval: .zero) {
            updates.append($0)
        }

        let all = updates.all
        #expect(all.count == 4) // One per item, plus the final report.
        #expect(Set(all.dropLast().map(\.currentPath)) == ["a/x.txt", "a/b/y.txt", "z.txt"])
        #expect(all.last == FolderProgress(itemsCompared: 3, currentPath: ""))
    }

    @Test func throttlesProgress() throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)

        let updates = FolderUpdates()
        _ = try DirectoryComparer().summarizeFolders(fixture.left, fixture.right, progressInterval: .seconds(60)) {
            updates.append($0)
        }

        #expect(updates.all == [FolderProgress(itemsCompared: 3, currentPath: "")])
    }

    @Test func cancellation() async throws {
        let fixture = try Fixture()
        try mirroredTree(fixture)
        let row = try #require(try fixture.compare().row("a"))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectoryComparer().checkFolderAsync(row)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func applyingToARow() throws {
        let fixture = try Fixture()
        try fixture.directory("a", in: .left, modified: jan1)
        try fixture.directory("a", in: .right, modified: feb1)
        try fixture.file("a/f", in: .left, contents: "1")
        try fixture.file("a/f", in: .right, contents: "2")
        let result = try fixture.compare()
        var row = try #require(result.row("a"))
        #expect(row.status == .folders)

        row.apply(try DirectoryComparer().summarizeFolders(row.left!.url, row.right!.url))

        #expect(row.status == .different)
        #expect(row.note == "1 different")
        #expect(row.folderSummary?.different == 1)
        #expect(row.isDifference)
    }
}

final class FolderUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [FolderProgress] = []

    func append(_ update: FolderProgress) {
        lock.withLock { updates.append(update) }
    }

    var all: [FolderProgress] {
        lock.withLock { updates }
    }
}

@Suite("Rows inside subfolders")
struct NestedRowTests {
    @Test func topLevelRowsHaveNoParent() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", in: .left)

        let row = try #require(try fixture.compare().row("a.txt"))

        #expect(row.id == "a.txt")
        #expect(row.path == "a.txt")
        #expect(row.parentID == "")
    }

    @Test func childRowsArePrefixedWithTheirParent() throws {
        let fixture = try Fixture()
        for side in [Side.left, .right] {
            try fixture.directory("outer/inner", in: side)
            try fixture.file("outer/inner/file.txt", in: side, contents: "same")
        }
        let comparer = DirectoryComparer()

        let outer = try #require(try fixture.compare().row("outer"))
        let level1 = try comparer.compare(outer.left!.url, outer.right!.url, under: outer)
        let inner = try #require(level1.row("inner"))
        let level2 = try comparer.compare(inner.left!.url, inner.right!.url, under: inner)
        let file = try #require(level2.row("file.txt"))

        #expect(inner.id == "outer/inner")
        #expect(inner.path == "outer/inner")
        #expect(inner.parentID == "outer")
        #expect(file.id == "outer/inner/file.txt")
        #expect(file.path == "outer/inner/file.txt")
        #expect(file.parentID == "outer/inner")
        #expect(file.status == .identical)
    }

    @Test func idsUseNormalizedNamesButPathsKeepDiskNames() throws {
        let fixture = try Fixture()
        let decomposed = "cafe\u{301}"
        try fixture.directory(decomposed, in: .left)
        try fixture.directory(decomposed, in: .right)
        try fixture.file("\(decomposed)/x", in: .left)

        let parent = try #require(try fixture.compare().rows.first)
        let child = try #require(try DirectoryComparer()
            .compare(parent.left!.url, parent.right!.url, under: parent).rows.first)

        #expect(child.id == "caf\u{E9}/x")
        #expect(child.path.unicodeScalars.elementsEqual("\(parent.name)/x".unicodeScalars))
    }

    @Test func markdownUsesPaths() {
        let row = ComparisonRow(id: "a/b", name: "b", path: "a/b", left: nil, right: nil, status: .onlyLeft)

        let markdown = MarkdownExport.render(rows: [row], left: URL(filePath: "/l"), right: URL(filePath: "/r"))

        #expect(markdown.contains("| a/b | Only left |"))
    }
}

@Suite("Keeping levels from recursive checks")
struct FolderCheckTests {
    /// a/            differs, deep down
    ///   b/c.txt     different
    ///   same/f.txt  identical, so a/same isn't kept
    ///   top.txt     identical
    /// z/            identical
    func tree(_ fixture: Fixture) throws -> DirectoryComparison {
        for side in [Side.left, .right] {
            try fixture.directory("a/b", in: side)
            try fixture.directory("a/same", in: side)
            try fixture.directory("z", in: side)
            try fixture.file("a/same/f.txt", in: side, contents: "f")
            try fixture.file("a/top.txt", in: side, contents: "t")
            try fixture.file("z/z.txt", in: side, contents: "z")
        }
        try fixture.file("a/b/c.txt", in: .left, contents: "left")
        try fixture.file("a/b/c.txt", in: .right, contents: "right!")
        return try fixture.compare()
    }

    @Test func keepsOnlyFoldersThatDiffer() throws {
        let fixture = try Fixture()
        let a = try #require(try tree(fixture).row("a"))

        let result = try DirectoryComparer().checkFolder(a)

        #expect(Set(result.levels.keys) == ["a", "a/b"])
        #expect(result.levels["a"]?.map(\.id) == ["a/b", "a/same", "a/top.txt"])
        #expect(result.levels["a/b"]?.map(\.id) == ["a/b/c.txt"])
        #expect(result.summary.different == 1)
        #expect(result.summary.identical == 2)
    }

    @Test func subfolderRowsHaveTheirOwnSummaries() throws {
        let fixture = try Fixture()
        let a = try #require(try tree(fixture).row("a"))

        let levels = try DirectoryComparer().checkFolder(a).levels
        let b = try #require(levels["a"]?.first { $0.id == "a/b" })
        let same = try #require(levels["a"]?.first { $0.id == "a/same" })

        #expect(b.status == .different)
        #expect(b.note == "1 different")
        #expect(b.path == "a/b")
        #expect(same.status == .identical)
        #expect(same.folderSummary?.identical == 1)
        #expect(levels["a/b"]?.first?.status == .different)
        #expect(levels["a/b"]?.first?.path == "a/b/c.txt")
    }

    @Test func identicalFolderKeepsNothing() throws {
        let fixture = try Fixture()
        let z = try #require(try tree(fixture).row("z"))

        let result = try DirectoryComparer().checkFolder(z)

        #expect(result.levels.isEmpty)
        #expect(result.summary.status == .identical)
    }

    @Test func matchesSummarizeFolders() throws {
        let fixture = try Fixture()
        let a = try #require(try tree(fixture).row("a"))
        let comparer = DirectoryComparer()

        #expect(try comparer.checkFolder(a).summary == comparer.summarizeFolders(a.left!.url, a.right!.url))
    }

    @Test func unreadableSubfolderIsKept() throws {
        let fixture = try Fixture()
        let a = try #require(try tree(fixture).row("a"))
        let locked = fixture.right.appendingPathComponent("a/same")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let result = try DirectoryComparer().checkFolder(a)

        let same = try #require(result.levels["a"]?.first { $0.id == "a/same" })
        #expect(same.status == .unreadable)
        // a/same couldn't be listed, so there are no rows to keep for it.
        #expect(result.levels["a/same"] == nil)
    }

    @Test func progressPathsAreRelativeToTheCheckedFolder() throws {
        let fixture = try Fixture()
        let a = try #require(try tree(fixture).row("a"))

        let updates = FolderUpdates()
        _ = try DirectoryComparer().checkFolder(a, progressInterval: .zero) { updates.append($0) }

        #expect(Set(updates.all.dropLast().map(\.currentPath)) == ["b/c.txt", "same/f.txt", "top.txt"])
        #expect(updates.all.last?.itemsCompared == 3)
    }
}

@Suite("Walking folders")
struct WalkTests {
    /// a/b/c.txt  different
    /// a/new.txt  only right
    /// a/same.txt identical
    /// z.txt      only left
    func tree(_ fixture: Fixture) throws {
        for side in [Side.left, .right] {
            try fixture.directory("a/b", in: side)
            try fixture.file("a/same.txt", in: side, contents: "s")
        }
        try fixture.file("a/b/c.txt", in: .left, contents: "left")
        try fixture.file("a/b/c.txt", in: .right, contents: "right!")
        try fixture.file("a/new.txt", in: .right)
        try fixture.file("z.txt", in: .left)
    }

    @Test func visitsEveryItemInPathOrder() throws {
        let fixture = try Fixture()
        try tree(fixture)

        var visited: [ComparisonRow] = []
        let summary = try DirectoryComparer().walk(fixture.left, fixture.right) { visited.append($0) }

        #expect(visited.map(\.path) == ["a/b/c.txt", "a/new.txt", "a/same.txt", "z.txt"])
        #expect(visited.map(\.status) == [.different, .onlyRight, .identical, .onlyLeft])
        #expect(try summary == DirectoryComparer().summarizeFolders(fixture.left, fixture.right))
    }

    @Test func prefixesPathsUnderAParent() throws {
        let fixture = try Fixture()
        try tree(fixture)
        let a = try #require(try fixture.compare().row("a"))

        var paths: [String] = []
        _ = try DirectoryComparer().walk(a.left!.url, a.right!.url, under: a) { paths.append($0.path) }

        #expect(paths == ["a/b/c.txt", "a/new.txt", "a/same.txt"])
    }

    @Test func unreadableSubfolderIsVisitedWithItsReason() throws {
        let fixture = try Fixture()
        try tree(fixture)
        let locked = fixture.right.appendingPathComponent("a/b")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        var visited: [ComparisonRow] = []
        let summary = try DirectoryComparer().walk(fixture.left, fixture.right) { visited.append($0) }

        let b = try #require(visited.first { $0.path == "a/b" })
        #expect(b.status == .unreadable)
        #expect(b.note?.contains("a/b") == true)
        #expect(summary.unreadable == 1)
    }

    @Test func errorFromTheVisitorStopsTheWalk() throws {
        struct Stop: Error {}
        let fixture = try Fixture()
        try tree(fixture)

        var visited: [String] = []
        #expect(throws: Stop.self) {
            try DirectoryComparer().walk(fixture.left, fixture.right) { row in
                visited.append(row.path)
                if row.status == .onlyRight { throw Stop() }
            }
        }
        #expect(visited == ["a/b/c.txt", "a/new.txt"])
    }

    @Test func unreadableRootThrows() throws {
        let fixture = try Fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.right.path)

        #expect(throws: ComparisonError.self) {
            try DirectoryComparer().walk(fixture.left, fixture.right) { _ in }
        }
    }
}

@Suite("Command-line report")
struct CommandLineReportTests {
    /// docs/a.md     different (3 → 5 bytes)
    /// docs/same.md  identical
    /// docs/x.md     only left
    /// lib/          identical folder
    /// lib/l.txt     identical
    /// top.txt       only right
    func tree(_ fixture: Fixture) throws {
        for side in [Side.left, .right] {
            try fixture.directory("docs", in: side)
            try fixture.directory("lib", in: side)
            try fixture.file("docs/same.md", in: side, contents: "same", modified: jan1)
            try fixture.file("lib/l.txt", in: side, contents: "l", modified: jan1)
        }
        try fixture.file("docs/a.md", in: .left, contents: "old", modified: jan1)
        try fixture.file("docs/a.md", in: .right, contents: "newer", modified: feb1)
        try fixture.file("docs/x.md", in: .left)
        try fixture.file("top.txt", in: .right, contents: "top")
    }

    func run(_ report: CommandLineReport) throws -> ([String], CommandLineReport.Outcome) {
        var lines: [String] = []
        let outcome = try report.run(comparer: DirectoryComparer()) { lines.append($0) }
        return (lines, outcome)
    }

    func report(_ fixture: Fixture, _ configure: (inout CommandLineReport) -> Void = { _ in }) -> CommandLineReport {
        var report = CommandLineReport(left: fixture.left, right: fixture.right)
        configure(&report)
        return report
    }

    @Test func listsDifferencesAllTheWayDown() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, outcome) = try run(report(fixture))

        #expect(lines == [
            "different    docs/a.md  (3 → 5 bytes; right newer)",
            "only-left    docs/x.md  (0 bytes)",
            "only-right   top.txt  (3 bytes)",
            "Summary: 1 only left, 1 only right, 1 different",
        ])
        #expect(outcome.exitCode == 1)
    }

    @Test func showAllIncludesIdenticalItems() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.showAll = true })

        #expect(lines.count == 6)
        #expect(lines.contains("identical    lib/l.txt  (1 byte)"))
    }

    @Test func identicalFoldersExitZero() throws {
        let fixture = try Fixture()
        try fixture.file("same.txt", in: .left, contents: "s")
        try fixture.file("same.txt", in: .right, contents: "s")

        let (lines, outcome) = try run(report(fixture))

        #expect(lines == ["Summary: The 1 item matches"])
        #expect(outcome.exitCode == 0)
    }

    @Test func limitCountsTheRest() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, outcome) = try run(report(fixture) { $0.limit = 1 })

        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("… 2 more not listed."))
        #expect(outcome.listed == 1)
        #expect(outcome.omitted == 2)
        #expect(outcome.exitCode == 1)
    }

    @Test func underKeepsPathsRelativeToTheRoots() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.under = "docs/" })

        #expect(lines.first?.contains(" docs/a.md ") == true)
        #expect(lines.last == "Summary: 1 only left, 1 different")
    }

    @Test func underAMissingFolderThrows() throws {
        let fixture = try Fixture()
        try tree(fixture)

        #expect(throws: ComparisonError.self) {
            try run(report(fixture) { $0.under = "nope" })
        }
    }

    @Test func shallowAlwaysListsFolderPairs() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, outcome) = try run(report(fixture) { $0.scope = .shallow })

        // docs and lib haven't been looked inside, so they're listed whatever their dates.
        #expect(lines == [
            "folders      docs/",
            "folders      lib/",
            "only-right   top.txt  (3 bytes)",
            "Summary: 1 only right, 2 folders not compared; look inside with --under PATH",
        ])
        #expect(outcome.foldersNotCompared == 2)
        #expect(outcome.exitCode == 1)
    }

    @Test func shallowUnderASubfolder() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, outcome) = try run(report(fixture) { $0.scope = .shallow; $0.under = "docs" })

        #expect(lines == [
            "different    docs/a.md  (3 → 5 bytes; right newer)",
            "only-left    docs/x.md  (0 bytes)",
            "Summary: 1 only left, 1 different",
        ])
        #expect(outcome.foldersNotCompared == 0)
    }

    @Test func summaryChecksEachFolder() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.scope = .summary; $0.showAll = true })

        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("different    docs/  ("))
        #expect(lines[0].hasSuffix("1 only left, 1 different)"))
        #expect(lines[1].hasSuffix("The 1 item matches)"))
        #expect(lines[3] == "Summary: 1 only left, 1 only right, 1 different")
    }

    @Test func unreadableFolderExitsTwo() throws {
        let fixture = try Fixture()
        try tree(fixture)
        let locked = fixture.right.appendingPathComponent("docs")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let (lines, outcome) = try run(report(fixture))

        #expect(lines.first?.hasPrefix("unreadable   docs/  (") == true)
        #expect(outcome.exitCode == 2)
    }

    @Test func firstStopsAtTheFirstDifference() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, outcome) = try run(report(fixture) { $0.stopAtFirstDifference = true; $0.showAll = true })

        #expect(lines == [
            "different    docs/a.md  (3 → 5 bytes; right newer)",
            "Summary: stopped at the first difference (--first)",
        ])
        #expect(outcome.stoppedEarly)
        #expect(outcome.summary.different == 1)
        #expect(outcome.summary.itemCount == 1)
        #expect(outcome.exitCode == 1)
    }

    @Test func firstKeepsGoingPastUnknowns() throws {
        let fixture = try Fixture()
        try tree(fixture)

        // docs/ and lib/ haven't been looked inside, which doesn't make them differ.
        let (lines, outcome) = try run(report(fixture) {
            $0.scope = .shallow
            $0.stopAtFirstDifference = true
        })

        #expect(lines == [
            "folders      docs/",
            "folders      lib/",
            "only-right   top.txt  (3 bytes)",
            "Summary: stopped at the first difference (--first)",
        ])
        #expect(outcome.stoppedEarly)
    }

    @Test func firstFinishesWhenNothingDiffers() throws {
        let fixture = try Fixture()
        try fixture.file("same.txt", in: .left, contents: "s")
        try fixture.file("same.txt", in: .right, contents: "s")

        let (lines, outcome) = try run(report(fixture) { $0.stopAtFirstDifference = true })

        #expect(lines == ["Summary: The 1 item matches"])
        #expect(!outcome.stoppedEarly)
        #expect(outcome.exitCode == 0)
    }

    @Test func jsonRecords() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.format = .json; $0.limit = 1 })
        let records = try lines.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }

        #expect(records.count == 2)
        let row = records[0]
        #expect(row["type"] as? String == "row")
        #expect(row["path"] as? String == "docs/a.md")
        #expect(row["status"] as? String == "different")
        #expect(row["newer"] as? String == "right")
        let left = try #require(row["left"] as? [String: Any])
        #expect(left["size"] as? Int == 3)
        #expect(left["modified"] as? String == "2026-01-01T00:00:00Z")
        #expect((left["path"] as? String)?.hasSuffix("/left/docs/a.md") == true)

        let summary = records[1]
        #expect(summary["type"] as? String == "summary")
        #expect(summary["schema"] as? Int == 1)
        #expect(summary["listed"] as? Int == 1)
        #expect(summary["omitted"] as? Int == 2)
        #expect(summary["exitCode"] as? Int == 1)
        #expect(summary["stoppedEarly"] as? Bool == false)
        #expect((summary["counts"] as? [String: Int])?["onlyLeft"] == 1)
    }

    @Test func jsonSummaryScopeIncludesCounts() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.format = .json; $0.scope = .summary })
        let docs = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(docs["path"] as? String == "docs")
        #expect((docs["counts"] as? [String: Int])?["different"] == 1)
        let left = try #require(docs["left"] as? [String: Any])
        #expect(left["size"] == nil)
        #expect((left["path"] as? String)?.hasSuffix("/left/docs") == true)
    }

    @Test func markdownTableThenSummary() throws {
        let fixture = try Fixture()
        try tree(fixture)

        let (lines, _) = try run(report(fixture) { $0.format = .markdown })

        // A line per row, so output cut short still has every row found so far.
        #expect(lines.count == 10)
        #expect(lines[0].hasPrefix("- **Left:** "))
        #expect(lines[5].hasPrefix("| docs/a.md | Different |"))
        #expect(lines[8] == "")
        #expect(lines[9].hasPrefix("Summary: "))
    }

    @Test func markdownHeaderEvenWithNoRows() throws {
        let fixture = try Fixture()

        let (lines, _) = try run(report(fixture) { $0.format = .markdown })

        #expect(lines.count == 7)
        #expect(lines[4] == "|---|---|---:|---:|---|---|---|")
        #expect(lines[6] == "Summary: Both empty")
    }

    @Test func markdownMatchesTheAppsExport() throws {
        let fixture = try Fixture()
        try tree(fixture)
        let utc = TimeZone(identifier: "UTC")!

        let (lines, _) = try run(report(fixture) { $0.format = .markdown; $0.showAll = true; $0.timeZone = utc })

        var rows: [ComparisonRow] = []
        _ = try DirectoryComparer().walk(fixture.left, fixture.right) { rows.append($0) }
        let table = MarkdownExport.render(rows: rows, left: fixture.left, right: fixture.right, timeZone: utc)
        #expect(lines.dropLast(2).joined(separator: "\n") + "\n" == table)
    }
}
