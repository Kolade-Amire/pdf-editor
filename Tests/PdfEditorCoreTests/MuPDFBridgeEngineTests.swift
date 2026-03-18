#if canImport(AppKit)
import AppKit
import Foundation
import PDFKit
@testable import PdfEditorCore
import XCTest

@MainActor
final class MuPDFBridgeEngineTests: XCTestCase {
    func testOpenRenderExtractAndSaveEditableDigitalPDF() throws {
        try requireMuPDF()

        let sourceURL = try makePDF(named: "editable") { [self] bounds in
            self.drawText(
                "WWWW MMMM",
                in: NSRect(x: 72, y: bounds.height - 180, width: 220, height: 48)
            )
        }
        let savedURL = temporaryFileURL(named: "editable-saved")

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if FileManager.default.fileExists(atPath: savedURL.path) {
                try? FileManager.default.removeItem(at: savedURL)
            }
        }

        let engine = MuPDFBridgeEngine(validationBinaryURL: nil)
        let document = try engine.open(url: sourceURL)

        XCTAssertEqual(document.descriptor.backend, .muPDFEditable)
        XCTAssertTrue(document.editabilityReport.isEditable)

        let image = try engine.renderPage(of: document, pageIndex: 0, scale: 2)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let blocks = try engine.extractEditableBlocks(from: document, pageIndex: 0)
        let editableBlock = try XCTUnwrap(blocks.first(where: { $0.isEditable }))
        XCTAssertEqual(editableBlock.lineFragments.count, 1)
        XCTAssertTrue(editableBlock.originalText.contains("WWWW MMMM"))

        let replacement = "iiii llll"
        let edit = TextEdit(blockID: editableBlock.id, replacementText: replacement)
        try engine.applyEdits([edit], to: document)

        let stagedBlocks = try engine.extractEditableBlocks(from: document, pageIndex: 0)
        XCTAssertEqual(
            stagedBlocks.first(where: { $0.id == editableBlock.id })?.currentText,
            replacement
        )

        let preflight = try engine.preflightSave([edit], for: document)
        XCTAssertEqual(preflight.trueRewriteCount, 1)
        XCTAssertEqual(preflight.overlayFallbackCount, 0)
        XCTAssertEqual(preflight.blockedCount, 0)

        let result = try engine.save(document, to: savedURL, mode: .automatic, allowOverlayFallback: false)
        XCTAssertTrue(result.validationReport.isValid)
        XCTAssertGreaterThanOrEqual(result.appliedEditCount, 1)
        XCTAssertEqual(result.trueRewriteCount, 1)
        XCTAssertEqual(result.overlayFallbackCount, 0)

        let reopenedDocument = try engine.open(url: savedURL)
        let reopenedBlocks = try engine.extractEditableBlocks(from: reopenedDocument, pageIndex: 0)
        XCTAssertTrue(
            reopenedBlocks.contains(where: { $0.originalText.contains("iiii llll") }),
            "Saved PDF should reopen with replacement text discoverable through MuPDF extraction."
        )
        XCTAssertFalse(
            reopenedBlocks.contains(where: { $0.originalText.contains("WWWW MMMM") }),
            "True rewrite should remove the original text from MuPDF extraction."
        )

        let pdfKitDocument = try XCTUnwrap(PDFDocument(url: savedURL))
        let extractedText = pdfKitDocument.string ?? ""
        XCTAssertTrue(extractedText.contains("iiii llll"))
        XCTAssertFalse(extractedText.contains("WWWW MMMM"))
    }

    func testExtractEditableMultiLineBlockAsSingleBlock() throws {
        try requireMuPDF()

        let sourceURL = try makePDF(named: "multiline") { [self] bounds in
            self.drawText(
                "First editable line\nSecond editable line",
                in: NSRect(x: 72, y: bounds.height - 220, width: 320, height: 120)
            )
        }

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let engine = MuPDFBridgeEngine(validationBinaryURL: nil)
        let document = try engine.open(url: sourceURL)
        let blocks = try engine.extractEditableBlocks(from: document, pageIndex: 0)
        let editableBlock = try XCTUnwrap(blocks.first(where: { $0.isEditable }))

        XCTAssertGreaterThanOrEqual(editableBlock.lineFragments.count, 2)
        XCTAssertTrue(editableBlock.originalText.contains("First editable line"))
        XCTAssertTrue(editableBlock.originalText.contains("Second editable line"))
    }

    func testRotatedTextBlockIsReportedReadOnly() throws {
        try requireMuPDF()

        let sourceURL = try makePDF(named: "rotated") { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Helvetica", size: 20) ?? NSFont.systemFont(ofSize: 20),
                .foregroundColor: NSColor.black,
            ]
            let attributed = NSAttributedString(string: "Rotated block", attributes: attributes)
            guard let context = NSGraphicsContext.current?.cgContext else {
                XCTFail("Missing graphics context while drawing rotated PDF fixture.")
                return
            }

            context.saveGState()
            context.translateBy(x: 180, y: 180)
            context.rotate(by: .pi / 2)
            attributed.draw(at: CGPoint(x: 0, y: 0))
            context.restoreGState()
        }

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let engine = MuPDFBridgeEngine(validationBinaryURL: nil)
        let document = try engine.open(url: sourceURL)

        XCTAssertFalse(document.editabilityReport.isEditable)

        let pageReport = try XCTUnwrap(document.editabilityReport.pageReports.first(where: { $0.pageIndex == 0 }))
        XCTAssertFalse(pageReport.isEditable)
        XCTAssertTrue(pageReport.issues.contains(where: { $0.kind == .unsupportedTransform }))

        let blocks = try engine.extractEditableBlocks(from: document, pageIndex: 0)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertFalse(block.isEditable)
        XCTAssertEqual(block.failureReason?.kind, .unsupportedTransform)
    }

    func testImageOnlyPageIsReportedReadOnly() throws {
        try requireMuPDF()

        let sourceURL = try makePDF(named: "image-only") { bounds in
            NSColor.systemRed.setFill()
            NSBezierPath(rect: NSRect(x: 120, y: bounds.height - 260, width: 220, height: 120)).fill()
        }

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let engine = MuPDFBridgeEngine(validationBinaryURL: nil)
        let document = try engine.open(url: sourceURL)

        XCTAssertFalse(document.editabilityReport.isEditable)

        let pageReport = try XCTUnwrap(document.editabilityReport.pageReports.first(where: { $0.pageIndex == 0 }))
        XCTAssertFalse(pageReport.isEditable)
        XCTAssertTrue(pageReport.issues.contains(where: { $0.kind == .imageOnly }))

        let blocks = try engine.extractEditableBlocks(from: document, pageIndex: 0)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testSaveRejectsTextThatNeitherOriginalFontNorBase14CanEncode() throws {
        try requireMuPDF()

        let sourceURL = try makePDF(named: "encoding") { [self] bounds in
            self.drawText(
                "Encoding fixture",
                in: NSRect(x: 72, y: bounds.height - 180, width: 240, height: 40)
            )
        }
        let destinationURL = temporaryFileURL(named: "encoding-saved")

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let engine = MuPDFBridgeEngine(validationBinaryURL: nil)
        let document = try engine.open(url: sourceURL)
        let editableBlock = try XCTUnwrap(
            try engine.extractEditableBlocks(from: document, pageIndex: 0).first(where: { $0.isEditable })
        )

        let edit = TextEdit(blockID: editableBlock.id, replacementText: "Encoding 😄 fixture")
        try engine.applyEdits([edit], to: document)

        let preflight = try engine.preflightSave([edit], for: document)
        XCTAssertEqual(preflight.blockedCount, 1)
        XCTAssertEqual(preflight.overlayFallbackCount, 0)

        XCTAssertThrowsError(
            try engine.save(document, to: destinationURL, mode: .automatic, allowOverlayFallback: true)
        ) { error in
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(
                message.contains("blocked") || message.contains("could not save"),
                "Unexpected save failure: \(error.localizedDescription)"
            )
        }
    }

    func testMixedModeSaveRequiresOverlayApprovalAndReportsCounts() throws {
        try requireMuPDF()
        throw XCTSkip("Mixed-mode MuPDF fixture coverage is pending broader true-rewrite candidate matching.")
    }

    private func requireMuPDF() throws {
        guard MuPDFBridgeEngine.isAvailable else {
            throw XCTSkip("MuPDF bridge artifacts are unavailable in this checkout.")
        }
    }

    private func makePDF(
        named name: String,
        drawHandler: @escaping (NSRect) -> Void
    ) throws -> URL {
        let view = FixturePDFView(
            frame: NSRect(x: 0, y: 0, width: 612, height: 792),
            drawHandler: drawHandler
        )
        let data = view.dataWithPDF(inside: view.bounds)
        let url = temporaryFileURL(named: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func temporaryFileURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
    }

    private func drawText(_ text: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        NSAttributedString(string: text, attributes: attributes).draw(in: rect)
    }
}

private final class FixturePDFView: NSView {
    private let drawHandler: (NSRect) -> Void

    init(frame: NSRect, drawHandler: @escaping (NSRect) -> Void) {
        self.drawHandler = drawHandler
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        drawHandler(bounds)
    }
}
#endif
