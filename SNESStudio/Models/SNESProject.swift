import Foundation

// MARK: - Build Settings

struct BuildSettings: Codable, Equatable {
    static let defaultBuildCommand = "asar {entry_file} {rom_name}"

    /// Final ROM filename, including extension (e.g. "game.sfc").
    var romName: String = "game.sfc"
    /// Command run to produce the ROM. Supports {entry_file}, {object_file},
    /// and {rom_name} placeholders, substituted with absolute paths at build time.
    var buildCommand: String = defaultBuildCommand
    var fixChecksum: Bool = true
    /// Source file passed to the build command as the build entry point.
    /// When nil, falls back to the alphabetically first source file.
    var mainSourceFile: String?

    private enum CodingKeys: String, CodingKey {
        case romName, buildCommand, fixChecksum, mainSourceFile
        // Legacy keys from before romName/buildCommand existed
        case legacyOutputName = "outputName"
        case legacyOutputFormat = "outputFormat"
    }

    init() {}

    // Custom decoding so projects saved before romName/buildCommand existed
    // (or before outputName/outputFormat were folded into romName) still load,
    // carrying their previously configured output name/format forward.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let romName = try container.decodeIfPresent(String.self, forKey: .romName) {
            self.romName = romName
        } else {
            let legacyName = try container.decodeIfPresent(String.self, forKey: .legacyOutputName) ?? "game"
            let legacyFormat = try container.decodeIfPresent(String.self, forKey: .legacyOutputFormat) ?? "sfc"
            romName = "\(legacyName).\(legacyFormat)"
        }
        buildCommand = try container.decodeIfPresent(String.self, forKey: .buildCommand) ?? Self.defaultBuildCommand
        fixChecksum = try container.decodeIfPresent(Bool.self, forKey: .fixChecksum) ?? true
        mainSourceFile = try container.decodeIfPresent(String.self, forKey: .mainSourceFile)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(romName, forKey: .romName)
        try container.encode(buildCommand, forKey: .buildCommand)
        try container.encode(fixChecksum, forKey: .fixChecksum)
        try container.encodeIfPresent(mainSourceFile, forKey: .mainSourceFile)
    }
}

// MARK: - SNES Project

struct SNESProject: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var author: String = ""
    var version: String = "0.1.0"
    var createdDate: Date = Date()
    var modifiedDate: Date = Date()
    var cartridge: CartridgeConfig
    var buildSettings: BuildSettings = BuildSettings()
    var sourceFiles: [String] = []
    var assetFiles: [String] = []

    // Not serialized — set at load time
    var projectPath: URL? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, author, version, createdDate, modifiedDate
        case cartridge, buildSettings, sourceFiles, assetFiles
    }

    // MARK: - Computed paths

    var projectFileURL: URL? {
        projectPath?.appendingPathComponent("\(name).snesproj")
    }

    var buildDirectoryURL: URL? {
        projectPath?.appendingPathComponent("build")
    }

    var sourceDirectoryURL: URL? {
        projectPath?.appendingPathComponent("src")
    }

    var assetsDirectoryURL: URL? {
        projectPath?.appendingPathComponent("assets")
    }

    var linkerConfigURL: URL? {
        projectPath?.appendingPathComponent(cartridge.linkerConfigName)
    }
}
