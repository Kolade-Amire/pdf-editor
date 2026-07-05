#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import CoreGraphics
import Foundation
import PDFKit

public final class PDFKitEngine: PDFEngine, PageAnalysisProvidingPDFEngine {
    private final class Storage {
        var sourceURL: URL
        let document: PDFDocument
        var cachedBaseBlocks: [Int: [EditableTextBlock]] = [:]
        var cachedPageReports: [Int: PageEditabilityReport] = [:]

        init(sourceURL: URL, document: PDFDocument) {
            self.sourceURL = sourceURL
            self.document = document
        }
    }

    private let readOnlyReason: String
    private let validationBinaryURL: URL?

    private var storageByID: [UUID: Storage] = [:]

    public init(
        readOnlyReason: String = "MuPDF editing is unavailable for this file, so PDFKit opened it in read-only mode.",
        validationBinaryURL: URL? = nil
    ) {
        self.readOnlyReason = readOnlyReason
        self.validationBinaryURL = validationBinaryURL ?? Self.findQPDF()
    }

    public func open(url: URL) throws -> LoadedPDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFEditorError.failedToOpen(url)
        }

        let identifier = UUID()
        let storage = Storage(sourceURL: url, document: document)
        storageByID[identifier] = storage

        let report = buildOpenEditabilityReport(for: storage)
        let descriptor = makeDescriptor(for: storage, report: report)
        return LoadedPDFDocument(id: identifier, descriptor: descriptor, editabilityReport: report)
    }

    public func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        guard let storage = storageByID[document.id] else {
            throw PDFEditorError.missingDocument
        }

        guard storage.document.unlock(withPassword: password) else {
            throw PDFEditorError.invalidPassword
        }

        storage.cachedBaseBlocks.removeAll()
        storage.cachedPageReports.removeAll()

        let report = buildOpenEditabilityReport(for: storage)
        let descriptor = makeDescriptor(for: storage, report: report)
        return LoadedPDFDocument(id: document.id, descriptor: descriptor, editabilityReport: report)
    }

    public func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        let page = try page(for: document, pageIndex: pageIndex)
        let bounds = page.bounds(for: .mediaBox)
        let renderSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )

        guard let context = CGContext(
            data: nil,
            width: Int(renderSize.width.rounded(.up)),
            height: Int(renderSize.height.rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFEditorError.saveFailed("Could not create a render context.")
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw PDFEditorError.saveFailed("Could not render page \(pageIndex + 1).")
        }

        return image
    }

    public func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        try extractPageAnalysis(from: document, pageIndex: pageIndex).blocks
    }

    package func extractPageAnalysis(from document: LoadedPDFDocument, pageIndex: Int) throws -> PageAnalysisResult {
        let storage = try storage(for: document)
        if storage.document.isLocked {
            throw PDFEditorError.passwordRequired
        }

        if let cachedBlocks = storage.cachedBaseBlocks[pageIndex],
           let cachedReport = storage.cachedPageReports[pageIndex] {
            return PageAnalysisResult(blocks: cachedBlocks, report: cachedReport)
        }

        let page = try page(for: document, pageIndex: pageIndex)
        let pageReport = makePageReport(for: page, pageIndex: pageIndex)
        let blocks = makeBlocks(
            for: page,
            pageIndex: pageIndex,
            pageReport: pageReport
        )
        storage.cachedBaseBlocks[pageIndex] = blocks
        storage.cachedPageReports[pageIndex] = pageReport
        return PageAnalysisResult(blocks: blocks, report: pageReport)
    }

    public func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        guard edits.isEmpty else {
            throw PDFEditorError.readOnly(readOnlyReason)
        }
    }

    public func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport {
        SavePreflightReport(
            blockOutcomes: edits.map {
                SavePreflightBlockOutcome(
                    blockID: $0.blockID,
                    pageIndex: 0,
                    mode: .blocked,
                    message: readOnlyReason
                )
            },
            warnings: edits.isEmpty ? [] : [readOnlyReason]
        )
    }

    public func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult {
        _ = document
        _ = url
        _ = mode
        _ = allowOverlayFallback
        throw PDFEditorError.readOnly(readOnlyReason)
    }

    public func validate(_ fileURL: URL) throws -> ValidationReport {
        if let validationBinaryURL {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = validationBinaryURL
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

        if PDFDocument(url: fileURL) != nil {
            return ValidationReport(
                isValid: true,
                validator: "PDFKit fallback",
                messages: ["qpdf is not installed; validation fell back to reopening the saved file."]
            )
        }

        return ValidationReport(
            isValid: false,
            validator: "PDFKit fallback",
            messages: ["Saved file could not be reopened for validation."]
        )
    }

    private func buildOpenEditabilityReport(for storage: Storage) -> EditabilityReport {
        let document = storage.document
        var documentIssues: [EditabilityIssue] = [
            EditabilityIssue(kind: .engineUnavailable, message: readOnlyReason)
        ]

        if document.isLocked {
            documentIssues.append(
                EditabilityIssue(
                    kind: .passwordRequired,
                    message: "This PDF is locked and requires a password before editing."
                )
            )
        }

        return EditabilityReport(
            isEditable: false,
            issues: documentIssues,
            pageReports: (0..<document.pageCount).map {
                PageEditabilityReport(pageIndex: $0, isEditable: false, issues: [])
            }
        )
    }

    private func makeDescriptor(for storage: Storage, report: EditabilityReport) -> PDFDocumentDescriptor {
        let attributes = storage.document.documentAttributes ?? [:]
        let title = attributes[PDFDocumentAttribute.titleAttribute] as? String

        return PDFDocumentDescriptor(
            sourceURL: storage.sourceURL,
            pageCount: storage.document.pageCount,
            title: title,
            isEncrypted: storage.document.isEncrypted,
            isLocked: storage.document.isLocked,
            canEdit: report.isEditable,
            isSigned: false,
            backend: .pdfKitReadOnlyFallback
        )
    }

    private func makeBlocks(
        for page: PDFPage,
        pageIndex: Int,
        pageReport: PageEditabilityReport?
    ) -> [EditableTextBlock] {
        let selection = page.selection(for: page.bounds(for: .mediaBox))
        let lines = selection?.selectionsByLine() ?? []
        let failureReason = pageReport?.issues.first
            ?? EditabilityIssue(
                kind: .engineUnavailable,
                message: readOnlyReason,
                pageIndex: pageIndex
            )

        return lines.enumerated().compactMap { lineIndex, lineSelection in
            let originalText = normalized(lineSelection.string ?? "")
            guard !originalText.isEmpty else {
                return nil
            }

            let bounds = lineSelection.bounds(for: page).integral
            guard !bounds.isEmpty else {
                return nil
            }

            let style = lineSelection.attributedString.flatMap(makeStyle(from:))
                ?? TextStyle(fontPostScriptName: "Helvetica", fontSize: 12, color: .black)
            let fallbackPlan = planFallback(for: style)
            let blockID = "pdfkit:block:\(pageIndex):\(lineIndex)"
            let runID = "\(blockID):line:0"

            let fragment = BlockLineFragment(
                id: runID,
                blockID: blockID,
                pageIndex: pageIndex,
                bounds: bounds,
                quads: [TextQuad.rect(bounds)],
                originalText: originalText,
                currentText: originalText,
                style: style,
                isEditable: false,
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
                isEditable: false,
                failureReason: failureReason,
                fallbackPlan: fallbackPlan,
                persistenceMode: .blocked,
                persistenceMessage: failureReason.message
            )
        }
    }

    private func makePageReport(for page: PDFPage, pageIndex: Int) -> PageEditabilityReport {
        let text = normalized(page.string ?? "")
        let issues: [EditabilityIssue]

        if text.isEmpty {
            issues = [
                EditabilityIssue(
                    kind: .imageOnly,
                    message: "Page \(pageIndex + 1) has no extractable digital text.",
                    pageIndex: pageIndex
                )
            ]
        } else {
            issues = []
        }

        return PageEditabilityReport(
            pageIndex: pageIndex,
            isEditable: false,
            issues: issues
        )
    }

    private func storage(for document: LoadedPDFDocument) throws -> Storage {
        guard let storage = storageByID[document.id] else {
            throw PDFEditorError.missingDocument
        }

        return storage
    }

    private func page(for document: LoadedPDFDocument, pageIndex: Int) throws -> PDFPage {
        let storage = try storage(for: document)
        guard let page = storage.document.page(at: pageIndex) else {
            throw PDFEditorError.pageOutOfRange(pageIndex)
        }

        return page
    }

    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeStyle(from attributedString: NSAttributedString) -> TextStyle? {
        guard attributedString.length > 0 else {
            return nil
        }

        let attributes = attributedString.attributes(at: 0, effectiveRange: nil)
        guard let font = attributes[.font] as? NSFont else {
            return nil
        }

        let color = (attributes[.foregroundColor] as? NSColor) ?? .black
        let traits = font.fontDescriptor.symbolicTraits
        let loweredName = font.fontName.lowercased()

        return TextStyle(
            fontPostScriptName: font.fontName,
            fontSize: font.pointSize,
            color: PDFColor(
                red: color.usingColorSpace(.deviceRGB)?.redComponent ?? 0,
                green: color.usingColorSpace(.deviceRGB)?.greenComponent ?? 0,
                blue: color.usingColorSpace(.deviceRGB)?.blueComponent ?? 0,
                alpha: color.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1
            ),
            characterSpacing: (attributes[.kern] as? CGFloat) ?? 0,
            horizontalScale: 1,
            rise: 0,
            isBold: traits.contains(.bold),
            isItalic: traits.contains(.italic),
            isMonospaced: traits.contains(.monoSpace) || loweredName.contains("mono") || loweredName.contains("courier"),
            isSerif: loweredName.contains("serif") || loweredName.contains("times")
        )
    }

    private func planFallback(for style: TextStyle) -> FontFallbackPlan {
        if style.isMonospaced {
            return FontFallbackPlan(
                requestedFontPostScriptName: style.fontPostScriptName,
                resolvedFontName: "Courier",
                family: .monospace,
                source: .systemBase14,
                warning: "PDFKit fallback is read-only; save is disabled and only base system font planning is shown."
            )
        }

        if style.isSerif {
            return FontFallbackPlan(
                requestedFontPostScriptName: style.fontPostScriptName,
                resolvedFontName: "Times-Roman",
                family: .serif,
                source: .systemBase14,
                warning: "PDFKit fallback is read-only; save is disabled and only base system font planning is shown."
            )
        }

        return FontFallbackPlan(
            requestedFontPostScriptName: style.fontPostScriptName,
            resolvedFontName: "Helvetica",
            family: .sans,
            source: .systemBase14,
            warning: "PDFKit fallback is read-only; save is disabled and only base system font planning is shown."
        )
    }

    public static func findQPDF() -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin/qpdf",
            "/usr/local/bin/qpdf",
            "/usr/bin/qpdf",
        ]

        return searchPaths
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
#else
import CoreGraphics
import Foundation

public final class PDFKitEngine: PDFEngine {
    public init(
        readOnlyReason: String = "PDFKit is unavailable in this environment.",
        validationBinaryURL: URL? = nil
    ) {}

    public func open(url: URL) throws -> LoadedPDFDocument {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func unlock(_ document: LoadedPDFDocument, password: String) throws -> LoadedPDFDocument {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func renderPage(of document: LoadedPDFDocument, pageIndex: Int, scale: CGFloat) throws -> CGImage {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func extractEditableBlocks(from document: LoadedPDFDocument, pageIndex: Int) throws -> [EditableTextBlock] {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func applyEdits(_ edits: [TextEdit], to document: LoadedPDFDocument) throws {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func preflightSave(_ edits: [TextEdit], for document: LoadedPDFDocument) throws -> SavePreflightReport {
        _ = edits
        _ = document
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func save(
        _ document: LoadedPDFDocument,
        to url: URL,
        mode: SaveMode,
        allowOverlayFallback: Bool
    ) throws -> SaveResult {
        _ = document
        _ = url
        _ = mode
        _ = allowOverlayFallback
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }

    public func validate(_ fileURL: URL) throws -> ValidationReport {
        throw PDFEditorError.unsupportedEngine("PDFKit is unavailable in this environment.")
    }
}
#endif
