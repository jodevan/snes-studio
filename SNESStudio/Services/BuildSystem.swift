import Foundation

struct BuildError: Identifiable {
    let id = UUID()
    let file: String
    let line: Int
    let column: Int
    let message: String
    let severity: Severity

    enum Severity { case error, warning }
}

struct BuildResult {
    let success: Bool
    let romURL: URL?
    let romSize: Int
    let errors: [BuildError]
    let duration: TimeInterval
}

@Observable
final class BuildSystem {
    var isBuilding = false
    var lastResult: BuildResult?

    private var asarPath: String?

    init() {
        detectTools()
    }

    // MARK: - Detect asar

    private func detectTools() {
        asarPath = findTool("asar")
    }

    private func findTool(_ name: String) -> String? {
        // First, try using 'which' with a full shell environment
        // This sources the user's shell profile to get the complete PATH
        let whichCommand = """
        if [ -f ~/.zshrc ]; then source ~/.zshrc; fi
        if [ -f ~/.bash_profile ]; then source ~/.bash_profile; fi
        if [ -f ~/.bashrc ]; then source ~/.bashrc; fi
        which \(name)
        """
        
        let result = shell(whichCommand)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
            return trimmed
        }
        
        // Fallback: Check common installation paths
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "~/bin/\(name)",
            "~/.local/bin/\(name)",
        ]
        for path in paths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                return expandedPath
            }
        }
        
        return nil
    }

    var toolsAvailable: Bool {
        asarPath != nil
    }

    // MARK: - Build

    @MainActor
    func build(project: SNESProject, console: AppState) async {
        guard !isBuilding else { return }
        guard let asar = asarPath else {
            console.appendConsole("asar not found. Please install asar and ensure it's in your PATH", type: .error)
            console.appendConsole("Searched locations:", type: .info)
            console.appendConsole("  - /opt/homebrew/bin/asar", type: .info)
            console.appendConsole("  - /usr/local/bin/asar", type: .info)
            console.appendConsole("  - /usr/bin/asar", type: .info)
            console.appendConsole("  - ~/bin/asar", type: .info)
            console.appendConsole("  - ~/.local/bin/asar", type: .info)
            console.appendConsole("Run 'which asar' in Terminal to find its location", type: .info)
            return
        }
        guard let projectPath = project.projectPath else {
            console.appendConsole("Project path not defined", type: .error)
            return
        }

        isBuilding = true
        let startTime = Date()
        var errors: [BuildError] = []

        console.appendConsole("=== Build \(project.name) ===", type: .info)
        console.appendConsole("Using asar at: \(asar)", type: .info)

        let srcDir = projectPath.appendingPathComponent("src")
        let buildDir = projectPath.appendingPathComponent("build")
        let outputName = project.buildSettings.outputName
        let outputFile = buildDir.appendingPathComponent("\(outputName).\(project.buildSettings.outputFormat)")

        // Create build directory
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // asar treats an existing output file as a ROM to patch and validates its
        // current header before writing, so a stale file from a failed build would
        // keep failing every subsequent build even after the source is fixed.
        try? FileManager.default.removeItem(at: outputFile)

        console.appendConsole("Build directory: \(buildDir.path)", type: .info)
        console.appendConsole("Output file: \(outputFile.path)", type: .info)

        // asar assembles all files in one pass, typically starting from a main file
        // Find the main source file (usually the first one or one named "main.asm")
        guard let mainSourceFile = project.sourceFiles.first else {
            console.appendConsole("No source files found in project", type: .error)
            isBuilding = false
            return
        }

        let mainSrcFile = srcDir.appendingPathComponent(mainSourceFile)
        guard FileManager.default.fileExists(atPath: mainSrcFile.path) else {
            console.appendConsole("Main source file not found: \(mainSourceFile)", type: .error)
            isBuilding = false
            return
        }

        // asar arguments: asar [options] source_file output_file
        var args = [
            mainSrcFile.path,
            outputFile.path,
        ]
        
        // Add debug symbols if enabled
        if project.buildSettings.generateDebugSymbols {
            args.insert("--symbols=wla", at: 0)
        }

        console.appendConsole("$ asar \(args.joined(separator: " "))", type: .command)
        let (output, exitCode) = await runProcess(asar, arguments: args, workingDirectory: projectPath)
        
        // Log the raw output for debugging
        if !output.isEmpty {
            console.appendConsole("asar output:", type: .info)
            console.appendConsole(output, type: .info)
        }

        if exitCode != 0 {
            console.appendConsole("asar exited with code \(exitCode)", type: .error)
            let parsed = parseAsarErrors(output, sourceFile: mainSourceFile)
            errors.append(contentsOf: parsed)
            for err in parsed {
                console.appendConsole(
                    "\(err.file):\(err.line): \(err.severity == .error ? "Error" : "Warning"): \(err.message)",
                    type: err.severity == .error ? .error : .warning,
                    fileRef: FileReference(file: err.file, line: err.line, column: err.column)
                )
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        let success = !errors.contains(where: { $0.severity == .error }) && exitCode == 0

        var romSize = 0
        if success, FileManager.default.fileExists(atPath: outputFile.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputFile.path) {
                romSize = (attrs[.size] as? Int) ?? 0
            }

            // Fix checksum if enabled
            if project.buildSettings.fixChecksum {
                fixChecksum(at: outputFile, mapping: project.cartridge.mapping)
            }
        }

        let result = BuildResult(
            success: success,
            romURL: success ? outputFile : nil,
            romSize: romSize,
            errors: errors,
            duration: duration
        )
        lastResult = result
        isBuilding = false

        if success {
            console.appendConsole("BUILD SUCCEEDED — \(romSize) bytes (\(String(format: "%.2f", duration))s)", type: .success)
            console.appendConsole("Output: \(outputFile.path)", type: .success)
        } else {
            console.appendConsole("BUILD FAILED — \(errors.count) error(s) (\(String(format: "%.2f", duration))s)", type: .error)
        }
    }

    // MARK: - Parse errors

    private func parseAsarErrors(_ output: String, sourceFile: String) -> [BuildError] {
        // asar error format: filename:line: error: message
        // or: filename:line:col: error: message
        // or: warning: message
        var errors: [BuildError] = []
        
        let pattern = #"(.+?):(\d+)(?::(\d+))?:\s*(error|warning):\s*(.+)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        
        for line in output.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }
            
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex?.firstMatch(in: line, range: range) {
                let file = (line as NSString).substring(with: match.range(at: 1))
                let lineNum = Int((line as NSString).substring(with: match.range(at: 2))) ?? 0
                let colNum = match.range(at: 3).location != NSNotFound ? 
                    Int((line as NSString).substring(with: match.range(at: 3))) ?? 0 : 0
                let severityStr = (line as NSString).substring(with: match.range(at: 4))
                let message = (line as NSString).substring(with: match.range(at: 5))
                
                errors.append(BuildError(
                    file: URL(fileURLWithPath: file).lastPathComponent,
                    line: lineNum,
                    column: colNum,
                    message: message,
                    severity: severityStr.lowercased() == "warning" ? .warning : .error
                ))
            } else {
                // Generic error without file/line info
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().contains("error") || trimmed.lowercased().contains("warning") {
                    errors.append(BuildError(
                        file: sourceFile,
                        line: 0,
                        column: 0,
                        message: trimmed,
                        severity: trimmed.lowercased().contains("warning") ? .warning : .error
                    ))
                }
            }
        }
        
        // If no specific errors were parsed but output exists, treat as generic error
        if errors.isEmpty && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(BuildError(
                file: sourceFile,
                line: 0,
                column: 0,
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                severity: .error
            ))
        }
        
        return errors
    }

    // MARK: - Checksum fix

    private func fixChecksum(at url: URL, mapping: ROMMapping) {
        guard var data = try? Data(contentsOf: url) else { return }
        guard data.count >= 0x10000 else { return }

        // Pad to power of 2 if needed
        var targetSize = 1
        while targetSize < data.count { targetSize <<= 1 }
        if data.count < targetSize {
            data.append(Data(count: targetSize - data.count))
        }

        // Calculate checksum
        var checksum: UInt16 = 0
        for byte in data {
            checksum = checksum &+ UInt16(byte)
        }
        let complement = checksum ^ 0xFFFF

        // Write at header location (varies by mapping)
        let headerBase: Int
        switch mapping {
        case .loROM:   headerBase = 0x7FDC
        case .hiROM, .exHiROM, .sa1: headerBase = 0xFFDC
        }

        guard data.count > headerBase + 3 else { return }
        data[headerBase]     = UInt8(complement & 0xFF)
        data[headerBase + 1] = UInt8(complement >> 8)
        data[headerBase + 2] = UInt8(checksum & 0xFF)
        data[headerBase + 3] = UInt8(checksum >> 8)

        try? data.write(to: url)
    }

    // MARK: - Process helpers

    private func runProcess(_ path: String, arguments: [String], workingDirectory: URL) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                
                // Set up environment with common PATH locations
                var environment = ProcessInfo.processInfo.environment
                let additionalPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    NSString(string: "~/bin").expandingTildeInPath,
                    NSString(string: "~/.local/bin").expandingTildeInPath,
                ]
                let currentPath = environment["PATH"] ?? ""
                let newPath = (additionalPaths + [currentPath]).joined(separator: ":")
                environment["PATH"] = newPath
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    // Tool output can embed raw binary (e.g. asar echoing back an invalid
                    // ROM title from the cartridge header), which fails strict UTF-8
                    // decoding. Decode lossily so diagnostics are never silently dropped.
                    let output = String(decoding: data, as: UTF8.self)
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: (error.localizedDescription, -1))
                }
            }
        }
    }

    private func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
