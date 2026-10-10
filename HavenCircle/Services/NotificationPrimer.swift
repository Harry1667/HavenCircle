import Foundation
import Observation
import UserNotifications

/// 通知權限的「App 內說明」協調者。
///
/// 為什麼存在：系統通知權限框只有一次機會，使用者拒絕後就只能去系統設定開。
/// 因此不在首次啟動就問，而是等使用者做了「需要通知才有意義」的事——加入／建立家庭、
/// 新增守護地點、第一次按「我平安」——先用 App 內的說明講清楚用途，使用者按「開啟通知」
/// 才呼叫系統詢問。按「稍後」不問系統，之後在相同時機最多再提示一次（次數記在 UserDefaults）。
///
/// 已授權或已拒絕時完全不顯示說明（拒絕的補救入口在設定頁與動態頂端的重問列）。
@MainActor
@Observable
final class NotificationPrimer {
    static let shared = NotificationPrimer()

    /// 觸發時機。加入與建立家庭共用 .family（對使用者而言是同一件事：進入家庭）。
    enum Trigger: String, Identifiable {
        case family
        case place
        case firstSafePing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .family: "開啟通知，才收得到家人的消息"
            case .place: "守護地點附近有狀況時通知你"
            case .firstSafePing: "家人回覆時也通知你"
            }
        }
    }

    /// 同一個時機最多顯示幾次（第一次＋稍後後再提示一次）
    nonisolated static let maxPromptsPerTrigger = 2

    /// 目前要顯示說明的時機；AppTabs 以 sheet(item:) 承載
    var presenting: Trigger?

    private init() {}

    /// 自動化截圖／UI 測試用：--skip-notification-prompt 時完全不顯示說明
    nonisolated private static var isSkipped: Bool {
        ProcessInfo.processInfo.arguments.contains("--skip-notification-prompt")
    }

    /// 在使用者完成某個動作後呼叫。條件不符（已授權／已拒絕／已提示滿次數／已有說明顯示中）就什麼都不做。
    /// delay：給前一張 sheet 收合動畫的時間，避免兩張 sheet 互相打斷。
    func request(_ trigger: Trigger, delay: Duration = .milliseconds(700)) {
        guard !Self.isSkipped, presenting == nil else { return }
        guard Self.shownCount(trigger) < Self.maxPromptsPerTrigger else { return }
        Task {
            guard await NotificationScheduler.authorizationStatus() == .notDetermined else { return }
            try? await Task.sleep(for: delay)
            guard presenting == nil else { return }
            Self.recordShown(trigger)
            presenting = trigger
            Analytics.track("notify_primer_shown")
        }
    }

    /// 嵌入式流程（如入圈後激活頁）自己顯示說明時，用這個判斷「還該不該問」。
    static func shouldAsk(_ trigger: Trigger) async -> Bool {
        guard !isSkipped, shownCount(trigger) < maxPromptsPerTrigger else { return false }
        return await NotificationScheduler.authorizationStatus() == .notDetermined
    }

    /// 嵌入式流程顯示了說明之後記一筆（與 request 內部記法相同）
    static func recordShown(_ trigger: Trigger) {
        let key = SettingsKeys.notificationPrimerCount(trigger.rawValue)
        UserDefaults.standard.set(shownCount(trigger) + 1, forKey: key)
    }

    static func shownCount(_ trigger: Trigger) -> Int {
        UserDefaults.standard.integer(forKey: SettingsKeys.notificationPrimerCount(trigger.rawValue))
    }

    /// 使用者按「開啟通知」：此刻才呼叫系統詢問
    func accept() async {
        presenting = nil
        let granted = await NotificationScheduler.requestPermission()
        Analytics.track(granted ? "notify_granted" : "notify_denied")
    }

    /// 使用者按「稍後」或下滑關閉：不問系統
    func later() {
        presenting = nil
        Analytics.track("notify_primer_later")
    }
}
