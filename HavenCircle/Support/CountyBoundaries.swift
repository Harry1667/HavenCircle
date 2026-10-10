import Foundation
import CoreLocation

/// 台灣 22 縣市外框（內嵌資源 TaiwanCounties.json，由 tools/geo/build_counties.py 從鄉鎮區界合併產生）。
/// 用途：地圖「顯示範圍」的金色邊界高光，以及「座標 → 縣市」的快取判斷。縣市名一律用「台」（不用「臺」）。
final class CountyBoundaries {
    static let shared = CountyBoundaries()

    /// 縣市名 → 外框（MultiPolygon 拆成多個 ring，頭尾已相接）
    private let outlines: [String: [[CLLocationCoordinate2D]]]
    /// 座標 → 縣市快取（座標取小數 3 位≈110m；事件座標多半是行政區中心，命中率高）
    private var countyCache: [CoordKey: String?] = [:]

    private struct CoordKey: Hashable {
        let lat: Int
        let lon: Int
        init(_ c: CLLocationCoordinate2D) {
            lat = Int((c.latitude * 1_000).rounded())
            lon = Int((c.longitude * 1_000).rounded())
        }
    }

    private init() {
        guard let url = Bundle.main.url(forResource: "TaiwanCounties", withExtension: "json") else {
            AppLog.dataError("TaiwanCounties.json 不在 bundle 內，地圖縣市高光停用")
            outlines = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let collection = try JSONDecoder().decode(CountyCollection.self, from: data)
            var result: [String: [[CLLocationCoordinate2D]]] = [:]
            for feature in collection.features {
                let polygons: [[[[Double]]]]
                switch feature.geometry.type {
                case "Polygon": polygons = [feature.geometry.polygon ?? []]
                case "MultiPolygon": polygons = feature.geometry.multiPolygon ?? []
                default: polygons = []
                }
                let rings = polygons.compactMap { $0.first }.map { ring in
                    ring.compactMap { pair -> CLLocationCoordinate2D? in
                        guard pair.count == 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0]) // GeoJSON 是 [經度, 緯度]
                    }
                }.filter { $0.count >= 4 }
                result[Self.normalize(feature.properties.county), default: []] += rings
            }
            outlines = result
        } catch {
            AppLog.dataError("TaiwanCounties.json 解析失敗：\(error.localizedDescription)")
            outlines = [:]
        }
    }

    /// 「臺」統一成「台」
    nonisolated static func normalize(_ county: String) -> String {
        county.replacingOccurrences(of: "臺", with: "台")
    }

    /// 縣市外框（找不到回空陣列）
    func outline(for county: String) -> [[CLLocationCoordinate2D]] {
        outlines[Self.normalize(county)] ?? []
    }

    /// 座標所在縣市（點面內判走鄉鎮區界，結果快取）；不在任何區內（海上、離島縫隙）回 nil
    func county(at coord: CLLocationCoordinate2D) -> String? {
        let key = CoordKey(coord)
        if let hit = countyCache[key] { return hit }
        let result = DistrictBoundaries.shared.district(at: coord).map { Self.normalize($0.county) }
        if countyCache.count > 3_000 { countyCache.removeAll() }
        countyCache[key] = .some(result)
        return result
    }
}

// MARK: - GeoJSON 解碼

private struct CountyCollection: Decodable {
    let features: [CountyFeature]
}

private struct CountyFeature: Decodable {
    struct Properties: Decodable { let county: String }
    let properties: Properties
    let geometry: CountyGeometry
}

private struct CountyGeometry: Decodable {
    let type: String
    let polygon: [[[Double]]]?
    let multiPolygon: [[[[Double]]]]?

    enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        switch type {
        case "Polygon":
            polygon = try c.decode([[[Double]]].self, forKey: .coordinates)
            multiPolygon = nil
        case "MultiPolygon":
            polygon = nil
            multiPolygon = try c.decode([[[[Double]]]].self, forKey: .coordinates)
        default:
            polygon = nil
            multiPolygon = nil
        }
    }
}
