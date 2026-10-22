#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import CallGemma

@MainActor
final class ContactAvatarTests: XCTestCase {
    func testEveryPortraitIsAnIndependentAssetAndRendersAtControlSize() throws {
        var portraits = Set<Data>()
        for index in 0..<14 {
            let asset = try XCTUnwrap(BlessengerResources.bundle.image(forResource: "contact-portrait-\(index)"))
            let pixels = try XCTUnwrap(asset.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(pixels.width, 314)
            XCTAssertEqual(pixels.height, 314)
            portraits.insert(try XCTUnwrap(asset.tiffRepresentation))
            for size in [CGFloat(28), 42, 48] {
                let renderer = ImageRenderer(content: ContactAvatar(value: "portrait:\(index)", size: size))
                renderer.scale = 1
                let rendered = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(rendered.width, Int(size))
                XCTAssertEqual(rendered.height, Int(size))
            }
        }
        XCTAssertEqual(portraits.count, 14)
    }

    func testNativeMenuCannotExposeThePortraitAtlas() throws {
        let menu = Menu { Button("Participant") {} } label: {
            ContactAvatar(value: "portrait:0", size: 28)
        }.menuStyle(.borderlessButton).fixedSize()
        let host = NSHostingView(rootView: menu)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let native = buttons(host)
        XCTAssertFalse(native.isEmpty, "Exercise the AppKit menu bridge, not just SwiftUI rendering")
        for button in native {
            let image = try XCTUnwrap(button.image, "The native menu must retain the portrait")
            XCTAssertEqual(image.size.width, 28)
            XCTAssertEqual(image.size.height, 28)
            XCTAssertLessThanOrEqual(button.fittingSize.height, 52)
        }
        window.contentView = nil
    }
}
#endif
