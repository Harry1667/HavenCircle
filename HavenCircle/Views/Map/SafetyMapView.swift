import SwiftUI
import SwiftData
import MapKit

/// 安全地圖：全螢幕地圖為主體，狀態橫幅、區域警報與附近更新以浮層呈現。
struct SafetyMapView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query private var events: [LocalSafetyEvent]
    @Query private var members: [LocalFamilyMember]
    @Query private var regionAlerts: [RegionAlert]
    @State private var selected: LocalSafetyEvent?
    @State private var selectedCluster: EventCluster?
    @State private var selectedAlert: RegionAlert?

    // 圖層與過濾（顯示偏好，不影響通知決策）
    @State private var showCircles = true
    @State private var showAlertAreas = true
    /// 避難所／醫院圖層：已接上消防署／衛福部開放資料（近 6,000 筆官方座標）。
    /// 開啟後只在鏡頭夠近時顯示視野內最近的一批，全國點位一次全畫會拖垮地圖。
    /// 2026-07-23 使用者實測裁決：平時**不**預設顯示（城區帳篷海干擾主畫面），
    /// 需要的人從圖層選單開；新手帶領的保底段自帶單一避難所標記，不依賴此圖層。
    /// 2026-07-24：改用 @AppStorage 記住使用者在圖層選單裡的選擇——開過一次之後，
    /// 下次開 App 不必重新再開一次（純顯示偏好，不影響通知判定）。
    @AppStorage(SettingsKeys.mapShowShelters) private var showShelters = false
    @AppStorage(SettingsKeys.mapShowHospitals) private var showHospitals = false
    /// 目前鏡頭範圍，供資源圖層做視野內過濾
    @State private var visibleRegion: MKCoordinateRegion?
    /// 空品圖層：日常環境資訊，預設關（開啟時才抓資料）
    @State private var showAirQuality = false
    @State private var aqiStations: [AQIStation] = []
    /// 治安參考圖層：季度歷史統計，預設關；刻意用靛藍色系與紅色系的即時警報區隔
    @State private var showCrimeLayer = false
    @State private var crimeReference: CrimeReference?
    @State private var enabledTypes: Set<String> = Set(EventCategory.all)
    @State private var showUnverified = true
    @State private var isSummaryExpanded = false
    @State private var isLegendExpanded = false

    // 守護圈開場（簽名動效）：Onboarding 完成後首次進地圖才演一次
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 開場進行中：摘要卡先隱藏，鏡頭抵達生活圈後才進場
    @State private var isIntroRunning = false
    /// 盾牌確認脈衝：翻轉一次觸發 symbolEffect bounce 與成功觸覺
    @State private var shieldConfirmPulse = false

    /// nil＝全家；對應產品規格「可切換媽媽、弟弟或全家」
    @State private var selectedMemberKey: String?
    /// 鏡頭明確框住生活圈（不能用 .automatic——它會框住所有內容，
    /// 加了全台塗層後開圖會變成全台灣視角，失去「聚焦自家」的預設）
    @State private var cameraPosition: MapCameraPosition = .region(Self.taiwanWideRegion)
    /// 目前「半徑調整面板」開著的圈（circleKey）；nil＝面板關閉。
    /// 點自己的圈標記開啟／收起面板——底部滑桿取代舊的拖曳把手
    /// （2026-07-23 使用者實測裁決：拖曳跟地圖平移手勢打架、圈大時把手在螢幕邊緣、讀數膠囊被切）。
    @State private var adjustingCircleKey: String?
    /// 面板滑桿拖動中的即時預覽半徑（公尺）；只有放手／按「完成」才寫回 SwiftData，
    /// 避免每個 tick 都觸發存檔。進入調整模式時以該圈目前的 radiusMeters 初始化。
    @State private var previewRadiusMeters: Double = 1_000
    /// 地圖的具名座標空間：guidance 脈動圈換算螢幕直徑要用 proxy.convert（見 circleScreenDiameter）
    private static let mapSpace = "safetyMapSpace"
    /// 跨縣市以上視野改顯示數字叢集，避免全國尺度的事件標記互相遮擋。
    private static let eventClusterZoomThreshold: CLLocationDegrees = 1.5
    /// 每個方向切成八格，兼顧叢集密度與線性分組成本。
    private static let eventClusterGridDivisions = 8
    /// 「警戒圈可拖動調整」的提示：第一次點開事件、關掉詳情後顯示一次（不在帶領卡就先講）
    @AppStorage(SettingsKeys.seenCircleAdjustHint) private var seenCircleAdjustHint = false
    @State private var showCircleAdjustHint = false
    /// 這次點開的事件關掉後，是否要接著顯示拖圈提示
    @State private var pendingCircleAdjustHint = false
    /// 第一次進地圖的「目標自己動」帶領：0＝脈動你的警戒圈，1＝脈動附近事件，nil＝結束（幾乎不用文字）
    @AppStorage(SettingsKeys.firstRunCoachingPending) private var firstRunCoachingPending = false
    @State private var guidanceStep: Int?
    /// 段 1 保底路徑（脈動最近避難所）為了讓兩點都入鏡而挪動過鏡頭時記為 true，
    /// 帶領結束要拉回原本的生活圈鏡頭，不留在挪過的位置
    @State private var guidanceCameraAdjusted = false
    /// 本次是否為「新手第一次進地圖」的 session：FirstRunSetup 建圈後會背景校正圈心，
    /// 校正落地時鏡頭要跟著重新取景；一般使用中則不能因為圈心變動就亂動鏡頭
    @State private var isFirstRunSession = false
    /// A4：帶領結束後的情境式通知權限卡是否顯示（只在權限 .notDetermined 時才會被種下 true）
    @State private var showNotificationPrompt = false
    // 用 @AppStorage 與設定頁共用同一旗標
    @AppStorage(SettingsKeys.alertsPaused) private var isPaused = false
    /// 點靜音鈕要先跳確認框才真的暫停；恢復不用確認（安全動作，越快越好）
    @State private var showMuteConfirmation = false

    /// 圖例首次自動展開一次的旗標。刻意用字串常數放在這裡（不進 SettingsKeys）——
    /// 這是本檔專屬、跟其他設定無關的一次性 UI 提示旗標，沒有共用需求。
    private static let legendAutoExpandedKey = "safetyMap.hasAutoExpandedLegend"
    @AppStorage(SafetyMapView.legendAutoExpandedKey) private var hasAutoExpandedLegend = false

    /// 目前顯示對象（家人切換器過濾後）
    private var visibleMembers: [LocalFamilyMember] {
        guard let key = selectedMemberKey else { return members }
        return members.filter { $0.memberKey == key }
    }

    private var allActiveEvents: [LocalSafetyEvent] {
        SafetyOverview.activeEvents(events)
    }

    /// 套用圖層過濾後、顯示在地圖與卡片上的事件
    private var filteredEvents: [LocalSafetyEvent] {
        allActiveEvents.filter {
            enabledTypes.contains($0.eventType) && (showUnverified || $0.isOfficiallyConfirmed)
        }
    }

    /// 地圖尚未回報鏡頭範圍時維持逐筆標記，避免首屏狀態不確定。
    private var isEventClusteringEnabled: Bool {
        guard let region = visibleRegion else { return false }
        return region.span.latitudeDelta > Self.eventClusterZoomThreshold
            || region.span.longitudeDelta > Self.eventClusterZoomThreshold
    }

    /// 遠距視野只聚合真實事件；演練標記一律保留原本的鈴鐺圖示。
    private var eventClusters: [EventCluster] {
        guard isEventClusteringEnabled, let region = visibleRegion else { return [] }
        let items = filteredEvents.lazy
            .filter { !$0.isDrill }
            .map {
                EventClusterItem(
                    event: $0,
                    eventKey: $0.eventKey,
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    isOfficiallyConfirmed: $0.isOfficiallyConfirmed,
                    occurredAt: $0.occurredAt
                )
            }
        return EventClustering.cluster(
            items: Array(items),
            region: region,
            gridDivisions: Self.eventClusterGridDivisions
        )
    }

    private var drillEvents: [LocalSafetyEvent] {
        filteredEvents.filter(\.isDrill)
    }

    /// 安全狀態一律以「未過濾」的事件計算——聚合邏輯與安心頁共用 SafetyStatus，
    /// 兩頁對「平安與否」的說法永遠一致
    private var status: SafetyOverview {
        SafetyOverview.compute(events: events, regionAlerts: regionAlerts, members: visibleMembers)
    }

    private var attentionCount: Int { status.attentionCount }
    private var confirmingCount: Int { status.confirmingCount }
    private var elsewhereCount: Int { status.elsewhereCount }

    private var activeRegionAlerts: [RegionAlert] {
        regionAlerts.filter { !$0.isEnded }
    }

    private var visibleCircles: [LocalLifeCircle] {
        visibleMembers.flatMap(\.lifeCircles)
    }

    /// 圖例用：目前畫面上有圈的成員，本人排第一、其餘依名字排序，
    /// 讓「顏色 → 是誰」的對照表和地圖上實際畫出來的圈一致。
    private var circleLegendMembers: [LocalFamilyMember] {
        visibleMembers
            .filter { !$0.lifeCircles.isEmpty }
            .sorted { a, b in
                if a.isCurrentUser != b.isCurrentUser { return a.isCurrentUser }
                return a.name < b.name
            }
    }

    /// 地圖上圈標記旁的名字 chip 文字：本人只顯示圈名（「我」再重複一次沒意義），
    /// 其他家人加上姓名前綴——辨識「這是誰的圈」不能只靠色盤，色相再怎麼拉開，
    /// 家人一多還是會挑到相近色，名字是唯一保證不會誤讀的通道。
    private func circleLabelText(_ circle: LocalLifeCircle) -> String {
        guard let member = circle.member, !member.isCurrentUser else { return circle.name }
        return "\(member.name)．\(circle.name)"
    }

    /// 圈標記的無障礙用類型描述：避開 LocalLifeCircle.kind.title 裡的「固定地點」字樣
    /// （使用者可見文字禁用詞），改用「守護地點」措辭，語意相同。
    private func circleKindAccessibilityText(_ kind: LifeCircleKind) -> String {
        kind == .live ? "即時警戒圈" : "守護地點警戒圈"
    }

    /// 尚未開啟即時圈的家人，仍可顯示最近一次主動安否回報的位置。
    private var familyPingAnnotations: [SafetyPing] {
        let liveNames = Set(sync.liveLocations.filter(\.isSharing).map(\.displayName))
        var latest: [String: SafetyPing] = [:]
        for ping in sync.pings where ping.hasLocation && !liveNames.contains(ping.senderName) {
            if let kept = latest[ping.senderName], kept.createdAt >= ping.createdAt { continue }
            latest[ping.senderName] = ping
        }
        return Array(latest.values)
    }

    /// 框住目前顯示對象所有生活圈的鏡頭範圍
    private var circlesRegion: MapCameraPosition {
        let circles = visibleMembers.flatMap(\.lifeCircles)
        // 沒有生活圈時仍從台灣開始，不能把第一次開圖交給 MapKit 的任意海外預設位置。
        guard !circles.isEmpty else { return .region(Self.taiwanWideRegion) }
        let lats = circles.map(\.latitude)
        let lons = circles.map(\.longitude)
        // 邊界加緩衝：至少涵蓋最大半徑的兩倍，避免圈貼著螢幕邊
        let maxRadiusDeg = Double(circles.map(\.radiusMeters).max() ?? 1000) / 111_000 * 2.5
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(lats.max()! - lats.min()! + maxRadiusDeg, 0.02),
            longitudeDelta: max(lons.max()! - lons.min()! + maxRadiusDeg, 0.02)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    /// 統一「點事件 marker → 選中它」的入口。事件詳情用 `.sheet(item: $selected)` 呈現，
    /// 而詳情卡的 `.presentationBackgroundInteraction` 刻意讓地圖在小尺寸卡片顯示期間仍可互動——
    /// 代表使用者能在事件 A 的卡片還開著時直接點事件 B 的 marker，`selected` 會從一個非 nil 值
    /// 直接換成另一個非 nil 值。SwiftUI 的 `.sheet(item:)` 遇到這種情況不會銷毀重建同一張 sheet，
    /// `MapEventSheet`／`EventDetailView` 內部的 `@State`（選中 detent、安否回報結果、AI 分析…）
    /// 會殘留上一個事件的舊狀態，使用者看到的就是「換了事件但畫面沒跟著換」的 bug。
    /// 修法比照下面 `selectedCluster` → `selected` 那條路徑：先關掉再等一小段時間才開新的，
    /// 強制 SwiftUI 真的銷毀舊 sheet、重建一張乾淨的。
    private func selectEvent(_ event: LocalSafetyEvent) {
        guard selected != nil, selected?.id != event.id else {
            selected = event
            return
        }
        selected = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            selected = event
        }
    }

    var body: some View {
        NavigationStack {
            map
                // 功能導覽直接讀取地圖實際版面，不再用機型相關的安全區域常數猜位置。
                .onAppear {
                    playGuardianIntroIfNeeded()
                    // 地圖藍點需要定位權限；只在未決定時跳系統框，拒絕過就不再打擾
                    LocationService.shared.requestPermissionIfNeeded()
                }
                .task {
                    await sync.fetchPings()
                    await sync.fetchLiveLocations(context: modelContext)
                }
                // 第一次進地圖：消耗旗標，稍等地圖穩定後開始「目標自己動」的帶領（脈動圈→脈動事件）
                .task {
                    #if DEBUG
                    // --guide-step N：直接跳到第 N 段帶領，供截圖
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "--guide-step"),
                       args.indices.contains(i + 1), let n = Int(args[i + 1]) {
                        firstRunCoachingPending = false
                        isFirstRunSession = true
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation { guidanceStep = max(0, n) }
                        return
                    }
                    #endif
                    guard firstRunCoachingPending else { return }
                    firstRunCoachingPending = false
                    isFirstRunSession = true
                    try? await Task.sleep(for: .milliseconds(700))
                    Analytics.track("guidance_started") // 漏斗：帶領開始（debug --guide-step 不記）
                    Analytics.track("map_data_shown") // 漏斗：新手首屏三件套（塗層＋資源點＋帶領）鋪出，只在這裡記一次
                    withAnimation { guidanceStep = 0 }
                }
                // 圖例找不到是本次走查最多人卡住的點之一：首次進地圖時自動展開一次圖例，
                // 幾秒後自動收合；使用者若在期間自己點圖例卡的 ✕ 或點地圖，也會提前收合
                // （isLegendExpanded 已被使用者改成 false，這裡的收合只是「順手再設一次」，無副作用）。
                // 旗標消耗式，只演一次，之後就跟其他圖例互動一樣要手動點開。
                .task {
                    guard !hasAutoExpandedLegend, legendHasContent else { return }
                    hasAutoExpandedLegend = true
                    try? await Task.sleep(for: .milliseconds(1_200))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded = true }
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded = false }
                }
                #if DEBUG
                // 截圖用：--adjust-circle 自動打開自己圈的半徑調整面板（headless 無法點圈觸發）
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--adjust-circle") else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let mine = visibleCircles.first(where: { $0.member?.isCurrentUser == true }) else { return }
                    previewRadiusMeters = Double(mine.radiusMeters)
                    adjustingCircleKey = mine.circleKey
                }
                #endif
                .overlay(alignment: .top) {
                    topOverlays
                }
                // 圖例：地圖有多層塗色，沒有圖例評審與使用者都無法自行解讀顏色
                // （含治安層免責：統計≠即時安全程度，避免標籤化社區——產品倫理要求）
                .overlay(alignment: .bottomLeading) {
                    legendPanel
                }
                // 半徑調整面板開著時取代附近卡片列（同一個 safe area 插槽，天然避開分頁列與事件卡片列）
                .safeAreaInset(edge: .bottom) {
                    if adjustingCircleKey != nil {
                        circleAdjustPanel
                    } else {
                        nearbyStrip
                    }
                }
                .navigationTitle("地圖")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // #3：只有自己（沒有家人）時不顯示「全家/我」切換器——沒有對象可切，
                    // 出現「全家」會讓人以為已經有家人。members 含本人，故 >1 才代表真的有家人。
                    if members.count > 1 {
                        memberPicker
                    }
                    filterMenu
                    pauseButton
                    // 三個主分頁右上角統一放同一顆設定齒輪
                    Button("設定", systemImage: "gearshape") { router.showSettings = true }
                }
                .sheet(item: $selected) {
                    MapEventSheet(event: $0, members: members)
                }
                .sheet(item: $selectedCluster) { cluster in
                    EventClusterListSheet(cluster: cluster) { event in
                        selectedCluster = nil
                        // 等叢集清單退場後再開既有事件詳情，避免兩張 sheet 爭用呈現時機。
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            selected = event
                        }
                    }
                }
                .sheet(item: $selectedAlert) {
                    RegionAlertDetailView(alert: $0, members: members)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        // iPad 會忽略 presentationDetents 而放大成整頁 sheet，這裡收斂成 form 尺寸
                        .formPresentationSizing()
                }
                // 點事件才教拖圈：點開事件詳情、關掉後，第一次跳一張拖圈提示
                .onChange(of: selected) { oldValue, newValue in
                    if newValue != nil {
                        if !seenCircleAdjustHint { pendingCircleAdjustHint = true }
                    } else if oldValue != nil, pendingCircleAdjustHint {
                        pendingCircleAdjustHint = false
                        seenCircleAdjustHint = true
                        Analytics.track("circle_adjust_hint_shown") // 漏斗：拖圈教學出現
                        withAnimation { showCircleAdjustHint = true }
                    }
                }
                .overlay {
                    if showCircleAdjustHint {
                        CoachCard(
                            icon: "hand.draw.fill",
                            text: "點你的警戒圈，可以調整範圍",
                            progress: nil,
                            onTap: { withAnimation { showCircleAdjustHint = false } }
                        )
                    }
                }
                // 帶領進行中：全螢幕透明層接住點擊往下一段，底部一個小小「輕點繼續」
                .overlay {
                    if guidanceStep != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { advanceGuidance() }
                            .overlay(alignment: .bottom) {
                                Text("輕點繼續")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(.bottom, 110)
                            }
                    }
                }
                // A4：帶領結束後的情境式通知權限卡（見 scheduleNotificationPromptIfNeeded）
                .overlay {
                    if showNotificationPrompt {
                        NotificationPromptCard {
                            withAnimation { showNotificationPrompt = false }
                            landOnFamilyAfterGuidance()
                        }
                    }
                }
        }
    }

    // MARK: - 地圖本體

    /// 區域警報塗層：受影響行政區整片著色（依嚴重度取色，同區取最嚴重）。
    /// 為什麼是塗層不是大頭針：強風/豪雨這類警報影響的是「一整個行政區」，
    /// 釘一個點會錯誤暗示事件發生在該點。
    private struct AlertArea: Identifiable {
        let id: String
        let ring: [CLLocationCoordinate2D]
        let severityRank: Int
    }

    private var alertAreas: [AlertArea] {
        // 只塗天災與公共安全：交通/民生類（捷運誤點、局部停水）把整區塗色會造成
        // 視覺洪水，反而稀釋真正的危險訊號；它們仍在提醒中心的分組清單裡
        let paintable = activeRegionAlerts.filter { ["天災", "公共安全"].contains($0.group) }
        // 同一區被多則警報涵蓋時取最嚴重的顏色
        var severityByTown: [String: (rank: Int, severity: String)] = [:]
        for alert in paintable {
            let rank = RegionAlert.severityRank(alert.severity)
            for town in alert.affectedDistricts where town != Districts.unspecified {
                if rank > (severityByTown[town]?.rank ?? -1) {
                    severityByTown[town] = (rank, alert.severity)
                }
            }
        }
        return severityByTown.flatMap { town, info in
            DistrictBoundaries.shared.districts(named: town).flatMap { district in
                district.rings.enumerated().map { index, ring in
                    AlertArea(id: "\(district.county)-\(town)-\(index)", ring: ring, severityRank: info.rank)
                }
            }
        }
    }

    // 嚴重度排序與配色已上移到 RegionAlert extension（Theme.swift）：
    // 警報卡、塗層、圖例共用同一套，避免「卡片的紅」與「地圖的紅」不一致

    /// 治安參考塗層：只塗「高於全國中位數」的行政區（四分位分級），
    /// 低於中位數不塗——全塗會讓圖層變成無資訊的雜訊。
    private var crimeAreas: [AlertArea] {
        guard let reference = crimeReference, !reference.districts.isEmpty else { return [] }
        let totals = reference.districts.map(\.total).sorted()
        let p50 = totals[totals.count / 2]
        let p75 = totals[totals.count * 3 / 4]
        let p90 = totals[min(totals.count * 9 / 10, totals.count - 1)]
        func normalize(_ s: String) -> String { s.replacingOccurrences(of: "臺", with: "台") }

        return reference.districts.flatMap { district -> [AlertArea] in
            let tier: Int
            switch district.total {
            case let t where t >= p90: tier = 3
            case let t where t >= p75: tier = 2
            case let t where t >= p50: tier = 1
            default: return [] // 低於中位數不塗
            }
            return DistrictBoundaries.shared.districts(named: district.town)
                .filter { normalize($0.county) == normalize(district.county) } // 縣市也要對上，避免同名區誤塗
                .flatMap { boundary in
                    boundary.rings.enumerated().map { index, ring in
                        AlertArea(id: "crime-\(district.county)-\(district.town)-\(index)",
                                  ring: ring, severityRank: tier)
                    }
                }
        }
    }

    private static func crimeOpacity(_ tier: Int) -> Double {
        switch tier {
        case 3: 0.32
        case 2: 0.20
        default: 0.10
        }
    }

    private var map: some View {
        MapReader { proxy in
        Map(position: $cameraPosition) {
            if showCrimeLayer {
                ForEach(crimeAreas) { area in
                    MapPolygon(coordinates: area.ring)
                        .foregroundStyle(HCColor.reference.opacity(Self.crimeOpacity(area.severityRank)))
                }
            }
            if showAlertAreas {
                ForEach(alertAreas) { area in
                    // 塗層濃度依嚴重度分級：大雨特報這類提醒級常一次涵蓋兩百多個行政區，
                    // 同等濃度會讓整個雙北鋪滿紅框（實機回報「地圖很亂」的主因之一）。
                    // 警戒／危急維持醒目；留意／注意退成極淡底色、幾乎無邊框
                    let isSevere = area.severityRank >= 2
                    let color = RegionAlert.severityColor(rank: area.severityRank)
                    MapPolygon(coordinates: area.ring)
                        .foregroundStyle(color.opacity(isSevere ? 0.20 : 0.07))
                        .stroke(color.opacity(isSevere ? 0.6 : 0.18), lineWidth: isSevere ? 1.5 : 0.5)
                }
            }
            if showCircles {
                ForEach(visibleCircles) { circle in
                    // 顏色改依「守護對象是誰」而非「圈的類型」分——同一個人的即時圈與固定圈
                    // 現在會是同一色，不同人盡量錯開；本人固定拿綠色（沿用舊語意）
                    let circleColor = CircleColorPalette.color(
                        for: circle.member?.memberKey ?? circle.circleKey,
                        isCurrentUser: circle.member?.isCurrentUser == true
                    )
                    let renderedColor = circle.isActiveForAlerts ? circleColor : Color.gray
                    // 調整面板開著時，這顆圈即時吃滑桿預覽值（放手前不寫回 SwiftData）；
                    // 沒在調整就照常顯示已存檔的半徑
                    let displayRadius = adjustingCircleKey == circle.circleKey
                        ? previewRadiusMeters
                        : Double(circle.radiusMeters)
                    MapCircle(
                        center: .init(latitude: circle.latitude, longitude: circle.longitude),
                        radius: CLLocationDistance(displayRadius)
                    )
                    .foregroundStyle(renderedColor.opacity(0.08))
                    .stroke(renderedColor.opacity(0.5), lineWidth: 1.5)
                    Annotation(
                        circle.name,
                        coordinate: .init(latitude: circle.latitude, longitude: circle.longitude)
                    ) {
                        // 降噪：圈標記只留小圖示＋自訂色名字 chip（類型交給圖示與顏色）；
                        // 即時圈保留過期提示，那是安全判斷必要資訊。
                        // 2026-07-24：色盤色距拉開後仍可能撞色（同色相鄰兩人），辨識不能只靠純色——
                        // 名字 chip 直接標「對象是誰」，用跟圈同色的描邊／文字，色弱使用者也能對照。
                        VStack(spacing: 1) {
                            Image(systemName: circle.kind.iconName)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(renderedColor, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            // #5：地圖圈標記文字改語意字體（.caption2 是最小的可縮放級距），
                            // 讓「字體大小」設定調整時這裡也看得出變化；圖示尺寸維持固定（純裝飾）
                            Text(circleLabelText(circle))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(renderedColor)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(renderedColor.opacity(0.6), lineWidth: 1))
                            if circle.kind == .live {
                                Text(circle.locationFreshnessText)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(circle.isActiveForAlerts || circle.member?.isCurrentUser == true ? .secondary : HCColor.attention)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(circleLabelText(circle))，\(circleKindAccessibilityText(circle.kind))，警戒半徑 \(circle.radiusMeters) 公尺，\(circle.locationFreshnessText)"
                        )
                        // 點自己的圈＝開啟／收起底部半徑調整面板
                        .onTapGesture {
                            guard circle.member?.isCurrentUser == true else { return }
                            if adjustingCircleKey == circle.circleKey {
                                finishAdjustingCircle()
                            } else {
                                previewRadiusMeters = Double(circle.radiusMeters)
                                withAnimation(.easeInOut(duration: 0.2)) { adjustingCircleKey = circle.circleKey }
                            }
                        }
                    }
                    // 名字 chip 已經內建在標記內容裡，MapKit 內建標題文字不需要重複再畫一次
                    .annotationTitles(.hidden)
                }
            }
            // 資源點放在事件標記之前宣告，讓事件永遠蓋在資源點上層。
            // limit 收斂為「最近的少數幾個」（resources 依離鏡頭中心距離排序）：
            // 圖層改預設開之後，城區視野內全量顯示會淹沒警戒圈主角（首屏 ~30 頂帳篷），
            // 保底資源的意圖是「最近的在哪」不是「全部在哪」。
            if showShelters, let region = resourceRegion {
                ForEach(EmergencyResourceStore.resources(kind: ResourceKind.shelter, in: region, limit: 12)) { resource in
                    resourceAnnotation(resource, icon: "tent.fill", color: HCColor.safe)
                }
            }
            if showHospitals, let region = resourceRegion {
                ForEach(EmergencyResourceStore.resources(kind: ResourceKind.hospital, in: region, limit: 6)) { resource in
                    resourceAnnotation(resource, icon: "cross.case.fill", color: HCColor.medical)
                }
            }
            if isEventClusteringEnabled {
                ForEach(eventClusters) { cluster in
                    Annotation(
                        "事件叢集",
                        coordinate: cluster.coordinate
                    ) {
                        Button {
                            selectedCluster = cluster
                        } label: {
                            Text("\(cluster.count)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                                .frame(width: 40, height: 40)
                                .background(
                                    cluster.hasOfficialConfirmed ? HCColor.danger : HCColor.attention,
                                    in: Circle()
                                )
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .accessibilityLabel(
                            "\(cluster.count) 件事件，\(cluster.hasOfficialConfirmed ? "含官方已確認事件" : "事件皆在持續確認中")，點擊查看清單"
                        )
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(drillEvents) { event in
                    Annotation(event.isDrill ? "演練" : event.eventType,
                               coordinate: .init(latitude: event.latitude, longitude: event.longitude)) {
                        Button {
                            selectEvent(event)
                        } label: {
                            // 演練不參與叢集，遠距視野仍沿用原本的個別鈴鐺標記。
                            Image(systemName: event.isDrill
                                  ? "bell.and.waves.left.and.right"
                                  : EventCategory.icon(for: event.eventType))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .accessibilityLabel("\(event.title)，\(event.trustStatus)，\(event.approximateLocation)")
                    }
                    .annotationTitles(.hidden)
                }
            } else {
                ForEach(filteredEvents) { event in
                    Annotation(event.isDrill ? "演練" : event.eventType,
                               coordinate: .init(latitude: event.latitude, longitude: event.longitude)) {
                        Button {
                            selectEvent(event)
                        } label: {
                            // 兩套視覺通道：圖示＝事件類型、顏色＝可信度（官方紅／確認中琥珀）；
                            // 白色外圈讓標記在任何底圖上都可辨識
                            Image(systemName: event.isDrill
                                  ? "bell.and.waves.left.and.right"
                                  : EventCategory.icon(for: event.eventType))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .accessibilityLabel("\(event.title)，\(event.trustStatus)，\(event.approximateLocation)")
                    }
                    // 事件 pin 不顯示文字標籤：圖示已表達類型，縮遠時一堆「重大交通事故」
                    // 文字互相壓、被鄰近 pin 截斷（實機回報）；點 pin 後底部卡片有完整標題
                    .annotationTitles(.hidden)
                }
            }
            // 第一次帶領：脈動圈把目光吸到「你的警戒圈」或「附近事件」（目標自己動、幾乎不用文字）
            if guidanceStep == 0, let mine = guidanceCircle {
                let diameter = circleScreenDiameter(mine, proxy: proxy)
                Annotation("", coordinate: .init(latitude: mine.latitude, longitude: mine.longitude)) {
                    PulseRing(color: HCColor.brand, maxDiameter: diameter)
                        .overlay(alignment: .center) {
                            guidancePill("你的守護範圍", color: HCColor.brand)
                                .offset(y: -(diameter / 2) - 18)
                        }
                }
                .annotationTitles(.hidden)
            }
            if guidanceStep == 1, let ev = guidanceEvent {
                Annotation("", coordinate: .init(latitude: ev.latitude, longitude: ev.longitude)) {
                    PulseRing(color: HCColor.danger, maxDiameter: 96)
                        .overlay(alignment: .center) {
                            guidancePill("附近的事件", color: HCColor.danger)
                                .offset(y: -66)
                        }
                }
                .annotationTitles(.hidden)
            }
            // 段 1 保底路徑：圈心附近沒有事件時，改脈動最近的避難收容所——
            // 資料驗證顯示多數地區平時沒有近距事件，這是常態路徑，品質要求與事件分支相同（用「安心」的品牌綠，不是警報紅）
            if guidanceStep == 1, guidanceEvent == nil, let shelter = guidanceShelter {
                Annotation("", coordinate: .init(latitude: shelter.resource.latitude, longitude: shelter.resource.longitude)) {
                    // 資源圖層預設關閉後，保底段自帶一枚帳篷標記——脈動要有實體目標才不會指著空地
                    ZStack {
                        PulseRing(color: HCColor.safe, maxDiameter: 96)
                        Circle()
                            .fill(HCColor.safe)
                            .frame(width: 28, height: 28)
                        Image(systemName: "tent.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .overlay(alignment: .center) {
                        guidancePill("離你最近的避難所", color: HCColor.safe)
                            .offset(y: -66)
                    }
                }
                .annotationTitles(.hidden)
            }
            // 自己的位置（藍點）：需要 when-in-use 權限，未授權時 MapKit 自動不畫。
            // ⚠️ UserAnnotation() 本身會在 Map 顯示時直接向 MapKit 內部的定位管理器要權限，
            // 完全繞過 LocationService 那層——--skip-location-prompt 只擋得住我們自己呼叫的
            // requestPermissionIfNeeded／requestAlwaysPermission，擋不住這個，所以自動化截圖
            // 模式下要整個不畫這個 annotation，系統對話框才不會跳出來卡住畫面。
            #if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--skip-location-prompt") {
                UserAnnotation()
            }
            #else
            UserAnnotation()
            #endif
            // 沒有即時圈時，以最近一次自願安否回報位置作為降級資訊。
            ForEach(familyPingAnnotations, id: \.id) { ping in
                Annotation(ping.senderName,
                           coordinate: .init(latitude: ping.latitude ?? 0, longitude: ping.longitude ?? 0)) {
                    VStack(spacing: 2) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(ping.status == .safe ? HCColor.safe : HCColor.danger, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        // #5：同上，改語意字體讓字級可調
                        Text(ping.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("\(ping.senderName) \(ping.status.rawValue)，回報於\(ping.createdAt.formatted(date: .omitted, time: .shortened))，位置\(ping.placeName ?? "未知")")
                }
            }
            if showAirQuality {
                ForEach(aqiStations) { station in
                    Annotation(station.name ?? "測站",
                               coordinate: .init(latitude: station.latitude, longitude: station.longitude)) {
                        Text("\(station.aqi)")
                            .font(.caption2.bold())
                            .foregroundStyle(station.aqi > 100 ? .white : .black)
                            .padding(6)
                            .background(station.color, in: Circle())
                            .accessibilityLabel("\(station.name ?? "")空品測站，AQI \(station.aqi)，\(station.status ?? "")")
                    }
                }
            }
        }
        // 降噪底圖：壓低底圖彩度並排除 Apple Maps 的 POI（餐廳、商店……），
        // 讓警報塗層、生活圈與事件標記成為畫面主角，而不是跟底圖搶注意力
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        // 開啟空品圖層時才抓資料（不開不花流量）
        .onChange(of: showAirQuality) { _, isOn in
            guard isOn, aqiStations.isEmpty else { return }
            Task {
                do {
                    aqiStations = try await AirQualityService.fetchStations()
                } catch {
                    AppLog.dataError("空品資料抓取失敗：\(error.localizedDescription)")
                }
            }
        }
        .onChange(of: showCrimeLayer) { _, isOn in
            guard isOn, crimeReference == nil else { return }
            Task {
                do {
                    crimeReference = try await CrimeReferenceService.fetch()
                } catch {
                    AppLog.dataError("治安統計抓取失敗：\(error.localizedDescription)")
                }
            }
        }
        // 鏡頭停下才更新（.onEnd），拖曳過程不重算資源過濾
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        // 新手首次進地圖：FirstRunSetup 背景把圈心從台北車站校正到實際位置，
        // 圈心落地時鏡頭要重新框住校正後的圈，否則會停在校正前的暫時位置。
        // 只在首次 session 生效——一般使用中不能因為圈心變動就搶走使用者手動平移的鏡頭
        .onChange(of: mineCircleCenterKey) { _, newKey in
            guard isFirstRunSession, !newKey.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.8)) { cameraPosition = circlesRegion }
        }
        // 具名座標空間：guidance 脈動圈換算螢幕直徑要用 proxy.convert（見 circleScreenDiameter）
        .coordinateSpace(.named(Self.mapSpace))
        // 調整面板開著時，點地圖其他處＝存檔＋收起面板；圖例展開時，點地圖其他處＝收合圖例。
        // 兩者共用同一個 onTapGesture，只加在各自模式成立時才動作，
        // 不影響平時的地圖平移／縮放手勢，也不吃大頭針/標註本身的點擊（onTapGesture 不吃 pan/pinch，
        // 且標註自己的手勢辨識優先於地圖底層這個 tap，實測與既有的調整面板收合邏輯一致）
        .onTapGesture {
            if adjustingCircleKey != nil {
                finishAdjustingCircle()
            }
            if isLegendExpanded {
                withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded = false }
            }
        }
        }
    }

    /// 圈的正東邊緣座標：guidance 脈動圈（circleScreenDiameter）拿來換算螢幕直徑用
    private static func edgeCoordinate(of circle: LocalLifeCircle) -> CLLocationCoordinate2D {
        let latRad = circle.latitude * .pi / 180
        let metersPerDegLon = 111_320 * max(cos(latRad), 0.01)
        let deltaLon = Double(circle.radiusMeters) / metersPerDegLon
        return CLLocationCoordinate2D(latitude: circle.latitude, longitude: circle.longitude + deltaLon)
    }

    // MARK: - 底部半徑調整面板（Find My 地理圍欄式，取代舊拖曳把手）

    /// 收起調整面板：半徑真的變了才寫回 SwiftData＋記漏斗事件，避免「開了面板但沒動滑桿」也算一次調整、
    /// 也避免沒變更卻多一次沒必要的存檔。不論是按「完成」、點地圖其他處、或再點一次自己的圈都會走這條路。
    private func finishAdjustingCircle() {
        if let key = adjustingCircleKey,
           let circle = visibleCircles.first(where: { $0.circleKey == key }) {
            let newValue = Int(previewRadiusMeters)
            if circle.radiusMeters != newValue {
                circle.radiusMeters = newValue
                modelContext.saveReporting()
                Analytics.track("circle_adjusted") // 漏斗：真的調整了警戒圈半徑
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { adjustingCircleKey = nil }
    }

    /// 半徑讀數格式化：>=1000 公尺顯示公里（一位小數），沿用事件卡片距離讀數的既有格式慣例
    private static func radiusDisplayText(_ meters: Int) -> String {
        meters >= 1000
            ? String(format: "%.1f 公里", Double(meters) / 1_000)
            : "\(meters) 公尺"
    }

    /// 底部滑桿面板：拖滑桿即時改 previewRadiusMeters（地圖上的圈跟著即時縮放），
    /// 放手不會存檔——真正寫入 SwiftData 的時機只有 finishAdjustingCircle。
    @ViewBuilder
    private var circleAdjustPanel: some View {
        if let key = adjustingCircleKey, let circle = visibleCircles.first(where: { $0.circleKey == key }) {
            VStack(spacing: HCSpacing.x3) {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "scope")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HCColor.brand)
                        .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                        .background(HCColor.brand.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text(circle.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text("警戒半徑")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: HCSpacing.x3)
                    Button("完成") { finishAdjustingCircle() }
                        .font(.subheadline.weight(.medium))
                }
                Text(Self.radiusDisplayText(Int(previewRadiusMeters)))
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
                Slider(value: $previewRadiusMeters, in: 200...5_000, step: 100)
                    .tint(HCColor.brand)
                    .accessibilityLabel("警戒半徑")
                    .accessibilityValue(Self.radiusDisplayText(Int(previewRadiusMeters)))
            }
            .padding(HCSpacing.x4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                    .stroke(HCColor.brand.opacity(0.16), lineWidth: 1)
            )
            .padding(.horizontal, HCSpacing.x4)
            .padding(.bottom, HCSpacing.x2)
            // iPad 上限制面板寬度並置中，外層仍貼底（safeAreaInset(edge: .bottom) 負責貼底，不受影響）
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 第一次帶領（目標自己動、幾乎不用文字）

    /// 帶領要指的「你的圈」：優先本人的圈，否則第一個可見圈。
    private var guidanceCircle: LocalLifeCircle? {
        visibleCircles.first { $0.member?.isCurrentUser == true } ?? visibleCircles.first
    }

    /// 自己的圈心座標指紋：FirstRunSetup 背景校正圈心後這個字串會變，
    /// 供 .onChange 偵測「圈心剛落地」，圈不存在就回空字串（不觸發）
    private var mineCircleCenterKey: String {
        guard let circle = guidanceCircle else { return "" }
        return "\(circle.latitude),\(circle.longitude)"
    }

    /// 帶領要指的「附近事件」：只挑圈心 2.5 公里內、大概在畫面裡的事件；沒有就回 nil（不指螢幕外的東西）。
    private var guidanceEvent: LocalSafetyEvent? {
        guard let circle = guidanceCircle else { return nil }
        let center = CLLocation(latitude: circle.latitude, longitude: circle.longitude)
        return filteredEvents.first { event in
            let loc = CLLocation(latitude: event.latitude, longitude: event.longitude)
            return center.distance(from: loc) <= 2_500
        }
    }

    /// 帶領段 1 的保底目標：圈心附近沒事件時，改指「離你最近的避難收容所」。
    /// 資料清洗後座標可信，理論上不會找不到；找不到就回 nil（帶領直接結束）。
    private var guidanceShelter: (resource: EmergencyResource, distanceMeters: Int)? {
        guard let circle = guidanceCircle else { return nil }
        return EmergencyResourceStore.nearest(
            kind: ResourceKind.shelter, latitude: circle.latitude, longitude: circle.longitude
        )
    }

    /// 座標是否落在目前鏡頭實際看得到的範圍內（用來判斷保底段要不要挪鏡頭）
    private func isCoordinateVisible(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let region = visibleRegion else { return false }
        let latHalf = region.span.latitudeDelta / 2
        let lonHalf = region.span.longitudeDelta / 2
        return abs(coordinate.latitude - region.center.latitude) <= latHalf
            && abs(coordinate.longitude - region.center.longitude) <= lonHalf
    }

    /// 框住兩個座標點的鏡頭範圍（外框加 1.4 倍緩衝，避免兩點貼著螢幕邊）
    private func framingRegion(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> MapCameraPosition {
        let lats = [a.latitude, b.latitude]
        let lons = [a.longitude, b.longitude]
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.02),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.02)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    /// 把圈的實際半徑換算成螢幕上的直徑（點），讓脈動圈剛好脹到圈的邊緣。
    private func circleScreenDiameter(_ circle: LocalLifeCircle, proxy: MapProxy) -> CGFloat {
        let center = CLLocationCoordinate2D(latitude: circle.latitude, longitude: circle.longitude)
        let edge = Self.edgeCoordinate(of: circle)
        guard let c = proxy.convert(center, to: .named(Self.mapSpace)),
              let e = proxy.convert(edge, to: .named(Self.mapSpace)) else { return 180 }
        return hypot(e.x - c.x, e.y - c.y) * 2
    }

    /// 帶領用的小標籤（極短、彩色膠囊）。
    private func guidancePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, HCSpacing.x3)
            .padding(.vertical, HCSpacing.x2)
            .background(color, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: HCSpacing.x1, y: HCSpacing.x1 / 2)
            .fixedSize()
    }

    /// 往下一段帶領：脈動圈 → 段 1 二擇一（附近有事件就脈動事件；沒有就脈動最近避難所當保底）→ 結束。
    private func advanceGuidance() {
        withAnimation {
            if guidanceStep == 0 {
                if guidanceEvent != nil {
                    guidanceStep = 1
                } else if let shelter = guidanceShelter {
                    // 保底段：多數地區平時沒有近距事件，這是常態路徑而非退化選項
                    guidanceStep = 1
                    Analytics.track("guidance_shelter_shown") // 漏斗：保底段——脈動最近避難所
                    let circleCoord = guidanceCircle.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    let shelterCoord = CLLocationCoordinate2D(
                        latitude: shelter.resource.latitude, longitude: shelter.resource.longitude
                    )
                    // 避難所不在目前視野內才挪鏡頭；已經看得到就不動，減少不必要的鏡頭跳動
                    if !isCoordinateVisible(shelterCoord), let circleCoord {
                        cameraPosition = framingRegion(circleCoord, shelterCoord)
                        guidanceCameraAdjusted = true
                    }
                } else {
                    guidanceStep = nil
                    Analytics.track("guidance_finished") // 漏斗：帶領走完（含只有一段的情況）
                    scheduleNotificationPromptIfNeeded()
                }
            } else {
                if guidanceCameraAdjusted {
                    // 保底段挪過鏡頭，結束時拉回原本框住生活圈的視角
                    cameraPosition = circlesRegion
                    guidanceCameraAdjusted = false
                }
                guidanceStep = nil
                Analytics.track("guidance_finished") // 漏斗：帶領走完
                scheduleNotificationPromptIfNeeded()
            }
        }
    }

    /// A4：帶領走完後，情境式問「要不要開通知」——先給了地圖／帶領的價值，再開口要權限。
    /// 只在權限狀態 .notDetermined（尚未問過系統框）且使用者沒按過「先不用」時才會顯示；
    /// 已授權或已被拒絕過都不再打擾。延遲 0.6 秒讓帶領收尾動畫先走完，避免卡片跟脈動圈打架。
    private func scheduleNotificationPromptIfNeeded() {
        Task {
            let declined = UserDefaults.standard.bool(forKey: SettingsKeys.notificationPromptDeclined)
            guard !declined,
                  await NotificationScheduler.authorizationStatus() == .notDetermined else {
                // 不需要再問通知：新手流程到此結束，落在家人首頁
                landOnFamilyAfterGuidance()
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation { showNotificationPrompt = true }
        }
    }

    /// 新手帶領（含通知權限卡）結束後落在家人首頁：App 啟動與新手結束都以家人為首頁。
    /// 稍等一拍讓卡片／帶領收尾動畫走完再切分頁。
    private func landOnFamilyAfterGuidance() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            router.selection = TabRouter.familyTab
        }
    }

    // MARK: - 緊急資源圖層

    /// 鏡頭夠近才顯示資源點：縮到全台視角時畫幾千個點既讀不了也拖效能
    private static let resourceZoomThreshold: CLLocationDegrees = 0.35
    private var resourceRegion: MKCoordinateRegion? {
        guard let region = visibleRegion,
              region.span.latitudeDelta <= Self.resourceZoomThreshold else { return nil }
        return region
    }

    /// 點資源標記→在 Apple 地圖顯示該地點（不直接發起導航，把決定權留給使用者）
    private func resourceAnnotation(_ resource: EmergencyResource, icon: String, color: Color) -> some MapContent {
        Annotation(resource.name, coordinate: .init(latitude: resource.latitude, longitude: resource.longitude)) {
            Button {
                var components = URLComponents(string: "https://maps.apple.com/")
                components?.queryItems = [
                    URLQueryItem(name: "q", value: resource.name),
                    URLQueryItem(name: "ll", value: "\(resource.latitude),\(resource.longitude)"),
                ]
                if let url = components?.url { UIApplication.shared.open(url) }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(color, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            .accessibilityLabel("\(resource.kind)：\(resource.name)，點擊在地圖 App 查看")
        }
    }

    // MARK: - 工具列

    /// 家人切換器：全家或個別家人（切換時鏡頭重新框選）
    private var memberPicker: some View {
        Menu {
            Picker("顯示對象", selection: $selectedMemberKey) {
                Text("全家").tag(String?.none)
                ForEach(members) { member in
                    Text(member.name).tag(String?.some(member.memberKey))
                }
            }
        } label: {
            Label(
                visibleMembers.count == members.count ? "全家" : (visibleMembers.first?.name ?? "全家"),
                systemImage: "person.2"
            )
        }
        .onChange(of: selectedMemberKey) {
            cameraPosition = circlesRegion
        }
        // 工具列圖示鈕預設只顯示 icon，文字會被吃掉——明確補一個無障礙標籤
        .accessibilityLabel(
            visibleMembers.count == members.count
                ? "顯示對象：全家，點擊切換"
                : "顯示對象：\(visibleMembers.first?.name ?? "全家")，點擊切換"
        )
    }

    /// 圖層與過濾：資源圖層開關＋事件類型與可信度過濾
    private var filterMenu: some View {
        Menu {
            Section("圖層") {
                Toggle("警戒圈範圍", isOn: $showCircles)
                Toggle("區域警報範圍", isOn: $showAlertAreas)
                Toggle("避難收容所", isOn: $showShelters)
                Toggle("急救責任醫院", isOn: $showHospitals)
                Toggle("空氣品質（每小時）", isOn: $showAirQuality)
                Toggle("治安參考（季更統計）", isOn: $showCrimeLayer)
            }
            Section("事件類型") {
                ForEach(EventCategory.all, id: \.self) { type in
                    Toggle(type, isOn: typeBinding(type))
                }
            }
            Section("可信度") {
                Toggle("顯示未驗證線索", isOn: $showUnverified)
            }
        } label: {
            Label("圖層與過濾", systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel("圖層與過濾，點擊選擇地圖圖層與事件類型")
    }

    private func typeBinding(_ type: String) -> Binding<Bool> {
        Binding(
            get: { enabledTypes.contains(type) },
            set: { isOn in
                if isOn { enabledTypes.insert(type) } else { enabledTypes.remove(type) }
            }
        )
    }

    /// 靜音鈕：暫停會關掉「所有」本機警報推播（含地震／海嘯／火災這類保命等級，
    /// 目前系統沒有分級豁免——見 NotificationScheduler.scheduleAlert 的 `!paused` guard，
    /// 一旦暫停就整個提前 return，沒有例外路徑）。誤觸的代價是「保命警報完全收不到」，
    /// 所以暫停這個方向要先跳確認框講清楚後果；恢復提醒是安全動作，不需要確認、越快越好。
    private var pauseButton: some View {
        Button {
            if isPaused {
                withAnimation { isPaused = false }
            } else {
                showMuteConfirmation = true
            }
        } label: {
            Label(isPaused ? "恢復提醒" : "暫停提醒",
                  systemImage: isPaused ? "bell.slash.fill" : "bell.slash")
        }
        .tint(isPaused ? HCColor.attention : nil)
        // 工具列圖示鈕預設只顯示 icon，文字會被吃掉——明確補一個無障礙標籤
        .accessibilityLabel(isPaused ? "恢復提醒" : "暫停提醒")
        .confirmationDialog(
            "暫停警報提醒？",
            isPresented: $showMuteConfirmation,
            titleVisibility: .visible
        ) {
            Button("暫停提醒", role: .destructive) {
                withAnimation { isPaused = true }
                Analytics.track("map_alerts_paused") // 漏斗：從地圖靜音鈕真的按下暫停（危險動作，值得追蹤頻率）
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("暫停後，包括地震、海嘯、火災在內的所有警報都不會推播，直到你手動恢復。事件仍會顯示在地圖與提醒中心，只是手機不會跳通知或響鈴。")
        }
    }

    // MARK: - 浮層

    private var topOverlays: some View {
        VStack(spacing: HCSpacing.x2) {
            safetySummary
            // 靜音生效期間常駐提示：誤觸靜音鈕後最容易被忽略的就是「沒有任何持續提示」，
            // 這顆 chip 跟摘要膠囊一樣永遠在視野裡，點一下立刻恢復，不必特地去工具列找。
            if isPaused {
                mutedChip
            }
        }
        .padding(.horizontal, HCSpacing.x4)
        .padding(.top, HCSpacing.x2)
        // 開場時摘要卡先退場，鏡頭抵達生活圈後縮放進場（Reduce Motion 只做淡入不縮放）
        .scaleEffect(isIntroRunning && !reduceMotion ? 0.9 : 1, anchor: .top)
        .opacity(isIntroRunning ? 0 : 1)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.45) : .spring(response: 0.5, dampingFraction: 0.75),
            value: isIntroRunning
        )
        // 進場完成的「守護開始」確認觸覺，與盾牌 bounce 同一個觸發源
        .sensoryFeedback(.success, trigger: shieldConfirmPulse)
        // iPad 上限制頂部狀態卡寬度並置中，避免撐滿 13 吋螢幕
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
    }

    /// 靜音常駐提示：目前的暫停機制是手動 toggle，沒有時限（見 pauseButton 註解），
    /// 所以這裡不寫「至 XX:XX」——寫了就是對使用者說謊。點擊直接恢復，不必再跳確認框
    /// （恢復是安全動作）。
    private var mutedChip: some View {
        Button {
            withAnimation { isPaused = false }
        } label: {
            HStack(spacing: HCSpacing.x2) {
                Image(systemName: "bell.slash.fill")
                    .font(.caption.weight(.semibold))
                Text("警報已靜音")
                    .font(.caption.weight(.semibold))
                Text("點擊恢復")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(HCColor.attention)
            .padding(.horizontal, HCSpacing.x3)
            .padding(.vertical, HCSpacing.x1 + 2)
            .background(HCColor.attention.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(HCColor.attention.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("警報已靜音，包括地震海嘯等所有警報都不會推播，點兩下立即恢復")
    }

    // MARK: - 守護圈開場（簽名動效）

    /// 開場起點：全台廣域鏡頭
    private static let taiwanWideRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
        span: MKCoordinateSpan(latitudeDelta: 4.6, longitudeDelta: 4.6)
    )

    /// Onboarding 完成後首次進地圖：鏡頭從全台飛向生活圈，抵達後摘要卡進場、
    /// 盾牌 bounce＋成功觸覺——把「開始守護這個範圍」演成一個確認儀式。
    /// 旗標消耗制只演一次；Reduce Motion 時不飛鏡頭，改直接定位＋交叉淡入。
    private func playGuardianIntroIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.guardianIntroPending) else {
            cameraPosition = circlesRegion
            return
        }
        defaults.set(false, forKey: SettingsKeys.guardianIntroPending)
        isIntroRunning = true
        if reduceMotion {
            cameraPosition = circlesRegion
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                isIntroRunning = false
                shieldConfirmPulse.toggle()
            }
            return
        }
        cameraPosition = .region(Self.taiwanWideRegion)
        Task { @MainActor in
            // 讓廣域畫面站穩一拍再起飛，觀眾才看得出「從哪裡飛到哪裡」
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeInOut(duration: 1.5)) { cameraPosition = circlesRegion }
            try? await Task.sleep(for: .milliseconds(1700))
            isIntroRunning = false
            shieldConfirmPulse.toggle()
        }
    }

    /// 圖例是否有內容可顯示（對應圖層開啟且畫面上真的有東西可解讀）；
    /// 抽成獨立屬性讓「面板要不要出現」與「首次自動展開要不要觸發」共用同一份判斷。
    private var legendHasContent: Bool {
        let showsSeverity = showAlertAreas && !alertAreas.isEmpty
        let resourceHint = (showShelters || showHospitals) && resourceRegion == nil
        return showsSeverity || showCrimeLayer || resourceHint || showCircles
    }

    /// 圖例面板：只在對應圖層開啟且畫面上真的有塗色時出現，避免常駐佔位
    @ViewBuilder
    private var legendPanel: some View {
        let showsSeverity = showAlertAreas && !alertAreas.isEmpty
        // 資源圖層開著但鏡頭太遠時，要說明「為什麼看不到點」——不說會像壞掉
        let resourceHint = (showShelters || showHospitals) && resourceRegion == nil
        if legendHasContent {
            Group {
                if isLegendExpanded {
                    // 整卡都能點收合（不只 chevron）：用 Button 包住整個卡片內容，
                    // .buttonStyle(.plain) 讓 hit-test 涵蓋整個 label 範圍（含背景），
                    // 而不是只有 chevron 那個小圖示——真機回報「一定要點三角形才收得起來」的修法。
                    // 2026-07-24：另外在標題列加一顆明確的 ✕——「點地圖任意處收合」與「點卡片本身收合」
                    // 都保留，✕ 只是再加一條路徑，讓不知道能點卡片的人也找得到關閉鈕。
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded = false }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label("地圖圖例", systemImage: "info.circle.fill")
                                    .font(.caption.bold())
                                Spacer(minLength: 12)
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            if showCircles {
                                // 顏色現在代表「守護對象是誰」而非「圈的類型」，
                                // 圖例改列出每個目前有圈的人＋對應顏色，不再是固定的「即時圈=綠、固定圈=藍」
                                Text("警戒圈：每個守護對象一個顏色").font(.caption2.bold())
                                ForEach(circleLegendMembers, id: \.memberKey) { member in
                                    legendRow(
                                        CircleColorPalette.color(for: member.memberKey, isCurrentUser: member.isCurrentUser).opacity(0.8),
                                        member.displayName
                                    )
                                }
                                legendRow(Color.gray.opacity(0.8), "即時位置超過 15 分鐘沒有回報")
                            }
                            if showsSeverity {
                                Text("警報區").font(.caption2.bold())
                                legendRow(RegionAlert.severityColor(rank: 3), "警戒／危急")
                                legendRow(RegionAlert.severityColor(rank: 1), "注意")
                                legendRow(RegionAlert.severityColor(rank: 0), "留意／提醒")
                            }
                            if showCrimeLayer {
                                Text("治安參考").font(.caption2.bold())
                                legendRow(HCColor.reference.opacity(0.7), "季度統計高於全國中位數（越深越多）")
                                Text("統計≠即時安全程度，僅供參考")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if resourceHint {
                                Label("放大地圖即可顯示避難所／醫院", systemImage: "plus.magnifyingglass")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("點兩下收合地圖圖例")
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
                } else {
                    // 收合態改成帶文字的膠囊鈕（不再是純 ⓘ icon）——「找不到圖例」是本次
                    // 走查最多人卡住的點之一，純圖示在滿版地圖上太容易被忽略。
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded = true }
                    } label: {
                        Label("圖例", systemImage: "info.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, HCSpacing.x3)
                            .padding(.vertical, HCSpacing.x2)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展開地圖圖例，查看警戒圈與警報區說明")
                }
            }
            .padding(.leading, 12)
            // 往上挪，跟 Apple Maps 底部的圖資標示（Legal）字樣拉開距離，避免視覺打架
            .padding(.bottom, HCSpacing.x6 + HCSpacing.x2)
        }
    }

    private func legendRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.8), lineWidth: 1))
                .frame(width: 14, height: 10)
            Text(text).font(.caption2)
        }
    }

    /// 摘要預設收成單行膠囊（把視野還給地圖），點開才展開完整卡。
    /// 平時整個畫面只有地圖與低彩度膠囊；真危險時膠囊變紅——警示色的獨佔舞台
    @ViewBuilder
    private var safetySummary: some View {
        if isSummaryExpanded { summaryCard } else { summaryCapsule }
    }

    /// 目前顯示對象是否有任何警戒圈（地點圈或跟隨圈皆算）。
    /// 完全沒有時，摘要膠囊絕不能顯示「平安」——沒有圈就沒有比對範圍，
    /// 打綠勾等於對使用者說謊，這是本次走查最嚴重的一條（18/20 人踩到）。
    private var hasAnyCircle: Bool { !visibleCircles.isEmpty }

    private var summaryCapsule: some View {
        let hasAttention = attentionCount > 0
        let hasCircles = hasAnyCircle
        // 三態：需要注意（紅）＞警戒圈內平安（綠）＞尚未設定警戒圈（灰、中性，不能講平安）
        let statusColor: Color = hasAttention ? HCColor.danger : (hasCircles ? HCColor.safe : Color.gray)
        return Button {
            withAnimation { isSummaryExpanded = true }
        } label: {
            HStack(spacing: HCSpacing.x2) {
                Image(systemName: hasAttention
                      ? "exclamationmark.shield.fill"
                      : (hasCircles ? "checkmark.shield.fill" : "shield"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: HCSpacing.x6 + HCSpacing.x1, height: HCSpacing.x6 + HCSpacing.x1)
                    .background(statusColor, in: Circle())
                    .symbolEffect(.bounce, value: shieldConfirmPulse)
                Text(hasAttention ? "\(attentionCount) 件需要注意" : (hasCircles ? "警戒圈內平安" : "尚未設定警戒圈"))
                    .font(.subheadline.weight(.semibold))
                if isPaused {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(HCColor.attention)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, HCSpacing.x3)
            .padding(.vertical, HCSpacing.x2)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(statusColor.opacity(hasCircles || hasAttention ? 0.35 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            hasAttention
                ? "警戒圈有 \(attentionCount) 件需要注意的事件，點擊展開摘要"
                : hasCircles
                    ? "警戒圈內平安\(isPaused ? "，提醒已暫停" : "")，點擊展開摘要"
                    : "尚未設定警戒圈，點擊了解如何開始守護"
        )
    }

    /// 展開版：完整安全狀態卡（各層級數字、區域警報入口、資料新鮮度）。
    /// 完全沒有警戒圈時走另一支 noCircleGuidanceCard，內容與有圈時完全不同，
    /// 不共用「需要注意 / 平安」兩態的邏輯——沒有圈就沒有「平安與否」可言。
    @ViewBuilder
    private var summaryCard: some View {
        if !hasAnyCircle {
            noCircleGuidanceCard
        } else {
            let hasAttention = attentionCount > 0
            VStack(alignment: .leading, spacing: HCSpacing.x3) {
                HStack(alignment: .center, spacing: HCSpacing.x3) {
                    // 盾牌放進色底圓形 chip：狀態色作底、白色圖示，讓「目前安全與否」一眼可辨
                    Image(systemName: hasAttention ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                        .background(hasAttention ? HCColor.danger : HCColor.safe, in: Circle())
                        // 守護圈細環：與 Onboarding hero、提醒中心平安狀態同一個圓環 motif
                        .overlay(
                            Circle()
                                .stroke((hasAttention ? HCColor.danger : HCColor.safe).opacity(0.35), lineWidth: 1.5)
                                .frame(width: HCSpacing.x6 + HCSpacing.x4, height: HCSpacing.x6 + HCSpacing.x4)
                        )
                        .symbolEffect(.bounce, value: shieldConfirmPulse)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text(hasAttention ? "警戒圈有需要注意的事件" : "警戒圈內目前平安")
                            .font(.body.weight(.semibold))
                        Text(hasAttention ? "已確認且位於提醒範圍內：\(attentionCount) 件" : "持續留意資料更新即可")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 消歧：地圖上滿版事件 pin 很容易讓人誤以為「到處都不安全」，
                        // 講清楚安全判斷只看警戒圈內，不看全台事件密度
                        if !hasAttention {
                            Text("地圖上顯示的是全台事件，不代表你的警戒圈有狀況")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { isSummaryExpanded = false }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收合摘要")
                }

                HStack(spacing: HCSpacing.x2) {
                    summaryMetric("需要注意", count: attentionCount, emphasis: hasAttention)
                    summaryMetric("未驗證線索（不限警戒圈）", count: confirmingCount, emphasis: false)
                    summaryMetric("其他區域", count: elsewhereCount, emphasis: false)
                }

                if let alert = activeRegionAlerts.first {
                    Button {
                        selectedAlert = alert
                    } label: {
                        HStack(spacing: HCSpacing.x2) {
                            Image(systemName: alert.iconName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(HCColor.attention)
                                .accessibilityHidden(true)
                            Text("區域警報：\(alert.kind)｜\(alert.title)")
                                .font(.caption.bold())
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("區域警報：\(alert.kind)，\(alert.title)")
                }

                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    if isPaused {
                        Text("提醒已暫停——事件仍會顯示，但不會推播。")
                            .font(.caption)
                            .foregroundStyle(HCColor.attention)
                    }
                    DataFreshnessLabel()
                }
            }
            .padding(HCSpacing.x3)
            .background(
                (hasAttention ? HCColor.danger : HCColor.safe).opacity(0.10),
                in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            // iPad 上限制展開卡寬度並置中；卡片內 summaryMetric 的 frame(maxWidth: .infinity) 撐滿卡片內的列，保留不動
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
    }

    /// 完全沒有警戒圈時的展開內容：中性灰、不講平安與否，純引導。
    private var noCircleGuidanceCard: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            HStack(alignment: .center, spacing: HCSpacing.x3) {
                Image(systemName: "shield")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                    .background(Color.gray, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("尚未設定警戒圈")
                        .font(.body.weight(.semibold))
                    Text("加一個守護地點，開始守護")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("地圖上顯示的是全台事件，不代表你有危險——設定警戒圈後才會比對你在意的範圍")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation { isSummaryExpanded = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收合摘要")
            }
            DataFreshnessLabel()
        }
        .padding(HCSpacing.x3)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
    }

    private func summaryMetric(_ title: String, count: Int, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: HCSpacing.x1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count) 件")
                .font(.caption.bold())
                .foregroundStyle(emphasis ? HCColor.danger : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HCSpacing.x2)
        .padding(.vertical, HCSpacing.x2)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: HCRadius.chip))
        .accessibilityElement(children: .combine)
    }

    /// 附近更新：地圖底部的橫向卡片（依離生活圈最近排序，且真的要「附近」——
    /// 超過 NearbyScope 上限的事件只留在地圖與提醒中心，不冒充附近）
    @ViewBuilder
    private var nearbyStrip: some View {
        let nearby = filteredEvents.filter {
            nearestCircleDistance($0, visibleMembers) <= NearbyScope.maxMeters
        }
        if !nearby.isEmpty {
            let sorted = nearby.sorted {
                nearestCircleDistance($0, visibleMembers) < nearestCircleDistance($1, visibleMembers)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HCSpacing.x2) {
                    ForEach(sorted.prefix(5)) { event in
                        Button {
                            selected = event
                        } label: {
                            EventRow(event: event, members: visibleMembers, style: .mapCompact)
                                .containerRelativeFrame(.horizontal) { availableWidth, _ in
                                    min(max(availableWidth - 48, 260), 340)
                                }
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                                        .stroke(.secondary.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HCSpacing.x4)
            }
            .padding(.vertical, HCSpacing.x2)
        }
    }
}

/// 點選數字叢集後顯示其中事件；每筆仍導向既有的事件詳情。
private struct EventClusterListSheet: View {
    let cluster: EventCluster
    let onSelect: (LocalSafetyEvent) -> Void
    @Environment(\.dismiss) private var dismiss

    private var sortedEvents: [LocalSafetyEvent] {
        cluster.events.sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sortedEvents) { event in
                        Button {
                            onSelect(event)
                        } label: {
                            HStack(alignment: .top, spacing: HCSpacing.x3) {
                                Image(systemName: EventCategory.icon(for: event.eventType))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention,
                                        in: Circle()
                                    )
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                                    Text(event.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(event.eventType)・\(event.approximateLocation)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(event.trustStatus)・\(relativeTime(event.occurredAt))")
                                        .font(.caption)
                                        .foregroundStyle(
                                            event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention
                                        )
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, HCSpacing.x2)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("開啟事件詳情")
                    }
                } header: {
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text(cluster.hasOfficialConfirmed ? "含官方已確認事件" : "事件皆在持續確認中")
                        if let latest = cluster.latestOccurredAt {
                            Text("最新事件：\(relativeTime(latest))")
                        }
                    }
                } footer: {
                    Text("社群資訊在官方或多來源驗證前皆視為尚未確認。有立即危險請直接撥打 110 或 119。")
                }
            }
            .navigationTitle("\(cluster.count) 件事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .formPresentationSizing()
    }
}

/// 地圖點選事件時先顯示低高度摘要；使用者主動展開後才進完整詳情。
private struct MapEventSheet: View {
    private static let compactDetent: PresentationDetent = .height(220)

    let event: LocalSafetyEvent
    let members: [LocalFamilyMember]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDetent: PresentationDetent = .height(220)

    var body: some View {
        Group {
            if selectedDetent == Self.compactDetent {
                compactContent
            } else {
                EventDetailView(event: event, members: members)
            }
        }
        .presentationDetents([Self.compactDetent, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.compactDetent))
        // iPad 會忽略 presentationDetents 而放大成整頁 sheet，這裡收斂成 form 尺寸
        .formPresentationSizing()
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.isDrill
                      ? "bell.and.waves.left.and.right"
                      : EventCategory.icon(for: event.eventType))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention)
                    .frame(width: 34, height: 34)
                    .background(
                        (event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.isDrill ? "【演練】\(event.title)" : event.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Text(eventSeverityAndTrust(event))
                        .font(.caption)
                        .foregroundStyle(event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉事件摘要")
            }

            metadata

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { selectedDetent = .large }
            } label: {
                Label("查看完整資訊", systemImage: "chevron.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Text("有立即危險請直接撥打 110 或 119。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, HCSpacing.x4)
        .padding(.top, HCSpacing.x3)
    }

    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(relativeTime(event.occurredAt))・\(relativeDistance(event, members))")
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(relativeTime(event.occurredAt))
                Text(relativeDistance(event, members))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview {
    SafetyMapView()
        .modelContainer(PreviewSupport.container())
}
#endif
