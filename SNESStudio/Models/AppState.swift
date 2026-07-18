import SwiftUI
import AppKit

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

    // MARK: - Tabs (kept for screen tab tracking)
    var tabManager = TabManager()

    // MARK: - Explorer / open files
    /// Files currently open in the LOGIQUE tab bar, as paths relative to the project root.
    var openFiles: [String] = []
    var explorerRefreshToken: Int = 0

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
        }
        activeSubTabID[.logique] = relativePath
    }

    func closeFile(_ relativePath: String) {
        openFiles.removeAll { $0 == relativePath }
        if activeSubTabID[.logique] == relativePath {
            activeSubTabID[.logique] = openFiles.last ?? ""
        }
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

        // Open the first source file by default
        openFiles = []
        if let first = sourceFiles.first {
            let path = "src/\(first)"
            openFiles = [path]
            activeSubTabID[.logique] = path
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

    func buildProject() async {
        guard let project = projectManager.currentProject else {
            appendConsole(String(localized: "No project open"), type: .error)
            return
        }
        await buildSystem.build(project: project, console: self)
        refreshExplorer()
    }

    func runProject() async {
        await buildProject()
        guard let result = buildSystem.lastResult, result.success, let romURL = result.romURL else {
            return
        }
        launchEmulator(romURL: romURL)
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
