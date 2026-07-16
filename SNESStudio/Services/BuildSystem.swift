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

    // MARK: - Build

    @MainActor
    func build(project: SNESProject, console: AppState) async {
        guard !isBuilding else { return }
        guard let projectPath = project.projectPath else {
            console.appendConsole(String(localized: "Project path not defined"), type: .error)
            return
        }

        let template = project.buildSettings.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            console.appendConsole(String(localized: "No build command configured — set one in the Cartridge tab"), type: .error)
            return
        }

        isBuilding = true
        let startTime = Date()
        var errors: [BuildError] = []

        console.appendConsole(String(localized: "=== Build \(project.name) ==="), type: .info)

        let srcDir = projectPath.appendingPathComponent("src")
        let buildDir = projectPath.appendingPathComponent("build")
        let outputFile = buildDir.appendingPathComponent(project.buildSettings.romName)

        // Build entry point. Falls back to the alphabetically first source file
        // if unset or if the configured file no longer exists in the project.
        let configuredMainFile = project.buildSettings.mainSourceFile
            .flatMap { project.sourceFiles.contains($0) ? $0 : nil }
        guard let mainSourceFile = configuredMainFile ?? project.sourceFiles.first else {
            console.appendConsole(String(localized: "No source files found in project"), type: .error)
            isBuilding = false
            return
        }

        let mainSrcFile = srcDir.appendingPathComponent(mainSourceFile)
        guard FileManager.default.fileExists(atPath: mainSrcFile.path) else {
            console.appendConsole(String(localized: "Main source file not found: \(mainSourceFile)"), type: .error)
            isBuilding = false
            return
        }

        let objectFileName = (mainSourceFile as NSString).deletingPathExtension + ".o"
        let objectFile = buildDir.appendingPathComponent(objectFileName)

        // Create build directory
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // Some tools (e.g. asar) treat an existing output file as a ROM to patch
        // and validate its current header before writing, so stale artifacts from
        // a previous failed build would keep failing every subsequent build even
        // after the source is fixed.
        try? FileManager.default.removeItem(at: outputFile)
        try? FileManager.default.removeItem(at: objectFile)

        console.appendConsole(String(localized: "Build directory: \(buildDir.path)"), type: .info)
        console.appendConsole(String(localized: "Output file: \(outputFile.path)"), type: .info)

        let command = template
            .replacingOccurrences(of: "{entry_file}", with: mainSrcFile.path)
            .replacingOccurrences(of: "{object_file}", with: objectFile.path)
            .replacingOccurrences(of: "{rom_name}", with: outputFile.path)
            .replacingOccurrences(of: "{src_folder}", with: srcDir.path)
            .replacingOccurrences(of: "{build_folder}", with: buildDir.path)

        console.appendConsole(String(localized: "$ \(command)"), type: .command)
        // Run through a shell so operators like && and ; work the same way they
        // would if the user typed the command in a terminal.
        let (output, exitCode) = await runProcess("/bin/sh", arguments: ["-c", command], workingDirectory: projectPath)

        // Log the raw output for debugging
        if !output.isEmpty {
            console.appendConsole(String(localized: "Build output:"), type: .info)
            console.appendConsole(output, type: .info)
        }

        if exitCode != 0 {
            let exitCodeText = String(exitCode)
            console.appendConsole(String(localized: "Build command exited with code \(exitCodeText)"), type: .error)
            let parsed = parseBuildErrors(output, sourceFile: mainSourceFile)
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
        let romExists = FileManager.default.fileExists(atPath: outputFile.path)
        let success = !errors.contains(where: { $0.severity == .error }) && exitCode == 0 && romExists

        var romSize = 0
        if success {
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
            let romSizeText = String(romSize)
            let durationText = String(format: "%.2f", duration)
            console.appendConsole(String(localized: "BUILD SUCCEEDED — \(romSizeText) bytes (\(durationText)s)"), type: .success)
            console.appendConsole(String(localized: "Output: \(outputFile.path)"), type: .success)
        } else if exitCode == 0 && !romExists {
            console.appendConsole(String(localized: "BUILD FAILED — command exited successfully but did not produce \(outputFile.lastPathComponent)"), type: .error)
        } else {
            let errorCountText = String(errors.count)
            let durationText = String(format: "%.2f", duration)
            console.appendConsole(String(localized: "BUILD FAILED — \(errorCountText) error(s) (\(durationText)s)"), type: .error)
        }
    }

    // MARK: - Parse errors

    private func parseBuildErrors(_ output: String, sourceFile: String) -> [BuildError] {
        // Common compiler/assembler error format: filename:line: error: message
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
}
