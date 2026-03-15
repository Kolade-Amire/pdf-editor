import Foundation
import XCTest
@testable import PdfEditorCore

@MainActor
final class DocumentSessionTests: XCTestCase {
    func testEditableBlockStagesPendingEditAndSaves() throws {
        let url = URL(fileURLWithPath: "/tmp/sample.pdf")
        let block = makeBlock(
            blockID: "block-1",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Original"
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [block]])
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.selectBlock("block-1")
        session.updateDraftText("Updated")

        XCTAssertEqual(session.pendingEdits["block-1"]?.replacementText, "Updated")

        let result = try session.save()

        XCTAssertEqual(result.appliedEditCount, 1)
        XCTAssertEqual(engine.savedURLs, [url])
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.document?.descriptor.sourceURL, url)
    }

    func testReadOnlyBlockCannotBeEdited() throws {
        let url = URL(fileURLWithPath: "/tmp/readonly.pdf")
        let issue = EditabilityIssue(kind: .rightsRestricted, message: "Read-only block.")
        let block = makeBlock(
            blockID: "locked-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Original",
            isEditable: false,
            failureReason: issue
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [block]], isEditable: false)
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.selectBlock("locked-block")
        session.updateDraftText("Nope")

        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.draftText, "Original")
        XCTAssertEqual(session.statusMessage, "Read-only block.")
    }

    func testOverflowingBlockTextIsRejectedOnSave() throws {
        let url = URL(fileURLWithPath: "/tmp/overflow.pdf")
        let block = makeBlock(
            blockID: "tight-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 16, height: 10),
            originalText: "OK"
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [block]])
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.selectBlock("tight-block")
        session.updateDraftText("This text is too long for the box")

        XCTAssertThrowsError(try session.save()) { error in
            XCTAssertEqual(error as? PDFEditorError, .textDoesNotFit(blockID: "tight-block"))
        }
    }

    private func makeBlock(
        blockID: String,
        pageIndex: Int,
        bounds: CGRect,
        originalText: String,
        isEditable: Bool = true,
        failureReason: EditabilityIssue? = nil
    ) -> EditableTextBlock {
        let style = TextStyle(fontPostScriptName: "Helvetica", fontSize: 12, color: .black)
        let fragment = BlockLineFragment(
            id: "\(blockID):line:0",
            blockID: blockID,
            pageIndex: pageIndex,
            bounds: bounds,
            quads: [TextQuad.rect(bounds)],
            originalText: originalText,
            currentText: originalText,
            style: style,
            isEditable: isEditable,
            failureReason: failureReason
        )

        return EditableTextBlock(
            id: blockID,
            pageIndex: pageIndex,
            bounds: bounds,
            originalText: originalText,
            currentText: originalText,
            style: style,
            lineFragments: [fragment],
            isEditable: isEditable,
            failureReason: failureReason,
            fallbackPlan: FontFallbackPlan(
                requestedFontPostScriptName: "Helvetica",
                resolvedFontName: "Helvetica",
                family: .sans,
                source: .originalFont
            )
        )
    }
}

private final class MockPDFEngine: PDFEngine {
    var document: LoadedPDFDocument
    var blocksByPage: [Int: [EditableTextBlock]]
    var savedURLs: [URL] = []

    init(url: URL, blocksByPage: [Int: [EditableTextBlock]], isEditable: Bool = true) {
        let pageReports = blocksByPage.keys.sorted().map { pageIndex in
            PageEditabilityReport(pageIndex: pageIndex, isEditable: isEditable, issues: [])
        }
        let report = EditabilityReport(isEditable: isEditable, issues: [], pageReports: pageReports)
        self.document = LoadedPDFDocument(
            id: UUID(),
            descriptor: PDFDocumentDescriptor(
                sourceURL: url,
                pageCount: max(blocksByPage.keys.max().map { $0 + 1 } ?? 0, 1),
                title: url.lastPathComponent,
                isEncrypted: false,
                isLocked: false,
                canEdit: isEditable,
                isSigned: false,
                backend: .muPDFEditable
            ),
            editabilityReport: report
        )
        self.blocksByPage = blocksByPage
    }

    func open(url: URL) throws -> LoadedPDFDocument {
        document
    }

    func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        document
    }

    func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        throw PDFEditorError.unsupportedEngine("Rendering is not used in unit tests.")
    }

    func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        blocksByPage[pageIndex] ?? []
    }

    func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        let replacements = Dictionary(uniqueKeysWithValues: edits.map { ($0.blockID, $0.replacementText) })

        blocksByPage = blocksByPage.mapValues { blocks in
            blocks.map { block in
                guard let replacement = replacements[block.id] else {
                    return block
                }

                let fragments = block.lineFragments.map {
                    BlockLineFragment(
                        id: $0.id,
                        blockID: $0.blockID,
                        pageIndex: $0.pageIndex,
                        bounds: $0.bounds,
                        quads: $0.quads,
                        originalText: $0.originalText,
                        currentText: replacement,
                        style: $0.style,
                        isEditable: $0.isEditable,
                        failureReason: $0.failureReason
                    )
                }

                return EditableTextBlock(
                    id: block.id,
                    pageIndex: block.pageIndex,
                    bounds: block.bounds,
                    originalText: block.originalText,
                    currentText: replacement,
                    style: block.style,
                    lineFragments: fragments,
                    isEditable: block.isEditable,
                    failureReason: block.failureReason,
                    fallbackPlan: block.fallbackPlan
                )
            }
        }
    }

    func save(_ document: LoadedPDFDocument, to url: URL, mode: SaveMode) throws -> SaveResult {
        savedURLs.append(url)
        self.document = LoadedPDFDocument(
            id: document.id,
            descriptor: PDFDocumentDescriptor(
                sourceURL: url,
                pageCount: document.descriptor.pageCount,
                title: document.descriptor.title,
                isEncrypted: false,
                isLocked: false,
                canEdit: document.editabilityReport.isEditable,
                isSigned: false,
                backend: document.descriptor.backend
            ),
            editabilityReport: document.editabilityReport
        )

        return SaveResult(
            fileURL: url,
            usedSaveMode: .fullRewrite,
            appliedEditCount: blocksByPage.values.joined().filter { $0.currentText != $0.originalText }.count,
            validationReport: ValidationReport(isValid: true, validator: "Mock", messages: [])
        )
    }

    func validate(_ fileURL: URL) throws -> ValidationReport {
        ValidationReport(isValid: true, validator: "Mock", messages: [])
    }
}
