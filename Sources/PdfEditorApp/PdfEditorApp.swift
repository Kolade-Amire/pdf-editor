import PdfEditorCore
import SwiftUI

@main
struct PdfEditorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            EditorRootView(appState: appState)
                .frame(minWidth: 1100, minHeight: 700)
                .alert("Error", isPresented: Binding(
                    get: { appState.errorMessage != nil },
                    set: { if !$0 { appState.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(appState.errorMessage ?? "Unknown error")
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    appState.openDocument()
                }
                .keyboardShortcut("o")
            }

            CommandMenu("PDF Editor") {
                Button("Save") {
                    appState.saveDocument()
                }
                .keyboardShortcut("s")
                .disabled(!appState.session.canSave)

                Button("Save As…") {
                    appState.saveDocumentAs()
                }
                .keyboardShortcut("S")
                .disabled(appState.session.document == nil)
            }
        }
        Settings {
            SettingsView()
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PDF Editor")
                .font(.title2.bold())
            Text("MuPDF bridge files can replace the current PDFKit engine without changing the app layer.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
