import AppKit
import CoreGraphics

enum CoordinateConverter {
    static func absolutePoint(relativeX: CGFloat, relativeY: CGFloat, in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + relativeX, y: windowFrame.minY + relativeY)
    }

    static func relativePoint(from absolutePoint: CGPoint, in windowFrame: CGRect) -> CGPoint? {
        let x = absolutePoint.x - windowFrame.minX
        let y = absolutePoint.y - windowFrame.minY

        guard x >= 0, y >= 0, x <= windowFrame.width, y <= windowFrame.height else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }

    static func appKitScreenPointToAX(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return point
        }

        return CGPoint(x: point.x, y: screen.frame.maxY - point.y)
    }

    static func axScreenPointToAppKit(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX
        }) else {
            return point
        }

        return CGPoint(x: point.x, y: screen.frame.maxY - point.y)
    }
}
