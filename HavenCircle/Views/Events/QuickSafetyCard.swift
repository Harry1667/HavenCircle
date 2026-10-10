import SwiftUI
import SwiftData

/// 動態頁頂端的「我平安」一鍵卡：打開 App 不必進家人分頁，一點就告訴家人你平安。
///
/// 沿用既有送出流程（FamilySyncService.postPing → Firestore pings），不新增後端：
/// 與家人分頁「回報平安」按鈕送出的是同一種安否回報。
/// 三種狀態：
/// - 沒有家人：改為引導邀請家人，不假裝送出（單人時沒有人會收到）。
/// - 可送出：醒目的「我平安」按鈕；附近有需要注意的事件時文案換成「附近有狀況，告訴家人你平安」。
/// - 已送出：顯示「已告訴家人你平安・剛剛」，並提供「改報需要協助」。
///   Firestore 規則只允許圈主刪除回報，一般成員無法撤回，所以這裡不提供「撤回」，
///   只提供更正成另一種狀態（家人看到的永遠是最新一筆）。
/// 定位是「家人互報平安」而非緊急求救：卡片固定附非緊急服務聲明與 110／119 提示。
struct QuickSafetyCard: View {
    /// 附近是否有需要注意的事件（落在守護範圍內的可信事件）
    let hasNearbyAttention: Bool

    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Query private var members: [LocalFamilyMember]
    @AppStorage(SettingsKeys.lastQuickPingAt) private var lastPingAt: Double = 0
    @AppStorage(SettingsKeys.lastQuickPingStatus) private var lastPingStatus = ""

    @State private var gate = SignInGate()
    @State private var isSending = false
    @State private var errorText: String?
    @State private var confirmNeedHelp = false

    /// 已送出狀態的有效期：超過就回到可再次送出的狀態（平安是「當下」的訊息）
    private static let sentValiditySeconds: Double = 30 * 60

    var body: some View {
        Group {
            if sync.isSolo(localMembers: members) {
                inviteFamilyCard
            } else {
                // 每 30 秒重算一次，讓「剛剛」自然變成「N 分鐘前」、過期後恢復成可送出
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let sent = sentState(now: context.date) {
                        sentCard(sent, now: context.date)
                    } else {
                        sendCard
                    }
                }
            }
        }
        // 內容撐滿整列：已送出卡文字較短時，卡片才不會比下方其他卡片窄一截
        .frame(maxWidth: .infinity, alignment: .leading)
        .hcCard()
        .cardRow()
        .signInPreflight(gate)
        .confirmationDialog("要告訴家人你需要協助嗎？", isPresented: $confirmNeedHelp, titleVisibility: .visible) {
            Button("告訴家人我需要協助") { send(.needHelp) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("家人會收到通知。安心圈不是緊急服務，危急請先直接撥 110／119。")
        }
    }

    // MARK: - 狀態

    private struct SentState {
        let status: SafetyStatus
        let at: Date
    }

    private func sentState(now: Date) -> SentState? {
        guard lastPingAt > 0, let status = SafetyStatus(rawValue: lastPingStatus) else { return nil }
        let at = Date(timeIntervalSince1970: lastPingAt)
        guard now.timeIntervalSince(at) < Self.sentValiditySeconds else { return nil }
        return SentState(status: status, at: at)
    }

    private func agoText(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "剛剛" : "\(minutes) 分鐘前"
    }

    // MARK: - 沒有家人

    private var inviteFamilyCard: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            HStack(alignment: .top, spacing: HCSpacing.x3) {
                Image(systemName: "person.2.badge.plus")
                    .foregroundStyle(HCColor.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("加入家人，才能一鍵報平安")
                        .font(.headline)
                    Text("目前還沒有家人會收到你的平安通知。邀請家人加入後，這裡點一下就能讓他們放心。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Analytics.track("quick_safe_invite_tapped")
                router.selection = TabRouter.familyTab
            } label: {
                Text("邀請家人")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(HCColor.brand)
            disclaimer
        }
    }

    // MARK: - 可送出

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x3) {
            if hasNearbyAttention {
                // 不只靠顏色：圖示＋文字說明為什麼此刻特別提醒
                Label("守護範圍內有需要注意的事件", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HCColor.attention)
            }
            Button {
                send(.safe)
            } label: {
                HStack(spacing: HCSpacing.x3) {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        // 主文固定「我平安」：長文案在窄螢幕會被截成「附近有狀況，告訴…」，
                        // 附近有狀況的提醒已在按鈕上方那行，副文再補一句即可
                        Text("我平安")
                            .font(.headline)
                        Text(hasNearbyAttention ? "附近有狀況，一鍵告訴家人" : "一鍵告訴家人你現在很平安")
                            .font(.caption)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, HCSpacing.x4)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(HCColor.safe, in: RoundedRectangle(cornerRadius: HCRadius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .accessibilityIdentifier("quickSafe.sendButton")
            .accessibilityHint(hasNearbyAttention ? "附近有狀況。送出後，家人會收到你平安的通知" : "送出後，家人會收到你平安的通知")
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(HCColor.danger)
            }
            disclaimer
        }
    }

    // MARK: - 已送出

    private func sentCard(_ sent: SentState, now: Date) -> some View {
        let isSafe = sent.status == .safe
        return VStack(alignment: .leading, spacing: HCSpacing.x3) {
            HStack(alignment: .top, spacing: HCSpacing.x3) {
                Image(systemName: sent.status.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSafe ? HCColor.safe : HCColor.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("已告訴家人\(sentPhrase(sent.status))・\(agoText(sent.at, now: now))")
                        .font(.headline)
                    Text(isSafe ? "家人會收到通知，可在「家人」分頁看到已讀回條。"
                                : "家人會收到通知。若情況危急，請先直接撥 110／119。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: HCSpacing.x2) {
                if isSafe {
                    Button("改報需要協助") { confirmNeedHelp = true }
                        .buttonStyle(.bordered)
                        .tint(HCColor.danger)
                } else {
                    Button("改報我平安") { send(.safe) }
                        .buttonStyle(.bordered)
                        .tint(HCColor.safe)
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(isSending)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(HCColor.danger)
            }
            disclaimer
        }
    }

    /// 狀態原文是第一人稱（「我平安」），直接接在「已告訴家人」後會變成「你我平安」，改成敘述句
    private func sentPhrase(_ status: SafetyStatus) -> String {
        switch status {
        case .safe: return "你平安"
        case .needHelp: return "你需要協助"
        case .inDanger: return "你尚未脫離危險"
        case .pleaseReport: return "請大家回報平安"
        }
    }

    private var disclaimer: some View {
        Text("安心圈不是緊急服務，遇到危險請直接撥 110／119。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 送出

    /// 未登入先走登入預告卡（登入後自動接續）；已登入直接送。
    /// isSending 在實際開始送出時才設，避免使用者取消登入後按鈕永遠鎖住。
    private func send(_ status: SafetyStatus) {
        guard !isSending else { return }
        errorText = nil
        gate.perform { await performSend(status) }
    }

    private func performSend(_ status: SafetyStatus) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        let ok = await sync.postPing(senderName: FamilyNaming.ownUploadName(), status: status)
        if ok {
            lastPingAt = Date.now.timeIntervalSince1970
            lastPingStatus = status.rawValue
            Analytics.track(status == .safe ? "quick_safe_sent" : "quick_help_sent")
            // 第一次報平安之後，才說明為什麼需要通知（家人回覆、附近警報）；已授權或問夠次數會自動略過
            if status == .safe { NotificationPrimer.shared.request(.firstSafePing, delay: .milliseconds(1500)) }
        } else if case .error(let message) = sync.state {
            // 人話文案已由 FamilySyncService 轉譯（含逾時「可能未送出」的說明）
            errorText = message
        } else {
            errorText = "沒有送出，請再試一次"
        }
    }
}

#if DEBUG
#Preview {
    List {
        QuickSafetyCard(hasNearbyAttention: true)
    }
    .modelContainer(PreviewSupport.container())
    .environment(FamilySyncService())
    .environment(TabRouter(selection: 0))
}
#endif
