import Foundation
import CoreLocation
import Observation
import os // Swift 6.2 MemberImportVisibility：用 os.Logger 插值的檔案必須自行 import

/// 定位服務有三種清楚分離的用途：
/// (1) 地圖藍點與一次性取位；(2) 本機即時圈更新；(3) 使用者主動開啟的家庭位置分享。
/// 家庭分享開啟時使用約 100 公尺精度／距離門檻，並允許背景更新；關閉後立即停止標準定位。
/// 顯著位置變更保留作為省電喚醒與本機即時圈的降級路徑。
///
/// 心跳（分享中才有）：distanceFilter 只在「移動 100 公尺」時回報，人待在原地就完全沒有回呼，
/// 家人端會誤判成「超過 15 分鐘沒更新」。所以分享期間每分鐘檢查一次，距離上一筆送出的
/// 定位超過 [heartbeatDueInterval] 就暫時把 distanceFilter 放開，取一筆新定位走同一條
/// onLiveLocationUpdate 寫入路徑（同座標、新的最後回報時間），拿到後立刻恢復 100 公尺門檻。
/// 用「真的新定位」而不是重送舊座標，是為了讓心跳同時證明「定位還在運作」。
@Observable
@MainActor
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 一次性取位的等待者（同時間只允許一個，新請求會讓舊的以 nil 結束）
    private var oneShot: CheckedContinuation<CLLocation?, Never>?
    private var oneShotTimeout: Task<Void, Never>?
    /// 跟隨圈回呼：顯著位置變更到達時呼叫（由 AppDelegate 啟動時掛上）
    var onFollowLocationUpdate: ((CLLocation) -> Void)?
    /// 家庭即時位置分享回呼；只有使用者明確開啟分享時才呼叫。
    var onLiveLocationUpdate: ((CLLocation) -> Void)?
    private var hasFollowCircle = false
    private var liveSharingEnabled = false
    /// 心跳排程：分享期間每分鐘醒來檢查一次是否該補一筆「仍在此處」
    private var heartbeatTask: Task<Void, Never>?
    /// 心跳取位等待中：distanceFilter 暫時放開，下一筆定位到手就恢復
    private var heartbeatAwaitingFix = false
    private var heartbeatFixTimeout: Task<Void, Never>?
    /// 最後一次送給 onLiveLocationUpdate 的時間（移動回報與心跳都算）
    private var lastLiveDeliveryAt: Date?
    /// 平常的移動門檻（公尺）：心跳負責時間，distanceFilter 負責移動
    private static let movementDistanceFilter: CLLocationDistance = 100
    /// 距離上次送出超過這麼久就補心跳；比 5 分鐘短 30 秒，吸收每分鐘檢查與取位耗時的誤差
    private static let heartbeatDueInterval: TimeInterval = LiveLocationPresence.heartbeatInterval - 30

    override private init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = Self.movementDistanceFilter
        manager.activityType = .other
        // 不讓 iOS 自動暫停：自動暫停的觸發條件正是「一段時間沒移動」，暫停後背景 App 會被掛起、
        // 不會自動恢復，靜止的人就再也送不出心跳，被家人端判成失聯。
        // 標準定位只在使用者開啟家庭分享時運作（見 reconcileMonitoring），關閉分享即停止，
        // 所以這個設定不影響沒開分享的使用者耗電。
        manager.pausesLocationUpdatesAutomatically = false
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// 地圖藍點用：只負責要權限，位置由 MapKit 的 UserAnnotation 自行取得
    func requestPermissionIfNeeded() {
        #if DEBUG
        guard !Self.skipLocationPromptForScreenshots else { return }
        #endif
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 跟隨圈用：要求「永遠允許」（顯著位置變更要在背景喚醒 App 必須是 Always）。
    /// 從未問過會先出 when-in-use 對話框，之後系統會再問升級；已是 when-in-use 則直接問升級
    func requestAlwaysPermission() {
        #if DEBUG
        guard !Self.skipLocationPromptForScreenshots else { return }
        #endif
        manager.requestAlwaysAuthorization()
    }

    #if DEBUG
    /// --skip-location-prompt：自動化截圖用。系統定位權限對話框無法用 simctl 自動點掉
    /// （`simctl privacy grant` 對這個對話框不生效，AppleScript/cliclick 這台機器上又拿不到
    /// 輔助使用權限），一擋住畫面整組截圖流程就卡死。加這個旗標讓 App 乾脆不發出權限請求，
    /// 對話框永遠不會跳出來；地圖藍點／即時圈這類需要真實定位的功能在這個模式下自然不可用，
    /// 純粹是截圖模式的取捨，不影響一般使用者（Release 版整段編不進去）。
    private static let skipLocationPromptForScreenshots =
        ProcessInfo.processInfo.arguments.contains("--skip-location-prompt")
    #endif

    /// 依「是否存在跟隨圈」開關顯著位置變更監聽。
    /// 呼叫時機：App 啟動（含背景被喚醒）、跟隨圈建立或刪除後。
    /// 顯著位置變更不需要 UIBackgroundModes location，系統會在必要時自行重啟 App
    func syncFollowMonitoring(hasFollowCircle: Bool) {
        self.hasFollowCircle = hasFollowCircle
        reconcileMonitoring()
    }

    /// 即時圈分享開關。標準定位只在分享期間運作；分享狀態與停止入口由 App 內持續清楚顯示。
    func syncLiveLocationSharing(isEnabled: Bool) {
        liveSharingEnabled = isEnabled
        reconcileMonitoring()
    }

    /// 安否回報用：一次性取得目前位置；未授權或取不到一律回 nil，不擋回報流程
    func currentLocation() async -> CLLocation? {
        guard isAuthorized else { return nil }
        // 一分鐘內的快取位置直接用，省一次 GPS 熱機
        if let cached = manager.location, cached.timestamp > .now.addingTimeInterval(-60) {
            return cached
        }
        return await withCheckedContinuation { continuation in
            oneShotTimeout?.cancel()
            oneShot?.resume(returning: nil)
            oneShot = continuation
            manager.requestLocation()
            oneShotTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(12))
                } catch {
                    return
                }
                guard let self, let waiting = self.oneShot else { return }
                self.oneShot = nil
                waiting.resume(returning: nil)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate（manager 建立在主執行緒，回呼也在主執行緒）

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        reconcileMonitoring()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        oneShotTimeout?.cancel()
        oneShotTimeout = nil
        // 一次性取位與跟隨圈共用這個回呼：兩邊都要餵到
        oneShot?.resume(returning: latest)
        oneShot = nil
        onFollowLocationUpdate?(latest)
        if heartbeatAwaitingFix {
            finishHeartbeatFix()
        }
        if liveSharingEnabled {
            lastLiveDeliveryAt = .now
            onLiveLocationUpdate?(latest)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.data.error("一次性取位失敗：\(error.localizedDescription)")
        oneShotTimeout?.cancel()
        oneShotTimeout = nil
        oneShot?.resume(returning: nil)
        oneShot = nil
    }

    private func reconcileMonitoring() {
        guard isAuthorized else {
            stopHeartbeat()
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
            manager.allowsBackgroundLocationUpdates = false
            return
        }

        if liveSharingEnabled {
            startHeartbeatIfNeeded()
            manager.allowsBackgroundLocationUpdates = authorization == .authorizedAlways
            // Always 授權下可在背景更新而不常駐藍色狀態膠囊；When In Use 的顯示仍由系統決定。
            // 隱私透明度由家人頁的「即時圈分享中」文字、最後更新時間與停止按鈕承擔。
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
        } else {
            stopHeartbeat()
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
        }

        if hasFollowCircle || liveSharingEnabled {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    // MARK: - 心跳（只在家庭分享期間運作）

    /// iOS 背景限制下的實際保證：
    /// - 前景：Task 正常排程，保證約每 5 分鐘一筆。
    /// - 背景＋「永遠允許」：標準定位持續運作（allowsBackgroundLocationUpdates、且不自動暫停），
    ///   App 不會被掛起，這個 Task 會繼續醒來，原則上同樣約每 5 分鐘一筆。
    /// - 背景＋「使用 App 期間」：App 進背景就被掛起，心跳停止；家人端 15 分鐘後會如實顯示「沒有回報」。
    /// - 使用者滑掉 App、系統因記憶體回收終止、低電量關機：標準定位停止，心跳停止（同樣如實顯示失聯）；
    ///   顯著位置變更在移動約 500 公尺時會重新喚醒 App 並恢復分享。
    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self else { return }
                self.heartbeatTickIfDue()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lastLiveDeliveryAt = nil
        if heartbeatAwaitingFix {
            finishHeartbeatFix()
        }
    }

    private func heartbeatTickIfDue(now: Date = .now) {
        guard liveSharingEnabled, isAuthorized, !heartbeatAwaitingFix else { return }
        if let lastLiveDeliveryAt, now.timeIntervalSince(lastLiveDeliveryAt) < Self.heartbeatDueInterval {
            return
        }
        // 放開距離門檻後，正在運作的標準定位會在數秒內送來下一筆（多半來自 Wi-Fi／基地台，百米精度不必等 GPS）
        heartbeatAwaitingFix = true
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation() // 已在運作時不會重複啟動；保險起見確保定位沒被停掉
        heartbeatFixTimeout?.cancel()
        heartbeatFixTimeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, self.heartbeatAwaitingFix else { return }
            // 取不到定位就不送心跳：寧可讓家人看到「沒有回報」，也不拿舊座標假裝確認過
            AppLog.data.error("心跳取位逾時，這一輪不回報")
            self.finishHeartbeatFix()
        }
    }

    private func finishHeartbeatFix() {
        heartbeatAwaitingFix = false
        heartbeatFixTimeout?.cancel()
        heartbeatFixTimeout = nil
        manager.distanceFilter = Self.movementDistanceFilter
    }
}
