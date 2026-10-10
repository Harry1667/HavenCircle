import SwiftData
import CoreLocation

/// 新手第一次開 App 的資料地基（零導覽版）：
/// - 冷啟動只建「我」這個成員，不建圈、不要任何權限。
/// - 使用者授權定位之後，才建 1 公里「跟著人」的跟隨圈，圈心用實際位置。
///
/// 為什麼拆開：以前一開始就建圈並把圈心放台北車站，拒絕定位的人會拿台北車站去算「與我有關」，
/// 是假相關。現在沒定位就沒有圈，動態停在「全台動態」，並提供「新增守護地點」的路。
/// 身分（爸爸／媽媽…）稍後才選，所以本人先叫「我」，選完身分再改名（見 AppTabs.applyRole）。
enum FirstRunSetup {
    /// 預設警戒半徑（公尺）＝1 公里。
    static let defaultRadiusMeters = 1_000

    /// 若尚無「本人」成員就建一個。已存在則不重複建立。
    @MainActor
    static func ensureCurrentUser(context: ModelContext) {
        let members = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
        guard !members.contains(where: \.isCurrentUser) else { return }
        let me = LocalFamilyMember(name: "我", relationship: "擁有者")
        me.isCurrentUser = true
        context.insert(me)
        context.saveReporting()
    }

    /// 已授權定位且尚無跟隨圈時，建立 1 公里跟隨圈（isFollowMe=true）。
    /// 圈心用目前實際位置；取不到位置就不建（下次授權狀態變化或回前景再試），
    /// 絕不放台北車站之類的假座標。回傳是否新建了圈。
    @MainActor
    @discardableResult
    static func ensureFollowCircleIfAuthorized(context: ModelContext) async -> Bool {
        guard LocationService.shared.isAuthorized else { return false }
        let circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        guard !circles.contains(where: \.isFollowMe) else { return false }
        ensureCurrentUser(context: context)
        let members = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
        guard let me = members.first(where: \.isCurrentUser),
              let location = await LocationService.shared.currentLocation() else { return false }
        // await 期間可能已被別處建立，再檢查一次避免重複
        let latest = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        guard !latest.contains(where: \.isFollowMe) else { return false }

        let circle = LocalLifeCircle(
            name: FollowCircleToggleSection.onName,
            encryptedAddress: "位置由這支手機分享",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radiusMeters: defaultRadiusMeters,
            alertTypes: EventCategory.defaultSelection,
            member: me
        )
        circle.isFollowMe = true
        circle.kind = .live
        circle.locationUpdatedAt = location.timestamp
        context.insert(circle)
        context.saveReporting()
        // 跟隨圈監聽開關跟著圈的存在與否走（同 FollowCircleToggleSection）
        LocationService.shared.syncFollowMonitoring(hasFollowCircle: true)
        return true
    }
}
