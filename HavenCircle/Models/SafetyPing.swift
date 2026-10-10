import Foundation

/// 安否狀態（安否回報的核心）。
/// 「尚未脫離危險」介於平安與求助之間：人還安全但事件未結束（例：火警已疏散、仍在現場外等待），
/// 讓家人知道「已有回音、但要持續關注」，而不是二選一的平安／求助。
enum SafetyStatus: String, CaseIterable {
    case safe = "我平安"
    case inDanger = "尚未脫離危險"
    case needHelp = "需要協助"
    /// 平安確認請求：家人圈出事時，其他人長按通知發起「請回報平安」。
    /// 不是自我狀態——回報頁的按鈕列只放前三個（見 selfReportable）
    case pleaseReport = "請回報平安"

    /// 自我回報用的狀態（回報頁按鈕列）；pleaseReport 是發給別人的請求，不在此列
    static let selfReportable: [SafetyStatus] = [.safe, .inDanger, .needHelp]

    var systemImage: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .inDanger: "exclamationmark.triangle.fill"
        case .needHelp: "exclamationmark.circle.fill"
        case .pleaseReport: "questionmark.circle.fill"
        }
    }
}

/// 一則安否回報。透過 Firestore（families/{familyId}/pings 子集合）在家人之間同步。
/// 這是「事件 → 我 → 家人 → 回報」雙向閉環的回報端。
struct SafetyPing: Identifiable {
    let id: String
    let senderName: String
    /// 回報者 uid（雲端文件本來就有）。名字空白時讀取端靠它排「家人 N」，也用來認出自己的回報
    var senderUid: String = ""
    let status: SafetyStatus
    let note: String
    let createdAt: Date
    /// 已讀這則回報的家人名稱（已讀回條）
    let readBy: [String]
    /// 回報者「自願附上」的當下位置（nil＝沒附）。這不是追蹤——
    /// 位置只在按下回報的那一刻取得一次，由回報者自己決定要不要附
    let latitude: Double?
    let longitude: Double?
    /// 位置的可讀描述（回報端反向地理編碼一次，例「台北市信義區」），家人不用看座標
    let placeName: String?
    /// 「收到 ❤️」確認：uid → 名字（名字可能為空字串，顯示端以 resolvedName 補「家人 N」）。
    /// 家人收到平安／求助回報後按「收到」寫入，回報者即可知道有人看到了；舊文件沒有這欄＝空
    var ack: [String: String] = [:]

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// CloudKit 記錄類型與欄位名（集中定義，避免字串散落）
    enum Field {
        static let recordType = "SafetyPing"
        static let senderName = "senderName"
        static let status = "status"
        static let note = "note"
        static let createdAt = "createdAt"
        static let readBy = "readBy"
        static let ack = "ack"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let placeName = "placeName"
    }
}
