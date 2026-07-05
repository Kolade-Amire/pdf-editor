#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import Foundation
import PDFKit
@testable import PdfEditorCore
import XCTest

@MainActor
final class PDFKitEngineTests: XCTestCase {
    func testOpenBuildsMetadataOnlyPlaceholderPageReports() throws {
        let sourceURL = try makePDF(named: "pdfkit-open") { [self] bounds in
            self.drawText(
                "PDFKit metadata-first open",
                in: NSRect(x: 72, y: bounds.height - 180, width: 280, height: 40)
            )
        }

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let engine = PDFKitEngine(readOnlyReason: "Test PDFKit fallback.")
        let document = try engine.open(url: sourceURL)

        XCTAssertEqual(document.descriptor.backend, .pdfKitReadOnlyFallback)
        XCTAssertFalse(document.editabilityReport.isEditable)
        XCTAssertEqual(document.editabilityReport.pageReports.count, 1)
        XCTAssertTrue(document.editabilityReport.pageReports.allSatisfy { !$0.isEditable && $0.issues.isEmpty })
    }

    func testExtractPageAnalysisBuildsImageOnlyReportOnDemand() throws {
        let sourceURL = try makePDF(named: "pdfkit-image-only") { bounds in
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: NSRect(x: 120, y: bounds.height - 260, width: 220, height: 120)).fill()
        }

        defer {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let engine = PDFKitEngine(readOnlyReason: "Test PDFKit fallback.")
        let document = try engine.open(url: sourceURL)
        let analysis = try engine.extractPageAnalysis(from: document, pageIndex: 0)

        XCTAssertFalse(analysis.report.isEditable)
        XCTAssertTrue(analysis.report.issues.contains(where: { $0.kind == .imageOnly }))
        XCTAssertTrue(analysis.blocks.isEmpty)
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
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
