import SwiftUI

/// 窗口比例画布：按目标窗口宽高比画线框，录制点以可拖动的红点呈现，
/// 同 profile 的其他点以灰点作参照，避免两个映射点重叠。
/// 拖动即微调坐标，不必再跑一趟目标 app 重录。
struct PositionCanvas: View {
    /// 当前点（窗口内坐标，单位与 referenceSize 一致）
    @Binding var point: CGPoint?
    /// 录制时的窗口尺寸；为空时按 16:9 兜底并禁用拖动
    let referenceSize: CGSize?
    /// 其他参照点（窗口内坐标 + 标签）
    var otherPoints: [(point: CGPoint, label: String)] = []
    var isRecording: Bool = false

    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var aspect: CGFloat {
        guard let referenceSize, referenceSize.height > 0 else { return 16.0 / 9.0 }
        return referenceSize.width / referenceSize.height
    }

    var body: some View {
        GeometryReader { geo in
            let canvas = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Palette.tint(.gray))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(isRecording ? Theme.Palette.danger : Theme.Palette.separator, lineWidth: isRecording ? 2 : 1)
                    )
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)

                ForEach(Array(otherPoints.enumerated()), id: \.offset) { _, other in
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .position(canvasPosition(for: other.point, in: canvas))
                        .help(other.label)
                }

                if let point {
                    ZStack {
                        Circle()
                            .strokeBorder(Theme.Palette.danger, lineWidth: 2)
                            .background(Circle().fill(Theme.Palette.danger.opacity(0.28)))
                            .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                    }
                    .position(canvasPosition(for: point, in: canvas))
                    .animation(Theme.Motion.quick(reduceMotion), value: isDragging)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard referenceSize != nil else { return }
                                isDragging = true
                                self.point = windowPoint(fromCanvas: value.location, canvas: canvas)
                            }
                            .onEnded { _ in isDragging = false }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 150)
        .accessibilityLabel("点击位置画布")
        .accessibilityValue(point.map { "x \(Int($0.x))，y \(Int($0.y))" } ?? "未录制")
    }

    /// 在可用区域内按窗口比例居中放置画布
    private func fittedRect(in size: CGSize) -> CGRect {
        let availableAspect = size.width / max(size.height, 1)
        var w = size.width
        var h = size.height
        if availableAspect > aspect {
            w = size.height * aspect
        } else {
            h = size.width / aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func canvasPosition(for windowPoint: CGPoint, in canvas: CGRect) -> CGPoint {
        let ref = referenceSize ?? CGSize(width: 1600, height: 900)
        let fx = ref.width > 0 ? windowPoint.x / ref.width : 0
        let fy = ref.height > 0 ? windowPoint.y / ref.height : 0
        return CGPoint(x: canvas.minX + fx * canvas.width, y: canvas.minY + fy * canvas.height)
    }

    private func windowPoint(fromCanvas location: CGPoint, canvas: CGRect) -> CGPoint {
        let ref = referenceSize ?? CGSize(width: 1600, height: 900)
        let fx = min(max((location.x - canvas.minX) / max(canvas.width, 1), 0), 1)
        let fy = min(max((location.y - canvas.minY) / max(canvas.height, 1), 0), 1)
        return CGPoint(x: (fx * ref.width).rounded(), y: (fy * ref.height).rounded())
    }
}
