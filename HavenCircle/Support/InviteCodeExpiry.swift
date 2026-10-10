import Foundation

/// 邀請碼效期判斷（純函式，無任何 UI／網路相依，方便獨立驗證）。
/// 家人頁與邀請頁共用同一份規則：過期或剩不到 24 小時就必須換新碼，
/// 過期狀態絕不顯示可分享的舊碼。
enum InviteCodeExpiry: Equatable {
    /// 舊碼沒有 expiresAt 欄位（或尚未讀到）：後端視為長期有效，不強制換。
    case noExpiry
    /// 剩 24 小時以上；daysLeft 為「無條件捨去」的整天數（保守，不多報）
    case valid(expiresAt: Date, daysLeft: Int)
    /// 剩不到 24 小時：仍可用，但應該自動換新碼
    case expiringSoon(expiresAt: Date, hoursLeft: Int)
    /// 已過期：不得顯示或分享
    case expired(expiresAt: Date)

    /// 需要換新碼的門檻：剩不到 24 小時
    static let renewThreshold: TimeInterval = 24 * 60 * 60

    static func evaluate(expiresAt: Date?, now: Date = Date()) -> InviteCodeExpiry {
        guard let expiresAt else { return .noExpiry }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired(expiresAt: expiresAt) }
        if remaining < renewThreshold {
            // 至少顯示 1 小時，避免出現「剩 0 小時」
            return .expiringSoon(expiresAt: expiresAt, hoursLeft: max(1, Int(remaining / 3600)))
        }
        return .valid(expiresAt: expiresAt, daysLeft: Int(remaining / 86400))
    }

    /// 是否該自動換新碼（已過期或剩不到 24 小時）
    var needsRenewal: Bool {
        switch self {
        case .expired, .expiringSoon: return true
        case .noExpiry, .valid: return false
        }
    }

    /// 是否可以拿來分享（過期的碼加入會失敗，絕不顯示）
    var isShareable: Bool {
        if case .expired = self { return false }
        return true
    }

    /// 顯示文字：含年份與剩餘天數，例如「有效到 2026/10/17（剩 6 天）」
    var displayText: String {
        switch self {
        case .noExpiry:
            return "長期有效（建議重新產生）"
        case .valid(let expiresAt, let daysLeft):
            return "有效到 \(Self.format(expiresAt))（剩 \(daysLeft) 天）"
        case .expiringSoon(let expiresAt, let hoursLeft):
            return "即將到期：\(Self.format(expiresAt))（剩約 \(hoursLeft) 小時）"
        case .expired(let expiresAt):
            return "已於 \(Self.format(expiresAt)) 過期"
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.string(from: date)
    }
}
