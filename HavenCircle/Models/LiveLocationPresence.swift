import Foundation

/// 即時圈的「在不在線」判定與文案（純函式，不碰 SwiftData／Firestore／定位，方便測試與 Preview）。
///
/// 兩個時間必須分開看，不能混成一個 updatedAt：
/// - 最後回報時間（lastReportedAt，Firestore 的 `updatedAt`）：手機最後一次寫入「我還在、位置是這裡」。
///   分享中的手機即使沒移動，也會每 [heartbeatInterval] 寫一次心跳，所以它代表「手機還活著」。
/// - 開始停留時間（stationarySince，Firestore 的 `stationarySince`）：座標最後一次移動超過
///   [stationaryRadiusMeters] 的時間，代表「人在這裡待多久了」。
///
/// 15 分鐘過時規則只看「最後回報時間」：人坐著不動不是失聯，手機沒電／關機／斷網才是。
enum LiveLocationPresence {
    /// 超過這個時間沒有回報，就視為失聯：舊位置不參與警報判斷，也不能冒充現在位置
    static let staleInterval: TimeInterval = 15 * 60
    /// 分享中的手機至少每 5 分鐘回報一次（沒移動也回報），留 3 倍餘裕給 iOS 排程延遲與網路重試
    static let heartbeatInterval: TimeInterval = 5 * 60
    /// 移動多少公尺以內算「同一地點」：與 LocationService 的 distanceFilter（100 公尺）一致
    static let stationaryRadiusMeters: Double = 100
    /// 停留滿這麼久才顯示「在同一地點 N 分鐘」，避免剛到就顯示「在同一地點 0 分鐘」
    static let stationaryDisplayThreshold: TimeInterval = 5 * 60

    /// 手機是否仍在回報（＝即時圈是否可參與警報判斷）
    static func isReporting(lastReportedAt: Date?, now: Date = .now) -> Bool {
        guard let lastReportedAt else { return false }
        return lastReportedAt > now.addingTimeInterval(-staleInterval)
    }

    /// 家人列表「位置：」那一行的文字（純函式）。
    /// 「沒分享」與「分享了但過期」是兩回事，不能都說成過期：
    /// - 本人沒開分享：「未分享給家人」（中性，不是警告）；本人有開分享才依最後上傳時間判斷
    /// - 家人沒有即時圈：「未分享位置」
    /// - 有分享、15 分鐘內有回報：「分享中・剛剛更新」；超過 15 分鐘：「超過 15 分鐘未更新」
    static func memberLocationLine(
        isCurrentUser: Bool,
        sharingEnabled: Bool,
        hasLiveCircle: Bool,
        lastReportedAt: Date?,
        statusDetail: String? = nil,
        now: Date = .now
    ) -> String {
        if isCurrentUser {
            guard sharingEnabled else { return "位置：未分享給家人" }
        } else {
            guard hasLiveCircle else { return "位置：未分享位置" }
        }
        // 有完整狀態句（在家・從 08:30 起／移動中／停留…／N 分鐘沒有回報）就直接用，
        // 本人手機自己的位置不會「失聯」，所以本人過期時仍走下面的舊文案
        if let statusDetail, !statusDetail.isEmpty,
           !isCurrentUser || isReporting(lastReportedAt: lastReportedAt, now: now) {
            return "位置：\(statusDetail)"
        }
        guard isReporting(lastReportedAt: lastReportedAt, now: now), let lastReportedAt else {
            return "位置：超過 15 分鐘未更新"
        }
        // 分享中一併顯示最後更新時間（AGENTS 紅線：live circle 一律顯示最後更新）
        return "位置：分享中・\(agoText(max(0, now.timeIntervalSince(lastReportedAt))))更新"
    }

    /// 這次寫入時的「開始停留時間」。
    /// - movedMeters：與上次寫入座標的距離；nil 代表沒有上次紀錄（第一次分享或 App 重啟後查不到）
    /// - previousStationarySince：上次寫入的開始停留時間；舊版文件沒有這欄時為 nil
    /// 沒移動（< 100 公尺）就沿用舊值；移動了、或沒有可比較的舊值，就從現在重新起算。
    static func stationarySince(
        previousStationarySince: Date?,
        movedMeters: Double?,
        now: Date = .now
    ) -> Date {
        guard let movedMeters, movedMeters < stationaryRadiusMeters,
              let previousStationarySince, previousStationarySince <= now else {
            return now
        }
        return previousStationarySince
    }

    /// 給家人看的狀態句（純文字，不靠顏色）。
    /// - 失聯：「20 分鐘沒有回報（可能沒電、關機或沒有網路）」
    /// - 在守護地點內：「在家・從 08:30 起・2 分鐘前確認」
    /// - 剛移動過（停留不滿 5 分鐘）：「移動中・3 分鐘前」
    /// - 停留：「停留 大安區・40 分鐘・5 分鐘前確認」（沒有行政區時「在同一地點 40 分鐘・…」）
    /// - 舊版文件（沒有 stationarySince）：「3 分鐘前更新位置」
    /// 所有分支都帶上最後回報時間（AGENTS 紅線：即時圈一律顯示最後更新）。
    static func statusText(
        lastReportedAt: Date?,
        stationarySince: Date?,
        placeName: String? = nil,
        placeSince: Date? = nil,
        district: String? = nil,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        guard let lastReportedAt else { return "尚未取得位置" }
        let sinceReport = max(0, now.timeIntervalSince(lastReportedAt))
        guard isReporting(lastReportedAt: lastReportedAt, now: now) else {
            return "\(durationText(sinceReport))沒有回報（可能沒電、關機或沒有網路）"
        }
        if let placeName, !placeName.isEmpty {
            if let since = placeSince ?? stationarySince {
                return "在\(placeName)・從 \(clockText(since, timeZone: timeZone)) 起・\(agoText(sinceReport))確認"
            }
            return "在\(placeName)・\(agoText(sinceReport))確認"
        }
        if let stationarySince {
            let stayed = max(0, now.timeIntervalSince(stationarySince))
            if stayed >= stationaryDisplayThreshold {
                if let district, !district.isEmpty, district != Districts.unspecified {
                    return "停留 \(district)・\(durationText(stayed))・\(agoText(sinceReport))確認"
                }
                return "在同一地點 \(durationText(stayed))・\(agoText(sinceReport))確認"
            }
            return "移動中・\(agoText(sinceReport))"
        }
        return "\(agoText(sinceReport))更新位置"
    }

    /// 「08:30」：固定 24 小時制、不跟著裝置語言變 AM/PM
    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 「剛剛」／「5 分鐘前」：自己組字串，不用系統相對時間格式器（會跟著裝置語言變英文）
    static func agoText(_ interval: TimeInterval) -> String {
        interval < 60 ? "剛剛" : "\(durationText(interval))前"
    }

    /// 「40 分鐘」／「2 小時 5 分鐘」／「1 天 3 小時」；不足 1 分鐘以 1 分鐘計
    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int(interval / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小時" : "\(days) 天"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小時 \(minutes) 分鐘" : "\(hours) 小時"
        }
        return "\(minutes) 分鐘"
    }
}

#if DEBUG
import SwiftUI

/// 判定邏輯的固定案例（以固定的 now 計算，結果可重現）；Preview 與自我檢查共用。
enum LiveLocationPresenceSamples {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    struct Case: Identifiable {
        let id: String
        let lastReportedAt: Date?
        let stationarySince: Date?
        let expectReporting: Bool
    }

    static let cases: [Case] = [
        // 靜止 40 分鐘＋心跳 5 分鐘前 → 不過時
        Case(id: "靜止＋心跳", lastReportedAt: now.addingTimeInterval(-5 * 60),
             stationarySince: now.addingTimeInterval(-40 * 60), expectReporting: true),
        // 16 分鐘沒有心跳 → 過時（不論停留多久）
        Case(id: "無心跳 16 分鐘", lastReportedAt: now.addingTimeInterval(-16 * 60),
             stationarySince: now.addingTimeInterval(-60 * 60), expectReporting: false),
        // 剛移動、2 分鐘前回報
        Case(id: "剛移動", lastReportedAt: now.addingTimeInterval(-2 * 60),
             stationarySince: now.addingTimeInterval(-2 * 60), expectReporting: true),
        // 舊版文件沒有 stationarySince
        Case(id: "舊資料", lastReportedAt: now.addingTimeInterval(-3 * 60),
             stationarySince: nil, expectReporting: true),
        Case(id: "尚未取得", lastReportedAt: nil, stationarySince: nil, expectReporting: false)
    ]
}

#Preview("即時圈回報狀態") {
    List(LiveLocationPresenceSamples.cases) { sample in
        let reporting = LiveLocationPresence.isReporting(
            lastReportedAt: sample.lastReportedAt, now: LiveLocationPresenceSamples.now
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(sample.id).font(.headline)
            Label(
                LiveLocationPresence.statusText(
                    lastReportedAt: sample.lastReportedAt,
                    stationarySince: sample.stationarySince,
                    now: LiveLocationPresenceSamples.now
                ),
                systemImage: reporting ? "location.fill" : "clock.badge.exclamationmark"
            )
            Text(reporting == sample.expectReporting ? "判定正確" : "判定錯誤")
                .font(.caption)
                .foregroundStyle(reporting == sample.expectReporting ? .green : .red)
        }
    }
}
#endif
