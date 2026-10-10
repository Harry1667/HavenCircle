import SwiftUI

// MARK: - 兩種可切換外觀（層次／晴空湖水）
// 設計背景（2026-10-11）：使用者決定「層次」與「晴空湖水」兩種都做、App 內可切換，比較後再留一個。
// 兩者共用同一套層次版面與元件，只換「情緒色」（品牌／次要強調／頁面底／家人色盤）與動態頁頁首：
// - 層次：品牌藍沿用舊 HCColor；頁首是守護範圍的靜態地圖快照。
// - 晴空湖水：天藍＋湖水青；頁首是隨時段變色的天空。
// 狀態色（danger／attention／safe／medical…）兩外觀完全共用，不隨外觀變——紅、琥珀、綠只有一種解讀。

enum AppAppearance: String, CaseIterable, Identifiable {
    case layered
    case skyLagoon

    var id: String { rawValue }

    /// 預設外觀：晴空湖水
    static let `default`: AppAppearance = .skyLagoon

    var label: String {
        switch self {
        case .layered: "層次"
        case .skyLagoon: "晴空湖水"
        }
    }

    /// 目前外觀。每次直接讀 UserDefaults（鍵不存在＝預設），與 @AppStorage 讀的是同一份，
    /// 不另存快取，才不會出現「設定改了但 HCColor 還讀舊值」的雙份真相。
    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: SettingsKeys.appAppearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .default
    }

    var palette: AppPalette {
        switch self {
        case .layered: AppPalette.layered
        case .skyLagoon: AppPalette.skyLagoon
        }
    }
}

/// 外觀相依的「情緒色」。狀態色不在這裡（見 HCColor）。
struct AppPalette {
    /// 品牌主色：CTA、選取、全 App `.tint`
    let brand: Color
    /// 次要強調：守護範圍線、小標籤（層次沿用品牌色，晴空湖水用湖水青）
    let secondary: Color
    /// 頁面底色
    let background: Color
    /// 頁首淡染色（家人頁等沒有專屬頁首背景的頁面，頂端漸層用）
    let wash: Color
    /// 家人色盤：索引 0 保留給本人，其餘依穩定 hash 分配（見 CircleColorPalette）
    let familyColors: [Color]

    static let layered = AppPalette(
        brand: Color(light: 0x3657D6, dark: 0x89A0FF),
        secondary: Color(light: 0x3657D6, dark: 0x89A0FF),
        background: Color(uiColor: .systemGroupedBackground),
        wash: Color(light: 0x3657D6, dark: 0x89A0FF).opacity(0.14),
        familyColors: [
            HCColor.safe, // 0：本人專屬，沿用平安綠語意
            Color(hue: 0.58, saturation: 0.68, brightness: 0.88), // 天藍（約 209°）
            Color(hue: 0.70, saturation: 0.55, brightness: 0.72), // 藍紫（約 252°）
            Color(hue: 0.80, saturation: 0.55, brightness: 0.78), // 紫（約 288°）
            Color(hue: 0.875, saturation: 0.55, brightness: 0.82), // 洋紅（約 315°）
            Color(hue: 0.94, saturation: 0.50, brightness: 0.85), // 玫瑰粉（約 338°）
        ]
    )

    /// 晴空湖水 tokens（設計比較頁「配色 A」）。五個家人色全落在青→藍→紫，避開紅／琥珀／綠；
    /// 本人固定湖水青（＝次要強調色），其餘四色依穩定 hash 分配。
    static let skyLagoon = AppPalette(
        brand: Color(light: 0x2E86FF, dark: 0x6FAEFF),
        secondary: Color(light: 0x19C3C9, dark: 0x4DD8DC),
        background: Color(light: 0xF3F7FC, dark: 0x0E1630),
        wash: Color(light: 0x2E86FF, dark: 0x6FAEFF).opacity(0.14),
        familyColors: [
            Color(light: 0x19C3C9, dark: 0x4DD8DC), // 我：湖水青
            Color(light: 0x2E86FF, dark: 0x5EA5FF), // 爸爸：天藍
            Color(light: 0x7A5AF8, dark: 0xA08CFF), // 媽媽：紫
            Color(light: 0xC45AE8, dark: 0xDA8CFF), // 妹妹：洋紅紫
            Color(light: 0x0F7A96, dark: 0x3FB1D1), // 阿嬤：深青
        ]
    )
}

// MARK: - 天空時段

/// 頁首天空的四個時段。天空只是情緒、不是資訊：任何停靠點都不帶狀態色（紅／琥珀／綠），
/// 傍晚的珊瑚粉彩度刻意壓低，避免被讀成紅色警報。
enum SkyPhase: String, CaseIterable {
    case dawn, day, dusk, night

    /// 依小時分段：清晨 05–08、白天 08–17、傍晚 17–19、夜晚 19–05
    static func phase(at date: Date, calendar: Calendar = .current) -> SkyPhase {
        switch calendar.component(.hour, from: date) {
        case 5..<8: .dawn
        case 8..<17: .day
        case 17..<19: .dusk
        default: .night
        }
    }

    /// 目前時段。測試參數 `--force-sky-period dawn|day|dusk|night` 可強制指定（僅 DEBUG 編入，發佈版永遠依時鐘）
    static func current(at date: Date = .now) -> SkyPhase {
        #if DEBUG
        if let forced = debugForced { return forced }
        #endif
        return phase(at: date)
    }

    #if DEBUG
    private static let debugForced: SkyPhase? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--force-sky-period"), i + 1 < args.count else { return nil }
        return SkyPhase(rawValue: args[i + 1])
    }()
    #endif

    /// 夜晚天空是深靛：標題與狀態列要改白字（淺色外觀的使用者在夜晚也看到深靛天空）
    var isDarkSky: Bool { self == .night }

    /// 由上到下三個停靠點。深色模式用調暗的版本（底端一律收進深靛底色 #0E1630）。
    func colors(dark: Bool) -> [Color] {
        switch (self, dark) {
        case (.dawn, false): [Color(rgb: 0xFFD2C0), Color(rgb: 0xE6E3F2), Color(rgb: 0xB9DBFF)]
        case (.day, false): [Color(rgb: 0x3D8FFF), Color(rgb: 0x8FC4FF), Color(rgb: 0xD4EAFF)]
        case (.dusk, false): [Color(rgb: 0xB9A8E8), Color(rgb: 0xE4BFC4), Color(rgb: 0xF4E3E0)]
        case (.dawn, true): [Color(rgb: 0x6A4A5E), Color(rgb: 0x2E2F5C), Color(rgb: 0x0E1630)]
        case (.day, true): [Color(rgb: 0x2A5CC4), Color(rgb: 0x1B3A8A), Color(rgb: 0x0E1630)]
        case (.dusk, true): [Color(rgb: 0x5B4A8F), Color(rgb: 0x3B2F66), Color(rgb: 0x0E1630)]
        case (.night, _): [Color(rgb: 0x1E3F9E), Color(rgb: 0x15296B), Color(rgb: 0x0E1630)]
        }
    }

    /// 給輔助功能朗讀用的時段名稱（天空本身 accessibilityHidden，這只在 UI 測試 identifier 用）
    var label: String {
        switch self {
        case .dawn: "清晨"
        case .day: "白天"
        case .dusk: "傍晚"
        case .night: "夜晚"
        }
    }
}

extension Color {
    /// 單一不分深淺的實色（0xRRGGBB）
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - 測試／除錯啟動參數

enum AppearanceLaunchArguments {
    /// `--appearance layered|skyLagoon`：啟動時直接套用指定外觀（寫入 UserDefaults，與設定頁同一份）。
    /// 僅 DEBUG 編入——發佈版不解析任何啟動參數，使用者無從被參數改掉外觀。
    static func applyIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--appearance"), i + 1 < args.count else { return }
        guard let appearance = AppAppearance(rawValue: args[i + 1]) else {
            AppLog.dataError("--appearance 參數無法辨識：\(args[i + 1])（可用：layered、skyLagoon）")
            return
        }
        UserDefaults.standard.set(appearance.rawValue, forKey: SettingsKeys.appAppearance)
        #endif
    }
}
