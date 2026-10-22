#if os(macOS)
import AppKit

@MainActor
enum MessagePrintLayout {
    static func makeView(text: String, printInfo: NSPrintInfo) -> NSTextView {
        let width = max(1, printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.minSize = .zero
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.string = text
        view.font = .systemFont(ofSize: 12)
        view.textColor = .black
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: max(1, ceil(layout.usedRect(for: container).maxY))))
        }
        return view
    }
}
#endif
