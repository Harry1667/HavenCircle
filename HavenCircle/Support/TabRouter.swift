import Foundation
import Observation

/// 跨分頁導航：讓任何畫面能切換主分頁、推入動態分頁的二級頁、或打開設定 sheet。
/// 方案 B「家人優先」：三個一級分頁依序為 家人（首頁）・動態・地圖；
/// 回顧由動態分頁 push，設定是全域 sheet。
@Observable
@MainActor
final class TabRouter {
    nonisolated static let familyTab = 0
    nonisolated static let eventsTab = 1
    nonisolated static let mapTab = 2      // 保留原 tag 值：DEBUG --start-tab 2 仍是地圖

    /// 動態分頁的二級頁（回顧由此 push）
    enum EventsDestination: Hashable {
        case history
    }

    var selection: Int
    /// 動態分頁的導航堆疊
    var eventsPath: [EventsDestination] = []
    /// 設定改為全域 sheet（掛在 AppTabs 層，任何頁面都能打開）
    var showSettings = false
    /// 通知深連結指定的事件：動態分頁出現後直接打開這一則的詳情，
    /// 使用者不必在清單裡自己找剛剛通知講的是哪一件
    var pendingEventKey: String?
    /// B2：QR／havencircle://join 深連結帶進來的邀請碼，交給家人頁消耗（開加入流程並預填）；
    /// 用過就清空，避免重新進到家人頁時被舊值誤觸發。
    var pendingJoinCode: String?

    init(selection: Int = TabRouter.familyTab) {
        self.selection = selection
    }

    /// 跳到動態分頁；可選擇推入二級頁（deep link 與狀態卡共用）
    func openEvents(_ destination: EventsDestination? = nil) {
        selection = Self.eventsTab
        if let destination, eventsPath.last != destination {
            eventsPath.append(destination)
        }
    }
}
