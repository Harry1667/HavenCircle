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
    @State private var feedScope: FeedScope = .related

    private var visibleEvents: [LocalSafetyEvent] {
        events.filter { !$0.isArchived && !EventVisibility.isSuppressed($0) }
    }
    /// 需要注意＝可信（官方確認／多來源交叉驗證／主流媒體單一報導）「且真的落在某個
    /// 生活圈的提醒範圍」（分類標籤與邏輯必須一致）。改用 isCredible 而非 isOfficiallyConfirmed，
    /// 讓中央社、TVBS 這類一線媒體的獨家報導不再被誤收進「未驗證線索」摺疊區看不到
    /// （產品判斷：大型新聞台一報導就會立刻播出，獨家不等於不可信）。
    private var attention: [LocalSafetyEvent] {
        visibleEvents
            .filter { $0.isActiveForAwareness && $0.isCredible && isInAnyCircle($0) }
            .sorted { nearestCircleDistance($0, members) < nearestCircleDistance($1, members) }
    }
    /// 可信、但離所有生活圈較遠的事件另立分類，不冒充「需要注意」。
    /// 加距離上限：超過 NearbyScope 的全國事件再拆到「全台其他」摺疊清單，避免灌成雜訊。
    private var elsewhere: [LocalSafetyEvent] {
        visibleEvents
            .filter {
                $0.isActiveForAwareness && $0.isCredible && !isInAnyCircle($0)
                    && nearestCircleDistance($0, members) <= NearbyScope.maxMeters
            }
            .sorted { nearestCircleDistance($0, members) < nearestCircleDistance($1, members) }
    }

    /// 離所有生活圈超過上限的全國可信事件（預設摺疊）
    private var nationwide: [LocalSafetyEvent] {
        visibleEvents
            .filter {
                $0.isActiveForAwareness && $0.isCredible && !isInAnyCircle($0)
                    && nearestCircleDistance($0, members) > NearbyScope.maxMeters
            }
            .sorted { $0.occurredAt > $1.occurredAt }
    }
    /// 與上面三類互斥且互補：非可信（!isCredible）的事件才落在「未驗證線索」——
    /// 四個集合合起來剛好涵蓋 visibleEvents 中所有 isActiveForAwareness 的事件，
    /// 且彼此不重疊（先按 isCredible 二分，可信的一半再按 isInAnyCircle／距離三分）。
    private var confirming: [LocalSafetyEvent] {
        visibleEvents.filter { $0.isActiveForAwareness && !$0.isCredible }
    }
    /// 全台動態是「看見資訊密度」的獨立層，不改變首頁與通知的生活圈優先原則。
    /// 未驗證新聞也可在這裡閱讀，但每一列都保留明確的驗證文字，絕不偽裝成官方訊息。
    private var nationwideDynamics: [LocalSafetyEvent] {
        visibleEvents
            .filter(\.isActiveForAwareness)
            .sorted { lhs, rhs in
                if lhs.isCredible != rhs.isCredible {
                    return lhs.isCredible
                }
                return lhs.occurredAt > rhs.occurredAt
            }
    }
    private func isInAnyCircle(_ event: LocalSafetyEvent) -> Bool {
        !AlertPolicy.evaluate(event: event, members: members).matches.isEmpty
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
        List {
            scopeSection
            if visibleEvents.isEmpty && activeRegionAlerts.isEmpty {
                Section {
                    safeStateHero
                        .listRowBackground(Color.clear)
                }
            }
            if feedScope == .related {
                regionAlertSection
                // 顯示面積跟「可信度／急迫性」成正比：需要注意永遠攤開；
                // 未驗證的確認中、離圈遠的附近動態、已結束——預設收合，點標題展開
                section(title: "需要注意", subtitle: "已充分驗證（官方／主流媒體／多來源）且位於有效警戒圈內", items: attention)
                section(title: "未驗證線索", subtitle: "資料尚未充分驗證，不會推播", items: confirming, collapsible: true)
                section(title: "附近動態", subtitle: "已驗證事件，離警戒圈 10 公里內", items: elsewhere, collapsible: true)
                nationwideSection
            } else {
                nationwideDynamicsSection
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
            guard let match = visibleEvents.first(where: { $0.eventKey == key }) else { return }
            // 等 push 導航動畫完成再出 sheet，避免兩種轉場互相打斷（同 DEBUG 自動開啟的考量）
            try? await Task.sleep(for: .milliseconds(450))
            selected = match
        }
        .sheet(item: $selected) { EventDetailView(event: $0, members: members).hcSheet() }
        .sheet(item: $selectedAlert) { RegionAlertDetailView(alert: $0, members: members).hcSheet() }
        #if DEBUG
        .task(id: events.count) {
            guard !didOpenDebugDetail,
                  ProcessInfo.processInfo.arguments.contains("--open-first-event-detail") else { return }
            let target = attention.first { $0.eventKey.contains("NFA_Fire") }
                ?? attention.first
                ?? visibleEvents.first { $0.eventKey.contains("NFA_Fire") }
                ?? visibleEvents.first
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
            Picker("動態範圍", selection: $feedScope) {
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
    private var nationwideSection: some View {
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
    private var nationwideDynamicsSection: some View {
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
