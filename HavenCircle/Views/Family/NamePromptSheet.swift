import SwiftUI
import SwiftData

/// 「家人要怎麼稱呼你？」——需要名字的時機才問（建立／分享邀請、輸入邀請碼加入之前），不擋首屏。
///
/// 為什麼存在：以前沒人要求使用者輸入名字，App 拿「我」「家人」頂替並上傳，家人那邊就看到一位叫「我」
/// 的成員。現在名字只在真正要和家人連線前問一次；可略過，但會明講略過後家人會看到「家人 N」。
///
/// 可重用：
/// - 流程入口用 `NamePromptGate`（`gate.perform { ... }`＋`.namePrompt(gate)`）
/// - 家人頁「我的卡」編輯名字直接呈現 `NamePromptSheet(mode: .edit)`
struct NamePromptSheet: View {
    enum Mode { case ask, edit }

    var mode: Mode = .ask
    /// 按「儲存」或「先略過」後呼叫（呼叫端據此關閉 sheet）
    var onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(FamilySyncService.self) private var sync
    @AppStorage(SettingsKeys.profileDisplayName) private var storedName = ""
    @AppStorage(SettingsKeys.profileFamilyRole) private var storedRole = ""
    @State private var text = ""
    @State private var pickedRole: String?
    @FocusState private var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: HCSpacing.x2), count: 3)

    private var cleaned: String { FamilyNaming.clean(text) }
    /// 使用者輸入了「我」「家人」這類佔位字：不收，並提示改填真正的稱呼
    private var isPlaceholderInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cleaned.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：小明、媽媽", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("namePrompt.field")
                    LazyVGrid(columns: columns, spacing: HCSpacing.x2) {
                        ForEach(FamilyRole.all) { role in
                            Button {
                                text = role.label
                                pickedRole = role.label
                            } label: {
                                Text("\(role.emoji) \(role.label)")
                                    .font(.callout.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, HCSpacing.x2)
                                    .background(
                                        RoundedRectangle(cornerRadius: HCRadius.chip, style: .continuous)
                                            .fill(text == role.label ? HCColor.brand.opacity(0.14)
                                                                     : Color(.secondarySystemBackground))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(role.label)
                            .accessibilityAddTraits(text == role.label ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, HCSpacing.x1)
                } header: {
                    Text(mode == .ask ? "家人要怎麼稱呼你？" : "你的名字")
                } footer: {
                    if isPlaceholderInput {
                        Text("請填家人認得的稱呼，「我」「家人」這類字不會被當成名字。")
                            .foregroundStyle(HCColor.danger)
                    } else if mode == .ask {
                        Text("家人會在家人清單與平安回報看到這個名字。先略過的話，家人會暫時看到你是「家人 N」，之後可在家人頁「我」的卡片修改。")
                    } else {
                        Text("改名後會同步給家人。")
                    }
                }
            }
            .navigationTitle(mode == .ask ? "設定稱呼" : "編輯名字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == .ask ? "先略過" : "取消") {
                        Analytics.track(mode == .ask ? "name_prompt_skipped" : "name_edit_cancelled")
                        onFinish()
                    }
                    .accessibilityIdentifier("namePrompt.skip")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: save)
                        .disabled(cleaned.isEmpty)
                        .accessibilityIdentifier("namePrompt.save")
                }
            }
            .onAppear {
                text = FamilyNaming.clean(storedName)
                if mode == .ask { focused = true }
            }
        }
    }

    private func save() {
        guard !cleaned.isEmpty else { return }
        storedName = cleaned
        // 點了身分快捷鈕才連身分一起記（本名 ≠ 身分的人不會被蓋掉身分）
        if let pickedRole, pickedRole == cleaned { storedRole = pickedRole }
        Analytics.track(mode == .ask ? "name_prompt_saved" : "name_edited")
        Task { await sync.applyOwnNameChange(context: context) }
        onFinish()
    }
}

/// 「需要名字才能繼續」的把關：有名字直接執行；沒有就先彈 NamePromptSheet，
/// 使用者儲存或略過、sheet **完全關閉後**才執行原動作（避免在 sheet 收合動畫途中接著 present 下一張）。
@MainActor
@Observable
final class NamePromptGate {
    var isPresenting = false
    private var pending: (() -> Void)?

    init() {}

    func perform(_ action: @escaping () -> Void) {
        if FamilyNaming.hasOwnName {
            action()
        } else {
            pending = action
            isPresenting = true
        }
    }

    fileprivate func runPending() {
        guard let action = pending else { return }
        pending = nil
        action()
    }
}

extension View {
    /// 掛在用到 `NamePromptGate` 的畫面根層（需要 FamilySyncService environment）
    func namePrompt(_ gate: NamePromptGate) -> some View {
        modifier(NamePromptModifier(gate: gate))
    }
}

private struct NamePromptModifier: ViewModifier {
    @Bindable var gate: NamePromptGate

    func body(content: Content) -> some View {
        content.sheet(isPresented: $gate.isPresenting, onDismiss: { gate.runPending() }) {
            NamePromptSheet(mode: .ask) { gate.isPresenting = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .formPresentationSizing()
        }
    }
}

#if DEBUG
#Preview {
    NamePromptSheet(onFinish: {})
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
}
#endif
