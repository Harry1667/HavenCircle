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
    let isSharing: Bool

    /// 過時判斷只看「最後回報時間」：人沒移動但心跳正常，仍是新鮮的
    var isFresh: Bool {
        isSharing && LiveLocationPresence.isReporting(lastReportedAt: updatedAt)
    }

    var freshnessText: String {
        guard isSharing else { return "已停止分享" }
        return LiveLocationPresence.statusText(lastReportedAt: updatedAt, stationarySince: stationarySince)
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
        static let isSharing = "isSharing"
    }
}
