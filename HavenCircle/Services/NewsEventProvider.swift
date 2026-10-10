import Foundation
import CoreLocation

/// 媒體報導事件來源：中繼站新聞爬蟲（中央社／自由／ETtoday 的現場事故，
/// 經 LLM 分類與地點抽取）。產品守則：媒體報導未經官方確認，
/// `isOfficial = false` → 單一來源只進「持續確認中」層；多來源合併後可升為
/// 「多來源交叉驗證」。是否通知仍由 AlertPolicy 與使用者的提醒設定決定。
/// 每則事件都帶 sourceName＋sourceURL，詳情頁的「來源」區會如實列出。
nonisolated struct NewsEventProvider: EventProvider {
    let sourceName = "媒體報導"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=news")!

    /// 顯示壽命：發布後 12 小時。新聞的守護價值在即時性，過了半天還掛著只會誤導
    private static let ttlSeconds: TimeInterval = 12 * 3_600

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(NewsEnvelope.self, from: data)

        return envelope.data.events.compactMap { event in
            guard let published = Self.parseDate(event.publishedAt) else { return nil }
            let ttl = published.addingTimeInterval(Self.ttlSeconds).timeIntervalSinceNow
            guard ttl > 0 else { return nil }

            // 定位失敗（縣市缺失、或縣市/行政區都比對不到座標）才會真的丟棄這則事件；
            // 丟棄前一律記 log，方便日後查「事件為何在 App 裡消失」——過去是靜默丟棄，
            // 真實治安事件（例如縣市欄位吐「台中」而非「台中市」）就這樣悄悄不見了。
            guard let anchor = Self.locate(county: event.county, district: event.district) else {
                print("⚠️ NewsEventProvider 丟棄事件：無法定位縣市 '\(event.county ?? "nil")' district '\(event.district ?? "nil")' title=\(event.title)")
                return nil
            }

            let location = [event.county ?? "", event.district ?? "", event.place ?? ""]
                .filter { !$0.isEmpty }
                .joined()
            return RawEventReport(
                // 優先用爬蟲 LLM 產的 10–12 字短摘要（地點＋事件重點）；
                // 舊資料或 LLM 未產出時退回原始新聞標題，永不因缺欄位丟事件
                title: event.summary?.isEmpty == false ? event.summary! : event.title,
                eventType: Self.eventType(for: event.category, title: event.title, detail: event.detail),
                approximateLocation: location,
                latitude: anchor.latitude,
                longitude: anchor.longitude,
                // 座標是行政區推定不是事發點：區級 3 公里、僅縣市級 15 公里，誠實標示不確定度
                precisionMeters: (event.district?.isEmpty == false) ? 3_000 : 15_000,
                sourceName: event.sourceLabel,
                sourceURL: event.sourceURL,
                // 媒體報導不是官方資訊；是否通知由可信度設定與裝置端政策決定。
                isOfficial: false,
                occurredAt: published,
                ttlSeconds: ttl,
                // AI 整理的 1–2 句詳細描述（爬蟲 LLM 產）；沒有就 nil，詳情頁退回其他欄位
                detail: event.detail?.isEmpty == false ? event.detail : nil,
                corroborationCount: max(event.corroboration ?? 1, 1),
                stableDeduplicationKey: "news-\(event.id)",
                isOngoing: event.isOngoing ?? false
            )
        }
    }

    /// 爬蟲分類 → App 的事件類型。
    /// 先用既有的精準分類字串／治安關鍵字判斷落在哪個粗類（跟先前邏輯完全相同，不動，
    /// 避免既有行為回歸），粗類判斷完才用標題＋詳述文字做細分類（對標 Beacon 後補上）——
    /// 細分類抓不到任何關鍵字時，穩穩退回粗類，絕不因為細分類失敗而讓事件消失或分類錯誤。
    static func eventType(for category: String?, title: String = "", detail: String? = nil) -> String {
        let broad = broadCategory(for: category)
        let haystack = title + " " + (detail ?? "")
        return refine(broad, haystack: haystack)
    }

    private static func broadCategory(for category: String?) -> String {
        guard let category, !category.isEmpty else { return EventCategory.disaster }
        if category == "火災" { return EventCategory.fire }
        if category == "交通" { return EventCategory.traffic }
        let publicSafetyKeywords = ["公共安全", "槍", "擊", "襲", "械", "攻擊", "治安", "爆", "持刀", "兇"]
        if publicSafetyKeywords.contains(where: { category.contains($0) }) {
            return EventCategory.publicSafety
        }
        return EventCategory.disaster // 天災、民生
    }

    /// 細分類關鍵字表：依序比對，第一個命中的就用；找不到就維持傳入的粗類不變。
    /// 刻意只在對應的粗類範圍內細分（例：只有 publicSafety 才去猜是槍擊還是持刀），
    /// 不跨粗類細分，避免一則車禍新聞因標題含「爆」字誤判成爆炸。
    private static func refine(_ broad: String, haystack: String) -> String {
        switch broad {
        case EventCategory.publicSafety:
            let rules: [(String, [String])] = [
                (EventCategory.shooting, ["槍擊", "開槍", "掃射", "槍手", "亂槍", "開火", "中彈"]),
                (EventCategory.knifeAttack, ["持刀", "刺傷", "砍傷", "砍人"]),
                (EventCategory.explosion, ["爆炸", "氣爆", "爆裂物"]),
                (EventCategory.disturbance, ["鬥毆", "群毆", "互毆", "大亂鬥", "打群架"]),
                (EventCategory.harassment, ["性騷擾", "性侵", "猥褻"]),
                (EventCategory.suspiciousPerson, ["可疑人物", "可疑男子", "可疑女子", "尾隨"]),
                (EventCategory.animalAttack, ["野生動物攻擊", "犬隻攻擊", "動物咬傷", "熊出沒"]),
            ]
            for (type, keywords) in rules where keywords.contains(where: { haystack.contains($0) }) {
                return type
            }
            return broad
        case EventCategory.disaster:
            let rules: [(String, [String])] = [
                (EventCategory.earthquake, ["地震"]),
                (EventCategory.flood, ["淹水", "積水"]),
                (EventCategory.landslide, ["土石流", "落石", "山崩", "走山"]),
                (EventCategory.powerOutage, ["停電", "斷電", "跳電"]),
                (EventCategory.waterOutage, ["停水", "斷水"]),
                (EventCategory.gasLeak, ["瓦斯外洩", "瓦斯洩漏"]),
                (EventCategory.injuredAnimal, ["受傷動物", "動物受傷", "動物救援"]),
            ]
            for (type, keywords) in rules where keywords.contains(where: { haystack.contains($0) }) {
                return type
            }
            return broad
        case EventCategory.traffic:
            if ["捷運"].contains(where: { haystack.contains($0) }) { return EventCategory.metroIncident }
            if ["火車", "台鐵", "臺鐵", "鐵路"].contains(where: { haystack.contains($0) }) { return EventCategory.trainIncident }
            return broad
        default:
            return broad
        }
    }

    /// 事件錨點：優先用行政區邊界外框中心（縣市名對得上才用，避免同名區誤置）；
    /// 縣市缺失、或縣市對不上行政區資料時，退而求其次只用行政區名比對第一筆結果
    /// （放寬同名風險，換取「能靠 district 補救就別丟事件」）；
    /// 最後才退回縣市代表點。全部落空才回傳 nil，交由呼叫端記 log 後丟棄。
    static func locate(county: String?, district: String?) -> CLLocationCoordinate2D? {
        if let district, !district.isEmpty {
            let candidates = DistrictBoundaries.shared.districts(named: district)
            if let county, !county.isEmpty,
               let match = candidates.first(where: { normalize($0.county) == normalize(county) }),
               let ring = match.rings.first, !ring.isEmpty {
                return ringCenter(ring)
            }
            // 縣市缺失或比對不到同名同縣市的行政區：退一步只認行政區名
            if let fallback = candidates.first, let ring = fallback.rings.first, !ring.isEmpty {
                return ringCenter(ring)
            }
        }
        guard let county, !county.isEmpty else { return nil }
        return countyCenter(for: county)
    }

    private static func ringCenter(_ ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let lats = ring.map(\.latitude)
        let lons = ring.map(\.longitude)
        return CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
    }

    /// 只做「臺→台」置換，**不**在這裡去掉「市/縣」字尾——新竹市／新竹縣、
    /// 嘉義市／嘉義縣字根相同、字尾不同，若在正規化階段就砍掉字尾會讓兩者互相打架，
    /// 缺字尾的容錯改在 `countyCenter(for:)` 查表端做，才不會製造新的誤配。
    static func normalize(_ name: String) -> String {
        name.replacingOccurrences(of: "臺", with: "台")
    }

    /// 依縣市名查代表點座標。容錯：先照原樣查，查不到且輸入缺「市/縣」字尾時
    /// （例如爬蟲吐「台中」而非「台中市」），依序補「市」「縣」再查一次——
    /// 確保「台中」「台中市」「臺中市」都能對到同一座標，不會因缺字尾就整則事件被丟棄。
    static func countyCenter(for rawCounty: String) -> CLLocationCoordinate2D? {
        let key = normalize(rawCounty)
        if let hit = countyCenters[key] { return hit }
        guard !key.hasSuffix("市"), !key.hasSuffix("縣") else { return nil }
        return countyCenters[key + "市"] ?? countyCenters[key + "縣"]
    }

    /// 縣市代表點（政府所在地概略座標）：只在抽不到行政區時使用，
    /// precisionMeters 會標 15 公里讓不確定度可見
    static let countyCenters: [String: CLLocationCoordinate2D] = [
        "台北市": .init(latitude: 25.0375, longitude: 121.5637),
        "新北市": .init(latitude: 25.0124, longitude: 121.4625),
        "桃園市": .init(latitude: 24.9937, longitude: 121.3010),
        "台中市": .init(latitude: 24.1477, longitude: 120.6736),
        "台南市": .init(latitude: 22.9999, longitude: 120.2270),
        "高雄市": .init(latitude: 22.6273, longitude: 120.3014),
        "基隆市": .init(latitude: 25.1276, longitude: 121.7392),
        "新竹市": .init(latitude: 24.8138, longitude: 120.9675),
        "新竹縣": .init(latitude: 24.8387, longitude: 121.0177),
        "苗栗縣": .init(latitude: 24.5602, longitude: 120.8214),
        "彰化縣": .init(latitude: 24.0518, longitude: 120.5161),
        "南投縣": .init(latitude: 23.9609, longitude: 120.9719),
        "雲林縣": .init(latitude: 23.7092, longitude: 120.4313),
        "嘉義市": .init(latitude: 23.4801, longitude: 120.4491),
        "嘉義縣": .init(latitude: 23.4518, longitude: 120.2555),
        "屏東縣": .init(latitude: 22.5519, longitude: 120.5487),
        "宜蘭縣": .init(latitude: 24.7021, longitude: 121.7378),
        "花蓮縣": .init(latitude: 23.9872, longitude: 121.6016),
        "台東縣": .init(latitude: 22.7583, longitude: 121.1444),
        "澎湖縣": .init(latitude: 23.5712, longitude: 119.5793),
        "金門縣": .init(latitude: 24.4321, longitude: 118.3171),
        "連江縣": .init(latitude: 26.1505, longitude: 119.9499),
    ]

    private static func parseDate(_ raw: String) -> Date? {
        // 爬蟲輸出帶時區的 ISO8601（偶有小數秒），兩種格式都試
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}

// MARK: - 中繼站信封解碼

private nonisolated struct NewsEnvelope: Decodable {
    let data: NewsPayload
}

private nonisolated struct NewsPayload: Decodable {
    let events: [NewsEvent]
}

private nonisolated struct NewsEvent: Decodable {
    let id: String
    let title: String
    let publishedAt: String
    let sourceURL: String
    let county: String?
    let district: String?
    let place: String?
    let category: String?
    /// LLM 產的短摘要（10–12 字）。必須是 Optional：舊資料沒有這欄，缺欄硬解會讓整批事件消失
    let summary: String?
    /// LLM 產的詳細描述（1–2 句，地點＋發生什麼＋現況）。同樣 Optional 相容舊資料
    let detail: String?
    /// 爬蟲跨媒體合併後的來源數；舊資料缺欄時視為 1。
    let corroboration: Int?
    /// 新聞模型明確判定是否仍在發生。缺欄的舊資料採保守 false，
    /// 避免只因 12 小時顯示壽命尚未到期就標示「進行中」。
    let isOngoing: Bool?
    /// sourceName 可能是字串（單一來源）或陣列（跨來源合併），寬鬆解碼
    private let sourceName: SourceName?

    private enum CodingKeys: String, CodingKey {
        case id, title, publishedAt, sourceURL, county, district, place, category
        case summary, detail, corroboration, sourceName
        case isOngoing = "is_ongoing"
    }

    var sourceLabel: String {
        switch sourceName {
        case .single(let name): name
        case .multiple(let names): names.joined(separator: "、")
        case nil: "媒體報導"
        }
    }

    private enum SourceName: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                self = .single(name)
            } else {
                self = .multiple(try container.decode([String].self))
            }
        }
    }
}
