import DirCompareCore
import SwiftUI

/// Progress while comparing; otherwise clickable counts that set the filter.
struct StatusBar: View {
    let model: CompareModel

    var body: some View {
        HStack(spacing: 14) {
            if model.isComparing {
                comparing
            } else if let result = model.result {
                summary(result)
            } else {
                Text(" ")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var comparing: some View {
        if let progress = model.progress, progress.total > 0 {
            ProgressView(value: Double(progress.completed), total: Double(progress.total))
                .frame(width: 140)
            Text("Comparing \(progress.currentName ?? "")… (\(progress.completed) of \(progress.total))")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
            Text("Reading folders…").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Stop", action: model.cancel)
            .controlSize(.small)
    }

    @ViewBuilder
    private func summary(_ result: DirectoryComparison) -> some View {
        chip(.onlyLeft, count: result.count(.onlyLeft), status: .onlyLeft)
        chip(.onlyRight, count: result.count(.onlyRight), status: .onlyRight)
        chip(.different, count: result.count(.different) + result.count(.kindMismatch), status: .different)
        chip(.identical, count: result.count(.identical), status: .identical)
        chip(.folders, count: result.rows.count(where: \.bothAreFolders), status: .folders)
        if result.count(.unreadable) > 0 {
            Label("\(result.count(.unreadable)) unreadable", systemImage: ComparisonStatus.unreadable.symbol)
                .foregroundStyle(.secondary)
        }
        if result.count(.unchecked) > 0 {
            Label("\(result.count(.unchecked)) not checked", systemImage: ComparisonStatus.unchecked.symbol)
                .foregroundStyle(.secondary)
        }

        Spacer()

        if let check = model.folderCheck {
            folderCheckProgress(check)
        } else {
            // Top level only, like the counts on the left.
            let shown = model.visibleChildren(of: "").count
            Text(shown == result.rows.count ? "\(shown) items" : "Showing \(shown) of \(result.rows.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// "Checking folder 3 of 25: Library — 12,345 items (Caches/…/file)"
    @ViewBuilder
    private func folderCheckProgress(_ check: CompareModel.FolderCheck) -> some View {
        ProgressView(value: Double(check.completed), total: Double(check.total))
            .frame(width: 80)
        Group {
            if let progress = check.progress {
                Text("Checking folder \(check.completed + 1) of \(check.total): \(check.currentName), \(progress.itemsCompared.formatted()) items")
                    .help(progress.currentPath)
            } else {
                Text("Checking folder \(check.completed + 1) of \(check.total): \(check.currentName)")
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Button("Stop", action: model.cancel)
            .controlSize(.small)
    }

    private func chip(_ filter: RowFilter, count: Int, status: ComparisonStatus) -> some View {
        let isActive = model.filter == filter
        return Button {
            model.filter = isActive ? .all : filter
        } label: {
            Label("\(count) \(filter.title.lowercased())", systemImage: status.symbol)
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(status.color))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isActive ? AnyShapeStyle(status.color.opacity(0.15)) : AnyShapeStyle(.clear),
                            in: .capsule)
        }
        .buttonStyle(.plain)
        .help(isActive ? "Show all rows" : "Show only \(filter.title.lowercased())")
    }
}
