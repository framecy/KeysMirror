import AppKit
import CoreGraphics

enum ModifierHelper {
    /// 提取标准修饰键，返回规范化的原始位值
    static func cleanModifiers(from rawValue: UInt64) -> UInt64 {
        let flags = CGEventFlags(rawValue: rawValue)
        var result: UInt64 = 0
        if flags.contains(.maskCommand) { result |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.maskControl) { result |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.maskAlternate) { result |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.maskShift) { result |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.maskSecondaryFn) { result |= CGEventFlags.maskSecondaryFn.rawValue }
        return result
    }
    
    /// 将 NSEvent 修饰键转换为规范化的 CG 原始位值
    static func cleanModifiers(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var result: UInt64 = 0
        if flags.contains(.command) { result |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.control) { result |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.option) { result |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.shift) { result |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.function) { result |= CGEventFlags.maskSecondaryFn.rawValue }
        return result
    }
    
    /// 将 CGEventFlags 转换为规范化的 CG 原始位值
    static func cleanModifiers(from flags: CGEventFlags) -> UInt64 {
        return cleanModifiers(from: flags.rawValue)
    }
}
