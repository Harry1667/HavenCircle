import CoreLocation
import Foundation

/// 全台縣市消防局「即時派遣案件」來源：15 個縣市消防局逐案級 119 派遣紀錄。
/// 跟 NFAIncidentProvider（消防署「初(結)報」）互補：消防署只發布站方主動公告的
/// 重大案件，這支才是逐案級、涵蓋多數縣市 119 派遣系統的資料。
///
/// 主要缺口：**車禍**——現行系統（NCDR／消防署初報）完全沒有單獨管道會發布車禍，
/// 這支直接從各縣市 119 派遣系統拿「緊急救護」案類底下的「車禍」子類，補上使用者
/// 最在意但一直漏抓的類別。爬蟲端（`tools/crawler/fetch_city_fire.py`）已在案類白名單
/// 做好過濾：只收「火災」「災害搶救」全部案件，以及「緊急救護」但子類是「車禍」的案件
/// （一般救護涉個資、不收）。
///
/// 座標只到「縣市＋鄉鎮市區」精度（各站派遣系統本身不吐經緯度，僅台南比照官方個資
/// 規範只留到行政區），沿用 NewsEventProvider.locate(county:district:) 同一份查表，
/// 不重複造輪子（跟 NFAIncidentProvider 同一套做法）。
nonisolated struct CityFireIncidentProvider: EventProvider {
    let sourceName = "縣市消防局"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=cityfire")!

    /// 各站派遣紀錄沒有 expires 欄位，比照 NFAIncidentProvider 的固定 TTL 常數做法：
    /// 已結案（返隊／離院／完成）縮短保留時間，進行中的案件保留較長時間可見
    private static let resolvedTTLSeconds: TimeInterval = 2 * 3_600
    private static let ongoingTTLSeconds: TimeInterval = 12 * 3_600

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(CityFireEnvelope.self, from: data)

        return envelope.data.events.compactMap { event -> RawEventReport? in
            // occurredAt 格式跟 NFA/CWA 同一套帶時區位移的 ISO8601，沿用既有共用工具，不重複實作
            guard let occurredAt = NCDRRegionAlertProvider.parseDate(event.occurredAt) else {
                return nil
            }
            let ttl = Self.isResolved(status: event.status) ? Self.resolvedTTLSeconds : Self.ongoingTTLSeconds
            let expiresAt = occurredAt.addingTimeInterval(ttl)
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            // 定位優先序：來源自帶的實際座標 > 行政區中心點推定。
            // 新北市 e點通會給事發點經緯度，精度遠高於「整個行政區的中心點」——
            // 生活圈交集判斷吃的就是這個距離，用 3 公里的推定值會讓隔壁區的火災
            // 也落進 1 公里的警戒圈，反之亦然。有實測座標時就別退而求其次。
            // 沒有縣市/行政區又沒有座標則無法定位，直接略過，不硬塞一個錯誤位置。
            let exactCoordinate: (latitude: Double, longitude: Double)? = {
                guard let lat = event.latitude, let lon = event.longitude else { return nil }
                // 座標為 0 視同缺值（部分政府來源用 0 表示「沒有這筆資料」而非赤道外海）
                guard lat != 0, lon != 0 else { return nil }
                return (lat, lon)
            }()
            guard let coordinate = exactCoordinate
                ?? NewsEventProvider.locate(county: event.county, district: event.district)
                    .map({ (latitude: $0.latitude, longitude: $0.longitude) })
            else {
                return nil
            }

            return RawEventReport(
                title: Self.title(location: event.location, caseType: event.caseType, caseSub: event.caseSub),
                eventType: Self.eventType(caseType: event.caseType, caseSub: event.caseSub),
                approximateLocation: event.location.isEmpty ? "\(event.county)\(event.district)" : event.location,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                // 誠實標示不確定度：來源給了事發點座標就用 300 公尺（門牌級誤差），
                // 否則只有鄉鎮市區精度，比照 NFAIncidentProvider／NewsEventProvider
                // 的「有行政區用 3 公里、只有縣市用 15 公里」慣例
                precisionMeters: exactCoordinate != nil ? 300 : (event.district.isEmpty ? 15_000 : 3_000),
                sourceName: event.sourceName,
                sourceURL: Self.sourceURL(for: event.county),
                isOfficial: true, // 各縣市消防局自己的派遣紀錄，官方第一手來源，可推播
                occurredAt: occurredAt,
                // 傳剩餘時間，不是完整 TTL；否則一筆已發生很久的案件在首次下載時
                // 會被錯誤延長 2/12 小時（同 NFAIncidentProvider 的處理方式）
                ttlSeconds: remaining,
                detail: Self.detail(unit: event.unit, status: event.status),
                stableDeduplicationKey: "cityfire-\(event.sourceId)"
            )
        }
    }

    /// 結案狀態關鍵字：各站用詞不一（返隊／離院／完成／任務完成），比對到任一個
    /// 就視為已結案，縮短保留時間。狀態字串抓不到、或仍在「已到院」「送醫中」「處理中」
    /// 「到達現場」「火已控」等仍有變動可能的狀態時，一律當進行中處理（寧可多留、不要漏報）。
    private static func isResolved(status: String) -> Bool {
        let resolvedKeywords = ["已返隊", "返隊中", "已完成", "任務完成", "已離院"]
        return resolvedKeywords.contains { status.contains($0) }
    }

    /// 案類 → App 事件分類。爬蟲端已把案類收斂到只剩三種（見 fetch_city_fire.py
    /// is_relevant()）：「火災」「災害搶救」「緊急救護」（子類恆為「車禍」），
    /// 對應到 App 現有的三個既有字串，不新造分類。
    static func eventType(caseType: String, caseSub: String) -> String {
        switch caseType {
        case "火災":
            return EventCategory.fire
        case "災害搶救":
            // 溺水、山域事故、動物救援等雜項搶救案件，跟 NFAIncidentProvider 對「山域事故／
            // 職業災害／鬥毆」等抓不到細分類的案件一樣，一律歸公共安全
            return EventCategory.publicSafety
        default:
            // 「緊急救護」／「救護」：爬蟲端只放行子類是「車禍」的案件，其餘一般救護
            // （涉個資）已在 Python 端擋掉，故這裡不必再檢查 caseSub
            return EventCategory.traffic
        }
    }

    /// 標題：把地點與案情組成一眼看懂的短句。火災帶上細項（如「誤(謊)報」「雜草」），
    /// 讓使用者能分辨是真的失火還是誤報；災害搶救直接用子類（如「溺水」）；
    /// 車禍固定文案（子類已在爬蟲端收斂成只有「車禍」）。
    static func title(location: String, caseType: String, caseSub: String) -> String {
        let place = location.isEmpty ? "" : "\(location) "
        switch caseType {
        case "火災":
            let note = caseSub.isEmpty ? "" : "（\(caseSub)）"
            return "\(place)火災\(note)"
        case "災害搶救":
            return "\(place)\(caseSub.isEmpty ? "災害搶救" : caseSub)"
        default:
            return "\(place)車禍"
        }
    }

    /// 詳細描述：用派遣分隊＋案件狀態組一段可讀文字，兩者皆缺才回 nil
    static func detail(unit: String, status: String) -> String? {
        let parts = [
            unit.isEmpty ? nil : "派遣分隊：\(unit)",
            status.isEmpty ? nil : "案件狀態：\(status)",
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 各縣市消防局的公開查詢頁網址，逐一對應 fetch_city_fire.py 的 SOURCES 設定
    /// （型態 C 的 url 本身就是可瀏覽頁面；型態 A／B 沒有公開頁面時退回 API 主機根網址，
    /// 至少讓使用者能查證資料確實來自該縣市系統，不是憑空編一個網址）
    private static let sourceURLByCounty: [String: String] = [
        "台南市": "https://119dts.tncfd.gov.tw",
        "高雄市": "https://119dts.fdkc.gov.tw",
        "雲林縣": "https://119.ylfire.gov.tw",
        "苗栗縣": "https://119mlfire.mlfd.gov.tw",
        "基隆市": "https://klc-dt.klfd.klcg.gov.tw",
        "新竹市": "https://119.hcfd.gov.tw",
        "宜蘭縣": "https://nfa119.e-land.gov.tw",
        "澎湖縣": "http://210.241.42.144:8080",
        "台北市": "https://service119.tfd.gov.tw/service119/citizenCase/caseList",
        "台中市": "https://www.fire.taichung.gov.tw/caselist/index.asp?Parser=99,8,226",
        "桃園市": "https://www.tyfd.gov.tw/cht/index.php?act=caselist",
        "南投縣": "https://www.ntfd.gov.tw/index.php?act=caselist",
        "彰化縣": "https://www.chfd.gov.tw/RealInfo/index.aspx?Parser=99,3,29",
        "嘉義縣": "https://cycfb.cyhg.gov.tw/DisasterPrevent.aspx?n=5F10482409025004&sms=ED4E0CDDC2EA92E6",
        "屏東縣": "https://pteoc.pthg.gov.tw/News119",
    ]

    private static func sourceURL(for county: String) -> String {
        sourceURLByCounty[county] ?? "https://havencircle.looptw.com"
    }
}

private nonisolated struct CityFireEnvelope: Decodable {
    let data: CityFirePayload
}

private nonisolated struct CityFirePayload: Decodable {
    let events: [CityFireRecord]
}

private nonisolated struct CityFireRecord: Decodable {
    let county: String
    let district: String
    let location: String
    let caseType: String
    let caseSub: String
    let occurredAt: String
    let unit: String
    let status: String
    let sourceId: String
    let sourceName: String
    /// 事發點的實際經緯度。目前只有新北市 e點通會提供（其餘縣市的派遣系統
    /// 不吐街道座標），故為選填；缺席時退回行政區中心點推定。
    let latitude: Double?
    let longitude: Double?
}
