import SwiftUI

/// Read-only preview for image files (.png, .jpg, .jpeg) opened from the Explorer.
struct ImagePreviewView: View {
    let state: AppState
    let fileID: String

    private var nsImage: NSImage? {
        guard let url = state.fileURL(for: fileID) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let nsImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding()
                }
            } else {
                Spacer()
                Text("Could not load image")
                    .font(.system(size: 13))
                    .foregroundStyle(SNESTheme.textDisabled)
                Spacer()
            }

            // Status bar, matching CodeEditorView's
            HStack(spacing: 0) {
                Text(fileID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SNESTheme.textDisabled)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(SNESTheme.bgPanel)
            .overlay(alignment: .top) {
                SNESTheme.border.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SNESTheme.bgEditor)
    }
}
