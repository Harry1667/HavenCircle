import SwiftUI

/// 通知權限的 App 內說明（見 NotificationPrimer）。先講「為什麼」，使用者按「開啟通知」才會跳系統詢問框。
struct NotificationPrimerSheet: View {
    let trigger: NotificationPrimer.Trigger
    var onAccept: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(spacing: HCSpacing.x4) {
            Spacer(minLength: 4)
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 44))
                .foregroundStyle(HCColor.brand)
                .accessibilityHidden(true)
            Text(trigger.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: HCSpacing.x3) {
                reasonRow("checkmark.shield.fill", "家人報平安", "家人回報平安或需要協助時，第一時間讓你知道。")
                reasonRow("exclamationmark.triangle.fill", "附近警報", "你和家人的守護範圍附近有狀況時提醒你。")
                reasonRow("house.fill", "家人到家", "家人抵達守護地點時通知你。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("安心圈不是緊急服務，遇到危險請直接撥 110／119。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAccept) {
                Text("開啟通知")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(HCColor.brand)
            Button("稍後", action: onLater)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .analyticsScreen("notification_primer")
    }

    private func reasonRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: HCSpacing.x3) {
            Image(systemName: icon)
                .foregroundStyle(HCColor.brand)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview {
    NotificationPrimerSheet(trigger: .family, onAccept: {}, onLater: {})
}
#endif
