@preconcurrency import CoreGraphics
import Foundation

/// 录制到的一次鼠标按下。
struct RecordedClick {
    /// 事件坐标（CG / AX 全局坐标系，原点在主屏左上角）
    let location: CGPoint
    /// 录制起点以来的秒数
    let elapsed: TimeInterval
    /// 系统的连击计数：1 = 单击，2 = 双击的第二下，3 = 三击的第三下
    let clickState: Int
}

/// 已经换算成窗口内相对坐标的一次点击，`MacroSequenceRecorder.buildSteps` 的输入。
struct SequenceSample: Hashable {
    var relativePoint: CGPoint
    var referenceSize: CGSize
    var elapsed: TimeInterval
    var clickState: Int
}

/// 连续录制鼠标点击序列：与只抓一个点的 `PointRecorder` 不同，这里在用户手动停止前
/// 一直记录，每次点击带上位置、时间戳和连击计数，用来一次性生成整串宏步骤。
///
/// tap 用 `.defaultTap` 而不是 `.listenOnly`：鼠标事件原样放行（用户是在真的操作目标 app），
/// 只吞掉 Esc 用作「结束录制」，避免 Esc 同时在游戏里弹出菜单。
@MainActor
final class MacroSequenceRecorder {
    static let shared = MacroSequenceRecorder()

    /// Esc，用于结束录制
    private static let escapeKeyCode: UInt16 = 53

    private(set) var isRecording = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onClick: ((RecordedClick) -> Void)?
    private var onFinish: (() -> Void)?
    private var startedAt: TimeInterval = 0

    private init() {}

    /// - Parameters:
    ///   - onClick: 每次鼠标左键按下时回调
    ///   - onFinish: 用户按 Esc 结束录制时回调（主动调用 `stop()` 不会触发）
    func start(onClick: @escaping (RecordedClick) -> Void, onFinish: @escaping () -> Void) -> Bool {
        stop()
        self.onClick = onClick
        self.onFinish = onFinish
        self.startedAt = Date.timeIntervalSinceReferenceDate

        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.onClick = nil
            self.onFinish = nil
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
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
        onClick = nil
        onFinish = nil
        isRecording = false
    }

    // MARK: - Pure helpers (testable)

    /// 同一位置的连击判定阈值：与系统双击间隔同量级。
    static let multiClickInterval: TimeInterval = 0.5
    /// 连击的位置容差（窗口内点数）
    static let multiClickTolerance: CGFloat = 8

    /// 把录制到的点击样本转成宏步骤：
    /// - 相邻两次点击若构成连击（系统的 clickState > 1，或间隔够短且位置够近），合并成一步并累加 `clickCount`；
    /// - 每一步的 `delaySeconds` = 与上一步首次点击的时间差；第一步为 0，让宏触发后立即开始。
    static func buildSteps(from samples: [SequenceSample]) -> [MacroStep] {
        var steps: [MacroStep] = []
        var previousStart: TimeInterval?
        var lastSample: SequenceSample?

        for sample in samples {
            if let last = lastSample, isContinuation(of: last, next: sample), var current = steps.last {
                current.clickCount += 1
                steps[steps.count - 1] = current
                lastSample = sample
                continue
            }

            let delay = previousStart.map { max(0, sample.elapsed - $0) } ?? 0
            steps.append(
                MacroStep(
                    delaySeconds: (delay * 1000).rounded() / 1000,
                    position: .inline(
                        relativeX: sample.relativePoint.x,
                        relativeY: sample.relativePoint.y,
                        referenceWidth: sample.referenceSize.width,
                        referenceHeight: sample.referenceSize.height
                    ),
                    clickCount: 1
                )
            )
            previousStart = sample.elapsed
            lastSample = sample
        }

        return steps
    }

    private static func isContinuation(of last: SequenceSample, next: SequenceSample) -> Bool {
        let dt = next.elapsed - last.elapsed
        guard dt >= 0, dt <= multiClickInterval else { return false }
        let dx = next.relativePoint.x - last.relativePoint.x
        let dy = next.relativePoint.y - last.relativePoint.y
        guard abs(dx) <= multiClickTolerance, abs(dy) <= multiClickTolerance else { return false }
        // clickState > 1 是系统自己的连击判定，优先采信；否则用「间隔短 + 位置近」兜底
        return next.clickState > 1 || dt <= multiClickInterval
    }

    // MARK: - Tap plumbing

    private func process(type: CGEventType, event: CGEvent?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        guard let event else { return nil }

        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == Self.escapeKeyCode else {
                return Unmanaged.passRetained(event)
            }
            let finish = onFinish
            stop()
            finish?()
            return nil  // 吞掉 Esc，不传给目标 app
        case .leftMouseDown:
            let click = RecordedClick(
                location: event.location,
                elapsed: Date.timeIntervalSinceReferenceDate - startedAt,
                clickState: Int(event.getIntegerValueField(.mouseEventClickState))
            )
            onClick?(click)
            return Unmanaged.passRetained(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let recorder = Unmanaged<MacroSequenceRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        return recorder.handleCallback(type: type, event: event)
    }

    private nonisolated func handleCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let optionalEvent: CGEvent? = (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput) ? nil : event
        let unsafeEvent = UnsafeOptionalEvent(value: optionalEvent)
        return assumingMainActor {
            process(type: type, event: unsafeEvent.value)
        }
    }
}

private struct UnsafeOptionalEvent: @unchecked Sendable {
    let value: CGEvent?
}
