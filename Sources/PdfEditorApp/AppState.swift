import AppKit
import Foundation
import PdfEditorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    struct OverlaySaveRequest: Identifiable {
        let id = UUID()
        let destinationURL: URL?
        let report: SavePreflightReport
    }

    @Published var session: DocumentSession
    @Published var errorMessage: String?
    @Published var overlaySaveRequest: OverlaySaveRequest?

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
        attemptSave(to: nil)
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = loadedURL?.lastPathComponent ?? "Edited.pdf"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        attemptSave(to: url)
    }

    func unlockDocument(with password: String) {
        do {
            try session.unlock(with: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmOverlaySave() {
        guard let overlaySaveRequest else {
            return
        }

        do {
            _ = try session.save(to: overlaySaveRequest.destinationURL, allowOverlayFallback: true)
            self.overlaySaveRequest = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelOverlaySave() {
        overlaySaveRequest = nil
    }

    private func attemptSave(to url: URL?) {
        do {
            let report = try session.prepareSave(to: url)
            if report.blockedCount > 0 {
                errorMessage = report.blockOutcomes
                    .filter { $0.mode == .blocked }
                    .map(\.message)
                    .joined(separator: "\n")
                return
            }

            if report.requiresOverlayConfirmation {
                overlaySaveRequest = OverlaySaveRequest(destinationURL: url, report: report)
                return
            }

            _ = try session.save(to: url, allowOverlayFallback: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
