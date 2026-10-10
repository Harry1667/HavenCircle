import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseMessaging
import os // Swift 6.2 MemberImportVisibility：直接使用 os.Logger 插值的檔案必須自行 import

/// AppDelegate 與家庭邀請深連結（deep link）的處理鏈（原為 CKShare 時代寫的檔案，
/// 家庭同步改走 Firebase 邀請碼後功能已改為：Firebase 初始化、FCM 訂閱、深連結接手）。
///
/// SwiftUI 生命週期的 App 沒有直接的分享接受修飾符，必須透過
/// UIApplicationDelegate 設定一個 scene delegate，由系統在使用者點開邀請連結時回呼。
/// 接受到的內容透過 NotificationCenter 轉交給 FamilySyncService 處理。
extension Notification.Name {
    static let didAcceptFamilyShare = Notification.Name("didAcceptFamilyShare")
    static let didReceiveDeepLink = Notification.Name("didReceiveDeepLink")
}

/// 冷啟動時由 URL 拉起 App 的暫存（scene 連接早於 SwiftUI 視圖訂閱，直接發通知會漏接）
enum DeepLinkStore {
    @MainActor static var pending: URL?
}

/// AppDelegate 回呼（無聲推播喚醒）需要資料庫容器才能跑資料管線，
/// 但容器由 HavenCircleApp.init 建立——這裡提供橋接（init 一定早於任何推播回呼）
enum AppRuntime {
    @MainActor static var container: ModelContainer?
    @MainActor static var familySync: FamilySyncService?
}

final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {
    /// 跟隨圈的監聽必須在這裡掛（而不是只在 SwiftUI .task）：
    /// 顯著位置變更在背景重啟 App 時，scene 不一定會連接，.task 可能永遠不跑
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Firebase 要在任何 Firebase 呼叫前初始化；緊接著套用「匿名使用統計」開關，
        // 使用者若關閉統計，Firebase 也不收集（不含 IDFA，用的是 FirebaseAnalytics 無廣告識別碼版）。
        FirebaseApp.configure()
        Analytics.applyFirebaseCollectionSetting()
        Messaging.messaging().delegate = self // FCM 行政區主題訂閱（地區性推播）
        if let container = AppRuntime.container {
            LocationService.shared.onFollowLocationUpdate = { location in
                Task { @MainActor in
                    await FollowCircleService.handle(location: location, container: container)
                }
            }
            LocationService.shared.onLiveLocationUpdate = { location in
                Task { @MainActor in
                    let defaults = UserDefaults.standard
                    guard defaults.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
                          let sync = AppRuntime.familySync else { return }
                    let storedRadius = defaults.integer(forKey: SettingsKeys.liveCircleRadiusMeters)
                    await sync.publishLiveLocation(
                        location,
                        displayName: defaults.string(forKey: SettingsKeys.profileDisplayName) ?? "",
                        radiusMeters: storedRadius > 0 ? storedRadius : 1_000,
                        context: container.mainContext
                    )
                }
            }
            // 被系統因「顯著位置變更／拜訪／地理圍欄」在背景重新啟動時（launchOptions 有 .location），
            // 走到這裡就已經重建 LocationService 並掛好回呼；定位資料會緊接著送進上面的 onLiveLocationUpdate。
            if launchOptions?[.location] != nil {
                AppLog.data.info("App 因位置事件在背景啟動，已重建定位服務")
            }
            LocationService.shared.onVisit = { visit in
                Task { @MainActor in
                    await AppRuntime.familySync?.handleVisit(visit, context: container.mainContext)
                }
            }
            LocationService.shared.onRegionTransition = { transition in
                Task { @MainActor in
                    await AppRuntime.familySync?.handleRegionTransition(transition, context: container.mainContext)
                }
            }
            let hasFollow = FollowCircleService.hasFollowCircle(context: container.mainContext)
            LocationService.shared.syncFollowMonitoring(hasFollowCircle: hasFollow)
            LocationService.shared.syncLiveLocationSharing(
                isEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled)
            )
            GeofenceSync.sync(context: container.mainContext)
            // 前景啟動即校正一次跟隨圈：顯著位置變更（SLC）要走約 500 公尺才觸發，
            // 只靠它的話「出遠門後第一次開 App」圈還停在舊位置，警報比對用錯地點。
            // 開 App 當下主動取一次位（已授權才會有結果），把圈先搬到人所在的地方。
            if hasFollow {
                Task { @MainActor in
                    guard let location = await LocationService.shared.currentLocation() else { return }
                    await FollowCircleService.handle(location: location, container: container)
                }
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShareSceneDelegate.self
        return config
    }

    // MARK: - APNs 裝置權杖

    /// 拿到權杖：存本機（Debug 版設定頁可複製，供 Push Console 測試）＋
    /// 上傳中繼站登記（伺服器偵測到新官方警報時才知道要喚醒誰）
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: SettingsKeys.apnsDeviceToken)
        AppLog.notifications.info("已取得 APNs 裝置權杖")
        // FCM 需要原始 APNs 權杖才能把主題推播轉送到這台 iOS 裝置。
        // proxy 關閉後 FCM 的環境自動判定不可靠，必須明確指定 sandbox/prod，
        // 否則 FCM 會用 production 閘道去送 sandbox(Debug) 權杖 → APNs 靜默丟包（發送端回 ok 但收不到）。
        #if DEBUG
        Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)
        #else
        Messaging.messaging().setAPNSToken(deviceToken, type: .prod)
        #endif
        Task { await APNsRegistrar.upload(token: token) }
    }

    // MARK: - FCM 註冊權杖

    /// FCM 權杖就緒後，主題訂閱才會真正生效——此時觸發一次行政區主題同步。
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        AppLog.notifications.info("已取得 FCM 註冊權杖")
        Task { @MainActor in
            if let container = AppRuntime.container {
                // 權杖（可能）換新 → 強制清快取重訂，避免舊「已訂閱」旗標讓新權杖漏訂主題
                FCMTopicSync.resync(container: container)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 模擬器與未佈建的裝置會走到這裡，只記錄不打擾使用者
        AppLog.notifications.error("APNs 註冊失敗：\(error.localizedDescription)")
    }

    // MARK: - 無聲推播喚醒

    /// 伺服器偵測到新官方警報 → 廣播 {content-available:1} → 系統在背景叫醒 App 走到這裡。
    /// 喚醒後跑一次完整資料管線：抓最新警報、比對生活圈、相關才發本機通知——
    /// 事件伺服器只做廣播喚醒，警報比對仍在裝置上完成；家庭位置存在 Firebase Firestore，不會送到這台事件伺服器。
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Firebase proxy 已關閉：手動把收到的推播轉交 FCM（資料訊息追蹤／分析所需）
        Messaging.messaging().appDidReceiveMessage(userInfo)
        // 匿名漏斗：記「裝置實際收到無聲喚醒」，和伺服器端 FCM API 回傳成功分開看。
        // 不記推播內容、主題、位置或裝置識別。
        Analytics.track("silent_wake_received")
        guard let container = AppRuntime.container else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            if let sync = AppRuntime.familySync {
                await sync.fetchLiveLocations(context: container.mainContext)
            }
            await EventPipeline.refresh(context: container.mainContext)
            AppLog.notifications.info("無聲推播喚醒：資料管線刷新完成")
            Analytics.track("silent_wake_refreshed")
            // 一律回 .newData：官方警報或家庭位置任一更新，都完成了一次有價值的同步
            completionHandler(.newData)
        }
    }
}

final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    // Firebase 邀請碼取代 CKShare 後，家庭加入改由 JoinByCodeView 輸碼完成，
    // 不再需要系統的 userDidAcceptCloudKitShareWith 分享接受回呼。

    // 設了自訂 scene delegate 後，SwiftUI 的 .onOpenURL 收不到 URL（系統改送這裡），
    // Widget deep link 必須在此接手轉交。
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let url = connectionOptions.urlContexts.first?.url {
            DeepLinkStore.pending = url // 冷啟動：等視圖出現後再路由
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        NotificationCenter.default.post(name: .didReceiveDeepLink, object: url)
    }
}
