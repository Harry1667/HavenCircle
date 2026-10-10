import SwiftUI
import SwiftData

/// 家人首頁（FamilyHome）：以「人」為中心呈現——災害時真正要看的是「誰在哪、平不平安」，
/// 不是一排參數設定。版面仿 Apple 家庭共享：頂部固定「我的帳號」卡，
/// 下方才是家庭圈內容，依「是否已加入家庭圈」分三種狀態：
/// - 未加入任何家庭圈：情境卡直球講「為什麼需要」＋邀請大按鈕
///   （2026-07 實測回饋：「想要自己的位置也需要登入，第三頁是做壞的」正是這個畫面）。
/// - 已加入但只有自己一人：「等待家人加入」卡（邀請碼＋再次分享），不重複顯示邀請大按鈕。
/// - 已加入且有其他成員：家庭圈 header（名稱＋人數）＋本人卡＋每位家人一張卡＋重要地點另起小節。
///
/// 這一頁只放「人」與「地方」：我的卡、家人卡、單人時的邀請碼卡、守護地點。
/// 位置分享開關、警報跟著我、輸入邀請碼換圈、解散／退出都收進 [FamilyManageView]（管理子頁）。
///
/// 分支判斷一律看 [FamilySyncService.isInFamilyCircle] / [FamilySyncService.isSolo]（雲端真相），
/// 不看本機 LocalFamilyMember 筆數——本機清單是投影，剛加入時會落後於雲端，
/// 用本機筆數判斷會出現「明明已加入卻還看到邀請空狀態」的錯覺（2026-07-24 實測撞到的 bug）。

// MARK: - 家人列樣式共用小工具（FamilyHomeView 使用）

/// 身分 emoji：成員名對得上 FamilyRole.all 的用其 emoji（爸爸、媽媽⋯），對不上一律用中性黃臉。
private func roleEmoji(for name: String) -> String {
    FamilyRole.all.first(where: { $0.label == name })?.emoji ?? FamilyRole.customEmoji
}

/// 這位家人最新的安否回報時間（比對署名）。分項標示「平安回報：」，
/// 還沒回報過就明講「尚未回報」，不是留白讓人猜。
private func lastPingText(_ member: LocalFamilyMember, pings: [SafetyPing]) -> String {
    guard let ping = pings
        .filter({ $0.senderName == member.name })
        .max(by: { $0.createdAt < $1.createdAt }) else {
        return "平安回報：尚未回報"
    }
    return "平安回報：\(ping.createdAt.formatted(.relative(presentation: .named)))"
}

/// 位置狀態（分項標示「位置：」，不只靠顏色）：
/// 沒分享是中性文字，分享中才依最後上傳時間判斷新鮮度（規則見 LiveLocationPresence.memberLocationLine）。
private func locationStatusText(_ member: LocalFamilyMember) -> String {
    let live = member.lifeCircles.first(where: { $0.kind == .live })
    return LiveLocationPresence.memberLocationLine(
        isCurrentUser: member.isCurrentUser,
        sharingEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
        hasLiveCircle: live != nil,
        lastReportedAt: live?.locationUpdatedAt,
        statusDetail: live?.locationFreshnessText
    )
}

/// 成員列的兩行狀態文字（平安回報／位置各一行），FamilyHomeView 使用
private struct MemberStatusLines: View {
    let member: LocalFamilyMember
    let pings: [SafetyPing]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lastPingText(member, pings: pings))
            Text(locationStatusText(member))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// #15 本名/身分分離：家人清單「自己」那列的主標題——本名優先，
/// 本名沒填才退回身分（爸爸／媽媽…），兩者皆空才 fallback「我」。

private func familySelfListTitle(displayName: String, familyRole: String) -> String {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty { return trimmedName }
    let trimmedRole = familyRole.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedRole.isEmpty ? "我" : trimmedRole
}

/// 「自己」那列的身分小標籤：只有本名跟身分「都」有值才顯示——本名沒填時身分已經
/// 當主標題用了，不必再重複顯示一次同樣的字。
private func familySelfRoleBadge(displayName: String, familyRole: String) -> String? {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedRole = familyRole.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedRole.isEmpty else { return nil }
    return trimmedRole
}

struct FamilyHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Environment(EntitlementStore.self) private var entitlementStore
    @Query private var members: [LocalFamilyMember]
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var familyRole = ""
    @AppStorage(SettingsKeys.appleAccountEmail) private var appleAccountEmail = ""

    @State private var addingPlace = false
    /// 「更新位置」滑動操作的結果提示
    @State private var locationRequestToast: String?
    /// 地點額度閘門觸發時開這個付費頁（見 [gateAddPlace]）
    @State private var showPaywall = false
    /// 剛儲存的家人/地點：編輯器收合後接著替它開固定圈編輯器（兩段式流程合併成一段）
    @State private var newMemberForCircle: LocalFamilyMember?
    /// 剛在 PlaceSelectView 選好、建立好的地點成員，暫存到「選地點 sheet 完全關閉」後
    /// 才由 onDismiss 開圈編輯器——見 addingPlace sheet 的 onDismiss 說明（新增固定圈打不開的修正）
    @State private var pendingCirclePlace: LocalFamilyMember?

    // 邀請流程（空狀態的主 CTA／單人邀請碼卡）
    @State private var signInGate = SignInGate()
    @State private var showInviteOptions = false
    @State private var showJoinByCode = false
    @State private var showRoleSelect = false
    @State private var isInviting = false
    @State private var inviteError: String?
    /// B2：deep link（QR／havencircle://join）帶進來的邀請碼，交給 JoinByCodeView 預填並自動查詢
    @State private var prefilledJoinCode: String?

    /// D1：是否已加入或建立家庭圈——優先於本機成員數的分支依據
    private var isInFamilyCircle: Bool { sync.isInFamilyCircle }
    /// D1：已在家庭圈內是否只有自己一人（雲端 memberUids 為準）
    private var isCircleSolo: Bool { sync.isSolo(localMembers: members) }
    /// D2：是否已用 Apple 帳號登入（沿用 LiveCircleSharingSection 同款判法）
    private var isSignedIn: Bool { sync.state != .noAccount }

    private var me: LocalFamilyMember? { members.first(where: \.isCurrentUser) }
    /// 家人清單（#4：含「自己」，排在最前面）——memberRow 會依 isCurrentUser 特判顯示方式。
    private var familyMembers: [LocalFamilyMember] {
        let others = members.filter { !$0.isPlace && !$0.isCurrentUser }
        guard let me else { return others }
        return [me] + others
    }
    private var places: [LocalFamilyMember] {
        members.filter(\.isPlace)
    }
    private var myDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "我" : trimmed
    }
    /// #15 本名/身分分離：家人清單「自己」那列的主標題（規則見檔案頂部共用函式 familySelfListTitle）。
    private var selfListTitle: String {
        familySelfListTitle(displayName: displayName, familyRole: familyRole)
    }
    /// 「自己」那列的身分小標籤。其他家人的身分沒有同步到雲端，這個標籤只會出現在自己這一列。
    private var selfRoleBadge: String? {
        familySelfRoleBadge(displayName: displayName, familyRole: familyRole)
    }

    var body: some View {
        List {
            // 提醒暫停中（#19）：地圖不再放暫停鈴鐺，靜音狀態改在家人首頁顯示，點一下恢復
            MutedAlertsBanner()
            // 狀態卡：我的警戒圈／家人平不平安、附近動態、最近避難所
            FamilyStatusCard()
            if !isInFamilyCircle {
                // 未入圈：邀請大鈕（連同「我收到了邀請碼」）永遠置頂——
                // 受邀者尚未加入任何家庭時一定要看得到輸碼入口
                emptyStateSection
                myAccountSection
                placesSection
                manageLinkSection
            } else if isCircleSolo {
                // 單人：我的卡＋邀請碼卡（唯一邀請入口）＋守護地點
                familyMembersSection
                waitingForFamilyCard
                placesSection
                manageLinkSection
            } else {
                // 多人：我的卡＋家人卡＋守護地點；邀請更多家人收進管理頁
                familyMembersSection
                placesSection
                manageLinkSection
            }
        }
        .toolbar {
            // 三個主分頁右上角統一放同一顆齒輪；家人頁的 NavigationStack 由 FamilyHubView 提供。
            // 右上「＋」已移除（#13）：新增守護地點在頁內「守護地點」小節。
            ToolbarItem(placement: .topBarTrailing) {
                Button("設定", systemImage: "gearshape") { router.showSettings = true }
            }
        }
        .signInPreflight(signInGate)
        .alert(
            "更新位置",
            isPresented: Binding(get: { locationRequestToast != nil }, set: { if !$0 { locationRequestToast = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(locationRequestToast ?? "")
        }
        .sheet(isPresented: $addingPlace, onDismiss: presentPendingCircleEditor) {
            // 名字用點擊選擇取代打字（少一步輸入畫面）。選定後先把地點成員建好、暫存起來，
            // 等這個 sheet「完全關閉」再由 onDismiss 開圈編輯器——不能在關閉動畫途中就 present
            // 下一個 sheet，否則 SwiftUI 會把後者靜默丟掉（＝新增固定圈完全打不開的根因）。
            PlaceSelectView { name, _ in
                pendingCirclePlace = createPlace(name: name)
                addingPlace = false
            }
            .hcSheet()
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(item: $newMemberForCircle) { member in
            CircleEditorView(member: member).hcSheet()
        }
        .sheet(isPresented: $showInviteOptions) {
            InviteOptionsView()
                .hcSheet()
        }
        .sheet(isPresented: $showJoinByCode, onDismiss: { prefilledJoinCode = nil }) {
            JoinByCodeView(prefilledCode: prefilledJoinCode)
                .hcSheet()
        }
        .fullScreenCover(isPresented: $showRoleSelect) {
            RoleSelectView(
                onSelect: { role in
                    applyRole(role)
                    showRoleSelect = false
                    showInviteOptions = true
                },
                onSkip: {
                    showRoleSelect = false
                    showInviteOptions = true
                }
            )
        }
        .task {
            await sync.refreshAccountStatus()
            await sync.refreshFamilyMembers(context: context)
            await sync.fetchPings()
            // 開啟家人頁時邀請碼已過期／剩不到 24 小時 → 自動換新碼
            await sync.renewInviteCodeIfNeeded()
        }
        .refreshable {
            await sync.refreshAccountStatus()
            await sync.refreshFamilyMembers(context: context)
            await sync.fetchPings()
            await sync.renewInviteCodeIfNeeded()
        }
        // B2：deep link 帶碼進來（QR 掃描／havencircle://join）——切到本頁後這裡接手，
        // 未登入先走登入預告卡，登入完成才開加入流程；消耗式旗標，用過就清空避免重觸發。
        .task(id: router.pendingJoinCode) {
            guard let code = router.pendingJoinCode else { return }
            router.pendingJoinCode = nil
            signInGate.perform {
                prefilledJoinCode = code
                showJoinByCode = true
            }
        }
        // iPad：整份清單限寬置中，避免按鈕與列卡撐滿 13 吋全寬（iPhone 上無感）；
        // 外圍再鋪同款群組底色，否則 List 底色只到 600pt，左右會露出不同色階的接縫
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - 家庭圈管理入口

    /// 管理子頁入口：位置分享、警報跟著我、換圈、解散都在裡面。
    /// 用一列明確的文字入口，不用只有 icon 的按鈕——低頻功能要找得到、但不佔首頁。
    private var manageLinkSection: some View {
        Section {
            NavigationLink {
                FamilyManageView()
            } label: {
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Label("家庭圈管理", systemImage: "slider.horizontal.3")
                        .font(.body.weight(.medium))
                    Text(isInFamilyCircle
                         ? "位置分享、警報跟著我、換圈與退出"
                         : "警報跟著我、輸入邀請碼")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("family.manageLink")
        }
    }

    // MARK: - D2：我的帳號卡（只在未入圈時顯示——已入圈後這件事由家庭圈 header／成員清單接手，
    // 見 familyMembersSection 的「自己」列）

    /// 整張卡可點：已登入點下去開設定頁（「個人資訊」在設定頁最上方，可改本名），
    /// 未登入點下去走跟右側「登入」按鈕相同的登入前置流程（#16 可到個人資訊）。
    private var myAccountSection: some View {
        Section {
            Button {
                if isSignedIn {
                    router.showSettings = true
                } else {
                    signInGate.isPresentingPreflight = true
                }
            } label: {
                HStack(spacing: HCSpacing.x3) {
                    Text(roleEmoji(for: myDisplayName))
                        .font(.system(size: 30))
                        .frame(width: 48, height: 48)
                        .background(.secondary.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text(accountDisplayText).font(.body.weight(.semibold))
                        Text(accountSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSignedIn {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("登入")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HCColor.brand)
                    }
                }
                .foregroundStyle(.primary)
                .hcCard()
            }
            .buttonStyle(.plain)
        } header: {
            Text("我的帳號")
        }
        .listRowInsets(
            EdgeInsets(
                top: HCSpacing.x1,
                leading: HCSpacing.x4,
                bottom: HCSpacing.x1,
                trailing: HCSpacing.x4
            )
        )
        .listRowBackground(Color.clear)
    }

    /// 問題2：未登入時不該顯示「我」這種假名——主文字改講狀態本身，
    /// 副文字講清楚「什麼時候會用到 Apple 帳號」，已登入兩者行為不變。
    private var accountDisplayText: String {
        isSignedIn ? myDisplayName : "尚未登入"
    }

    private var accountSubtitle: String {
        guard isSignedIn else { return "加入或建立家人圈時會用 Apple 帳號登入" }
        return appleAccountEmail.isEmpty ? "已使用 Apple 帳號登入" : appleAccountEmail
    }

    // MARK: - 空狀態（還沒加入任何家庭圈）

    /// 情境卡置頂：直球講「為什麼需要」，不是功能清單——這正是使用者罵「沒有引導」的畫面，
    /// 不能再放一排並列 Section 讓人自己猜入口在哪。
    private var emptyStateSection: some View {
        Section {
            VStack(spacing: HCSpacing.x4) {
                ZStack {
                    Circle()
                        .fill(HCColor.brand.opacity(0.10))
                        .frame(width: 72, height: 72)
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(HCColor.brand)
                }
                Text("災害來的時候，一個人知道不夠。")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Button {
                    signInGate.perform { await startInviteFlow() }
                } label: {
                    // 問題2：未登入時先講成本再讓人按——「登入並邀請家人」比裸「邀請家人」
                    // 更誠實，不會讓人點下去才發現還要先過一關登入。
                    // #9：不用 Label 直接套 .frame(maxWidth: .infinity)（icon 會消失），改用 HCCenteredLabel。
                    HCCenteredLabel(isSignedIn ? "邀請家人" : "登入並邀請家人", systemImage: "person.crop.circle.badge.plus")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInviting)
                .accessibilityIdentifier("family.inviteButton")
                if !isSignedIn {
                    Text("用 Apple 帳號，約 10 秒完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 問題4：隱私承諾寫進 UI——加入家庭圈只共用安否回報，位置分享是另一個
                // 各自預設關閉的開關（見 LiveCircleSharingSection／SettingsKeys.liveLocationSharingEnabled）
                Text("加入後只互報平安；位置分享另外由每個人自己決定，預設關閉")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if isInviting {
                    ProgressView()
                }
                if let inviteError {
                    Text(inviteError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // 問題2：阿嬤是被邀請方——小灰字容易被當成無用的免責宣告直接忽略，
                // 升級成次要按鈕樣式，跟主鈕同寬同尺寸但視覺次要（#16：輸碼入口置頂可見）
                Button {
                    signInGate.perform {
                        prefilledJoinCode = nil
                        showJoinByCode = true
                    }
                } label: {
                    HCCenteredLabel("我收到了邀請碼", systemImage: "number.square")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("family.joinByCodeButton")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HCSpacing.x2)
            .hcCard()
        }
        .listRowInsets(
            EdgeInsets(
                top: HCSpacing.x1,
                leading: HCSpacing.x4,
                bottom: HCSpacing.x1,
                trailing: HCSpacing.x4
            )
        )
        .listRowBackground(Color.clear)
    }

    /// 建立家庭圈（若尚未建立）並開啟邀請碼畫面。首次建立家庭圈成功後先接身分選擇（C3），
    /// 選完／略過再開邀請碼畫面。
    private func startInviteFlow() async {
        isInviting = true
        inviteError = nil
        defer { isInviting = false }
        do {
            // 建/沿用家庭圈的決策抽到 FamilySyncService.ensureInviteReady（C1 情境卡共用同一份）
            let isFirstFamily = try await sync.ensureInviteReady(context: context)
            if isFirstFamily {
                showRoleSelect = true
            } else {
                showInviteOptions = true
            }
        } catch {
            inviteError = "建立家庭圈失敗：\(error.localizedDescription)"
            AppLog.cloudError("建立家庭圈失敗：\(error.localizedDescription)")
        }
    }

    /// #15 本名/身分分離：選身分只寫 `profileFamilyRole`，絕不覆寫 `profileDisplayName`
    /// （舊行為會把本名蓋成「媽媽」，本名跟身分是兩件事）。member.name 本名優先，
    /// 本名還沒填時才用身分當顯示名，避免同步給家人的名字是空白。
    private func applyRole(_ role: FamilyRole) {
        familyRole = role.label
        if let me {
            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            me.name = trimmedName.isEmpty ? role.label : trimmedName
            context.saveReporting()
        }
        Analytics.track("role_selected")
    }

    // MARK: - C4：等待家人加入（已入圈但只有自己一人）

    private var waitingForFamilyCard: some View {
        Section {
            VStack(spacing: HCSpacing.x4) {
                ZStack {
                    Circle()
                        .fill(HCColor.brand.opacity(0.10))
                        .frame(width: 72, height: 72)
                    Image(systemName: "hourglass")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(HCColor.brand)
                }
                Text("等待家人加入")
                    .font(.title3.weight(.bold))
                if sync.currentInviteCode != nil, !sync.inviteCodeExpiry.isShareable {
                    // 過期：不顯示舊碼、不給分享鈕，只顯示換新碼進度或錯誤＋重試
                    expiredInviteBlock
                } else {
                    if let code = sync.currentInviteCode {
                        Text(code)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .tracking(HCSpacing.x1)
                            .accessibilityIdentifier("invite.code")
                            .padding(.horizontal, HCSpacing.x4)
                            .padding(.vertical, HCSpacing.x2)
                            .background(
                                .primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: HCRadius.control, style: .continuous)
                            )
                        Label(sync.inviteCodeExpiry.displayText, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(sync.inviteCodeExpiry.needsRenewal ? HCColor.danger : .secondary)
                        if sync.isRenewingInviteCode {
                            ProgressView()
                        } else if let error = sync.inviteRenewError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(HCColor.danger)
                                .multilineTextAlignment(.center)
                        }
                    }
                    Text("把邀請碼給家人，或讓他們掃你畫面上的 QR code 就能加入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        showInviteOptions = true
                    } label: {
                        // #9：同上，改用 HCCenteredLabel 保留 icon
                        HCCenteredLabel("分享邀請碼", systemImage: "square.and.arrow.up")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HCSpacing.x2)
            .hcCard()
        }
        .listRowInsets(
            EdgeInsets(
                top: HCSpacing.x1,
                leading: HCSpacing.x4,
                bottom: HCSpacing.x1,
                trailing: HCSpacing.x4
            )
        )
        .listRowBackground(Color.clear)
    }

    /// 邀請碼過期時取代「碼＋再次分享」的內容
    @ViewBuilder
    private var expiredInviteBlock: some View {
        if sync.isRenewingInviteCode {
            ProgressView()
            Text("邀請碼已過期，正在產生新邀請碼⋯")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(sync.inviteCodeExpiry.displayText, systemImage: "clock.badge.exclamationmark")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HCColor.danger)
            Text(sync.inviteRenewError ?? "邀請碼已過期，需要換一組新的才能邀請家人。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await sync.renewInviteCodeIfNeeded() }
            } label: {
                HCCenteredLabel("重試", systemImage: "arrow.clockwise")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("family.renewInviteRetry")
        }
    }

    /// 家人清單：#4 本名/身分分離——「自己」這列也在清單裡（排在最前面），
    /// 主標題本名優先、身分當輔助小標籤；其他成員的身分沒有同步到雲端，只顯示同步來的名字。
    @ViewBuilder
    private var familyMembersSection: some View {
        if !familyMembers.isEmpty {
            Section(isCircleSolo ? "我" : "家人（\(familyMembers.count)）") {
                ForEach(familyMembers) { member in
                    NavigationLink {
                        MemberDetailView(member: member)
                    } label: {
                        memberRow(member)
                    }
                    .hcCard()
                    .listRowInsets(
                        EdgeInsets(
                            top: HCSpacing.x1,
                            leading: HCSpacing.x4,
                            bottom: HCSpacing.x1,
                            trailing: HCSpacing.x4
                        )
                    )
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        // 請這位家人的手機現在回報一次位置（對方沒開分享就不會回應）
                        if !member.isCurrentUser, let uid = member.sharedIdentityKey,
                           member.lifeCircles.contains(where: { $0.kind == .live }) {
                            Button {
                                Task {
                                    let name = UserDefaults.standard.string(forKey: SettingsKeys.profileDisplayName) ?? ""
                                    switch await sync.requestLocationUpdate(forUid: uid, requesterName: name) {
                                    case .sent: locationRequestToast = "已通知\(member.name)的手機更新位置"
                                    case .cooldown(let seconds): locationRequestToast = "剛剛已請\(member.name)更新過，\(seconds) 秒後可再試"
                                    case .failed(let reason): locationRequestToast = reason
                                    }
                                }
                            } label: {
                                Label("更新位置", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(HCColor.brand)
                        }
                    }
                    .swipeActions {
                        // 自己這列不給滑動刪除：刪掉的是本機的「自己」成員資料，不是退出家庭圈
                        // （退出家庭圈有專門的 leaveFamilySection，語意不同，不能被滑一下誤觸）
                        if !member.isCurrentUser {
                            Button(role: .destructive) {
                                context.delete(member)
                                context.saveReporting()
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func memberRow(_ member: LocalFamilyMember) -> some View {
        let circleCount = member.lifeCircles.count
        let titleText = member.isCurrentUser ? selfListTitle : member.name
        return HStack(spacing: HCSpacing.x3) {
            Text(roleEmoji(for: titleText))
                .font(.system(size: 24))
                .frame(width: 40, height: 40)
                .background(.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                HStack(spacing: HCSpacing.x2) {
                    Text(titleText).font(.body.weight(.medium))
                    // #4：身分小標籤只出現在自己這列——其他家人的身分沒有同步到雲端（刻意裁切）
                    if member.isCurrentUser, let badge = selfRoleBadge {
                        Text("〔\(badge)〕")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                MemberStatusLines(member: member, pings: sync.pings)
            }
            Spacer()
            Text("\(circleCount) 圈")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 守護地點小節：不論家庭狀態一律顯示（未入圈／單人／多人家庭都固定在成員區之後），
    /// 新增入口收在小節內這一列，不再另外放一張會在多人家庭時消失的獨立卡片。
    private var placesSection: some View {
        Section("守護地點") {
            if places.isEmpty {
                Text("還沒有守護地點，加一個爸媽家吧")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(places) { place in
                    NavigationLink {
                        MemberDetailView(member: place)
                    } label: {
                        HStack(spacing: HCSpacing.x3) {
                            Image(systemName: "mappin.circle.fill")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                                Text(place.name)
                                // 設計鐵律：一個守護地點＝剛好一個警戒圈，副標直接講那個圈的實際資訊
                                // （地址或警戒半徑）比報數字有用；0 圈孤兒才需要提示「還沒設」。
                                let fixedCircle = place.lifeCircles.first { $0.kind == .fixed }
                                Text(placeSubtitleText(fixedCircle))
                                    .font(.caption)
                                    .foregroundStyle(fixedCircle == nil ? HCColor.attention : .secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            context.delete(place)
                            context.saveReporting()
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                }
            }
            Button {
                gateAddPlace()
            } label: {
                // #9：同上，改用 HCCenteredLabel 保留 icon
                HCCenteredLabel("新增守護地點", systemImage: "plus.circle.fill")
            }
        }
    }

    /// 地點列表副標：一個地點剛好一個警戒圈，直接講那個圈的實際資訊（地址優先，
    /// 沒有地址文字才退回警戒半徑），比報「N 個警戒圈」這種需要心算的數字有用；
    /// 0 圈孤兒（歷史殘留）維持提示「還沒設」並暗示點進去完成。
    private func placeSubtitleText(_ circle: LocalLifeCircle?) -> String {
        guard let circle else { return "還沒設警戒圈——點我完成" }
        let address = circle.addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            return address
        }
        return "警戒半徑 \(circle.radiusMeters) 公尺"
    }

    /// 等前一張 sheet 的收合動畫結束再開警戒圈編輯器；
    /// 立刻 present 會撞上仍在收合中的 sheet 而被系統丟棄。
    ///
    /// 鐵律：只有「地點」才會有警戒圈（一個守護地點＝剛好一個警戒圈，額度＝地點數）。
    /// 只放行地點成員（見 createPlace）——#17 移除「新增家人」假家人卡入口後，
    /// 這個函式現在只會被地點流程呼叫，guard 仍保留當防呆。
    /// 兩段式新增地點的收尾：等 PlaceSelectView 這個 sheet 完全關閉（onDismiss）後，
    /// 才 present 圈編輯器。用 onDismiss 取代舊的「關 sheet→sleep 550ms→開下一個 sheet」
    /// 計時接力——後者在真機上常撞到「前一個 sheet 還在關就 present 下一個」被 SwiftUI 丟掉，
    /// 導致圈編輯器根本沒出現、地點成員變孤兒（新增固定圈完全打不開的根因）。
    private func presentPendingCircleEditor() {
        guard let member = pendingCirclePlace else { return }
        pendingCirclePlace = nil
        newMemberForCircle = member
    }

    // MARK: - 付費閘門（地點額度）

    /// 「新增重要地點」入口共用閘門：placesSection 內的新增列呼叫這裡。
    private func gateAddPlace() {
        guard entitlementStore.canAddPlace(currentCount: places.count) else {
            Analytics.track("paywall_from_place_limit")
            showPaywall = true
            return
        }
        addingPlace = true
    }

    /// PlaceSelectView 選定名稱後直接建立地點成員（不再經過 MemberEditorView 的打字表單），
    /// 接著沿用既有兩段式時序接固定圈編輯器。
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
    NavigationStack {
        FamilyHomeView()
    }
    .modelContainer(PreviewSupport.container())
    .environment(FamilySyncService())
    .environment(TabRouter())
    .environment(EntitlementStore())
}
#endif
