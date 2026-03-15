import AppKit
import PdfEditorCore
import SwiftUI

struct PageCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    let pageIndex: Int
    private let renderScale: CGFloat = 2

    func makeNSView(context: Context) -> PageCanvasView {
        let view = PageCanvasView()
        view.onSelectRun = { runID in
            session.selectRun(runID)
        }
        view.onEditText = { text in
            session.updateDraftText(text)
        }
        return view
    }

    func updateNSView(_ nsView: PageCanvasView, context: Context) {
        do {
            let image = try session.renderPage(pageIndex: pageIndex, scale: renderScale)
            nsView.image = image
            nsView.pageSize = CGSize(
                width: CGFloat(image.width) / renderScale,
                height: CGFloat(image.height) / renderScale
            )
        } catch {
            nsView.image = nil
            nsView.pageSize = .zero
        }

        nsView.pageIndex = pageIndex
        nsView.runs = session.runs(for: pageIndex)
        nsView.selectedBlock = session.selectedBlock?.pageIndex == pageIndex ? session.selectedBlock : nil
        nsView.selectedRunID = session.selectedRunID
        nsView.selectedText = session.draftText
    }
}

final class PageCanvasView: NSView, NSTextFieldDelegate {
    var image: CGImage? {
        didSet {
            needsDisplay = true
        }
    }

    var pageSize: CGSize = .zero {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var pageIndex = 0

    var runs: [EditableTextRun] = [] {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    var selectedBlock: EditableTextBlock? {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    var selectedRunID: String? {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    var selectedText = "" {
        didSet {
            syncEditorField()
        }
    }

    var onSelectRun: ((String?) -> Void)?
    var onEditText: ((String) -> Void)?

    private let editorField = NSTextField()
    private var isProgrammaticUpdate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupEditorField()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupEditorField()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        guard let image, pageSize.width > 0, pageSize.height > 0 else {
            return
        }

        let drawRect = aspectFitRect(for: pageSize, in: bounds)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.interpolationQuality = .high
        context.draw(image, in: drawRect)

        for run in runs {
            let highlightRect = rectForRun(run)
            let color: NSColor
            if selectedBlock?.id == run.blockID {
                color = .systemBlue
            } else if run.isEditable {
                color = NSColor.systemBlue.withAlphaComponent(0.3)
            } else {
                color = NSColor.systemGray.withAlphaComponent(0.2)
            }

            color.setStroke()
            let path = NSBezierPath(rect: highlightRect)
            path.lineWidth = selectedBlock?.id == run.blockID ? 2 : 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let point = pdfPoint(for: location) else {
            onSelectRun?(nil)
            return
        }

        let run = runs.first { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
        onSelectRun?(run?.id)
    }

    override func layout() {
        super.layout()
        positionEditorField()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticUpdate else {
            return
        }

        onEditText?(editorField.stringValue)
    }

    private func setupEditorField() {
        editorField.isHidden = true
        editorField.isBordered = true
        editorField.backgroundColor = .white.withAlphaComponent(0.95)
        editorField.delegate = self
        addSubview(editorField)
    }

    private func syncEditorField() {
        guard editorField.stringValue != selectedText else {
            return
        }

        isProgrammaticUpdate = true
        editorField.stringValue = selectedText
        isProgrammaticUpdate = false
    }

    private func positionEditorField() {
        guard let block = selectedBlock else {
            editorField.isHidden = true
            return
        }

        let rect = rectForBlock(block)
        editorField.frame = rect
        editorField.font = NSFont(name: block.style.fontPostScriptName, size: block.style.fontSize)
            ?? NSFont.systemFont(ofSize: block.style.fontSize)
        editorField.textColor = NSColor(
            red: block.style.color.red,
            green: block.style.color.green,
            blue: block.style.color.blue,
            alpha: block.style.color.alpha
        )
        syncEditorField()
        editorField.isHidden = !block.isEditable
    }

    private func rectForRun(_ run: EditableTextRun) -> CGRect {
        scaledRect(for: run.bounds)
    }

    private func rectForBlock(_ block: EditableTextBlock) -> CGRect {
        scaledRect(for: block.bounds)
    }

    private func scaledRect(for boundsInPage: CGRect) -> CGRect {
        let drawRect = aspectFitRect(for: pageSize, in: bounds)
        let scaleX = drawRect.width / pageSize.width
        let scaleY = drawRect.height / pageSize.height

        return CGRect(
            x: drawRect.minX + (boundsInPage.minX * scaleX),
            y: drawRect.minY + (boundsInPage.minY * scaleY),
            width: max(boundsInPage.width * scaleX, 24),
            height: max(boundsInPage.height * scaleY, 20)
        )
    }

    private func pdfPoint(for viewPoint: CGPoint) -> CGPoint? {
        let drawRect = aspectFitRect(for: pageSize, in: bounds)
        guard drawRect.contains(viewPoint) else {
            return nil
        }

        let x = ((viewPoint.x - drawRect.minX) / drawRect.width) * pageSize.width
        let y = ((viewPoint.y - drawRect.minY) / drawRect.height) * pageSize.height
        return CGPoint(x: x, y: y)
    }

    private func aspectFitRect(for contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale

        return CGRect(
            x: bounds.midX - (width / 2),
            y: bounds.midY - (height / 2),
            width: width,
            height: height
        )
    }
}
