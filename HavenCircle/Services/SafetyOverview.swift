import Foundation

/// 安全狀態聚合——安心頁與地圖頁共用的單一事實來源。
///
/// 鐵律：一律以「未過濾」的活動事件計算。圖層開關、未驗證顯示開關都只是
/// 顯示偏好，絕不能影響安全判定——「有危險卻顯示平安」（假性安心）
/// 比任何介面問題都嚴重，這是本型別存在的第一理由。
@MainActor
struct SafetyOverview {
    /// 可信（官方確認／多來源交叉驗證／主流媒體報導）且落在生活圈提醒範圍內，
    /// 是讓狀態變「需要注意」的唯一來源
    let attentionCount: Int
    /// 資料尚未充分驗證（單一非主流來源）——只顯示、不推播的那一層
    let confirmingCount: Int
    /// 可信但離所有生活圈都遠
    let elsewhereCount: Int
    /// 生效中的區域警報
    let regionAlertCount: Int

    var isAllClear: Bool { attentionCount == 0 }

    /// 活動事件的統一定義（仍在發生、未封存、未被抑制）——兩頁都從這裡取，不各自過濾。
    /// 顯示壽命尚未到期的事後新聞不可以把首頁從「平安」誤變成有事件。
    static func activeEvents(_ events: [LocalSafetyEvent]) -> [LocalSafetyEvent] {
        events.filter { $0.isActiveForAwareness && !$0.isArchived && !EventVisibility.isSuppressed($0) }
    }

    static func compute(
        events: [LocalSafetyEvent],
        regionAlerts: [RegionAlert],
        members: [LocalFamilyMember]
    ) -> SafetyOverview {
        let active = activeEvents(events)
        var attention = 0
        var confirming = 0
        var elsewhere = 0
        // 判定門檻必須與提醒中心（EventListView）的分類完全一致，否則會出現
        // 「首頁說平安、提醒中心卻列著需要注意的事件」——那正是本型別要防的假性安心。
        // 主流媒體報導納入 isCredible 後，這裡一併跟進，兩處不可再各自為政。
        for event in active {
            if !event.isCredible {
                confirming += 1
            } else if AlertPolicy.evaluate(event: event, members: members).matches.isEmpty {
                elsewhere += 1
            } else {
                attention += 1
            }
        }
        return SafetyOverview(
            attentionCount: attention,
            confirmingCount: confirming,
            elsewhereCount: elsewhere,
            regionAlertCount: regionAlerts.filter { !$0.isEnded }.count
        )
    }
}
