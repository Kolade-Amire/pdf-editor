import Combine
import CoreGraphics
import Foundation

@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var document: LoadedPDFDocument?
    @Published public private(set) var pageBlocks: [Int: [EditableTextBlock]] = [:]
    @Published package private(set) var pageLoadStates: [Int: PageBlockLoadState] = [:]
    @Published public private(set) var pendingEdits: [String: TextEdit] = [:]
    @Published public private(set) var selectedBlockID: String?
    @Published public private(set) var selectedRunID: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var lastValidationReport: ValidationReport?
    @Published public private(set) var pendingSavePreflight: SavePreflightReport?
    @Published public private(set) var isReadOnly = true
    @Published public private(set) var requiresPassword = false
    @Published public var currentPageIndex = 0
    @Published public var draftText = ""

    public let engine: PDFEngine

    private let textFitEvaluator: TextFitEvaluator

    public init(
        engine: PDFEngine = PDFEngineFactory.makeDefault(),
        textFitEvaluator: TextFitEvaluator = TextFitEvaluator()
    ) {
        self.engine = engine
        self.textFitEvaluator = textFitEvaluator
    }

    public var pageCount: Int {
        document?.descriptor.pageCount ?? 0
    }

    public var currentPageBlocks: [EditableTextBlock] {
        blocks(for: currentPageIndex)
    }

    public var currentPageRuns: [EditableTextRun] {
        runs(for: currentPageIndex)
    }

    package var currentPageLoadState: PageBlockLoadState {
        pageLoadState(for: currentPageIndex)
    }

    public var selectedBlock: EditableTextBlock? {
        guard let selectedBlockID else {
            return nil
        }

        return pageBlocks.values
            .joined()
            .first(where: { $0.id == selectedBlockID })
    }

    public var selectedRun: EditableTextRun? {
        guard let selectedRunID else {
            return nil
        }

        return pageBlocks.values
            .joined()
            .flatMap(\.displayRuns)
            .first(where: { $0.id == selectedRunID })
    }

    public var currentPageReport: PageEditabilityReport? {
        document?.editabilityReport.pageReports.first(where: { $0.pageIndex == currentPageIndex })
    }

    public var documentIssues: [EditabilityIssue] {
        document?.editabilityReport.issues ?? []
    }

    public var canSave: Bool {
        guard let document else {
            return false
        }

        return !pendingEdits.isEmpty && !isReadOnly && document.descriptor.backend.supportsWrites
    }

    public func load(url: URL) throws {
        let openedDocument = try engine.open(url: url)
        document = openedDocument
        requiresPassword = openedDocument.descriptor.isLocked
        isReadOnly = !openedDocument.editabilityReport.isEditable
        currentPageIndex = 0
        pendingEdits = [:]
        selectedBlockID = nil
        selectedRunID = nil
        draftText = ""
        lastValidationReport = nil
        pendingSavePreflight = nil
        statusMessage = nil
        pageBlocks = [:]
        pageLoadStates = [:]
    }

    public func unlock(with password: String) throws {
        guard let document else {
            throw PDFEditorError.missingDocument
        }

        let unlockedDocument = try engine.unlock(document, password: password)
        self.document = unlockedDocument
        requiresPassword = unlockedDocument.descriptor.isLocked
        isReadOnly = !unlockedDocument.editabilityReport.isEditable
        pageBlocks = [:]
        pageLoadStates = [:]
        selectedBlockID = nil
        selectedRunID = nil
        draftText = ""

        if !requiresPassword {
            statusMessage = "Document unlocked."
        }
    }

    public func blocks(for pageIndex: Int) -> [EditableTextBlock] {
        pageBlocks[pageIndex] ?? []
    }

    package func pageLoadState(for pageIndex: Int) -> PageBlockLoadState {
        pageLoadStates[pageIndex] ?? .unloaded
    }

    public func runs(for pageIndex: Int) -> [EditableTextRun] {
        blocks(for: pageIndex).flatMap(\.displayRuns)
    }

    public func renderPage(pageIndex: Int, scale: CGFloat = 2) throws -> CGImage {
        guard let document else {
            throw PDFEditorError.missingDocument
        }

        return try engine.renderPage(of: document, pageIndex: pageIndex, scale: scale)
    }

    public func selectBlock(_ blockID: String?, preferredRunID: String? = nil) {
        selectedBlockID = blockID
        selectedRunID = preferredRunID ?? selectedBlock?.lineFragments.first?.id
        draftText = selectedBlock?.currentText ?? ""
    }

    public func selectRun(_ runID: String?) {
        guard let runID else {
            selectedRunID = nil
            selectBlock(nil)
            return
        }

        let allRuns = pageBlocks.values.joined().flatMap(\.displayRuns)
        guard let run = allRuns.first(where: { $0.id == runID }) else {
            selectedRunID = nil
            selectBlock(nil)
            return
        }

        currentPageIndex = run.pageIndex
        selectBlock(run.blockID, preferredRunID: run.id)
    }

    public func selectRun(on pageIndex: Int, at point: CGPoint) {
        let hit = runs(for: pageIndex).first { run in
            run.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
        currentPageIndex = pageIndex
        selectRun(hit?.id)
    }

    public func updateDraftText(_ text: String) {
        draftText = text

        guard let block = selectedBlock else {
            return
        }

        guard block.isEditable else {
            statusMessage = block.failureReason?.message ?? "This text block is read-only."
            draftText = block.currentText
            return
        }

        if text == block.originalText {
            pendingEdits.removeValue(forKey: block.id)
        } else {
            pendingEdits[block.id] = TextEdit(blockID: block.id, replacementText: text)
        }

        pendingSavePreflight = nil
        stagePendingEdits()
        reloadBlocks(for: block.pageIndex)
    }

    public func discardSelectedEdit() {
        guard let block = selectedBlock else {
            return
        }

        pendingEdits.removeValue(forKey: block.id)
        draftText = block.originalText
        pendingSavePreflight = nil
        stagePendingEdits()
        reloadBlocks(for: block.pageIndex)
    }

    public func prepareSave(to url: URL? = nil) throws -> SavePreflightReport {
        guard let document else {
            throw PDFEditorError.missingDocument
        }

        _ = url ?? document.descriptor.sourceURL
        try validatePendingEdits()
        try engine.applyEdits(Array(pendingEdits.values), to: document)

        let report = try engine.preflightSave(Array(pendingEdits.values), for: document)
        pendingSavePreflight = report

        if report.blockedCount > 0 {
            statusMessage = report.blockOutcomes
                .filter { $0.mode == .blocked }
                .map(\.message)
                .joined(separator: " ")
        } else if report.requiresOverlayConfirmation {
            statusMessage = "Overlay fallback confirmation is required before save."
        } else {
            statusMessage = "Ready to save with true PDF rewriting."
        }

        return report
    }

    @discardableResult
    public func save(to url: URL? = nil, allowOverlayFallback: Bool = false) throws -> SaveResult {
        guard let document else {
            throw PDFEditorError.missingDocument
        }

        let destinationURL = url ?? document.descriptor.sourceURL
        let preflight = try prepareSave(to: destinationURL)
        if preflight.blockedCount > 0 {
            throw PDFEditorError.saveFailed(
                preflight.blockOutcomes
                    .filter { $0.mode == .blocked }
                    .map(\.message)
                    .joined(separator: " ")
            )
        }
        if preflight.requiresOverlayConfirmation && !allowOverlayFallback {
            throw PDFEditorError.saveFailed("One or more edits require overlay fallback confirmation before save.")
        }

        let result = try engine.save(
            document,
            to: destinationURL,
            mode: .automatic,
            allowOverlayFallback: allowOverlayFallback
        )
        lastValidationReport = result.validationReport
        pendingEdits = [:]
        selectedBlockID = nil
        selectedRunID = nil
        draftText = ""
        pendingSavePreflight = nil
        if result.validationReport.isValid {
            statusMessage = "Saved \(result.fileURL.lastPathComponent): \(result.trueRewriteCount) true edit(s), \(result.overlayFallbackCount) overlay fallback edit(s)."
        } else {
            statusMessage = "Saved with validation warnings: \(result.trueRewriteCount) true edit(s), \(result.overlayFallbackCount) overlay fallback edit(s)."
        }

        try load(url: destinationURL)
        lastValidationReport = result.validationReport
        return result
    }

    public func validateCurrentDocument() throws -> ValidationReport {
        guard let document else {
            throw PDFEditorError.missingDocument
        }

        let report = try engine.validate(document.descriptor.sourceURL)
        lastValidationReport = report
        return report
    }

    package func loadBlocksIfNeeded(for pageIndex: Int) {
        loadBlocks(for: pageIndex, forceReload: false)
    }

    package func reloadCurrentPageBlocks() {
        reloadBlocks(for: currentPageIndex)
    }

    package func reloadBlocks(for pageIndex: Int) {
        loadBlocks(for: pageIndex, forceReload: true)
    }

    private func loadBlocks(for pageIndex: Int, forceReload: Bool) {
        guard let document else {
            return
        }

        guard !requiresPassword else {
            return
        }

        guard (0..<document.descriptor.pageCount).contains(pageIndex) else {
            return
        }

        let currentState = pageLoadState(for: pageIndex)
        if !forceReload {
            switch currentState {
            case .loaded, .loading:
                return
            case .unloaded, .failed:
                break
            }
        }

        pageLoadStates[pageIndex] = .loading

        do {
            pageBlocks[pageIndex] = try engine.extractEditableBlocks(from: document, pageIndex: pageIndex)
            pageLoadStates[pageIndex] = .loaded
            syncSelectionAfterPageRefresh(pageIndex: pageIndex)
            return
        } catch {
            pageBlocks[pageIndex] = []
            pageLoadStates[pageIndex] = .failed(message: error.localizedDescription)
            clearSelectionIfNeeded(for: pageIndex)
        }
    }

    private func syncSelectionAfterPageRefresh(pageIndex: Int) {
        guard let selectedBlockID else {
            return
        }

        guard blocks(for: pageIndex).contains(where: { $0.id == selectedBlockID }) else {
            clearSelectionIfNeeded(for: pageIndex)
            return
        }

        let preferredRunID = selectedRunID
        selectBlock(selectedBlockID, preferredRunID: preferredRunID)
    }

    private func clearSelectionIfNeeded(for pageIndex: Int) {
        guard selectedBlock?.pageIndex == pageIndex || selectedRun?.pageIndex == pageIndex else {
            return
        }

        selectBlock(nil)
    }

    private func stagePendingEdits() {
        guard let document else {
            return
        }

        do {
            try engine.applyEdits(Array(pendingEdits.values), to: document)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func validatePendingEdits() throws {
        let allBlocks = Dictionary(uniqueKeysWithValues: pageBlocks.values.joined().map { ($0.id, $0) })

        for edit in pendingEdits.values {
            guard let block = allBlocks[edit.blockID] else {
                throw PDFEditorError.blockNotFound(edit.blockID)
            }

            let fit = textFitEvaluator.evaluate(text: edit.replacementText, in: block)
            guard fit.fits else {
                statusMessage = "Edited text must fit inside the original text block."
                throw PDFEditorError.textDoesNotFit(blockID: edit.blockID)
            }
        }
    }
}
