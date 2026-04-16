@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class PointRecorder {
    static let shared = PointRecorder()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onPointCaptured: ((CGPoint) -> Void)?

    private init() {}

    func start(onPointCaptured: @escaping (CGPoint) -> Void) -> Bool {
        stop()
        self.onPointCaptured = onPointCaptured

        let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.onPointCaptured = nil
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
        onPointCaptured = nil
    }

    private func process(type: CGEventType, event: CGEvent?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        guard let event else { return nil }

        guard type == .leftMouseDown else {
            return Unmanaged.passRetained(event)
        }

        let point = event.location
        let handler = onPointCaptured
        stop()
        handler?(point)
        return Unmanaged.passRetained(event)
    }

    private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let recorder = Unmanaged<PointRecorder>.fromOpaque(userInfo).takeUnretainedValue()
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
