import DirCompareCore
import QuickLook
import SwiftUI

struct ResultsTable: View {
    @Bindable var model: CompareModel

    var body: some View {
        let rows = model.visibleRows

        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                NameCell(row: row)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Status", value: \.statusRank) { row in
                StatusBadge(status: row.status)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Left Size", value: \.leftSizeKey) { row in
                SizeCell(size: row.left?.displaySize, highlighted: row.status == .different && row.bothAreFiles)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Right Size", value: \.rightSizeKey) { row in
                SizeCell(size: row.right?.displaySize, highlighted: row.status == .different && row.bothAreFiles)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Left Modified", value: \.leftDateKey) { row in
                DateCell(date: row.left?.modified, isNewer: row.newer == .left)
            }
            .width(min: 120, ideal: 135)

            TableColumn("Right Modified", value: \.rightDateKey) { row in
                DateCell(date: row.right?.modified, isNewer: row.newer == .right)
            }
            .width(min: 120, ideal: 135)

            TableColumn("Newer", value: \.newerRank) { row in
                NewerCell(side: row.newer)
            }
            .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: ComparisonRow.ID.self) { ids in
            RowMenu(model: model, rows: model.rows(for: ids))
        } primaryAction: { ids in
            model.activate(ids)
        }
        .onKeyPress(.space) {
            guard !model.selection.isEmpty || model.quickLookURL != nil else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
        .onChange(of: model.selection) { model.selectionChanged() }
        .quickLookPreview($model.quickLookURL, in: model.quickLookItems)
        .overlay { placeholder(rowCount: rows.count) }
    }

    @ViewBuilder
    private func placeholder(rowCount: Int) -> some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn’t Compare", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again", action: model.compare)
            }
        } else if !model.canCompare {
            ContentUnavailableView(
                "Choose Two Folders",
                systemImage: "folder.badge.questionmark",
                description: Text("Pick a folder on each side, or drag folders in from Finder.")
            )
        } else if model.result == nil {
            if model.isComparing {
                ProgressView()
            }
        } else if rowCount == 0 {
            if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.filter == .differences {
                ContentUnavailableView(
                    "No Differences",
                    systemImage: "checkmark.circle",
                    description: Text("Everything at this level matches.")
                )
            } else {
                ContentUnavailableView("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

// MARK: - Cells

struct NameCell: View {
    let row: ComparisonRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note = row.note, row.kind == .symlink {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(row.note ?? row.name)
    }

    private var icon: String {
        if row.status == .kindMismatch {
            return "exclamationmark.triangle"
        }
        return switch row.kind {
        case .directory: "folder.fill"
        case .file: "doc"
        case .symlink: "arrow.up.right.square"
        case .other: "questionmark.square"
        }
    }

    private var iconColor: Color {
        switch row.kind {
        case .directory: .blue
        case .symlink: .teal
        default: .secondary
        }
    }
}

struct StatusBadge: View {
    let status: ComparisonStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .foregroundStyle(status.color)
            .lineLimit(1)
    }
}

extension ComparisonStatus {
    var symbol: String {
        switch self {
        case .onlyLeft: "arrow.left.circle.fill"
        case .onlyRight: "arrow.right.circle.fill"
        case .different: "notequal.circle.fill"
        case .kindMismatch: "exclamationmark.triangle.fill"
        case .unreadable: "lock.fill"
        case .unchecked: "questionmark.circle"
        case .folders: "folder"
        case .identical: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .onlyLeft: .orange
        case .onlyRight: .purple
        case .different: .red
        case .kindMismatch: .pink
        case .unreadable: .gray
        case .unchecked: .secondary
        case .folders: .blue
        case .identical: .green
        }
    }
}

struct SizeCell: View {
    let size: Int64?
    let highlighted: Bool

    var body: some View {
        Text(Formatting.bytes(size))
            .monospacedDigit()
            .foregroundStyle(size == nil ? .tertiary : highlighted ? .primary : .secondary)
            .fontWeight(highlighted ? .medium : .regular)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(size.map { $0.formatted(.byteCount(style: .file)) } ?? "")
    }
}

struct DateCell: View {
    let date: Date?
    let isNewer: Bool

    var body: some View {
        Text(Formatting.date(date))
            .monospacedDigit()
            .foregroundStyle(date == nil ? .tertiary : isNewer ? .primary : .secondary)
            .fontWeight(isNewer ? .semibold : .regular)
            .help(date?.formatted(date: .complete, time: .complete) ?? "")
    }
}

struct NewerCell: View {
    let side: Side?

    var body: some View {
        switch side {
        case .left?:
            Label("Left", systemImage: "arrow.left")
        case .right?:
            Label("Right", systemImage: "arrow.right")
        case nil:
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Context menu

struct RowMenu: View {
    let model: CompareModel
    let rows: [ComparisonRow]

    var body: some View {
        if !rows.isEmpty {
            Button(rows.count == 1 ? "Quick Look" : "Quick Look \(rows.count) Items") {
                model.quickLook(Set(rows.map(\.id)))
            }
            Divider()
        }
        if rows.count == 1, let row = rows.first {
            if row.bothAreFolders {
                Button("Open Folders Side by Side") { model.open(row) }
            }
            if row.bothAreFiles, FileMerge.isAvailable, let left = row.left?.url, let right = row.right?.url {
                Button("Compare in FileMerge") { try? FileMerge.open(left, right) }
            }
            if row.bothAreFolders || row.bothAreFiles {
                Divider()
            }
            if let left = row.left?.url {
                Button("Show Left in Finder") { revealInFinder([left]) }
            }
            if let right = row.right?.url {
                Button("Show Right in Finder") { revealInFinder([right]) }
            }
            Divider()
            Button("Copy Name") { copyToPasteboard(row.name) }
            if let left = row.left?.url {
                Button("Copy Left Path") { copyToPasteboard(left.path(percentEncoded: false)) }
            }
            if let right = row.right?.url {
                Button("Copy Right Path") { copyToPasteboard(right.path(percentEncoded: false)) }
            }
        } else if !rows.isEmpty {
            Button("Show in Finder") {
                revealInFinder(rows.flatMap { [$0.left?.url, $0.right?.url].compactMap { $0 } })
            }
            Button("Copy Names") { copyToPasteboard(rows.map(\.name).joined(separator: "\n")) }
            Button("Copy as Markdown") {
                if let result = model.result {
                    copyToPasteboard(MarkdownExport.render(rows: rows, left: result.left, right: result.right))
                }
            }
        }
    }
}
