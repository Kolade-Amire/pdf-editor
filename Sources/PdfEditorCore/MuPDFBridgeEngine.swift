import CPdfEngineBridge
import CoreGraphics
import Foundation

public final class MuPDFBridgeEngine: PDFEngine {
    public static var isAvailable: Bool {
        pdf_engine_bridge_is_available()
    }

    public init() {}

    public func open(url: URL) throws -> LoadedPDFDocument {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func save(_ document: LoadedPDFDocument, to url: URL, mode: SaveMode) throws -> SaveResult {
        throw PDFEditorError.unsupportedEngine("MuPDF bridge sources are not built yet.")
    }

    public func validate(_ fileURL: URL) throws -> ValidationReport {
        if let qpdf = PDFKitEngine.findQPDF() {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = qpdf
            process.arguments = ["--check", fileURL.path]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let messages = [stdout, stderr]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            return ValidationReport(
                isValid: process.terminationStatus == 0,
                validator: "qpdf",
                messages: messages.isEmpty ? ["qpdf reported no issues."] : messages
            )
        }

        return ValidationReport(
            isValid: false,
            validator: "MuPDF bridge",
            messages: ["MuPDF validation is unavailable until the vendored bridge is built."]
        )
    }
}
