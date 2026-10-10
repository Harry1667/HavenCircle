import SwiftUI
import UserNotifications

/// D4 重問通道：情境式權限卡（A4）被按過「先不用」之後，通知就永遠沒有回頭路——
/// 這裡是唯一的補救：事件串頂部再問一次。notDetermined 直接跳系統框；已被系統拒絕過
/// 就只能靠使用者自己去系統設定開，這裡負責把人帶過去。授權成功後這列自然消失。
struct NotificationReaskRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @AppStorage(SettingsKeys.notificationPromptDeclined) private var declined = false

    var body: some View {
        Group {
            if declined, status != .authorized {
                Button {
                    Task {
                        if status == .notDetermined {
                            _ = await NotificationScheduler.requestPermission()
                        } else if let url = URL(string: UIApplication.openSettingsURLString) {
                            await UIApplication.shared.open(url) // 已被系統拒絕過，只能引導到系統設定重新開啟
                        }
                        status = await NotificationScheduler.authorizationStatus()
                    }
                } label: {
                    HStack(spacing: HCSpacing.x3) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundStyle(HCColor.attention)
                            .accessibilityHidden(true)
                        Text("通知未開啟，圈內有狀況不會提醒你")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("開啟")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HCColor.brand)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            status = await NotificationScheduler.authorizationStatus()
        }
    }
}
