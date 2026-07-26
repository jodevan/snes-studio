import SwiftUI
import AppKit

/// State for the Explorer's inline text-field editing (new file/folder name, or rename).
/// Paths are relative to the project root; "" means the project root itself.
enum ExplorerInlineEdit: Equatable {
    case creatingFile(parent: String)
    case creatingFolder(parent: String)
    case renaming(path: String)
}

@Observable
final class AppState {
    // MARK: - Navigation
    var activeLevel: PyramidLevel = .atelier
    var activeSubTabID: [PyramidLevel: String] = [
        .atelier: "palettes",
        .orchestre: "niveaux",
        .logique: "",
        .hardware: "cartouche",
    ]
    var sourceFiles: [String] = []
    /// Set when a build/run action is blocked by a missing build command, so the
    /// Cartridge tab can show a prompt pointing at the Command field.
    var showBuildCommandPrompt: Bool = false

    // MARK: - Tabs (kept for screen tab tracking)
    var tabManager = TabManager()

    // MARK: - Explorer / open files
    /// Files currently open in the LOGIQUE tab bar, as paths relative to the project root.
    var openFiles: [String] = []
    /// Cached `FileKind` for each open file, sniffed once when opened (see `openFile`).
    var openFileKinds: [String: FileKind] = [:]
    var explorerRefreshToken: Int = 0
    /// The folder selected in the Explorer (path relative to the project root, "" for the project root itself).
    var selectedExplorerFolderPath: String? = nil
    var expandedExplorerPaths: Set<String> = []
    /// Non-nil while an inline text field (new file/folder name, or rename) is showing in the Explorer.
    var explorerInlineEdit: ExplorerInlineEdit? = nil
    /// Path (relative to the project root) most recently copied via the Explorer's Copy action.
    var explorerClipboardPath: String? = nil

    // MARK: - Panel visibility
    var isExplorerVisible: Bool = true
    var isRightPanelVisible: Bool = false
    var isConsoleVisible: Bool = true
    var isRecentProjectsVisible: Bool = true
    var isRecentProjectsOverlayVisible: Bool = false

    // MARK: - Panel sizes
    var explorerWidth: CGFloat = SNESTheme.sidebarDefaultWidth
    var rightPanelWidth: CGFloat = SNESTheme.rightPanelDefaultWidth
    var bottomHeight: CGFloat = SNESTheme.hardwareBarHeight + SNESTheme.consoleDefaultHeight

    // MARK: - Hardware budget
    var budgetMeters: [BudgetMeter] = []

    // MARK: - Cursor
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    // MARK: - Console
    var consoleMessages: [ConsoleMessage] = [
        ConsoleMessage(timestamp: Date(), type: .info, text: "SNES Studio v0.1.0 — Ready"),
    ]

    // MARK: - Project
    var projectManager = ProjectManager()
    var buildSystem = BuildSystem()
    var assetStore = AssetStore()
    var romAnalyzer = ROMAnalyzer()
    var chatManager = ChatManager()
    var spriteDrawingSession = SpriteDrawingSession()
    var showNewProjectSheet = false

    // MARK: - Right panel mode
    enum RightPanelMode { case aide, chat }
    var rightPanelMode: RightPanelMode = .aide

    // MARK: - Termination observer
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushAutoSave()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        sourceDirWatcher?.cancel()
    }

    // MARK: - Navigation Actions

    func selectSubTab(_ id: String) {
        activeSubTabID[activeLevel] = id
    }

    func openScreenTab(screenID: UUID, screenName: String) {
        activeLevel = .orchestre
        activeSubTabID[.orchestre] = "screen_\(screenID.uuidString)"
    }

    func toggleAide() {
        if isRightPanelVisible && rightPanelMode == .aide {
            withAnimation(.easeInOut(duration: 0.2)) { isRightPanelVisible = false }
        } else {
            rightPanelMode = .aide
            withAnimation(.easeInOut(duration: 0.2)) { isRightPanelVisible = true }
        }
    }

    func toggleChat() {
        if isRightPanelVisible && rightPanelMode == .chat {
            withAnimation(.easeInOut(duration: 0.2)) { isRightPanelVisible = false }
        } else {
            rightPanelMode = .chat
            withAnimation(.easeInOut(duration: 0.2)) { isRightPanelVisible = true }
        }
    }

    func toggleRightPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isRightPanelVisible.toggle()
        }
    }

    func toggleConsole() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isConsoleVisible.toggle()
        }
    }

    func toggleExplorer() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExplorerVisible.toggle()
        }
    }

    func refreshExplorer() {
        explorerRefreshToken += 1
    }

    /// On the Welcome screen this shows/hides the docked sidebar; once a project is
    /// open (and that sidebar isn't part of the view tree) it toggles a floating
    /// overlay instead, so the same menu command/shortcut works in both contexts.
    func toggleRecentProjects() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if projectManager.currentProject != nil {
                isRecentProjectsOverlayVisible.toggle()
            } else {
                isRecentProjectsVisible.toggle()
            }
        }
    }

    func setLevel(_ level: PyramidLevel) {
        withAnimation(.easeInOut(duration: 0.3)) {
            activeLevel = level
        }
    }

    func appendConsole(_ text: String, type: ConsoleMessage.MessageType = .info, fileRef: FileReference? = nil) {
        consoleMessages.append(
            ConsoleMessage(timestamp: Date(), type: type, text: text, fileRef: fileRef)
        )
    }

    func clearConsole() {
        consoleMessages.removeAll()
    }

    // MARK: - File URL helper

    /// Returns the file URL for a file ID (path relative to the project root, e.g. "src/main.asm")
    func fileURL(for fileID: String) -> URL? {
        guard let projectPath = projectManager.currentProject?.projectPath else { return nil }
        return projectPath.appendingPathComponent(fileID)
    }

    // MARK: - Open files (LOGIQUE)

    /// Opens a file (path relative to the project root) in the LOGIQUE editor and switches to it.
    func openFile(relativePath: String) {
        activeLevel = .logique
        if !openFiles.contains(relativePath) {
            openFiles.append(relativePath)
            projectManager.currentProject?.openFiles = openFiles
        }
        if openFileKinds[relativePath] == nil {
            openFileKinds[relativePath] = FileKind.openKind(path: relativePath, url: fileURL(for: relativePath))
        }
        activeSubTabID[.logique] = relativePath
    }

    func closeFile(_ relativePath: String) {
        openFiles.removeAll { $0 == relativePath }
        projectManager.currentProject?.openFiles = openFiles
        openFileKinds.removeValue(forKey: relativePath)
        if activeSubTabID[.logique] == relativePath {
            activeSubTabID[.logique] = openFiles.last ?? ""
        }
    }

    // MARK: - Explorer file operations

    /// Shows an inline "new file"/"new folder" text field under `parent` (or the current
    /// Explorer selection/project root when `parent` is nil), expanding any collapsed
    /// ancestor folders so it's visible.
    func beginCreateItem(isFolder: Bool, in parent: String? = nil) {
        guard projectManager.currentProject != nil else { return }
        isExplorerVisible = true
        let target = parent ?? selectedExplorerFolderPath ?? ""
        expandExplorerAncestors(of: target)
        if parent != nil { selectedExplorerFolderPath = target }
        explorerInlineEdit = isFolder ? .creatingFolder(parent: target) : .creatingFile(parent: target)
    }

    /// Kept for the File menu / Cmd+N call site.
    func beginCreateFile() {
        beginCreateItem(isFolder: false)
    }

    /// Shows an inline rename text field in place of the row for `relativePath`.
    func beginRename(_ relativePath: String) {
        isExplorerVisible = true
        explorerInlineEdit = .renaming(path: relativePath)
    }

    private func expandExplorerAncestors(of path: String) {
        var ancestor = path
        while !ancestor.isEmpty {
            expandedExplorerPaths.insert(ancestor)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    /// Creates an empty file named `name` inside `relativeFolder` (path relative to the
    /// project root, "" for the project root) and opens it.
    func createFile(name: String, inFolder relativeFolder: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        let folderURL = relativeFolder.isEmpty ? projectPath : projectPath.appendingPathComponent(relativeFolder)
        let fileURL = folderURL.appendingPathComponent(name)

        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            appendConsole(String(localized: "File already exists: \(name)"), type: .warning)
            return
        }
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            appendConsole(String(localized: "Could not create file: \(name)"), type: .error)
            return
        }

        syncFileLists()

        let relativePath = relativeFolder.isEmpty ? name : "\(relativeFolder)/\(name)"
        openFile(relativePath: relativePath)
    }

    /// Creates a folder named `name` inside `relativeFolder` and selects it.
    func createFolder(name: String, inFolder relativeFolder: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        let folderURL = relativeFolder.isEmpty ? projectPath : projectPath.appendingPathComponent(relativeFolder)
        let newFolderURL = folderURL.appendingPathComponent(name)

        guard !FileManager.default.fileExists(atPath: newFolderURL.path) else {
            appendConsole(String(localized: "Folder already exists: \(name)"), type: .warning)
            return
        }
        do {
            try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: false)
        } catch {
            appendConsole(String(localized: "Could not create folder: \(error.localizedDescription)"), type: .error)
            return
        }

        let relativePath = relativeFolder.isEmpty ? name : "\(relativeFolder)/\(name)"
        selectedExplorerFolderPath = relativePath
        syncFileLists()
    }

    /// Renames the file/folder at `relativePath` to `newName`, remapping any open tabs,
    /// selection, and expansion state that pointed inside it.
    func renameItem(at relativePath: String, to newName: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        let parent = (relativePath as NSString).deletingLastPathComponent
        let newRelativePath = parent.isEmpty ? newName : "\(parent)/\(newName)"
        guard newRelativePath != relativePath else { return }

        let oldURL = projectPath.appendingPathComponent(relativePath)
        let newURL = projectPath.appendingPathComponent(newRelativePath)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            appendConsole(String(localized: "\"\(newName)\" already exists"), type: .warning)
            return
        }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            appendConsole(String(localized: "Rename failed: \(error.localizedDescription)"), type: .error)
            return
        }
        remapExplorerPaths(from: relativePath, to: newRelativePath)
        syncFileLists()
    }

    /// Moves the file/folder at `relativePath` into `targetFolder` (path relative to the
    /// project root, "" for the project root). No-op if it's already there.
    func moveItem(at relativePath: String, toFolder targetFolder: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        guard relativePath != targetFolder, !targetFolder.hasPrefix(relativePath + "/") else {
            appendConsole(String(localized: "Can't move an item into itself"), type: .warning)
            return
        }
        let name = (relativePath as NSString).lastPathComponent
        let currentParent = (relativePath as NSString).deletingLastPathComponent
        guard currentParent != targetFolder else { return }

        let newRelativePath = targetFolder.isEmpty ? name : "\(targetFolder)/\(name)"
        let oldURL = projectPath.appendingPathComponent(relativePath)
        let newURL = projectPath.appendingPathComponent(newRelativePath)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            appendConsole(String(localized: "\"\(name)\" already exists in the destination"), type: .warning)
            return
        }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            appendConsole(String(localized: "Move failed: \(error.localizedDescription)"), type: .error)
            return
        }
        remapExplorerPaths(from: relativePath, to: newRelativePath)
        syncFileLists()
    }

    /// Marks `relativePath` to be duplicated by a later `pasteFromClipboard`.
    func copyToClipboard(_ relativePath: String) {
        explorerClipboardPath = relativePath
    }

    /// Duplicates the clipboard item into `targetFolder`, auto-renaming on a name collision
    /// the way Finder does ("name copy.ext", "name copy 2.ext", ...).
    func pasteFromClipboard(intoFolder targetFolder: String) {
        guard let source = explorerClipboardPath,
              let projectPath = projectManager.currentProject?.projectPath else { return }
        let sourceURL = projectPath.appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            appendConsole(String(localized: "Copied item no longer exists"), type: .warning)
            explorerClipboardPath = nil
            return
        }

        let name = (source as NSString).lastPathComponent
        let destinationURL = uniqueExplorerDestination(forName: name, inFolder: targetFolder, projectPath: projectPath)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            appendConsole(String(localized: "Paste failed: \(error.localizedDescription)"), type: .error)
            return
        }
        syncFileLists()
    }

    private func uniqueExplorerDestination(forName name: String, inFolder folder: String, projectPath: URL) -> URL {
        let folderURL = folder.isEmpty ? projectPath : projectPath.appendingPathComponent(folder)
        let firstCandidate = folderURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: firstCandidate.path) else { return firstCandidate }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        var candidate = folderURL.appendingPathComponent(ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
            candidate = folderURL.appendingPathComponent(suffixed)
            counter += 1
        }
        return candidate
    }

    /// Moves the file/folder at `relativePath` to the Trash, closing any open tabs under it.
    func deleteItem(at relativePath: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        let url = projectPath.appendingPathComponent(relativePath)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            appendConsole(String(localized: "Delete failed: \(error.localizedDescription)"), type: .error)
            return
        }

        for path in openFiles where path == relativePath || path.hasPrefix(relativePath + "/") {
            closeFile(path)
        }
        if selectedExplorerFolderPath == relativePath { selectedExplorerFolderPath = nil }
        expandedExplorerPaths.remove(relativePath)
        if explorerClipboardPath == relativePath { explorerClipboardPath = nil }
        syncFileLists()
    }

    func revealInFinder(_ relativePath: String) {
        guard let projectPath = projectManager.currentProject?.projectPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectPath.appendingPathComponent(relativePath)])
    }

    /// Updates open tabs, selection, and expansion state after a file/folder moved from
    /// `oldPath` to `newPath` (covers both a rename and a drag-and-drop move).
    private func remapExplorerPaths(from oldPath: String, to newPath: String) {
        func remap(_ path: String) -> String {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return path
        }
        openFiles = openFiles.map(remap)
        openFileKinds = openFileKinds.reduce(into: [:]) { result, entry in
            result[remap(entry.key)] = entry.value
        }
        projectManager.currentProject?.openFiles = openFiles
        if let active = activeSubTabID[.logique] {
            activeSubTabID[.logique] = remap(active)
        }
        expandedExplorerPaths = Set(expandedExplorerPaths.map(remap))
        if let selected = selectedExplorerFolderPath {
            selectedExplorerFolderPath = remap(selected)
        }
    }

    /// Rescans src/ (for the build system's file list) and refreshes the Explorer tree.
    /// Used after any operation that touches the filesystem outside the normal editor save path.
    private func syncFileLists() {
        rescanSourceFiles()
        refreshExplorer()
    }

    /// Label for the current active sub-tab
    var activeSubTabLabel: String {
        guard let id = activeSubTabID[activeLevel], !id.isEmpty else { return "" }
        // For source files, the ID is a path relative to the project root — show just the filename
        if activeLevel == .logique { return (id as NSString).lastPathComponent }
        // For screen tabs
        if id.hasPrefix("screen_") {
            if let uuid = UUID(uuidString: String(id.dropFirst("screen_".count))),
               let screen = assetStore.worldScreens.first(where: { $0.id == uuid }) {
                return screen.name
            }
            return String(localized: "Screen")
        }
        // Static sub-tab names
        let labels: [String: String] = [
            "palettes": String(localized: "Palettes"), "tiles": String(localized: "Tiles"), "tilemaps": String(localized: "Tilemaps"),
            "sprites": String(localized: "Sprites"), "audio": String(localized: "Audio"), "controleur": String(localized: "Controller"),
            "niveaux": String(localized: "Screens"),
            "cartouche": String(localized: "Cartridge"), "registres": String(localized: "Registers"), "memoire": String(localized: "Memory"),
            "vram": String(localized: "VRAM"), "couches_bg": String(localized: "BG Layers"), "rom_analyzer": String(localized: "ROM Analyzer"),
        ]
        return labels[id] ?? id
    }

    // MARK: - Auto-save

    private var autoSaveWork: DispatchWorkItem?

    /// Immediate save — for discrete changes (palette, controller, world, code)
    func saveAssetsNow() {
        autoSaveWork?.cancel()
        autoSaveWork = nil
        performAutoSave()
    }

    /// Debounced save — for continuous drawing (tiles, tilemap, sprites, levels)
    func scheduleAutoSave() {
        autoSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performAutoSave()
        }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Flush on app termination
    func flushAutoSave() {
        autoSaveWork?.cancel()
        autoSaveWork = nil
        performAutoSave()
    }

    private func performAutoSave() {
        guard let project = projectManager.currentProject else {
            return
        }
        guard let assetsDir = project.assetsDirectoryURL else {
            appendConsole(String(localized: "Auto-save: no assets folder"), type: .warning)
            return
        }
        do {
            try assetStore.save(to: assetsDir)
            try projectManager.saveProject()
        } catch {
            appendConsole(String(localized: "Auto-save error: \(error.localizedDescription)"), type: .error)
        }
    }

    // MARK: - Project actions

    func loadProject() {
        guard let project = projectManager.currentProject else { return }
        sourceFiles = project.sourceFiles
        tabManager.closeAllTabs()
        isRecentProjectsOverlayVisible = false
        activeLevel = .logique

        // Reset Explorer state
        selectedExplorerFolderPath = nil
        expandedExplorerPaths = []
        explorerInlineEdit = nil
        explorerClipboardPath = nil

        // Reopen the files that were open when the project was last saved, falling
        // back to the first source file for projects with no saved tab state.
        openFiles = []
        openFileKinds = [:]
        let restoredFiles = (project.openFiles ?? []).filter { path in
            guard let url = fileURL(for: path) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        if !restoredFiles.isEmpty {
            for path in restoredFiles {
                openFile(relativePath: path)
            }
        } else if let first = sourceFiles.first {
            openFile(relativePath: "src/\(first)")
        } else {
            activeSubTabID[.logique] = ""
        }

        startWatchingSourceDirectory()
        refreshExplorer()

        if let assetsDir = project.assetsDirectoryURL {
            let result = assetStore.load(from: assetsDir)
            if !result.directoryExists {
                appendConsole(String(localized: "assets/ folder not found — \(assetsDir.path)"), type: .warning)
            } else if !result.loaded.isEmpty {
                appendConsole(String(localized: "Assets loaded: \(result.loaded.joined(separator: ", "))"), type: .info)
            }
            if !result.missing.isEmpty {
                appendConsole(String(localized: "Missing files (defaults): \(result.missing.joined(separator: ", "))"), type: .info)
            }
            for (file, err) in result.errors {
                appendConsole(String(localized: "Error \(file): \(err)"), type: .error)
            }
            // New project: save defaults so files exist for next load
            if result.loaded.isEmpty && result.errors.isEmpty {
                performAutoSave()
            }
        } else {
            appendConsole(String(localized: "No assets path configured"), type: .warning)
        }
        recalculateBudget()
        appendConsole(String(localized: "Project \"\(project.name)\" loaded — \(project.projectPath?.path ?? "?")"), type: .success)
    }

    // MARK: - Source directory watching

    private var sourceDirWatcher: DispatchSourceFileSystemObject?
    private var sourceRescanWork: DispatchWorkItem?

    /// Watches the project's src/ directory so files added/removed outside the
    /// app (or by external tools) refresh the LOGIQUE file list without reopening.
    private func startWatchingSourceDirectory() {
        sourceDirWatcher?.cancel()
        sourceDirWatcher = nil

        guard let srcDir = projectManager.currentProject?.sourceDirectoryURL else { return }
        let fd = open(srcDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleSourceFilesRescan()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        sourceDirWatcher = source
    }

    /// Debounced so a single save (temp file + rename) doesn't trigger repeated rescans.
    private func scheduleSourceFilesRescan() {
        sourceRescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rescanSourceFiles()
        }
        sourceRescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rescanSourceFiles() {
        guard let srcDir = projectManager.currentProject?.sourceDirectoryURL,
              FileManager.default.fileExists(atPath: srcDir.path) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)) ?? []
        let files = contents
            .filter { $0.pathExtension == "asm" || $0.pathExtension == "inc" }
            .map { $0.lastPathComponent }
            .sorted()
        guard files != sourceFiles else { return }

        sourceFiles = files
        projectManager.currentProject?.sourceFiles = files

        let validPaths = Set(files.map { "src/\($0)" })
        openFiles.removeAll { $0.hasPrefix("src/") && !validPaths.contains($0) }
        openFileKinds = openFileKinds.filter { openFiles.contains($0.key) }
        projectManager.currentProject?.openFiles = openFiles
        if let active = activeSubTabID[.logique], active.hasPrefix("src/"), !validPaths.contains(active) {
            activeSubTabID[.logique] = openFiles.last ?? ""
        }

        refreshExplorer()
    }

    func recalculateBudget() {
        guard let config = projectManager.currentProject?.cartridge else {
            budgetMeters = []
            return
        }
        budgetMeters = BudgetMeter.metersFromCartridge(config, assets: assetStore)
    }

    func saveActiveFile() {
        do {
            try projectManager.saveProject()
            if let assetsDir = projectManager.currentProject?.assetsDirectoryURL {
                try assetStore.save(to: assetsDir)
            }
            recalculateBudget()
            appendConsole(String(localized: "Project saved"), type: .success)
        } catch {
            appendConsole(String(localized: "Save error: \(error.localizedDescription)"), type: .error)
        }
    }

    func openFileAtLine(file: String, line: Int) {
        guard sourceFiles.contains(file) else {
            appendConsole(String(localized: "File \(file) not found in project"), type: .warning)
            return
        }
        openFile(relativePath: "src/\(file)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: .setCursorPosition,
                object: nil,
                userInfo: ["line": line, "column": 1]
            )
        }
    }

    func buildProject(entryFileOverride: String? = nil) async {
        guard let project = projectManager.currentProject else {
            appendConsole(String(localized: "No project open"), type: .error)
            return
        }
        guard !project.buildSettings.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !project.buildSettings.romName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            promptForBuildCommand()
            return
        }
        await buildSystem.build(project: project, console: self, entryFile: entryFileOverride)
        refreshExplorer()
    }

    func runProject(entryFileOverride: String? = nil) async {
        await buildProject(entryFileOverride: entryFileOverride)
        guard let result = buildSystem.lastResult, result.success, let romURL = result.romURL else {
            return
        }
        launchEmulator(romURL: romURL)
    }

    /// Runs a single .asm file as the build entry point, overriding the project's
    /// configured main source file for this run only. `relativePath` is a
    /// project-root-relative path (e.g. "src/main.asm").
    func runFile(atPath relativePath: String) async {
        await runProject(entryFileOverride: (relativePath as NSString).lastPathComponent)
    }

    /// Switches to the Cartridge tab and flags the Build section so the user can
    /// fill in the command/ROM name before building/running is possible.
    private func promptForBuildCommand() {
        appendConsole(String(localized: "Build command or ROM name not set — configure them in the Cartridge tab"), type: .error)
        setLevel(.hardware)
        selectSubTab("cartouche")
        showBuildCommandPrompt = true
    }

    private func launchEmulator(romURL: URL) {
        guard let path = UserDefaults.standard.string(forKey: SettingsView.emulatorPathKey), !path.isEmpty else {
            appendConsole(String(localized: "No emulator configured — set one in Settings"), type: .warning)
            return
        }
        let configuredURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: configuredURL.path) else {
            appendConsole(String(localized: "Emulator not found at \(path) — check Settings"), type: .error)
            return
        }

        // A .app bundle isn't directly executable — resolve it to the Mach-O binary
        // inside Contents/MacOS/. If the configured path is already that binary
        // (or any other command-line tool), use it as-is.
        let executableURL = configuredURL.pathExtension == "app"
            ? (Bundle(url: configuredURL)?.executableURL ?? configuredURL)
            : configuredURL

        let template = UserDefaults.standard.string(forKey: SettingsView.emulatorArgumentsKey) ?? "{rom}"
        let arguments = parseArguments(template.isEmpty ? "{rom}" : template)
            .map { $0.replacingOccurrences(of: "{rom}", with: romURL.path) }

        appendConsole(String(localized: "Launching \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))…"), type: .command)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            appendConsole(String(localized: "Failed to launch emulator: \(error.localizedDescription)"), type: .error)
        }
    }

    /// Splits a launch-argument template into tokens, honoring single/double quotes
    /// so paths containing spaces can be quoted.
    private func parseArguments(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quoteChar: Character?
        for char in raw {
            if let q = quoteChar {
                if char == q { quoteChar = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quoteChar = char
            } else if char.isWhitespace {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }
}
