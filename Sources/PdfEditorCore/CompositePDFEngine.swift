import CoreGraphics
import Foundation

public final class CompositePDFEngine: PDFEngine, PageAnalysisProvidingPDFEngine {
    private let muPDFEngine: MuPDFBridgeEngine
    private var engineByDocumentID: [UUID: PDFEngine] = [:]

    public init(muPDFEngine: MuPDFBridgeEngine = MuPDFBridgeEngine()) {
        self.muPDFEngine = muPDFEngine
    }

    public func open(url: URL) throws -> LoadedPDFDocument {
        if MuPDFBridgeEngine.isAvailable {
            do {
                let document = try muPDFEngine.open(url: url)
                engineByDocumentID[document.id] = muPDFEngine
                return document
            } catch {
                let fallbackEngine = PDFKitEngine(
                    readOnlyReason: "MuPDF could not open this file for safe editing (\(error.localizedDescription)). PDFKit opened it in read-only fallback mode."
                )
                let document = try fallbackEngine.open(url: url)
                engineByDocumentID[document.id] = fallbackEngine
                return document
            }
        }

        let fallbackEngine = PDFKitEngine(
            readOnlyReason: "MuPDF is not built for this checkout yet, so PDFKit opened the file in read-only fallback mode."
        )
        let document = try fallbackEngine.open(url: url)
        engineByDocumentID[document.id] = fallbackEngine
        return document
    }

    public func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        let engine = try engine(for: document)
        return try engine.unlock(document, password: password)
    }

    public func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        let engine = try engine(for: document)
        return try engine.renderPage(of: document, pageIndex: pageIndex, scale: scale)
    }

    public func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        try extractPageAnalysis(from: document, pageIndex: pageIndex).blocks
    }

    public func extractEditableRuns(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextRun] {
        let engine = try engine(for: document)
        return try engine.extractEditableRuns(from: document, pageIndex: pageIndex)
    }

    public func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        let engine = try engine(for: document)
        try engine.applyEdits(edits, to: document)
    }

    public func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport {
        let engine = try engine(for: document)
        return try engine.preflightSave(edits, for: document)
    }

    public func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult {
        let engine = try engine(for: document)
        return try engine.save(document, to: url, mode: mode, allowOverlayFallback: allowOverlayFallback)
    }

    public func validate(_ fileURL: URL) throws -> ValidationReport {
        if MuPDFBridgeEngine.isAvailable {
            return try muPDFEngine.validate(fileURL)
        }

        return try PDFKitEngine().validate(fileURL)
    }

    package func extractPageAnalysis(from document: LoadedPDFDocument, pageIndex: Int) throws -> PageAnalysisResult {
        let engine = try engine(for: document)

        if let pageAnalysisEngine = engine as? any PageAnalysisProvidingPDFEngine {
            return try pageAnalysisEngine.extractPageAnalysis(from: document, pageIndex: pageIndex)
        }

        let blocks = try engine.extractEditableBlocks(from: document, pageIndex: pageIndex)
        return PageAnalysisResult(
            blocks: blocks,
            report: PageEditabilityReport(
                pageIndex: pageIndex,
                isEditable: blocks.contains(where: \.isEditable),
                issues: blocks.compactMap(\.failureReason)
            )
        )
    }

    private func engine(for document: LoadedPDFDocument) throws -> PDFEngine {
        guard let engine = engineByDocumentID[document.id] else {
            throw PDFEditorError.missingDocument
        }

        return engine
    }
}
