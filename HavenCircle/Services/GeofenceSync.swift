import Foundation
import SwiftData

/// 把本機的守護地點（固定圈）餵給 LocationService 建立地理圍欄。
/// 圍欄只在位置分享開啟時存在（LocationService.syncGeofences 內判斷），分享關閉就全部移除。
@MainActor
enum GeofenceSync {
    static func places(context: ModelContext) -> [GeofencePlace] {
        let circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        return circles
            .filter { $0.kind == .fixed && !($0.latitude == 0 && $0.longitude == 0) }
            .map { circle in
                // 守護地點的名字以地點成員為準（「家」「公司」），沒有才退回警戒圈名稱
                let name = circle.member?.isPlace == true ? (circle.member?.name ?? circle.name) : circle.name
                return GeofencePlace(
                    id: circle.circleKey,
                    name: name,
                    latitude: circle.latitude,
                    longitude: circle.longitude
                )
            }
    }

    static func sync(context: ModelContext) {
        LocationService.shared.syncGeofences(places(context: context))
    }
}
