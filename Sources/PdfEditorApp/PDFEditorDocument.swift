import AppKit
import PdfEditorCore

@MainActor
final class PDFEditorDocument: NSDocument {
    let session = DocumentSession()

    override class var autosavesInPlace: Bool {
        true
    }

    override func read(from url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            try session.load(url: url)
        }
    }

    override func write(to url: URL, ofType typeName: String) throws {
        _ = try MainActor.assumeIsolated {
            try session.save(to: url)
        }
    }
}
