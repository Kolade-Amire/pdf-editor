import CoreGraphics
import Foundation

public protocol PDFEngine: AnyObject {
    func open(url: URL) throws -> LoadedPDFDocument
    func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument
    func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage
    func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock]
    func extractEditableRuns(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextRun]
    func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws
    func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport
    func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult
    func validate(_ fileURL: URL) throws -> ValidationReport
}

package struct PageAnalysisResult: Sendable {
    package let blocks: [EditableTextBlock]
    package let report: PageEditabilityReport

    package init(blocks: [EditableTextBlock], report: PageEditabilityReport) {
        self.blocks = blocks
        self.report = report
    }
}

package protocol PageAnalysisProvidingPDFEngine: PDFEngine {
    func extractPageAnalysis(from document: LoadedPDFDocument, pageIndex: Int) throws -> PageAnalysisResult
}

public extension PDFEngine {
    func extractEditableRuns(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextRun] {
        try extractEditableBlocks(from: document, pageIndex: pageIndex)
            .flatMap(\.displayRuns)
    }
}
