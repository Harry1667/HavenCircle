import SwiftUI
import CoreLocation

/// 安否回報中心：雙向閉環的回報端。
/// - 上半：我一鍵回報「我平安 / 需要協助」
/// - 下半：家人的回報清單與已讀回條
/// - 工具列：邀請家人加入家庭圈（CKShare）
struct SafetyCheckInView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    let myName: String

    @State private var showInviteOptions = false
    @State private var note = ""
    @State private var isWorking = false
    /// 送出成功的暫時性提示，2.5 秒後自動消失（token 避免舊的自動消失計時器誤清掉新的提示）
    @State private var successBanner: String?
    @State private var successBannerToken: UUID?
    /// 回報時附上目前位置（自願、一次性）。用 AppStorage 記住偏好，預設關（隱私優先）
    @AppStorage("checkInAttachLocation") private var attachLocation = false
    /// 邀請失敗時的可見錯誤——只寫 log 的話，使用者看到的是「按了沒反應＝App 壞了」
    @State private var shareError: String?
    /// 登入前置把關：未登入時先彈預告卡解釋「為什麼」，登入成功後自動接續原動作
    @State private var gate = SignInGate()
    @State private var nameGate = NamePromptGate()
    /// 通知點進來要特別標示的那一則回報（短暫高亮，約 3 秒後消失）
    @State private var highlightedPingID: String?
    /// 正在送出「收到」的回報 ID（防連點）
    @State private var ackingPingIDs: Set<String> = []

    var body: some View {
        // 由 FamilyHubView 承載（提供 NavigationStack 與分段切換）
        ScrollViewReader { proxy in
        List {
            accountSection
            if sync.state == .sharing || !sync.pings.isEmpty {
                checkInSection
                familyPingsSection
            }
        }
        // 通知深連結：清單載入後（冷啟動要等 fetchPings）捲到該則並高亮
        .onChange(of: sync.pings.map(\.id)) { _, _ in focusPendingPing(proxy) }
        .onChange(of: router.pendingPingID) { _, _ in focusPendingPing(proxy) }
        .onAppear { focusPendingPing(proxy) }
        .listSectionSpacing(HCSpacing.x6)
        .signInPreflight(gate)
        .analyticsScreen("check_in")
        .toolbar {
            if isWorking {
                ProgressView()
            } else {
                Button("邀請家人", systemImage: "person.badge.plus") {
                    nameGate.perform { Task { await startShare() } }
                }
                .disabled(sync.state == .noAccount)
            }
        }
        .alert("邀請家人失敗", isPresented: .init(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .sheet(isPresented: $showInviteOptions, onDismiss: {
            // 剛建立家庭圈、邀請頁收合後，才說明為什麼需要通知（已授權／已問夠次數會自動略過）
            NotificationPrimer.shared.request(.family)
        }) {
            InviteOptionsView().hcSheet()
        }
        .namePrompt(nameGate)
        .task {
            await sync.refreshAccountStatus()
            await sync.fetchPings()
        }
        .refreshable { await sync.fetchPings() }
        }
    }

    /// 處理通知帶來的 pendingPingID：清單裡找得到就捲過去、高亮 3 秒並清掉待辦；
    /// 找不到（已被清掉或尚未載入）就先保留，等下一次清單更新再試。
    private func focusPendingPing(_ proxy: ScrollViewProxy) {
        guard let id = router.pendingPingID, sync.pings.contains(where: { $0.id == id }) else { return }
        router.pendingPingID = nil
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        highlightedPingID = id
        Task {
            try? await Task.sleep(for: .seconds(3))
            if highlightedPingID == id { highlightedPingID = nil }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        switch sync.state {
        case .noAccount:
            Section {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HCColor.attention)
                        .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                        .background(HCColor.attention.opacity(0.10), in: Circle())
                    Text("尚未登入 Apple 帳號")
                        .font(.body.weight(.semibold))
                }
                Text("回報平安需要 Apple 帳號，才能同步給家人。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("登入") {
                    gate.perform {
                        await sync.refreshAccountStatus()
                        await sync.fetchPings()
                    }
                }
            }
        case .error(let message):
            Section {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HCColor.danger)
                        .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                        .background(HCColor.danger.opacity(0.10), in: Circle())
                    Text("同步發生問題")
                        .font(.body.weight(.semibold))
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Section {
                Text("按右上角「邀請家人」建立你的家庭圈，家人接受後就能互相回報平安。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sharing, .unknown:
            EmptyView()
        }
    }

    private var checkInSection: some View {
        Section {
            TextField("補充說明（選填）", text: $note)
            Toggle(isOn: $attachLocation) {
                Label("附上我的目前位置", systemImage: "location")
            }
            .onChange(of: attachLocation) { _, isOn in
                // 開啟當下就要權限，別等到按回報才跳系統框打斷流程
                if isOn { LocationService.shared.requestPermissionIfNeeded() }
            }
            if let successBanner {
                Label(successBanner, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(HCColor.safe)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: HCSpacing.x3) {
                ForEach(SafetyStatus.selfReportable, id: \.self) { status in
                    Button {
                        report(status)
                    } label: {
                        VStack(spacing: HCSpacing.x2) {
                            Image(systemName: status.systemImage)
                                .font(.title3.weight(.medium))
                            Text(status.rawValue)
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(status == .safe ? Color.white : HCColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: HCSpacing.x6 * 4)
                        .background(
                            status == .safe ? HCColor.safeFill : HCColor.danger.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: HCRadius.control, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HCRadius.control, style: .continuous)
                                .stroke(
                                    status == .safe ? HCColor.safe.opacity(0) : HCColor.danger.opacity(0.24),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
        } header: {
            Text("回報我的狀態")
        } footer: {
            Text("位置只在你按下回報的那一刻取得並分享一次，安心圈不會持續追蹤任何人的位置。")
        }
    }

    @ViewBuilder
    private var familyPingsSection: some View {
        Section("家人回報") {
            if sync.pings.isEmpty {
                Text("目前還沒有家人的回報")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, HCSpacing.x4)
            } else {
                ForEach(sync.pings) { ping in
                    pingRow(ping)
                        .id(ping.id)
                        // 高亮不只靠顏色：同時有外框；通知帶來的那則才會有
                        .listRowBackground(highlightedPingID == ping.id ? HCColor.brand.opacity(0.15) : nil)
                }
            }
        }
    }

    private func pingRow(_ ping: SafetyPing) -> some View {
        HStack(alignment: .top, spacing: HCSpacing.x3) {
            Image(systemName: ping.status.systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ping.status == .safe ? HCColor.safe : HCColor.danger)
                .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                .background(
                    (ping.status == .safe ? HCColor.safe : HCColor.danger).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                HStack(alignment: .firstTextBaseline, spacing: HCSpacing.x2) {
                    Text(ping.senderName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(ping.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(ping.status.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ping.status == .safe ? HCColor.safe : HCColor.danger)
                if !ping.note.isEmpty {
                    Text(ping.note)
                        .font(.caption)
                }
                if ping.hasLocation {
                    Label(ping.placeName ?? "已附上位置", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !ping.readBy.isEmpty {
                    Label("已讀：\(ping.readBy.joined(separator: "、"))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, HCSpacing.x2)
                        .padding(.vertical, HCSpacing.x1)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                }
                if !ping.ack.isEmpty {
                    Label("\(sync.ackNames(of: ping).joined(separator: "、")) 已收到", systemImage: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pingRow.ackSummary")
                }
                // 他人的平安／求助回報可回「收到 ❤️」；「請回報平安」是請求，不是要確認的狀態
                if !sync.isMine(ping) && ping.status != .pleaseReport {
                    ackButton(ping)
                }
            }
        }
        .padding(.vertical, HCSpacing.x1)
        .task {
            // 顯示他人回報時，自動標記我已讀（已讀回條）
            if !sync.isMine(ping) && !ping.readBy.contains(myName) {
                await sync.markRead(pingID: ping.id, readerName: myName)
            }
        }
    }

    /// 「收到 ❤️」按鈕；已按過改顯示「已回覆收到」（不可再按）
    @ViewBuilder
    private func ackButton(_ ping: SafetyPing) -> some View {
        if sync.hasAcked(ping) {
            Label("已回覆收到", systemImage: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HCColor.brandText)
                .accessibilityIdentifier("pingRow.acked")
        } else {
            Button {
                guard !ackingPingIDs.contains(ping.id) else { return }
                ackingPingIDs.insert(ping.id)
                Task {
                    let ok = await sync.ackPing(pingID: ping.id)
                    ackingPingIDs.remove(ping.id)
                    if !ok { showSuccessBanner("沒有送出，請確認網路後再按一次") }
                }
            } label: {
                Text("收到 ❤️")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, HCSpacing.x3)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(HCColor.brandText)
            .disabled(ackingPingIDs.contains(ping.id))
            .accessibilityIdentifier("pingRow.ackButton")
        }
    }

    private func startShare() async {
        isWorking = true
        defer { isWorking = false }
        do {
            // 已在家庭圈就沿用現有邀請碼；還沒有就建立一個新家庭圈
            if sync.currentInviteCode == nil {
                _ = try await sync.createFamily()
            }
            showInviteOptions = true
        } catch {
            AppLog.cloudError("建立家庭圈失敗：\(error.localizedDescription)")
            shareError = "無法建立家庭圈邀請：\(error.localizedDescription)\n請確認已登入且網路正常後再試一次。"
        }
    }

    /// isWorking 在這裡（Task 外層、按鈕點下當下）就同步設 true，而不是留到 async 函式內部第一行——
    /// 比照 EventDetailView.report 的防抖寫法：Task{} 排入佇列到實際開始執行之間有一個小窗口，
    /// 若 isWorking 要等 async 函式跑起來才設 true，連點兩下有機會在窗口內重複觸發。
    private func report(_ status: SafetyStatus) {
        isWorking = true
        successBanner = nil
        Task { await performReport(status) }
    }

    private func performReport(_ status: SafetyStatus) async {
        // 自願附位置：取不到（未授權/逾時）就照常回報，定位失敗不能擋「我平安」
        var latitude: Double?
        var longitude: Double?
        var placeName: String?
        if attachLocation, let location = await LocationService.shared.currentLocation() {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            placeName = await Self.reverseGeocode(location)
        }
        let success = await sync.postPing(
            senderName: myName, status: status, note: note,
            latitude: latitude, longitude: longitude, placeName: placeName
        )
        isWorking = false
        if success {
            note = ""
            showSuccessBanner("已送出，家人會收到通知")
        }
        // 失敗／逾時的人話文案已經在 sync.state（.error(message)）裡，由 accountSection 顯示，
        // 這裡不重複顯示——避免同一件事兩個地方講不一致的話。
    }

    /// 顯示成功提示並在 2.5 秒後自動消失；用 token 確保「消失」只作用在自己這次顯示上，
    /// 不會誤清掉使用者緊接著又按一次回報而新蓋上去的提示。
    private func showSuccessBanner(_ text: String) {
        successBanner = text
        let token = UUID()
        successBannerToken = token
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if successBannerToken == token {
                successBanner = nil
            }
        }
    }

    /// 回報端做一次反向地理編碼，家人看到的是「台北市信義區」而不是座標。
    /// 失敗回 nil（回報列會退回顯示「已附上位置」），不重試不阻塞。
    private static func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let place = await MapReverseGeocoder.lookup(location) else { return nil }
        let district = Districts.guess(from: place.searchableText)
        return place.approximateLabel(district: district)
    }
}
