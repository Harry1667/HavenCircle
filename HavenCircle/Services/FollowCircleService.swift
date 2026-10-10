import Foundation
import CoreLocation
import SwiftData
import os

/// 跟隨圈更新器：顯著位置變更（約移動 500 公尺）到達時，
/// 把所有 isFollowMe 圈的圈心移到新位置、反查行政區，再重跑資料管線——
/// 新位置可能落進不同的警報範圍，比對要立刻重做才有守護意義。
/// 隱私邊界：位置只寫本機 SwiftData，這條路徑完全不經網路。
@MainActor
enum FollowCircleService {
    /// 移動門檻：不到 300 公尺不更新，過濾 GPS 漂移造成的頻繁重算
    private static let minimumMove: CLLocationDistance = 300

    static func handle(location: CLLocation, container: ModelContainer) async {
        let context = container.mainContext
        let descriptor = FetchDescriptor<LocalLifeCircle>(predicate: #Predicate { $0.isFollowMe })
        guard let circles = try? context.fetch(descriptor), !circles.isEmpty else { return }

        var moved = false
        for circle in circles {
            let old = CLLocation(latitude: circle.latitude, longitude: circle.longitude)
            guard location.distance(from: old) >= minimumMove else { continue }
            circle.latitude = location.coordinate.latitude
            circle.longitude = location.coordinate.longitude
            circle.kind = .live
            circle.locationUpdatedAt = location.timestamp
            moved = true
        }
        guard moved else { return }

        // 反查行政區（區域型警報比對用）與粗略地名；反查失敗保留原值，不擋座標更新
        if let place = await MapReverseGeocoder.lookup(location) {
            let district = Districts.guess(from: place.searchableText)
            let label = place.approximateLabel(district: district)
            for circle in circles {
                if district != Districts.unspecified { circle.district = district }
                if let label { circle.setAddress(label) } // 反查地名也走加密，與手動輸入住址一致
            }
        }

        context.saveReporting()
        AppLog.pipeline.info("跟隨圈已隨位置變更更新圈心，重跑比對")
        await EventPipeline.refresh(context: context)
    }

    /// 是否存在跟隨圈——App 啟動與圈增刪後呼叫，決定顯著位置變更監聽的開關
    static func hasFollowCircle(context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<LocalLifeCircle>(predicate: #Predicate { $0.isFollowMe })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
