import Foundation

/// A node in the Explorer's project file tree. `id` is the path relative to the project root.
struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension FileNode {
    /// Builds the project file tree from disk, rooted at `rootURL`. Hidden files are skipped.
    static func buildTree(rootURL: URL) -> [FileNode] {
        children(of: rootURL, rootURL: rootURL)
    }

    private static func children(of dirURL: URL, rootURL: URL) -> [FileNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .map { url -> FileNode in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))
                let kids = isDirectory ? children(of: url, rootURL: rootURL) : nil
                return FileNode(id: relativePath, name: url.lastPathComponent, isDirectory: isDirectory, children: kids?.isEmpty == true ? nil : kids)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
