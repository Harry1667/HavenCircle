import SwiftUI
import SwiftData

/// B3-2：入圈後兩題激活。受邀者選完（或略過）身分之後、真正落回家人頁之前插入這一頁，
/// 直球問完「位置分享」與「通知」這兩個模擬死點 5 的關鍵開關——不然這兩個開關永遠要
/// 靠受邀者自己去家人頁 / 系統設定裡找，邀請者只能被迫遠端客服教人開權限。
///
/// 兩步都可跳過、都已設定過的自動略過整步，兩步都不適用時整個畫面直接收掉——
/// 不製造「兩題都跳過還要多按一次」的多餘摩擦。
struct PostJoinActivationView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.liveLocationSharingEnabled) private var isLocationSharingEnabled = false
    @AppStorage(SettingsKeys.liveCircleRadiusMeters) private var radiusMeters = 1_000

    /// 兩步都跳過或都完成後呼叫，交由呼叫端 dismiss 整個加入流程（維持現行落回家人頁）
    var onFinished: () -> Void

    private enum Step {
        case checking   // 尚未決定要不要顯示任何一步（避免顯示空白瞬間的過渡態）
        case location
        case notifications
    }

    @State private var step: Step = .checking
    @State private var isWorking = false

    var body: some View {
        ZStack {
            // fullScreenCover 呈現、根層只有 VStack，沒有 List/Form/NavigationStack 自帶不透明底，
            // 同 RoleSelectView／JoinWelcomeView 的坑，鋪系統底色避免深色模式整層透明。
            Color(.systemBackground).ignoresSafeArea()

            switch step {
            case .checking:
                EmptyView()
            case .location:
                questionCard(
                    icon: "location.fill",
                    title: "要讓家人看得到你的位置嗎？",
                    subtitle: "開啟後位置只分享給家庭圈成員，可隨時暫停；軌跡只保留 24 小時。",
                    primaryLabel: "開啟位置分享",
                    primaryAction: { Task { await enableLocation() } },
                    secondaryAction: { Task { await checkNotificationsStep() } }
                )
            case .notifications:
                questionCard(
                    icon: "bell.badge.fill",
                    title: "圈內有狀況時通知你？",
                    subtitle: "家人回報平安、附近有警報、家人到家時提醒你。安心圈不是緊急服務，危急請撥 110／119。",
                    primaryLabel: "開啟通知",
                    primaryAction: { Task { await enableNotifications() } },
                    secondaryAction: { onFinished() } // 「稍後」：不問系統，次數在顯示時已記下
                )
            }
        }
        // iPad：內容欄自己限寬置中，避免整頁在 13 吋螢幕上被拉伸得又空又怪
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
        .analyticsScreen("post_join_activation")
        .task {
            await checkLocationStep()
        }
    }

    @ViewBuilder
    private func questionCard(
        icon: String,
        title: String,
        subtitle: String,
        primaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: HCSpacing.x6) {
            Spacer()
            ZStack {
                Circle()
                    .fill(HCColor.brand.opacity(0.10))
                    .frame(width: 104, height: 104)
                Circle()
                    .stroke(HCColor.brand.opacity(0.14), lineWidth: 1)
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(HCColor.brand)
            }
            VStack(spacing: HCSpacing.x2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, HCSpacing.x6)
            } else {
                VStack(spacing: HCSpacing.x3) {
                    Button(action: primaryAction) {
                        Text(primaryLabel)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(HCColor.brand)

                    Button(action: secondaryAction) {
                        Text("先不用")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color.secondary)
                }
                .padding(.bottom, HCSpacing.x6)
            }
        }
        .padding(.horizontal, HCSpacing.x6)
        .transition(.opacity)
    }

    // MARK: - 步驟判斷（已設定過的自動跳過；兩步都不適用直接結束）

    private func checkLocationStep() async {
        guard !isLocationSharingEnabled else {
            await checkNotificationsStep()
            return
        }
        step = .location
    }

    private func checkNotificationsStep() async {
        // 已授權／已拒絕／已提示滿次數／自動化跳過時，整步略過
        guard await NotificationPrimer.shouldAsk(.family) else {
            onFinished()
            return
        }
        NotificationPrimer.recordShown(.family)
        step = .notifications
    }

    private func enableLocation() async {
        isWorking = true
        defer { isWorking = false }
        await sync.enableLiveLocationSharing(radiusMeters: radiusMeters, context: context)
        Analytics.track("post_join_location_enabled")
        await checkNotificationsStep()
    }

    private func enableNotifications() async {
        isWorking = true
        defer { isWorking = false }
        _ = await NotificationScheduler.requestPermission()
        Analytics.track("post_join_notifications_enabled")
        onFinished()
    }
}

#if DEBUG
#Preview {
    PostJoinActivationView(onFinished: {})
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
}
#endif
