import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import AuthenticationServices
import UserNotifications

/// 設定頁：沿用 Apple 系統設定的結構，並以低彩度語意圖示維持可掃讀性。
struct SettingsView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss // 設定現在是 sheet：重看導覽等動作要先把自己收起來
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.appleAccountEmail) private var appleEmail = ""
    @AppStorage(SettingsKeys.apnsDeviceToken) private var apnsToken = ""
    @AppStorage(SettingsKeys.analyticsEnabled) private var analyticsEnabled = true
    @AppStorage(SettingsKeys.devToolsUnlocked) private var devToolsUnlocked = false
    @State private var showPaywall = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteReauth = false
    @State private var isDeleting = false
    @State private var demoNoticeScheduled = false
    @State private var tokenCopied = false
    @State private var demoSeedFeedback: String?

    var body: some View {
        NavigationStack {
            List {
                // 頂端帳號列：仿系統設定的 Apple 帳號列（頭像＋名字＋說明＋chevron），不再包成卡片
                Section {
                    NavigationLink {
                        AppleAccountView()
                    } label: {
                        HStack(spacing: HCSpacing.x3) {
                            ProfileAvatar(name: accountName, size: 60)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accountTitle)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(accountSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("settings.accountRow")
                }

                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack(spacing: HCSpacing.x3) {
                            settingsIcon("crown.fill", color: HCColor.brand)
                            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                                Text("升級 Guardian+")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("多據點、完整歷史與更多；核心警報永遠免費")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    // 標題從「個人資訊」改為白話版，讓使用者一眼知道改名／改身分在這裡
                    settingsRow("你的名字與家庭身分", subtitle: "本名、家人怎麼叫你，與緊急聯絡備註",
                                icon: "person.text.rectangle.fill", color: HCColor.brand) {
                        PersonalProfileView()
                    }
                    settingsRow("提醒設定", subtitle: "本機提醒、可信度與每日摘要",
                                icon: "bell.badge.fill", color: HCColor.brand) {
                        AlertSettingsView()
                    }
                    settingsRow("顯示與文字", subtitle: "深淺外觀、字體大小與即時預覽",
                                icon: "textformat.size", color: HCColor.brand) {
                        DisplaySettingsView()
                    }
                }

                Section {
                    settingsRow("法律與隱私", subtitle: "隱私權政策、用戶協議與使用條款",
                                icon: "hand.raised.square.fill", color: HCColor.brand) {
                        LegalCenterView()
                    }
                    settingsRow("資料來源", subtitle: "政府示警來源與資料新鮮度",
                                icon: "antenna.radiowaves.left.and.right", color: HCColor.brand) {
                        DataSourceView()
                    }
                    // 匿名統計可整個關掉：隱私承諾不是只寫在政策裡，要給使用者實際的關閉權
                    Toggle(isOn: $analyticsEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("匿名使用統計")
                                    .foregroundStyle(.primary)
                                Text("僅事件次數、頁面瀏覽與停留時長，不含識別碼與位置")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            settingsIcon("chart.bar.fill", color: HCColor.brand)
                        }
                    }
                    .onChange(of: analyticsEnabled) { _, enabled in
                        if !enabled { Analytics.clearQueue() } // 關閉即清空未送出的佇列
                        Analytics.applyFirebaseCollectionSetting() // 同步 Firebase 收集開關
                    }
                    settingsRow("關於安心圈", subtitle: "版本、官網與隱私原則",
                                icon: "info.circle.fill", color: HCColor.brand) {
                        AboutView()
                    }
                    Button {
                        // 清掉引導卡旗標＋關掉設定 sheet＋回到動態：三張情境卡下次進動態會重新出現
                        FeedOnboardingFlags.reset()
                        router.selection = TabRouter.eventsTab
                        dismiss()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("重新顯示引導卡")
                                    .foregroundStyle(.primary)
                                Text("回到動態後會重新顯示定位、通知與邀請碼引導卡")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            settingsIcon("rectangle.stack.badge.plus", color: HCColor.brand)
                        }
                    }
                }

                // App Store 審查指南 5.1.1(v)：提供帳號/資料刪除
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label {
                            Text("刪除帳號與所有資料")
                        } icon: {
                            settingsIcon("trash.fill", color: HCColor.danger)
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("清除這支手機上的所有家人、警戒圈與事件資料，停止即時位置分享，並撤銷 Apple 登入授權、退出（擁有者則解散）家庭圈。此動作無法復原。")
                }

                #if DEBUG
                // 隱藏區：在「關於安心圈」連點版本號 7 下才出現（展示時不會被誤點）
                if devToolsUnlocked { demoSection }
                #endif

                Section {
                    Label("安心圈不是緊急服務。遇立即危險請直接撥打 110 或 119。", systemImage: "phone.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listSectionSpacing(HCSpacing.x6)
            .navigationTitle("設定")
            // iPad 的 sheet 預設大標題會佔掉一大塊，統一 inline；右上「完成」與其他 sheet 一致
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .analyticsScreen("settings")
            .task { await sync.refreshAccountStatus() }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView()
            }
            .confirmationDialog("確定要刪除帳號與所有資料嗎？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("刪除所有資料", role: .destructive) {
                    // 未登入（沒有 Firebase 帳號可刪）：跳過重新驗證，直接跑本機清除；
                    // 已登入：帳號本體是真的要刪掉的東西，必須先讓使用者重新驗證一次
                    // （見 DeleteAccountReauthSheet 與 AuthService.deleteAccount 的設計說明）。
                    if sync.state == .noAccount {
                        Task { await deleteEverything() }
                    } else {
                        showDeleteReauth = true
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("你的 Apple 登入授權、家庭圈成員資格，與這台裝置上的所有資料都會被刪除，無法復原。")
            }
            .sheet(isPresented: $showDeleteReauth) {
                DeleteAccountReauthSheet(
                    onCleanupBeforeDelete: { await cleanupCloudDependenciesBeforeDelete() },
                    onLocalWipe: { await wipeLocalData() },
                    onFinished: {
                        showDeleteReauth = false
                        dismiss() // 退回主畫面：本機資料已清空，回到零導覽的動態首頁
                    }
                )
                // iPad 會忽略隱含尺寸而放大成整頁 sheet，這裡收斂成 form 尺寸
                .formPresentationSizing()
            }
        }
    }

    // MARK: - 示範與開發

    /// 模擬警報通知與 APNs 權杖。誠實原則：模擬通知標題一律帶【示範】字樣，
    /// 不冒充真實災害警報；權杖只在本機顯示，供 Apple Push Console 推播測試。
    /// 整段只在 DEBUG 編譯：引用了 DEBUG-only 的 SixDisasterScenario
    #if DEBUG
    @ViewBuilder
    private var demoSection: some View {
        Section {
            Button {
                Task { await scheduleDemoNotification() }
            } label: {
                Label {
                    Text("模擬警報通知（示範用）")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(HCColor.attention.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            if demoNoticeScheduled {
                Label("已排程，5 秒後送達——現在鎖定螢幕可看到鎖屏通知。", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(HCColor.safe)
            }
            Button {
                DemoSeed.loadHistoricalEvents(context: context)
                demoSeedFeedback = "已載入 2 筆歷史官方事件（標題含【歷史示範】）"
            } label: {
                Label {
                    Text("載入歷史官方事件示範")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(HCColor.brand.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            Button {
                Task {
                    await SixDisasterScenario.seed(context: context)
                    demoSeedFeedback = "已載入六災難測試場景（4 點狀＋2 區域，含測試家人與倉庫）"
                }
            } label: {
                Label {
                    Text("載入六災難測試場景")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "tornado")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            Button {
                SixDisasterScenario.clear(context: context)
                demoSeedFeedback = "已清除六災難測試場景"
            } label: {
                Label {
                    Text("清除六災難場景")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            Button {
                DemoSeed.removeAll(context: context)
                demoSeedFeedback = "已移除所有歷史示範與演練事件"
            } label: {
                Label {
                    Text("重設 Demo 資料")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            // 重跑新手流程：清空本機家庭資料＋重置旗標，讓完整新手流程（地圖著陸→帶領→第二次選身分）當場重來
            Button {
                resetOnboarding()
            } label: {
                Label {
                    Text("重跑新手流程（清空本機家庭資料）")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "figure.walk.arrival")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(HCColor.brand.gradient, in: RoundedRectangle(cornerRadius: HCRadius.badge))
                }
            }
            if let demoSeedFeedback {
                Label(demoSeedFeedback, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(HCColor.safe)
            }
            // APNs 權杖只在 Debug build 顯示：權杖本身不足以發送推播（還需開發者私鑰），
            // 但它能識別裝置，且對一般使用者只是一串困惑的亂碼——正式版不編譯這段
            #if DEBUG
            if !apnsToken.isEmpty {
                Button {
                    UIPasteboard.general.string = apnsToken
                    tokenCopied = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tokenCopied ? "APNs 裝置權杖（已複製）" : "APNs 裝置權杖（點一下複製）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(apnsToken)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                }
            }
            #endif
            Button("收起示範與開發") { devToolsUnlocked = false }
        } header: {
            Text("示範與開發")
        } footer: {
            #if DEBUG
            Text("模擬通知為本機發送的示範內容（標題含【示範】字樣），非真實災害警報。歷史事件示範重播的是 NCDR 實際發布過的官方示警原文（標題含【歷史示範】，僅顯示效期經過調整）。權杖供 APNs 推播測試，操作步驟見專案 APNS_PUSH_TEST.md。")
            #else
            Text("模擬通知為本機發送的示範內容（標題含【示範】字樣），非真實災害警報。歷史事件示範重播的是 NCDR 實際發布過的官方示警原文（標題含【歷史示範】，僅顯示效期經過調整）。")
            #endif
        }
    }

    /// 開發用：清空本機家庭資料＋重置所有新手旗標，讓零導覽首次體驗（動態情境卡）當場重來。
    /// launchCount 設回 1，模擬「這是第一次開 App」。
    private func resetOnboarding() {
        for member in (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? [] {
            context.delete(member)
        }
        for circle in (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? [] {
            context.delete(circle)
        }
        context.saveReporting()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: SettingsKeys.seenCircleAdjustHint)
        FeedOnboardingFlags.reset()
        defaults.set(1, forKey: SettingsKeys.launchCount)
        defaults.set("", forKey: SettingsKeys.profileDisplayName)
        dismiss() // 收起設定；ContentView 會重建「我」，動態頂端引導卡重新出現
    }
    #endif

    /// 延遲 5 秒發送：留時間鎖定螢幕，展示通知在鎖屏上的真實樣貌
    private func scheduleDemoNotification() async {
        guard await NotificationScheduler.requestPermission() else { return }
        let content = UNMutableNotificationContent()
        content.title = "【示範】地震速報：臺北市南港區"
        content.body = "官方確認事件落在「住家」提醒範圍內。此為示範內容，非真實警報。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "demo-alert", content: content, trigger: trigger)
            )
            demoNoticeScheduled = true
            try? await Task.sleep(for: .seconds(6))
            demoNoticeScheduled = false
        } catch {
            AppLog.notificationsError("示範通知排程失敗：\(error.localizedDescription)")
        }
    }

    /// 雲端／裝置外部依賴的清理：撤銷推播權杖 → 停止即時位置分享 → 退出或解散雲端家庭圈。
    ///
    /// ⚠️ 順序很重要：這一段全部要在 Firebase 帳號「還存在」時做完。已登入的刪除路徑
    /// （DeleteAccountReauthSheet）會先呼叫這裡，才呼叫 AuthService.deleteAccount 真正刪除
    /// Firebase 帳號——一旦帳號被刪除，Firestore 規則的 request.auth 立即變成 null，
    /// 屆時這裡所有的 Firestore 呼叫都會被拒絕，且再也無法自己清理。
    /// leaveFamily 用 `try?` 吞掉錯誤：即使離線失敗，本機清除仍要能完成，不該被雲端呼叫卡住。
    private func cleanupCloudDependenciesBeforeDelete() async {
        UserDefaults.standard.set(false, forKey: SettingsKeys.liveLocationSharingEnabled)
        LocationService.shared.syncLiveLocationSharing(isEnabled: false)
        // 先使用仍保留的權杖要求中繼站刪除，再清掉本機副本；即使離線失敗，
        // Apple 之後也會讓失效權杖被 APNs 回收，且刪除流程不應因此卡住。
        if !apnsToken.isEmpty {
            await APNsRegistrar.unregister(token: apnsToken)
        }
        if UserDefaults.standard.string(forKey: SettingsKeys.liveLocationDeviceID) != nil {
            await sync.stopLiveLocationSharing(context: context)
        }
        // 圈主且只剩自己 → 內部自動改走解散家庭圈；其餘情況照舊退出（見 FamilySyncService.leaveFamily）
        try? await sync.leaveFamily()
    }

    /// 本機資料庫 → 偏好設定 → 通知：純本機清除，不依賴登入狀態或網路。
    /// 完成後 ContentView 會因旗標與資料清空自動回到新手設定。
    private func wipeLocalData() async {
        // 逐筆刪除，不用 delete(model:)：批次刪除走 CoreData batch delete，
        // 會撞上 LocalLifeCircle.member 強制反向關聯的約束（實機已踩到）；
        // 逐筆刪除才會執行 cascade 與反向關聯清理。資料量小，效能無虞。
        do {
            for member in try context.fetch(FetchDescriptor<LocalFamilyMember>()) {
                context.delete(member) // cascade 會一併刪除生活圈
            }
            for circle in try context.fetch(FetchDescriptor<LocalLifeCircle>()) {
                context.delete(circle) // 保險：清掉沒掛在成員下的孤兒生活圈
            }
            for event in try context.fetch(FetchDescriptor<LocalSafetyEvent>()) {
                context.delete(event)
            }
            for alert in try context.fetch(FetchDescriptor<RegionAlert>()) {
                context.delete(alert)
            }
        } catch {
            AppLog.dataError("刪除本機資料失敗：\(error.localizedDescription)")
        }
        context.saveReporting()
        for key in [SettingsKeys.profileDisplayName, SettingsKeys.profileContactNote,
                    SettingsKeys.appleAccountEmail, SettingsKeys.onboardingCompleted,
                    SettingsKeys.lastDataRefresh, SettingsKeys.alertsEnabled,
                    SettingsKeys.alertsPaused, SettingsKeys.highConfidenceOnly,
                    SettingsKeys.digestEnabled, SettingsKeys.digestHour,
                    SettingsKeys.liveLocationSharingEnabled, SettingsKeys.liveCircleRadiusMeters,
                    SettingsKeys.liveLocationDeviceID, SettingsKeys.apnsDeviceToken,
                    SettingsKeys.legalAcceptanceVersion, SettingsKeys.knownFamilyMemberUids,
                    SettingsKeys.notificationPromptDeclined, SettingsKeys.seenCircleAdjustHint,
                    SettingsKeys.feedLocationCardDismissed, SettingsKeys.notificationCardEligibleAt,
                    SettingsKeys.inviteRowDismissed, SettingsKeys.mapRangePillShown,
                    SettingsKeys.feedLocationDeniedShown, SettingsKeys.hasOpenedEventDetail] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        ProfilePhotoStore.shared.remove()
        EventVisibility.reset()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// 未登入狀態按刪除鈕的路徑：沒有 Firebase 帳號可刪，跳過重新驗證，直接做完整本機清除。
    /// （[cleanupCloudDependenciesBeforeDelete] 內部呼叫的 sync.leaveFamily 在 uid 為 nil 時
    /// 會自行跳過所有 Firestore 呼叫，這裡不需要另外分支。）
    private func deleteEverything() async {
        isDeleting = true
        defer { isDeleting = false }
        await cleanupCloudDependenciesBeforeDelete()
        await wipeLocalData()
        dismiss()
    }

    /// 頭像用的真名（沒有任何來源時為 nil，頭像改顯示 person.fill）
    private var accountName: String? {
        ProfileIdentity.resolvedName(local: displayName, email: appleEmail)
    }

    // 2026-10-11 實機：Apple 只在首次授權給姓名，使用者若當時隱藏姓名或已授權過就永遠拿不到，
    // email 也是隱藏信箱——此時不要停在「Apple 帳號」，直接引導去設定名字
    private var accountTitle: String {
        if sync.state == .noAccount { return "登入" }
        return accountName ?? "設定你的名字"
    }

    private var accountSubtitle: String {
        if sync.state == .noAccount { return "用 Apple 帳號登入，與家人互報平安" }
        if accountName == nil { return "家人目前看到的是「家人」，點一下設定名字與照片" }
        return "Apple 帳號、家庭圈與個人資料"
    }

    /// 仿系統設定的列：低彩度語意圖示＋標題＋副標。
    private func settingsRow(
        _ title: String,
        subtitle: String,
        icon: String,
        color: Color,
        @ViewBuilder destination: () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                settingsIcon(icon, color: color)
            }
        }
    }

    private func settingsIcon(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: HCRadius.badge))
    }
}

/// 將外觀與字級移出一列四段的 segmented control：當使用者選「最大」時，
/// 控制項本身也會放大；每個選項改為完整列，確保不截字、不重疊且有 44pt 以上點按範圍。
private struct DisplaySettingsView: View {
    @AppStorage(SettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage(SettingsKeys.appTextSize) private var appTextSize = AppTextSize.system.rawValue
    @AppStorage(SettingsKeys.appAppearance) private var appAppearance = AppAppearance.default.rawValue

    private var selectedAppearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceMode) ?? .system
    }

    private var selectedTextSize: AppTextSize {
        AppTextSize(rawValue: appTextSize) ?? .system
    }

    var body: some View {
        List {
            // 外觀風格：換配色與動態頁頁首；與下方「深淺」是兩件事，切換後立即生效
            Section {
                Picker("外觀", selection: $appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearancePicker")
            } header: {
                Text("外觀風格")
            } footer: {
                Text("兩種外觀功能相同，只有配色與頁首不同。")
            }

            Section {
                ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                    Button {
                        appearanceMode = mode.rawValue
                    } label: {
                        optionRow(
                            title: mode.label,
                            detail: appearanceDetail(for: mode),
                            isSelected: selectedAppearance == mode
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("外觀：\(mode.label)")
                    .accessibilityValue(selectedAppearance == mode ? "已選取" : "未選取")
                }
            } header: {
                Text("深淺")
            } footer: {
                Text("切換後立即套用；選「跟隨系統」會使用 iPhone 目前的深淺外觀。")
            }

            Section {
                ForEach(AppTextSize.allCases) { size in
                    Button {
                        appTextSize = size.rawValue
                    } label: {
                        optionRow(
                            title: size.label,
                            detail: size.detail,
                            isSelected: selectedTextSize == size
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("字體大小：\(size.label)")
                    .accessibilityValue(selectedTextSize == size ? "已選取" : "未選取")
                }
            } header: {
                Text("字體大小")
            } footer: {
                Text("跟隨系統會使用 iOS「設定 > 螢幕顯示與亮度 > 文字大小」。")
            }

            Section("即時預覽") {
                Text("警報來時，這行字就是目前設定的大小。")
                    .font(.body)
                Text("選最大時，清單可捲動但不會縮字或截斷選項。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("顯示與文字")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("display_settings")
    }

    private func optionRow(title: String, detail: String, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HCSpacing.x3) {
            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: HCSpacing.x2)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(HCColor.brand)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private func appearanceDetail(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "依照 iPhone 目前的外觀設定"
        case .light: return "固定使用淺色背景與深色文字"
        case .dark: return "固定使用深色背景與淺色文字"
        }
    }
}

private struct AppleAccountView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.appleAccountEmail) private var appleEmail = ""
    @State private var signInError: String?
    @State private var showLogoutConfirm = false
    @State private var showSignIn = false
    @State private var showEditDialog = false
    @State private var showPhotoPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var photoError: String?
    @State private var showNameEditor = false

    private var accountName: String? {
        ProfileIdentity.resolvedName(local: displayName, email: appleEmail)
    }

    var body: some View {
        List {
            // 仿系統「Apple 帳號」頁：置中大頭像、編輯、名字、email
            Section {
                VStack(spacing: HCSpacing.x2) {
                    ProfileAvatar(name: accountName, size: 90)
                    Button("編輯") { showEditDialog = true }
                        .font(.subheadline)
                        .accessibilityIdentifier("account.editPhoto")
                    if let accountName {
                        Text(accountName)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                    } else {
                        // 沒有任何名字來源（Apple 沒給、隱藏信箱）：名字位置直接是設定入口
                        // 用 Button＋navigationDestination 而非 NavigationLink：List 列內的 NavigationLink
                        // 會自帶靠右箭頭並靠左排，破壞置中版面
                        Button {
                            showNameEditor = true
                        } label: {
                            Text("設定你的名字")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(HCColor.brand)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("家人收到你的平安通知時會看到這個名字")
                    }
                    if !appleEmail.isEmpty {
                        Text(appleEmail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("照片只存在這支手機，不會上傳給家人或伺服器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, HCSpacing.x1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HCSpacing.x2)
                .listRowBackground(Color.clear)
            }

            if sync.state == .noAccount {
                // 未登入：維持原本的登入按鈕與說明
                // 真登入：nonce/scopes 由 AuthService 統一設定，換到 Firebase uid 才是家庭圈能用的身份
                // （原本這顆按鈕只寫本機 @AppStorage，從不呼叫 AuthService，是一顆假登入按鈕）
                Section {
                    SignInWithAppleButton(.continue) { request in
                        AuthService.shared.prepareAppleRequest(request)
                    } onCompletion: { result in
                        handleSignIn(result)
                    }
                    .frame(height: 44)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    if let signInError {
                        Text(signInError)
                            .font(.caption)
                            .foregroundStyle(HCColor.danger)
                    }
                } footer: {
                    Text("用 Apple 帳號登入安心圈：免費，只用來讓家人找到彼此、同步安否回報與即時位置。")
                }
            }

            Section("個人資料") {
                NavigationLink {
                    PersonalProfileView()
                } label: {
                    LabeledContent("名字與家庭身分", value: displayName.isEmpty ? "未設定" : displayName)
                }
            }

            Section {
                LabeledContent("目前狀態", value: statusTitle)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("家庭圈")
            } footer: {
                Text("Apple 帳號登入用於同步家人安否回報與即時位置給家庭圈。警戒圈與事件資料仍保存在此裝置。")
            }

            Section("登入與安全") {
                if sync.state != .noAccount {
                    // 已登入：顯示現況，不能同時又冒出一顆登入按鈕（真機回報過這個自相矛盾）
                    if !appleEmail.isEmpty {
                        LabeledContent("Email", value: appleEmail)
                    }
                    Text("已用 Apple 帳號登入安心圈，家人回報平安與即時位置會同步給家庭圈。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Apple 登入", value: sync.state == .noAccount ? "尚未登入" : "已登入")
                Button("重新檢查帳號狀態", systemImage: "arrow.clockwise") {
                    Task { await sync.refreshAccountStatus() }
                }
            }

            if sync.state != .noAccount {
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("登出").frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("登出會登出 Apple 帳號並清除此裝置顯示的名稱與 email；警戒圈與事件資料不受影響。請先在家人頁停止即時位置分享。")
                }
            }
        }
        .navigationDestination(isPresented: $showNameEditor) { PersonalProfileView() }
        .navigationTitle("Apple 帳號")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sync.refreshAccountStatus() }
        .confirmationDialog("大頭照", isPresented: $showEditDialog, titleVisibility: .visible) {
            Button("選擇照片") { showPhotoPicker = true }
            if ProfilePhotoStore.shared.image != nil {
                Button("移除照片", role: .destructive) { ProfilePhotoStore.shared.remove() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片只存在這支手機，不會上傳給家人或伺服器。")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .alert("無法設定照片", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .confirmationDialog("確定要登出嗎？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("登出", role: .destructive) {
                Task {
                    UserDefaults.standard.set(false, forKey: SettingsKeys.liveLocationSharingEnabled)
                    LocationService.shared.syncLiveLocationSharing(isEnabled: false)
                    if UserDefaults.standard.string(forKey: SettingsKeys.liveLocationDeviceID) != nil {
                        await sync.stopLiveLocationSharing(context: context)
                    }
                    // 真登出：一併清掉 Firebase session，否則下次啟動 AuthService 又會還原成舊帳號，
                    // 跟畫面上「已登出」的狀態互相矛盾
                    AuthService.shared.signOut()
                    appleEmail = ""
                    displayName = ""
                    ProfilePhotoStore.shared.remove()
                    await sync.refreshAccountStatus()
                    showSignIn = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會登出 Apple 帳號並清除本機顯示的資訊，不會刪除任何資料。")
        }
        .fullScreenCover(isPresented: $showSignIn) {
            AppleSignInSheet()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoError = ProfilePhotoStore.PhotoError.unreadable.localizedDescription
                return
            }
            try ProfilePhotoStore.shared.save(imageData: data)
        } catch {
            AppLog.dataError("載入頭像失敗：\(error.localizedDescription)")
            photoError = (error as? ProfilePhotoStore.PhotoError)?.localizedDescription
                ?? "照片載入失敗，請確認網路（iCloud 照片）後再試。"
        }
    }

    /// Apple 只在首次授權提供姓名與 email；先存本機顯示欄位，再用 idToken＋nonce 換 Firebase
    /// 憑證真正登入——這一步才是關鍵，之前的版本只做了前半段，從沒呼叫過 AuthService，
    /// 所以按了按鈕畫面看似登入、其實 Firebase 端仍是未登入狀態。
    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            signInError = nil
            if let email = credential.email, !email.isEmpty {
                appleEmail = email
            }
            if let components = credential.fullName {
                let formatted = ProfileIdentity.formattedName(from: components)
                // 名稱只在使用者還沒自己設定時帶入，不覆蓋現有稱呼
                if !formatted.isEmpty && displayName.isEmpty {
                    displayName = formatted
                }
            }
            Task {
                do {
                    _ = try await AuthService.shared.completeAppleSignIn(credential)
                    await sync.refreshAccountStatus()
                } catch {
                    // 原始錯誤只進 log；UI 一律顯示轉譯過的人話（見 AuthService.userFacingMessage）
                    signInError = AuthService.userFacingMessage(for: error, context: "登入失敗")
                }
            }
        case .failure(let error):
            // 取消／裝置未登入／網路問題都交給共用轉譯判斷；使用者主動取消時會回傳 nil，不吵他
            signInError = AuthService.userFacingMessage(for: error, context: "登入失敗")
        }
    }

    private var statusTitle: String {
        switch sync.state {
        case .ready: "已登入，可建立家庭圈"
        case .sharing: "已登入，家庭圈同步中"
        case .noAccount: "尚未登入"
        case .error: "目前無法使用"
        case .unknown: "檢查中"
        }
    }

    private var statusDescription: String {
        switch sync.state {
        case .noAccount:
            "用上方按鈕登入 Apple 帳號，即可建立或加入家庭圈。"
        case .error(let message):
            message
        case .ready, .sharing:
            "你可以在「家人」分頁邀請家人加入。"
        case .unknown:
            "正在確認登入狀態。"
        }
    }
}

/// 刪除帳號前的最後確認：要求使用者用 Apple 帳號重新驗證一次，驗證成功後依序執行
/// 「雲端清理 → 真正刪除 Firebase 帳號 → 本機資料清除」，全部完成才收工。
///
/// 三段呼叫端各自的職責與順序原因（見 SettingsView 對應函式的註解）：
/// 1. onCleanupBeforeDelete：退出／解散家庭圈等所有還需要 Firebase 帳號存在才能做的
///    Firestore 呼叫，必須在帳號被刪除「之前」完成。
/// 2. AuthService.deleteAccount：reauthenticate → 撤銷 Apple 授權 → 真正刪除 Firebase 帳號。
/// 3. onLocalWipe：純本機清除，放最後，不受前兩步是否完全成功影響。
private struct DeleteAccountReauthSheet: View {
    /// 雲端清理（見上方順序說明第 1 步）
    var onCleanupBeforeDelete: () async -> Void
    /// 本機資料與偏好清除（見上方順序說明第 3 步）
    var onLocalWipe: () async -> Void
    /// 全部完成後呼叫：由 SettingsView 負責收掉這張 sheet並 dismiss 整個設定頁回主畫面
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: HCSpacing.x6) {
                Spacer(minLength: HCSpacing.x1)
                ZStack {
                    Circle()
                        .fill(HCColor.danger.opacity(0.08))
                        .frame(width: HCSpacing.x6 * 4, height: HCSpacing.x6 * 4)
                    Circle()
                        .stroke(HCColor.danger.opacity(0.16), lineWidth: HCSpacing.x1 / 2)
                        .frame(width: HCSpacing.x6 * 5, height: HCSpacing.x6 * 5)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle.weight(.medium))
                        .foregroundStyle(HCColor.danger)
                }
                .accessibilityHidden(true)
                VStack(spacing: HCSpacing.x2) {
                    Text("最後確認")
                        .font(.title2.weight(.bold))
                    Text("為了安全，請再用 Apple 帳號驗證一次，驗證完成後立即刪除。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: HCSpacing.x4) {
                    if isDeleting {
                        ProgressView("正在刪除…")
                            .padding(.vertical, HCSpacing.x2)
                        // #1：AuthService.deleteAccount 現在對驗證與刪除各套 15 秒逾時，
                        // 這裡明講「最長等候」讓使用者知道畫面會自動恢復，不必反覆點按鎖住的按鈕。
                        Text("最長等候約 30 秒；若網路不穩逾時，畫面會自動恢復並提示重試。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        SignInWithAppleButton(.continue) { request in
                            AuthService.shared.prepareAppleRequest(request)
                        } onCompletion: { result in
                            handle(result)
                        }
                        .frame(height: 50)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(HCColor.danger)
                            .multilineTextAlignment(.leading)
                    }

                    Button("取消") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .disabled(isDeleting)
                }
                .hcCard()

                Spacer(minLength: HCSpacing.x1)
            }
            .padding(.horizontal, HCSpacing.x6)
            .padding(.top, HCSpacing.x3)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
        // 刪除中不給滑掉，避免中途離開造成「雲端清乾淨了、本機沒清」的半殘狀態
        .interactiveDismissDisabled(isDeleting)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            errorMessage = nil
            isDeleting = true
            Task {
                // 1) 趁 Firebase 帳號還在時，先清乾淨雲端家庭圈——順序不能反過來（見型別註解）
                await onCleanupBeforeDelete()
                do {
                    // 2) 重新驗證 → 撤銷 Apple 授權 → 真正刪除 Firebase 帳號
                    try await AuthService.shared.deleteAccount(with: credential)
                    AuthService.shared.signOut() // 防萬一快取殘留 session
                    // 3) 本機資料與偏好清除（純本機，不依賴登入狀態）
                    await onLocalWipe()
                    onFinished()
                } catch {
                    isDeleting = false
                    // 原始錯誤只進 log；UI 一律顯示轉譯過的人話（見 AuthService.userFacingMessage）
                    errorMessage = AuthService.userFacingMessage(for: error, context: "刪除帳號驗證失敗")
                }
            }
        case .failure(let error):
            // 取消／裝置未登入／網路問題都交給共用轉譯判斷；使用者主動取消時會回傳 nil，不吵他
            errorMessage = AuthService.userFacingMessage(for: error, context: "刪除帳號驗證失敗")
        }
    }
}

/// #7+8：「設定你的名稱」空殼修好——這頁才是真正能改名、改家庭身分的地方。
/// 本名（profileDisplayName）與家庭身分（profileFamilyRole）是分開的兩個鍵：
/// 本名優先當顯示名稱，本名空著時才退而用身分頂替（與 FamilyHomeView/applyRole 等既有邏輯一致）。
private struct PersonalProfileView: View {
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var familyRole = ""
    @AppStorage(SettingsKeys.profileContactNote) private var contactNote = ""
    @Environment(\.modelContext) private var context
    @Query private var members: [LocalFamilyMember]
    @Environment(FamilySyncService.self) private var sync
    /// 改名同步到雲端的去抖任務：打字中不要每個字都寫一次 Firestore
    @State private var cloudSyncTask: Task<Void, Never>?

    private var me: LocalFamilyMember? { members.first(where: \.isCurrentUser) }

    /// 家庭身分是否命中六個常見快選；命中時下方自訂輸入框顯示空白，避免跟方塊重複顯示同一個值
    private var isPresetRole: Bool {
        familyRole.isEmpty || FamilyRole.all.contains(where: { $0.label == familyRole })
    }

    private let roleColumns = [
        GridItem(.flexible(), spacing: HCSpacing.x2),
        GridItem(.flexible(), spacing: HCSpacing.x2),
        GridItem(.flexible(), spacing: HCSpacing.x2),
    ]

    var body: some View {
        Form {
            Section {
                TextField("本名", text: $displayName)
                Text("家人會在安否回報、家人清單上看到這個名字，請只填家人辨識所需的資訊。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("你的本名")
            }
            .onChange(of: displayName) { _, newValue in
                syncMemberName(displayName: newValue, familyRole: familyRole)
                scheduleCloudSync()
            }

            Section {
                LazyVGrid(columns: roleColumns, spacing: HCSpacing.x2) {
                    ForEach(FamilyRole.all) { role in
                        roleChip(role)
                    }
                }
                .padding(.vertical, HCSpacing.x1)
                TextField("其他稱呼（例如：姊姊、看護）", text: Binding(
                    get: { isPresetRole ? "" : familyRole },
                    set: { familyRole = $0 }
                ))
                Text("這是你在家裡的角色（例如「媽媽」），會顯示在家人清單上；本名沒填時，家人會改看到這個稱呼。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("你的家庭身分")
            }
            .onChange(of: familyRole) { _, newValue in
                syncMemberName(displayName: displayName, familyRole: newValue)
                scheduleCloudSync()
            }

            Section("緊急聯絡備註") {
                TextField("備註（選填）", text: $contactNote, axis: .vertical)
                    .lineLimit(3...6)
                Text("請勿填入不必要的個人資料；此原型只會儲存在此裝置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("你的名字與家庭身分")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("personal_profile")
    }

    private func roleChip(_ role: FamilyRole) -> some View {
        let isSelected = familyRole == role.label
        return Button {
            familyRole = role.label
            Analytics.track("role_selected")
        } label: {
            VStack(spacing: HCSpacing.x1) {
                Text(role.emoji)
                    .font(.title2)
                Text(role.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HCSpacing.x2)
            .background(
                RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                    .fill(isSelected ? HCColor.brand.opacity(0.14) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                    .stroke(isSelected ? HCColor.brand : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(role.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 停止打字 1 秒後，把新名字同步到雲端（成員資料與位置文件）
    private func scheduleCloudSync() {
        cloudSyncTask?.cancel()
        cloudSyncTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await sync.applyOwnNameChange(context: context)
        }
    }

    /// 同步到本人的家庭成員資料：安否回報署名（senderName）與家人清單都靠它，
    /// 不同步的話改了名字或身分、家人收到的回報還是舊署名。本名優先，本名空著才用身分頂替。
    private func syncMemberName(displayName: String, familyRole: String) {
        guard let me else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmedName.isEmpty ? familyRole : trimmedName
        guard !resolved.isEmpty, me.name != resolved else { return }
        me.name = resolved
        context.saveReporting()
    }
}

private struct AlertSettingsView: View {
    @AppStorage(SettingsKeys.alertsEnabled) private var alertsEnabled = true
    @AppStorage(SettingsKeys.alertsPaused) private var paused = false
    @AppStorage(SettingsKeys.highConfidenceOnly) private var highConfidenceOnly = true
    @AppStorage(SettingsKeys.alertFrequencyLevel) private var alertFrequencyLevel = AlertFrequency.standard.rawValue
    @AppStorage(SettingsKeys.digestEnabled) private var digestEnabled = true
    @AppStorage(SettingsKeys.digestHour) private var digestHour = 20
    // D4：通知自主權——吵醒門檻與安靜時段（實際攔截在 NotificationScheduler.effectiveTimeSensitive）
    @AppStorage(SettingsKeys.wakeThreshold) private var wakeThresholdRaw = WakeThreshold.standard.rawValue
    @AppStorage(SettingsKeys.mapDisplayScope) private var mapDisplayScopeRaw = MapDisplayScope.family.rawValue
    @AppStorage(SettingsKeys.quietHoursEnabled) private var quietHoursEnabled = false
    @AppStorage(SettingsKeys.quietStartHour) private var quietStartHour = 22
    @AppStorage(SettingsKeys.quietEndHour) private var quietEndHour = 7
    @Query private var events: [LocalSafetyEvent]
    @Query private var members: [LocalFamilyMember]
    @Query private var circles: [LocalLifeCircle]
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.liveCircleRadiusMeters) private var alertRadius = 1_000
    /// 「允許通知」按下後的結果（nil＝尚未按過）——按了沒反應等於壞掉，必須有可見回饋
    @State private var notificationGranted: Bool?
    /// 2026-07-24：關閉「災害警報通知」等於關掉所有保命警報，一滑就掉風險太高，
    /// 改用中間值攔截——使用者關閉時先跳確認框，取消就不落地，Toggle 視覺上維持原樣
    @State private var showDisableAlertsConfirm = false

    private var wakeThreshold: WakeThreshold {
        WakeThreshold(rawValue: wakeThresholdRaw) ?? .standard
    }

    var body: some View {
        Form {
            Section("提醒偏好") {
                // 2026-07-24：原「啟用本機提醒」是工程師詞彙，實機測試員看不懂「本機」是什麼、
                // 也不知道關掉後保命警報還在不在——查證結果：所有會顯示給使用者看的警報
                // （事件推播、家人安否詢問／回報）全部經過 NotificationScheduler.scheduleAlert，
                // 這顆開關關掉＝一律不發，沒有任何警報會顯示；伺服器的無聲推播只會在背景
                // 喚醒 App 刷新資料，本身不會跳出任何通知。故改名為「災害警報通知」並
                // 明講「關閉後不會收到任何警報」，且關閉動作需二次確認。
                Toggle("災害警報通知", isOn: Binding(
                    get: { alertsEnabled },
                    set: { newValue in
                        if newValue {
                            alertsEnabled = true
                        } else {
                            showDisableAlertsConfirm = true
                        }
                    }
                ))
                Text("關閉後將不會收到任何警報通知。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("提醒多寡")
                    .font(.subheadline.weight(.semibold))
                Text("調整你收到通知的多寡，不影響文字大小（文字大小在「外觀」設定另外調整）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("通知頻率", selection: $alertFrequencyLevel) {
                    ForEach(AlertFrequency.allCases) { level in
                        Text(level.shortLabel).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((AlertFrequency(rawValue: alertFrequencyLevel) ?? .standard).explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("公共安全事件僅高可信度提醒", isOn: $highConfidenceOnly)
                Toggle("暫停提醒", isOn: $paused)
                Button("允許通知") {
                    Task { notificationGranted = await NotificationScheduler.requestPermission() }
                }
                if let granted = notificationGranted {
                    Label(
                        granted ? "通知已開啟" : "通知未開啟——請到系統「設定 > 通知」中允許安心圈",
                        systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(granted ? HCColor.safe : HCColor.attention)
                    if !granted, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("到設定開啟") { UIApplication.shared.open(url) }
                    }
                }
            }
            Section {
                Picker("警戒範圍", selection: $alertRadius) {
                    ForEach(FamilySyncService.alertRadiusOptions, id: \.self) { meters in
                        Text(Self.radiusLabel(meters)).tag(meters)
                    }
                }
                .accessibilityIdentifier("alertRadiusPicker")
            } header: {
                Text("警戒範圍")
            } footer: {
                Text("以你的位置為圓心，這個半徑內發生的事件才會提醒你。改了會立即套用到地圖上的圈與警報判斷；分享位置中時家人也會看到新的範圍。")
            }
            Section {
                Picker("地圖顯示範圍", selection: $mapDisplayScopeRaw) {
                    ForEach(MapDisplayScope.allCases) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                .accessibilityIdentifier("mapDisplayScopePicker")
            } header: {
                Text("地圖")
            } footer: {
                Text("只影響地圖上顯示的事件，不影響通知。範圍內的縣市邊界會用金色描出。")
            }
            Section("勿擾與吵醒") {
                Picker("吵醒門檻", selection: $wakeThresholdRaw) {
                    ForEach(WakeThreshold.allCases) { level in
                        Text(level.shortLabel).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("吵醒＝突破靜音與勿擾的時效性通知；降級後通知仍會送達，只是不亮屏、不出聲。要控制推播事件的種類多寡，請調整上方『提醒偏好』的通知頻率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 「絕不吵醒」與「僅重大才吵」下，安靜時段對實際行為都沒有額外效果
                // （見 NotificationScheduler.effectiveTimeSensitive：never 在安靜時段判斷前就 return false；
                // majorOnly 下非重大已被攔在前面、重大又不受安靜時段影響，兩檔下開關形同虛設）。
                // 與其留一顆「打得開但沒作用」的開關誤導使用者，改收起整塊並用一行話說明理由；
                // 既有設定值（quietHoursEnabled／start／end）保留不清除，切回「標準」時原樣恢復。
                switch wakeThreshold {
                case .never:
                    Text("已設為絕不吵醒：任何警報在任何時段都不會吵醒你，毋須設定安靜時段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .majorOnly:
                    Text("你已設定僅重大才吵：安靜時段內外行為相同（僅地震、海嘯、火災與家人安否會吵醒你），毋須另外設定安靜時段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .standard:
                    Toggle("安靜時段", isOn: $quietHoursEnabled)
                    if quietHoursEnabled {
                        Stepper("開始：\(quietStartHour):00", value: $quietStartHour, in: 0...23)
                        Stepper("結束：\(quietEndHour):00", value: $quietEndHour, in: 0...23)
                        Text("時段內僅地震・海嘯・火災與家人安否會吵醒你。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: wakeThresholdRaw)
            Section("每日安全摘要") {
                Toggle("每天固定時間發送摘要", isOn: $digestEnabled)
                if digestEnabled {
                    Picker("發送時間", selection: $digestHour) {
                        ForEach(0..<24, id: \.self) { Text("\($0):00") }
                    }
                }
                Text("沒有事件的日子也會告訴你「今天平安」，並回報過濾了多少低風險資訊。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("資料與安全") {
                Text("警戒圈、家人與事件資料保存在此裝置；主動開啟的即時圈位置會同步給家庭圈成員。刪除 App 會刪除本機資料。")
                Text("安心圈不是 110、119 或緊急救難服務。遇立即危險請直接撥打 110 或 119。")
            }
        }
        .navigationTitle("提醒設定")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("alert_settings")
        // 摘要設定變更時立即重排通知
        .onChange(of: digestEnabled) { refreshDigest() }
        // 警戒範圍：改了立即寫進本人的圈、重算警報並（分享中）重新上傳
        .onChange(of: alertRadius) { _, newValue in
            Task { await sync.applyAlertRadius(newValue, context: context) }
        }
        .onAppear {
            // 以本人即時圈實際半徑為準（避免與舊版地圖調整後的值不一致），對齊到最近的選項
            let current = circles.first { $0.member?.isCurrentUser == true && ($0.isFollowMe || $0.kind == .live) }?.radiusMeters ?? alertRadius
            let nearest = FamilySyncService.alertRadiusOptions.min { abs($0 - current) < abs($1 - current) } ?? 1_000
            if nearest != alertRadius { alertRadius = nearest }
        }
        .onChange(of: digestHour) { refreshDigest() }
        // FCM 現在只負責無聲喚醒；停用或暫停時立即退訂，恢復時重訂目前有效生活圈。
        .onChange(of: alertsEnabled) { FCMTopicSync.sync(circles: circles) }
        .onChange(of: paused) { FCMTopicSync.sync(circles: circles) }
        // 保命 App 的總開關不能一滑就掉：關閉「災害警報通知」需二次確認，取消則維持開啟
        .confirmationDialog(
            "確定要關閉災害警報通知？",
            isPresented: $showDisableAlertsConfirm,
            titleVisibility: .visible
        ) {
            Button("確定關閉", role: .destructive) { alertsEnabled = false }
            Button("取消", role: .cancel) {}
        } message: {
            Text("關閉後，任何警報（包含火災、地震等保命警報）都不會再通知你。")
        }
    }

    private static func radiusLabel(_ meters: Int) -> String {
        meters >= 1_000 ? String(format: "%g 公里", Double(meters) / 1_000) : "0.5 公里"
    }

    private func refreshDigest() {
        let summary = DigestComposer.summary(events: events, members: members)
        Task { await NotificationScheduler.refreshDailyDigest(summary: summary) }
    }
}

#Preview {
    SettingsView()
        .environment(FamilySyncService())
}
