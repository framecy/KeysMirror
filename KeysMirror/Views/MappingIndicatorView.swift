import SwiftUI

struct MappingIndicatorView: View {
    let mapping: KeyMapping
    let opacity: Double

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .stroke(Color.red, lineWidth: 2)
                .background(Circle().fill(Color.red.opacity(0.3)))
                .frame(width: 12, height: 12)
            
            Text(mapping.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4)
        }
        .opacity(opacity)
    }
}
