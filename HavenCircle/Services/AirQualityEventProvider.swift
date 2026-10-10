import Foundation

/// 空品惡化 → 災害事件的連鎖來源：警戒圈附近測站 AQI 突破門檻時，
/// 生成一筆官方事件進資料管線，走既有的「影響圈 ∩ 警戒圈 → 警報」判定。
/// 情境：工廠火災的空污飄到你家——火災點本身可能離圈很遠，但空品測站會先反映。
///
/// 防洗版設計：
///   - 門檻預設 AQI ≥ 150（環境部「對所有族群不健康」紅色等級），可由 config/app.json 遠端調整
///   - 測站座標固定 → 去重簽名（類型＋500m 網格）穩定，每小時資料更新只會刷新同一筆事件
///   - 整個來源可用 features.aqiAlerts 遠端開關
nonisolated struct AirQualityEventProvider: EventProvider {
    let sourceName = "環境部空氣品質監測"

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        // RemoteConfig 的快取是主執行緒狀態：只回主執行緒讀兩個值，其餘解碼與轉換都在背景
        let (enabled, threshold) = await MainActor.run {
            (RemoteConfig.feature("aqiAlerts", default: true),
             Int(RemoteConfig.tuning("aqiAlertThreshold", default: 150)))
        }
        guard enabled else { return [] }

        let stations = try await AirQualityService.fetchStations()
        return stations.filter { $0.aqi >= threshold }.map { station in
            RawEventReport(
                title: "空氣品質不良：\(station.name ?? "測站")站 AQI \(station.aqi)（主要污染物 \(station.pollutant)）",
                eventType: EventCategory.disaster,
                approximateLocation: "\(station.county ?? "")\(station.name ?? "")測站周邊",
                latitude: station.latitude,
                longitude: station.longitude,
                // 測站代表半徑：空品是面狀現象，單站讀值大致代表周邊數公里
                precisionMeters: 3_000,
                sourceName: sourceName,
                sourceURL: "https://airtw.moenv.gov.tw/",
                isOfficial: true, // 環境部官方監測資料
                occurredAt: .now,
                ttlSeconds: 3 * 3_600, // 每小時更新；連續超標會持續刷新同一筆
                stableDeduplicationKey: "aqi-\(station.id)"
            )
        }
    }
}
