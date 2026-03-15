import Foundation

public enum PDFEngineFactory {
    public static func makeDefault() -> PDFEngine {
        CompositePDFEngine()
    }
}
