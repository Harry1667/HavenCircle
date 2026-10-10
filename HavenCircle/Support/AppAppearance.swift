import SwiftUI

// 配色（晴空湖水）已併入 Theme.swift 的 HCColor；本檔只留頁首天空的時段與色票。

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
