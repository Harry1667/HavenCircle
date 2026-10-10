import Foundation
import Observation

/// 跨分頁導航：讓任何畫面能切換主分頁、推入動態分頁的二級頁、或打開設定 sheet。
/// 三個一級分頁依序為 動態（首頁）・地圖・家人；
/// 回顧由動態分頁 push，設定是全域 sheet。
@Observable
@MainActor
final class TabRouter {
    // 分頁順序：動態(0)・地圖(1)・家人(2)；DEBUG --start-tab <n> 直接對應這三個值
    nonisolated static let eventsTab = 0
    nonisolated static let mapTab = 1
    nonisolated static let familyTab = 2

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
    /// 通知深連結指定的家人回報（pingId）：家人頁會打開回報中心、捲到該則並短暫高亮，
    /// 處理完（高亮結束或找不到）由回報中心清空。
    var pendingPingID: String?
    /// 動態頁情境卡「新增守護地點」：切到家人頁後由 FamilyHomeView 消耗並開啟新增地點流程。
    var pendingAddPlace = false

    init(selection: Int = TabRouter.eventsTab) {
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
