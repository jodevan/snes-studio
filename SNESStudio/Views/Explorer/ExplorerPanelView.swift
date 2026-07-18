import SwiftUI

struct ExplorerPanelView: View {
    @Bindable var state: AppState

    @State private var newFileName: String = ""
    @FocusState private var isNewFileFieldFocused: Bool

    private struct Row: Identifiable {
        let id: String
        let node: FileNode?
        let depth: Int
    }

    /// Rebuilt from disk on every body evaluation — cheap for project-sized trees, and
    /// keeps the tree in sync without a second, delayed render pass (a cached @State
    /// copy updated via .onChange missed insertions into already-expanded folders).
    private var rootNodes: [FileNode] {
        _ = state.explorerRefreshToken
        guard let projectPath = state.projectManager.currentProject?.projectPath else { return [] }
        return FileNode.buildTree(rootURL: projectPath)
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if state.creatingFileParentPath == "" {
            rows.append(Row(id: "__pending__", node: nil, depth: 0))
        }
        appendRows(rootNodes, depth: 0, into: &rows)
        return rows
    }

    private func appendRows(_ nodes: [FileNode], depth: Int, into rows: inout [Row]) {
        for node in nodes {
            rows.append(Row(id: node.id, node: node, depth: depth))
            guard node.isDirectory else { continue }
            if state.creatingFileParentPath == node.id {
                rows.append(Row(id: "__pending__", node: nil, depth: depth + 1))
            }
            if state.expandedExplorerPaths.contains(node.id), let children = node.children {
                appendRows(children, depth: depth + 1, into: &rows)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if rootNodes.isEmpty {
                emptyState
            } else {
                List(rows) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(SNESTheme.bgPanel)
    }

    private var header: some View {
        HStack {
            Text("EXPLORER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(SNESTheme.textDisabled)
            Spacer()
            Button {
                state.refreshExplorer()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(SNESTheme.textDisabled)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            SNESTheme.border.frame(height: 1)
        }
    }

    private var emptyState: some View {
        Text("No files")
            .font(.system(size: 11))
            .foregroundStyle(SNESTheme.textDisabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if let node = row.node {
            fileRow(node, depth: row.depth)
        } else {
            pendingRow(depth: row.depth)
        }
    }

    private func fileRow(_ node: FileNode, depth: Int) -> some View {
        let isActiveOpenFile = !node.isDirectory
            && state.activeLevel == .logique
            && state.activeSubTabID[.logique] == node.id
        let isSelectedFolder = node.isDirectory && state.selectedExplorerFolderPath == node.id
        let isExpanded = state.expandedExplorerPaths.contains(node.id)

        return Button {
            if node.isDirectory {
                state.selectedExplorerFolderPath = node.id
                if isExpanded {
                    state.expandedExplorerPaths.remove(node.id)
                } else {
                    state.expandedExplorerPaths.insert(node.id)
                }
            } else {
                state.openFile(relativePath: node.id)
            }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(SNESTheme.textDisabled)
                    }
                }
                .frame(width: 10)
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(node.isDirectory ? SNESTheme.textSecondary : SNESTheme.textDisabled)
                Text(node.name)
                    .font(.system(size: 12, weight: isActiveOpenFile ? .medium : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(isActiveOpenFile ? SNESTheme.textPrimary : SNESTheme.textSecondary)
            .padding(.vertical, 3)
            .padding(.leading, 8 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelectedFolder ? SNESTheme.bgEditor : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
    }

    private func pendingRow(depth: Int) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 10)
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(SNESTheme.textDisabled)
            TextField("", text: $newFileName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(SNESTheme.textPrimary)
                .focused($isNewFileFieldFocused)
                .onSubmit { commitNewFile() }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .onAppear {
            newFileName = ""
            DispatchQueue.main.async { isNewFileFieldFocused = true }
        }
        .onExitCommand { cancelNewFile() }
    }

    private func commitNewFile() {
        let trimmed = newFileName.trimmingCharacters(in: .whitespaces)
        let parent = state.creatingFileParentPath ?? ""
        state.creatingFileParentPath = nil
        newFileName = ""
        guard !trimmed.isEmpty else { return }
        state.createFile(name: trimmed, inFolder: parent)
    }

    private func cancelNewFile() {
        state.creatingFileParentPath = nil
        newFileName = ""
    }
}
