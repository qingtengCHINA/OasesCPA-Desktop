import SwiftUI

struct SparklineView: View {
    let values: [CGFloat]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let maxValue = values.max() ?? 1
            let minValue = values.min() ?? 0
            let range = max(maxValue - minValue, 1)

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = proxy.size.height * (1 - (value - minValue) / range)
                    let point = CGPoint(x: x, y: y)

                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 34)
    }
}
