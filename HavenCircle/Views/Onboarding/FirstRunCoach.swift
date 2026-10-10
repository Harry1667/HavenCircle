import SwiftUI

/// 聲納式脈動圈：兩圈錯開、由小放大同時淡出、反覆播放，用來把目光吸到某個目標上（幾乎不用文字）。
struct PulseRing: View {
    var color: Color
    /// 脈動放到最大時的直徑（點）
    var maxDiameter: CGFloat
    var lineWidth: CGFloat = 3
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: maxDiameter, height: maxDiameter)
                    .scaleEffect(animate ? 1.0 : 0.2)
                    .opacity(animate ? 0.0 : 0.85)
                    .animation(
                        .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.9),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

/// App 內模擬的 iOS 通知橫幅樣式：純視覺示範「通知長怎樣」，明確標示「此為示範」，
/// 不會被誤認為真通知。
struct DemoNotificationBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(HCColor.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("安心圈")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("此為示範")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("🔴【示範】火災：距你的警戒圈 800 公尺")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 12)
    }
}
