import SwiftUI

/// 提醒暫停中的常駐提示（家人首頁頂部）：地圖不再放全域靜音鈴鐺後，
/// 「現在被靜音」這件事改在第一個畫面講清楚，並可一鍵恢復。
/// 沒暫停時整段不顯示（回傳空 Section）。
struct MutedAlertsBanner: View {
    @AppStorage(SettingsKeys.alertsPaused) private var isPaused = false

    var body: some View {
        if isPaused {
            Section {
                Button {
                    withAnimation { isPaused = false }
                    Analytics.track("home_alerts_resumed") // 漏斗：從首頁提示恢復提醒
                } label: {
                    HStack(spacing: HCSpacing.x3) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundStyle(HCColor.attention)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HCSpacing.x1) {
                            Text("提醒已暫停・點擊恢復")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("暫停期間手機不會跳出任何警報通知；事件仍會顯示在動態與地圖。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("恢復")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HCColor.brand)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.mutedBanner")
            }
        }
    }
}
