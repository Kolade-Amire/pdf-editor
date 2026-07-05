import Foundation
import XCTest
@testable import PdfEditorCore

@MainActor
final class DocumentSessionTests: XCTestCase {
    func testLoadIsMetadataFirstUntilBlocksAreRequested() throws {
        let url = URL(fileURLWithPath: "/tmp/metadata-first.pdf")
        let pageZeroBlock = makeBlock(
            blockID: "page-0-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 0"
        )
        let pageOneBlock = makeBlock(
            blockID: "page-1-block",
            pageIndex: 1,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 1"
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [pageZeroBlock], 1: [pageOneBlock]])
        let session = DocumentSession(engine: engine)

        try session.load(url: url)

        XCTAssertEqual(session.document?.descriptor.sourceURL, url)
        XCTAssertEqual(session.pageCount, 2)
        XCTAssertTrue(session.pageBlocks.isEmpty)
        XCTAssertEqual(session.pageLoadState(for: 0), .unloaded)
        XCTAssertTrue(engine.extractCallCountsByPage.isEmpty)
    }

    func testLoadCurrentPagePopulatesOnlyRequestedPage() throws {
        let url = URL(fileURLWithPath: "/tmp/lazy-page-load.pdf")
        let pageZeroBlock = makeBlock(
            blockID: "page-0-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 0"
        )
        let pageOneBlock = makeBlock(
            blockID: "page-1-block",
            pageIndex: 1,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 1"
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [pageZeroBlock], 1: [pageOneBlock]])
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.loadBlocksIfNeeded(for: 0)

        XCTAssertEqual(session.pageLoadState(for: 0), .loaded)
        XCTAssertEqual(session.pageLoadState(for: 1), .unloaded)
        XCTAssertEqual(session.currentPageReport?.pageIndex, 0)
        XCTAssertTrue(session.currentPageReport?.isEditable == true)
        XCTAssertEqual(session.pageBlocks[0]?.map(\.id), ["page-0-block"])
        XCTAssertNil(session.pageBlocks[1])
        XCTAssertEqual(engine.extractCallCountsByPage[0], 1)
        XCTAssertNil(engine.extractCallCountsByPage[1])
    }

    func testNavigatingToAnotherPageLoadsThatPageOnce() throws {
        let url = URL(fileURLWithPath: "/tmp/page-navigation.pdf")
        let pageZeroBlock = makeBlock(
            blockID: "page-0-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 0"
        )
        let pageOneBlock = makeBlock(
            blockID: "page-1-block",
            pageIndex: 1,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 1"
        )
        let engine = MockPDFEngine(url: url, blocksByPage: [0: [pageZeroBlock], 1: [pageOneBlock]])
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.loadBlocksIfNeeded(for: 0)
        session.loadBlocksIfNeeded(for: 0)
        session.loadBlocksIfNeeded(for: 1)

        XCTAssertEqual(engine.extractCallCountsByPage[0], 1)
        XCTAssertEqual(engine.extractCallCountsByPage[1], 1)

        session.reloadBlocks(for: 1)
        XCTAssertEqual(engine.extractCallCountsByPage[1], 2)
    }

    func testPageExtractionFailureKeepsDocumentOpen() throws {
        let url = URL(fileURLWithPath: "/tmp/page-failure.pdf")
        let block = makeBlock(
            blockID: "page-0-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Page 0"
        )
        let engine = MockPDFEngine(
            url: url,
            blocksByPage: [0: [block]],
            pageExtractionErrors: [1: PDFEditorError.saveFailed("Page 2 failed.")]
        )
        engine.document = LoadedPDFDocument(
            id: engine.document.id,
            descriptor: PDFDocumentDescriptor(
                sourceURL: url,
                pageCount: 2,
                title: url.lastPathComponent,
                isEncrypted: false,
                isLocked: false,
                canEdit: true,
                isSigned: false,
                backend: .muPDFEditable
            ),
            editabilityReport: EditabilityReport(
                isEditable: true,
                issues: [],
                pageReports: [
                    PageEditabilityReport(pageIndex: 0, isEditable: true, issues: []),
                    PageEditabilityReport(pageIndex: 1, isEditable: true, issues: []),
                ]
            )
        )
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.loadBlocksIfNeeded(for: 1)

        XCTAssertEqual(session.document?.descriptor.sourceURL, url)
        XCTAssertEqual(session.pageLoadState(for: 1), .failed(message: "Page 2 failed."))
        XCTAssertNil(session.pageReport(for: 1))
        XCTAssertEqual(session.pageBlocks[1], [])
        XCTAssertEqual(engine.extractCallCountsByPage[1], 1)
    }

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
        session.loadBlocksIfNeeded(for: 0)
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
        session.loadBlocksIfNeeded(for: 0)
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
        session.loadBlocksIfNeeded(for: 0)
        session.selectBlock("tight-block")
        session.updateDraftText("This text is too long for the box")

        XCTAssertThrowsError(try session.save()) { error in
            XCTAssertEqual(error as? PDFEditorError, .textDoesNotFit(blockID: "tight-block"))
        }
    }

    func testOverlayFallbackRequiresApprovalBeforeSave() throws {
        let url = URL(fileURLWithPath: "/tmp/overlay.pdf")
        let block = makeBlock(
            blockID: "overlay-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Original",
            persistenceMode: .overlayFallback,
            persistenceMessage: "Saving this block requires overlay fallback."
        )
        let engine = MockPDFEngine(
            url: url,
            blocksByPage: [0: [block]],
            preflightModesByBlockID: ["overlay-block": .overlayFallback]
        )
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.loadBlocksIfNeeded(for: 0)
        session.selectBlock("overlay-block")
        session.updateDraftText("Updated")

        let preflight = try session.prepareSave()
        XCTAssertTrue(preflight.requiresOverlayConfirmation)
        XCTAssertEqual(preflight.overlayFallbackCount, 1)

        XCTAssertThrowsError(try session.save()) { error in
            XCTAssertEqual(
                error as? PDFEditorError,
                .saveFailed("One or more edits require overlay fallback confirmation before save.")
            )
        }

        let result = try session.save(allowOverlayFallback: true)
        XCTAssertEqual(result.overlayFallbackCount, 1)
        XCTAssertEqual(engine.saveAllowOverlayFallbackFlags, [true])
    }

    func testPrepareSaveReportsBlockedEditsWithoutSaving() throws {
        let url = URL(fileURLWithPath: "/tmp/blocked.pdf")
        let issue = EditabilityIssue(kind: .unsupportedStructure, message: "This block cannot be rewritten safely.")
        let block = makeBlock(
            blockID: "blocked-block",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 120, height: 40),
            originalText: "Original",
            isEditable: true,
            failureReason: nil,
            persistenceMode: .blocked,
            persistenceMessage: issue.message
        )
        let engine = MockPDFEngine(
            url: url,
            blocksByPage: [0: [block]],
            preflightModesByBlockID: ["blocked-block": .blocked],
            preflightMessagesByBlockID: ["blocked-block": issue.message]
        )
        let session = DocumentSession(engine: engine)

        try session.load(url: url)
        session.loadBlocksIfNeeded(for: 0)
        session.selectBlock("blocked-block")
        session.updateDraftText("Updated")

        let report = try session.prepareSave()
        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.blockedCount, 1)
        XCTAssertEqual(session.statusMessage, issue.message)
        XCTAssertTrue(engine.savedURLs.isEmpty)
    }

    private func makeBlock(
        blockID: String,
        pageIndex: Int,
        bounds: CGRect,
        originalText: String,
        isEditable: Bool = true,
        failureReason: EditabilityIssue? = nil,
        persistenceMode: BlockPersistenceMode = .trueRewrite,
        persistenceMessage: String? = nil
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
            ),
            persistenceMode: persistenceMode,
            persistenceMessage: persistenceMessage
        )
    }
}

private final class MockPDFEngine: PDFEngine, PageAnalysisProvidingPDFEngine {
    var document: LoadedPDFDocument
    var blocksByPage: [Int: [EditableTextBlock]]
    var pageReportsByPage: [Int: PageEditabilityReport]
    var extractCallCountsByPage: [Int: Int] = [:]
    var savedURLs: [URL] = []
    var saveAllowOverlayFallbackFlags: [Bool] = []
    private let preflightModesByBlockID: [String: BlockPersistenceMode]
    private let preflightMessagesByBlockID: [String: String]
    private let pageExtractionErrors: [Int: Error]

    init(
        url: URL,
        blocksByPage: [Int: [EditableTextBlock]],
        isEditable: Bool = true,
        preflightModesByBlockID: [String: BlockPersistenceMode] = [:],
        preflightMessagesByBlockID: [String: String] = [:],
        pageExtractionErrors: [Int: Error] = [:]
    ) {
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
                backend: isEditable ? .muPDFEditable : .muPDFReadOnly
            ),
            editabilityReport: report
        )
        self.blocksByPage = blocksByPage
        self.pageReportsByPage = Dictionary(
            uniqueKeysWithValues: pageReports.map { ($0.pageIndex, $0) }
        )
        self.preflightModesByBlockID = preflightModesByBlockID
        self.preflightMessagesByBlockID = preflightMessagesByBlockID
        self.pageExtractionErrors = pageExtractionErrors
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
        try extractPageAnalysis(from: document, pageIndex: pageIndex).blocks
    }

    package func extractPageAnalysis(from document: LoadedPDFDocument, pageIndex: Int) throws -> PageAnalysisResult {
        extractCallCountsByPage[pageIndex, default: 0] += 1

        if let error = pageExtractionErrors[pageIndex] {
            throw error
        }

        return PageAnalysisResult(
            blocks: blocksByPage[pageIndex] ?? [],
            report: pageReportsByPage[pageIndex]
                ?? PageEditabilityReport(pageIndex: pageIndex, isEditable: false, issues: [])
        )
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
                    fallbackPlan: block.fallbackPlan,
                    persistenceMode: block.persistenceMode,
                    persistenceMessage: block.persistenceMessage
                )
            }
        }
    }

    func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport {
        let blockMap = Dictionary(uniqueKeysWithValues: blocksByPage.values.joined().map { ($0.id, $0) })
        let outcomes = edits.compactMap { edit -> SavePreflightBlockOutcome? in
            guard let block = blockMap[edit.blockID] else {
                return nil
            }

            let mode = preflightModesByBlockID[edit.blockID] ?? block.persistenceMode
            let message = preflightMessagesByBlockID[edit.blockID]
                ?? block.persistenceMessage
                ?? mode.displayName

            return SavePreflightBlockOutcome(
                blockID: edit.blockID,
                pageIndex: block.pageIndex,
                mode: mode,
                message: message
            )
        }
        return SavePreflightReport(blockOutcomes: outcomes)
    }

    func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult {
        _ = mode
        let report = try preflightSave(
            blocksByPage.values.joined()
                .filter { $0.currentText != $0.originalText }
                .map { TextEdit(blockID: $0.id, replacementText: $0.currentText) },
            for: document
        )

        if report.blockedCount > 0 {
            throw PDFEditorError.saveFailed(
                report.blockOutcomes
                    .filter { $0.mode == .blocked }
                    .map(\.message)
                    .joined(separator: " ")
            )
        }
        if report.requiresOverlayConfirmation && !allowOverlayFallback {
            throw PDFEditorError.saveFailed("One or more edits require overlay fallback confirmation before save.")
        }

        saveAllowOverlayFallbackFlags.append(allowOverlayFallback)
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
            savedBlockOutcomes: report.blockOutcomes.map {
                SavedBlockOutcome(
                    blockID: $0.blockID,
                    pageIndex: $0.pageIndex,
                    mode: $0.mode,
                    message: $0.message
                )
            },
            validationReport: ValidationReport(isValid: true, validator: "Mock", messages: [])
        )
    }

    func validate(_ fileURL: URL) throws -> ValidationReport {
        ValidationReport(isValid: true, validator: "Mock", messages: [])
    }
}
