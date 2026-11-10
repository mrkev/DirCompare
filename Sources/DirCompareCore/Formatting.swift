import Foundation

public enum Formatting {
    /// Exact byte counts with grouping ("11,088"), so small differences stay visible.
    public static func bytes(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return size.formatted(.number.grouping(.automatic))
    }

    /// "2026-10-26 06:49", which reads the same in every locale and sorts as text.
    public static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Abbreviates the home folder as "~".
    public static func path(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    public static func newer(_ side: Side?) -> String {
        switch side {
        case .left?: "Left"
        case .right?: "Right"
        case nil: "—"
        }
    }
}

public enum MarkdownExport {
    /// Renders rows as a Markdown table, headed by the two folder paths.
    public static func render(
        rows: [ComparisonRow],
        left: URL,
        right: URL,
        timeZone: TimeZone = .current
    ) -> String {
        let lines = header(left: left, right: right) + rows.map { line(for: $0, timeZone: timeZone) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The lines before the first row: the folder paths, then the table's header.
    public static func header(left: URL, right: URL) -> [String] {
        [
            "- **Left:** `\(Formatting.path(left))`",
            "- **Right:** `\(Formatting.path(right))`",
            "",
            "| Path | Status | Left size | Right size | Left modified | Right modified | Newer |",
            "|---|---|---:|---:|---|---|---|",
        ]
    }

    /// One row of the table.
    public static func line(for row: ComparisonRow, timeZone: TimeZone = .current) -> String {
        let cells = [
            escape(row.path),
            row.status.title,
            Formatting.bytes(row.left?.displaySize),
            Formatting.bytes(row.right?.displaySize),
            Formatting.date(row.left?.modified, timeZone: timeZone),
            Formatting.date(row.right?.modified, timeZone: timeZone),
            Formatting.newer(row.newer),
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
