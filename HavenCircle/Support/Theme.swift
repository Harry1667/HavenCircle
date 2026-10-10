import SwiftUI
import UIKit

// MARK: - 設計 token 層
// 三方設計討論（2026-07-16）的共識產物：視覺方向「沉著守護」——
// 平時 90% 畫面用低彩度品牌色與中性色，只有真正的危險才用警示色；
// 「事件類型」用圖示表達、「可信度」用顏色表達，兩套視覺通道不互搶。
// 所有畫面的顏色、間距、圓角一律取自這裡，不再各自硬編。

extension Color {
    /// 深淺模式雙色（0xRRGGBB）——暗色不是亮色反相，而是獨立調過對比的色值
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 語意色票：命名說「用途」不說「顏色」，之後換色不用改呼叫端
enum HCColor {
    /// 地圖「顯示範圍」縣市外框高光（金色）；搭配「顯示範圍：…」文字膠囊，不單靠顏色傳達
    static let countyHighlight = Color(red: 0.96, green: 0.78, blue: 0.25)
    /// 品牌主色：CTA、選取狀態、生活圈。依 App 外觀取值（層次＝深群青，與 AccentColor.colorset 同值；
    /// 晴空湖水＝天藍）。每次讀目前外觀，切換外觀後重建的畫面立刻拿到新色。
    static var brand: Color { AppAppearance.current.palette.brand }
    /// 次要強調（守護範圍線、小標籤）：層次沿用品牌色，晴空湖水為湖水青
    static var accent2: Color { AppAppearance.current.palette.secondary }
    /// 頁面底色：層次＝系統群組底，晴空湖水＝冷白／深靛
    static var pageBackground: Color { AppAppearance.current.palette.background }
    /// 實色狀態方塊（圖示方塊）上的符號色：淺色模式白字；深色模式的狀態色偏亮，白字對比不足，改近黑
    static let onStatus = Color(light: 0xFFFFFF, dark: 0x14161C)
    /// 無需注意、回報平安、操作成功。兩種外觀共用同一個值（狀態語意不隨外觀變）。
    /// 2026-10-11 依晴空湖水規格改為 0x0F8A5C／0x1F9D6E：往黃綠側推（色相約 152°），
    /// 與湖水青（182°）拉開；層次外觀也共用，「家人收到的已報平安」在兩種外觀下顏色一致。
    /// 色相仍與 medical（0x0E7C86，偏青）保持距離，地圖上盾牌與醫院標記不混淆
    static let safe = Color(light: 0x0F8A5C, dark: 0x1F9D6E)
    /// 確認中、需留意、時段外。深色值刻意偏橘（0xFFAF52）：
    /// 與 notice 的黃（0xF5D76E）拉開色相，深色模式下兩階才分得出來
    static let attention = Color(light: 0xA96400, dark: 0xFFAF52)
    /// 明確危險、官方確認的警報
    static let danger = Color(light: 0xC83E3E, dark: 0xFF8A80)
    /// 區域警報最低層級（留意/提醒）的塗色——比 attention 再低一階
    static let notice = Color(light: 0xB89500, dark: 0xF5D76E)
    /// 統計參考圖層（治安等歷史資料）：刻意用冷色與紅橙色系的「即時警示」區隔
    static let reference = Color(light: 0x5856D6, dark: 0x7D7AFF)
    /// 醫療資源（急救責任醫院）標記
    static let medical = Color(light: 0x0E7C86, dark: 0x5BC8D2)
}

/// 間距刻度：4 的倍數，卡片內距一律 x4（16pt）
enum HCSpacing {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x6: CGFloat = 24
}

/// 圓角只留五檔——全 App 圓角不一致是「各畫面各自發明卡片」的主因
enum HCRadius {
    /// 列表行首的小型 icon 徽章
    static let badge: CGFloat = 8
    static let chip: CGFloat = 12
    static let control: CGFloat = 16
    static let card: CGFloat = 16
    static let sheet: CGFloat = 28
}

/// 外觀模式：使用者可在設定頁強制淺色／深色，預設跟隨系統。
/// rawValue 存在 UserDefaults（SettingsKeys.appearanceMode），根視圖以 preferredColorScheme 套用
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "跟隨系統"
        case .light: "淺色"
        case .dark: "深色"
        }
    }

    /// nil = 不強制，交還給系統設定
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 全域外觀：導航標題改圓體（SF Rounded）——「沉著守護」的柔和感從標題字型貫穿全 App，
/// 一次設定所有 NavigationStack 生效，不用每頁各自改
enum HCAppearance {
    static func apply() {
        let navBar = UINavigationBar.appearance()
        navBar.largeTitleTextAttributes = [.font: roundedFont(style: .largeTitle, weight: .bold)]
        navBar.titleTextAttributes = [.font: roundedFont(style: .headline, weight: .semibold)]
    }

    /// 取系統動態字級的尺寸，再套 rounded design——直接指定 pointSize 會失去「放大字體」的無障礙支援
    private static func roundedFont(style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// 保留 icon 又能置中的按鈕標籤：直接對 SwiftUI 內建 `Label` 套 `.frame(maxWidth: .infinity)`
/// 會讓 SF Symbol 消失、只剩文字（2026-07「按鈕文字置中」commit 撞到的反模式，#9）。
/// 改用手動 HStack＋左右 Spacer 達成「置中且圖示不消失」，家人頁重設計時修好的幾處置中鈕
/// 都改用這個共用元件，避免各檔各自重蹈覆轍。
struct HCCenteredLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack {
            Spacer()
            Image(systemName: systemImage)
            Text(title)
            Spacer()
        }
    }
}

extension View {
    /// 統一卡片（層次風格）：`.regularMaterial` 單層＋極淡描邊與陰影，兩種外觀共用。
    /// 卡片內不再放第二層 Material（疊 Material 會掉幀且對比不足）；
    /// 要染色（例如警報底色）請用實色 fill，不要再疊材質。
    func hcCard() -> some View {
        self
            .padding(HCSpacing.x3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    /// 頁面底：外觀頁面色＋頂端淡染色漸層（用在沒有專屬頁首背景的頁面，如家人頁）。
    /// 同時隱藏 List 預設底色，讓這層底透出來。
    func hcPageBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(alignment: .top) { HCPageBackdrop() }
    }
}

// MARK: - 區域警報嚴重度的視覺對應（單一事實來源：警報卡、地圖塗層、圖例共用）

extension RegionAlert {
    /// 嚴重度排序：危急(3)＞警戒(2)＞注意(1)＞留意/提醒(0)。NCDR severity 是封閉集合。
    static func severityRank(_ severity: String) -> Int {
        switch severity {
        case "危急": 3
        case "警戒": 2
        case "注意": 1
        default: 0
        }
    }

    /// 嚴重度顏色：危急/警戒＝danger、注意＝attention、其餘＝notice。
    /// 警報卡與地圖塗層必須同一套，使用者才能把「卡片的紅」和「地圖的紅」對起來。
    static func severityColor(rank: Int) -> Color {
        switch rank {
        case 2...: HCColor.danger
        case 1: HCColor.attention
        default: HCColor.notice
        }
    }

    var severityRank: Int { Self.severityRank(severity) }
    var severityColor: Color { Self.severityColor(rank: severityRank) }
}

// MARK: - 事件分類的視覺對應（圖示＝類型、顏色＝可信度，分工明確）

extension EventCategory {
    /// 類型圖示：只用歷代都有的 SF Symbols，避免舊系統開天窗
    static func icon(for type: String) -> String {
        switch type {
        case fire: "flame.fill"
        case traffic: "car.fill"
        case disaster: "cloud.bolt.rain.fill"
        case publicSafety: "exclamationmark.shield.fill"
        // 對標 Beacon 後補上的細分類圖示——每種事件有專屬圖示，不再全部套用同一個盾牌
        case knifeAttack: "bandage.fill"
        case shooting: "burst.fill"
        case disturbance: "person.3.fill"
        case harassment: "hand.raised.slash.fill"
        case suspiciousPerson: "person.fill.questionmark"
        case animalAttack: "pawprint.fill"
        case injuredAnimal: "stethoscope"
        case gasLeak: "smoke.fill"
        case explosion: "bolt.fill"
        case emergencyMedical: "cross.fill"
        case trainIncident: "tram.fill"
        case metroIncident: "bus.fill"
        case earthquake: "waveform"
        case flood: "water.waves"
        case landslide: "mountain.2.fill"
        case powerOutage: "bolt.slash.fill"
        case waterOutage: "drop.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    /// 「類型色」兩層色彩紀律的單一判斷來源：危及生命的危險級（RemoteConfig.isDangerKind：
    /// 火災、公共安全、地震、海嘯、颱風）＝ danger（紅）；其餘留意/行政級（空品、停水、
    /// 高溫、降雨…）＝ attention（琥珀）。刻意與「狀態色」（進行中/已結束，見
    /// LocalSafetyEvent.statusText／isEnded）完全分開判斷、互不參照——類型色回答「這個類型
    /// 本質上多危險」，狀態色回答「這件事現在還在不在發生」，兩件事不該共用同一個屬性。
    /// 點狀事件（eventType）與區域警報（RegionAlert.kind）兩個命名空間字串不重疊，
    /// 這個函式對兩者都能直接呼叫——詳情頁與（未來）地圖共用同一套判斷，紅/黃分級才對得起來。
    static func typeColor(for type: String) -> Color {
        RemoteConfig.isDangerKind(type) ? HCColor.danger : HCColor.attention
    }
}

/// 頁面底＋頂端淡染色（隨外觀）。純色加一層漸層，沒有 Material，也不動。
struct HCPageBackdrop: View {
    var body: some View {
        let palette = AppAppearance.current.palette
        ZStack(alignment: .top) {
            palette.background
            LinearGradient(colors: [palette.wash, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
