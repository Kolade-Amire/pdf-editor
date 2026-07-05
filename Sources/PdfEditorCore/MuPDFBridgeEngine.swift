import CPdfEngineBridge
import CoreGraphics
import Foundation

public final class MuPDFBridgeEngine: PDFEngine, PageAnalysisProvidingPDFEngine {
    private struct NativeBlockReference {
        let pageIndex: Int
        let nativeBlockID: Int32
    }

    private struct NativePageAnalysis {
        let blocks: [EditableTextBlock]
        let report: PageEditabilityReport
    }

    private final class Storage {
        var sourceURL: URL
        let handle: OpaquePointer
        var cachedBaseBlocks: [Int: [EditableTextBlock]] = [:]
        var cachedPageReports: [Int: PageEditabilityReport] = [:]
        var blockReferencesByID: [String: NativeBlockReference] = [:]
        var pendingEditsByBlockID: [String: TextEdit] = [:]

        init(sourceURL: URL, handle: OpaquePointer) {
            self.sourceURL = sourceURL
            self.handle = handle
        }

        deinit {
            pdf_bridge_close_document(handle)
        }
    }

    public static var isAvailable: Bool {
        pdf_engine_bridge_is_available()
    }

    private let validationBinaryURL: URL?
    private var storageByID: [UUID: Storage] = [:]

    public init(validationBinaryURL: URL? = nil) {
        self.validationBinaryURL = validationBinaryURL ?? PDFKitEngine.findQPDF()
    }

    public func open(url: URL) throws -> LoadedPDFDocument {
        guard Self.isAvailable else {
            throw PDFEditorError.unsupportedEngine("MuPDF bridge artifacts are unavailable in this checkout.")
        }

        var handle: OpaquePointer?
        var info = pdf_bridge_document_info()
        var report = pdf_bridge_editability_report()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didOpen = pdf_bridge_open_document(
            url.path,
            &handle,
            &info,
            &report,
            &errorMessage
        ) != 0

        guard didOpen, let handle else {
            defer {
                pdf_bridge_free_document_info(&info)
                pdf_bridge_free_editability_report(&report)
            }
            throw bridgeError(
                errorMessage,
                fallback: "MuPDF could not open \(url.lastPathComponent).",
                defaultError: .unsupportedEngine("MuPDF could not open \(url.lastPathComponent).")
            )
        }

        defer {
            pdf_bridge_free_document_info(&info)
            pdf_bridge_free_editability_report(&report)
        }

        let identifier = UUID()
        let storage = Storage(sourceURL: url, handle: handle)
        let loadedDocument = makeLoadedDocument(
            identifier: identifier,
            sourceURL: url,
            info: info,
            report: report
        )
        storageByDocumentID[identifier] = storage
        return loadedDocument
    }

    public func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        let storage = try storage(for: document)

        var info = pdf_bridge_document_info()
        var report = pdf_bridge_editability_report()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didUnlock = pdf_bridge_unlock_document(
            storage.handle,
            password,
            &info,
            &report,
            &errorMessage
        ) != 0

        guard didUnlock else {
            defer {
                pdf_bridge_free_document_info(&info)
                pdf_bridge_free_editability_report(&report)
            }
            let message = takeBridgeError(errorMessage) ?? "The provided password did not unlock the document."
            if message.localizedCaseInsensitiveContains("password") {
                throw PDFEditorError.invalidPassword
            }
            throw PDFEditorError.saveFailed(message)
        }

        defer {
            pdf_bridge_free_document_info(&info)
            pdf_bridge_free_editability_report(&report)
        }

        storage.cachedBaseBlocks.removeAll()
        storage.cachedPageReports.removeAll()
        storage.blockReferencesByID.removeAll()
        storage.pendingEditsByBlockID.removeAll()

        return makeLoadedDocument(
            identifier: document.id,
            sourceURL: storage.sourceURL,
            info: info,
            report: report
        )
    }

    public func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        let storage = try storage(for: document)
        try validatePageIndex(pageIndex, in: document)

        var renderedPage = pdf_bridge_rendered_page()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didRender = pdf_bridge_render_page(
            storage.handle,
            Int32(pageIndex),
            scale,
            &renderedPage,
            &errorMessage
        ) != 0

        guard didRender else {
            defer { pdf_bridge_free_rendered_page(&renderedPage) }
            throw bridgeError(
                errorMessage,
                fallback: "MuPDF could not render page \(pageIndex + 1).",
                defaultError: .saveFailed("MuPDF could not render page \(pageIndex + 1).")
            )
        }

        defer { pdf_bridge_free_rendered_page(&renderedPage) }

        let width = Int(renderedPage.width)
        let height = Int(renderedPage.height)
        let stride = Int(renderedPage.stride)
        let byteCount = stride * height

        guard width > 0, height > 0, stride > 0, byteCount > 0, let pixels = renderedPage.pixels else {
            throw PDFEditorError.saveFailed("MuPDF returned an empty render for page \(pageIndex + 1).")
        }

        let data = Data(bytes: pixels, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PDFEditorError.saveFailed("Could not build a Core Graphics data provider for page \(pageIndex + 1).")
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw PDFEditorError.saveFailed("Could not construct a Core Graphics image for page \(pageIndex + 1).")
        }

        return image
    }

    public func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        try extractPageAnalysis(from: document, pageIndex: pageIndex).blocks
    }

    package func extractPageAnalysis(from document: LoadedPDFDocument, pageIndex: Int) throws -> PageAnalysisResult {
        let storage = try storage(for: document)
        try validatePageIndex(pageIndex, in: document)

        let analysis = try loadPageAnalysis(forPage: pageIndex, in: storage, document: document)
        return PageAnalysisResult(
            blocks: overlayPendingEdits(on: analysis.blocks, pendingEdits: storage.pendingEditsByBlockID),
            report: analysis.report
        )
    }

    public func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        let storage = try storage(for: document)

        guard document.descriptor.backend.supportsWrites else {
            throw PDFEditorError.readOnly("This PDF is currently read-only and cannot accept staged edits.")
        }

        var normalizedEdits: [String: TextEdit] = [:]
        for edit in edits {
            let block = try resolveBlock(id: edit.blockID, in: storage, document: document)
            guard block.isEditable else {
                throw PDFEditorError.readOnly(block.failureReason?.message ?? "This text block is read-only.")
            }

            if edit.replacementText == block.originalText {
                continue
            }

            normalizedEdits[edit.blockID] = edit
        }

        storage.pendingEditsByBlockID = normalizedEdits
    }

    public func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport {
        let storage = try storage(for: document)

        guard document.descriptor.backend.supportsWrites else {
            throw PDFEditorError.readOnly("This PDF is currently read-only and cannot be saved through MuPDF.")
        }

        let sortedEdits = try edits.sorted { lhs, rhs in
            let left = try nativeReference(for: lhs.blockID, in: storage, document: document)
            let right = try nativeReference(for: rhs.blockID, in: storage, document: document)
            if left.pageIndex != right.pageIndex {
                return left.pageIndex < right.pageIndex
            }
            return left.nativeBlockID < right.nativeBlockID
        }

        var nativeStrings: [UnsafeMutablePointer<CChar>?] = []
        nativeStrings.reserveCapacity(sortedEdits.count)
        for edit in sortedEdits {
            guard let duplicated = strdup(edit.replacementText) else {
                nativeStrings.forEach { free($0) }
                throw PDFEditorError.saveFailed("Out of memory while preparing replacement text for save preflight.")
            }
            nativeStrings.append(duplicated)
        }
        defer { nativeStrings.forEach { free($0) } }

        var nativeEdits: [pdf_bridge_text_edit] = []
        nativeEdits.reserveCapacity(sortedEdits.count)
        for (index, edit) in sortedEdits.enumerated() {
            let reference = try nativeReference(for: edit.blockID, in: storage, document: document)
            nativeEdits.append(
                pdf_bridge_text_edit(
                    page_index: Int32(reference.pageIndex),
                    native_block_id: reference.nativeBlockID,
                    replacement_text: nativeStrings[index]
                )
            )
        }

        var report = pdf_bridge_save_preflight_report()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didPreflight = nativeEdits.withUnsafeBufferPointer { buffer in
            pdf_bridge_preflight_save(
                storage.handle,
                buffer.baseAddress,
                buffer.count,
                &report,
                &errorMessage
            ) != 0
        }

        guard didPreflight else {
            defer { pdf_bridge_free_save_preflight_report(&report) }
            throw bridgeError(
                errorMessage,
                fallback: "MuPDF could not prepare a save preflight report.",
                defaultError: .saveFailed("MuPDF could not prepare a save preflight report.")
            )
        }

        defer { pdf_bridge_free_save_preflight_report(&report) }
        return mapSavePreflightReport(report)
    }

    public func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult {
        let storage = try storage(for: document)

        guard document.descriptor.backend.supportsWrites else {
            throw PDFEditorError.readOnly("This PDF is currently read-only and cannot be saved through MuPDF.")
        }

        let sortedEdits = try storage.pendingEditsByBlockID.values
            .sorted { lhs, rhs in
                let left = try nativeReference(for: lhs.blockID, in: storage, document: document)
                let right = try nativeReference(for: rhs.blockID, in: storage, document: document)
                if left.pageIndex != right.pageIndex {
                    return left.pageIndex < right.pageIndex
                }
                return left.nativeBlockID < right.nativeBlockID
            }

        var nativeStrings: [UnsafeMutablePointer<CChar>?] = []
        nativeStrings.reserveCapacity(sortedEdits.count)
        for edit in sortedEdits {
            guard let duplicated = strdup(edit.replacementText) else {
                nativeStrings.forEach { free($0) }
                throw PDFEditorError.saveFailed("Out of memory while preparing replacement text for save.")
            }
            nativeStrings.append(duplicated)
        }
        defer {
            nativeStrings.forEach { free($0) }
        }

        var nativeEdits: [pdf_bridge_text_edit] = []
        nativeEdits.reserveCapacity(sortedEdits.count)
        for (index, edit) in sortedEdits.enumerated() {
            let reference = try nativeReference(for: edit.blockID, in: storage, document: document)
            nativeEdits.append(
                pdf_bridge_text_edit(
                    page_index: Int32(reference.pageIndex),
                    native_block_id: reference.nativeBlockID,
                    replacement_text: nativeStrings[index]
                )
            )
        }

        var saveResult = pdf_bridge_save_result()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let requestedMode = bridgeSaveMode(for: mode)

        let didSave = nativeEdits.withUnsafeBufferPointer { buffer in
            pdf_bridge_save_document(
                storage.handle,
                url.path,
                buffer.baseAddress,
                buffer.count,
                requestedMode,
                allowOverlayFallback,
                &saveResult,
                &errorMessage
            ) != 0
        }

        guard didSave else {
            defer { pdf_bridge_free_save_result(&saveResult) }
            throw bridgeError(
                errorMessage,
                fallback: "MuPDF could not save \(url.lastPathComponent).",
                defaultError: .saveFailed("MuPDF could not save \(url.lastPathComponent).")
            )
        }

        defer { pdf_bridge_free_save_result(&saveResult) }

        storage.pendingEditsByBlockID.removeAll()
        storage.sourceURL = url

        let baseValidation = mapValidationReport(saveResult.validation)
        let validation = try combineWithQPDFIfAvailable(baseValidation, fileURL: url)

        return SaveResult(
            fileURL: url,
            usedSaveMode: mapSaveMode(saveResult.used_save_mode),
            appliedEditCount: Int(saveResult.applied_edit_count),
            savedBlockOutcomes: bufferPointer(start: saveResult.outcomes, count: Int(saveResult.outcome_count)).map(mapSavedBlockOutcome),
            validationReport: validation
        )
    }

    public func validate(_ fileURL: URL) throws -> ValidationReport {
        guard Self.isAvailable else {
            throw PDFEditorError.unsupportedEngine("MuPDF bridge artifacts are unavailable in this checkout.")
        }

        var report = pdf_bridge_validation_report()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didValidate = pdf_bridge_validate_file(fileURL.path, &report, &errorMessage) != 0
        guard didValidate else {
            defer { pdf_bridge_free_validation_report(&report) }
            throw bridgeError(
                errorMessage,
                fallback: "MuPDF could not validate \(fileURL.lastPathComponent).",
                defaultError: .validationFailed("MuPDF could not validate \(fileURL.lastPathComponent).")
            )
        }

        defer { pdf_bridge_free_validation_report(&report) }

        let baseValidation = mapValidationReport(report)
        return try combineWithQPDFIfAvailable(baseValidation, fileURL: fileURL)
    }

    private var storageByDocumentID: [UUID: Storage] {
        get { storageByID }
        set { storageByID = newValue }
    }

    private func storage(for document: LoadedPDFDocument) throws -> Storage {
        guard let storage = storageByDocumentID[document.id] else {
            throw PDFEditorError.missingDocument
        }
        return storage
    }

    private func validatePageIndex(_ pageIndex: Int, in document: LoadedPDFDocument) throws {
        guard (0..<document.descriptor.pageCount).contains(pageIndex) else {
            throw PDFEditorError.pageOutOfRange(pageIndex)
        }
    }

    private func loadPageAnalysis(
        forPage pageIndex: Int,
        in storage: Storage,
        document: LoadedPDFDocument
    ) throws -> NativePageAnalysis {
        if let cachedBlocks = storage.cachedBaseBlocks[pageIndex],
           let cachedReport = storage.cachedPageReports[pageIndex] {
            return NativePageAnalysis(blocks: cachedBlocks, report: cachedReport)
        }

        var nativeBlocks = pdf_bridge_text_block_array()
        var nativePageReport = pdf_bridge_page_report()
        var errorMessage: UnsafeMutablePointer<CChar>?

        let didExtract = pdf_bridge_extract_blocks_with_report(
            storage.handle,
            Int32(pageIndex),
            &nativeBlocks,
            &nativePageReport,
            &errorMessage
        ) != 0

        guard didExtract else {
            defer {
                pdf_bridge_free_text_block_array(&nativeBlocks)
                pdf_bridge_free_page_report(&nativePageReport)
            }
            let message = takeBridgeError(errorMessage) ?? "MuPDF could not extract text blocks for page \(pageIndex + 1)."
            if message.localizedCaseInsensitiveContains("password") {
                throw PDFEditorError.passwordRequired
            }
            throw PDFEditorError.saveFailed(message)
        }

        defer {
            pdf_bridge_free_text_block_array(&nativeBlocks)
            pdf_bridge_free_page_report(&nativePageReport)
        }

        let blocks = mapTextBlocks(nativeBlocks, document: document, storage: storage)
        let report = PageEditabilityReport(
            pageIndex: Int(nativePageReport.page_index),
            isEditable: nativePageReport.is_editable,
            issues: bufferPointer(start: nativePageReport.issues, count: Int(nativePageReport.issue_count)).map(mapIssue)
        )
        storage.cachedBaseBlocks[pageIndex] = blocks
        storage.cachedPageReports[pageIndex] = report
        return NativePageAnalysis(blocks: blocks, report: report)
    }

    private func resolveBlock(
        id blockID: String,
        in storage: Storage,
        document: LoadedPDFDocument
    ) throws -> EditableTextBlock {
        if let block = storage.cachedBaseBlocks.values.joined().first(where: { $0.id == blockID }) {
            return overlayPendingEdit(on: block, pendingEdits: storage.pendingEditsByBlockID)
        }

        for pageIndex in 0..<document.descriptor.pageCount {
            let pageBlocks = try loadPageAnalysis(forPage: pageIndex, in: storage, document: document).blocks
            if let block = pageBlocks.first(where: { $0.id == blockID }) {
                return overlayPendingEdit(on: block, pendingEdits: storage.pendingEditsByBlockID)
            }
        }

        throw PDFEditorError.blockNotFound(blockID)
    }

    private func nativeReference(
        for blockID: String,
        in storage: Storage,
        document: LoadedPDFDocument
    ) throws -> NativeBlockReference {
        if let reference = storage.blockReferencesByID[blockID] {
            return reference
        }

        _ = try resolveBlock(id: blockID, in: storage, document: document)
        guard let reference = storage.blockReferencesByID[blockID] else {
            throw PDFEditorError.blockNotFound(blockID)
        }
        return reference
    }

    private func overlayPendingEdits(
        on blocks: [EditableTextBlock],
        pendingEdits: [String: TextEdit]
    ) -> [EditableTextBlock] {
        blocks.map { overlayPendingEdit(on: $0, pendingEdits: pendingEdits) }
    }

    private func overlayPendingEdit(
        on block: EditableTextBlock,
        pendingEdits: [String: TextEdit]
    ) -> EditableTextBlock {
        let currentText = pendingEdits[block.id]?.replacementText ?? block.originalText
        return EditableTextBlock(
            id: block.id,
            pageIndex: block.pageIndex,
            bounds: block.bounds,
            originalText: block.originalText,
            currentText: currentText,
            style: block.style,
            lineFragments: block.lineFragments,
            isEditable: block.isEditable,
            failureReason: block.failureReason,
            fallbackPlan: block.fallbackPlan,
            persistenceMode: block.persistenceMode,
            persistenceMessage: block.persistenceMessage
        )
    }

    private func makeLoadedDocument(
        identifier: UUID,
        sourceURL: URL,
        info: pdf_bridge_document_info,
        report: pdf_bridge_editability_report
    ) -> LoadedPDFDocument {
        let descriptor = PDFDocumentDescriptor(
            sourceURL: sourceURL,
            pageCount: Int(info.page_count),
            title: string(from: info.title),
            isEncrypted: info.is_encrypted,
            isLocked: info.is_locked,
            canEdit: info.can_edit,
            isSigned: info.is_signed,
            backend: mapBackend(info.backend_kind)
        )

        return LoadedPDFDocument(
            id: identifier,
            descriptor: descriptor,
            editabilityReport: mapEditabilityReport(report)
        )
    }

    private func mapEditabilityReport(_ report: pdf_bridge_editability_report) -> EditabilityReport {
        EditabilityReport(
            isEditable: report.is_editable,
            issues: bufferPointer(start: report.issues, count: Int(report.issue_count)).map {
                mapIssue($0)
            },
            pageReports: bufferPointer(start: report.page_reports, count: Int(report.page_report_count)).map { pageReport in
                PageEditabilityReport(
                    pageIndex: Int(pageReport.page_index),
                    isEditable: pageReport.is_editable,
                    issues: bufferPointer(start: pageReport.issues, count: Int(pageReport.issue_count)).map {
                        mapIssue($0)
                    }
                )
            }
        )
    }

    private func mapTextBlocks(
        _ nativeBlocks: pdf_bridge_text_block_array,
        document: LoadedPDFDocument,
        storage: Storage
    ) -> [EditableTextBlock] {
        bufferPointer(start: nativeBlocks.items, count: Int(nativeBlocks.count)).map { nativeBlock in
            let blockID = makeBlockID(pageIndex: Int(nativeBlock.page_index), nativeBlockID: nativeBlock.native_block_id)
            let style = TextStyle(
                fontPostScriptName: string(from: nativeBlock.font_postscript_name) ?? "Helvetica",
                fontSize: nativeBlock.font_size,
                color: makeColor(nativeBlock.color),
                characterSpacing: nativeBlock.character_spacing,
                horizontalScale: nativeBlock.horizontal_scale,
                rise: nativeBlock.rise,
                isBold: nativeBlock.is_bold,
                isItalic: nativeBlock.is_italic,
                isMonospaced: nativeBlock.is_monospaced,
                isSerif: nativeBlock.is_serif
            )

            let failureReason: EditabilityIssue? = nativeBlock.has_failure_reason
                ? mapIssue(nativeBlock.failure_reason)
                : nil

            let lineFragments = bufferPointer(start: nativeBlock.lines, count: Int(nativeBlock.line_count)).map { nativeLine in
                BlockLineFragment(
                    id: makeRunID(blockID: blockID, nativeLineID: nativeLine.native_line_id),
                    blockID: blockID,
                    pageIndex: Int(nativeBlock.page_index),
                    bounds: makeCGRect(nativeLine.bounds),
                    quads: bufferPointer(start: nativeLine.quads, count: Int(nativeLine.quad_count)).map(makeTextQuad),
                    originalText: string(from: nativeLine.text) ?? "",
                    currentText: string(from: nativeLine.text) ?? "",
                    style: style,
                    isEditable: nativeBlock.is_editable,
                    failureReason: failureReason
                )
            }

            let block = EditableTextBlock(
                id: blockID,
                pageIndex: Int(nativeBlock.page_index),
                bounds: makeCGRect(nativeBlock.bounds),
                originalText: string(from: nativeBlock.text) ?? "",
                currentText: string(from: nativeBlock.text) ?? "",
                style: style,
                lineFragments: lineFragments,
                isEditable: nativeBlock.is_editable,
                failureReason: failureReason,
                fallbackPlan: mapFallbackPlan(nativeBlock.fallback_plan),
                persistenceMode: mapPersistenceMode(nativeBlock.persistence_mode),
                persistenceMessage: string(from: nativeBlock.persistence_message)
            )

            storage.blockReferencesByID[blockID] = NativeBlockReference(
                pageIndex: Int(nativeBlock.page_index),
                nativeBlockID: nativeBlock.native_block_id
            )
            return block
        }
    }

    private func mapValidationReport(_ report: pdf_bridge_validation_report) -> ValidationReport {
        ValidationReport(
            isValid: report.is_valid,
            validator: string(from: report.validator) ?? "MuPDF reopen",
            messages: bufferPointer(start: report.messages, count: Int(report.message_count)).compactMap {
                guard let message = $0 else { return nil }
                return String(cString: message)
            }
        )
    }

    private func mapSavePreflightReport(_ report: pdf_bridge_save_preflight_report) -> SavePreflightReport {
        SavePreflightReport(
            blockOutcomes: bufferPointer(start: report.outcomes, count: Int(report.outcome_count)).map(mapSavePreflightBlockOutcome),
            warnings: bufferPointer(start: report.warnings, count: Int(report.warning_count)).compactMap {
                guard let warning = $0 else { return nil }
                return String(cString: warning)
            }
        )
    }

    private func combineWithQPDFIfAvailable(
        _ baseValidation: ValidationReport,
        fileURL: URL
    ) throws -> ValidationReport {
        guard let validationBinaryURL else {
            return baseValidation
        }

        do {
            let qpdfValidation = try runQPDFValidation(binaryURL: validationBinaryURL, fileURL: fileURL)
            return ValidationReport(
                isValid: baseValidation.isValid && qpdfValidation.isValid,
                validator: "\(baseValidation.validator) + \(qpdfValidation.validator)",
                messages: baseValidation.messages + qpdfValidation.messages
            )
        } catch {
            return ValidationReport(
                isValid: baseValidation.isValid,
                validator: baseValidation.validator,
                messages: baseValidation.messages + ["qpdf could not be executed: \(error.localizedDescription)"]
            )
        }
    }

    private func runQPDFValidation(binaryURL: URL, fileURL: URL) throws -> ValidationReport {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = binaryURL
        process.arguments = ["--check", fileURL.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let messages = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ValidationReport(
            isValid: process.terminationStatus == 0,
            validator: "qpdf",
            messages: messages.isEmpty ? ["qpdf reported no issues."] : messages
        )
    }

    private func bridgeError(
        _ errorMessage: UnsafeMutablePointer<CChar>?,
        fallback: String,
        defaultError: PDFEditorError
    ) -> Error {
        let message = takeBridgeError(errorMessage) ?? fallback

        switch defaultError {
        case .validationFailed:
            return PDFEditorError.validationFailed(message)
        case .saveFailed:
            return PDFEditorError.saveFailed(message)
        case .unsupportedEngine:
            return PDFEditorError.unsupportedEngine(message)
        default:
            return defaultError
        }
    }

    private func takeBridgeError(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }

        defer { pdf_bridge_free_error(pointer) }
        let message = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private func mapBackend(_ backend: pdf_bridge_backend_kind) -> PDFBackendKind {
        switch backend {
        case PDF_BRIDGE_BACKEND_MUPDF_EDITABLE:
            return .muPDFEditable
        case PDF_BRIDGE_BACKEND_MUPDF_READ_ONLY:
            return .muPDFReadOnly
        default:
            return .muPDFReadOnly
        }
    }

    private func mapIssue(_ issue: pdf_bridge_issue) -> EditabilityIssue {
        let pageIndex = issue.page_index >= 0 ? Int(issue.page_index) : nil
        let blockID: String?
        if let pageIndex, issue.native_block_id >= 0 {
            blockID = makeBlockID(pageIndex: pageIndex, nativeBlockID: issue.native_block_id)
        } else {
            blockID = nil
        }

        return EditabilityIssue(
            kind: mapIssueKind(issue.kind),
            message: string(from: issue.message) ?? "",
            pageIndex: pageIndex,
            blockID: blockID
        )
    }

    private func mapIssueKind(_ kind: pdf_bridge_issue_kind) -> EditabilityIssueKind {
        switch kind {
        case PDF_BRIDGE_ISSUE_ENCRYPTED:
            return .encrypted
        case PDF_BRIDGE_ISSUE_IMAGE_ONLY:
            return .imageOnly
        case PDF_BRIDGE_ISSUE_SIGNED:
            return .signed
        case PDF_BRIDGE_ISSUE_UNSUPPORTED_FONT:
            return .unsupportedFont
        case PDF_BRIDGE_ISSUE_UNSUPPORTED_STRUCTURE:
            return .unsupportedStructure
        case PDF_BRIDGE_ISSUE_UNSUPPORTED_TRANSFORM:
            return .unsupportedTransform
        case PDF_BRIDGE_ISSUE_MISSING_FONT_METRICS:
            return .missingFontMetrics
        case PDF_BRIDGE_ISSUE_RIGHTS_RESTRICTED:
            return .rightsRestricted
        case PDF_BRIDGE_ISSUE_PASSWORD_REQUIRED:
            return .passwordRequired
        case PDF_BRIDGE_ISSUE_TEXT_OVERFLOW:
            return .textOverflow
        case PDF_BRIDGE_ISSUE_VALIDATION_FAILED:
            return .validationFailed
        case PDF_BRIDGE_ISSUE_ENGINE_UNAVAILABLE:
            return .engineUnavailable
        default:
            return .unsupportedStructure
        }
    }

    private func mapFallbackPlan(_ plan: pdf_bridge_font_plan) -> FontFallbackPlan {
        FontFallbackPlan(
            requestedFontPostScriptName: string(from: plan.requested_font_postscript_name) ?? "",
            resolvedFontName: string(from: plan.resolved_font_name) ?? "",
            family: mapFallbackFamily(plan.family),
            source: mapFallbackSource(plan.source),
            warning: string(from: plan.warning)
        )
    }

    private func mapFallbackFamily(_ family: pdf_bridge_fallback_family) -> FontFallbackFamily {
        switch family {
        case PDF_BRIDGE_FALLBACK_FAMILY_SANS:
            return .sans
        case PDF_BRIDGE_FALLBACK_FAMILY_SERIF:
            return .serif
        case PDF_BRIDGE_FALLBACK_FAMILY_MONOSPACE:
            return .monospace
        default:
            return .sans
        }
    }

    private func mapFallbackSource(_ source: pdf_bridge_fallback_source) -> FontFallbackSource {
        switch source {
        case PDF_BRIDGE_FALLBACK_SOURCE_ORIGINAL:
            return .originalFont
        case PDF_BRIDGE_FALLBACK_SOURCE_BASE14:
            return .systemBase14
        default:
            return .systemBase14
        }
    }

    private func mapPersistenceMode(_ mode: pdf_bridge_persistence_mode) -> BlockPersistenceMode {
        switch mode {
        case PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE:
            return .trueRewrite
        case PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK:
            return .overlayFallback
        case PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED:
            return .blocked
        default:
            return .blocked
        }
    }

    private func mapSavePreflightBlockOutcome(_ outcome: pdf_bridge_block_outcome) -> SavePreflightBlockOutcome {
        SavePreflightBlockOutcome(
            blockID: makeBlockID(pageIndex: Int(outcome.page_index), nativeBlockID: outcome.native_block_id),
            pageIndex: Int(outcome.page_index),
            mode: mapPersistenceMode(outcome.mode),
            message: string(from: outcome.message) ?? ""
        )
    }

    private func mapSavedBlockOutcome(_ outcome: pdf_bridge_block_outcome) -> SavedBlockOutcome {
        SavedBlockOutcome(
            blockID: makeBlockID(pageIndex: Int(outcome.page_index), nativeBlockID: outcome.native_block_id),
            pageIndex: Int(outcome.page_index),
            mode: mapPersistenceMode(outcome.mode),
            message: string(from: outcome.message) ?? ""
        )
    }

    private func bridgeSaveMode(for mode: SaveMode) -> pdf_bridge_save_mode {
        switch mode {
        case .automatic:
            return PDF_BRIDGE_SAVE_MODE_AUTOMATIC
        case .incremental:
            return PDF_BRIDGE_SAVE_MODE_INCREMENTAL
        case .fullRewrite:
            return PDF_BRIDGE_SAVE_MODE_FULL_REWRITE
        }
    }

    private func mapSaveMode(_ mode: pdf_bridge_save_mode) -> SaveMode {
        switch mode {
        case PDF_BRIDGE_SAVE_MODE_INCREMENTAL:
            return .incremental
        case PDF_BRIDGE_SAVE_MODE_FULL_REWRITE:
            return .fullRewrite
        case PDF_BRIDGE_SAVE_MODE_AUTOMATIC:
            return .automatic
        default:
            return .automatic
        }
    }

    private func makeBlockID(pageIndex: Int, nativeBlockID: Int32) -> String {
        "mupdf:block:\(pageIndex):\(nativeBlockID)"
    }

    private func makeRunID(blockID: String, nativeLineID: Int32) -> String {
        "\(blockID):line:\(nativeLineID)"
    }

    private func makeCGRect(_ rect: pdf_bridge_rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func makeColor(_ color: pdf_bridge_color) -> PDFColor {
        PDFColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private func makeTextQuad(_ quad: pdf_bridge_quad) -> TextQuad {
        TextQuad(
            topLeft: CGPoint(x: quad.top_left.x, y: quad.top_left.y),
            topRight: CGPoint(x: quad.top_right.x, y: quad.top_right.y),
            bottomLeft: CGPoint(x: quad.bottom_left.x, y: quad.bottom_left.y),
            bottomRight: CGPoint(x: quad.bottom_right.x, y: quad.bottom_right.y)
        )
    }

    private func string(from pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }

        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func bufferPointer<Element>(start: UnsafePointer<Element>?, count: Int) -> [Element] {
        guard let start, count > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(start: start, count: count))
    }

    private func bufferPointer<Element>(start: UnsafeMutablePointer<Element>?, count: Int) -> [Element] {
        guard let start, count > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(start: UnsafePointer(start), count: count))
    }
}
