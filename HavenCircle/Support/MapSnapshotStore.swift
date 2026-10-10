import MapKit
import UIKit

/// 動態頁頁首（層次外觀）用的「守護範圍」靜態地圖快照。
///
/// 為什麼是快照而不是即時 `Map`：動態頁是冷啟動第一屏，放即時 Map 會常駐吃 GPU 與記憶體、
/// 還會搶捲動手勢；快照只是一張圖，產生在背景、完成後淡入，主執行緒只負責顯示。
/// 快取兩層：記憶體（NSCache）→ 磁碟（Caches 目錄 PNG）。key 含座標（取到小數 3 位 ≈ 100 公尺）、
/// 半徑、尺寸與深淺色——守護範圍沒動、螢幕寬沒變就不會重畫，也不會重打地圖圖磚。
/// 圖上已畫好範圍圈（品牌色 16% 填色＋細線），所以顯示端只需調淡與去飽和。
nonisolated enum MapSnapshotStore {
    struct Request: Hashable {
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int
        let width: Int
        let height: Int
        let isDark: Bool

        /// 快取鍵：座標取小數 3 位，圈心微小飄移不會每次都重畫
        var key: String {
            let lat = String(format: "%.3f", latitude)
            let lon = String(format: "%.3f", longitude)
            return "L_\(lat)_\(lon)_\(radiusMeters)_\(width)x\(height)_\(isDark ? "d" : "l")"
                .replacingOccurrences(of: ".", with: "p")
                .replacingOccurrences(of: "-", with: "m")
        }
    }

    // NSCache 本身執行緒安全；以 nonisolated(unsafe) 宣告讓背景任務可直接存取
    nonisolated(unsafe) private static let memory = NSCache<NSString, UIImage>()

    /// 取快照：記憶體 → 磁碟 → 新產生。失敗回 nil（呼叫端退回柔和漸層），並記錄原因。
    static func image(for request: Request, stroke: UIColor) async -> UIImage? {
        let key = request.key
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let disk = loadFromDisk(key: key) {
            memory.setObject(disk, forKey: key as NSString)
            return disk
        }
        guard let rendered = await render(request, stroke: stroke) else { return nil }
        memory.setObject(rendered, forKey: key as NSString)
        saveToDisk(rendered, key: key)
        return rendered
    }

    // MARK: - 產生

    private static func render(_ request: Request, stroke: UIColor) async -> UIImage? {
        // 圈約佔畫面寬的 40%：可視寬度 = 半徑 × 5。半徑夾在 300 公尺～20 公里，避免極端比例
        let radius = Double(min(max(request.radiusMeters, 300), 20_000))
        let widthMeters = radius * 5
        let heightMeters = widthMeters * Double(request.height) / Double(request.width)
        let center = CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: heightMeters,
            longitudinalMeters: widthMeters
        )
        options.size = CGSize(width: request.width, height: request.height)
        options.traitCollection = UITraitCollection(userInterfaceStyle: request.isDark ? .dark : .light)
        options.pointOfInterestFilter = .excludingAll // 頁首只要底圖脈絡，不要一堆店家圖示
        options.showsBuildings = false

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            // 範圍圈：用快照座標換算半徑像素（經度方向 1 度 ≈ 111320 公尺 × cos(緯度)）
            let lonDelta = radius / (111_320 * max(cos(center.latitude * .pi / 180), 0.01))
            let centerPoint = snapshot.point(for: center)
            let edgePoint = snapshot.point(for: CLLocationCoordinate2D(
                latitude: center.latitude,
                longitude: center.longitude + lonDelta
            ))
            let radiusPoints = abs(edgePoint.x - centerPoint.x)
            let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
            return renderer.image { _ in
                snapshot.image.draw(at: .zero)
                let path = UIBezierPath(
                    arcCenter: centerPoint, radius: radiusPoints,
                    startAngle: 0, endAngle: .pi * 2, clockwise: true
                )
                stroke.withAlphaComponent(0.16).setFill()
                path.fill()
                stroke.withAlphaComponent(0.7).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        } catch {
            AppLog.dataError("守護範圍地圖快照產生失敗：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 磁碟快取

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HCMapSnapshots", isDirectory: true)
    }

    private static func loadFromDisk(key: String) -> UIImage? {
        guard let url = cacheDirectory?.appendingPathComponent("\(key).png"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func saveToDisk(_ image: UIImage, key: String) {
        guard let dir = cacheDirectory, let data = image.pngData() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(key).png"), options: .atomic)
        } catch {
            // 快取寫入失敗不影響顯示（記憶體快取仍有效），但要留下紀錄
            AppLog.dataError("地圖快照寫入磁碟快取失敗：\(error.localizedDescription)")
        }
    }
}
