import SwiftUI
import CoreLocation
import UserNotifications

/// 零導覽新手引導：動態列表頂端的三張「情境卡」，取代舊的著陸頁與地圖強制帶領。
/// 它們是列表裡的普通列（不是 overlay、不擋畫面），可滑過、可關；沒有任何一張是進 App 的前置條件。
/// - 定位邀請卡：定位尚未決定時出現；拒絕後換成「新增守護地點／前往設定」的出路（拒絕定位也有路）。
/// - 通知：不再於動態頂端主動邀請——改在加入／建立家庭、新增守護地點、第一次按「我平安」時由 NotificationPrimer 說明後才問。
/// - 邀請碼列：還沒加入家庭圈的前 3 次啟動，給「家人傳了邀請碼給你」的人一個入口。
/// 一次只顯示一張引導卡；邀請碼列是一行小列，可與卡片並存。

/// 引導卡共用的旗標重置（設定「重新顯示引導卡」、DEBUG 的 --demo-firstrun、重跑新手流程共用）。
enum FeedOnboardingFlags {
    static func reset() {
        let defaults = UserDefaults.standard
        for key in [SettingsKeys.feedLocationCardDismissed, SettingsKeys.inviteRowDismissed,
                    SettingsKeys.feedLocationDeniedShown, SettingsKeys.hasOpenedEventDetail,
                    SettingsKeys.notificationPromptDeclined] {
            defaults.set(false, forKey: key)
        }
        defaults.removeObject(forKey: SettingsKeys.notificationCardEligibleAt)
    }
}

/// 動態頂端的情境卡區塊（放在 List 內，自己是一個 Section）。
struct FeedOnboardingCards: View {
    /// 是否已有任何守護範圍（跟隨圈或守護地點）；有了就不再需要定位邀請卡的拒絕態
    let hasCircle: Bool

    @Environment(TabRouter.self) private var router
    @AppStorage(SettingsKeys.feedLocationCardDismissed) private var locationDismissed = false
    @AppStorage(SettingsKeys.feedLocationDeniedShown) private var deniedShown = false
    @AppStorage(SettingsKeys.inviteRowDismissed) private var inviteDismissed = false
    @AppStorage(SettingsKeys.currentFamilyID) private var currentFamilyID = ""
    @AppStorage(SettingsKeys.launchCount) private var launchCount = 0

    /// 本次啟動中看到「被拒絕」才顯示拒絕態（避免之後每次啟動都提醒）
    @State private var deniedVisibleThisSession = false

    private var location: LocationService { LocationService.shared }

    private var authorizationDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }

    /// 定位邀請尚未處理：還沒做決定且沒按關閉。決定（允許／拒絕）或關閉後視為處理掉，才輪到通知卡
    private var locationPending: Bool {
        !locationDismissed && location.authorization == .notDetermined
    }

    /// 拒絕後的出路卡：只在沒有其他卡片佔位時才顯示，避免與通知卡疊在一起
    private var showLocationDenied: Bool {
        !locationDismissed && authorizationDenied && deniedVisibleThisSession && !hasCircle
    }

    private var showInvite: Bool {
        currentFamilyID.isEmpty && launchCount <= 3 && !inviteDismissed
    }

    /// 一次一張：定位邀請 > 定位拒絕出路；邀請碼列另外附在後面（一行小列）
    private var visibleKinds: [Kind] {
        var kinds: [Kind] = []
        if locationPending {
            kinds.append(.location)
        } else if showLocationDenied {
            kinds.append(.location)
        }
        if showInvite { kinds.append(.invite) }
        return kinds
    }

    private enum Kind: Hashable { case location, invite }

    var body: some View {
        Group {
            if !visibleKinds.isEmpty {
                Section {
                    ForEach(visibleKinds, id: \.self) { kind in
                        switch kind {
                        case .location: locationCard
                        case .invite: inviteRow
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visibleKinds)
        .onChange(of: location.authorization) { old, new in
            // 剛被拒絕：本次啟動內顯示一次拒絕態，並記下「顯示過」
            if old == .notDetermined, new == .denied || new == .restricted {
                deniedVisibleThisSession = true
                deniedShown = true
                Analytics.track("onboarding_location_denied")
            } else if new == .authorizedWhenInUse || new == .authorizedAlways {
                Analytics.track("onboarding_location_granted")
            }
        }
        .onAppear {
            // 先前已被拒絕、這是第一次看到拒絕態（例如舊用戶或升級後）：顯示一次
            if authorizationDenied, !deniedShown {
                deniedVisibleThisSession = true
                deniedShown = true
            }
        }
    }

    // MARK: - 定位邀請卡

    private var locationCard: some View {
        let denied = authorizationDenied
        return VStack(alignment: .leading, spacing: HCSpacing.x2) {
            HStack(alignment: .top) {
                Image(systemName: denied ? "location.slash.fill" : "location.fill")
                    .foregroundStyle(HCColor.brandText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text(denied ? "沒有定位也能用" : "想看你家附近的？")
                        .font(.headline)
                    Text(denied
                         ? "你可以新增一個守護地點，或之後到設定開啟定位。"
                         : "允許定位後，這裡只顯示你身邊 1 公里內的狀況。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    locationDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
            }
            HStack(spacing: HCSpacing.x2) {
                if denied {
                    Button("新增守護地點") { addPlace() }
                        .buttonStyle(.borderedProminent)
                        .tint(HCColor.brandFill)
                    Button("前往設定") { openSystemSettings() }
                        .buttonStyle(.bordered)
                } else {
                    Button("允許定位") {
                        Analytics.track("feed_location_card_tapped")
                        location.requestPermissionIfNeeded()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HCColor.brandFill)
                    Button("新增守護地點") { addPlace() }
                        .buttonStyle(.bordered)
                }
            }
            .tint(HCColor.brandText)
            .font(.subheadline.weight(.semibold))
        }
        .hcCard()
        .cardRow()
        .onAppear { Analytics.track("feed_location_card_shown") }
    }

    // MARK: - 邀請碼列

    private var inviteRow: some View {
        HStack(spacing: HCSpacing.x3) {
            Button {
                Analytics.track("invite_row_tapped")
                router.pendingJoinCode = "" // 空字串＝開加入流程但不預填
                router.selection = TabRouter.familyTab
            } label: {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "number.square.fill")
                        .foregroundStyle(HCColor.brandText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("家人傳了邀請碼給你？")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("輸入或掃碼加入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                inviteDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉邀請碼提示")
        }
        .hcCard()
        .cardRow()
        .swipeActions { Button("關閉") { inviteDismissed = true }.tint(.gray) }
    }

    // MARK: - 動作

    private func addPlace() {
        router.pendingAddPlace = true
        router.selection = TabRouter.familyTab
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// 「與我有關」在沒有任何守護範圍時的空狀態：說明原因並給兩條出路（和定位邀請卡同一組動作）。
struct NoCircleEmptyState: View {
    @Environment(TabRouter.self) private var router

    private func addPlace() {
        router.pendingAddPlace = true
        router.selection = TabRouter.familyTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            Text("還沒有你的守護範圍。允許定位，或新增一個守護地點，這裡就只顯示身邊的狀況。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: HCSpacing.x2) {
                if LocationService.shared.authorization == .notDetermined {
                    Button("允許定位") { LocationService.shared.requestPermissionIfNeeded() }
                        .buttonStyle(.borderedProminent)
                        .tint(HCColor.brandFill)
                    Button("新增守護地點") { addPlace() }
                        .buttonStyle(.bordered)
                } else {
                    Button("新增守護地點") { addPlace() }
                        .buttonStyle(.borderedProminent)
                        .tint(HCColor.brandFill)
                }
            }
            .tint(HCColor.brandText)
            .font(.subheadline.weight(.semibold))
        }
        .hcCard()
        .cardRow()
    }
}

extension View {
    /// 卡片列：透明列背景＋較小邊距，避免「卡中卡」的雙層框
    func cardRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: HCSpacing.x1, leading: HCSpacing.x4, bottom: HCSpacing.x1, trailing: HCSpacing.x4))
    }
}
