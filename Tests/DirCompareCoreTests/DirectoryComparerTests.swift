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

            | Name | Status | Left size | Right size | Left modified | Right modified | Newer |
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
