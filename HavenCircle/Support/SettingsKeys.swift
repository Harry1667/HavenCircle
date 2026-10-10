import Foundation
import SwiftUI

/// UserDefaults / @AppStorage 鍵值集中定義，避免字串打錯造成設定失效
enum SettingsKeys {
    static let alertsEnabled = "alertsEnabled"
    static let alertsPaused = "alertsPaused"
    static let highConfidenceOnly = "highConfidenceOnly"
    static let digestEnabled = "digestEnabled"
    static let digestHour = "digestHour"
    static let profileDisplayName = "profileDisplayName"
    /// 家庭身分（爸爸／媽媽…）：與本名分離的獨立鍵（#15）。選身分只寫這裡，
    /// 絕不覆寫 profileDisplayName——避免「選了『媽媽』就把本名蓋掉」的舊行為。
    /// 只記自己的身分；其他家人的身分不會同步到雲端，家人清單上只有「自己」這列會顯示身分標籤。
    static let profileFamilyRole = "profileFamilyRole"
    static let liveLocationSharingEnabled = "liveLocationSharingEnabled"
    static let liveCircleRadiusMeters = "liveCircleRadiusMeters"
    static let liveLocationDeviceID = "liveLocationDeviceID"
    /// 接受 CKShare 後目前選用的家庭圈 zone；避免本機曾建立過空白家庭圈時又切回 private zone。
    /// （CloudKit 舊架構遺留，Firebase 版改用 currentFamilyID；保留鍵名供舊資料清理）
    static let activeFamilyZoneName = "activeFamilyZoneName"
    static let activeFamilyOwnerName = "activeFamilyOwnerName"
    /// 目前所屬家庭圈的 Firestore familyId（取代上面兩個 CloudKit zone 鍵）。
    /// 本機快取；換裝置／重裝時由 Firebase uid 反查還原。
    static let currentFamilyID = "currentFamilyID"
    /// A3：上次同步已知的家庭成員 uid 清單（用來偵測「新成員加入」並發本機通知）。
    /// 鍵不存在＝從未同步過，首次同步只登記不通知，避免剛加入就被既有成員洗版。
    static let knownFamilyMemberUids = "knownFamilyMemberUids"
    static let profileContactNote = "profileContactNote"
    /// 最後一次資料更新時間（timeIntervalSince1970；0 表示尚未更新過）
    static let lastDataRefresh = "lastDataRefresh"
    /// 新手設定是否完成（獨立旗標，不再以「有沒有家人資料」推斷）
    static let onboardingCompleted = "onboardingCompleted"
    /// App 冷啟動累計次數（HavenCircleApp.init 每次 +1）；用來判定「第二次開 App」的時機
    static let launchCount = "launchCount"
    /// 尚未選家庭身分的待辦旗標：新手第一次開 App 只走地圖著陸就種下，
    /// 待「第二次開 App 或點家人分頁」時跳出身分選擇；選完清除（仿 guardianIntroPending 消耗式旗標）
    static let roleSelectionPending = "roleSelectionPending"
    /// 第一次進主畫面的地圖親切帶領待播旗標：第一次開 App 完成著陸就種下，
    /// 讓首次落在地圖頁並播放「這是安全地圖／你的警戒圈」等教學卡，播完消耗。
    static let firstRunCoachingPending = "firstRunCoachingPending"
    /// 是否已看過「警戒圈可拖動調整」的提示（第一次點開事件、關掉詳情後顯示一次）
    static let seenCircleAdjustHint = "seenCircleAdjustHint"
    /// Sign in with Apple 授權後存下的帳號 email（僅本機顯示用；CloudKit 拿不到 email）
    static let appleAccountEmail = "appleAccountEmail"
    /// APNs 裝置權杖（十六進位字串）：設定頁「示範與開發」區顯示，供 Push Console 推播測試
    static let apnsDeviceToken = "apnsDeviceToken"
    /// 守護圈開場動效待播旗標：Onboarding 完成時種下，地圖首次出現時消耗（只演一次）
    static let guardianIntroPending = "guardianIntroPending"
    /// 外觀模式（AppearanceMode 的 rawValue）：跟隨系統／淺色／深色
    static let appearanceMode = "appearanceMode"
    /// 全域字體大小（AppTextSize 的 rawValue）：跟隨系統（預設）／大／特大／最大
    /// 與 alertFrequencyLevel（提醒多寡：僅重大／標準／靈敏）是兩件事，實機測試曾誤認為同一個設定，故分鍵獨立管理
    static let appTextSize = "appTextSize"
    /// 首次設定時明確同意的法律文件版本；條款重大更新時改版號即可重新取得同意
    static let legalAcceptanceVersion = "legalAcceptanceVersion"
    /// 匿名使用統計開關（預設開）：關閉時 Analytics 不記錄也不送出
    static let analyticsEnabled = "analyticsEnabled"
    /// 通知頻率等級（AlertFrequency 的 rawValue）：小＝僅重大只推危險級／中＝標準（預設）／大＝靈敏，連早期未確認線索也推
    static let alertFrequencyLevel = "alertFrequencyLevel"

    // MARK: - 吵醒門檻與勿擾時段（D4：通知自主權）

    /// 吵醒門檻（WakeThreshold 的 rawValue）：標準（現行）／僅重大／絕不吵醒。預設 standard
    static let wakeThreshold = "wakeThreshold"
    /// 是否啟用安靜時段（預設關）
    static let quietHoursEnabled = "quietHoursEnabled"
    /// 安靜時段開始時（0-23，預設 22）
    static let quietStartHour = "quietStartHour"
    /// 安靜時段結束時（0-23，預設 7）；可能小於開始時＝跨夜區間
    static let quietEndHour = "quietEndHour"
    /// 情境式通知權限卡（帶領結束後）是否被使用者按過「先不用」；按過就不再出現這張卡
    static let notificationPromptDeclined = "notificationPromptDeclined"

    // MARK: - 安全地圖圖層記憶（2026-07-24：使用者拍板「預設地圖不要出現避難所」）

    /// 避難收容所圖層開關；預設關（城區帳篷海會干擾主畫面），使用者從圖層選單打開後要記住這個選擇
    static let mapShowShelters = "mapShowShelters"
    /// 急救責任醫院圖層開關；預設關，理由同避難收容所
    static let mapShowHospitals = "mapShowHospitals"
}

/// 吵醒門檻：勿擾／靜音下，時效性通知能不能突破。使用者在設定頁「勿擾與吵醒」調整；
/// 實際攔截集中在 NotificationScheduler.effectiveTimeSensitive（單一收斂點），
/// 降級只影響 interruptionLevel（時效性→一般），**不擋通知本身**——訊息仍會送達，只是不吵醒人。
enum WakeThreshold: String, CaseIterable, Identifiable {
    case standard   // 標準：危險警報都可突破靜音（現行行為）
    case majorOnly  // 僅重大才吵：只有地震／海嘯／火災（家人安否視同重大）才吵醒
    case never      // 絕不吵醒：一律降為一般通知，仍會送達只是不亮屏不出聲

    var id: String { rawValue }

    /// 目前設定值（鍵不存在時預設「標準」，與舊版行為一致）
    static var current: WakeThreshold {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.wakeThreshold)
        return raw.flatMap(WakeThreshold.init(rawValue:)) ?? .standard
    }

    /// 分段控制顯示的短標籤
    var shortLabel: String {
        switch self {
        case .standard: return "標準"
        case .majorOnly: return "重大才吵"
        case .never: return "絕不吵醒"
        }
    }

    /// 「重大」的硬性集合：比 RemoteConfig.dangerKinds（決定要不要推播）更窄，
    /// 這裡決定的是「推播了以後能不能吵醒人」——只有危及生命的災型才有資格突破勿擾。
    /// 刻意寫死不走遠端熱更：吵醒門檻是使用者對 App 的信任紅線，不該被伺服器端設定意外放寬。
    static let majorKinds: Set<String> = ["地震", "海嘯", "火災"]

    /// 是否屬於「重大」：「家人安否」不在字面集合裡，但視同重大——家人不平安值得吵醒。
    static func isMajor(kind: String?) -> Bool {
        guard let kind else { return false }
        return kind == "家人安否" || majorKinds.contains(kind)
    }
}

/// 通知頻率（依事件嚴重度分級）。使用者在 Onboarding 與設定頁可調；
/// 實際過濾集中在 AlertPolicy.evaluate（單一決策點），避免變成「有 UI 卻沒接線」的死開關。
enum AlertFrequency: Int, CaseIterable, Identifiable {
    case low = 0        // 小：只推危險級（火災／地震／海嘯／颱風／公共安全）
    case standard = 1   // 中：危險級＋提醒級（高溫／降雨／停水…）＝預設
    case high = 2       // 大：再放寬到未經官方／多來源確認的早期線索

    var id: Int { rawValue }

    /// 目前設定值（鍵不存在時預設「中」，與舊版行為一致）
    static var current: AlertFrequency {
        let raw = UserDefaults.standard.object(forKey: SettingsKeys.alertFrequencyLevel) as? Int
        return raw.flatMap(AlertFrequency.init(rawValue:)) ?? .standard
    }

    /// 分段控制顯示的短標籤（僅重大／標準／靈敏）
    /// 2026-07-24：實機測試員誤讀成字體大小調整，改名消除與「字體大小」的歧義；
    /// 2026-07-24（第二輪）：「安靜」被誤讀成「靜音」——選了以為警報不會出聲，
    /// 結果火災警報照樣響（此設定只管「推不推」，出不出聲吵醒人是下面「勿擾與吵醒」的事）。
    /// 改名「僅重大」直接講清楚篩的是「事件多寡」；
    /// case 名、rawValue、UserDefaults 儲存格式都不變，只改顯示文字
    var shortLabel: String {
        switch self {
        case .low: return "僅重大"
        case .standard: return "標準"
        case .high: return "靈敏"
        }
    }

    /// 一句話說明目前選擇會收到哪些通知，直接顯示給使用者。
    /// 每段都刻意點出「這裡講的是推不推播，不是吵不吵醒你」，
    /// 避免與下面「勿擾與吵醒」（WakeThreshold）的災型白名單被誤讀成同一件事。
    var explanation: String {
        switch self {
        case .low:
            return "只有火災、地震、海嘯、颱風、公共安全等危險事件才會推播；高溫、降雨、停水等一般提醒只在 App 內顯示。要控制警報會不會出聲吵醒你，請調整下方『勿擾與吵醒』。"
        case .standard:
            return "危險事件會立即推播，高溫、降雨、停水等一般提醒也會推播。多數人適用。這裡只決定推不推播；會不會出聲吵醒你，由下方『勿擾與吵醒』另外決定。"
        case .high:
            return "除了上述，連尚未經官方或多來源確認的早期線索也會推播——更早知道，但可能偶有誤報。同樣地，會不會出聲吵醒你仍由下方『勿擾與吵醒』決定。"
        }
    }
}

/// 全域字體大小。使用者在設定頁「外觀」附近調整；套用點是 App 根視圖（見 HavenCircleApp）
/// 的 .dynamicTypeSize 覆寫，一次套用全樹、所有機型自動適配（xLarge/xxxLarge/accessibility1
/// 都是 SwiftUI 內建的 Dynamic Type 級距，不是自訂 pt 數字，才能吃到系統的無障礙排版邏輯）。
/// 「跟隨系統」＝不覆寫，尊重使用者在 iOS 設定 > 螢幕顯示與亮度 > 文字大小 的選擇。
enum AppTextSize: String, CaseIterable, Identifiable {
    case system      // 跟隨系統（預設）：不覆寫
    case large       // 大：對應 DynamicTypeSize.xLarge
    case extraLarge  // 特大：對應 DynamicTypeSize.xxxLarge
    case huge        // 最大：對應 DynamicTypeSize.accessibility1

    var id: String { rawValue }

    /// 目前設定值（鍵不存在時預設「跟隨系統」，與舊版行為一致——這是新設定，舊使用者不該被意外放大）
    static var current: AppTextSize {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.appTextSize)
        return raw.flatMap(AppTextSize.init(rawValue:)) ?? .system
    }

    /// 分段控制顯示的短標籤
    var shortLabel: String {
        switch self {
        case .system: return "跟隨系統"
        case .large: return "大"
        case .extraLarge: return "特大"
        case .huge: return "最大"
        }
    }

    /// 設定頁列表用的完整標籤；不可只靠「大／特大」這種單字，輔助功能朗讀時會失去語意。
    var label: String {
        switch self {
        case .system: return "跟隨系統"
        case .large: return "較大"
        case .extraLarge: return "特大"
        case .huge: return "最大"
        }
    }

    var detail: String {
        switch self {
        case .system: return "使用 iPhone 系統的文字大小設定"
        case .large: return "適合想稍微放大介面的人"
        case .extraLarge: return "適合需要更高可讀性的人"
        case .huge: return "最大且保留可捲動版面"
        }
    }

    /// 要覆寫的 Dynamic Type 級距；跟隨系統時回 nil（呼叫端看到 nil 就不加 modifier，原樣交還系統）
    var overrideSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .large: return .xLarge
        case .extraLarge: return .xxxLarge
        case .huge: return .accessibility1
        }
    }
}

/// 資料時效：所有會刷新事件資料的路徑都應呼叫這裡
enum DataFreshness {
    static func markRefreshedNow() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: SettingsKeys.lastDataRefresh)
    }
}
