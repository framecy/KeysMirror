@preconcurrency import CoreGraphics
import Foundation
import AppKit

enum CapturedTrigger {
    case keyboard(keyCode: UInt16, modifiers: UInt64)
    case mouseRight
    case mouseOther(buttonNumber: Int)
}

@MainActor
final class TriggerRecorder {
    static let shared = TriggerRecorder()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onTriggerCaptured: ((CapturedTrigger) -> Void)?

    private init() {}

    func start(onTriggerCaptured: @escaping (CapturedTrigger) -> Void) -> Bool {
        stop()
        self.onTriggerCaptured = onTriggerCaptured

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.onTriggerCaptured = nil
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        onTriggerCaptured = nil
    }

    private func process(type: CGEventType, event: CGEvent?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        guard let event else { return nil }

        let trigger: CapturedTrigger
        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = ModifierHelper.cleanModifiers(from: event.flags)
            trigger = .keyboard(keyCode: keyCode, modifiers: modifiers)
        case .rightMouseDown:
            trigger = .mouseRight
        case .otherMouseDown:
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            trigger = .mouseOther(buttonNumber: buttonNumber)
        default:
            return Unmanaged.passRetained(event)
        }

        let handler = onTriggerCaptured
        stop()
        handler?(trigger)

        return nil
    }

    private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let recorder = Unmanaged<TriggerRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        return recorder.handleCallback(type: type, event: event)
    }

    private nonisolated func handleCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let optionalEvent: CGEvent? = (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput) ? nil : event
        let unsafeEvent = UnsafeOptionalEvent(value: optionalEvent)
        return MainActor.assumeIsolated {
            process(type: type, event: unsafeEvent.value)
        }
    }
}

private struct UnsafeOptionalEvent: @unchecked Sendable {
    let value: CGEvent?
}
