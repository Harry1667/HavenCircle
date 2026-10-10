import Foundation

/// 家庭圈（Firestore locations 子集合）中每台裝置最新的一筆位置快照。
/// 「即時」代表位置變動後近即時同步，沒移動時也有每 5 分鐘的心跳；
/// 畫面必須同時顯示最後回報時間，不能暗示秒級連續追蹤。
struct FamilyLiveLocation: Identifiable, Equatable {
    let id: String
    let participantID: String
    let displayName: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let district: String
    /// 最後回報時間：位置變動或心跳（沒移動也每 5 分鐘一次）都會刷新
    let updatedAt: Date
    /// 開始停留時間：座標最後一次移動超過 100 公尺的時間；舊版文件沒有此欄為 nil
    var stationarySince: Date? = nil
    /// 目前所在的守護地點名稱與進入時間（不在任何守護地點內為 nil）
    var placeName: String? = nil
    var placeSince: Date? = nil
    let isSharing: Bool

    /// 複製一份並換成讀取端解析後的顯示名稱（雲端沒名字時補「家人 N」，不會寫回雲端）
    func withDisplayName(_ name: String) -> FamilyLiveLocation {
        FamilyLiveLocation(
            id: id, participantID: participantID, displayName: name,
            latitude: latitude, longitude: longitude, radiusMeters: radiusMeters,
            district: district, updatedAt: updatedAt, stationarySince: stationarySince,
            placeName: placeName, placeSince: placeSince, isSharing: isSharing
        )
    }

    /// 過時判斷只看「最後回報時間」：人沒移動但心跳正常，仍是新鮮的
    var isFresh: Bool {
        isSharing && LiveLocationPresence.isReporting(lastReportedAt: updatedAt)
    }

    var freshnessText: String {
        guard isSharing else { return "已停止分享" }
        return LiveLocationPresence.statusText(
            lastReportedAt: updatedAt,
            stationarySince: stationarySince,
            placeName: placeName,
            placeSince: placeSince,
            district: district
        )
    }

    enum Field {
        static let recordType = "FamilyLiveLocation"
        static let participantID = "participantID"
        static let displayName = "displayName"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let radiusMeters = "radiusMeters"
        static let district = "district"
        static let updatedAt = "updatedAt"
        static let stationarySince = "stationarySince"
        static let placeName = "placeName"
        static let placeSince = "placeSince"
        static let isSharing = "isSharing"
    }
}
