import Foundation
import SwiftData
import SwiftUI

/// 可信度狀態（對外顯示一律用文字說明，不能只靠顏色）
nonisolated enum TrustStatus {
    static let officialConfirmed = "官方已確認"
    static let crossVerified = "多來源交叉驗證"
    /// 一線主流媒體單一報導即可升級到的等級（見 MainstreamMedia）。
    /// 文案刻意標明「媒體」而非任何暗示官方的字眼——大型新聞台獨家不等於不可信，
    /// 但絕不能讓使用者誤以為是官方資訊（App Store 審查與產品誠信的雙重底線）。
    static let mediaConfirmed = "主流媒體報導"
    static let confirming = "持續確認中"
}

/// 主流媒體分級：決定「單一報導是否足以讓使用者看見」的判斷依據。
/// 一線媒體（中央社、公視、TVBS、聯合報、自由時報、ETtoday）採即時查證後即播出，
/// 單一報導即可視為足夠可信，跳過交叉驗證直接升級為「主流媒體報導」；
/// 二線媒體（Newtalk新聞、記者新聞網）不在名單內，維持原規則——仍需多來源交叉驗證才升級。
nonisolated enum MainstreamMedia {
    static let tier1: [String] = ["中央社", "公視", "TVBS", "聯合報", "自由時報", "ETtoday"]

    /// 比對方式：用「包含比對」而非精確相等。爬蟲跨來源合併同一事件時，
    /// sourceName 會把多家媒體以「、」串接（見 tools/crawler/fetch_news.py 的
    /// merge_duplicate，例如「中央社、TVBS」），用 contains 才能在合併字串中
    /// 命中任一家一線媒體；精確相等在合併情境下永遠比不中。
    static func isTier1(_ sourceName: String) -> Bool {
        tier1.contains { sourceName.contains($0) }
    }
}

/// 事件生命週期狀態機：進行中 → 已解除（解除時發送解除通知，關閉使用者的焦慮迴圈）
enum EventStatus: String {
    case active = "進行中"
    case resolved = "已解除"
}

@Model
final class LocalSafetyEvent {
    @Attribute(.unique) var eventKey: String
    var title: String
    var eventType: String
    var occurredAt: Date
    var updatedAt: Date
    /// 概略位置描述；對外不顯示精確地址
    var approximateLocation: String
    var latitude: Double
    var longitude: Double
    /// 位置精準度（公尺）
    var precisionMeters: Int
    var sourceName: String
    var sourceURL: String
    var trustStatus: String
    var severity: String
    /// AI 整理的詳細描述（1–2 句：地點＋發生什麼＋現況）。
    /// 新聞事件走爬蟲 LLM 產出、官方事件用政府原始 description＋instruction；
    /// 缺這欄的舊資料為 nil，詳情頁會退回既有欄位組合。給預設值以支援輕量遷移
    var detail: String? = nil
    /// 相似事件去重群組
    var deduplicationGroup: String
    var expiresAt: Date
    /// 生命週期狀態（EventStatus 的 rawValue；新欄位給預設值以支援輕量遷移）
    var status: String = EventStatus.active.rawValue
    /// 演練模式產生的模擬事件
    var isDrill: Bool = false
    /// 來源明確表示仍在發生或剛發生、需要即時反應。
    /// 這與顯示到期時間不同：新聞壽命尚未到期不代表事故仍在進行。
    var isOngoing: Bool = true
    /// 是否已成功推播過（避免同一事件重複打擾；生活圈事後新增時補通知也靠它判斷）
    var hasNotified: Bool = false
    /// 已封存（過期後保留供歷史回顧，不再出現在提醒中心）
    var isArchived: Bool = false
    /// 同一事件的多篇報導合併後，被合併的那幾筆指向代表事件的 eventKey（代表事件本身為 nil）。
    /// 被合併者同時標記 isArchived，所有清單／地圖／警報判斷自然排除；保留為墓碑而非刪除，
    /// 是為了來源仍在回報同一篇報導時不會被當成新事件重建、重推播。
    var mergedIntoKey: String? = nil
    /// 代表事件涵蓋的報導則數（含自己；每次刷新由合併流程重算）
    var reportCount: Int = 1

    init(
        eventKey: String,
        title: String,
        eventType: String,
        occurredAt: Date = .now,
        updatedAt: Date = .now,
        approximateLocation: String,
        latitude: Double,
        longitude: Double,
        precisionMeters: Int,
        sourceName: String,
        sourceURL: String,
        trustStatus: String,
        severity: String,
        deduplicationGroup: String,
        expiresAt: Date,
        detail: String? = nil,
        status: EventStatus = .active,
        isDrill: Bool = false,
        isOngoing: Bool = true
    ) {
        self.eventKey = eventKey
        self.title = title
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.updatedAt = updatedAt
        self.approximateLocation = approximateLocation
        self.latitude = latitude
        self.longitude = longitude
        self.precisionMeters = precisionMeters
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.trustStatus = trustStatus
        self.severity = severity
        self.deduplicationGroup = deduplicationGroup
        self.expiresAt = expiresAt
        self.detail = detail
        self.status = status.rawValue
        self.isDrill = isDrill
        self.isOngoing = isOngoing
    }
}

extension LocalSafetyEvent {
    /// 只有官方來源或多來源交叉驗證的事件才允許推播（產品守則）。
    /// ⚠️ 語意固定為「官方確認」，別的地方（合規、Widget、每日摘要、地圖統計）靠這個
    /// 名字判斷「真的是官方／多來源」，不要為了讓主流媒體報導也算進來而改這個屬性——
    /// 想表達「可信到該讓使用者看見」請改用下面的 isCredible。
    var isOfficiallyConfirmed: Bool {
        trustStatus == TrustStatus.officialConfirmed || trustStatus == TrustStatus.crossVerified
    }

    /// 「可信到該讓使用者看見」的三級：官方確認／多來源交叉驗證／主流媒體單一報導。
    /// 語意上比 isOfficiallyConfirmed 寬——用於決定使用者在提醒中心是否該看到這則事件，
    /// 不代表這則事件就是官方資訊（媒體報導在其他文案仍會誠實標示「非官方確認」）。
    var isCredible: Bool {
        trustStatus == TrustStatus.officialConfirmed
            || trustStatus == TrustStatus.crossVerified
            || trustStatus == TrustStatus.mediaConfirmed
    }

    var isExpired: Bool { expiresAt <= .now }

    var isResolved: Bool { status == EventStatus.resolved.rawValue }

    /// 提醒中心「已結束」分類：使用者標記解除、或已過期
    var isEnded: Bool { isResolved || isExpired }

    /// 可作為即時安全狀態、地圖與通知判斷的事件；不能僅以 TTL 推論「還在發生」。
    var isActiveForAwareness: Bool { !isEnded && isOngoing && !isArchived }

    /// 多則報導的標示文字（N>1 才有）；接在來源或狀態文字後面
    var reportCountText: String? { reportCount > 1 ? "\(reportCount) 則報導" : nil }

    /// 對使用者顯示的狀態文字（不能只靠顏色）
    var statusText: String {
        if isEnded { return EventStatus.resolved.rawValue }
        return isOngoing ? EventStatus.active.rawValue : "非即時資訊"
    }

    /// 標記為已解除（呼叫端負責存檔與發送解除通知）
    func resolve() {
        status = EventStatus.resolved.rawValue
        updatedAt = .now
    }

    /// 事件「類型色」：只回答這個 eventType 本質上多危險（見 EventCategory.typeColor 的判斷規則），
    /// 與是否已結束（isEnded／statusText 那套「狀態色」）完全獨立——已結束的火災類型色仍是紅，
    /// 呼叫端要不要因為已結束而改用灰階，是畫面自己的決定，不該混進這個屬性裡。
    var typeColor: Color { EventCategory.typeColor(for: eventType) }
}
