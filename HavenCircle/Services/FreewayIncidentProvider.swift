import Foundation

/// 高速公路局「即時路況事件」來源：國道即時交通事故。
/// 這是車禍這個類別長期以來唯一沒有官方即時管道、只能靠新聞轉述才會出現的缺口——
/// NCDR／消防署／各縣市消防局三支爬蟲都拿不到國道路況，國道本身不歸地方消防局的
/// 派遣系統管，是高速公路局自己的交控中心資料。
///
/// 座標直接來自爬蟲端解析的 WKT 座標（見 `tools/crawler/fetch_freeway.py`
/// parse_position()），不像縣市消防局那樣要靠行政區反查——這是國道交控系統回報的
/// 實際事故點位，精度遠高於「縣市＋鄉鎮市區」。
///
/// 爬蟲端已用 EventType 白名單只保留「1＝交通事故」（壅塞／施工／管制等交通資訊
/// 不算鄰里安全事件），故這裡收到的一律是事故，不需要再判斷事件類型。
nonisolated struct FreewayIncidentProvider: EventProvider {
    let sourceName = "高速公路局"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=freeway")!

    /// 沒有 expires 欄位；國道事故多半在數小時內排除或降級為壅塞事件（改由壅塞類事件
    /// 承接，不在本 provider 的白名單內），固定 TTL 比照 NFAIncidentProvider 的做法，
    /// 但抓短一點——比起火災／車禍現場，國道事故現場清空速度通常較快
    private static let ttlSeconds: TimeInterval = 3 * 3_600

    /// 爬蟲已用白名單過濾過，這裡仍保留一次防線：萬一日後 Python 端白名單放寬
    /// （見該檔註解「日後若要放寬…只需把代碼加進 RELEVANT_EVENT_TYPES」），
    /// App 端不會突然把壅塞、施工事件也當成事故推播出去
    private static let relevantEventType = "1"

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(FreewayEnvelope.self, from: data)

        return envelope.data.events.compactMap { event -> RawEventReport? in
            guard event.eventType == Self.relevantEventType else { return nil }
            // 座標解析失敗（WKT 格式異常）就無法定位，寧可丟棄不硬塞錯誤座標
            guard let latitude = event.latitude, let longitude = event.longitude else { return nil }
            // occurredAt 格式跟 NFA/CWA 同一套帶時區位移的 ISO8601，沿用既有共用工具
            guard let occurredAt = NCDRRegionAlertProvider.parseDate(event.occurredAt) else { return nil }
            let expiresAt = occurredAt.addingTimeInterval(Self.ttlSeconds)
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            return RawEventReport(
                title: Self.title(road: event.road, direction: event.direction, km: event.km, section: event.section),
                eventType: EventCategory.traffic,
                approximateLocation: Self.title(road: event.road, direction: event.direction, km: event.km, section: event.section),
                latitude: latitude,
                longitude: longitude,
                // 國道交控系統回報的是實際事故點位（非行政區概略位置），精度給 500 公尺，
                // 比縣市消防局那組「行政區級 3000 公尺」高一個檔次
                precisionMeters: 500,
                sourceName: sourceName,
                sourceURL: "https://www.freeway.gov.tw/",
                isOfficial: true, // 高速公路局官方交控中心通報，可推播
                occurredAt: occurredAt,
                // 傳剩餘時間，不是完整 TTL；避免已發生一段時間的事故在首次下載時被錯誤延長
                ttlSeconds: remaining,
                detail: event.description.isEmpty ? nil : event.description,
                stableDeduplicationKey: "freeway-\(event.eventId)"
            )
        }
    }

    /// 標題：路名＋方向直接相連（國道慣用讀法「國道一號北向」），里程與路段用括號
    /// 補充定位資訊，讓使用者一眼看懂大概位置，不必自己查地圖換算里程樁
    static func title(road: String, direction: String, km: String, section: String) -> String {
        let head = "\(road)\(direction)"
        let kmPart = km.isEmpty ? "" : " \(km)"
        let sectionPart = section.isEmpty ? "" : "（\(section.replacingOccurrences(of: "-", with: "－"))）"
        return "\(head)\(kmPart)交通事故\(sectionPart)"
    }
}

private nonisolated struct FreewayEnvelope: Decodable {
    let data: FreewayPayload
}

private nonisolated struct FreewayPayload: Decodable {
    let events: [FreewayRecord]
}

private nonisolated struct FreewayRecord: Decodable {
    let eventId: String
    let road: String
    let direction: String
    let km: String
    let section: String
    let description: String
    let latitude: Double?
    let longitude: Double?
    let occurredAt: String
    let eventType: String
}
