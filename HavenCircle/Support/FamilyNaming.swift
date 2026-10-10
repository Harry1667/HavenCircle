import Foundation

/// 家人名字的單一規則來源：哪些字是「本機顯示用佔位字」、上傳前怎麼清、讀取端怎麼補。
///
/// 為什麼需要：以前使用者沒被要求輸入名字，App 拿「我」「家人」「圈主」頂替並上傳到 Firestore，
/// 家人那邊就看到一位叫「我」的成員。鐵則：**佔位字只能存在於顯示端，絕不寫進雲端**。
enum FamilyNaming {
    /// 本機顯示用的佔位字（含「家人 3」這種讀取端補的編號）。出現在雲端＝舊版 bug 留下的髒資料。
    static let placeholderNames: Set<String> = [
        "我", "家人", "圈主", "家庭成員", "一位家人", "本人", "自己", "擁有者"
    ]

    static func isPlaceholder(_ raw: String?) -> Bool {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if placeholderNames.contains(trimmed) { return true }
        // 「家人 1」「家人2」：讀取端補的編號，不是真名
        if trimmed.hasPrefix("家人") {
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// 上傳／比對前的清洗：佔位字一律變空字串（空字串＝「沒有名字」，由讀取端顯示 fallback）。
    static func clean(_ raw: String?) -> String {
        isPlaceholder(raw) ? "" : (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本人要上傳到雲端的名字：本名優先，沒有本名才用家庭身分（爸爸／媽媽…）；都沒有回空字串。
    static func ownUploadName(defaults: UserDefaults = .standard) -> String {
        let name = clean(defaults.string(forKey: SettingsKeys.profileDisplayName))
        if !name.isEmpty { return name }
        return clean(defaults.string(forKey: SettingsKeys.profileFamilyRole))
    }

    /// 本人是否已有可上傳的真名／稱呼（決定要不要彈 NamePromptSheet）
    static var hasOwnName: Bool { !ownUploadName().isEmpty }

    /// 讀取端 fallback 標籤：「家人 1」「家人 2」（number 從 1 起算）
    static func fallbackLabel(number: Int) -> String { "家人 \(max(number, 1))" }
}
