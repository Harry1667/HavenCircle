import SwiftUI
import SwiftData
import UserNotifications

/// 安心頁——App 的第一畫面。
/// 90% 的開啟只為確認一件事：「家人都平安嗎」。這頁把答案做成 3 秒可讀完的三段式：
/// 大字狀態語句 → 家人列 → 背景看守摘要，底部一顆「回報我平安」。
/// 想深究的人再進地圖或事件列表——狀態優先、細節下鑽。
struct HomeStatusView: View {
    let myName: String
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EntitlementStore.self) private var entitlementStore
    // PlaceSelectView 選定後要直接建立地點成員，這裡才需要 modelContext（原本這件事都在
    // MemberEditorView 內部完成，這頁只負責呈現 sheet）
    @Environment(\.modelContext) private var context
    @Query private var members: [LocalFamilyMember]
    @Query private var events: [LocalSafetyEvent]
    @Query private var regionAlerts: [RegionAlert]
    @State private var showCheckIn = false
    @State private var selectedEvent: LocalSafetyEvent?
    @State private var breathing = false
    /// 單人態「守護更多地方卡」：兩段式流程（先存地點、sheet 收合後再開固定圈編輯器）
    @State private var addingPlace = false
    @State private var newPlaceForCircle: LocalFamilyMember?
    /// 剛選好建好、等「選地點 sheet 完全關閉」後才開圈編輯器的地點成員（見 addingPlace onDismiss）
    @State private var pendingCirclePlace: LocalFamilyMember?
    /// 地點額度閘門觸發時開這個付費頁（見 [gateAddPlace]，共用判斷在 EntitlementStore）
    @State private var showPaywall = false

    /// 浮動分頁列（膠囊）從系統安全區下緣量到膠囊頂端的視覺高度（12pt 間距＋64pt 膠囊高度＝76）。
    /// 用 safeAreaInset 疊加（而非塞進可捲動內容尾端的固定 padding）：不論系統本身
    /// 已經自動保留多少安全區，這裡都只是「再往上多補一段」，不必猜測兩者加總是否剛好蓋滿。
    private static let floatingTabBarClearance: CGFloat = 76

    /// 與地圖頁共用同一個聚合（SafetyStatus）：兩頁對「平安與否」的說法永遠一致，
    /// 且一律以未過濾事件計算——假性安心是這頁最不可犯的錯
    private var status: SafetyOverview {
        SafetyOverview.compute(events: events, regionAlerts: regionAlerts, members: members)
    }

    /// 單人／多人判斷：共用 [FamilySyncService.isSolo]（D1 統一規則，取代各頁各自一份）——
    /// 已在家庭圈時看雲端 memberUids，不看本機 LocalFamilyMember 筆數（會落後於雲端）；
    /// 未在家庭圈時退回本機成員數（沿用舊行為）。familySection、checkInButton、
    /// 單人專屬卡片全部共用這一個判斷，避免各處各自寫一份計數邏輯而養出兩套真相。
    private var isSoloUser: Bool {
        sync.isSolo(localMembers: members)
    }

    /// 只計「家人」的即時圈：自己這支手機的圈不算（人在自己手上，不存在「沒有回報」），
    /// 單人使用者因此永遠不會看到這個警告。
    private var staleLiveCircleCount: Int {
        guard !isSoloUser else { return 0 }
        return members.filter { !$0.isCurrentUser }.flatMap(\.lifeCircles).filter {
            $0.kind == .live && !$0.isActiveForAlerts
        }.count
    }

    private var pageStatusColor: Color {
        if !status.isAllClear { return HCColor.danger }
        return staleLiveCircleCount > 0 ? HCColor.attention : HCColor.safe
    }

    var body: some View {
        // 導航堆疊綁在 router 上：deep link（widget/通知的 alerts）能直接推入提醒中心
        NavigationStack(path: Bindable(router).homePath) {
            ScrollView {
                VStack(spacing: HCSpacing.x6) {
                    statusHero
                    // 單人時 members 只有自己＋重要地點，一張「全家名單」對一個人沒有意義
                    if !isSoloUser {
                        familySection
                    }
                    eventFeedSection
                    // 單人態：沒有家人可看，事件串後面補兩張引導卡，取代原本按了沒人看見的回報鈕
                    if isSoloUser {
                        guardMorePlacesCard
                        inviteFamilyCard
                    }
                    historyRow
                }
                .padding(.horizontal, HCSpacing.x4)
                .padding(.top, HCSpacing.x4)
                // iPad 上限制內容主欄寬度並置中，避免 hcCard 卡片撐滿 13 吋螢幕
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("安心圈")
            // 情緒底色：狀態色從頁面頂部滲下來的極淡漸層——平安是守護綠、
            // 有事件變警示紅，「變臉」從盾牌擴散到整頁氛圍，但淡到不搶警示色的戲
            .background(alignment: .top) {
                LinearGradient(
                    colors: [
                        pageStatusColor.opacity(0.12),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.6)
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: status.isAllClear)
            }
            .toolbar {
                Button("設定", systemImage: "gearshape") { router.showSettings = true }
            }
            .navigationDestination(for: TabRouter.HomeDestination.self) { destination in
                switch destination {
                case .events: EventListView()
                case .history: HistoryView()
                }
            }
            // 單人時按了沒人看見，「回報我平安」直接不出現，不留一顆死路按鈕；
            // 但沒有按鈕就沒有東西墊在內容與浮動分頁列之間，改補一段等高透明留白（floatingTabBarClearance），
            // 兩支路徑都走 safeAreaInset（而非其中一支用可捲動內容裡的固定 padding），
            // 確保無論系統本身自動保留多少安全區，這裡都正確疊加在上面，捲到底不會被膠囊分頁列蓋到文字。
            .safeAreaInset(edge: .bottom) {
                if isSoloUser {
                    Color.clear.frame(height: Self.floatingTabBarClearance)
                } else {
                    checkInButton
                }
            }
            .sheet(isPresented: $showCheckIn) {
                NavigationStack { SafetyCheckInView(myName: myName) }
            }
            .sheet(item: $selectedEvent) {
                EventDetailView(event: $0, members: members)
            }
            .sheet(isPresented: $addingPlace, onDismiss: presentPendingCircleEditor) {
                // 選定後先建好地點成員暫存，等這個 sheet 完全關閉再由 onDismiss 開圈編輯器——
                // 不能在關閉動畫途中就 present 下一個 sheet，否則會被 SwiftUI 靜默丟掉
                // （＝新增固定圈完全打不開的根因，與 FamilyHomeView 同款修正）。
                PlaceSelectView { name, _ in
                    pendingCirclePlace = createPlace(name: name)
                    addingPlace = false
                }
            }
            .sheet(item: $newPlaceForCircle) { member in
                CircleEditorView(member: member)
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView()
            }
        }
    }

    // MARK: - 大字狀態

    @ViewBuilder
    private var statusHero: some View {
        if status.isAllClear {
            let needsLocationUpdate = staleLiveCircleCount > 0
            let clearColor = needsLocationUpdate ? HCColor.attention : HCColor.safe
            // 縮小約 35-40%：狀態區只傳達一個布林狀態，不該佔掉螢幕近半高度——
            // 同心圓 motif（品牌識別）保留，三圈比例不變，只是整體係數從 7/5.5/4 降到 4.5/3.5/2.5
            // （約原尺寸 62-65%），把空間還給下面的事件動態與家人資訊。
            VStack(spacing: HCSpacing.x4) {
                ZStack {
                    // 守護圈環：同心圓 motif（與地圖盾牌、Onboarding 同一簽名語言）
                    Circle()
                        .fill(clearColor.opacity(0.04))
                        .frame(width: HCSpacing.x6 * 4.5, height: HCSpacing.x6 * 4.5)
                    Circle()
                        .stroke(clearColor.opacity(0.10), lineWidth: HCSpacing.x1 / 2)
                        .frame(width: HCSpacing.x6 * 4.5, height: HCSpacing.x6 * 4.5)
                    Circle()
                        .stroke(clearColor.opacity(0.22), lineWidth: HCSpacing.x1 / 2)
                        .frame(width: HCSpacing.x6 * 3.5, height: HCSpacing.x6 * 3.5)
                    Circle()
                        .fill(clearColor.gradient)
                        .frame(width: HCSpacing.x6 * 2.5, height: HCSpacing.x6 * 2.5)
                        .shadow(color: clearColor.opacity(0.28), radius: HCSpacing.x3, y: HCSpacing.x1)
                    Image(systemName: needsLocationUpdate ? "location.slash.fill" : "checkmark.shield.fill")
                        .font(.title.weight(.medium))
                        .foregroundStyle(.white)
                }
                // 呼吸動效：緩慢、低幅度——安心不是興奮；reduceMotion 時靜止
                .scaleEffect(breathing ? 1.03 : 1.0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                    value: breathing
                )
                .onAppear { breathing = true }
                .accessibilityHidden(true)

                // 單人態不能說「全家」——這行只顯示一個人的警戒圈，說「全家」是謊言；
                // 待更新那句沒有「全家」字眼，兩態文字相同即可
                VStack(spacing: HCSpacing.x2) {
                    Text(needsLocationUpdate ? "部分即時圈沒有回報" : (isSoloUser ? "守護中：你" : "警戒圈一切平安"))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    // 單人副句跟著事件串的口徑走：串裡有事件卻說「附近無事件」是自打嘴巴，
                    // 有事件時改說「你的圈平安」——附近有事 ≠ 圈被影響，兩件事分開講才誠實
                    Text(needsLocationUpdate
                         ? "\(staleLiveCircleCount) 個即時圈超過 15 分鐘沒有回報（可能沒電、關機或沒有網路），舊位置不會用來判斷警報。待在原地不動的家人會定時回報，不會出現在這裡。"
                         : (isSoloUser
                            ? (eventFeed.isEmpty ? "附近 24 小時無事件" : "附近有 \(eventFeed.count) 件事件，你的警戒圈平安")
                            : "目前沒有需要注意的事件，安心圈持續看守中。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .padding(.vertical, HCSpacing.x4)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            // 有事件靠近生活圈：全 App 唯一「變臉」的時刻。同樣縮小約 35-40%（6/4 → 3.75/2.5），
            // 與上面平安態的縮小比例一致，只是危險態原本就比較克制，係數起點略小。
            VStack(spacing: HCSpacing.x4) {
                ZStack {
                    Circle()
                        .fill(HCColor.danger.opacity(0.04))
                        .frame(width: HCSpacing.x6 * 3.75, height: HCSpacing.x6 * 3.75)
                    Circle()
                        .stroke(HCColor.danger.opacity(0.16), lineWidth: HCSpacing.x1 / 2)
                        .frame(width: HCSpacing.x6 * 3.75, height: HCSpacing.x6 * 3.75)
                    Circle()
                        .fill(HCColor.danger.gradient)
                        .frame(width: HCSpacing.x6 * 2.5, height: HCSpacing.x6 * 2.5)
                        .shadow(color: HCColor.danger.opacity(0.28), radius: HCSpacing.x3, y: HCSpacing.x1)
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title.weight(.medium))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(spacing: HCSpacing.x2) {
                    Text("\(status.attentionCount) 件事件靠近警戒圈")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(HCColor.danger)
                        .multilineTextAlignment(.center)
                    // 計數來源 SafetyOverview.attentionCount 已含主流媒體報導，
                    // 文案不可再只說「官方已確認」——那會把媒體來源冒充成官方。
                    Text("經官方或主流媒體確認的事件落在提醒範圍內，點開地圖確認位置與建議。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                Button {
                    router.selection = TabRouter.mapTab
                } label: {
                    Label("查看地圖", systemImage: "map.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HCColor.danger)
                .controlSize(.large)
            }
            .padding(.vertical, HCSpacing.x4)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 家人列

    private var familySection: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            ForEach(members) { member in
                memberRow(member)
            }
            Divider()
            Text("未收到安否回報不代表發生危險；請一併查看最後回報與即時位置更新時間。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .hcCard()
    }

    private func memberRow(_ member: LocalFamilyMember) -> some View {
        let nearbyEvent = nearestNearbyEvent(for: member)
        let hasNearbyEvent = nearbyEvent != nil
        let hasStaleLiveCircle = !member.isCurrentUser && member.lifeCircles.contains {
            $0.kind == .live && !$0.isActiveForAlerts
        }
        let ping = latestPing(for: member)
        let rowColor = hasNearbyEvent
            ? HCColor.danger
            : (hasStaleLiveCircle ? HCColor.attention : HCColor.safe)
        return Button {
            selectedEvent = nearbyEvent
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: member.isPlace ? "mappin.circle.fill" : "person.crop.circle.fill")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(member.isPlace ? HCColor.medical : HCColor.brand)
                    .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                    .background(
                        (member.isPlace ? HCColor.medical : HCColor.brand).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text(member.displayName).font(.body.weight(.medium))
                    if let nearbyEvent {
                        Text(nearbyEvent.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(rowColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(memberEventMetadata(member, event: nearbyEvent))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(memberStatusText(member, nearbyEvent: nil, ping: ping))
                            .font(.caption)
                            .foregroundStyle(hasStaleLiveCircle ? rowColor : .secondary)
                    }
                }
                Spacer()
                // 狀態點：文字＋顏色雙通道（色弱可辨靠文字，不只靠這顆點）
                Circle()
                    .fill(rowColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                if hasNearbyEvent {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HCColor.danger)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasNearbyEvent)
        .padding(.vertical, HCSpacing.x1)
        .frame(minHeight: 44) // 觸控與可讀性下限
        .accessibilityElement(children: .combine)
        .accessibilityHint(hasNearbyEvent ? "點兩下查看圈內最近的事件詳情" : "")
    }

    /// 同一個圈內可能同時有多件事件；首頁先打開離該成員警戒圈最近的一件，
    /// 完整清單仍可從「背景看守」或地圖查看。
    private func nearestNearbyEvent(for member: LocalFamilyMember) -> LocalSafetyEvent? {
        SafetyOverview.activeEvents(events)
            .filter { event in
                event.isOfficiallyConfirmed
                    && !AlertPolicy.evaluate(event: event, members: [member]).matches.isEmpty
            }
            .min {
                nearestCircleDistance($0, [member]) < nearestCircleDistance($1, [member])
            }
    }

    /// 這位家人最新的安否回報（比對署名；地點類成員不會有回報）
    private func latestPing(for member: LocalFamilyMember) -> SafetyPing? {
        sync.pings
            .filter { $0.senderName == member.name }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    private func memberStatusText(_ member: LocalFamilyMember, nearbyEvent: LocalSafetyEvent?, ping: SafetyPing?) -> String {
        var parts: [String] = []
        if let event = nearbyEvent {
            // 寫清楚是哪個圈、多遠、什麼事件——只寫「圈內有事件」不足以判斷要不要行動
            if let match = AlertPolicy.evaluate(event: event, members: [member])
                .matches.min(by: { $0.distanceMeters < $1.distanceMeters }) {
                let distanceText = match.distanceMeters >= 1_000
                    ? String(format: "約 %.1f 公里", Double(match.distanceMeters) / 1_000)
                    : "約 \(match.distanceMeters) 公尺"
                parts.append("「\(match.circleName)」\(distanceText)處：\(event.title)")
            } else {
                parts.append("圈內事件：\(event.title)")
            }
        } else {
            parts.append(member.isPlace ? "範圍內無事件" : "圈內無事件")
        }
        if let liveCircle = member.lifeCircles.first(where: { $0.kind == .live }) {
            parts.append(liveCircle.locationFreshnessText)
        }
        if !member.isPlace, let ping {
            let ago = ping.createdAt.formatted(.relative(presentation: .named))
            parts.append("\(ago)回報平安")
        }
        return parts.joined(separator: "・")
    }

    /// 事件標題只回答「發生什麼」；地點、距離、時間與狀態降到次要資訊，
    /// 小螢幕不必在同一長句裡找重點，也不會用省略號截掉事件結論。
    private func memberEventMetadata(_ member: LocalFamilyMember, event: LocalSafetyEvent) -> String {
        var parts = ["需要注意"]
        if let match = AlertPolicy.evaluate(event: event, members: [member])
            .matches.min(by: { $0.distanceMeters < $1.distanceMeters }) {
            let distance = match.distanceMeters >= 1_000
                ? String(format: "約 %.1f 公里", Double(match.distanceMeters) / 1_000)
                : "約 \(match.distanceMeters) 公尺"
            parts.append("「\(match.circleName)」\(distance)")
        }
        parts.append(relativeTime(event.occurredAt))
        if let liveCircle = member.lifeCircles.first(where: { $0.kind == .live }) {
            parts.append(liveCircle.locationFreshnessText)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 事件串（取代原本的背景看守摘要）

    /// 平時打開安心頁要有東西看：一行「背景看守中」的字太薄，換成可點開的事件清單。
    /// 只取近距（30 公里內）＋未封存＋未被使用者略過的事件，進行中優先、再依時間新到舊，
    /// 最多 5 筆——第一屏不塞全國事件，細節仍可從「查看全部」下鑽到提醒中心。
    private var eventFeed: [LocalSafetyEvent] {
        events
            .filter { $0.isActiveForAwareness && !$0.isArchived && !EventVisibility.isSuppressed($0) }
            .filter { nearestCircleDistance($0, members) <= NearbyScope.maxMeters }
            .sorted { lhs, rhs in
                if lhs.isEnded != rhs.isEnded { return !lhs.isEnded } // 進行中排前面
                return lhs.occurredAt > rhs.occurredAt
            }
            .prefix(5)
            .map { $0 }
    }

    /// 首頁只呈現與生活圈接近的少量事件，但不能讓「已替你過濾」看起來像「沒有資料」。
    /// 這兩個數字把背景看守工作變得可見，點進去再由提醒中心的全台動態完整閱讀。
    private var activeVisibleEvents: [LocalSafetyEvent] {
        events.filter { $0.isActiveForAwareness && !$0.isArchived && !EventVisibility.isSuppressed($0) }
    }

    private var nearbyActiveEventCount: Int {
        activeVisibleEvents.filter { nearestCircleDistance($0, members) <= NearbyScope.maxMeters }.count
    }

    private var eventFeedSection: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            monitoringSummaryRow
            if eventFeed.isEmpty {
                quietFeedRow
                nearestShelterRow
            } else {
                // D4 重問通道：曾拒絕過情境式權限卡、但通知仍未開啟時，事件串頂部再給一次機會
                NotificationReaskRow()
                ForEach(eventFeed) { event in
                    eventFeedRow(event)
                }
            }
            Divider()
            Button {
                router.openHome(.events)
            } label: {
                HStack {
                    Text("查看全部")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(HCColor.brand)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .hcCard()
        // statusHero 是淡雅漸層＋大量留白，這張卡若只是硬邊灰底會顯得突兀（上空下擠）；
        // 加一點點陰影讓它像「浮」在頁面上而非「貼」在頁面上，跟其他卡片一樣用 HCRadius.card 圓角，
        // 視覺重量往 statusHero 那邊拉近一些——不動留白量本身，只是加一點呼吸感。
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var monitoringSummaryRow: some View {
        Button {
            router.openHome(.events)
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HCColor.brand)
                    .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                    .background(HCColor.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("背景看守中")
                        .font(.subheadline.weight(.semibold))
                    Text("附近 \(nearbyActiveEventCount) 件 · 全台 \(activeVisibleEvents.count) 件進行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("背景看守中，附近 \(nearbyActiveEventCount) 件，全台 \(activeVisibleEvents.count) 件進行中。點兩下查看提醒中心")
    }

    /// D4 重問通道：情境式權限卡（A4）被按過「先不用」之後，通知就永遠沒有回頭路——
    /// 這裡是唯一的補救：事件串頂部再問一次。notDetermined 直接跳系統框；已被系統拒絕過
    /// 就只能靠使用者自己去系統設定開，這裡負責把人帶過去。授權成功後這列自然消失。
    private struct NotificationReaskRow: View {
        @State private var status: UNAuthorizationStatus = .notDetermined
        @AppStorage(SettingsKeys.notificationPromptDeclined) private var declined = false

        var body: some View {
            Group {
                if declined, status != .authorized {
                    Button {
                        Task {
                            if status == .notDetermined {
                                _ = await NotificationScheduler.requestPermission()
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                await UIApplication.shared.open(url) // 已被系統拒絕過，只能引導到系統設定重新開啟
                            }
                            status = await NotificationScheduler.authorizationStatus()
                        }
                    } label: {
                        HStack(spacing: HCSpacing.x3) {
                            Image(systemName: "bell.slash.fill")
                                .foregroundStyle(HCColor.attention)
                                .accessibilityHidden(true)
                            Text("通知未開啟，圈內有狀況不會提醒你")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("開啟")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(HCColor.brand)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                status = await NotificationScheduler.authorizationStatus()
            }
        }
    }

    /// 單筆事件列：已結束的整列灰階，色弱／可信度仍靠圖示顏色＋文字雙通道判讀
    private func eventFeedRow(_ event: LocalSafetyEvent) -> some View {
        let ended = event.isEnded
        let trustColor = event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention
        return Button {
            selectedEvent = event
            Analytics.track("event_feed_item_opened") // 漏斗：安心頁事件串點開
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: EventCategory.icon(for: event.eventType))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ended ? .secondary : trustColor)
                    .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                    .background(
                        (ended ? Color.secondary : trustColor).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text(event.isDrill ? "【演練】\(event.title)" : event.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text("\(relativeDistance(event, members)) · \(relativeTime(event.occurredAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .opacity(ended ? 0.55 : 1) // 已結束事件整列降低存在感，但不隱藏（歷史仍可查）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, HCSpacing.x1)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// 事件串全空時的安心行：告訴使用者「不是沒東西顯示，是真的平靜」
    private var quietFeedRow: some View {
        HStack(spacing: HCSpacing.x3) {
            Image(systemName: "checkmark.shield.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HCColor.safe)
                .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                .background(
                    HCColor.safe.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                )
                .accessibilityHidden(true)
            Text("這 24 小時你附近很平靜")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(minHeight: 44)
    }

    /// 全空狀態退而求其次：給一個「就算沒事，這附近有這個避難所」的實用資訊，
    /// 而不是留一片空白。座標取本人（isCurrentUser）成員的圈心；本人還沒設圈就不顯示這列。
    @ViewBuilder
    private var nearestShelterRow: some View {
        if let center = currentUserCircleCenter,
           let nearest = EmergencyResourceStore.nearest(kind: ResourceKind.shelter, latitude: center.latitude, longitude: center.longitude),
           // 資料只涵蓋台灣：人在境外（或模擬器預設舊金山）時最近避難所會是「10,344 公里外的鼻頭國小」，
           // 誠實但荒謬——超過 50 公里就不顯示這列，而不是顯示一個沒人走得到的建議
           nearest.distanceMeters <= 50_000 {
            Button {
                router.selection = TabRouter.mapTab
            } label: {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "tent.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HCColor.brand)
                        .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                        .background(
                            HCColor.brand.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text("最近避難所")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HCColor.brand)
                        Text(nearest.resource.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(shelterDistanceText(nearest.distanceMeters))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
    }

    /// 本人成員的第一個生活圈中心點（不分即時／固定圈；取不到就回 nil，呼叫端據此隱藏避難所列）
    private var currentUserCircleCenter: (latitude: Double, longitude: Double)? {
        guard let circle = members.first(where: \.isCurrentUser)?.lifeCircles.first else { return nil }
        return (circle.latitude, circle.longitude)
    }

    private func shelterDistanceText(_ meters: Int) -> String {
        meters >= 1_000
            ? String(format: "距離約 %.1f 公里", Double(meters) / 1_000)
            : "距離約 \(meters) 公尺"
    }

    /// 回顧入口：低頻查閱不配一級分頁，降為安心頁的一列
    private var historyRow: some View {
        Button {
            router.openHome(.history)
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                    )
                // 天數依方案分層跟著變（見 HistoryView／FreeTier），不寫死 30 天避免 Guardian+ 使用者看到錯誤天數
                Text("回顧過去 \(entitlementStore.isPlus ? FreeTier.plusHistoryDays : FreeTier.historyDays) 天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .hcCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 回報平安

    private var checkInButton: some View {
        Button {
            showCheckIn = true
        } label: {
            Label("回報我平安", systemImage: "checkmark.shield.fill")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, HCSpacing.x1)
        }
        .buttonStyle(.borderedProminent)
        .tint(HCColor.brand)
        .padding(.horizontal, HCSpacing.x4)
        .padding(.bottom, HCSpacing.x2)
        .background(.bar)
    }

    // MARK: - 單人態引導卡

    /// 主鈕級卡片：一個人也能守護「不是自己」的地方（爸媽家、公司），
    /// 讓單人使用者在還沒有家人可看時，App 仍有事可做
    private var guardMorePlacesCard: some View {
        Button {
            gateAddPlace()
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(HCColor.brand)
                    .frame(width: HCSpacing.x6 * 2, height: HCSpacing.x6 * 2)
                    .background(HCColor.brand.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("守護更多地方").font(.body.weight(.semibold))
                    Text("爸媽家、公司，都能設警戒圈")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hcCard()
    }

    /// 次要樣式（非滿版主鈕）：邀請不是這一刻非做不可的事，用較輕的視覺重量呈現，
    /// 避免跟上面的「守護更多地方」搶第一順位
    private var inviteFamilyCard: some View {
        Button {
            Analytics.track("home_invite_tapped") // 漏斗：單人主畫面邀請入口
            router.selection = TabRouter.familyTab
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: "person.2.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                    .background(Color.secondary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("邀請家人").font(.subheadline.weight(.medium))
                    // 問題4：隱私承諾寫進 UI——加入只共用安否回報，位置分享是另一個各自
                    // 預設關閉的開關（見 SettingsKeys.liveLocationSharingEnabled 預設值 false）
                    Text("加入後只互報平安；位置分享另外由每個人自己決定，預設關閉")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hcCard()
    }

    // MARK: - 付費閘門（地點額度）

    /// 「守護更多地方」入口共用閘門：額度用滿且非 Guardian+ 就改開付費頁——
    /// 判斷邏輯與 FamilyHomeView 共用同一份（見 [EntitlementStore.canAddPlace]）。
    private func gateAddPlace() {
        let placeCount = members.filter(\.isPlace).count
        guard entitlementStore.canAddPlace(currentCount: placeCount) else {
            Analytics.track("paywall_from_place_limit")
            showPaywall = true
            return
        }
        addingPlace = true
    }

    /// 等「新增重要地點」sheet 完全關閉（onDismiss）後才開固定圈編輯器。
    /// 用 onDismiss 取代舊的 sleep 550ms 計時接力——後者在真機上常撞到「前一個 sheet 仍在
    /// 收合就 present 下一個」被系統丟棄，導致圈編輯器沒出現、地點變孤兒（新增固定圈打不開的根因）。
    private func presentPendingCircleEditor() {
        guard let member = pendingCirclePlace else { return }
        pendingCirclePlace = nil
        newPlaceForCircle = member
    }

    /// PlaceSelectView 選定名稱後直接建立地點成員（不再經過 MemberEditorView 的打字表單），
    /// 回傳建好的成員交由呼叫端暫存，待 sheet 關閉後開固定圈編輯器。
    @discardableResult
    private func createPlace(name: String) -> LocalFamilyMember {
        let member = LocalFamilyMember(name: name, relationship: "重要地點", kind: "place")
        context.insert(member)
        context.saveReporting()
        Analytics.track("place_added")
        return member
    }
}

#if DEBUG
#Preview {
    HomeStatusView(myName: "測試者")
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
        .environment(TabRouter())
        .environment(EntitlementStore())
}
#endif
