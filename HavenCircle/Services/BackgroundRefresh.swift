import Foundation
import BackgroundTasks
import SwiftData
import os

/// 背景刷新：App 不在前景時，請 iOS 週期性喚醒我們跑一次資料管線，
/// 讓 NCDR 新示警能以本地通知送達，而不是等使用者想到才開 App。
///
/// 能力邊界（誠實標示）：BGAppRefreshTask 的喚醒時機由系統決定——
/// earliestBeginDate 只是「不早於」，實際間隔受使用習慣、電量、低耗電模式影響，
/// 常見是幾十分鐘到數小時，因此它是 APNs 喚醒之外的補充刷新路徑，不承諾固定頻率。
enum BackgroundRefresh {
    nonisolated static let taskIdentifier = "com.gomiigo.CamMenuApp.HavenCircle.refresh"

    /// 向系統登記背景任務處理器。必須在 App 啟動完成前呼叫（App.init 內）。
    /// launchHandler 由系統在背景佇列呼叫，所以這裡明確標 nonisolated，
    /// 實際工作再跳回 MainActor（EventPipeline 與 mainContext 都是 MainActor 隔離）。
    nonisolated static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await handle(refreshTask, container: container)
            }
        }
    }

    /// 排下一次背景喚醒。呼叫時機：App 進背景時、以及每次背景任務執行時（讓鏈條延續）。
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 模擬器不支援 BGTaskScheduler（固定丟 unavailable），真機也可能因系統策略拒絕；
            // 記錄即可，不影響前景功能
            AppLog.pipeline.error("背景刷新排程失敗：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask, container: ModelContainer) async {
        schedule() // 先排下一次，確保這次失敗也不會斷鏈

        let work = Task {
            // 位置心跳優先（時間額度有限）：靜止時前景計時器與定位回呼都可能停擺，
            // 這裡是分享中補一筆「仍在此處」的保底路徑，讓家人端的「最後更新」不會一路落後
            await uploadHeartbeatIfSharing(container: container)
            await EventPipeline.refresh(context: container.mainContext)
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        // refresh 內部沒有逐步檢查取消旗標，被 cancel 時仍會跑完當前批次；
        // 這裡以取消狀態回報 success，讓系統據實調整之後給我們的背景額度
        task.setTaskCompleted(success: !work.isCancelled)
        AppLog.pipeline.info("背景刷新完成（cancelled=\(work.isCancelled)）")
    }

    /// 分享中才取一次位置並上傳（沿用 publishLiveLocation：沒移動只更新 updatedAt、不加軌跡點）；
    /// 沒開分享、沒定位授權、取不到位置都安靜略過，不 fabricate 舊座標
    @MainActor
    private static func uploadHeartbeatIfSharing(container: ModelContainer) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
              LocationService.shared.isAuthorized,
              let sync = AppRuntime.familySync else { return }
        guard let location = await LocationService.shared.currentLocation() else {
            AppLog.data.error("背景刷新取不到位置，這一輪不上傳心跳")
            return
        }
        let storedRadius = defaults.integer(forKey: SettingsKeys.liveCircleRadiusMeters)
        let ok = await sync.publishLiveLocation(
            location,
            displayName: defaults.string(forKey: SettingsKeys.profileDisplayName) ?? "",
            radiusMeters: storedRadius > 0 ? storedRadius : 1_000,
            context: container.mainContext
        )
        AppLog.data.info("背景刷新位置心跳：\(ok ? "已上傳" : "未上傳")")
    }
}
