import SwiftUI

/// 親切帶領的教學卡：**置中**、極短一句話、**點任意處就繼續**（不放按鈕）。
/// 目前用於：分頁一句話介紹、以及「點事件才教拖圈」的一次性提示。
/// （地圖第一次帶領已改為「目標自己動」的動畫，見 SafetyMapView 的 PulseRing 帶領。）
struct CoachCard: View {
    let icon: String
    let text: String
    /// (目前第幾張, 共幾張)；有值時顯示小圓點進度，nil＝單張不顯示
    var progress: (index: Int, total: Int)?
    /// 點任意處觸發（前進到下一張／關閉）
    var onTap: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(HCColor.brand)
                Text(text)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let progress {
                    HStack(spacing: 6) {
                        ForEach(0..<progress.total, id: \.self) { i in
                            Circle()
                                .fill(i == progress.index ? HCColor.brand : HCColor.brand.opacity(0.25))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.top, 2)
                }
                Text("輕點繼續")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .transition(.opacity)
    }
}

/// 聲納式脈動圈：兩圈錯開、由小放大同時淡出、反覆播放，用來把目光吸到某個目標上（幾乎不用文字）。
struct PulseRing: View {
    var color: Color
    /// 脈動放到最大時的直徑（點）
    var maxDiameter: CGFloat
    var lineWidth: CGFloat = 3
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: maxDiameter, height: maxDiameter)
                    .scaleEffect(animate ? 1.0 : 0.2)
                    .opacity(animate ? 0.0 : 0.85)
                    .animation(
                        .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.9),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

/// 帶領結束後的情境式通知權限卡（A4）：不在新手一開始就要權限，
/// 而是先讓使用者看過地圖與帶領、感受到價值後才問——「先給價值再開口」。
/// 卡片一出現就自動播一次 App 內示範橫幅（約 2.5 秒，標明「此為示範」），
/// 使用者不必按任何東西就看到警報長什麼樣；只剩兩顆鈕：開啟通知／先不用。
/// 置中卡＋regularMaterial，風格比照 CoachCard；沒有長說明，一句話問完。
struct NotificationPromptCard: View {
    /// 卡片結束（不論走哪個分支）都呼叫一次，讓外層收起顯示狀態
    var onDismiss: () -> Void

    /// 模擬通知橫幅是否正在顯示（App 內模擬，不是真通知）
    @State private var showDemoBanner = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.001) // 幾乎透明但能接住點擊，避免使用者誤點到底下的地圖
                .ignoresSafeArea()
                // 點卡片外的空白處＝先不用（關閉，等同按「先不用」）
                .onTapGesture { decline() }
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Text("圈內有新狀況時，要通知你嗎？")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("警報通知就像上方的示範橫幅。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await enable() }
                } label: {
                    Text("好，開啟通知")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HCColor.brand)

                Button("先不用") { decline() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(40)

            if showDemoBanner {
                VStack {
                    DemoNotificationBanner()
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
            Analytics.track("notify_prompt_shown") // 漏斗：情境式通知權限卡出現
        }
        // 自動播示範橫幅：不發真通知（未授權發不出、勿擾下也可能靜默失敗），App 內繪製即可
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Analytics.track("notify_demo_viewed") // 漏斗：模擬通知橫幅被看過
            withAnimation { showDemoBanner = true }
            try? await Task.sleep(for: .milliseconds(2500))
            withAnimation { showDemoBanner = false }
        }
    }

    private func enable() async {
        let granted = await NotificationScheduler.requestPermission()
        Analytics.track(granted ? "notify_granted" : "notify_denied") // 漏斗：系統權限框結果
        onDismiss()
    }

    private func decline() {
        UserDefaults.standard.set(true, forKey: SettingsKeys.notificationPromptDeclined)
        onDismiss()
    }
}

/// App 內模擬的 iOS 通知橫幅樣式：純視覺示範「通知長怎樣」，明確標示「此為示範」，
/// 不會被誤認為真通知。
private struct DemoNotificationBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(HCColor.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("安心圈")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("此為示範")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("🔴【示範】火災：距你的警戒圈 800 公尺")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 12)
    }
}
