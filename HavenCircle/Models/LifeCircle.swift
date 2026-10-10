import Foundation
import SwiftData

enum LifeCircleKind: String, CaseIterable {
    case live
    case fixed

    var title: String {
        switch self {
        case .live: "即時圈"
        case .fixed: "固定地點"
        }
    }

    var iconName: String {
        switch self {
        case .live: "location.fill"
        case .fixed: "mappin.and.ellipse"
        }
    }
}

@Model
final class LocalLifeCircle {
    @Attribute(.unique) var circleKey: String
    var name: String
    /// 精確住址，以 AES-GCM 加密後儲存（見 AddressCrypto）。
    /// 請勿直接讀寫此欄位；改用 `addressText`（解密讀取）與 `setAddress(_:)`（加密寫入）。
    /// 相容：無密文前綴的舊明文/即時圈固定文案會被原樣回傳。
    var encryptedAddress: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Int
    /// 這個生活圈要接收的事件類型（改為陣列，取代舊版頓號分隔字串）
    var alertTypes: [String]
    /// 時段感知：只在指定作息時段推播（例如公司圈只在上班時間）。
    /// 時段外的官方事件仍會顯示在 App 內，只是不推播——這是對抗通知疲勞的主要機制。
    var scheduleEnabled: Bool = false
    /// 適用星期（Calendar.weekday 慣例：1=週日 … 7=週六）
    var scheduleWeekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var scheduleStartHour: Int = 0
    var scheduleEndHour: Int = 24
    /// 所在行政區（供區域型警報比對；「未指定」表示不參與區域警報）
    var district: String = "未指定"
    /// 圈類型：fixed＝固定資產／地點，live＝由家人手機共享的移動警戒圈。
    /// 保留 isFollowMe 供舊資料遷移；本機擁有者的 live circle 會同時設為 true。
    var kindRawValue: String = "fixed"
    var isFollowMe: Bool = false
    /// 即時圈的位置時效與 CloudKit 來源。固定圈兩欄皆為 nil。
    var locationUpdatedAt: Date?
    /// 即時圈「開始停留在這個位置」的時間（座標最後一次移動超過 100 公尺）。
    /// 與 locationUpdatedAt（最後回報時間）分開：人沒動但手機持續回報，不算過期。
    /// 新增的可選欄位，SwiftData 輕量遷移即可；本機跟隨圈與舊資料為 nil。
    var locationStationarySince: Date?
    /// 即時圈最近一次「確認實際移動」的時間（「移動中」需要它在 5 分鐘內）。新增的可選欄位，輕量遷移即可。
    var locationMovedAt: Date?
    /// 即時圈目前所在的守護地點名稱與進入時間（家人端「在家・從 08:30 起」用）。
    /// 新增的可選欄位，SwiftData 輕量遷移即可。
    var locationPlaceName: String?
    var locationPlaceSince: Date?
    var sharedLocationID: String?
    /// 全家共用守護地點的雲端文件 ID（families/{fid}/places/{id}）。nil＝尚未上雲（或沒有家庭）。
    /// 新增的可選欄位，SwiftData 輕量遷移即可。
    var remotePlaceId: String?
    /// 共用守護地點的建立者 Firebase uid（家人頁顯示「由 X 新增」用）；本機專屬或舊資料為 nil。
    var createdByUid: String?
    var member: LocalFamilyMember?

    init(
        circleKey: String = UUID().uuidString,
        name: String,
        encryptedAddress: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Int,
        alertTypes: [String],
        member: LocalFamilyMember? = nil
    ) {
        self.circleKey = circleKey
        self.name = name
        self.encryptedAddress = encryptedAddress
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.alertTypes = alertTypes
        self.member = member
    }
}

extension LocalLifeCircle {
    var kind: LifeCircleKind {
        get { isFollowMe || kindRawValue == LifeCircleKind.live.rawValue ? .live : .fixed }
        set { kindRawValue = newValue.rawValue }
    }

    /// 即時圈超過 15 分鐘「沒有回報」，就不能再用來觸發安全判斷。
    /// 圈仍保留在畫面上並明示失聯，避免把舊座標冒充現在位置。
    ///
    /// locationUpdatedAt 是「最後回報時間」：分享中的手機沒移動也會每 5 分鐘心跳一次，
    /// 所以待在原地的人不會被誤判過期；只有手機沒電、關機、斷網或停止回報才會過期。
    /// 本人與家人的即時圈都遵守相同規則：沒有回報時間或超過 15 分鐘就不參與警報判斷。
    var isActiveForAlerts: Bool {
        guard kind == .live else { return true }
        return LiveLocationPresence.isReporting(lastReportedAt: locationUpdatedAt)
    }

    /// 狀態文案（純文字、不靠顏色）：在同一地點多久・多久前確認／多久沒有回報
    var locationFreshnessText: String {
        guard kind == .live else { return "固定位置" }
        // 自己的圈在自己手機上：位置來自這支手機本身，「沒有回報」是對家人說的話，
        // 對本人顯示成「X 小時沒有回報」只會嚇到自己；誠實標示來源即可。
        if member?.isCurrentUser == true && !isActiveForAlerts {
            return "這支手機的位置（尚未回報給家人）"
        }
        return LiveLocationPresence.statusText(
            lastReportedAt: locationUpdatedAt,
            stationarySince: locationStationarySince,
            movedAt: locationMovedAt,
            placeName: locationPlaceName,
            placeSince: locationPlaceSince,
            district: district
        )
    }

    /// 事件發生時間是否落在這個生活圈的提醒時段內
    func isWithinSchedule(at date: Date = .now) -> Bool {
        guard scheduleEnabled else { return true }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return scheduleWeekdays.contains(weekday)
            && hour >= scheduleStartHour
            && hour < scheduleEndHour
    }

    /// 顯示用的時段描述
    var scheduleText: String {
        guard scheduleEnabled else { return "全天提醒" }
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let days = scheduleWeekdays.sorted().compactMap { $0 >= 1 && $0 <= 7 ? names[$0 - 1] : nil }
        return "週\(days.joined(separator: "、")) \(scheduleStartHour):00–\(scheduleEndHour):00"
    }

    /// 住址明文存取：底層 `encryptedAddress` 存密文，這裡負責解密。
    /// 相容舊明文與即時圈固定文案（無密文前綴者原樣回傳），詳見 AddressCrypto。
    var addressText: String {
        AddressCrypto.decrypt(encryptedAddress)
    }

    /// 寫入使用者輸入的住址（加密後存入 `encryptedAddress`）。
    func setAddress(_ plaintext: String) {
        encryptedAddress = AddressCrypto.encrypt(plaintext)
    }
}

/// 事件類型清單（MVP 四大類＋對標 Beacon 後補上的細分類）。
///
/// 「四大類」（fire/traffic/disaster/publicSafety）是生活圈 alertTypes 的粗顆粒度選項，
/// defaultSelection 跟閘門判斷都繼續用這四個，不動——避免影響既有的圈子比對邏輯。
/// 下面的細分類只當作 eventType 的實際值（更精確的圖示/文案用），本身不是使用者要
/// 勾選的「類型」，而是「這件事具體是哪一種」，讓地圖/事件卡能顯示對的圖示而不是
/// 一律套用「公共安全」的通用盾牌。細分類事件仍會被 publicSafety／disaster 等
/// 既有 isDangerKind 判斷涵蓋是否推播（見 RemoteConfig.defaultDangerKinds）。
enum EventCategory {
    static let fire = "火災"
    static let traffic = "重大交通事故"
    static let disaster = "天災"
    static let publicSafety = "公共安全"
    static let all = [fire, traffic, disaster, publicSafety]
    /// 生活圈預設接收的類型。
    /// 公共安全（槍擊、械鬥、攻擊等治安事件）先前未列入預設，導致這類真實事件即使
    /// 有資料來源也永遠比對不到任何生活圈、等同對使用者隱形——這是覆蓋漏抓，
    /// 危害不亞於漏報天災，故補上。
    /// 「重大交通事故」目前沒有政府即時資料源，不列入預設——勾了卻永遠收不到是空承諾，
    /// 接上資料源後再加回。
    static let defaultSelection = [fire, disaster, publicSafety]

    // MARK: - 細分類（對標 Beacon 守護臺灣後補上，僅供圖示/文案更精確，不影響上面四類的閘門邏輯）

    static let knifeAttack = "持刀傷人"
    static let shooting = "槍擊案"
    static let disturbance = "公共騷動/鬥毆"
    static let harassment = "性騷擾"
    static let suspiciousPerson = "可疑人物"
    static let animalAttack = "動物攻擊"
    static let injuredAnimal = "受傷動物"
    static let gasLeak = "瓦斯外洩"
    static let explosion = "爆炸"
    static let emergencyMedical = "緊急救護"
    static let trainIncident = "火車事故"
    static let metroIncident = "捷運異常"
    static let earthquake = "地震"
    static let flood = "淹水"
    static let landslide = "土石流"
    static let powerOutage = "停電"
    static let waterOutage = "停水"

    /// 細分類回推生活圈使用的四大類，避免圈只存「公共安全」時，
    /// 「槍擊案／持刀傷人」等真實事件因字串不同而完全比對不到。
    static func broadCategory(for eventType: String) -> String {
        switch eventType {
        case knifeAttack, shooting, disturbance, harassment, suspiciousPerson,
             animalAttack, gasLeak, explosion, emergencyMedical:
            publicSafety
        case trainIncident, metroIncident:
            traffic
        case earthquake, flood, landslide, powerOutage, waterOutage:
            disaster
        default:
            eventType
        }
    }
}
