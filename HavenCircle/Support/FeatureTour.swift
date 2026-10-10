import SwiftUI
import UIKit
import os // Swift 6.2 MemberImportVisibility：用 os.Logger 插值的檔案必須自行 import

// MARK: - 功能導覽（coach marks）
// 半透明遮罩＋聚光燈挖洞，逐步介紹安心、地圖與家人頁的主要使用流程。
// 觸發：Onboarding 完成後首次進主畫面（homeTourPending 旗標消耗制）；設定頁可重看。

/// 導覽目標：目標元件用 .tourAnchor(_:) 登記自己的位置，遮罩層據此挖洞
enum TourTarget: String {
    case statusHero
    case familyList
    case historyRow
    case checkInButton
    /// 分頁列是 TabView 私有結構拿不到 anchor，用畫面底部矩形近似
    case tabBar
    /// Map 與主要內容使用實際 anchor；系統 toolbar 無法直接取 anchor 時才用安全區域降級推算
    case mapCanvas
    case mapControls
    case familyContent
}

extension Notification.Name {
    /// 導覽步驟切換時廣播目標：目標所在頁面（如安心頁的 ScrollView）收到後
    /// 先把目標捲進畫面，聚光燈才有正確的錨點矩形可框
    static let tourStepTargetChanged = Notification.Name("tourStepTargetChanged")
}

struct TourStep {
    let target: TourTarget
    let tab: Int
    let title: String
    let message: String
}

/// 收集各目標元件位置的 PreferenceKey（由子視圖向上匯報）
struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourTarget: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 把自己登記為導覽目標
    func tourAnchor(_ target: TourTarget) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// 挖洞遮罩：全畫面黑底＋目標區圓角開窗（even-odd 填色）
private struct CutoutMask: Shape {
    var cutout: CGRect
    /// 挖洞範圍可動畫：聚光燈在步驟間「滑」過去，而不是瞬間跳位
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(cutout.origin.x, cutout.origin.y),
                AnimatablePair(cutout.size.width, cutout.size.height)
            )
        }
        set {
            cutout = CGRect(
                x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second
            )
        }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 16, height: 16), style: .continuous)
        return path
    }
}

struct FeatureTourView: View {
    let anchors: [TourTarget: Anchor<CGRect>]
    /// nil＝導覽未進行；由 AppTabs 持有
    @Binding var stepIndex: Int?
    /// 導覽跨到下一個一級頁面時，同步驅動 TabView 自動切頁
    @Binding var selectedTab: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var isCardFocused: Bool

    private static let allSteps: [TourStep] = [
        .init(target: .statusHero, tab: TabRouter.homeTab, title: "一眼看到全家狀態",
              message: "打開 App 第一眼就會用文字告訴你：警戒圈是否平安、是否有事件靠近，以及即時位置是否超過 15 分鐘沒有回報。"),
        // 背景看守列已被安心頁事件串取代，2026-07-23：這一步整步移除，不再介紹「背景看守」，
        // 事件串本身用途夠直覺（點列開詳情），不需要專門一步導覽
        .init(target: .historyRow, tab: TabRouter.homeTab, title: "回顧過去 30 天",
              message: "查看警戒圈周遭最近一個月的事件統計與紀錄，了解這個區域平時的安全樣貌。"),
        .init(target: .mapCanvas, tab: TabRouter.mapTab, title: "安全地圖",
              message: "地圖同時呈現家人主動分享的即時圈、你儲存的守護地點、官方警報範圍與事件位置；每個即時圈都會標示最後更新時間。"),
        .init(target: .familyContent, tab: TabRouter.familyTab, title: "管理家人與守護地點",
              message: "邀請家人加入、開啟自己的即時位置分享，或新增住家、倉庫等守護地點；每位家人都必須在自己的手機上同意位置分享。"),
        .init(target: .checkInButton, tab: TabRouter.homeTab, title: "回報平安，完成導覽",
              message: "一鍵告訴全家「我平安」，也可只在送出當下附上一次位置。完成後會留在安心總覽；下一步可到「家人」邀請成員。"),
    ]

    /// 跨頁目標不能用當下頁面的 anchors 篩掉，否則尚未切入的頁面永遠不會被介紹。
    private var steps: [TourStep] {
        Self.allSteps
    }

    var body: some View {
        GeometryReader { proxy in
            let _ = {
                let anchoredTargets: [TourTarget] = [.statusHero, .historyRow, .mapCanvas, .familyContent, .checkInButton]
                let missing = anchoredTargets.filter { anchors[$0] == nil }
                if !missing.isEmpty {
                    AppLog.pipeline.info("導覽缺錨點：\(missing.map(\.rawValue).joined(separator: ","))")
                }
            }()
            if let index = stepIndex, steps.indices.contains(index) {
                let step = steps[index]
                let rect = cutoutRect(for: step.target, in: proxy)
                ZStack(alignment: .topLeading) {
                    CutoutMask(cutout: rect)
                        .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture { advance() } // 點遮罩任意處＝下一步
                    // 聚光邊框：讓被介紹的元件在黑幕上發亮
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                    card(step: step, index: index, near: rect, in: proxy)
                }
                .transition(.opacity)
                .accessibilityAddTraits(.isModal)
                // 錨點在頁面渲染後才註冊；rect 從降級推算換成實際位置時要用滑動而非跳動
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rect)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: stepIndex)
        .onAppear {
            // 從中途步驟啟動（--tour-step）時要先切到該步所屬分頁
            if let index = stepIndex, steps.indices.contains(index) {
                selectedTab = steps[index].tab
            }
            focusCurrentCard()
            broadcastTarget()
        }
        .onChange(of: stepIndex) { _, newValue in
            guard newValue != nil else { return }
            focusCurrentCard()
            broadcastTarget()
        }
    }

    /// 目標挖洞範圍：優先使用實際 anchor；只有系統私有容器才以安全區域降級推算。
    /// FeatureTourView 本身不可 ignoresSafeArea，否則 GeometryProxy 的 safeAreaInsets 會歸零，
    /// 在瀏海／動態島高度不同的裝置上造成整個聚光窗位移。
    private func cutoutRect(for target: TourTarget, in proxy: GeometryProxy) -> CGRect {
        let width = proxy.size.width
        let height = proxy.size.height
        let safeTop = proxy.safeAreaInsets.top

        if let anchor = anchors[target] {
            let anchoredRect = proxy[anchor]
            #if DEBUG
            AppLog.pipeline.info("導覽挖洞：\(target.rawValue) 錨點=\(String(format: "%.0f,%.0f %.0fx%.0f", anchoredRect.minX, anchoredRect.minY, anchoredRect.width, anchoredRect.height)) safeTop=\(String(format: "%.0f", safeTop))")
            #endif
            switch target {
            case .mapCanvas, .familyContent:
                return contentSpotlightRect(from: anchoredRect, in: proxy)
            default:
                return clamped(anchoredRect.insetBy(dx: -8, dy: -8), in: proxy)
            }
        }
        #if DEBUG
        AppLog.pipeline.info("導覽挖洞：\(target.rawValue) 無錨點，走降級推算")
        #endif

        switch target {
        case .tabBar:
            return clamped(
                CGRect(x: 12, y: height - proxy.safeAreaInsets.bottom - 76, width: width - 24, height: 64),
                in: proxy
            )
        case .mapCanvas:
            let top = safeTop + 56
            let availableHeight = max(180, height - top - 250)
            return clamped(
                CGRect(x: 12, y: top, width: width - 24, height: min(360, availableHeight)),
                in: proxy
            )
        case .mapControls:
            let controlWidth = min(236, width - 24)
            return clamped(
                CGRect(x: width - controlWidth - 8, y: safeTop, width: controlWidth, height: 48),
                in: proxy
            )
        case .familyContent:
            let top = safeTop + 56
            let availableHeight = max(160, height - top - 250)
            return clamped(
                CGRect(x: 12, y: top, width: width - 24, height: min(360, availableHeight)),
                in: proxy
            )
        default:
            return clamped(
                CGRect(x: 12, y: safeTop + 56, width: width - 24, height: 96),
                in: proxy
            )
        }
    }

    /// 地圖與家人清單可能比螢幕還高；聚光窗取其實際可見區域上半段，
    /// 留出下方空間擺說明卡，同時不再依賴特定機型的狀態列高度。
    private func contentSpotlightRect(from anchoredRect: CGRect, in proxy: GeometryProxy) -> CGRect {
        // 錨點與繪製同在 proxy 的區域座標（原點已在狀態列下方），這裡不可再加 safeAreaInsets——
        // 重複加會把整個聚光窗往下推 60+pt，正是「窗頂切在卡片標題上」的根因（log 實測定位）。
        // 錨點區域本來就從導航列下方開始，外擴 8pt 後直接用即可
        let top = max(anchoredRect.minY - 8, 8)
        let left = max(8, anchoredRect.minX - 4)
        let right = min(proxy.size.width - 8, anchoredRect.maxX + 4)
        let availableHeight = max(160, anchoredRect.maxY - top + 8)
        let result = clamped(
            CGRect(x: left, y: top, width: max(0, right - left), height: min(360, availableHeight)),
            in: proxy
        )
        #if DEBUG
        AppLog.pipeline.info("導覽挖洞：內容區回傳 rect=\(String(format: "%.0f,%.0f %.0fx%.0f", result.minX, result.minY, result.width, result.height))")
        #endif
        return result
    }

    private func clamped(_ rect: CGRect, in proxy: GeometryProxy) -> CGRect {
        let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 2, dy: 2)
        let intersection = rect.standardized.intersection(bounds)
        return intersection.isNull || intersection.isEmpty
            ? CGRect(x: 12, y: proxy.safeAreaInsets.top + 56, width: max(0, proxy.size.width - 24), height: 96)
            : intersection
    }

    /// 說明卡：目標在上半場放下方、在下半場放上方，避免遮住主角。
    /// 不用 ScrollView 當最外層：ScrollView 會貪滿 maxHeight，形成大片黑色空白邊。
    private func card(step: TourStep, index: Int, near rect: CGRect, in proxy: GeometryProxy) -> some View {
        let placeBelow = rect.midY < proxy.size.height / 2
        let estimatedCardHeight = min(230, proxy.size.height * 0.32)
        return VStack(alignment: .leading, spacing: HCSpacing.x2) {
            Text(step.title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("略過") { finishTour() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                if index > 0 {
                    Button("上一步", systemImage: "chevron.left") { goBack() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\(index + 1) / \(steps.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityLabel("第 \(index + 1) 步，共 \(steps.count) 步")
                Button(index + 1 == steps.count ? "完成" : "下一步") { advance() }
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(HCColor.brand, in: Capsule())
            }
            .padding(.top, 4)
        }
        .padding(HCSpacing.x4)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.12).opacity(0.95), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        .padding(.horizontal, HCSpacing.x4)
        .frame(maxWidth: .infinity)
        .offset(y: placeBelow ? min(rect.maxY + 16, proxy.size.height - estimatedCardHeight - 20)
                              : max(rect.minY - estimatedCardHeight - 16, 60))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能導覽：\(step.title)")
        .accessibilityFocused($isCardFocused)
    }

    private func advance() {
        guard let index = stepIndex else { return }
        if index + 1 < steps.count {
            let nextIndex = index + 1
            // 先切到目標分頁，再讓下一張說明卡取代目前步驟。
            // 同一個 SwiftUI 更新週期完成，不會要求使用者手動點分頁列。
            move(to: nextIndex)
        } else {
            finishTour()
        }
    }

    private func goBack() {
        guard let index = stepIndex, index > 0 else { return }
        move(to: index - 1)
    }

    private func move(to index: Int) {
        let targetTab = steps[index].tab
        if targetTab != selectedTab {
            // 跨分頁：先切頁、等目標頁面掛上錨點（約半秒）再移動聚光燈——
            // 立刻移動只能用降級推算的位置畫框，就是「沒對齊」的來源
            selectedTab = targetTab
            announcePage(for: targetTab)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 450))
                stepIndex = index
            }
        } else {
            stepIndex = index
        }
    }

    private func finishTour() {
        selectedTab = TabRouter.homeTab
        stepIndex = nil
        UIAccessibility.post(notification: .announcement, argument: "功能導覽完成，已回到安心頁")
    }

    private func announcePage(for tab: Int) {
        let pageName = switch tab {
        case TabRouter.mapTab: "安全地圖頁"
        case TabRouter.familyTab: "家人頁"
        default: "安心頁"
        }
        UIAccessibility.post(notification: .announcement, argument: "已切換到\(pageName)")
    }

    private func focusCurrentCard() {
        DispatchQueue.main.async { isCardFocused = true }
    }

    /// 通知目標所在頁面把目標捲進畫面（安心頁的列在小螢幕可能位於摺疊線以下）
    private func broadcastTarget() {
        guard let index = stepIndex, steps.indices.contains(index) else { return }
        NotificationCenter.default.post(name: .tourStepTargetChanged, object: steps[index].target)
    }
}
