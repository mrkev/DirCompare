import DirCompareCore
import SwiftUI

struct ContentView: View {
    @State private var model = CompareModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            FolderBar(model: model)
            Divider()
            OptionsBar(model: model)
            Divider()
            ResultsTable(model: model)
            Divider()
            StatusBar(model: model)
        }
        .navigationTitle("DirCompare")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter names")
        .toolbar { toolbar }
        .onAppear { model.compare() }
    }

    private var subtitle: String {
        guard let left = model.leftURL, let right = model.rightURL else { return "" }
        return "\(Formatting.path(left))  ↔  \(Formatting.path(right))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: model.goBack)
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the parent folders (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Swap Sides", systemImage: "arrow.left.arrow.right", action: model.swapSides)
                .disabled(!model.canCompare)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Swap left and right (⇧⌘S)")

            if model.isComparing {
                Button("Stop", systemImage: "xmark", action: model.cancel)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop comparing (⌘.)")
            } else {
                Button("Compare", systemImage: "arrow.clockwise", action: model.compare)
                    .disabled(!model.canCompare)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Compare again (⌘R)")
            }

            Button("Copy as Markdown", systemImage: "doc.on.clipboard", action: model.copyMarkdown)
                .disabled(model.result == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the visible rows as a Markdown table (⇧⌘C)")
        }
    }
}

// MARK: - Folder pickers

struct FolderBar: View {
    let model: CompareModel

    var body: some View {
        HStack(spacing: 12) {
            FolderWell(title: "Left", url: model.leftURL) { model.setFolder($0, side: .left) }
            FolderWell(title: "Right", url: model.rightURL) { model.setFolder($0, side: .right) }
        }
        .padding(12)
    }
}

struct FolderWell: View {
    let title: String
    let url: URL?
    let onChoose: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                        .resizable()
                } else {
                    Image(systemName: "folder.badge.questionmark")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.map(Formatting.path) ?? "Choose a folder, or drop one here")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .help(url?.path(percentEncoded: false) ?? "")
            }

            Spacer(minLength: 8)

            Button("Choose…", action: choose)
        }
        .padding(8)
        .background(.quaternary.opacity(isTargeted ? 0.9 : 0.4), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first(where: Self.isFolder) else {
                return false
            }
            onChoose(folder)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            if let url {
                Button("Show in Finder") { revealInFinder([url]) }
                Button("Copy Path") { copyToPasteboard(url.path(percentEncoded: false)) }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the \(title.lowercased()) folder"
        panel.directoryURL = url
        if panel.runModal() == .OK, let chosen = panel.url {
            onChoose(chosen)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

// MARK: - Options

struct OptionsBar: View {
    @Bindable var model: CompareModel

    var body: some View {
        HStack(spacing: 16) {
            Picker("Show", selection: $model.filter) {
                ForEach(RowFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Toggle("Hidden files", isOn: $model.includeHidden)
                .help("Include names that start with a dot")
            Toggle("Compare contents", isOn: $model.compareContents)
                .help("Compare same-size files byte by byte. When off, only sizes are compared.")

            HStack(spacing: 6) {
                Text("Ignore")
                TextField("e.g. .DS_Store, *.swp", text: $model.ignoreText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 260)
                    .onSubmit(model.optionsChanged)
                    .help("Comma-separated names or wildcard patterns to leave out. Press Return to apply.")
            }

            Spacer()
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: model.includeHidden) { model.optionsChanged() }
        .onChange(of: model.compareContents) { model.optionsChanged() }
    }
}
