import SwiftUI
import SwiftData

/// 邀請家人的共用區塊：已入圈時是單獨一列「邀請更多家人」；未登入時走 SignInPreflight
/// 預告卡（不再是「查看 Apple 帳號狀態」把人丟去設定頁的死路——那顆按鈕連到的
/// AppleAccountView 舊版還是顆假登入按鈕，使用者點了也回不來）。
struct InviteFamilySection: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Query private var members: [LocalFamilyMember]
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var familyRole = ""

    @State private var signInGate = SignInGate()
    @State private var nameGate = NamePromptGate()
    @State private var showInviteOptions = false
    @State private var showRoleSelect = false
    @State private var isWorking = false
    @State private var shareError: String?

    var body: some View {
        Section {
            switch sync.state {
            case .noAccount:
                Button {
                    nameGate.perform { signInGate.perform { await startInvite() } }
                } label: {
                    Label("邀請更多家人", systemImage: "person.crop.circle.badge.plus")
                }
            default:
                Button {
                    nameGate.perform { Task { await startInvite() } }
                } label: {
                    HStack {
                        Label("邀請更多家人", systemImage: "person.crop.circle.badge.plus")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking || sync.state == .unknown)
            }
            if let shareError {
                Text(shareError)
                    .font(.caption)
                    .foregroundStyle(HCColor.danger)
            }
        }
        .signInPreflight(signInGate)
        .namePrompt(nameGate)
        // 邀請頁（建立家庭圈後）收合後，說明為什麼需要通知
        .sheet(isPresented: $showInviteOptions, onDismiss: { NotificationPrimer.shared.request(.family) }) {
            InviteOptionsView()
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
        .task { await sync.refreshAccountStatus() }
    }

    /// 建立家庭圈（若尚未建立）並開啟邀請碼畫面。首次建立家庭圈成功後先接身分選擇（C3），
    /// 選完／略過再開邀請碼畫面，避免使用者一直沒被問過「你在家裡是誰」。
    private func startInvite() async {
        isWorking = true
        shareError = nil
        defer { isWorking = false }
        do {
            let isFirstFamily = sync.currentInviteCode == nil
            if isFirstFamily {
                _ = try await sync.createFamily(context: context)
                showRoleSelect = true
            } else {
                // 已在家庭圈就沿用現有邀請碼，直接開邀請畫面
                showInviteOptions = true
            }
        } catch {
            // 失敗要讓使用者看到，不能只寫 log（silent fail 禁令）
            shareError = "建立家庭圈失敗：\(error.localizedDescription)"
            AppLog.cloudError("建立家庭圈失敗：\(error.localizedDescription)")
        }
    }

    /// #15 本名/身分分離：選身分只寫 `profileFamilyRole`，絕不覆寫 `profileDisplayName`。
    /// member.name 本名優先，本名還沒填時才用身分當顯示名。
    private func applyRole(_ role: FamilyRole) {
        familyRole = role.label
        if let me = members.first(where: \.isCurrentUser) {
            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            me.name = trimmedName.isEmpty ? role.label : trimmedName
            context.saveReporting()
        }
        Analytics.track("role_selected")
    }
}
