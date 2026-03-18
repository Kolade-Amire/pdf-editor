import CoreGraphics
import Foundation

public struct TextQuad: Hashable, Sendable {
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomLeft: CGPoint
    public let bottomRight: CGPoint

    public init(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    public static func rect(_ rect: CGRect) -> TextQuad {
        TextQuad(
            topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        )
    }
}

public struct PDFColor: Hashable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = PDFColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = PDFColor(red: 1, green: 1, blue: 1, alpha: 1)
}

public struct TextStyle: Hashable, Sendable {
    public let fontPostScriptName: String
    public let fontSize: CGFloat
    public let color: PDFColor
    public let characterSpacing: CGFloat
    public let horizontalScale: CGFloat
    public let rise: CGFloat
    public let isBold: Bool
    public let isItalic: Bool
    public let isMonospaced: Bool
    public let isSerif: Bool

    public init(
        fontPostScriptName: String,
        fontSize: CGFloat,
        color: PDFColor,
        characterSpacing: CGFloat = 0,
        horizontalScale: CGFloat = 1,
        rise: CGFloat = 0,
        isBold: Bool = false,
        isItalic: Bool = false,
        isMonospaced: Bool = false,
        isSerif: Bool = false
    ) {
        self.fontPostScriptName = fontPostScriptName
        self.fontSize = fontSize
        self.color = color
        self.characterSpacing = characterSpacing
        self.horizontalScale = horizontalScale
        self.rise = rise
        self.isBold = isBold
        self.isItalic = isItalic
        self.isMonospaced = isMonospaced
        self.isSerif = isSerif
    }
}

public enum PDFBackendKind: String, Hashable, Sendable {
    case muPDFEditable
    case muPDFReadOnly
    case pdfKitReadOnlyFallback

    public var displayName: String {
        switch self {
        case .muPDFEditable:
            "MuPDF editable"
        case .muPDFReadOnly:
            "MuPDF read-only"
        case .pdfKitReadOnlyFallback:
            "PDFKit read-only fallback"
        }
    }

    public var supportsWrites: Bool {
        self == .muPDFEditable
    }
}

public enum FontFallbackFamily: String, Hashable, Sendable {
    case sans
    case serif
    case monospace
}

public enum FontFallbackSource: String, Hashable, Sendable {
    case originalFont
    case bundledFont
    case systemBase14
}

public struct FontFallbackPlan: Hashable, Sendable {
    public let requestedFontPostScriptName: String
    public let resolvedFontName: String
    public let family: FontFallbackFamily
    public let source: FontFallbackSource
    public let warning: String?

    public init(
        requestedFontPostScriptName: String,
        resolvedFontName: String,
        family: FontFallbackFamily,
        source: FontFallbackSource,
        warning: String? = nil
    ) {
        self.requestedFontPostScriptName = requestedFontPostScriptName
        self.resolvedFontName = resolvedFontName
        self.family = family
        self.source = source
        self.warning = warning
    }
}

public enum EditabilityIssueKind: String, Hashable, Sendable {
    case encrypted
    case imageOnly
    case signed
    case unsupportedFont
    case unsupportedStructure
    case unsupportedTransform
    case missingFontMetrics
    case rightsRestricted
    case passwordRequired
    case textOverflow
    case validationFailed
    case engineUnavailable
}

public struct EditabilityIssue: Identifiable, Hashable, Sendable {
    public let kind: EditabilityIssueKind
    public let message: String
    public let pageIndex: Int?
    public let blockID: String?
    public let runID: String?

    public init(
        kind: EditabilityIssueKind,
        message: String,
        pageIndex: Int? = nil,
        blockID: String? = nil,
        runID: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.runID = runID
    }

    public var id: String {
        let page = pageIndex.map(String.init) ?? "document"
        let block = blockID ?? "all-blocks"
        let run = runID ?? "all-runs"
        return "\(kind.rawValue):\(page):\(block):\(run):\(message)"
    }
}

public struct PageEditabilityReport: Hashable, Sendable {
    public let pageIndex: Int
    public let isEditable: Bool
    public let issues: [EditabilityIssue]

    public init(pageIndex: Int, isEditable: Bool, issues: [EditabilityIssue]) {
        self.pageIndex = pageIndex
        self.isEditable = isEditable
        self.issues = issues
    }
}

public struct EditabilityReport: Hashable, Sendable {
    public let isEditable: Bool
    public let issues: [EditabilityIssue]
    public let pageReports: [PageEditabilityReport]

    public init(isEditable: Bool, issues: [EditabilityIssue], pageReports: [PageEditabilityReport]) {
        self.isEditable = isEditable
        self.issues = issues
        self.pageReports = pageReports
    }

    public static let empty = EditabilityReport(isEditable: false, issues: [], pageReports: [])
}

public struct PDFDocumentDescriptor: Hashable, Sendable {
    public let sourceURL: URL
    public let pageCount: Int
    public let title: String?
    public let isEncrypted: Bool
    public let isLocked: Bool
    public let canEdit: Bool
    public let isSigned: Bool
    public let backend: PDFBackendKind

    public init(
        sourceURL: URL,
        pageCount: Int,
        title: String?,
        isEncrypted: Bool,
        isLocked: Bool,
        canEdit: Bool,
        isSigned: Bool,
        backend: PDFBackendKind
    ) {
        self.sourceURL = sourceURL
        self.pageCount = pageCount
        self.title = title
        self.isEncrypted = isEncrypted
        self.isLocked = isLocked
        self.canEdit = canEdit
        self.isSigned = isSigned
        self.backend = backend
    }
}

public struct LoadedPDFDocument: Hashable, Sendable {
    public let id: UUID
    public let descriptor: PDFDocumentDescriptor
    public let editabilityReport: EditabilityReport

    public init(id: UUID, descriptor: PDFDocumentDescriptor, editabilityReport: EditabilityReport) {
        self.id = id
        self.descriptor = descriptor
        self.editabilityReport = editabilityReport
    }
}

public struct BlockLineFragment: Identifiable, Hashable, Sendable {
    public let id: String
    public let blockID: String
    public let pageIndex: Int
    public let bounds: CGRect
    public let quads: [TextQuad]
    public let originalText: String
    public let currentText: String
    public let style: TextStyle
    public let isEditable: Bool
    public let failureReason: EditabilityIssue?

    public init(
        id: String,
        blockID: String,
        pageIndex: Int,
        bounds: CGRect,
        quads: [TextQuad],
        originalText: String,
        currentText: String,
        style: TextStyle,
        isEditable: Bool,
        failureReason: EditabilityIssue?
    ) {
        self.id = id
        self.blockID = blockID
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.quads = quads
        self.originalText = originalText
        self.currentText = currentText
        self.style = style
        self.isEditable = isEditable
        self.failureReason = failureReason
    }
}

public struct EditableTextRun: Identifiable, Hashable, Sendable {
    public let id: String
    public let blockID: String
    public let pageIndex: Int
    public let bounds: CGRect
    public let quads: [TextQuad]
    public let originalText: String
    public let currentText: String
    public let style: TextStyle
    public let isEditable: Bool
    public let failureReason: EditabilityIssue?

    public init(
        id: String,
        blockID: String,
        pageIndex: Int,
        bounds: CGRect,
        quads: [TextQuad],
        originalText: String,
        currentText: String,
        style: TextStyle,
        isEditable: Bool,
        failureReason: EditabilityIssue?
    ) {
        self.id = id
        self.blockID = blockID
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.quads = quads
        self.originalText = originalText
        self.currentText = currentText
        self.style = style
        self.isEditable = isEditable
        self.failureReason = failureReason
    }
}

public enum BlockPersistenceMode: String, Hashable, Sendable {
    case trueRewrite
    case overlayFallback
    case blocked

    public var displayName: String {
        switch self {
        case .trueRewrite:
            "True edit"
        case .overlayFallback:
            "Overlay fallback if saved"
        case .blocked:
            "Read-only"
        }
    }

    public var requiresExplicitConfirmation: Bool {
        self == .overlayFallback
    }
}

public struct EditableTextBlock: Identifiable, Hashable, Sendable {
    public let id: String
    public let pageIndex: Int
    public let bounds: CGRect
    public let originalText: String
    public let currentText: String
    public let style: TextStyle
    public let lineFragments: [BlockLineFragment]
    public let isEditable: Bool
    public let failureReason: EditabilityIssue?
    public let fallbackPlan: FontFallbackPlan
    public let persistenceMode: BlockPersistenceMode
    public let persistenceMessage: String?

    public init(
        id: String,
        pageIndex: Int,
        bounds: CGRect,
        originalText: String,
        currentText: String,
        style: TextStyle,
        lineFragments: [BlockLineFragment],
        isEditable: Bool,
        failureReason: EditabilityIssue?,
        fallbackPlan: FontFallbackPlan,
        persistenceMode: BlockPersistenceMode,
        persistenceMessage: String? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.originalText = originalText
        self.currentText = currentText
        self.style = style
        self.lineFragments = lineFragments
        self.isEditable = isEditable
        self.failureReason = failureReason
        self.fallbackPlan = fallbackPlan
        self.persistenceMode = persistenceMode
        self.persistenceMessage = persistenceMessage
    }

    public var displayRuns: [EditableTextRun] {
        lineFragments.map {
            EditableTextRun(
                id: $0.id,
                blockID: id,
                pageIndex: $0.pageIndex,
                bounds: $0.bounds,
                quads: $0.quads,
                originalText: $0.originalText,
                currentText: $0.currentText,
                style: $0.style,
                isEditable: $0.isEditable,
                failureReason: $0.failureReason
            )
        }
    }
}

public struct TextEdit: Hashable, Sendable {
    public let blockID: String
    public let replacementText: String

    public init(blockID: String, replacementText: String) {
        self.blockID = blockID
        self.replacementText = replacementText
    }
}

package enum PageBlockLoadState: Hashable, Sendable {
    case unloaded
    case loading
    case loaded
    case failed(message: String)

    package var displayName: String {
        switch self {
        case .unloaded:
            "Not loaded"
        case .loading:
            "Loading editable blocks"
        case .loaded:
            "Loaded"
        case .failed:
            "Failed to load"
        }
    }

    package var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }

        return message
    }
}

public enum SaveMode: String, Hashable, Sendable {
    case automatic
    case incremental
    case fullRewrite
}

public struct ValidationReport: Hashable, Sendable {
    public let isValid: Bool
    public let validator: String
    public let messages: [String]

    public init(isValid: Bool, validator: String, messages: [String]) {
        self.isValid = isValid
        self.validator = validator
        self.messages = messages
    }
}

public struct SavePreflightBlockOutcome: Identifiable, Hashable, Sendable {
    public let blockID: String
    public let pageIndex: Int
    public let mode: BlockPersistenceMode
    public let message: String

    public init(blockID: String, pageIndex: Int, mode: BlockPersistenceMode, message: String) {
        self.blockID = blockID
        self.pageIndex = pageIndex
        self.mode = mode
        self.message = message
    }

    public var id: String {
        "\(pageIndex):\(blockID):\(mode.rawValue):\(message)"
    }
}

public struct SavePreflightReport: Hashable, Sendable {
    public let blockOutcomes: [SavePreflightBlockOutcome]
    public let warnings: [String]

    public init(blockOutcomes: [SavePreflightBlockOutcome], warnings: [String] = []) {
        self.blockOutcomes = blockOutcomes
        self.warnings = warnings
    }

    public var trueRewriteCount: Int {
        blockOutcomes.filter { $0.mode == .trueRewrite }.count
    }

    public var overlayFallbackCount: Int {
        blockOutcomes.filter { $0.mode == .overlayFallback }.count
    }

    public var blockedCount: Int {
        blockOutcomes.filter { $0.mode == .blocked }.count
    }

    public var requiresOverlayConfirmation: Bool {
        overlayFallbackCount > 0
    }

    public var canProceed: Bool {
        blockedCount == 0
    }
}

public struct SavedBlockOutcome: Identifiable, Hashable, Sendable {
    public let blockID: String
    public let pageIndex: Int
    public let mode: BlockPersistenceMode
    public let message: String

    public init(blockID: String, pageIndex: Int, mode: BlockPersistenceMode, message: String) {
        self.blockID = blockID
        self.pageIndex = pageIndex
        self.mode = mode
        self.message = message
    }

    public var id: String {
        "\(pageIndex):\(blockID):\(mode.rawValue):\(message)"
    }
}

public struct SaveResult: Hashable, Sendable {
    public let fileURL: URL
    public let usedSaveMode: SaveMode
    public let appliedEditCount: Int
    public let savedBlockOutcomes: [SavedBlockOutcome]
    public let validationReport: ValidationReport

    public init(
        fileURL: URL,
        usedSaveMode: SaveMode,
        appliedEditCount: Int,
        savedBlockOutcomes: [SavedBlockOutcome],
        validationReport: ValidationReport
    ) {
        self.fileURL = fileURL
        self.usedSaveMode = usedSaveMode
        self.appliedEditCount = appliedEditCount
        self.savedBlockOutcomes = savedBlockOutcomes
        self.validationReport = validationReport
    }

    public var trueRewriteCount: Int {
        savedBlockOutcomes.filter { $0.mode == .trueRewrite }.count
    }

    public var overlayFallbackCount: Int {
        savedBlockOutcomes.filter { $0.mode == .overlayFallback }.count
    }
}

public enum PDFEditorError: LocalizedError, Equatable {
    case failedToOpen(URL)
    case missingDocument
    case pageOutOfRange(Int)
    case passwordRequired
    case invalidPassword
    case readOnly(String)
    case blockNotFound(String)
    case textDoesNotFit(blockID: String)
    case saveFailed(String)
    case validationFailed(String)
    case unsupportedEngine(String)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let url):
            "Failed to open PDF at \(url.path)."
        case .missingDocument:
            "No document is currently loaded."
        case .pageOutOfRange(let pageIndex):
            "Page \(pageIndex + 1) does not exist."
        case .passwordRequired:
            "This PDF requires a password before it can be edited."
        case .invalidPassword:
            "The provided password did not unlock the document."
        case .readOnly(let reason):
            reason
        case .blockNotFound(let blockID):
            "Could not find editable text block \(blockID)."
        case .textDoesNotFit(let blockID):
            "Edited text for block \(blockID) does not fit inside the original bounds."
        case .saveFailed(let reason):
            reason
        case .validationFailed(let reason):
            reason
        case .unsupportedEngine(let reason):
            reason
        }
    }
}
