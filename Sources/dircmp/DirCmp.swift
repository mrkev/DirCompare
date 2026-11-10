import ArgumentParser
import DirCompareCore
import Foundation

@main
struct DirCmp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dircmp",
        abstract: "Compare two folders, all the way down.",
        discussion: """
            Lists what differs between LEFT and RIGHT, one line per item, in path order. \
            Paths are relative to LEFT and RIGHT. Folders present on both sides are \
            descended into rather than listed. Symlinks are never followed.

            Each line starts with a status:
              only-left     only in LEFT (a folder there counts as one item)
              only-right    only in RIGHT
              different     sizes or bytes differ, or symlinks point elsewhere
              type-differs  e.g. a file on one side, a folder on the other
              unreadable    couldn't be read; the reason follows
              not-checked   same size but contents not compared (--no-contents),
                            or a special file
              identical     same bytes (listed only with --all)
              folders       a folder pair, compared by date only (--shallow)

            Modification dates within --date-tolerance count as equal. A newer date \
            on its own isn't a difference: files with the same bytes are identical.

            Output stops after --limit items and says how many more there were. For a \
            large tree, start with --summary, then look inside one folder with --under.

            --format json writes one JSON object per line: a "row" record per item \
            (relative path, status, newer side, and for each side its absolute path, \
            kind, size in bytes and ISO 8601 modification date), then one "summary" \
            record with counts, "listed", "omitted" and "exitCode". The "schema" field \
            changes if the format changes incompatibly.

            Exit status: 0 if nothing differs, 1 if something does, 2 if something \
            couldn't be read (the rest of the output is still complete) or the folders \
            can't be compared, 64 for invalid arguments.

            Examples:
              dircmp ~/Photos /Volumes/Backup/Photos
              dircmp a b --summary
              dircmp a b --under docs/notes --all
              dircmp a b --json --limit 0 | jq -r 'select(.status=="only-left").left.path'
              dircmp a b --ignore '.DS_Store, *.swp' --no-contents
            """
    )

    @Argument(help: "The left folder.")
    var left: String

    @Argument(help: "The right folder.")
    var right: String

    @Option(help: ArgumentHelp(
        "Compare only this subfolder, present on both sides. Output paths stay relative to LEFT and RIGHT.",
        valueName: "path"
    ))
    var under: String?

    @Flag(help: "Compare only the items directly inside the folders. Folder pairs are compared by date only.")
    var shallow = false

    @Flag(help: "List the items directly inside the folders, with each folder pair checked all the way down and shown with its counts.")
    var summary = false

    @Flag(name: [.short, .long], help: "List identical items too, not only differences.")
    var all = false

    @Option(help: "List at most this many items; the rest are counted. 0 lists everything.")
    var limit = 200

    @Option(help: "Output format: text, json (one object per line) or markdown.")
    var format: ReportFormat = .text

    @Flag(help: "Same as --format json.")
    var json = false

    @Option(help: ArgumentHelp(
        "Names or wildcards to skip, comma-separated, like '.DS_Store, *.swp'. Can be repeated.",
        valueName: "patterns"
    ))
    var ignore: [String] = []

    @Flag(help: "Skip names that start with a dot.")
    var noHidden = false

    @Flag(help: "Don't read file contents. Same-size files are reported as not-checked instead of compared byte by byte.")
    var noContents = false

    @Option(help: ArgumentHelp("Modification dates closer than this count as equal.", valueName: "seconds"))
    var dateTolerance: Double = 2

    func validate() throws {
        if shallow && summary {
            throw ValidationError("--shallow and --summary can't be used together.")
        }
        if json && format != .text && format != .json {
            throw ValidationError("--json and --format \(format.rawValue) can't be used together.")
        }
        if limit < 0 {
            throw ValidationError("--limit can't be negative.")
        }
        if dateTolerance < 0 {
            throw ValidationError("--date-tolerance can't be negative.")
        }
    }

    func run() throws {
        // Flush each line, so output cut short by a timeout or Ctrl-C isn't lost.
        setvbuf(stdout, nil, _IOLBF, 0)

        let options = ComparisonOptions(
            includeHidden: !noHidden,
            compareContents: !noContents,
            ignorePatterns: ignore.flatMap(ComparisonOptions.parsePatterns),
            dateTolerance: dateTolerance
        )
        var report = CommandLineReport(left: folderURL(left), right: folderURL(right))
        report.under = under
        report.scope = shallow ? .shallow : summary ? .summary : .recursive
        report.format = json ? .json : format
        report.showAll = all
        report.limit = limit == 0 ? nil : limit

        let status = StatusLine()
        let outcome: CommandLineReport.Outcome
        do {
            outcome = try report.run(
                comparer: DirectoryComparer(options: options),
                progress: status.isEnabled ? status.show : nil
            ) { line in
                status.clear()
                print(line)
            }
        } catch {
            status.clear()
            FileHandle.standardError.write(Data("dircmp: \(error.localizedDescription)\n".utf8))
            throw ExitCode(2)
        }
        status.clear()
        throw ExitCode(outcome.exitCode)
    }

    func folderURL(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath).absoluteURL.standardized
    }
}

extension ReportFormat: ExpressibleByArgument {}

/// Progress on stderr, only when it's a terminal, overwritten in place.
final class StatusLine: @unchecked Sendable {
    let isEnabled = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var showing = false

    func show(_ progress: FolderProgress) {
        var path = progress.currentPath
        if path.count > 60 {
            path = "…" + path.suffix(59)
        }
        let line = "\r\u{1B}[K\(progress.itemsCompared.formatted()) items compared  \(path)"
        lock.withLock {
            FileHandle.standardError.write(Data(line.utf8))
            showing = true
        }
    }

    func clear() {
        lock.withLock {
            guard showing else { return }
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            showing = false
        }
    }
}
