import Foundation
import CoreLocation

struct CircleMatch {
    let memberName: String
    let circleName: String
    /// 概略距離（取整到百公尺，避免暴露精確位置）
    let distanceMeters: Int
    let withinSchedule: Bool
    /// 命中的圈屬於本人＝通知帶「回報我平安」；屬於其他家人＝帶「詢問是否平安」
    let isCurrentUser: Bool
    /// 地點類成員（倉庫等）不會回報平安，不掛互動按鈕
    let isPlace: Bool
    /// 以「同一行政區」命中（行政區級事件對守護地點）時為該行政區名稱；此時 distanceMeters 只供排序，不對使用者顯示
    var sameDistrict: String? = nil

    /// 詳情頁／AI 上下文用的範圍文字
    var rangeText: String {
        if let sameDistrict { return "同在\(sameDistrict)" }
        return "約 \(distanceMeters) 公尺"
    }
}

/// 提醒決策結果。reason 直接顯示給使用者——「每則通知都能看見為何收到」
struct AlertDecision {
    let shouldPush: Bool
    let matches: [CircleMatch]
    let reason: String
}

/// 分級提醒的單一決策點：所有「要不要推播」的判斷都集中在這裡，
/// 才能保證產品守則（未驗證線索不推播、時段外不打擾）處處一致。
enum AlertPolicy {
    static func evaluate(
        event: LocalSafetyEvent,
        members: [LocalFamilyMember],
        at date: Date = .now,
        frequency: AlertFrequency = .current
    ) -> AlertDecision {
        guard event.isActiveForAwareness else {
            return AlertDecision(
                shouldPush: false,
                matches: [],
                reason: "來源未確認事件仍在發生，僅作背景資訊，不會推播"
            )
        }
        let point = CLLocation(latitude: event.latitude, longitude: event.longitude)
        var matches: [CircleMatch] = []
        let broadCategory = EventCategory.broadCategory(for: event.eventType)
        // 事件定位只到行政區：座標是行政區中心，誤差達數公里，守護地點改用同一行政區判斷
        let districtLevel = AlertMatchRule.isDistrictLevel(precisionMeters: event.precisionMeters)
        let eventDistrict: String? = districtLevel ? Self.district(of: event) : nil

        for member in members {
            for circle in member.lifeCircles {
                guard circle.isActiveForAlerts else { continue }
                // 危險類（火災／天災／公共安全等保命災型）一律通過類型閘門——即使使用者的圈
                // alertTypes 還是舊的〔火災,天災〕沒勾到公共安全，槍擊／械鬥這種保命事件也要能
                // 命中，不必去改動已存的 SwiftData 資料（見 RemoteConfig.isDangerKind）。其餘
                // 一般提醒（空品、停水…）仍照該圈的 alertTypes 設定過濾。
                guard circle.alertTypes.contains(event.eventType)
                        || circle.alertTypes.contains(broadCategory)
                        || RemoteConfig.isDangerKind(event.eventType) else { continue }
                let distance = point.distance(
                    from: CLLocation(latitude: circle.latitude, longitude: circle.longitude)
                )
                // 只看「事件是否落在警戒圈半徑內」（＋位置精度緩衝——新聞事件常只精確到行政區，
                // 沒這個緩衝會漏掉行政區中心稍遠、但其實就在你附近的事件）。
                // 使用者要求：只有圈內的事件才叫，不再額外疊加「災型影響半徑」把命中範圍往圈外擴張。
                // 誤差加成上限 min(誤差, 半徑, 1000m)，大範圍不確定事件不再把命中範圍撐到數公里外。
                var sameDistrict: String?
                if districtLevel && member.isPlace {
                    guard AlertMatchRule.isSameDistrict(
                        circleDistrict: circle.district, eventDistrict: eventDistrict, unspecified: Districts.unspecified
                    ) else { continue }
                    sameDistrict = circle.district
                } else {
                    let buffer = AlertMatchRule.precisionBuffer(
                        precisionMeters: event.precisionMeters, radiusMeters: circle.radiusMeters
                    )
                    guard distance <= Double(circle.radiusMeters) + buffer else { continue }
                }
                matches.append(CircleMatch(
                    memberName: member.name,
                    circleName: circle.name,
                    distanceMeters: max(Int(distance / 100) * 100, 100),
                    withinSchedule: circle.isWithinSchedule(at: date),
                    isCurrentUser: member.isCurrentUser,
                    isPlace: member.isPlace,
                    sameDistrict: sameDistrict
                ))
            }
        }

        guard !matches.isEmpty else {
            return AlertDecision(shouldPush: false, matches: [], reason: "事件不在任何有效警戒圈的提醒範圍內")
        }
        // 通知頻率「小」：只推危險級事件；提醒級（高溫、降雨、停水…）僅在 App 內顯示，不發通知
        if frequency == .low && !RemoteConfig.isDangerKind(event.eventType) {
            return AlertDecision(shouldPush: false, matches: matches, reason: "通知頻率設為「小」，此類一般提醒僅在 App 內顯示")
        }
        // 設定頁的「公共安全事件僅高可信度提醒」過去只有 UI、沒有接進決策。
        // 開啟時，公共安全粗類與所有細分類都要求高可信度（官方／多來源／一線主流媒體）；
        // 關閉後仍須使用者主動把提醒多寡設成「靈敏」，才會允許單一媒體早期線索。
        // 用 isCredible（而非 isOfficiallyConfirmed）判斷，讓 mediaConfirmed 視同高可信度、
        // 與 crossVerified 一致——開關的語意本身不變（仍是「只推高可信度」），只是「高可信度」
        // 的定義正確納入一線媒體單一報導。
        let highConfidenceOnly = UserDefaults.standard.object(
            forKey: SettingsKeys.highConfidenceOnly
        ) as? Bool ?? true
        if highConfidenceOnly,
           broadCategory == EventCategory.publicSafety,
           !event.isCredible {
            return AlertDecision(
                shouldPush: false,
                matches: matches,
                reason: "公共安全事件設定為僅高可信度提醒；此線索尚未經官方、主流媒體或多來源確認"
            )
        }
        // 可信度門檻：未經官方／多來源／一線媒體確認的線索一般不推播；
        // 但通知頻率「大」時放寬，讓更早期的單一來源消息也能通知（代價是可能偶有誤報）
        guard event.isCredible || frequency == .high else {
            return AlertDecision(shouldPush: false, matches: matches, reason: "未驗證線索僅在 App 內顯示，不會推播")
        }
        let inSchedule = matches.filter(\.withinSchedule)
        guard let best = inSchedule.min(by: { $0.distanceMeters < $1.distanceMeters }) else {
            return AlertDecision(shouldPush: false, matches: matches, reason: "相關警戒圈都在提醒時段外，僅在 App 內顯示")
        }
        // 文字只講「距離誰、多遠」，不重複地點名稱與警戒圈（地點成員與圈常同名）：
        // 本人跟隨圈「距離你約 X」；守護地點「距離你的守護地點「名稱」約 X」；家人「距離家人「名稱」約 X」
        let distanceText = Self.distanceText(best.distanceMeters)
        let phrase: String
        if best.isCurrentUser {
            phrase = "距離你約 \(distanceText)"
        } else if best.isPlace, let district = best.sameDistrict {
            // 行政區級事件沒有可信的距離，不顯示假的公里數
            phrase = "在你的守護地點「\(best.memberName)」所在的\(district)"
        } else if best.isPlace {
            phrase = "距離你的守護地點「\(best.memberName)」約 \(distanceText)"
        } else {
            phrase = "距離家人「\(best.memberName)」約 \(distanceText)"
        }
        return AlertDecision(
            shouldPush: true,
            matches: matches,
            reason: "\(phrase)，\(event.trustStatus)"
        )
    }

    /// 事件所在行政區：先從地點文字取最長的行政區名稱（避免「中西區」被「西區」誤配），
    /// 取不到再用座標做邊界內判
    static func district(of event: LocalSafetyEvent) -> String? {
        let text = event.approximateLocation + event.title
        // 效能：結果只取決於文字與座標，動態頁／地圖每次重繪都會對每個事件問一次，快取起來
        let cacheKey = "\(text)|\(event.latitude),\(event.longitude)"
        if let hit = districtCache[cacheKey] { return hit.value }
        let result: String?
        if let name = Districts.all.dropFirst().filter({ text.contains($0) }).max(by: { $0.count < $1.count }) {
            result = name
        } else {
            result = DistrictBoundaries.shared
                .district(at: CLLocationCoordinate2D(latitude: event.latitude, longitude: event.longitude))?.town
        }
        if districtCache.count > 1_000 { districtCache.removeAll() }
        districtCache[cacheKey] = .init(value: result)
        return result
    }

    private struct CachedDistrict { let value: String? }
    private static var districtCache: [String: CachedDistrict] = [:]

    /// 1 公里以下用公尺，以上用公里並保留一位小數（5500 公尺 -> 5.5 公里）
    static func distanceText(_ meters: Int) -> String {
        meters < 1_000 ? "\(meters) 公尺" : String(format: "%.1f 公里", Double(meters) / 1_000)
    }
}
