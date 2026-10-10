import SwiftUI
import UserNotifications

/// 通知被系統拒絕後的補救列：已在家庭圈（會收到家人報平安）卻拒絕了通知時，
/// 事件串頂部給一條「到設定開啟」的路。舊版情境卡被按過「先不用」（declined 旗標）者
/// 仍保留原本的重問行為。授權成功後這列自然消失。
/// 注意：這一列只是補救入口，不是首次詢問——首次詢問由 NotificationPrimer 在使用者
/// 加入家庭／新增守護地點／按「我平安」時先說明再問。
struct NotificationReaskRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @AppStorage(SettingsKeys.notificationPromptDeclined) private var declined = false
    @AppStorage(SettingsKeys.currentFamilyID) private var currentFamilyID = ""

    /// 顯示條件：舊版「先不用」過且尚未授權；或已在家庭圈卻被系統拒絕（會漏接家人回報）
    private var shouldShow: Bool {
        if status == .authorized || status == .provisional || status == .ephemeral { return false }
        if status == .denied { return !currentFamilyID.isEmpty }
        return declined
    }

    var body: some View {
        Group {
            if shouldShow {
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
                        Text(status == .notDetermined ? "開啟" : "到設定開啟")
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
