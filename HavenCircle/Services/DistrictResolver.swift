import Foundation
import CoreLocation

/// 位置上傳用的「所在行政區」解析（家人列表的「停留 西屯區」與區域型警報都靠它）。
///
/// 以前行政區取自本機跟隨圈的 district 欄位，而它在新裝置上預設「未指定」，
/// 上傳後又被雲端回讀寫回本機，形成自我強化——iPhone 一直上傳「未指定」。
/// 現在直接由座標解析：
/// 1. 先用內嵌的鄉鎮市區邊界做點面內判（離線、即時、不耗網路）；
/// 2. 查不到才退回 CLGeocoder 反向地理編碼（失敗 60 秒內不重試，避免被系統限流）；
/// 3. 結果快取，每移動超過 500 公尺才重查；都拿不到就回 nil（呼叫端不寫任何字樣）。
@MainActor
final class DistrictResolver {
    static let shared = DistrictResolver()

    /// 移動超過這個距離才重查
    static let requeryDistance: CLLocationDistance = 500
    private static let geocoderRetryInterval: TimeInterval = 60

    private var cachedLocation: CLLocation?
    private var cachedDistrict: String?
    private var lastGeocoderFailureAt: Date?

    func resolve(_ location: CLLocation) async -> String? {
        if let cachedLocation, let cachedDistrict,
           location.distance(from: cachedLocation) < Self.requeryDistance {
            return cachedDistrict
        }
        if let town = DistrictBoundaries.shared.district(at: location.coordinate)?.town, !town.isEmpty {
            remember(town, at: location)
            return town
        }
        if let lastGeocoderFailureAt,
           Date.now.timeIntervalSince(lastGeocoderFailureAt) < Self.geocoderRetryInterval {
            return nil
        }
        if let place = await MapReverseGeocoder.lookup(location) {
            let guessed = Districts.guess(from: place.searchableText)
            if guessed != Districts.unspecified {
                remember(guessed, at: location)
                return guessed
            }
        }
        lastGeocoderFailureAt = .now
        return nil
    }

    private func remember(_ district: String, at location: CLLocation) {
        cachedLocation = location
        cachedDistrict = district
    }
}
