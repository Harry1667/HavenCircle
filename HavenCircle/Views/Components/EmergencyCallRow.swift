import SwiftUI
import UIKit

/// 110 / 119 緊急撥號列：安心圈不是緊急服務，有立即危險時要讓人第一眼就能撥出去。
/// 事件詳情與區域警報詳情共用，放在「建議行動」之後的第一屏內。
struct EmergencyCallRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x2) {
            HStack(spacing: HCSpacing.x3) {
                callButton(number: "110", title: "撥 110", subtitle: "人身安全、犯罪", icon: "phone.fill")
                callButton(number: "119", title: "撥 119", subtitle: "火災、緊急救護", icon: "cross.case.fill")
            }
            Text("安心圈不是緊急服務；有立即危險請直接撥打，不要等待 App 通知。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func callButton(number: String, title: String, subtitle: String, icon: String) -> some View {
        Button {
            guard let tel = URL(string: "tel://\(number)") else { return }
            UIApplication.shared.open(tel)
        } label: {
            VStack(spacing: 2) {
                Label(title, systemImage: icon)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(HCColor.danger)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}
