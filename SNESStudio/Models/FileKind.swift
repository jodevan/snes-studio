import Foundation

/// Categorizes a project file to decide how it should open in the editor.
enum FileKind {
    case text
    case image
    case other

    private static let textExtensions: Set<String> = [
        "asm", "inc", "cfg", "s", "txt", "md", "json", "sh", "bat", "snesproj",
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// Cheap, extension-only guess for file-tree/tab icons. No disk access, so it
    /// only recognizes a curated set of extensions and isn't the source of truth
    /// for what can actually be opened as text — see `openKind(path:url:)`.
    static func of(path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }

    /// Accurate kind for a file actually being opened. Images are still recognized
    /// by extension, but anything else is sniffed by content so any text file opens
    /// in the editor, not just the curated extensions in `of(path:)`.
    static func openKind(path: String, url: URL?) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 8000)) ?? Data()
        if sample.isEmpty { return .text }
        if sample.contains(0) { return .other }
        return String(data: sample, encoding: .utf8) != nil ? .text : .other
    }

    var iconName: String {
        switch self {
        case .text: "doc.text"
        case .image: "photo"
        case .other: "doc"
        }
    }
}
