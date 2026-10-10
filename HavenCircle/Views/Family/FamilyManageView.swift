import SwiftUI
import SwiftData

/// 家庭圈管理（FamilyManage）：家人首頁拆出來的低頻、設定心智的功能。
/// 由上到下：位置分享（opt-in、可暫停、顯示最後更新）→ 警報跟著我 → 邀請更多家人（多人時）
/// → 輸入邀請碼換圈 → 解散／退出（最底，破壞性動作）。
/// 首頁只留「人」與「地方」，這些開關與一次性動作不再和回報、家人卡混在同一條捲軸上。
struct FamilyManageView: View {
    @Environment(\.modelContext) private var context
    @Environment(FamilySyncService.self) private var sync
    @Query private var members: [LocalFamilyMember]

    @State private var signInGate = SignInGate()
    @State private var showJoinByCode = false
    /// 已有家庭圈時，點「輸入邀請碼換圈」先說明後果的確認框
    @State private var showJoinSwitchConfirm = false

    // 退出／解散家庭圈
    @State private var showLeaveConfirm = false
    @State private var isLeavingFamily = false
    @State private var leaveError: String?

    private var isInFamilyCircle: Bool { sync.isInFamilyCircle }
    private var isCircleSolo: Bool { sync.isSolo(localMembers: members) }

    var body: some View {
        List {
            if isInFamilyCircle {
                // 位置分享：必須維持「本人自己開啟、可隨時停止、顯示最後更新、15 分鐘過期」
                LiveCircleSharingSection()
            }
            FollowCircleToggleSection(disambiguateFromSharing: isInFamilyCircle)
            if isInFamilyCircle && !isCircleSolo {
                // 多人時邀請入口收在這裡；單人時首頁的邀請碼卡就是唯一入口
                InviteFamilySection()
            }
            if isInFamilyCircle {
                joinByCodeSection
                leaveFamilySection
            }
        }
        .listSectionSpacing(HCSpacing.x6)
        .navigationTitle("家庭圈管理")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("family_manage")
        .signInPreflight(signInGate)
        .sheet(isPresented: $showJoinByCode) {
            JoinByCodeView(prefilledCode: nil)
                .hcSheet()
        }
        .confirmationDialog("要加入另一個家庭圈嗎？", isPresented: $showJoinSwitchConfirm, titleVisibility: .visible) {
            Button("繼續輸入邀請碼") {
                signInGate.perform {
                    showJoinByCode = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(joinSwitchMessage)
        }
        .confirmationDialog(leaveDialogTitle, isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button(isCircleSolo && sync.isFamilyOwner ? "解散家庭圈" : "退出家庭圈", role: .destructive) {
                Task { await performLeaveFamily() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(leaveDialogMessage)
        }
    }

    // MARK: - B：輸入邀請碼加入（已入圈時降級為次要入口）

    /// 已入圈時的換圈入口：放在管理頁、解散／退出上方。
    /// 實際行為（FamilySyncService.joinFamily）：加入新家庭圈成功後會自動退出目前的家庭圈，
    /// 所以按下去先跳確認框把後果講清楚；未入圈時的主要入口在 emptyStateSection，不經過這裡。
    private var joinByCodeSection: some View {
        Section {
            Button {
                showJoinSwitchConfirm = true
            } label: {
                Label("輸入邀請碼換圈", systemImage: "number.square")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("family.joinByCodeButton")
        } footer: {
            Text("想換到另一個家庭圈時使用。加入後會退出目前的家庭圈。")
        }
    }

    private var joinSwitchMessage: String {
        let current = sync.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = current.isEmpty ? "目前的家庭圈" : "「\(current)」"
        if sync.isFamilyOwner, isCircleSolo {
            return "你已在\(name)且只有你一人。加入新的家庭圈後，\(name)會被解散。"
        }
        return "你已在\(name)。加入新的家庭圈後會自動退出\(name)，原本的家人將看不到你，你也看不到他們。如果只是要邀請家人，請改用「邀請更多家人」。"
    }

    // MARK: - C：退出／解散家庭圈

    /// 已入圈兩態（單人／多人）底部都會出現的破壞性動作區。
    private var leaveFamilySection: some View {
        Section {
            Button(role: .destructive) {
                leaveError = nil
                showLeaveConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text(isCircleSolo && sync.isFamilyOwner ? "解散家庭圈" : "退出家庭圈")
                    if isLeavingFamily {
                        ProgressView()
                    }
                    Spacer()
                }
            }
            .disabled(isLeavingFamily)
            if let leaveError {
                Text(leaveError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// C2：文案分流——一般成員／圈主但還有其他成員／圈主且只剩自己（會直接解散）。
    private var leaveDialogTitle: String {
        isCircleSolo && sync.isFamilyOwner ? "確定要解散家庭圈嗎？" : "確定要退出家庭圈嗎？"
    }

    private var leaveDialogMessage: String {
        if isCircleSolo && sync.isFamilyOwner {
            return "你是唯一成員，退出後這個家庭圈會直接解散。"
        }
        let base = "退出後你將看不到家人的位置與回報，家人也看不到你。你的帳號與本機資料都會保留。"
        if sync.isFamilyOwner {
            return base + "你建立的家庭圈會留給其他成員繼續使用。"
        }
        return base
    }

    /// C3/C4：離開前先停止即時位置分享（避免 currentFamilyID 變 nil 後，背景定位更新
    /// 又透過 ensureFamily() 意外建立一個新家庭圈），再呼叫 FamilySyncService 統一入口
    /// （內部依 isFamilyOwner／memberUids 自動決定退出或解散，並清掉同步而來的家人投影）。
    /// 失敗要顯示人話錯誤，不得 silent fail。
    private func performLeaveFamily() async {
        isLeavingFamily = true
        leaveError = nil
        defer { isLeavingFamily = false }
        if UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled) {
            UserDefaults.standard.set(false, forKey: SettingsKeys.liveLocationSharingEnabled)
            LocationService.shared.syncLiveLocationSharing(isEnabled: false)
            await sync.stopLiveLocationSharing(context: context)
        }
        do {
            try await sync.leaveFamily(context: context)
        } catch {
            leaveError = "網路連線有問題，請稍後再試一次。"
            AppLog.cloudError("退出家庭圈失敗：\(error.localizedDescription)")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FamilyManageView()
    }
    .modelContainer(PreviewSupport.container())
    .environment(FamilySyncService())
    .environment(TabRouter())
}
#endif
