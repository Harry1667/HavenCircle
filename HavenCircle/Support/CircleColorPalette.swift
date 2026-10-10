import SwiftUI

/// 地圖上每個「守護對象」（家人／地點）的專屬顏色。
///
/// 背景：舊版地圖只依「圈的類型」上色——所有人的即時圈都是同一種綠、所有固定地點
/// 都是同一種藍，多個家人同時顯示時完全分不清哪個圈是誰的。2026-07-24 使用者拍板
/// 「不同的圈子給不同的顏色」，改成依「人」而非「類型」上色。
///
/// 設計：
/// - 色盤第一格保留給「本人」，沿用既有的 HCColor.safe 綠色語意（使用者已經習慣
///   這個顏色代表自己），本人的圈（不論即時或固定）一律顯示這個綠色。
/// - 其餘成員依穩定鍵（優先用 LocalFamilyMember.memberKey，沒有 member 時退回
///   LocalLifeCircle.circleKey；兩者都是 SwiftData `@Attribute(.unique)` 的持久字串 id）
///   算 hash 取色，同一個人／圈每次開 App 顏色都一樣；不同人碰撞機率低，碰撞可接受（規格明訂）。
/// - 刻意避開紅／橙／黃：RegionAlert 嚴重度用色是「危急＝紅、注意＝橙、留意＝黃」
///   （見 Theme.swift severityColor），事件 pin 也是紅／琥珀色系；圈的顏色若落在這些
///   色相，使用者會把「誰的圈」跟「多嚴重的警報」搞混——這是本色盤唯一的硬性排除規則。
///   2026-07-24 追加：連系統 `.brown`（棕）也移除——它跟 `HCColor.attention`（琥珀／棕橙）
///   的色相太近，20 人冷啟動走查裡有人把「某人的圈」誤讀成「有需要注意的事件」。
/// - 2026-07-24：改用 `Color(hue:saturation:brightness:)` 自訂 5 色（不再用系統具名色），
///   刻意把色相集中在藍→紫→洋紅這段「冷色系」，並讓相鄰色相距至少 35°——
///   舊色盤的 `.teal`（約 178°）跟 `.indigo`（約 241°）之間還夾著 `.blue`（約 211°）跟
///   `.purple`（約 280°），四色全部擠在藍紫色系一小段，加上飽和度/亮度雷同，
///   使用者回報「藍色系圈全部長得差不多」。新色盤明度／飽和度也刻意錯開，
///   即使色弱也還能靠明暗分辨。
/// - 「即時位置已過期」的灰色語意不變，過期判斷在呼叫端（SafetyMapView）用
///   `renderedColor = isActiveForAlerts ? color : .gray` 蓋掉這裡算出的顏色，不受本色盤影響。
enum CircleColorPalette {
    /// 索引 0 保留給本人；其餘依 hash 分給其他成員。色盤見 HCColor.familyColors：
    /// 層次沿用上面描述的冷色五色，晴空湖水為「我＝湖水青＋四個青→藍→紫」。
    /// 每次讀目前外觀，所以切換外觀後地圖圈與頭像一起換色。
    static var colors: [Color] { HCColor.familyColors }

    /// 依「穩定鍵」與「是否本人」取色。
    /// - Parameters:
    ///   - key: 這個人／圈的持久 id 字串（member.memberKey 或退回 circle.circleKey）。
    ///   - isCurrentUser: 是不是本人；本人固定拿綠色，不受 hash 影響。
    static func color(for key: String, isCurrentUser: Bool) -> Color {
        let colors = Self.colors
        guard !isCurrentUser else { return colors[0] }
        let candidateCount = colors.count - 1 // 扣掉本人專屬的索引 0
        guard candidateCount > 0 else { return colors[0] }
        let bucket = Int(stableHash(key) % UInt64(candidateCount))
        return colors[1 + bucket]
    }

    /// 穩定字串 hash（djb2 變體）。
    /// 不能用 Swift 內建的 `String.hashValue`／`Hasher`：兩者都會依處理程序隨機種子
    /// 打散（防雜湊洪水攻擊的設計），同一個字串在不同次 App 啟動會算出不同值——
    /// 那樣「同一個圈每次開 App 顏色一致」的規格就做不到，所以自己刻一個不受隨機種子
    /// 影響的版本，只吃 UTF8 bytes 累加，天生就是決定性的。
    private static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in s.utf8 {
            hash = (hash << 5) &+ hash &+ UInt64(byte) // hash*33 + byte，經典 djb2
        }
        return hash
    }
}
