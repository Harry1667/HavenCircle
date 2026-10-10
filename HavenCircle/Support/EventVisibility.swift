import Foundation

/// 使用者在此裝置選擇略過的相似事件群組。
/// 這是顯示偏好，不會改變官方事件、來源資料或其他家人的畫面。
enum EventVisibility {
    private static let suppressedGroupsKey = "suppressedEventGroups"

    static func isSuppressed(_ event: LocalSafetyEvent) -> Bool {
        suppressedGroups.contains(event.deduplicationGroup)
    }

    static func suppressSimilar(to event: LocalSafetyEvent) {
        var groups = suppressedGroups
        groups.insert(event.deduplicationGroup)
        UserDefaults.standard.set(Array(groups), forKey: suppressedGroupsKey)
        cachedGroups = groups
    }

    /// 效能：列表與地圖每次重繪對每個事件都問一次 isSuppressed，以前每次都讀 UserDefaults 並重建 Set；
    /// 改成記憶體快取，只有 suppressSimilar／reset 兩個寫入點會更新它。
    private static var cachedGroups: Set<String>?

    private static var suppressedGroups: Set<String> {
        if let cachedGroups { return cachedGroups }
        let loaded = Set(UserDefaults.standard.stringArray(forKey: suppressedGroupsKey) ?? [])
        cachedGroups = loaded
        return loaded
    }

    /// 清空略過紀錄（刪除帳號與資料流程用）
    static func reset() {
        UserDefaults.standard.removeObject(forKey: suppressedGroupsKey)
        cachedGroups = nil
    }
}
