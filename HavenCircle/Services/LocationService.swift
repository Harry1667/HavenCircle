import Foundation
import CoreLocation
import Observation
import os // Swift 6.2 MemberImportVisibility：用 os.Logger 插值的檔案必須自行 import

/// 定位服務有三種清楚分離的用途：
/// (1) 地圖藍點與一次性取位；(2) 本機即時圈更新；(3) 使用者主動開啟的家庭位置分享。
/// 家庭分享開啟時（像「尋找」App 一樣）持續背景定位：
/// - 移動中：100 公尺精度、distanceFilter 50 公尺；「永遠」授權時允許背景更新並顯示系統的藍色定位指示。
/// - 偵測到靜止（約 4 分鐘位移 < 50 公尺，見 MotionDetector）：維持 100 公尺精度、不設距離門檻（持續有回呼喚醒 App），回呼端節流成 5 分鐘一筆心跳；
///   離開錨點 100 公尺後恢復移動參數。
/// - 顯著位置變更保留作為 App 被系統終止後的喚醒路徑；關閉分享後立即停止標準定位。
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
    /// 拜訪偵測（CLVisit）回呼：到達／離開某處
    var onVisit: ((VisitTransition) -> Void)?
    /// 守護地點進出回呼（地理圍欄）
    var onRegionTransition: ((RegionTransition) -> Void)?
    /// 目前所在的守護地點（地理圍欄判斷；持久化，背景重啟後仍有效）
    private(set) var currentPlace: CurrentPlace? = LocationService.loadCurrentPlace()
    private var hasFollowCircle = false
    private var liveSharingEnabled = false
    /// 心跳排程：分享期間每 15 秒醒來檢查一次是否該補一筆「仍在此處」（到期才真的取位，平常不耗電；15 秒是為了上傳失敗時能快速重試）
    private var heartbeatTask: Task<Void, Never>?
    /// 心跳取位等待中：distanceFilter 暫時放開，下一筆定位到手就恢復
    private var heartbeatAwaitingFix = false
    private var heartbeatFixTimeout: Task<Void, Never>?
    /// 最後一次送給 onLiveLocationUpdate 的時間（移動回報與心跳都算）
    private var lastLiveDeliveryAt: Date?
    /// 靜止偵測：移動中／靜止切換定位參數（見 LocationProfile）
    private var motionDetector = MotionDetector()
    var motionState: MotionState { motionDetector.state }
    /// 距離上次送出超過這麼久就補心跳；比 5 分鐘短 30 秒，吸收每分鐘檢查與取位耗時的誤差
    private static let heartbeatDueInterval: TimeInterval = LiveLocationPresence.heartbeatInterval - 30

    override private init() {
        super.init()
        applyProfile()
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
        lastFollowDispatchLocation = nil // 圈剛建立或變更：下一筆定位要能立刻校正圈心
        reconcileMonitoring()
    }

    /// 即時圈分享開關。標準定位只在分享期間運作；分享狀態與停止入口由 App 內持續清楚顯示。
    func syncLiveLocationSharing(isEnabled: Bool) {
        liveSharingEnabled = isEnabled
        reconcileMonitoring()
        // 關閉分享就移除所有守護地點圍欄；開啟時由呼叫端用最新的守護地點清單呼叫 syncGeofences
        if !isEnabled { syncGeofences([]) }
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
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
                guard let self, let waiting = self.oneShot else { return }
                self.oneShot = nil
                waiting.resume(returning: nil)
            }
        }
    }

    /// 等使用者做完定位授權決定（按了允許／不允許，或本來就已決定）；回傳是否已授權。
    /// 最多等 60 秒（要留時間給使用者讀系統對話框）。授權通過後的取位逾時另計。
    func waitForAuthorizationDecision(timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while authorization == .notDetermined, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isAuthorized
    }

    /// 家庭位置確實送達雲端後由 FamilySyncService 呼叫，心跳計時以此為準：
    /// 只有「真的上傳成功」才算一次回報，上傳失敗時下一個檢查週期就會重試。
    func noteLiveLocationDelivered() {
        lastLiveDeliveryAt = .now
    }

    /// 回到前景時立刻檢查心跳是否到期（背景被掛起期間 Task 不會跑，回來要補一筆）
    func kickHeartbeat() {
        heartbeatTickIfDue()
    }

    // MARK: - 守護地點地理圍欄

    private static let currentPlaceKey = "hc.currentPlace"
    private static let geofenceNamesKey = "hc.geofenceNames"

    private static func loadCurrentPlace() -> CurrentPlace? {
        guard let data = UserDefaults.standard.data(forKey: currentPlaceKey) else { return nil }
        return try? JSONDecoder().decode(CurrentPlace.self, from: data)
    }

    private func setCurrentPlace(_ place: CurrentPlace?) {
        currentPlace = place
        if let place, let data = try? JSONEncoder().encode(place) {
            UserDefaults.standard.set(data, forKey: Self.currentPlaceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.currentPlaceKey)
        }
    }

    /// regionID → 地點名稱（App 被系統終止後由圍欄喚醒時，不必讀資料庫也知道叫什麼）
    private func storedGeofenceNames() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: Self.geofenceNamesKey) as? [String: String]) ?? [:]
    }

    /// 對守護地點（固定圈）建立地理圍欄；iOS 最多 20 個，超過取離目前位置最近的 20 個。
    /// 只在使用者開啟位置分享且已授權時運作；否則清掉所有圍欄。
    /// 呼叫時機：App 啟動、回前景／進背景、分享開關變更（守護地點增刪改後下一次切換就會同步）。
    func syncGeofences(_ places: [GeofencePlace]) {
        let existing = manager.monitoredRegions.compactMap { $0 as? CLCircularRegion }
            .filter { $0.identifier.hasPrefix(GeofencePlanner.identifierPrefix) }
        guard liveSharingEnabled, isAuthorized,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            for region in existing { manager.stopMonitoring(for: region) }
            UserDefaults.standard.removeObject(forKey: Self.geofenceNamesKey)
            if currentPlace != nil { setCurrentPlace(nil) }
            return
        }
        let center = manager.location.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        let desired = GeofencePlanner.select(places, near: center)
        let desiredIDs = Set(desired.map { GeofencePlanner.identifier(forCircleKey: $0.id) })

        for region in existing where !desiredIDs.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let radius = min(GeofencePlanner.regionRadiusMeters, manager.maximumRegionMonitoringDistance)
        var names: [String: String] = [:]
        for place in desired {
            let identifier = GeofencePlanner.identifier(forCircleKey: place.id)
            names[identifier] = place.name
            if let current = existing.first(where: { $0.identifier == identifier }),
               abs(current.center.latitude - place.latitude) < 0.000_01,
               abs(current.center.longitude - place.longitude) < 0.000_01,
               current.radius == radius {
                continue // 沒變就不重建，避免重設系統的進出判斷
            }
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: radius,
                identifier: identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            manager.requestState(for: region) // 立刻問「現在在不在裡面」，補上已經在家的情況
        }
        UserDefaults.standard.set(names, forKey: Self.geofenceNamesKey)
        if let current = currentPlace, !desiredIDs.contains(current.id) {
            setCurrentPlace(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(GeofencePlanner.identifierPrefix) else { return }
        let name = storedGeofenceNames()[region.identifier] ?? "守護地點"
        let now = Date.now
        setCurrentPlace(CurrentPlace(id: region.identifier, name: name, since: now))
        onRegionTransition?(RegionTransition(kind: .arrive, placeID: region.identifier, placeName: name, date: now))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier.hasPrefix(GeofencePlanner.identifierPrefix) else { return }
        let name = storedGeofenceNames()[region.identifier] ?? currentPlace?.name ?? "守護地點"
        if currentPlace?.id == region.identifier { setCurrentPlace(nil) }
        onRegionTransition?(RegionTransition(kind: .depart, placeID: region.identifier, placeName: name, date: .now))
    }

    /// 啟動圍欄後 requestState 的回答：只校正「目前在哪」，不當成進出事件（避免重啟 App 就誤報到達）
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(GeofencePlanner.identifierPrefix) else { return }
        switch state {
        case .inside:
            if currentPlace?.id != region.identifier {
                let name = storedGeofenceNames()[region.identifier] ?? "守護地點"
                setCurrentPlace(CurrentPlace(id: region.identifier, name: name, since: .now))
            }
        case .outside:
            if currentPlace?.id == region.identifier { setCurrentPlace(nil) }
        case .unknown:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        AppLog.data.error("地理圍欄監控失敗：\(error.localizedDescription)")
    }

    // MARK: - 拜訪偵測

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let transition = VisitMapper.transition(
            arrival: visit.arrivalDate,
            departure: visit.departureDate,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude
        )
        guard liveSharingEnabled else { return }
        onVisit?(transition)
    }

    // MARK: - CLLocationManagerDelegate（manager 建立在主執行緒，回呼也在主執行緒）

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        reconcileMonitoring()
    }

    /// 回呼端節流：靜止模式 distanceFilter 為 none，系統可能每秒回呼一次。
    /// 這個回呼在主執行緒，每筆都派 Task、做動作偵測、更新 @Observable，會讓打字與捲動延遲。
    /// 做法：靜止時同一個 10 秒窗內只處理第一筆（動作偵測要連續 2 筆才確認移動，延後 10 秒無妨），
    /// 其餘在第一行直接 return。一次性取位／心跳取位等待中不節流。
    private var lastProcessedFixAt: Date?
    private static let stationaryMinProcessInterval: TimeInterval = 10
    /// 跟隨圈上次派發的位置：位移不到 300 公尺（FollowCircleService 的門檻）就不派 Task、不查 SwiftData
    private var lastFollowDispatchLocation: CLLocation?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let arrivedAt = Date.now
        if liveSharingEnabled, motionDetector.state == .stationary, oneShot == nil, !heartbeatAwaitingFix,
           let lastProcessedFixAt,
           arrivedAt.timeIntervalSince(lastProcessedFixAt) < Self.stationaryMinProcessInterval {
            return
        }
        lastProcessedFixAt = arrivedAt
        oneShotTimeout?.cancel()
        oneShotTimeout = nil
        // 一次性取位與跟隨圈共用這個回呼：兩邊都要餵到
        oneShot?.resume(returning: latest)
        oneShot = nil
        if lastFollowDispatchLocation.map({ latest.distance(from: $0) >= 300 }) ?? true {
            lastFollowDispatchLocation = latest
            onFollowLocationUpdate?(latest)
        }
        let wasHeartbeatFix = heartbeatAwaitingFix
        if heartbeatAwaitingFix {
            finishHeartbeatFix()
        }
        // 注意：不在這裡記 lastLiveDeliveryAt——收到定位不等於上傳成功，
        // 由 noteLiveLocationDelivered() 在實際送達後才記，上傳失敗的話心跳會盡快補送。
        if liveSharingEnabled {
            let previousState = motionDetector.state
            motionDetector.ingest(LocationSample(latest))
            if motionDetector.state != previousState {
                AppLog.data.info("定位模式切換：\(self.motionDetector.state.rawValue)")
                applyProfile()
            }
            // 靜止模式 distanceFilter 為 none，回呼可能很密：每筆都餵給動作偵測（才能即時發現開始移動），
            // 但上傳節流成心跳頻率（5 分鐘一筆，位置沒變只刷新 updatedAt）。
            // 心跳取位、剛切回移動、上次上傳失敗（lastLiveDeliveryAt 沒更新）都不受節流限制。
            if motionDetector.state == .stationary, !wasHeartbeatFix,
               let lastLiveDeliveryAt,
               Date.now.timeIntervalSince(lastLiveDeliveryAt) < Self.heartbeatDueInterval {
                return
            }
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
            manager.stopMonitoringVisits()
            manager.allowsBackgroundLocationUpdates = false
            return
        }

        if liveSharingEnabled {
            startHeartbeatIfNeeded()
            // 「永遠」授權才能在背景持續更新。不顯示時間旁的藍色膠囊（使用者反映一直掛著很干擾，
            // Life360 也不顯示）；「正在分享」改由 App 內「分享中・X 分鐘前更新」與
            // iOS 狀態列的定位箭頭呈現，仍符合 AGENTS「看得見正在運作」。
            // 注意：「使用期間」授權下 iOS 一律強制顯示藍色膠囊，所以背景更新只在「永遠」時開。
            let always = authorization == .authorizedAlways
            manager.allowsBackgroundLocationUpdates = always
            manager.showsBackgroundLocationIndicator = false
            applyProfile()
            manager.startUpdatingLocation()
        } else {
            stopHeartbeat()
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
            motionDetector.reset()
            applyProfile()
        }

        // 顯著位置變更＋拜訪偵測：App 被系統終止（或使用者滑掉）後，系統仍會在人移動／到達時
        // 重新啟動 App 並送來定位，是「App 關掉也要回報」的保底路徑。只在分享開啟時啟動拜訪偵測。
        if hasFollowCircle || liveSharingEnabled {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
        if liveSharingEnabled {
            manager.startMonitoringVisits()
        } else {
            manager.stopMonitoringVisits()
            if currentPlace != nil { setCurrentPlace(nil) }
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
                    try await Task.sleep(for: .seconds(15))
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
        // 靜止省電模式的精度是 1 公里，取到的定位可能粗到被上傳端拒收；心跳這一筆暫時改回 100 公尺精度
        manager.desiredAccuracy = LocationProfile.moving.desiredAccuracy
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation() // 已在運作時不會重複啟動；保險起見確保定位沒被停掉
        manager.requestLocation() // 人沒動時 distanceFilter 放開也不一定有回呼，主動要一筆保證有新定位
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
        applyProfile()
    }

    /// 依目前移動／靜止狀態套用定位參數
    private func applyProfile() {
        let profile = LocationProfile.profile(for: motionDetector.state)
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
    }
}
