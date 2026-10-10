import SwiftUI
import SwiftData

/// 動態分頁（原提醒中心）：按「需要注意 / 持續確認中 / 已結束」分類（對應產品規格的通知頁分類）
struct EventListView: View {
    private enum FeedScope: String, CaseIterable, Identifiable {
        case related = "與我有關"
        case nationwide = "全台動態"

        var id: Self { self }
    }

    @Environment(\.modelContext) private var context
    @Environment(TabRouter.self) private var router
    @Environment(EntitlementStore.self) private var entitlementStore
    @Query(sort: \LocalSafetyEvent.occurredAt, order: .reverse) private var events: [LocalSafetyEvent]
    @Query private var members: [LocalFamilyMember]
    @Query private var regionAlerts: [RegionAlert]
    /// 可收合分組的展開狀態（預設全部收合：未驗證與已結束的資訊不該搶版面）
    @State private var expandedSections: Set<String> = []
    @State private var selected: LocalSafetyEvent?
    @State private var selectedAlert: RegionAlert?
    @State private var didOpenDebugDetail = false
    @Query private var circles: [LocalLifeCircle]
    /// 使用者手動選過的範圍；沒選過就跟著「有沒有守護範圍」走：
    /// 沒有圈（沒授權定位、也沒新增守護地點）→ 全台動態；一有圈（授權後建好跟隨圈）→ 自動切「與我有關」。
    /// 一旦使用者自己選了就尊重他的選擇，不再自動切。
    @State private var feedScopeOverride: FeedScope?

    private var feedScope: FeedScope {
        feedScopeOverride ?? (circles.isEmpty ? .nationwide : .related)
    }
    private var feedScopeBinding: Binding<FeedScope> {
        Binding(get: { feedScope }, set: { feedScopeOverride = $0 })
    }

    /// 一次 body 計算只分類一次：以前 visibleEvents／attention／elsewhere／nationwide／confirming
    /// 各自是計算屬性，body 內被讀到十幾次，每次都對全部事件重跑 AlertPolicy.evaluate 與排序
    /// （Time Profiler 實測是主執行緒大宗）。現在每個事件的「是否落在圈內」「最近圈距離」只算一次。
    private struct Feed {
        let visibleEvents: [LocalSafetyEvent]
        /// 需要注意＝可信（官方確認／多來源交叉驗證／主流媒體單一報導）「且真的落在某個
        /// 生活圈的提醒範圍內」（分類標籤與邏輯必須一致）。改用 isCredible 而非 isOfficiallyConfirmed，
        /// 讓中央社、TVBS 這類一線媒體的獨家報導不再被誤收進「未驗證線索」摺疊區看不到
        let attention: [LocalSafetyEvent]
        /// 可信、但離所有生活圈較遠的事件另立分類，不冒充「需要注意」（距離上限 NearbyScope）
        let elsewhere: [LocalSafetyEvent]
        /// 離所有生活圈超過上限的全國可信事件（預設摺疊）
        let nationwide: [LocalSafetyEvent]
        /// 與上面三類互斥且互補：非可信（!isCredible）的事件才落在「未驗證線索」
        let confirming: [LocalSafetyEvent]
        /// 全台動態是「看見資訊密度」的獨立層，不改變首頁與通知的生活圈優先原則；
        /// 未驗證新聞也可在這裡閱讀，但每一列都保留明確的驗證文字。
        let nationwideDynamics: [LocalSafetyEvent]

        @MainActor
        init(events: [LocalSafetyEvent], members: [LocalFamilyMember]) {
            let visible = events.filter { !$0.isArchived && $0.mergedIntoKey == nil && !EventVisibility.isSuppressed($0) }
            visibleEvents = visible
            let active = visible.filter(\.isActiveForAwareness)
            var attention: [(LocalSafetyEvent, Double)] = []
            var elsewhere: [(LocalSafetyEvent, Double)] = []
            var nationwide: [LocalSafetyEvent] = []
            var confirming: [LocalSafetyEvent] = []
            for event in active {
                guard event.isCredible else { confirming.append(event); continue }
                let nearest = nearestCircleDistance(event, members)
                if !AlertPolicy.evaluate(event: event, members: members).matches.isEmpty {
                    attention.append((event, nearest))
                } else if nearest <= NearbyScope.maxMeters {
                    elsewhere.append((event, nearest))
                } else {
                    nationwide.append(event)
                }
            }
            self.attention = attention.sorted { $0.1 < $1.1 }.map(\.0)
            self.elsewhere = elsewhere.sorted { $0.1 < $1.1 }.map(\.0)
            self.nationwide = nationwide.sorted { $0.occurredAt > $1.occurredAt }
            self.confirming = confirming
            nationwideDynamics = active.sorted { lhs, rhs in
                if lhs.isCredible != rhs.isCredible { return lhs.isCredible }
                return lhs.occurredAt > rhs.occurredAt
            }
        }
    }

    /// Feed 快取：分類要對每個事件跑 AlertPolicy，body 因無關狀態（展開收合、sheet）重算時不該重做。
    /// 以「事件／成員／守護圈內容 + 分鐘」的指紋判斷輸入是否變動，沒變就沿用上次結果。
    /// （class 而非 @State 值：在 body 裡更新快取不會再觸發一輪 body）
    private final class FeedCache {
        var fingerprint: Int?
        var feed: Feed?
    }
    @State private var feedCache = FeedCache()

    private func currentFeed() -> Feed {
        var hasher = Hasher()
        hasher.combine(events.count)
        for e in events {
            hasher.combine(e.eventKey)
            hasher.combine(e.updatedAt)
            hasher.combine(e.expiresAt)
            hasher.combine(e.status)
            hasher.combine(e.isOngoing)
            hasher.combine(e.isArchived)
            hasher.combine(e.trustStatus)
            hasher.combine(e.reportCount)
            hasher.combine(EventVisibility.isSuppressed(e))
        }
        hasher.combine(members.count)
        for m in members {
            hasher.combine(m.memberKey)
            hasher.combine(m.kind)
            for c in m.lifeCircles {
                hasher.combine(c.circleKey)
                hasher.combine(c.latitude)
                hasher.combine(c.longitude)
                hasher.combine(c.radiusMeters)
                hasher.combine(c.alertTypes)
                hasher.combine(c.district)
                hasher.combine(c.isActiveForAlerts)
                hasher.combine(c.scheduleEnabled)
            }
        }
        // 事件到期是時間函數：每分鐘至多重算一次
        hasher.combine(Int(Date.now.timeIntervalSince1970 / 60))
        let fingerprint = hasher.finalize()
        if feedCache.fingerprint == fingerprint, let feed = feedCache.feed { return feed }
        let feed = Feed(events: events, members: members)
        feedCache.fingerprint = fingerprint
        feedCache.feed = feed
        return feed
    }

    /// 進行中的區域警報，依 kind＋title 去重取最新——NCDR 同一場警報常拆成多筆
    /// （鄉鎮清單不同、標題相同），全部列出會讓提醒中心看起來像同一則洗版
    private var activeRegionAlerts: [RegionAlert] {
        var newest: [String: RegionAlert] = [:]
        for alert in regionAlerts where !alert.isEnded {
            let key = "\(alert.kind)|\(alert.title)"
            if let kept = newest[key], kept.updatedAt >= alert.updatedAt { continue }
            newest[key] = alert
        }
        return newest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // 本頁是「動態」分頁的根內容，導航堆疊由 EventsTabView 提供，
    // 自己不再包 NavigationStack（巢狀堆疊會讓 push/pop 行為錯亂）
    var body: some View {
        let feed = currentFeed()
        List {
            // 報平安一鍵卡：打開 App 就能告訴家人「我平安」（沒有家人時改為引導邀請）
            Section {
                QuickSafetyCard(hasNearbyAttention: !feed.attention.isEmpty)
            }
            // 零導覽引導：定位／邀請碼情境卡（通知說明改在使用者做了相關動作之後才出現）
            FeedOnboardingCards(hasCircle: !circles.isEmpty)
            scopeSection
            // 沒有任何守護範圍時不能說「一切平安」——那是假性安心；改給空狀態與出路
            if feedScope == .related && circles.isEmpty {
                Section { NoCircleEmptyState() }
            } else if feed.visibleEvents.isEmpty && activeRegionAlerts.isEmpty && feedScope == .related {
                Section {
                    safeStateHero
                        .listRowBackground(Color.clear)
                }
            }
            if feedScope == .related {
                regionAlertSection
                // 顯示面積跟「可信度／急迫性」成正比：需要注意永遠攤開；
                // 未驗證的確認中、離圈遠的附近動態、已結束——預設收合，點標題展開
                section(title: "需要注意", subtitle: "已充分驗證（官方／主流媒體／多來源）且位於有效警戒圈內", items: feed.attention)
                section(title: "未驗證線索", subtitle: "資料尚未充分驗證，不會推播", items: feed.confirming, collapsible: true)
                section(title: "附近動態", subtitle: "已驗證事件，離警戒圈 10 公里內", items: feed.elsewhere, collapsible: true)
                nationwideSection(feed.nationwide)
            } else {
                nationwideDynamicsSection(feed.nationwideDynamics)
            }
            // #B：不再顯示「已結束」區塊——使用者不需要看已解除／已過期的事件（地圖也早已排除）
            footerLinksSection
        }
        .navigationTitle("動態")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("alert_center")
        // 手動下拉刷新：重跑一次資料管線
        .refreshable { await EventPipeline.refresh(context: context) }
        // 通知深連結：帶事件 key 進來就直接打開那一則詳情，使用者不必在清單裡自己找。
        // 本機通知一定源自本機已存在的事件，找不到（例如已被刪除）就靜默留在清單。
        .task(id: router.pendingEventKey) {
            guard let key = router.pendingEventKey else { return }
            router.pendingEventKey = nil
            guard let match = currentFeed().visibleEvents.first(where: { $0.eventKey == key }) else { return }
            // 等 push 導航動畫完成再出 sheet，避免兩種轉場互相打斷（同 DEBUG 自動開啟的考量）
            try? await Task.sleep(for: .milliseconds(450))
            selected = match
        }
        // 看過內容的訊號：點開任一事件詳情後，通知邀請卡才有資格出現
        .onChange(of: selected?.eventKey) { _, key in
            if key != nil { UserDefaults.standard.set(true, forKey: SettingsKeys.hasOpenedEventDetail) }
        }
        .sheet(item: $selected) { EventDetailView(event: $0, members: members).hcSheet() }
        .sheet(item: $selectedAlert) { RegionAlertDetailView(alert: $0, members: members).hcSheet() }
        #if DEBUG
        .task(id: events.count) {
            guard !didOpenDebugDetail,
                  ProcessInfo.processInfo.arguments.contains("--open-first-event-detail") else { return }
            let debugFeed = currentFeed()
            let target = debugFeed.attention.first { $0.eventKey.contains("NFA_Fire") }
                ?? debugFeed.attention.first
                ?? debugFeed.visibleEvents.first { $0.eventKey.contains("NFA_Fire") }
                ?? debugFeed.visibleEvents.first
            guard let target else { return }
            didOpenDebugDetail = true
            // 等 push 導航動畫完成再出 sheet，避免兩種轉場互相打斷。
            try? await Task.sleep(for: .milliseconds(450))
            selected = target
        }
        #endif
    }

    private var scopeSection: some View {
        Section {
            // D4 重問通道：曾拒絕過情境式權限卡、但通知仍未開啟時，動態頂部再給一次機會
            NotificationReaskRow()
            Picker("動態範圍", selection: feedScopeBinding) {
                ForEach(FeedScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(feedScope == .related
                 ? "通知只會依你的生活圈與設定發送；全台內容不會干擾你。"
                 : "全台內容供了解動態；「持續確認中」代表尚未由官方、主流媒體或多來源充分驗證。")
        }
    }

    /// 動態分頁最底：低頻入口——回顧與防災問答（原本分別在首頁與設定裡）
    private var footerLinksSection: some View {
        Section {
            NavigationLink(value: TabRouter.EventsDestination.history) {
                // 天數依方案分層跟著變（見 HistoryView／FreeTier），不寫死避免 Guardian+ 看到錯誤天數
                Label("回顧過去 \(entitlementStore.isPlus ? FreeTier.plusHistoryDays : FreeTier.historyDays) 天",
                      systemImage: "clock.arrow.circlepath")
            }
            NavigationLink {
                AIAssistantView()
            } label: {
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Label("防災問答", systemImage: "bubble.left.and.text.bubble.right.fill")
                    Text("AI 助理：地震、颱風、火災怎麼辦")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 品牌簽名：平安不是「沒有內容」，是產品最想傳達的一刻——同心圓環＝守護圈完好。
    /// 圓環 motif 與 Onboarding hero、地圖盾牌 chip 呼應，構成貫穿全 App 的視覺識別
    private var safeStateHero: some View {
        VStack(spacing: HCSpacing.x3) {
            ZStack {
                Circle()
                    .stroke(HCColor.safe.opacity(0.18), lineWidth: 2)
                    .frame(width: 96, height: 96)
                Circle()
                    .stroke(HCColor.safe.opacity(0.4), lineWidth: 2)
                    .frame(width: 74, height: 74)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(HCColor.safe.gradient, in: Circle())
            }
            .accessibilityHidden(true)
            Text("警戒圈一切平安")
                .font(.system(.headline, design: .rounded))
            Text("目前沒有需要注意的事件，守護持續進行中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HCSpacing.x6)
    }

    /// 區域警報依分組分區顯示（天災→公共安全→民生→交通，安全相關優先排前）。
    /// 每組最多直接顯示 3 則，其餘收進摺疊清單——警報是背景資訊，不該淹沒事件列表
    @ViewBuilder
    private var regionAlertSection: some View {
        let grouped = Dictionary(grouping: activeRegionAlerts, by: \.group)
        ForEach(["天災", "公共安全", "民生", "交通"], id: \.self) { group in
            if let alerts = grouped[group], !alerts.isEmpty {
                Section("區域警報・\(group)（\(alerts.count)）") {
                    ForEach(alerts.prefix(3)) { alert in
                        regionAlertRow(alert)
                    }
                    if alerts.count > 3 {
                        DisclosureGroup("其餘 \(alerts.count - 3) 則") {
                            ForEach(alerts.dropFirst(3)) { alert in
                                regionAlertRow(alert)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 警報卡自帶底色與圓角，列背景改透明避免「卡中卡」的雙層框
    private func regionAlertRow(_ alert: RegionAlert) -> some View {
        Button {
            selectedAlert = alert
        } label: {
            RegionAlertBanner(alert: alert, members: members)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: HCSpacing.x1, leading: HCSpacing.x4, bottom: HCSpacing.x1, trailing: HCSpacing.x4))
    }

    /// 全台其他官方示警：預設摺疊——它們是真資料，但不該與「附近」搶注意力
    @ViewBuilder
    private func nationwideSection(_ nationwide: [LocalSafetyEvent]) -> some View {
        if !nationwide.isEmpty {
            Section {
                DisclosureGroup("全台其他已驗證事件（\(nationwide.count)）") {
                    ForEach(Array(nationwide.prefix(15))) { event in
                        Button {
                            selected = event
                        } label: {
                            EventRow(event: event, members: members)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("離所有警戒圈較遠的已驗證事件（官方／主流媒體／多來源）收在這裡，避免稀釋與你相關的訊號。")
            }
        }
    }

    @ViewBuilder
    private func nationwideDynamicsSection(_ nationwideDynamics: [LocalSafetyEvent]) -> some View {
        if nationwideDynamics.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("目前沒有全台動態", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("來源仍會持續更新；未驗證線索會清楚標示。")
                }
            }
        } else {
            Section {
                ForEach(nationwideDynamics) { event in
                    Button {
                        selected = event
                    } label: {
                        EventRow(event: event, members: members)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("全台動態（\(nationwideDynamics.count)）")
            } footer: {
                Text("顯示已驗證事件（官方／主流媒體／多來源）與未驗證新聞線索。未驗證內容不會單獨觸發可見通知。")
            }
        }
    }

    @ViewBuilder
    private func section(title: String, subtitle: String, items: [LocalSafetyEvent], collapsible: Bool = false) -> some View {
        if !items.isEmpty {
            let isExpanded = !collapsible || expandedSections.contains(title)
            Section {
                if isExpanded {
                    ForEach(items) { event in
                        Button {
                            selected = event
                        } label: {
                            EventRow(event: event, members: members)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { delete(at: $0, in: items) }
                }
            } header: {
                if collapsible {
                    Button {
                        withAnimation {
                            if isExpanded { expandedSections.remove(title) } else { expandedSections.insert(title) }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(title)（\(items.count)）")
                                Text(subtitle).font(.caption2).textCase(nil)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(items.count) 件，點擊\(isExpanded ? "收合" : "展開")")
                } else {
                    VStack(alignment: .leading) {
                        Text("\(title)（\(items.count)）")
                        Text(subtitle).font(.caption2).textCase(nil)
                    }
                }
            }
        }
    }

    /// 刪除索引對「該分類的清單」取，不能用完整 events 陣列
    private func delete(at offsets: IndexSet, in items: [LocalSafetyEvent]) {
        for index in offsets {
            context.delete(items[index])
        }
        context.saveReporting()
    }
}

#if DEBUG
#Preview {
    EventListView()
        .modelContainer(PreviewSupport.container())
        .environment(TabRouter())
        .environment(EntitlementStore())
}
#endif
