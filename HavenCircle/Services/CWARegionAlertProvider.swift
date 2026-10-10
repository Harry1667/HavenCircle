import Foundation

/// 中央氣象署（CWA）地震報告 → 區域警報。
///
/// 背景（2026-07-26 使用者實測踩到的真實漏報）：新北雙溪規模 5.6 地震（震度 3 級、
/// 北中部多縣市有感）當晚完全沒有推播。追查後發現三層問題：
/// 1. Mac Mini 爬蟲（fetch_cwa.py）其實每 5 分鐘都在抓 CWA 地震開放資料、也確實存進了
///    Oracle，但 App 端從沒有任何程式碼讀過 `dataset=cwa`——資料躺在那裡完全沒用上。
/// 2. 原本以為地震會走的 NCDRRegionAlertProvider（`dataset` 預設值，讀 NCDR 民生示警平台）
///    整份歷史 log 從未出現過「地震」——NCDR 那個來源根本不處理地震。
/// 3. 新聞爬蟲雖然正確抓到＋分類了這次地震，但地震是「大範圍、多縣市有感」的區域現象，
///    硬套用點狀事件的「距離警戒圈多近」模型天生就會漏接——事件定位只能落在新聞提到的
///    單一地名（例如「新北市雙溪區」），使用者人在台北市、桃園市一樣有感卻因為距離超標
///    被擋掉。地震應該跟颱風、海嘯一樣走「你的行政區在不在受影響清單」的區域比對模型。
///
/// 這支 Provider 補上第 1、3 點：把已經在抓的官方地震資料接進 App，且用區域比對（縣市展開
/// 成轄下所有區）取代距離比對，不會因為震央定位在別的城市就漏掉真正有感的使用者。
nonisolated struct CWARegionAlertProvider: RegionAlertProvider {
    let sourceName = "中央氣象署"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=cwa")!

    /// 地震報告只在意「剛發生的」——localQuakes 回傳的是近期歷史清單（過去數週都可能還在），
    /// 沒有這個窗口每次輪詢都會把舊地震當成新警報重新冒出來。只在第一次寫入時把關；
    /// 已存在的紀錄仍會被 EventPipeline 正常更新／到期，不受這裡影響。
    private static let recencyWindow: TimeInterval = 3 * 3_600
    /// 顯示壽命：地震本身是瞬時事件，但使用者仍需要一段時間確認家人平安、查看餘震資訊
    private static let ttlSeconds: TimeInterval = 12 * 3_600

    @concurrent func fetchAlerts() async throws -> [RawRegionAlert] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        let envelope = try JSONDecoder().decode(CWAEnvelope.self, from: data)
        let datasets = envelope.data.datasets

        // 兩個資料集可能重複報同一場地震（significantQuakes 是「顯著」門檻更高的子集），
        // 用 EarthquakeNo 去重，保留任一筆即可（欄位形狀相同）。
        var byNumber: [Int: CWAEarthquake] = [:]
        for quake in (datasets.localQuakes?.earthquake ?? []) + (datasets.significantQuakes?.earthquake ?? []) {
            byNumber[quake.earthquakeNo] = quake
        }

        return byNumber.values.compactMap { quake -> RawRegionAlert? in
            guard let originTime = Self.parseDate(quake.earthquakeInfo?.originTime) else { return nil }
            // 只收最近幾小時內發生的——避免歷史地震每輪都被當成新警報重新冒出
            guard Date.now.timeIntervalSince(originTime) <= Self.recencyWindow else { return nil }

            let shakingAreas = quake.intensity?.shakingArea ?? []
            guard !shakingAreas.isEmpty else { return nil }

            // 官方震度資料只到縣市粒度（例「宜蘭縣地區」），生活圈只存區名不含縣市——
            // 展開成每個受影響縣市轄下的「全部」區，寧可多蓋不漏接（跟既有同名區取捨一致）。
            let counties = Set(shakingAreas.map(\.countyName))
            let affectedDistricts = counties
                .flatMap { DistrictBoundaries.shared.townNames(inCounty: $0) }
            guard !affectedDistricts.isEmpty else { return nil }

            let maxIntensityRank = shakingAreas.map { Self.intensityRank($0.areaIntensity) }.max() ?? 0
            let magnitude = quake.earthquakeInfo?.earthquakeMagnitude?.magnitudeValue
            let magnitudeText = magnitude.map { String(format: "規模 %.1f", $0) } ?? ""
            let title = quake.reportContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? quake.reportContent!
                : "\(magnitudeText)地震（\(quake.earthquakeInfo?.epicenter?.location ?? "位置未提供")）"

            return RawRegionAlert(
                alertKey: "cwa-quake-\(quake.earthquakeNo)",
                title: title,
                kind: EventCategory.earthquake,
                affectedDistricts: affectedDistricts,
                severity: Self.severityText(rank: maxIntensityRank),
                guidance: "請確認自身與家人安全；室內應遠離窗戶與可能倒塌的傢俱，留意餘震與後續官方資訊。",
                sourceName: sourceName,
                sourceURL: quake.web ?? "https://www.cwa.gov.tw/V8/C/E/index.html",
                ttlSeconds: Self.ttlSeconds
            )
        }
    }

    /// 中央氣象署震度等級（10 級制：1、2、3、4、5弱、5強、6弱、6強、7）轉成可排序的整數，
    /// 供多站取最大值時比較用。字串解析失敗（未知格式）保守回 0，不會誤判成高震度。
    static func intensityRank(_ raw: String) -> Int {
        let normalized = raw.replacingOccurrences(of: "級", with: "")
        switch normalized {
        case "1": return 1
        case "2": return 2
        case "3": return 3
        case "4": return 4
        case "5弱": return 5
        case "5強": return 6
        case "6弱": return 7
        case "6強": return 8
        case "7": return 9
        default: return 0
        }
    }

    /// 震度轉嚴重度文案，沿用 RegionAlert 既有的四級封閉字串（危急/警戒/注意/留意），
    /// 顏色與地圖塗層才能跟颱風/海嘯等既有區域警報同一套視覺語言。
    static func severityText(rank: Int) -> String {
        switch rank {
        case 7...: "危急" // 6弱以上：強震，明顯搖晃甚至損壞風險
        case 4...: "警戒" // 4-5強：多數人有感、部分物品掉落
        case 3: "注意"    // 3級：有感但影響有限（這次雙溪地震的等級）
        default: "留意"
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - CWA JSON 解碼結構（對應 fetch_cwa.py 產出、經 ingest.php dataset=cwa 存放的形狀）

private nonisolated struct CWAEnvelope: Decodable {
    let data: CWAPayload
}

private nonisolated struct CWAPayload: Decodable {
    let datasets: CWADatasets
}

private nonisolated struct CWADatasets: Decodable {
    let localQuakes: CWAQuakeDataset?
    let significantQuakes: CWAQuakeDataset?
}

private nonisolated struct CWAQuakeDataset: Decodable {
    let earthquake: [CWAEarthquake]

    enum CodingKeys: String, CodingKey {
        case earthquake = "Earthquake"
    }
}

private nonisolated struct CWAEarthquake: Decodable {
    let earthquakeNo: Int
    let reportContent: String?
    let web: String?
    let earthquakeInfo: CWAEarthquakeInfo?
    let intensity: CWAIntensity?

    enum CodingKeys: String, CodingKey {
        case earthquakeNo = "EarthquakeNo"
        case reportContent = "ReportContent"
        case web = "Web"
        case earthquakeInfo = "EarthquakeInfo"
        case intensity = "Intensity"
    }
}

private nonisolated struct CWAEarthquakeInfo: Decodable {
    let originTime: String?
    let epicenter: CWAEpicenter?
    let earthquakeMagnitude: CWAMagnitude?

    enum CodingKeys: String, CodingKey {
        case originTime = "OriginTime"
        case epicenter = "Epicenter"
        case earthquakeMagnitude = "EarthquakeMagnitude"
    }
}

private nonisolated struct CWAEpicenter: Decodable {
    let location: String?

    enum CodingKeys: String, CodingKey {
        case location = "Location"
    }
}

private nonisolated struct CWAMagnitude: Decodable {
    let magnitudeValue: Double?

    enum CodingKeys: String, CodingKey {
        case magnitudeValue = "MagnitudeValue"
    }
}

private nonisolated struct CWAIntensity: Decodable {
    let shakingArea: [CWAShakingArea]?

    enum CodingKeys: String, CodingKey {
        case shakingArea = "ShakingArea"
    }
}

private nonisolated struct CWAShakingArea: Decodable {
    let countyName: String
    let areaIntensity: String

    enum CodingKeys: String, CodingKey {
        case countyName = "CountyName"
        case areaIntensity = "AreaIntensity"
    }
}
