#if canImport(AppKit)
import AppKit
#endif
import Foundation

public struct TextFitResult: Hashable, Sendable {
    public let fits: Bool
    public let measuredSize: CGSize
    public let overflowWidth: CGFloat
    public let overflowHeight: CGFloat

    public init(fits: Bool, measuredSize: CGSize, overflowWidth: CGFloat, overflowHeight: CGFloat) {
        self.fits = fits
        self.measuredSize = measuredSize
        self.overflowWidth = overflowWidth
        self.overflowHeight = overflowHeight
    }
}

public struct TextFitEvaluator: Sendable {
    public init() {}

    public func evaluate(text: String, in block: EditableTextBlock) -> TextFitResult {
        let measured = measure(
            text: text,
            style: block.style,
            constrainedTo: CGSize(width: block.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        )
        let overflowWidth = max(0, measured.width - block.bounds.width)
        let overflowHeight = max(0, measured.height - block.bounds.height)

        return TextFitResult(
            fits: overflowWidth <= 0.5 && overflowHeight <= 0.5,
            measuredSize: measured,
            overflowWidth: overflowWidth,
            overflowHeight: overflowHeight
        )
    }

    public func evaluate(text: String, in run: EditableTextRun) -> TextFitResult {
        let measured = measure(
            text: text,
            style: run.style,
            constrainedTo: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let overflowWidth = max(0, measured.width - run.bounds.width)
        let overflowHeight = max(0, measured.height - run.bounds.height)

        return TextFitResult(
            fits: overflowWidth <= 0.5 && overflowHeight <= 0.5,
            measuredSize: measured,
            overflowWidth: overflowWidth,
            overflowHeight: overflowHeight
        )
    }

    private func measure(text: String, style: TextStyle, constrainedTo size: CGSize) -> CGSize {
        #if canImport(AppKit)
        let font = NSFont(name: style.fontPostScriptName, size: style.fontSize)
            ?? NSFont.systemFont(ofSize: style.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: style.characterSpacing,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral.size
        return CGSize(width: max(size.width, 1), height: max(size.height, font.ascender - font.descender))
        #else
        let width = min(CGFloat(text.count) * style.fontSize * 0.55, size.width)
        let estimatedLines = max(1, ceil((CGFloat(text.count) * style.fontSize * 0.55) / max(size.width, 1)))
        return CGSize(width: width, height: estimatedLines * style.fontSize * 1.2)
        #endif
    }
}
