import Foundation

/// NCDR 點狀事件來源：從同一份中繼站資料裡，挑出「附精確座標」的示警
/// （CAP circle 欄位，目前主要是消防署火災通報）轉成地圖上的點狀事件。
/// 這是點狀事件管線的第一個真實來源，取代原本的 mock provider。
nonisolated struct NCDRPointEventProvider: EventProvider {
    let sourceName = "NCDR 民生示警平台"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php")!

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(PointEnvelope.self, from: data)

        return envelope.data.events.compactMap { event in
            // 只收有精確座標的示警；沒座標的走 RegionAlert（行政區塗層）那條路
            guard let circle = Self.parseCircle(event.circle) else { return nil }
            guard let expires = NCDRRegionAlertProvider.parseDate(event.expires) else { return nil }
            let ttl = expires.timeIntervalSinceNow
            guard ttl > 0 else { return nil }
            let occurredAt = NCDRRegionAlertProvider.parseDate(event.effective) ?? .now

            return RawEventReport(
                title: event.headline ?? event.event ?? "示警",
                eventType: Self.eventType(for: event.category),
                approximateLocation: event.areaDesc ?? "",
                latitude: circle.lat,
                longitude: circle.lon,
                precisionMeters: circle.radiusMeters,
                sourceName: event.senderName ?? sourceName,
                sourceURL: "https://alerts.ncdr.nat.gov.tw/",
                isOfficial: true, // NCDR 全是政府機關發布
                occurredAt: occurredAt,
                ttlSeconds: ttl,
                // 官方事件的「AI 詳細描述」直接用政府原始文字：description 是事件說明、
                // instruction 是應變建議，兩者合成一段完整可讀的官方描述
                detail: Self.composeDetail(description: event.description, instruction: event.instruction)
            )
        }
    }

    /// 合成官方詳細描述：事件說明（description）＋應變建議（instruction），去重與去空白。
    /// 兩者都空回 nil，讓詳情頁退回其他欄位而不是顯示空段落。
    static func composeDetail(description: String?, instruction: String?) -> String? {
        let parts = [description, instruction]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// CAP circle 格式："緯度,經度 半徑"（半徑單位公里），例 "24.0247,120.4281 0.5"
    static func parseCircle(_ raw: String?) -> (lat: Double, lon: Double, radiusMeters: Int)? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let coords = parts[0].split(separator: ",")
        guard coords.count == 2,
              let lat = Double(coords[0]), let lon = Double(coords[1]),
              let radiusKm = Double(parts[1]) else { return nil }
        // 座標合理性檢查（台灣範圍附近），擋掉來源塞錯欄位的情況
        guard (20...27).contains(lat), (117...123).contains(lon) else { return nil }
        return (lat, lon, max(100, Int(radiusKm * 1000)))
    }

    /// NCDR 類別對應到 App 的事件分類（MVP 四類）。
    /// 交通與公共安全類補齊對應：之前只認 3 種字串，交通類點狀事件會被誤歸「天災」
    /// 而套用天災的推播規則；歸對類後，交通類依產品預設不推播、僅在 App 內顯示。
    static func eventType(for category: String?) -> String {
        switch category {
        case "火災":
            EventCategory.fire
        case "疏散避難", "防空", "輻射災害", "傳染病", "急門診通報", "縣市災情通報":
            EventCategory.publicSafety
        case "鐵路事故":
            EventCategory.trainIncident
        case "捷運營運":
            EventCategory.metroIncident
        case "地下道積淹水":
            EventCategory.flood
        case "道路封閉", "高速公路路況", "聯絡道淹水封閉", "強風管制路段":
            EventCategory.traffic
        default:
            EventCategory.disaster
        }
    }
}

private nonisolated struct PointEnvelope: Decodable {
    let data: PointPayload
}

private nonisolated struct PointPayload: Decodable {
    let events: [PointCapEvent]
}

private nonisolated struct PointCapEvent: Decodable {
    let event: String?
    let effective: String?
    let expires: String?
    let senderName: String?
    let headline: String?
    let areaDesc: String?
    let circle: String?
    let category: String?
    /// 官方事件說明與應變建議（合成 detail 用；舊資料可能缺，故 Optional）
    let description: String?
    let instruction: String?
}
