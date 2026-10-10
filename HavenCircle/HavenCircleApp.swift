//
//  HavenCircleApp.swift
//  HavenCircle
//

import SwiftUI
import SwiftData
import UserNotifications
import os

@main
struct HavenCircleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let modelContainer: ModelContainer
    @State private var familySync = FamilySyncService()
    @State private var entitlementStore = EntitlementStore()
    // 外觀模式：使用者可在設定頁強制淺色/深色（預設跟隨系統）
    @AppStorage(SettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system.rawValue
    // 全域字體大小：使用者可在設定頁放大顯示（預設跟隨系統）；設定變更靠這個 @AppStorage
    // 驅動 Scene body 重新求值即時生效，套用方式同 appearanceMode
    @AppStorage(SettingsKeys.appTextSize) private var appTextSize = AppTextSize.system.rawValue
    @AppStorage(SettingsKeys.profileDisplayName) private var profileDisplayName = ""
    @AppStorage(SettingsKeys.liveLocationSharingEnabled) private var liveLocationSharingEnabled = false
    @AppStorage(SettingsKeys.liveCircleRadiusMeters) private var liveCircleRadiusMeters = 1_000

    init() {
        modelContainer = Self.makeContainer()
        // 無聲推播喚醒的回呼（AppDelegate）需要容器跑資料管線，橋接過去
        AppRuntime.container = modelContainer
        AppRuntime.familySync = familySync
        // 導航標題套圓體，appearance 要在第一個視圖建立前設定才會生效
        HCAppearance.apply()
        // 前景也要顯示通知橫幅（演練模式必要）
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // 警報通知的「回報我平安／尚未脫離危險」快速按鈕（要在任何通知送出前登記）
        NotificationScheduler.registerCategories()
        // 背景任務處理器必須在啟動完成前登記（Apple 規定），所以放 init 不放 .task
        BackgroundRefresh.register(container: modelContainer)
        // 冷啟動次數 +1：放 init 保證早於任何視圖出現，讓「第二次開 App 才問身分」的判定不會有競態。
        let launches = UserDefaults.standard.integer(forKey: SettingsKeys.launchCount) + 1
        UserDefaults.standard.set(launches, forKey: SettingsKeys.launchCount)
    }

    /// 建立本機資料庫。取代舊版 try!：schema 變動導致遷移失敗時，
    /// 先刪除舊資料庫重建（原型階段可接受），再不行才退回記憶體模式，
    /// 每一步都記錄原因，不讓 App 無聲閃退。
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([LocalSafetyEvent.self, LocalFamilyMember.self, LocalLifeCircle.self, RegionAlert.self])
        // 明確關閉 SwiftData 的 CloudKit 鏡像：本機模型只存這台裝置，
        // 家庭同步已改走 Firebase Firestore（FamilySyncService），不再用 CloudKit/CKShare。
        // entitlements 裡的 CloudKit 權限是舊架構殘留、目前未被程式碼使用，但若不指定
        // cloudKitDatabase: .none，SwiftData 偵測到 entitlement 仍會嘗試鏡像，
        // 而本機模型用了 @Attribute(.unique)（CloudKit 不支援）會建立失敗。
        // TODO：確認 Apple Developer Portal 的 App ID 能力設定同步後，可考慮整組移除
        // CloudKit entitlement——但要先確認移除不影響現有簽章/描述檔，此處先不動。
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            AppLog.data.error("ModelContainer 建立失敗，嘗試重建本機資料庫：\(error.localizedDescription)")
            // 必須連同 -wal / -shm side-car 檔一起刪，否則殘留的日誌檔會讓重建仍讀到舊 schema
            let storeURL = config.url
            for suffix in ["", "-wal", "-shm"] {
                let url = suffix.isEmpty ? storeURL
                    : storeURL.deletingLastPathComponent()
                        .appendingPathComponent(storeURL.lastPathComponent + suffix)
                try? FileManager.default.removeItem(at: url)
            }
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                AppLog.data.fault("重建仍失敗，退回記憶體模式（資料不會保存）：\(error.localizedDescription)")
                do {
                    return try ModelContainer(
                        for: schema,
                        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                    )
                } catch {
                    fatalError("無法建立任何資料庫：\(error)")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // nil（跟隨系統）時不強制，交還系統深淺設定
                .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
                // nil（跟隨系統）時不覆寫，交還使用者在 iOS 設定裡的文字大小
                .modifier(AppTextSizeOverride(rawValue: appTextSize))
                .environment(familySync)
                .environment(entitlementStore)
                .overlay(alignment: .top) { ArrivalBannerOverlay().environment(familySync) }
                .task {
                    // 以環境實際使用的實例為準（AppDelegate 回呼與定位回呼都經由 AppRuntime 找它）
                    AppRuntime.familySync = familySync
                    // StoreKit 2 交易長聽：先判定目前權益，再開 Transaction.updates 監聽
                    // （續訂／退款／家庭共享成員的權益變化都要在 App 存活期間即時反映）
                    entitlementStore.start()
                    // 遠端設定放最前面（5 秒逾時）：後面的資料管線要吃它的功能開關
                    await RemoteConfig.refresh()
                    Self.markCurrentUser(
                        context: modelContainer.mainContext,
                        displayName: profileDisplayName
                    )
                    #if DEBUG
                    // 六災難情境測試：--seed-six-disasters／--clear-six-disasters
                    await SixDisasterScenario.runIfRequested(context: modelContainer.mainContext)
                    #endif
                    // 註冊 APNs：權杖與通知權限互相獨立，先拿權杖存著（AppDelegate 回呼），
                    // AppDelegate 取得權杖後會上傳到中繼站；伺服器偵測新官方警報後用 APNs 喚醒。
                    UIApplication.shared.registerForRemoteNotifications()
                    // 啟動即跑一次資料管線（mock 來源；階段 4 換成真實來源）
                    await EventPipeline.refresh(context: modelContainer.mainContext)
                    // 匿名統計：記一次啟動並把累積佇列送出（斷網自動留到下次）
                    Analytics.track("app_open")
                    await Analytics.flush()
                    // #11：App 沒在跑時收不到 credentialRevokedNotification，啟動時主動複查一次
                    // Apple 授權是否已被撤銷（例如上次關閉 App 期間使用者去系統設定登出了 Apple 帳號）。
                    await AuthService.shared.checkAppleCredentialState()
                    await familySync.refreshAccountStatus()
                    LocationService.shared.syncLiveLocationSharing(
                        isEnabled: liveLocationSharingEnabled
                    )
                    if liveLocationSharingEnabled {
                        LocationService.shared.requestAlwaysPermission()
                        if let location = await LocationService.shared.currentLocation() {
                            await familySync.publishLiveLocation(
                                location,
                                displayName: profileDisplayName,
                                radiusMeters: liveCircleRadiusMeters,
                                context: modelContainer.mainContext
                            )
                        }
                    } else if UserDefaults.standard.string(
                        forKey: SettingsKeys.liveLocationDeviceID
                    ) != nil {
                        await familySync.stopLiveLocationSharing(
                            context: modelContainer.mainContext
                        )
                    }
                    await familySync.fetchLiveLocations(context: modelContainer.mainContext)
                }
                // 家人位置輪詢：前景才跑，每 20 秒讀一次（對方 App 在前景時 1 分鐘內一定看得到），
                // 回前景立刻讀一次。放在獨立 task 而非接在上面那串啟動流程後面——
                // 舊版輪詢排在資料管線、遠端設定、定位等一長串 await 之後，任何一步卡住就永遠不輪詢。
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await familySync.fetchLiveLocations(context: modelContainer.mainContext)
                        await familySync.pollArrivals()
                        do {
                            try await Task.sleep(for: .seconds(20))
                        } catch {
                            return
                        }
                    }
                }
                // App 停在前景時不能只靠「打開／切回來」才更新：使用者會把安心圈
                // 留在桌面上看，而 eventRefreshMinutes 已存在於遠端設定卻從未被使用。
                // scenePhase 改成非 active 時 SwiftUI 會取消這個 task，不會在背景持續拉資料。
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    let minutes = max(1, RemoteConfig.tuning("eventRefreshMinutes", default: 5))
                    let interval = Duration.seconds(Int(minutes * 60))
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: interval)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, scenePhase == .active else { return }
                        await EventPipeline.refresh(context: modelContainer.mainContext)
                    }
                }
        }
        .modelContainer(modelContainer)
        // App 進背景時排一次背景刷新（BGTaskScheduler 的請求要在背景前送出才有效）
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundRefresh.schedule()
                // 守護地點圍欄：離開前台時依最新的固定圈同步（編輯過守護地點後下次切換就生效）
                GeofenceSync.sync(context: modelContainer.mainContext)
            } else if phase == .active {
                GeofenceSync.sync(context: modelContainer.mainContext)
                // 分享中回到前景：心跳若已到期，立刻補一筆最新位置
                if liveLocationSharingEnabled { LocationService.shared.kickHeartbeat() }
                Task {
                    // #11：回前景複查一次 Apple 授權狀態（雙重保險的第二層；通知能送達時這裡多查一次
                    // 沒有壞處，通知没送達時這裡是唯一能及時發現撤銷的地方）。
                    await AuthService.shared.checkAppleCredentialState()
                    await familySync.fetchLiveLocations(context: modelContainer.mainContext)
                    // A2：回前景順便刷新家庭成員清單（新成員加入、名字改動都要跟著新鮮）
                    await familySync.refreshFamilyMembers(context: modelContainer.mainContext)
                }
                // 回前景時同步 FCM 行政區主題訂閱（生活圈可能已新增/編輯/刪除）
                FCMTopicSync.sync(container: modelContainer)
            }
        }
    }

    private static func markCurrentUser(context: ModelContext, displayName: String) {
        let members = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
        guard !members.contains(where: \.isCurrentUser) else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let owner = members.first(where: {
            $0.relationship == "擁有者" || (!trimmedName.isEmpty && $0.name == trimmedName)
        }) {
            owner.isCurrentUser = true
            context.saveReporting()
        }
    }
}

/// 全域字體大小覆寫：AppTextSize.system 時 overrideSize 為 nil，該分支原樣回傳 content
/// （不加 .dynamicTypeSize，交還系統設定）；其餘三檔套用對應的 Dynamic Type 級距，全樹適用。
private struct AppTextSizeOverride: ViewModifier {
    let rawValue: String

    func body(content: Content) -> some View {
        if let size = AppTextSize(rawValue: rawValue)?.overrideSize {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
