import CoreLocation
import Foundation

/// 內政部消防署「全國災情訊息」來源：全國救災救護指揮中心即時發布的初(結)報，
/// 涵蓋火災／車禍／地震／瓦斯洩漏／山域事故等，是官方第一手資料（非新聞轉述）。
/// 跟 NCDRPointEventProvider 互補：NCDR 只給示警級/CAP 格式事件，這支給消防署
/// 自己的秒級動態；跟 NewsEventProvider 互補：這支是官方確認、可推播，新聞是持續
/// 確認中、永不推播。
///
/// 對標競品「Beacon 守護臺灣」後補上的缺口——使用者實測發現我方漏抓治安/意外事件
/// （例：台中 MP5 槍擊案），根因是新聞爬蟲關鍵字缺口＋缺乏官方治安/意外來源；
/// 這支從「消防署自己的派遣紀錄」直接拿資料，不依賴新聞媒體有沒有報導、
/// 也不依賴關鍵字猜得準不準。
///
/// 座標只到「縣市＋鄉鎮市區」精度（消防署公告本身不含經緯度），沿用
/// NewsEventProvider.locate(county:district:) 同一份查表，不重複造輪子。
nonisolated struct NFAIncidentProvider: EventProvider {
    let sourceName = "內政部消防署"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=nfa")!

    /// 已解除／已撲滅的案件不必再提醒，TTL 縮短；進行中的案件保留較長時間可見
    private static let resolvedTTLSeconds: TimeInterval = 2 * 3_600
    private static let ongoingTTLSeconds: TimeInterval = 12 * 3_600

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(NFAEnvelope.self, from: data)

        return envelope.data.events.compactMap { event -> RawEventReport? in
            guard let occurredAt = ISO8601DateFormatter.nfaFlexible.date(from: event.occurredAt) else {
                return nil
            }
            let ttl = event.isResolved ? Self.resolvedTTLSeconds : Self.ongoingTTLSeconds
            let expiresAt = occurredAt.addingTimeInterval(ttl)
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            // 沒有縣市/行政區就無法定位到地圖上，這種列（例如公告類無地點的特殊公告，
            // 已在 Python 端的 TITLE_RE 格式檢查濾掉大部分）直接略過，不硬塞一個錯誤座標
            guard let coordinate = NewsEventProvider.locate(county: event.county, district: event.district) else {
                return nil
            }

            let location = [event.county, event.district]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined()

            return RawEventReport(
                title: event.title,
                eventType: Self.eventType(for: event.category),
                approximateLocation: location.isEmpty ? event.detail : location,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                // 只有鄉鎮市區精度（沒有街道座標），比照 NewsEventProvider 的
                // 「有行政區用 3 公里、只有縣市用 15 公里」慣例
                precisionMeters: (event.district?.isEmpty == false) ? 3_000 : 15_000,
                sourceName: sourceName,
                sourceURL: event.sourceURL ?? "https://www.nfa.gov.tw/pro/index.php?code=list&ids=114",
                isOfficial: true, // 消防署自己的派遣紀錄，官方第一手來源，可推播
                occurredAt: occurredAt,
                // 傳剩餘時間，不是完整 TTL；否則一筆已發生很久的事件在首次下載時
                // 會被錯誤延長 2/12 小時。
                ttlSeconds: remaining,
                detail: event.detail,
                stableDeduplicationKey: event.id.map { "nfa-\($0)" }
            )
        }
    }

    /// 消防署分類 → App 的事件分類。消防署的分類顆粒度比我們細很多
    /// （住宅火災/機關火災/汽車火災/餐廳火災/雞舍火災…都算火災），用 contains 判斷
    /// 比窮舉每個組合字串更耐用（消防署可能出現新的細分類名稱）。
    /// 對標 Beacon 後：能明確判斷細分類的直接給細分類圖示，判斷不出來才退回四大類。
    static func eventType(for category: String) -> String {
        if category.contains("火災") {
            return EventCategory.fire
        }
        if category.contains("地震") { return EventCategory.earthquake }
        if category.contains("淹水") { return EventCategory.flood }
        if category.contains("土石流") || category.contains("坍塌") { return EventCategory.landslide }
        if category.contains("瓦斯") { return EventCategory.gasLeak }
        if category.contains("停水") { return EventCategory.waterOutage }
        if category.contains("停電") { return EventCategory.powerOutage }
        if category.contains("捷運") { return EventCategory.metroIncident }
        if category.contains("火車") || category.contains("鐵路") { return EventCategory.trainIncident }
        if category.contains("交通") || category.contains("車禍") {
            return EventCategory.traffic
        }
        if category.contains("海嘯") || category.contains("颱風") {
            return EventCategory.disaster
        }
        if category.contains("動物") { return EventCategory.animalAttack }
        if category.contains("緊急救護") || category.contains("救護") {
            return EventCategory.emergencyMedical
        }
        // 山域事故、職業災害、鬥毆等其餘案類，判斷不出更細的分類，一律歸公共安全
        return EventCategory.publicSafety
    }
}

private nonisolated struct NFAEnvelope: Decodable {
    let data: NFAPayload
}

private nonisolated struct NFAPayload: Decodable {
    let events: [NFARecord]
}

private nonisolated struct NFARecord: Decodable {
    let id: String?
    let title: String
    let category: String
    let detail: String
    let county: String?
    let district: String?
    let unit: String
    let occurredAt: String
    let isResolved: Bool
    let statusTag: String
    let sourceURL: String?
}

private nonisolated extension ISO8601DateFormatter {
    /// Python 端輸出帶時區偏移的 ISO8601（例：2026-07-24T00:00:00+08:00），
    /// 標準 ISO8601DateFormatter 預設不含小數秒也能解析，這裡明確指定選項避免依賴預設值。
    static let nfaFlexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
