import SwiftUI

struct ExplorerPanelView: View {
    @Bindable var state: AppState

    @State private var newItemName: String = ""
    @FocusState private var isNewItemFieldFocused: Bool
    @State private var renameText: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    @State private var dropTargetedPath: String?
    @State private var pendingDeleteNode: FileNode?

    private struct Row: Identifiable {
        let id: String
        let node: FileNode?
        let depth: Int
        let isPendingFolder: Bool
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
        if let pending = pendingRow(at: "", depth: 0) { rows.append(pending) }
        appendRows(rootNodes, depth: 0, into: &rows)
        return rows
    }

    private func pendingRow(at parentPath: String, depth: Int) -> Row? {
        switch state.explorerInlineEdit {
        case .creatingFile(let parent) where parent == parentPath:
            return Row(id: "__pending_file__", node: nil, depth: depth, isPendingFolder: false)
        case .creatingFolder(let parent) where parent == parentPath:
            return Row(id: "__pending_folder__", node: nil, depth: depth, isPendingFolder: true)
        default:
            return nil
        }
    }

    private func appendRows(_ nodes: [FileNode], depth: Int, into rows: inout [Row]) {
        for node in nodes {
            rows.append(Row(id: node.id, node: node, depth: depth, isPendingFolder: false))
            guard node.isDirectory else { continue }
            if let pending = pendingRow(at: node.id, depth: depth + 1) { rows.append(pending) }
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
                .rootDropDestination(state: state)
                .contextMenu { rootContextMenuItems }
            }
        }
        .background(SNESTheme.bgPanel)
        .alert(
            deleteAlertTitle,
            isPresented: Binding(get: { pendingDeleteNode != nil }, set: { if !$0 { pendingDeleteNode = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let node = pendingDeleteNode { state.deleteItem(at: node.id) }
                pendingDeleteNode = nil
            }
        } message: {
            Text(pendingDeleteNode?.isDirectory == true
                ? "This folder and its contents will be moved to the Trash."
                : "This file will be moved to the Trash.")
        }
    }

    private var deleteAlertTitle: String {
        "Delete \"\(pendingDeleteNode?.name ?? "")\"?"
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
            .contextMenu { rootContextMenuItems }
    }

    @ViewBuilder
    private var rootContextMenuItems: some View {
        Button("New File...") { state.beginCreateItem(isFolder: false, in: "") }
        Button("New Folder...") { state.beginCreateItem(isFolder: true, in: "") }
        if state.explorerClipboardPath != nil {
            Divider()
            Button("Paste") { state.pasteFromClipboard(intoFolder: "") }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if let node = row.node {
            if case .renaming(let path) = state.explorerInlineEdit, path == node.id {
                renameRow(node, depth: row.depth)
            } else {
                fileRow(node, depth: row.depth)
            }
        } else {
            pendingCreationRow(isFolder: row.isPendingFolder, depth: row.depth)
        }
    }

    private func fileRow(_ node: FileNode, depth: Int) -> some View {
        let isActiveOpenFile = !node.isDirectory
            && state.activeLevel == .logique
            && state.activeSubTabID[.logique] == node.id
        let isSelectedFolder = node.isDirectory && state.selectedExplorerFolderPath == node.id
        let isExpanded = state.expandedExplorerPaths.contains(node.id)
        let isDropTargeted = dropTargetedPath == node.id

        // KNOWN ISSUE: dragging still doesn't initiate. Tried so far: (1) a Button wrapping
        // the row, swapped for onTapGesture — no change; (2) onTapGesture itself swapped for
        // .simultaneousGesture(TapGesture()) in case the tap gesture was claiming the mouse-down
        // exclusively — still no drag. Next to try: the older onDrag/onDrop (NSItemProvider)
        // API in place of .draggable/.dropDestination, since it's more established for
        // List rows on macOS; or isolate whether List(rows) itself is intercepting the gesture.
        return HStack(spacing: 6) {
            Group {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(SNESTheme.textDisabled)
                }
            }
            .frame(width: 10)
            Image(systemName: node.isDirectory ? "folder" : FileKind.of(path: node.id).iconName)
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
        .background(isDropTargeted ? PyramidLevel.logique.accent.opacity(0.25) : (isSelectedFolder ? SNESTheme.bgEditor : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
        .draggable(node.id)
        .dropDestination(for: String.self) { items, _ in
            guard let sourcePath = items.first else { return false }
            let targetFolder = node.isDirectory ? node.id : (node.id as NSString).deletingLastPathComponent
            state.moveItem(at: sourcePath, toFolder: targetFolder)
            return true
        } isTargeted: { targeted in
            dropTargetedPath = targeted ? node.id : (dropTargetedPath == node.id ? nil : dropTargetedPath)
        }
        // .simultaneousGesture (rather than .onTapGesture) so click handling doesn't
        // claim the mouse-down exclusively and block .draggable's own gesture.
        .simultaneousGesture(
            TapGesture().onEnded {
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
            }
        )
        .contextMenu { contextMenuItems(for: node) }
    }

    @ViewBuilder
    private func contextMenuItems(for node: FileNode) -> some View {
        let parent = node.isDirectory ? node.id : (node.id as NSString).deletingLastPathComponent

        if !node.isDirectory, (node.id as NSString).deletingLastPathComponent == "src",
           (node.id as NSString).pathExtension.lowercased() == "asm" {
            Button("Run This File") { Task { await state.runFile(atPath: node.id) } }
            Divider()
        }
        Button("New File...") { state.beginCreateItem(isFolder: false, in: parent) }
        Button("New Folder...") { state.beginCreateItem(isFolder: true, in: parent) }
        Divider()
        Button("Rename") { state.beginRename(node.id) }
        Button("Copy") { state.copyToClipboard(node.id) }
        if node.isDirectory {
            Button("Paste") { state.pasteFromClipboard(intoFolder: node.id) }
                .disabled(state.explorerClipboardPath == nil)
        }
        Divider()
        Button("Reveal in Finder") { state.revealInFinder(node.id) }
        Divider()
        Button("Delete", role: .destructive) { pendingDeleteNode = node }
    }

    private func renameRow(_ node: FileNode, depth: Int) -> some View {
        HStack(spacing: 6) {
            Group {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(SNESTheme.textDisabled)
                }
            }
            .frame(width: 10)
            Image(systemName: node.isDirectory ? "folder" : FileKind.of(path: node.id).iconName)
                .font(.system(size: 11))
                .foregroundStyle(SNESTheme.textSecondary)
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(SNESTheme.textPrimary)
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename(node) }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .onAppear {
            renameText = node.name
            DispatchQueue.main.async { isRenameFieldFocused = true }
        }
        .onExitCommand { state.explorerInlineEdit = nil }
    }

    private func commitRename(_ node: FileNode) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        state.explorerInlineEdit = nil
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        state.renameItem(at: node.id, to: trimmed)
    }

    private func pendingCreationRow(isFolder: Bool, depth: Int) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 10)
            Image(systemName: isFolder ? "folder" : FileKind.of(path: newItemName).iconName)
                .font(.system(size: 11))
                .foregroundStyle(SNESTheme.textDisabled)
            TextField("", text: $newItemName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(SNESTheme.textPrimary)
                .focused($isNewItemFieldFocused)
                .onSubmit { commitNewItem(isFolder: isFolder) }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .onAppear {
            newItemName = ""
            DispatchQueue.main.async { isNewItemFieldFocused = true }
        }
        .onExitCommand { cancelNewItem() }
    }

    private func commitNewItem(isFolder: Bool) {
        let trimmed = newItemName.trimmingCharacters(in: .whitespaces)
        let parent: String
        switch state.explorerInlineEdit {
        case .creatingFile(let p), .creatingFolder(let p): parent = p
        default: parent = ""
        }
        state.explorerInlineEdit = nil
        newItemName = ""
        guard !trimmed.isEmpty else { return }
        if isFolder {
            state.createFolder(name: trimmed, inFolder: parent)
        } else {
            state.createFile(name: trimmed, inFolder: parent)
        }
    }

    private func cancelNewItem() {
        state.explorerInlineEdit = nil
        newItemName = ""
    }
}

private extension View {
    /// Lets dropping onto empty space below the last row move an item to the project root.
    func rootDropDestination(state: AppState) -> some View {
        dropDestination(for: String.self) { items, _ in
            guard let sourcePath = items.first else { return false }
            state.moveItem(at: sourcePath, toFolder: "")
            return true
        }
    }
}
