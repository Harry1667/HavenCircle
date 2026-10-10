import SwiftUI
import AuthenticationServices

/// 登入前置：任何「需要登入才能做」的動作統一由這裡把關。
///
/// 設計動機：舊版把登入 gate 散落在各處（例如 InviteFamilySection 直接把人丟去設定頁一個
/// 死掉的 Apple 帳號畫面），使用者點了「邀請家人」卻只看到一句「請去設定」，不知道要做什麼。
/// 這裡統一成一個模式：已登入（判法同 FamilySyncService.createFamily 的
/// `guard let uid else { throw ... }`）→ 直接執行動作；未登入 → 先彈一張預告卡，解釋「為什麼
/// 要登入」、內嵌真登入按鈕，登入成功就自動接著把原本要做的事做完。
/// 目標：登入永遠不突襲（不會沒說明就跳系統框）、永遠不留死路（隨時可以「先不用」關掉）。
@MainActor
@Observable
final class SignInGate {
    var isPresentingPreflight = false
    private var pendingAction: (() async -> Void)?

    init() {}

    /// 觸發一個需要登入的動作：已登入就直接跑；未登入先顯示預告卡，登入成功後才執行。
    func perform(_ action: @escaping () async -> Void) {
        if AuthService.shared.uid != nil {
            Task { await action() }
        } else {
            pendingAction = action
            isPresentingPreflight = true
        }
    }

    fileprivate func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task { await action() }
    }

    fileprivate func cancel() {
        pendingAction = nil
    }
}

extension View {
    /// 掛在需要登入把關的畫面根層：預告卡 sheet 統一由這裡呈現，呼叫端只需要
    /// `signInGate.perform { ... }` 就能把任何動作包上登入前置。
    func signInPreflight(_ gate: SignInGate) -> some View {
        modifier(SignInPreflightModifier(gate: gate))
    }
}

private struct SignInPreflightModifier: ViewModifier {
    @Bindable var gate: SignInGate

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $gate.isPresentingPreflight) {
                SignInPreflightCard(
                    onSignedIn: { gate.runPendingAction() },
                    onSkip: { gate.cancel() }
                )
                .presentationDetents([.medium])
                // iPad 會忽略 presentationDetents 而放大成整頁 sheet，這裡收斂成 form 尺寸
                .formPresentationSizing()
            }
    }
}

/// 預告卡本體：先講「為什麼」再給登入按鈕，登入成功即自動關閉並接續原動作。
private struct SignInPreflightCard: View {
    /// 登入成功後呼叫（由呼叫端接著執行原本被擋下的動作）
    var onSignedIn: () -> Void
    /// 按「先不用」呼叫（單純放棄，不留待辦、下次還能再問）
    var onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.appleAccountEmail) private var appleEmail = ""
    @State private var signInError: String?

    var body: some View {
        VStack(spacing: HCSpacing.x4) {
            Spacer(minLength: 4)
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(HCColor.brandText)
            VStack(spacing: 6) {
                Text("連結家人需要 Apple 帳號")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("免費，只用來讓家人找到彼此")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SignInWithAppleButton(.signIn) { request in
                // nonce + requestedScopes 由 AuthService 統一設定（Firebase 憑證交換需要 nonce）
                AuthService.shared.prepareAppleRequest(request)
            } onCompletion: { result in
                handleSignIn(result)
            }
            .frame(height: 50)
            .padding(.horizontal, 32)

            SignInTermsLine()

            if let signInError {
                Text(signInError)
                    .font(.caption)
                    .foregroundStyle(HCColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("先不用") {
                onSkip()
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    /// 與 AppleSignInPage.handleSignIn 同一套邏輯：先存本機顯示欄位，
    /// 再用 idToken + nonce 換 Firebase 憑證真正登入。
    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            signInError = nil
            if let email = credential.email, !email.isEmpty {
                appleEmail = email
            }
            if let components = credential.fullName {
                let formatted = PersonNameComponentsFormatter().string(from: components)
                if !formatted.isEmpty && displayName.isEmpty {
                    displayName = formatted
                }
            }
            Task {
                do {
                    _ = try await AuthService.shared.completeAppleSignIn(credential)
                    SignInTermsLine.recordLegalAcceptance()
                    onSignedIn()
                    dismiss()
                } catch {
                    // 原始錯誤只進 log；UI 一律顯示轉譯過的人話（見 AuthService.userFacingMessage）
                    signInError = AuthService.userFacingMessage(for: error, context: "登入失敗")
                }
            }
        case .failure(let error):
            // 取消／裝置未登入／網路問題都交給共用轉譯判斷；使用者主動取消時會回傳 nil，不吵他
            signInError = AuthService.userFacingMessage(for: error, context: "登入失敗")
        }
    }
}

#if DEBUG
#Preview {
    Text("預覽用宿主")
        .sheet(isPresented: .constant(true)) {
            SignInPreflightCard(onSignedIn: {}, onSkip: {})
                .presentationDetents([.medium])
                .formPresentationSizing()
        }
}
#endif
