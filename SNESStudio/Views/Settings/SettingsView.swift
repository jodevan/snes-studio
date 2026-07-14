import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var saved: Bool = false
    @State private var selectedLanguage: AppLanguage = .system
    @State private var needsRestart: Bool = false
    @State private var emulatorPath: String = ""
    @State private var emulatorArguments: String = ""

    private let keychainKey = "anthropic_api_key"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Language")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SNESTheme.textPrimary)

                    Picker("", selection: $selectedLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .onChange(of: selectedLanguage) { _, newValue in
                        newValue.apply()
                        needsRestart = true
                    }

                    if needsRestart {
                        Label("Restart the app to apply the new language", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(SNESTheme.warning)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Anthropic API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SNESTheme.textPrimary)

                    Text("Required for the built-in AI assistant. Get a key at console.anthropic.com")
                        .font(.system(size: 11))
                        .foregroundStyle(SNESTheme.textSecondary)

                    HStack(spacing: 8) {
                        Group {
                            if showKey {
                                TextField("sk-ant-...", text: $apiKey)
                            } else {
                                SecureField("sk-ant-...", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(SNESTheme.textSecondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack {
                        Button("Save") {
                            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                KeychainHelper.delete(key: keychainKey)
                            } else {
                                KeychainHelper.save(key: keychainKey, value: trimmed)
                            }
                            saved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                saved = false
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SNESTheme.success)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Emulator")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SNESTheme.textPrimary)

                    Text("App used to launch the built ROM with Build & Run")
                        .font(.system(size: 11))
                        .foregroundStyle(SNESTheme.textSecondary)

                    HStack(spacing: 8) {
                        TextField("/Applications/Snes9x.app", text: $emulatorPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: emulatorPath) { _, _ in
                                saveEmulatorPath()
                            }

                        Button("Choose…") {
                            chooseEmulator()
                        }
                    }

                    Text("Launch Arguments")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SNESTheme.textPrimary)
                        .padding(.top, 4)

                    Text("Use {rom} for the built ROM's path. Leave blank to just pass the ROM path as the only argument.")
                        .font(.system(size: 11))
                        .foregroundStyle(SNESTheme.textSecondary)

                    TextField("-loadrom {rom}", text: $emulatorArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: emulatorArguments) { _, _ in
                            saveEmulatorArguments()
                        }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 480)
        .onAppear {
            apiKey = KeychainHelper.read(key: keychainKey) ?? ""
            selectedLanguage = AppLanguage.current
            emulatorPath = UserDefaults.standard.string(forKey: Self.emulatorPathKey) ?? ""
            emulatorArguments = UserDefaults.standard.string(forKey: Self.emulatorArgumentsKey) ?? ""
        }
    }

    static let emulatorPathKey = "emulatorPath"
    static let emulatorArgumentsKey = "emulatorArguments"

    private func chooseEmulator() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            emulatorPath = url.path
            saveEmulatorPath()
        }
    }

    private func saveEmulatorPath() {
        var trimmed = emulatorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        trimmed = NSString(string: trimmed).expandingTildeInPath
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.emulatorPathKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.emulatorPathKey)
        }
    }

    private func saveEmulatorArguments() {
        let trimmed = emulatorArguments.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.emulatorArgumentsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.emulatorArgumentsKey)
        }
    }
}

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case fr
    case es

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System default")
        case .en:     "English"
        case .fr:     "Français"
        case .es:     "Español"
        }
    }

    static var current: AppLanguage {
        guard let langs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let first = langs.first else {
            return .system
        }
        // UserDefaults may store "fr-FR" style — match prefix
        for lang in AppLanguage.allCases where lang != .system {
            if first.hasPrefix(lang.rawValue) { return lang }
        }
        return .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
