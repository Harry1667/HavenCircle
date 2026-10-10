import SwiftUI
import SwiftData

/// 用 8 位邀請碼加入家庭圈：兩段式流程（C2）——
/// 先查 Firestore 邀請碼索引拿到「要加入誰的家庭圈」的預覽（只讀，不寫入任何資料），
/// 使用者看到「你即將加入○○的家庭圈」確認後才真正呼叫 joinFamily，
/// 不會因為手滑打對一組陌生碼就悄悄加入不認識的家庭圈。
struct JoinByCodeView: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var members: [LocalFamilyMember]
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var familyRole = ""

    /// B2：deep link／QR 帶入的預填碼；出現時自動觸發一次查詢，省去使用者再打一次字。
    var prefilledCode: String? = nil

    @State private var code = ""
    @State private var isLookingUp = false
    @State private var lookupError: String?
    /// 查到的邀請預覽：非 nil＝進入「加入前確認」畫面（C2）
    @State private var preview: InvitePreview?
    @State private var isJoining = false
    @State private var joinError: String?
    /// 加入成功後：先播慶祝畫面（C3），「繼續」才接身分選擇
    @State private var showJoinWelcome = false
    @State private var showRoleSelect = false
    /// B3-2：身分選完／略過之後、真正 dismiss 整個加入流程之前，插入兩題激活（位置分享／通知）
    @State private var showActivation = false

    /// 格式檢查抽到 FirestoreFamilyBackend 共用（B3）：不只驗長度，也驗字元集，
    /// 讓「格式不對」與「查無此碼」是兩種不同、更精準的錯誤文案。
    private var isCodeValid: Bool {
        FirestoreFamilyBackend.isValidInviteCodeFormat(code)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    confirmSection(preview)
                } else {
                    inputSection
                }
            }
            .listSectionSpacing(HCSpacing.x6)
            .navigationTitle(preview == nil ? "輸入邀請碼加入" : "確認加入")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                Button("取消") { dismiss() }
            }
            // 輸碼與確認頁是同一個 view（preview 前後只是切換 section），只記一次
            .analyticsScreen("join_by_code")
            .fullScreenCover(isPresented: $showJoinWelcome) {
                JoinWelcomeView(familyDisplayName: welcomeFamilyName(preview)) {
                    showJoinWelcome = false
                    showRoleSelect = true
                }
            }
            .fullScreenCover(isPresented: $showRoleSelect) {
                RoleSelectView(
                    onSelect: { role in
                        applyRole(role)
                        showRoleSelect = false
                        showActivation = true // B3-2：接著問位置分享／通知，而不是直接 dismiss
                    },
                    onSkip: {
                        showRoleSelect = false
                        showActivation = true
                    }
                )
            }
            .fullScreenCover(isPresented: $showActivation) {
                PostJoinActivationView {
                    showActivation = false
                    dismiss() // 落回家人頁：此時成員清單已在 joinFamily 內刷新過
                }
            }
            .task(id: prefilledCode) {
                guard let prefilledCode, !prefilledCode.isEmpty else { return }
                code = String(prefilledCode.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                await lookupCode()
            }
        }
    }

    // MARK: - 第一段：輸碼／掃碼

    private var inputSection: some View {
        Section {
            VStack(spacing: HCSpacing.x3) {
                TextField("例如 AB12CD34", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("join.codeField")
                    // 鍵盤的 Return 直接送出：iPad 上鍵盤會蓋住「下一步」
                    .submitLabel(.next)
                    .onSubmit {
                        guard isCodeValid, !isLookingUp else { return }
                        Task { await lookupCode() }
                    }
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                    .kerning(HCSpacing.x1)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, HCSpacing.x3)
                    .background(
                        HCColor.brand.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: HCRadius.control, style: .continuous)
                    )
                    .onChange(of: code) { _, newValue in
                        // 只留合法字元、最多 8 碼，貼上帶空格也能正常
                        code = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                    }
                // PasteButton 不會觸發剪貼簿存取的系統提示（比 UIPasteboard 直讀更禮貌）
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    code = String(first.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                }
                .buttonBorderShape(.capsule)
            }
            Button {
                Task { await lookupCode() }
            } label: {
                HStack {
                    Label("下一步", systemImage: "arrow.right.circle.fill")
                        .font(.body.weight(.medium))
                    if isLookingUp {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HCColor.brand)
            .controlSize(.large)
            .disabled(!isCodeValid || isLookingUp)
            .accessibilityIdentifier("join.nextButton")
            if let lookupError {
                Label(lookupError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HCColor.danger)
                    .padding(HCSpacing.x2)
                    .background(
                        HCColor.danger.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                    )
            }
        } header: {
            Text("輸入家人給你的 8 位邀請碼")
        } footer: {
            Text("也可以直接用相機掃家人的 QR code。")
        }
    }

    // MARK: - 第二段：加入前確認（C2）

    private func confirmSection(_ preview: InvitePreview) -> some View {
        Section {
            VStack(spacing: HCSpacing.x6) {
                ZStack {
                    Circle()
                        .fill(HCColor.brand.opacity(0.08))
                        .frame(width: HCSpacing.x6 * 4, height: HCSpacing.x6 * 4)
                    Circle()
                        .stroke(HCColor.brand.opacity(0.16), lineWidth: HCSpacing.x1 / 2)
                        .frame(width: HCSpacing.x6 * 5, height: HCSpacing.x6 * 5)
                    Image(systemName: "person.2.fill")
                        .font(.largeTitle.weight(.medium))
                        .foregroundStyle(HCColor.brand)
                }
                .accessibilityHidden(true)

                VStack(spacing: HCSpacing.x2) {
                    Text("你即將加入")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(inviteTitle(preview))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                }

                // 已有家庭圈時，說清楚加入的後果（會自動退出目前的家庭圈）
                if let notice = switchFamilyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(HCColor.attention)
                        .multilineTextAlignment(.leading)
                        .padding(HCSpacing.x2)
                        .background(
                            HCColor.attention.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                        )
                }

                if isJoining {
                    ProgressView()
                        .padding(.vertical, HCSpacing.x2)
                } else {
                    Button {
                        Task { await join(familyId: preview.familyId) }
                    } label: {
                        Text(sync.isInFamilyCircle ? "退出目前家庭圈並加入" : "加入")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HCColor.brand)
                    .controlSize(.large)
                    .accessibilityIdentifier("join.confirmButton")

                    Button("取消") {
                        self.preview = nil
                        joinError = nil
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if let joinError {
                    Text(joinError)
                        .font(.caption)
                        .foregroundStyle(HCColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(HCSpacing.x2)
                        .background(
                            HCColor.danger.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HCSpacing.x6)
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

    /// 已在家庭圈時的後果說明；未入圈回傳 nil。
    /// 實際行為見 FamilySyncService.joinFamily：新家庭加入成功後會自動退出舊家庭
    /// （只剩自己的圈主則一併解散舊家庭圈）。
    private var switchFamilyNotice: String? {
        guard sync.isInFamilyCircle else { return nil }
        let current = sync.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentName = current.isEmpty ? "目前的家庭圈" : "「\(current)」"
        if sync.isFamilyOwner, sync.memberUids.count <= 1 {
            return "你已在\(currentName)，且只有你一人。加入新的家庭圈後，\(currentName)會被解散。"
        }
        return "你已在\(currentName)。加入新的家庭圈後會自動退出\(currentName)，原本的家人將看不到你，你也看不到他們。"
    }

    /// C2 標題優先序：自訂家庭名（非預設值「我的家庭」）優先；否則用「○○的家庭圈」；
    /// 兩者皆缺（舊邀請碼，補欄位之前建立的）就用通用降級文案。
    private func inviteTitle(_ preview: InvitePreview) -> String {
        if let name = preview.familyName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name != "我的家庭" {
            return name
        }
        if let owner = preview.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            return "\(owner) 的家庭圈"
        }
        return "這組邀請碼的家庭圈"
    }

    /// B3-1：歡迎頁（JoinWelcomeView）專用抬頭。同一份 InvitePreview，但用「安心圈」品牌詞
    /// 而非確認頁的「家庭圈」——確認頁接的是「你即將加入 ___」，這裡接的是慶祝語氣的
    /// 「已加入「___」！」，優先序仍是：自訂家庭名 >「○○ 的安心圈」>「安心圈」。
    private func welcomeFamilyName(_ preview: InvitePreview?) -> String {
        guard let preview else { return "安心圈" }
        if let name = preview.familyName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name != "我的家庭" {
            return name
        }
        if let owner = preview.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            return "\(owner) 的安心圈"
        }
        return "安心圈"
    }

    private func lookupCode() async {
        guard isCodeValid else {
            lookupError = "邀請碼格式不對，應該是 8 位英數字（不含 0、1、O、I 等易混淆字元）。"
            return
        }
        isLookingUp = true
        lookupError = nil
        defer { isLookingUp = false }
        do {
            preview = try await FirestoreFamilyBackend.lookupInvite(code: code)
        } catch {
            lookupError = classify(error, notFound: "找不到這組邀請碼，可能已失效，請向家人確認後再輸入一次。")
            AppLog.cloudError("查詢邀請碼失敗：\(error.localizedDescription)")
        }
    }

    private func join(familyId: String) async {
        isJoining = true
        joinError = nil
        defer { isJoining = false }
        do {
            try await sync.joinFamily(code: code, context: context)
            showJoinWelcome = true
        } catch {
            joinError = classify(error, notFound: "這組邀請碼已失效，請向家人確認後再試一次。")
            AppLog.cloudError("加入家庭圈失敗：\(error.localizedDescription)")
        }
    }

    /// 錯誤訊息講人話（B3）：分流「查無此碼」與「網路失敗」，不把 error.localizedDescription
    /// 直接丟給使用者看——原始錯誤只進 log。
    /// familyNotFound：邀請碼本身合法（inviteCodes 索引查得到），但指向的家庭圈已被圈主解散
    /// （見 FirestoreFamilyBackend.joinFamily 的錯誤轉換）——視同「這組碼已失效」處理。
    private func classify(_ error: Error, notFound: String) -> String {
        switch error {
        case FamilyBackendError.invalidInviteCode, FamilyBackendError.familyNotFound:
            return notFound
        case FamilyBackendError.inviteExpired:
            return "這組邀請碼已過期，請家人重新產生一組。"
        default:
            return "網路連線有問題，請檢查網路後再試一次。"
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

#if DEBUG
#Preview {
    JoinByCodeView()
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
}
#endif
