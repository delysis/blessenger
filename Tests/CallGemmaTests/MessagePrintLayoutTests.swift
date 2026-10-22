#if os(macOS)
import AppKit
import XCTest
@testable import CallGemma

final class MessagePrintLayoutTests: XCTestCase {
    @MainActor
    func testShortMessageFitsOnePageAndLongMessageIsNotClipped() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        let short = MessagePrintLayout.makeView(text: "Ada\n\nHello!", printInfo: info)
        XCTAssertLessThan(short.frame.height, 100)
        XCTAssertEqual(short.frame.width, 540)
        XCTAssertEqual(short.textColor, .black)
        let long = MessagePrintLayout.makeView(text: String(repeating: "A complete line of conversation.\n", count: 200), printInfo: info)
        XCTAssertGreaterThan(long.frame.height, 720)
        XCTAssertEqual(long.string.components(separatedBy: "\n").count, 201)
    }
}
#endif
