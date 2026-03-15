import AppKit
import Foundation
import PdfEditorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var session: DocumentSession
    @Published var errorMessage: String?

    init(session: DocumentSession = DocumentSession()) {
        self.session = session
    }

    var loadedURL: URL? {
        session.document?.descriptor.sourceURL
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try session.load(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDocument() {
        do {
            _ = try session.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = loadedURL?.lastPathComponent ?? "Edited.pdf"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            _ = try session.save(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockDocument(with password: String) {
        do {
            try session.unlock(with: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
