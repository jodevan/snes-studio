import SwiftUI

struct ExplorerPanelView: View {
    @Bindable var state: AppState

    @State private var rootNodes: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if rootNodes.isEmpty {
                emptyState
            } else {
                List(rootNodes, children: \.children) { node in
                    row(for: node)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(SNESTheme.bgPanel)
        .onAppear { refresh() }
        .onChange(of: state.explorerRefreshToken) { _, _ in refresh() }
    }

    private var header: some View {
        HStack {
            Text("EXPLORER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(SNESTheme.textDisabled)
            Spacer()
            Button {
                refresh()
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

    private func row(for node: FileNode) -> some View {
        let isActive = !node.isDirectory
            && state.activeLevel == .logique
            && state.activeSubTabID[.logique] == node.id

        return Button {
            guard !node.isDirectory else { return }
            state.openFile(relativePath: node.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(node.isDirectory ? SNESTheme.textSecondary : SNESTheme.textDisabled)
                Text(node.name)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(isActive ? SNESTheme.textPrimary : SNESTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        guard let projectPath = state.projectManager.currentProject?.projectPath else {
            rootNodes = []
            return
        }
        rootNodes = FileNode.buildTree(rootURL: projectPath)
    }
}
