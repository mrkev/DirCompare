import Foundation

/// What kind of file system object an entry is. Symlinks are never followed.
public enum EntryKind: String, Sendable, Hashable {
    case file
    case directory
    case symlink
    case other

    public var title: String {
        switch self {
        case .file: "File"
        case .directory: "Folder"
        case .symlink: "Symlink"
        case .other: "Special file"
        }
    }
}

/// Metadata for one entry directly inside a compared folder.
public struct EntryInfo: Sendable, Hashable {
    public var name: String
    public var url: URL
    public var kind: EntryKind
    /// Size in bytes as reported by the file system. Not meaningful for folders.
    public var size: Int64
    public var modified: Date?
    public var symlinkDestination: String?
    /// Set when the entry's attributes could not be read.
    public var readError: String?

    public init(
        name: String,
        url: URL,
        kind: EntryKind,
        size: Int64,
        modified: Date?,
        symlinkDestination: String? = nil,
        readError: String? = nil
    ) {
        self.name = name
        self.url = url
        self.kind = kind
        self.size = size
        self.modified = modified
        self.symlinkDestination = symlinkDestination
        self.readError = readError
    }

    /// The size to display or sort by: `nil` for folders, whose sizes vary by file system.
    public var displaySize: Int64? {
        kind == .directory ? nil : size
    }

    /// Reads an entry's attributes without following symlinks.
    public static func read(name: String, in directory: URL, fileManager: FileManager = .default) -> EntryInfo {
        let url = directory.appendingPathComponent(name)
        let path = url.path(percentEncoded: false)
        let attributes: [FileAttributeKey: Any]
        do {
            // attributesOfItem uses lstat, so symlinks describe themselves.
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch {
            return EntryInfo(name: name, url: url, kind: .other, size: 0, modified: nil,
                             readError: error.localizedDescription)
        }

        let kind: EntryKind = switch attributes[.type] as? FileAttributeType {
        case .typeRegular?: .file
        case .typeDirectory?: .directory
        case .typeSymbolicLink?: .symlink
        default: .other
        }

        return EntryInfo(
            name: name,
            url: url,
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            symlinkDestination: kind == .symlink ? try? fileManager.destinationOfSymbolicLink(atPath: path) : nil
        )
    }
}
