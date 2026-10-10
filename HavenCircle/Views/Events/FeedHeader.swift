import SwiftUI
import UIKit

// 動態頁頁首：兩種外觀共用一個入口 FeedHeaderBackdrop，內部依外觀切換——
// - 層次：守護範圍靜態地圖快照（無守護範圍／快照失敗時退回柔和漸層）
// - 晴空湖水：隨時段變色的天空（單層漸層＋夜晚星點＋附近有狀況時的琥珀光暈）
// 兩者都是裝飾（accessibilityHidden），資訊一律由旁邊的文字膠囊與卡片承載。
// 效能：背景只畫一層、不放即時 Map、不疊 Material；捲動時只改 opacity，
// 且捲動進度放在獨立的 @Observable，不會讓整個 EventListView 跟著每幀重算。

/// 捲動淡出進度（0＝完全顯示，1＝完全淡出）。獨立成參考型別：只有 FeedHeaderBackdrop 讀它，
/// 更新時不會觸發 EventListView 的 body（內有事件分類，很貴）。
@Observable
final class FeedHeaderFade {
    private(set) var progress: Double = 0
    /// 頁首列靜止（列表在最頂端）時的 minY。
    /// 2026-10-11 模擬器：原本取歷史最大值，冷啟動版面還沒定位時的暫時位置偏低，基準被拉歪，
    /// 回到頂端後天空已淡出九成。改為「捲回頂端後校準一次」，校準前不淡出；下拉回彈不改基準
    private var restY: CGFloat?
    private var lastMinY: CGFloat = .nan

    /// 列表剛捲到最頂端時呼叫：以當下位置為靜止基準
    func calibrate() {
        guard lastMinY.isFinite else { return }
        restY = lastMinY
        if progress != 0 { progress = 0 }
    }

    func update(minY: CGFloat) {
        guard minY.isFinite else { return }
        lastMinY = minY
        guard let restY else { return }
        // 捲過約 140pt 完全淡出；量化到 0.02 一格，避免每個像素都觸發重繪
        let raw = min(max(Double((restY - minY) / 140), 0), 1)
        let quantized = (raw * 50).rounded() / 50
        if quantized != progress { progress = quantized }
    }
}

private struct FeedHeaderMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next.isFinite { value = next }
    }
}

/// 守護範圍地圖快照的輸入（本人守護範圍的圈心與半徑）
struct GuardAreaCenter: Hashable {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
}

// MARK: - 頁首列（List 第一列：提供捲動基準＋注意事件文字膠囊）

struct FeedHeaderRow: View {
    let hasAttention: Bool
    let fade: FeedHeaderFade

    /// 自繪大標題：系統大標題在 iOS 17 不吃 toolbarColorScheme，夜晚深靛天空上會是黑字看不清，
    /// 所以改由頁首列自己畫；深色天空用白字，其餘跟系統主文字色
    private var titleColor: Color {
        AppAppearance.current == .skyLagoon && SkyPhase.current().isDarkSky ? .white : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x2) {
            Text("動態")
                .font(.largeTitle.bold())
                .foregroundStyle(titleColor)
                .accessibilityAddTraits(.isHeader)
            HStack {
                if hasAttention { AttentionPill() }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: hasAttention ? 40 : 8)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: FeedHeaderMinYKey.self, value: geo.frame(in: .global).minY)
            }
        )
        .onPreferenceChange(FeedHeaderMinYKey.self) { fade.update(minY: $0) }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: HCSpacing.x4, bottom: 0, trailing: HCSpacing.x4))
    }
}

/// 導覽列的小標題：頁首大標題捲走（天空淡出）時才淡入，任何時候都知道自己在哪一頁。
/// 獨立成小 view：只有它讀捲動進度，捲動時不會重算整個 EventListView
struct FeedInlineTitle: View {
    let fade: FeedHeaderFade
    var body: some View {
        Text("動態")
            .font(.headline)
            .opacity(fade.progress)
            .accessibilityHidden(true)
    }
}

/// 「守護範圍內有需要注意的事件」：圖示＋文字＋琥珀色，不單靠顏色；
/// 底用實色（不是 Material），疊在天空／地圖上也看得清。
struct AttentionPill: View {
    var body: some View {
        Label("守護範圍內有需要注意的事件", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(HCColor.attention)
            .padding(.horizontal, HCSpacing.x3)
            .padding(.vertical, 6)
            .background(Color(.systemBackground).opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(HCColor.attention.opacity(0.45), lineWidth: 1))
            .accessibilityIdentifier("feed.attentionPill")
    }
}

// MARK: - 頁首背景（List 後方，固定在頂端）

struct FeedHeaderBackdrop: View {
    let appearance: AppAppearance
    let hasAttention: Bool
    let guardArea: GuardAreaCenter?
    let fade: FeedHeaderFade

    var body: some View {
        Group {
            switch appearance {
            case .layered: MapSnapshotBackdrop(area: guardArea)
            case .skyLagoon: SkyBackdrop(hasAttention: hasAttention)
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        // 底端漸隱進頁面底色，避免硬邊
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .opacity(1 - fade.progress)
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - 晴空湖水：隨時間變色的天空

private struct SkyBackdrop: View {
    let hasAttention: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 每分鐘重算一次時段（時段邊界最多晚一分鐘切換）；時段不變時內容 identity 不變，不會重畫動畫
        TimelineView(.everyMinute) { context in
            let phase = SkyPhase.current(at: context.date)
            ZStack {
                // 單層漸層；時段切換用 .id＋opacity 轉場淡接（減少動態時直接換）
                LinearGradient(colors: phase.colors(dark: colorScheme == .dark), startPoint: .top, endPoint: .bottom)
                    .id(phase)
                    .transition(.opacity)
                if phase == .night { StarField() }
                if hasAttention {
                    // 琥珀光暈永遠搭文字膠囊，光暈本身不是狀態
                    RadialGradient(
                        colors: [HCColor.attention.opacity(0.55), .clear],
                        center: .topTrailing, startRadius: 0, endRadius: 220
                    )
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: phase)
        }
    }
}

/// 夜晚星點：固定座標（不隨機、不閃爍），一次 Canvas 畫完
private struct StarField: View {
    /// (x 比例, y 比例, 半徑, 不透明度)——手排 18 顆，集中在上半部
    private static let stars: [(Double, Double, Double, Double)] = [
        (0.06, 0.10, 1.2, 0.9), (0.14, 0.32, 0.8, 0.6), (0.22, 0.18, 1.4, 0.85), (0.31, 0.07, 0.9, 0.7),
        (0.38, 0.36, 1.0, 0.55), (0.47, 0.15, 1.3, 0.9), (0.55, 0.28, 0.8, 0.6), (0.62, 0.06, 1.1, 0.8),
        (0.69, 0.22, 0.9, 0.65), (0.76, 0.12, 1.5, 0.9), (0.83, 0.33, 0.8, 0.5), (0.90, 0.20, 1.2, 0.8),
        (0.95, 0.07, 0.9, 0.7), (0.10, 0.45, 0.8, 0.4), (0.27, 0.50, 0.9, 0.4), (0.51, 0.46, 0.8, 0.35),
        (0.73, 0.47, 0.9, 0.4), (0.88, 0.52, 0.8, 0.35),
    ]

    var body: some View {
        Canvas { context, size in
            for (x, y, r, a) in Self.stars {
                let rect = CGRect(x: x * size.width - r, y: y * size.height - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(a)))
            }
        }
    }
}

// MARK: - 層次：守護範圍地圖快照

private struct MapSnapshotBackdrop: View {
    let area: GuardAreaCenter?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    private struct TaskKey: Hashable {
        let area: GuardAreaCenter?
        let width: Int
        let isDark: Bool
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 沒有快照時的底：柔和品牌漸層（無守護範圍、尚在產生、產生失敗都是這個）
                LinearGradient(
                    colors: [HCColor.brand.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // 去飽和＋調淡：地圖只是脈絡，不能搶過卡片
                        .saturation(0.4)
                        .opacity(colorScheme == .dark ? 0.30 : 0.38)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: TaskKey(area: area, width: Int(geo.size.width), isDark: colorScheme == .dark)) {
                await loadSnapshot(width: Int(geo.size.width))
            }
        }
    }

    private func loadSnapshot(width: Int) async {
        guard let area, width > 0 else { image = nil; return }
        let request = MapSnapshotStore.Request(
            latitude: area.latitude, longitude: area.longitude, radiusMeters: area.radiusMeters,
            width: width, height: 300, isDark: colorScheme == .dark
        )
        let stroke = UIColor(HCColor.brand).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        )
        let result = await MapSnapshotStore.image(for: request, stroke: stroke)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { image = result }
    }
}
