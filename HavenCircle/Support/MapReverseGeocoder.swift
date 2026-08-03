import Foundation
import CoreLocation
import Contacts

/// MapKit 反向地理編碼結果的最小資料集。
/// 只保留產生行政區標籤需要的文字，避免在 App 狀態中傳遞或保存完整 MapItem。
struct ReverseGeocodedPlace {
    let name: String?
    let fullAddress: String?
    let shortAddress: String?
    let cityName: String?
    let cityWithContext: String?

    /// 行政區比對需要完整地址，但僅在記憶體中短暫使用，不會直接顯示或保存。
    var searchableText: String {
        [fullAddress, shortAddress, cityName, cityWithContext, name]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    /// 對外只顯示縣市／行政區，不回傳門牌等精確位置。
    func approximateLabel(district: String) -> String? {
        let locality = cityName ?? cityWithContext
        let districtName = district == Districts.unspecified ? nil : district
        let parts = [locality, districtName].compactMap(\.self)
        var seen = Set<String>()
        let unique = parts.filter { part in
            !parts.contains(where: { $0 != part && $0.contains(part) }) && seen.insert(part).inserted
        }
        return unique.isEmpty ? nil : unique.joined()
    }
}

enum MapReverseGeocoder {
    /// 用 `CLGeocoder` 反查行政區。
    ///
    /// 這裡刻意不用 MapKit 的 `MKReverseGeocodingRequest`：那個 API 需要 iOS 26，
    /// 而 App 的部署目標是 iOS 17。`CLGeocoder` 從 iOS 15 就有，涵蓋所有支援的系統版本。
    static func lookup(_ location: CLLocation) async -> ReverseGeocodedPlace? {
        let geocoder = CLGeocoder()
        let locale = Locale(identifier: "zh-Hant-TW")
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: locale).first else {
            return nil
        }

        // 台灣的 CLPlacemark 實測分佈（2026-08 以台北／新北／台中座標驗證）：
        //   administrativeArea = 縣市（臺北市、新北市、臺中市）
        //   locality           = 鄉鎮市區（信義區、板橋區、西屯區）← 不是縣市，別搞錯
        //   subLocality        = 里（西村里、黃石里、惠來里）
        // `Districts.all` 存的是鄉鎮市區名，比對靠 searchableText，所以 locality 一定要進得去。
        let city = placemark.administrativeArea ?? placemark.locality
        let cityWithContext = [placemark.administrativeArea, placemark.locality]
            .compactMap(\.self)
            .reduce(into: [String]()) { acc, part in
                if !acc.contains(part) { acc.append(part) }
            }
            .joined()

        // 完整地址優先用系統格式化器；它會帶出門牌，僅供行政區比對用，不對外顯示。
        let fullAddress = placemark.postalAddress.map {
            CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: "")
        }

        // 保底的短地址：即使 postalAddress 缺漏，也要讓區名（locality）進入可比對文字。
        let shortAddress = [placemark.locality, placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap(\.self)
            .joined()

        return ReverseGeocodedPlace(
            name: placemark.name,
            fullAddress: fullAddress,
            shortAddress: shortAddress.isEmpty ? nil : shortAddress,
            cityName: city,
            cityWithContext: cityWithContext.isEmpty ? nil : cityWithContext
        )
    }
}
