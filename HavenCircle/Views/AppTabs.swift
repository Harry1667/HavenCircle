import SwiftUI
import SwiftData

struct AppTabs: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Query private var members: [LocalFamilyMember]
    @AppStorage(SettingsKeys.profileDisplayName) private var profileDisplayName = ""
    /// 外觀風格（層次／晴空湖水）：變動時重建分頁內容，讓所有 HCColor 取值重新讀取；
    /// 設定 sheet 掛在外層，切換時不會被收掉
    @AppStorage(SettingsKeys.appAppearance) private var appAppearance = AppAppearance.default.rawValue

    /// 擁有者名稱作為安否回報的發送者署名
    private var myName: String {
        if !profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profileDisplayName
        }
        return members.first { $0.relationship == "擁有者" }?.name ?? members.first?.name ?? "我"
    }

    // DEBUG：--start-tab <n> 讓 App 直接開在指定分頁，方便自動化截圖驗證
    @State private var router = TabRouter(selection: Self.initialTab())
    /// 通知權限的 App 內說明：加入／建立家庭、新增守護地點、第一次按「我平安」後才由各處呼叫 request
    @State private var primer = NotificationPrimer.shared
    #if DEBUG
    // DEBUG：--show-paywall 啟動即開付費牆（IAP 審查截圖用），發佈版不編入
    @State private var debugShowPaywall = ProcessInfo.processInfo.arguments.contains("--show-paywall")
    #endif
    private static func initialTab() -> Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "--start-tab"),
           flagIndex + 1 < args.count,
           let tab = Int(args[flagIndex + 1]) {
            return min(max(tab, 0), 2)
        }
        #endif
        return TabRouter.eventsTab  // 第一次與之後的冷啟動都落在動態首頁（零導覽）
    }

    var body: some View {
        ZStack {
            TabView(selection: Bindable(router).selection) {
                EventsTabView()
                    .tabItem { Label("動態", systemImage: "bell.badge.fill") }
                    .tag(TabRouter.eventsTab)
                SafetyMapView()
                    .tabItem { Label("地圖", systemImage: "map.fill") }
                    .tag(TabRouter.mapTab)
                FamilyHubView(myName: myName)
                    .tabItem { Label("家人", systemImage: "person.2.fill") }
                    .tag(TabRouter.familyTab)
            }
            .tint(HCColor.brand)
            .environment(router)
            // 下滑關閉等同「稍後」：不問系統，次數已在顯示時記下，不需要額外處理
            .sheet(item: Bindable(primer).presenting) { trigger in
                NotificationPrimerSheet(
                    trigger: trigger,
                    onAccept: { Task { await primer.accept() } },
                    onLater: { primer.later() }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .formPresentationSizing()
            }
            #if DEBUG
            // DEBUG：--show-paywall 直接開付費牆，供自動化截圖（同 --start-tab 定式）
            // 跟正式的 4 個入口一樣改用 fullScreenCover，截圖才會反映使用者實際看到的樣子。
            .fullScreenCover(isPresented: $debugShowPaywall) { PaywallView() }
            #endif
        }
        .tint((AppAppearance(rawValue: appAppearance) ?? .default).palette.brand)
        // 設定改為全域 sheet：任何頁面（含家人頁的「查看 Apple 帳號狀態」）都能打開
        // 外層 sheet 不在 TabView 的 .environment(router) 範圍內，要自己補注入（缺了會在讀 TabRouter 時閃退）
        .sheet(isPresented: Bindable(router).showSettings) { SettingsView().hcSheet().environment(router) }
        // App 每次回到前景重跑資料管線（含每日摘要重算）。
        // 原型限制：沒有背景更新，用前景時機讓資料與摘要盡量新鮮。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await EventPipeline.refresh(context: context) }
        }
        // Widget deep link 路由（經 scene delegate 轉交，.onOpenURL 在自訂 delegate 下收不到）
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveDeepLink)) { note in
            if let url = note.object as? URL { route(url) }
        }
        // 授權定位後才建跟隨圈（沒授權就沒有圈，不放任何預設座標）；進場時已授權者也補建
        .task(id: LocationService.shared.authorization) {
            await FirstRunSetup.ensureFollowCircleIfAuthorized(context: context)
        }
        .onAppear {
            // 冷啟動由 URL 拉起的情況
            if let url = DeepLinkStore.pending {
                DeepLinkStore.pending = nil
                route(url)
            }
            // 三個主分頁的畫面瀏覽集中在這一處記錄：涵蓋一開場就看到的初始分頁
            // （切分頁才記的話，冷啟動落地的那一頁永遠不會被算到）。
            Analytics.trackScreen(screenName(for: router.selection))
        }
        // 三個主分頁集中記一筆畫面瀏覽，不進分頁 view 各自記一次
        .onChange(of: router.selection) { _, newTab in
            Analytics.trackScreen(screenName(for: newTab))
        }
    }

    /// havencircle://alerts[?event=<eventKey>]｜map｜family｜refresh｜havencircle://join?code=<8碼>
    /// alerts/refresh 切到「動態」分頁，widget 與通知不用改 URL；
    /// 通知另帶 event 參數時，動態分頁會直接打開那一則的詳情。
    /// havencircle://join（B2）：QR code／分享連結掃到後，切到家人分頁並把邀請碼交給
    /// FamilyHomeView 消耗，由它負責登入前置與開啟加入流程（這裡只負責路由，不碰登入／加入邏輯）。
    private func route(_ url: URL) {
        guard url.scheme == "havencircle" else { return }
        switch url.host {
        case "alerts":
            router.pendingEventKey = eventKey(from: url)
            router.openEvents()
        case "map": router.selection = TabRouter.mapTab
        case "family": router.selection = TabRouter.familyTab
        case "join":
            router.pendingJoinCode = queryValue("code", from: url)
            router.selection = TabRouter.familyTab
        case "refresh":
            router.openEvents()
            Task { await EventPipeline.refresh(context: context) }
        default: break
        }
    }

    private func eventKey(from url: URL) -> String? {
        queryValue("event", from: url)
    }

    /// 三個主分頁對照畫面名稱（tab 值對照 TabRouter 常數）。
    private func screenName(for tab: Int) -> String {
        switch tab {
        case TabRouter.eventsTab: "events"
        case TabRouter.mapTab: "map"
        case TabRouter.familyTab: "family"
        default: "unknown_tab"
        }
    }

    private func queryValue(_ name: String, from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

#if DEBUG
#Preview {
    AppTabs()
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
}
#endif
