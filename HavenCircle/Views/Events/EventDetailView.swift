import SwiftUI
import SwiftData
import UIKit

struct EventDetailView: View {
    let event: LocalSafetyEvent
    let members: [LocalFamilyMember]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(FamilySyncService.self) private var sync
    @AppStorage(SettingsKeys.profileDisplayName) private var profileName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var familyRole = ""
    @State private var aiExpanded = false
    @State private var checkInFeedback: String?
    /// 回報失敗／逾時的人話錯誤（見 FamilySyncService.humanPingErrorMessage）；
    /// 與 checkInFeedback 互斥，兩者任一顯示前都會清掉另一個
    @State private var checkInError: String?
    /// 「這類警報以後不吵醒我」按過後的回饋文字（nil＝尚未按過）
    @State private var wakeMuteFeedback: String?
    @State private var isReporting = false
    // C1：情境觸發邀請——「我平安」回報完成、圈內沒有其他人時，原地展開邀請卡
    @State private var showSoloInviteCard = false
    @State private var signInGate = SignInGate()
    @State private var showRoleSelect = false
    @State private var showInviteOptions = false
    @State private var isInviting = false
    @State private var inviteError: String?
    // AI 影響分析：只在使用者主動點按時才呼叫，結果存行程內快取避免重複計費
    @State private var aiImpact: String?
    @State private var aiImpactLoading = false
    @State private var aiImpactError: String?

    private var decision: AlertDecision {
        AlertPolicy.evaluate(event: event, members: members)
    }

    /// 這則事件最靠近的命中圈（決定安否按鈕要放哪一組）
    private var closestMatch: CircleMatch? {
        decision.matches.min(by: { $0.distanceMeters < $1.distanceMeters })
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                actionAdviceSection
                // 110/119 放在建議行動之後的第一屏內，不再藏在最底
                emergencySection
                detailSection
                whySection
                checkInSection
                infoSection
                sourceTimelineSection
                resourceSection
                actionSection
                // AI 分析非核心、需要網路：放最底並預設折疊
                aiImpactSection
            }
            .listSectionSpacing(HCSpacing.x6)
            .navigationTitle(event.isDrill ? "【演練】\(event.title)" : event.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .presentationDragIndicator(.visible)
            .onAppear {
                // 重開同一事件時，若行程內已有分析結果就直接顯示，不再打 AI
                if aiImpact == nil { aiImpact = AIImpactCache.store[impactCacheKey] }
            }
            // C1：情境觸發邀請的登入前置＋邀請動線（沿用 FamilyHomeView.startInviteFlow 的作法）
            .signInPreflight(signInGate)
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
            .sheet(isPresented: $showInviteOptions) {
                InviteOptionsView()
                    // iPad 會忽略隱含尺寸而放大成整頁 sheet，這裡收斂成 form 尺寸
                    .formPresentationSizing()
            }
        }
    }

    /// AI 個人化影響分析：結合這起事件與使用者的警戒圈命中狀況，說明「對我的影響」。
    /// 成本/延遲控制：僅在使用者主動點按時才呼叫；結果快取在行程內（同一事件重開不重複計費）；
    /// 用低運算強度（effort=low）壓延遲。刻意不寫進 SwiftData，避免為快取改 schema 觸發遷移風險。
    @ViewBuilder
    private var aiImpactSection: some View {
        Section {
            DisclosureGroup(isExpanded: $aiExpanded) {
                if let aiImpact {
                    Text(aiImpact)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    Text("AI 生成，僅供參考，不取代官方指示；有立即危險請直接撥 119 或 110。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await runImpactAnalysis(force: true) }
                    } label: {
                        Label("重新分析", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.caption)
                    .disabled(aiImpactLoading)
                } else {
                    Text("依你設定的警戒圈與這起事件的位置、類型，產生個人化的影響說明。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await runImpactAnalysis(force: false) }
                    } label: {
                        HStack {
                            Spacer()
                            Label("開始分析", systemImage: "sparkles")
                                .foregroundStyle(HCColor.brand)
                            if aiImpactLoading {
                                ProgressView()
                            }
                            Spacer()
                        }
                    }
                    .disabled(aiImpactLoading)
                }
                if let aiImpactError {
                    Text(aiImpactError)
                        .font(.caption)
                        .foregroundStyle(HCColor.danger)
                }
            } label: {
                Label("AI 分析：這起事件對我的影響", systemImage: "sparkles")
                    .font(.subheadline)
            }
        }
    }

    /// 這起事件在行程內快取的鍵：以事件本身＋命中圈的簽章組合，
    /// 圈設定改變（距離/時段/成員）時 key 就變，會重新分析而非給舊結果。
    private var impactCacheKey: String {
        let signature = decision.matches
            .map { "\($0.memberName):\($0.circleName):\($0.distanceMeters):\($0.withinSchedule)" }
            .joined(separator: ",")
        return "\(event.eventType)|\(Int(event.occurredAt.timeIntervalSince1970))|\(event.approximateLocation)|\(signature)"
    }

    /// 組給 AI 的提示詞：只帶「概略」位置與距離（已取整到百公尺），不外洩精確座標。
    private var impactPrompt: String {
        var lines: [String] = [
            "你是台灣的防災助理。根據以下災害事件與使用者的守護設定，用繁體中文寫一段 100–150 字的「這起事件對我的影響」個人化說明。",
            "要求：具體、冷靜、不誇大；聚焦(1)是否可能影響到使用者或其家人／據點(2)建議的下一步（留意／遠離／聯繫家人）。若有立即危險請提醒直接撥 119 或 110，不要提供其他電話號碼。不要重複事件標題，直接輸出說明本文、不要開場白。",
            "",
            "【事件】",
            "類型：\(event.eventType)",
            "概略位置：\(event.approximateLocation)",
            "發生時間：\(localizedDate(event.occurredAt))",
            "嚴重程度：\(event.severity)",
            // 直接用 trustStatus 文字（官方已確認／多來源交叉驗證／主流媒體報導／持續確認中），
            // 不要用 isOfficiallyConfirmed 二分——那會把主流媒體單一報導誤描述成「未驗證線索」，
            // 讓 AI 生成的個人化說明失真
            "狀態：\(event.trustStatus)",
        ]
        if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            lines.append("說明：\(detail)")
        }
        lines.append("")
        lines.append("【我的守護設定】")
        // 隱私：送到外部 AI 的內容「去識別化」——不送使用者自訂圈名（如「阿嬤家」）與家人真實稱謂，
        // 只送「我／一位家人」＋已取整到百公尺的概略距離。保留空間個人化，但不外洩可識別的名稱與關係細節。
        if decision.matches.isEmpty {
            lines.append("目前沒有任何警戒範圍直接落在事件影響範圍內，但使用者仍在關注此類事件。")
        } else {
            for match in decision.matches {
                let who = match.isCurrentUser ? "我" : "一位家人"
                let schedule = match.withinSchedule ? "提醒時段內" : "提醒時段外"
                lines.append("- \(who)的警戒範圍約 \(match.distanceMeters) 公尺（\(schedule)）")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func runImpactAnalysis(force: Bool) async {
        // 非強制且已有快取：直接用，不計費
        if !force, let cached = AIImpactCache.store[impactCacheKey] {
            aiImpact = cached
            return
        }
        aiImpactLoading = true
        aiImpactError = nil
        defer { aiImpactLoading = false }
        do {
            let result = try await AIService.complete(prompt: impactPrompt, effort: "low")
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            aiImpact = trimmed
            AIImpactCache.store[impactCacheKey] = trimmed
        } catch {
            aiImpactError = "分析失敗：\(error.localizedDescription)"
            AppLog.cloudError("AI 影響分析失敗：\(error.localizedDescription)")
        }
    }

    /// 狀態文案：故意用 trustStatus 逐一列出（而非 isOfficiallyConfirmed 二分），
    /// 避免主流媒體單一報導被誤標成「未驗證線索，不會自動通知家人」——mediaConfirmed
    /// 事件現在與 crossVerified 同樣可能觸發家人通知（見 AlertPolicy），文案要跟著誠實；
    /// 但也絕不能把它寫成「官方來源已確認」，那會違反「媒體報導不能偽裝成官方資訊」的產品底線。
    private func statusMessage(for event: LocalSafetyEvent) -> String {
        switch event.trustStatus {
        case TrustStatus.officialConfirmed:
            return "官方來源已確認。若有立即危險，請直接撥打 110 或 119。"
        case TrustStatus.crossVerified:
            return "已有多來源交叉驗證，可信度足以列入警戒圈提醒。若有立即危險，請直接撥打 110 或 119。"
        case TrustStatus.mediaConfirmed:
            return "已由主流媒體報導，可信度足以列入警戒圈提醒，惟尚未經官方證實。若有立即危險，請直接撥打 110 或 119。"
        default:
            return "這是未驗證線索，資料仍在確認中，不會自動通知家人。"
        }
    }

    private var statusSection: some View {
        let statusColor = event.isEnded || !event.isOngoing
            ? Color.secondary
            : (event.isCredible ? HCColor.danger : HCColor.attention)
        return Section {
            VStack(alignment: .leading, spacing: HCSpacing.x3) {
                HStack(spacing: HCSpacing.x3) {
                    Image(
                        systemName: event.isEnded
                            ? "checkmark.circle"
                            : (event.isOngoing
                                ? (event.isCredible ? "checkmark.seal.fill" : "clock.badge.questionmark")
                                : "newspaper")
                    )
                    .font(.title3.weight(.medium))
                    .foregroundStyle(statusColor)
                    .frame(width: HCSpacing.x6 * 2, height: HCSpacing.x6 * 2)
                    .background(statusColor.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                    Text("\(event.statusText)・\(event.trustStatus)")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                Divider()
                if event.isEnded {
                    Text("此事件已結束，無需進一步行動。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !event.isOngoing {
                    Text("這是非即時的背景資訊，不會作為警戒圈提醒或推播依據。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(statusMessage(for: event))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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

    /// 任務 A：「建議行動」獨立成醒目卡片——把「你現在該怎麼做」跟「發生什麼」分開，
    /// 不再讓建議行動埋在 LLM 生成的 detail 描述裡（那段文字每次生成用字都不同，
    /// 行動指引不該跟著變）。文案來自 EventActionAdvice 依 eventType 的靜態對照，不解析 LLM 文字。
    /// 底色沿用 event.typeColor（任務 C 的類型色），已結束事件改中性灰階，呼應狀態與類型色分離的原則。
    private var actionAdviceSection: some View {
        let advice = EventActionAdvice.advice(for: event)
        let tint = event.isEnded ? Color.secondary : event.typeColor
        return Section {
            HStack(alignment: .top, spacing: HCSpacing.x3) {
                Image(systemName: event.isEnded ? "checkmark.shield" : "figure.walk")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: HCSpacing.x6 * 2, height: HCSpacing.x6 * 2)
                    .background(tint.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("建議行動")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(advice)
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(HCSpacing.x3)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
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

    /// 110 / 119 一鍵撥號（第一屏）
    private var emergencySection: some View {
        Section {
            EmergencyCallRow()
        }
        .listRowInsets(
            EdgeInsets(top: HCSpacing.x1, leading: HCSpacing.x4, bottom: HCSpacing.x1, trailing: HCSpacing.x4)
        )
        .listRowBackground(Color.clear)
    }

    /// AI 整理的詳細描述：新聞事件是爬蟲 LLM 產的白話說明、官方事件是政府原始 description。
    /// 只在有內容時顯示；空的舊資料不佔版面（詳情頁其他區塊仍完整）。
    @ViewBuilder
    private var detailSection: some View {
        if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            Section("事件說明") {
                VStack(alignment: .leading, spacing: HCSpacing.x3) {
                    Text(detail)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    Divider()
                    Text(event.isOfficiallyConfirmed
                         ? "以上為官方發布內容。"
                         : "以上為新聞來源經整理後的說明，非官方確認資訊。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「每則通知都能看見為何收到」——直接顯示 AlertPolicy 的決策理由
    private var whySection: some View {
        Section("提醒判斷") {
            Text(decision.reason)
                .font(.subheadline)
            ForEach(decision.matches, id: \.circleName) { match in
                LabeledContent("\(match.isCurrentUser ? "我" : match.memberName)・\(match.circleName)") {
                    Text("約 \(match.distanceMeters) 公尺\(match.withinSchedule ? "" : "（時段外）")")
                }
                .font(.caption)
            }
        }
        .listRowSeparatorTint(.secondary.opacity(0.16))
    }

    /// 安否操作：與通知按鈕同一套「主角」邏輯，讓錯過通知的人也能在詳情頁快速回報。
    /// 我的圈→回報平安/尚未脫離危險；家人的圈→詢問對方是否平安；地點類（倉庫）→不顯示。
    @ViewBuilder
    private var checkInSection: some View {
        if !event.isEnded, let match = closestMatch, !match.isPlace {
            Section("安否") {
                if match.isCurrentUser {
                    Button {
                        report(.safe)
                    } label: {
                        Label("回報我平安", systemImage: "checkmark.circle.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HCColor.safe)
                    .controlSize(.large)
                    Button {
                        report(.inDanger)
                    } label: {
                        Label("尚未脫離危險", systemImage: "exclamationmark.triangle.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(HCColor.danger)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(HCColor.danger)
                    .controlSize(.large)
                    Button {
                        report(.needHelp)
                    } label: {
                        Label("需要協助", systemImage: "exclamationmark.circle.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(HCColor.danger)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(HCColor.danger)
                    .controlSize(.large)
                } else {
                    Button {
                        report(.pleaseReport)
                    } label: {
                        Label("詢問\(match.memberName)是否平安", systemImage: "questionmark.circle.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HCColor.brand)
                    .controlSize(.large)
                }
                if let checkInFeedback {
                    Label(checkInFeedback, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(HCColor.safe)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HCSpacing.x2)
                        .background(
                            HCColor.safe.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                        )
                }
                if let checkInError {
                    Label(checkInError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(HCColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HCSpacing.x2)
                        .background(
                            HCColor.danger.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                        )
                }
                if showSoloInviteCard {
                    soloInviteCard
                }
            }
            .disabled(isReporting)
        }
    }

    /// C1：情境觸發邀請——災害當下、剛按完「我平安」是邀請意願最高的瞬間，
    /// 圈內卻沒有其他人能看到這則回報，原地補一張卡把人導去邀請動線。
    private var soloInviteCard: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            HStack(alignment: .top, spacing: HCSpacing.x3) {
                Image(systemName: "person.2.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(HCColor.brand)
                    .frame(width: HCSpacing.x6 + HCSpacing.x3, height: HCSpacing.x6 + HCSpacing.x3)
                    .background(HCColor.brand.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                Text("你的回報已記錄，但還沒有家人會看到。邀請家人，讓他們安心。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                Analytics.track("solo_checkin_invite_tapped")
                signInGate.perform { await startInviteFlow() }
            } label: {
                Label("邀請家人", systemImage: "person.crop.circle.badge.plus")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HCColor.brand)
            .controlSize(.large)
            .disabled(isInviting)
            if isInviting {
                ProgressView()
            }
            if let inviteError {
                Text(inviteError)
                    .font(.caption)
                    .foregroundStyle(HCColor.danger)
            }
        }
        .hcCard()
    }

    /// 未登入時不能讓請求直接進 postPing 黑洞——套用既有的 SignInGate 模式（沿用同一個
    /// signInGate 實例，已由 `.signInPreflight(signInGate)` 掛在 body 根層）：已登入直接送出；
    /// 未登入先彈登入預告卡，登入成功後自動接續原本要回報的狀態。
    private func report(_ status: SafetyStatus) {
        signInGate.perform { await performReport(status) }
    }

    private func performReport(_ status: SafetyStatus) async {
        isReporting = true
        checkInFeedback = nil
        checkInError = nil
        let senderName = profileName.trimmingCharacters(in: .whitespaces).isEmpty ? "我" : profileName
        let success = await sync.postPing(
            senderName: senderName,
            status: status,
            note: status == .pleaseReport ? "從事件詳情發起平安確認" : "從事件詳情回報"
        )
        isReporting = false
        guard success else {
            // 失敗／逾時的人話文案已由 FamilySyncService 就地轉換好、存在 sync.state 裡；
            // 沒有更精確資訊時才退回通用文案（理論上 postPing 失敗一定會設 state，這裡是保底）。
            if case .error(let message) = sync.state {
                checkInError = message
            } else {
                checkInError = "回報失敗，請再試一次"
            }
            return
        }
        checkInFeedback = status == .pleaseReport ? "已送出確認請求" : "已送出回報"
        // C1：只有「我平安」且圈內目前沒有其他人時才觸發——這是模擬死點 5 的核心時機
        if status == .safe && sync.isSolo(localMembers: members) {
            showSoloInviteCard = true
            Analytics.track("solo_checkin_invite_shown")
        }
    }

    /// 建立家庭圈（沿用 FamilySyncService.ensureInviteReady，與 FamilyHomeView.startInviteFlow
    /// 共用同一份「建或沿用」決策，不重複實作）並依是否第一次建立決定先接身分選擇還是直接開邀請碼。
    private func startInviteFlow() async {
        isInviting = true
        inviteError = nil
        defer { isInviting = false }
        do {
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

    /// #15 本名/身分分離：選身分只寫 `profileFamilyRole`，絕不覆寫 `profileDisplayName`。
    /// member.name 本名優先，本名還沒填時才用身分當顯示名。
    private func applyRole(_ role: FamilyRole) {
        familyRole = role.label
        if let me = members.first(where: \.isCurrentUser) {
            let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            me.name = trimmedName.isEmpty ? role.label : trimmedName
            context.saveReporting()
        }
        Analytics.track("role_selected")
    }

    /// 任務 C：「類型」改用類型色 pill（圖示＋文字），紅／黃分級一眼可辨，
    /// 不再是純文字——與可信度／狀態的顏色（statusSection）各用各的屬性，互不參照。
    private var infoSection: some View {
        Section("事件資訊") {
            LabeledContent("類型") {
                Label(event.eventType, systemImage: EventCategory.icon(for: event.eventType))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(event.typeColor)
                    .padding(.horizontal, HCSpacing.x2)
                    .padding(.vertical, 3)
                    .background(event.typeColor.opacity(0.12), in: Capsule())
            }
            LabeledContent("概略位置", value: event.approximateLocation)
            LabeledContent("嚴重程度", value: event.severity)
            LabeledContent("位置精準度") {
                Text("約 \(event.precisionMeters) 公尺").monospacedDigit()
            }
            LabeledContent("最近更新") {
                Text(localizedDate(event.updatedAt)).monospacedDigit()
            }
        }
        .font(.subheadline)
        .listRowSeparatorTint(.secondary.opacity(0.16))
    }

    /// 任務 B：「來源與時效」透明度區塊——把來源全名、可信度、發生時間、有效期限攤開，
    /// 讓使用者自己判斷資訊新舊與有效性，不必只靠 App 的信任背書。
    /// 數字（日期時間）一律套 `.monospacedDigit()`，多行對齊時不會因數字寬度不一而歪斜。
    private var sourceTimelineSection: some View {
        Section("來源與時效") {
            LabeledContent("來源", value: event.sourceName)
            if let url = URL(string: event.sourceURL) {
                LabeledContent("原始連結") {
                    Link("查看原始來源", destination: url)
                }
            } else {
                // 來源網址格式異常時仍以文字呈現，不讓 App 因強制解包閃退
                LabeledContent("來源網址", value: event.sourceURL)
            }
            LabeledContent("可信度", value: event.trustStatus)
            LabeledContent("發生時間") {
                Text(localizedDate(event.occurredAt)).monospacedDigit()
            }
            LabeledContent("有效至") {
                if event.isExpired {
                    Text("已過期・\(localizedDate(event.expiresAt))")
                        .monospacedDigit()
                        .foregroundStyle(HCColor.danger)
                } else {
                    Text(localizedDate(event.expiresAt)).monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .listRowSeparatorTint(.secondary.opacity(0.16))
    }

    /// 事件「發生後怎麼辦」：離事件最近的避難收容所與急救責任醫院＋一鍵導航。
    /// 座標全數來自政府開放資料官方欄位（消防署／衛福部＋國土測繪中心），未自行 geocode——
    /// 導航目的地的正確性是安全產品的誠信底線。
    private var resourceSection: some View {
        Section("緊急應變") {
            resourceRow(kind: ResourceKind.shelter)
            resourceRow(kind: ResourceKind.hospital)
            Text("有立即危險時請勿等待 App 指引：直接撥打 119（火災、救護）或 110（治安）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("資料來源：內政部消防署避難收容處所、衛福部急救責任醫院名單。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func resourceRow(kind: String) -> some View {
        if let nearest = EmergencyResourceStore.nearest(
            kind: kind, latitude: event.latitude, longitude: event.longitude
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kind)：\(nearest.resource.name)").font(.subheadline)
                    Text("約 \(formattedDistance(nearest.distanceMeters)) · \(nearest.resource.district)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("導航", systemImage: "arrow.triangle.turn.up.right.circle") {
                    openInMaps(nearest.resource)
                }
                .font(.caption)
            }
        }
    }

    private func formattedDistance(_ meters: Int) -> String {
        meters >= 1000
            ? String(format: "%.1f 公里", Double(meters) / 1000)
            : "\(max(meters / 100 * 100, 100)) 公尺"
    }

    private func openInMaps(_ resource: EmergencyResource) {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(resource.latitude),\(resource.longitude)"),
            URLQueryItem(name: "q", value: resource.name),
        ]
        if let url = components?.url {
            UIApplication.shared.open(url)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                EventVisibility.suppressSimilar(to: event)
                dismiss()
            } label: {
                Label("隱藏此裝置的相似提醒", systemImage: "hand.thumbsdown")
                    .frame(maxWidth: .infinity)
            }
            // 降級只影響「吵不吵醒」，不影響通知送不送達——scheduleAlert 的 effectiveTimeSensitive 規則 f 讀同一集合
            Button {
                AlertWakePrefs.mute(event.eventType)
                wakeMuteFeedback = "已設定，這類警報以後不會吵醒你"
            } label: {
                Label("這類警報以後不吵醒我", systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity)
            }
            if let wakeMuteFeedback {
                Label(wakeMuteFeedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func localizedDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_TW")).year().month().day().hour().minute())
    }
}

/// 事件 AI 影響分析的行程內快取：同一事件重開不重複計費（重啟 App 即清空）。
/// 刻意不落地到 SwiftData——避免為快取欄位改 @Model schema 觸發遷移風險（見 LESSONS）。
@MainActor
enum AIImpactCache {
    static var store: [String: String] = [:]
}
