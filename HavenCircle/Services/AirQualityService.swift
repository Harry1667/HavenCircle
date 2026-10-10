import Foundation
import SwiftUI

/// 環境部空品測站資料（經 Oracle 中繼站，每小時更新）。
/// 兩種用途：①地圖上的日常環境資訊圖層（全部測站）；
/// ②AQI 突破警報門檻時由 AirQualityEventProvider 轉成災害事件進管線（預設 AQI≥150）。
nonisolated struct AQIStation: Decodable, Identifiable {
    let siteId: String?
    let name: String?
    let county: String?
    let aqi: Int
    let status: String?
    let pollutant: String
    let pm25: Double?
    let latitude: Double
    let longitude: Double
    let publishTime: String?

    var id: String { siteId ?? "\(latitude),\(longitude)" }

    /// AQI 標準色階（環境部定義的六級）
    var color: Color {
        switch aqi {
        case ..<51: .green
        case 51..<101: .yellow
        case 101..<151: .orange
        case 151..<201: .red
        case 201..<301: .purple
        default: Color(red: 0.5, green: 0.1, blue: 0.15) // 褐紅（危害）
        }
    }
}

nonisolated enum AirQualityService {
    private static let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=aqi")!

    @concurrent static func fetchStations() async throws -> [AQIStation] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }
        struct Envelope: Decodable {
            let data: Payload
        }
        struct Payload: Decodable {
            let stations: [AQIStation]
        }
        return try JSONDecoder().decode(Envelope.self, from: data).data.stations
    }
}
