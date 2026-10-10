import Foundation
import CoreLocation

/// 台灣鄉鎮市區邊界（內嵌資源 TaiwanDistricts.json）。
/// 來源：內政部鄉鎮市區界線（政府資料開放授權），經 Douglas-Peucker 簡化到約 200 公尺容差
/// （20MB → 341KB）——塗色顯示用，不做精確定位判斷。
/// 用途：區域警報的「行政區塗層」——把受影響的行政區整片著色，取代誤導性的單點標記。
nonisolated struct DistrictBoundaries {
    struct District {
        let county: String
        let town: String
        /// 每個 ring 是一圈外框座標（MultiPolygon 拆成多個 ring；洞已忽略，塗色用途可接受）
        let rings: [[CLLocationCoordinate2D]]
    }

    /// 外接矩形：點面內判前先用它快速排除大多數不可能的區（O(1) 比對）
    private struct BBox {
        let minLat, maxLat, minLon, maxLon: Double
        init?(rings: [[CLLocationCoordinate2D]]) {
            let points = rings.flatMap { $0 }
            guard let first = points.first else { return nil }
            var mnLa = first.latitude, mxLa = first.latitude
            var mnLo = first.longitude, mxLo = first.longitude
            for p in points {
                mnLa = min(mnLa, p.latitude);  mxLa = max(mxLa, p.latitude)
                mnLo = min(mnLo, p.longitude); mxLo = max(mxLo, p.longitude)
            }
            minLat = mnLa; maxLat = mxLa; minLon = mnLo; maxLon = mxLo
        }
        func contains(_ p: CLLocationCoordinate2D) -> Bool {
            p.latitude >= minLat && p.latitude <= maxLat &&
            p.longitude >= minLon && p.longitude <= maxLon
        }
    }

    static let shared = DistrictBoundaries()

    /// 以區名索引（例「大雅區」→ 各縣市同名區的清單）。
    /// 已知限制：RegionAlert 只存區名不含縣市，同名區（如各縣市的「東區」）會一起亮，
    /// 寧可多塗不漏塗——這是安全 App 的正確取捨方向。
    private let byTown: [String: [District]]

    /// 扁平清單＋每區外接矩形（bounding box），供「座標→縣市+區」的點面內判快速篩選。
    private let indexed: [(district: District, bbox: BBox)]

    /// 全國鄉鎮市區名清單（排序去重），供生活圈行政區選單與警報比對使用
    let allTownNames: [String]

    private init() {
        guard let url = Bundle.main.url(forResource: "TaiwanDistricts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data) else {
            AppLog.dataError("TaiwanDistricts.json 載入失敗，區域警報塗層停用")
            byTown = [:]
            indexed = []
            allTownNames = []
            return
        }
        var index: [String: [District]] = [:]
        var flat: [(District, BBox)] = []
        for feature in collection.features {
            let rings: [[CLLocationCoordinate2D]]
            switch feature.geometry.type {
            case "Polygon":
                guard let coords = feature.geometry.polygonCoordinates else { continue }
                rings = [Self.ring(coords.first ?? [])] // 只取外框，忽略洞
            case "MultiPolygon":
                guard let coords = feature.geometry.multiPolygonCoordinates else { continue }
                rings = coords.compactMap { poly in poly.first.map(Self.ring) }
            default:
                continue
            }
            let cleaned = rings.filter { $0.count >= 4 }
            let district = District(county: feature.properties.county,
                                    town: feature.properties.town,
                                    rings: cleaned)
            index[feature.properties.town, default: []].append(district)
            if let bbox = BBox(rings: cleaned) {
                flat.append((district, bbox))
            }
        }
        byTown = index
        indexed = flat
        allTownNames = index.keys.sorted()
    }

    /// 依區名找邊界（可能對到多個縣市的同名區）
    func districts(named town: String) -> [District] {
        byTown[town] ?? []
    }

    /// 縣市名 → 轄下所有鄉鎮市區名（去重排序）。
    /// 用途：地震等「官方只給到縣市層級影響範圍」的區域警報——氣象署震度分布只到
    /// 「宜蘭縣地區」這種縣市粒度，我們的生活圈卻只存區名（不含縣市，見 RegionAlert 既有取捨），
    /// 要讓「宜蘭縣有感」比對得到「宜蘭縣XX鄉」的生活圈，就得把縣市展開成該縣市全部的區。
    /// 寧可多蓋（同縣市其他區也會顯示這則警報）不要漏接，跟現有 byTown 同名區的取捨方向一致。
    func townNames(inCounty county: String) -> [String] {
        let normalized = county.replacingOccurrences(of: "臺", with: "台")
        return Set(
            indexed
                .map(\.district)
                .filter { $0.county.replacingOccurrences(of: "臺", with: "台") == normalized }
                .map(\.town)
        ).sorted()
    }

    /// 座標落在哪個「縣市＋區」——點面內判（先用 bounding box 篩，再對外框做射線法）。
    /// 這是把生活圈精確座標對應到唯一行政區（含縣市，解決同名區歧義）的入口。
    func district(at coord: CLLocationCoordinate2D) -> District? {
        for entry in indexed where entry.bbox.contains(coord) {
            for ring in entry.district.rings where Self.ringContains(ring, coord) {
                return entry.district
            }
        }
        return nil
    }

    /// 圈心＋半徑「碰到」的所有行政區（圈心那一區＋四周取樣點落到的鄰區），用來解邊界漏接：
    /// 圈壓在區界時，隔壁區的事件也該通知。以圈心與八方位取樣點做點面內判，去重回傳。
    func districtsTouching(center: CLLocationCoordinate2D, radiusMeters: Double) -> [District] {
        let dLat = radiusMeters / 111_320.0
        let dLon = radiusMeters / (111_320.0 * max(cos(center.latitude * .pi / 180), 0.01))
        let offsets: [(Double, Double)] = [
            (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1),
            (-0.7, -0.7), (-0.7, 0.7), (0.7, -0.7), (0.7, 0.7),
        ]
        var seen = Set<String>()
        var result: [District] = []
        for (oLat, oLon) in offsets {
            let sample = CLLocationCoordinate2D(latitude: center.latitude + oLat * dLat,
                                                longitude: center.longitude + oLon * dLon)
            if let d = district(at: sample), seen.insert(d.county + d.town).inserted {
                result.append(d)
            }
        }
        return result
    }

    /// 射線法（even-odd）判斷點是否在外框內
    nonisolated private static func ringContains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = a.longitude + (p.latitude - a.latitude) / (b.latitude - a.latitude) * (b.longitude - a.longitude)
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    nonisolated private static func ring(_ coords: [[Double]]) -> [CLLocationCoordinate2D] {
        coords.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0]) // GeoJSON 是 [經度, 緯度]
        }
    }
}

// MARK: - GeoJSON 解碼（座標維度不同，手動分流）

private nonisolated struct FeatureCollection: Decodable {
    let features: [Feature]
}

private nonisolated struct Feature: Decodable {
    let properties: Properties
    let geometry: Geometry
}

private nonisolated struct Properties: Decodable {
    let county: String
    let town: String
}

private nonisolated struct Geometry: Decodable {
    let type: String
    let polygonCoordinates: [[[Double]]]?
    let multiPolygonCoordinates: [[[[Double]]]]?

    enum CodingKeys: String, CodingKey {
        case type, coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Polygon":
            polygonCoordinates = try container.decode([[[Double]]].self, forKey: .coordinates)
            multiPolygonCoordinates = nil
        case "MultiPolygon":
            polygonCoordinates = nil
            multiPolygonCoordinates = try container.decode([[[[Double]]]].self, forKey: .coordinates)
        default:
            polygonCoordinates = nil
            multiPolygonCoordinates = nil
        }
    }
}
