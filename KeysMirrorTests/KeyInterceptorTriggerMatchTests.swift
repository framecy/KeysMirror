import XCTest
import CoreGraphics
@testable import KeysMirror

@MainActor
final class KeyInterceptorTriggerMatchTests: XCTestCase {
    // MARK: - keyboard

    func testKeyboardKeyCodeMatchesWithoutModifiers() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        XCTAssertTrue(KeyInterceptor.triggerMatches(
            event: event, type: .keyDown,
            keyCode: 12, eventModifiers: 0, buttonNumber: 0,
            triggerType: .keyboard, mappingKeyCode: 12,
            mappingModifiers: 0, mappingButton: nil
        ))
    }

    func testKeyboardModifierMismatchDoesNotMatch() throws {
        // event 没带 cmd；映射要求 cmd
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .keyDown,
            keyCode: 12, eventModifiers: 0, buttonNumber: 0,
            triggerType: .keyboard, mappingKeyCode: 12,
            mappingModifiers: CGEventFlags.maskCommand.rawValue, mappingButton: nil
        ))
    }

    func testKeyboardKeyCodeMismatchDoesNotMatch() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .keyDown,
            keyCode: 12, eventModifiers: 0, buttonNumber: 0,
            triggerType: .keyboard, mappingKeyCode: 13,
            mappingModifiers: 0, mappingButton: nil
        ))
    }

    func testKeyboardAutorepeatDoesNotMatch() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .keyDown,
            keyCode: 12, eventModifiers: 0, buttonNumber: 0,
            triggerType: .keyboard, mappingKeyCode: 12,
            mappingModifiers: 0, mappingButton: nil
        ))
    }

    // MARK: - mouse

    func testMouseRightAlwaysMatchesOnRightMouseDown() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: .zero, mouseButton: .right
        ))
        XCTAssertTrue(KeyInterceptor.triggerMatches(
            event: event, type: .rightMouseDown,
            keyCode: 0, eventModifiers: 0, buttonNumber: 1,
            triggerType: .mouseRight, mappingKeyCode: 0,
            mappingModifiers: 0, mappingButton: nil
        ))
    }

    func testMouseOtherMatchesByButtonNumber() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseDown,
            mouseCursorPosition: .zero, mouseButton: .center
        ))
        XCTAssertTrue(KeyInterceptor.triggerMatches(
            event: event, type: .otherMouseDown,
            keyCode: 0, eventModifiers: 0, buttonNumber: 3,
            triggerType: .mouseOther, mappingKeyCode: 0,
            mappingModifiers: 0, mappingButton: 3
        ))
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .otherMouseDown,
            keyCode: 0, eventModifiers: 0, buttonNumber: 3,
            triggerType: .mouseOther, mappingKeyCode: 0,
            mappingModifiers: 0, mappingButton: 4
        ))
    }

    // MARK: - cross-type

    func testKeyboardEventDoesNotMatchMouseTrigger() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .keyDown,
            keyCode: 12, eventModifiers: 0, buttonNumber: 0,
            triggerType: .mouseOther, mappingKeyCode: 0,
            mappingModifiers: 0, mappingButton: 3
        ))
    }

    func testMouseEventDoesNotMatchKeyboardTrigger() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseDown,
            mouseCursorPosition: .zero, mouseButton: .center
        ))
        XCTAssertFalse(KeyInterceptor.triggerMatches(
            event: event, type: .otherMouseDown,
            keyCode: 0, eventModifiers: 0, buttonNumber: 3,
            triggerType: .keyboard, mappingKeyCode: 12,
            mappingModifiers: 0, mappingButton: nil
        ))
    }
}
