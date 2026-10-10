import Foundation
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import SwiftData // MemberImportVisibility：AppRuntime.container?.mainContext 用得到 ModelContainer 的成員
import os // Swift 6.2 MemberImportVisibility：直接使用 os.Logger 插值的檔案必須自行 import

/// Firebase 身份服務：用 Sign in with Apple 登入 Firebase Auth，取得穩定的 uid。
///
/// 設計動機：Firebase 家庭圈用 uid 當成員與位置文件的主鍵，取代舊 CloudKit 架構的
/// participantID（本機隨機 UUID）與 CKCurrentUserDefaultName。uid 是跨裝置、換手機都不變的
/// 真實身份，家庭圈的「誰是誰」才穩得住。
///
/// 隱私邊界：登入只換到一個匿名的 uid 字串；顯示名稱／email 仍存在本機 @AppStorage，
/// 由使用者決定要不要分享給家人（同意式）。
@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    /// 目前登入的 Firebase uid（未登入為 nil）。家庭圈所有寫入都以此為身份。
    private(set) var uid: String?
    private(set) var isSignedIn: Bool = false

    /// 當前登入流程使用的原始 nonce。Apple 端用它的 SHA256 簽 idToken，
    /// Firebase 端用原始值驗證，兩者比對防止重放攻擊。
    private var currentNonce: String?

    /// Firebase Auth 狀態監聽 handle，deinit 時要移除，避免 listener 洩漏。
    /// 這兩個 token 只用於生命週期清理，無須觸發畫面重繪。
    @ObservationIgnored private var authStateHandle: AuthStateDidChangeListenerHandle?
    /// Apple 帳號授權撤銷通知的 observer token，deinit 時要移除（理由同上）。
    @ObservationIgnored private var credentialRevokedObserver: NSObjectProtocol?

    /// 這次登入使用的 Apple 穩定使用者代碼（`credential.user`）存本機，供之後
    /// [checkAppleCredentialState] 複查 Apple 端授權是否被撤銷。只是 Apple 給的不透明代碼，
    /// 不是任何可讀的個資。
    private static let appleUserIdentifierDefaultsKey = "authAppleUserIdentifier"

    private init() {
        // Firebase Auth 會持久化 session；啟動時直接還原既有登入狀態，免得每次都要重登。
        if let user = Auth.auth().currentUser {
            uid = user.uid
            isSignedIn = true
            // 本機名字是空的、但 Firebase 帳號有 displayName（Apple 首次授權的姓名）時回填
            ProfileIdentity.backfillLocalName()
        }

        // #2/#13：登入狀態要即時反映，不能只在啟動時讀一次快照。掛上 Firebase 官方的狀態監聽，
        // 之後不論是「這次啟動之後才完成登入」或「其他地方呼叫 signOut／帳號被撤銷」，
        // uid/isSignedIn 都會自動更新（本類別是 @Observable，看這兩個欄位的畫面會自動重繪，
        // 不必再靠使用者下拉刷新）。
        //
        // 狀態「真的改變」時，順便自動觸發 FamilySyncService.refreshAccountStatus()——這是
        // 「登入完成但家人頁要下拉才顯示已登入」這個 bug 的根本解法：狀態源頭一變就自動推播，
        // 不必等使用者手動點「重新檢查帳號狀態」。這裡用 AppRuntime.familySync（一個
        // HavenCircleApp.init 建立後才賦值的橋接指標，同一份 FamilySyncService 實例）去呼叫，
        // 而不是讓 FamilySyncService 反過來訂閱 AuthService——本類別只是呼叫一個既有 singleton
        // 實例上的方法，沒有新增任何雙向的強參照，不會造成循環相依。
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                let newUid = user?.uid
                let stateChanged = self.isSignedIn != (newUid != nil) || self.uid != newUid
                self.uid = newUid
                self.isSignedIn = newUid != nil
                if stateChanged {
                    await AppRuntime.familySync?.refreshAccountStatus()
                }
            }
        }

        // #11：監聽 Apple 帳號授權撤銷（使用者到系統「設定」登出這個 Apple 帳號，或撤銷了
        // 對本 App 的存取）。這個通知只在 App 存活期間才送得到；App 沒在跑時會錯過，
        // 所以另外提供 [checkAppleCredentialState] 給啟動／回前景時主動複查（見 HavenCircleApp）。
        credentialRevokedObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleCredentialRevocation()
            }
        }
    }

    isolated deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
        if let credentialRevokedObserver {
            NotificationCenter.default.removeObserver(credentialRevokedObserver)
        }
    }

    // MARK: - Sign in with Apple 流程

    /// 在 SignInWithAppleButton 的 request 階段呼叫：產生一次性 nonce，
    /// 設定 requestedScopes 與 nonce 的 SHA256。
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Apple 授權成功後呼叫：用 idToken + 原始 nonce 換 Firebase 憑證並登入，回傳 uid。
    @discardableResult
    func completeAppleSignIn(_ credential: ASAuthorizationAppleIDCredential) async throws -> String {
        guard let nonce = currentNonce else {
            throw AuthError.missingNonce
        }
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )
        let result = try await Auth.auth().signIn(with: firebaseCredential)
        currentNonce = nil
        uid = result.user.uid
        isSignedIn = true
        // #11：存下 Apple 穩定使用者代碼，供之後 [checkAppleCredentialState] 複查授權是否被撤銷。
        UserDefaults.standard.set(credential.user, forKey: Self.appleUserIdentifierDefaultsKey)
        // 名字回填：本機還沒名字時，用 Apple 這次給的姓名（僅首次授權才有），否則用 Firebase displayName
        ProfileIdentity.backfillLocalName(fullName: credential.fullName)
        AppLog.cloud.info("Firebase Auth（Sign in with Apple）登入成功")
        return result.user.uid
    }

    /// 登出：清除 Firebase session 與本地身份狀態。
    func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            AppLog.cloud.error("Firebase 登出失敗：\(error.localizedDescription)")
        }
        uid = nil
        isSignedIn = false
        currentNonce = nil
    }

    // MARK: - #11：Apple 帳號撤銷偵測（登出 Apple 帳號 → 退出家庭圈；同帳號重登 → 自動加回）

    /// App 啟動／回前景時主動複查一次 Apple 授權狀態（Apple 官方建議的雙重保險：
    /// `credentialRevokedNotification` 只在 App 存活時才送得到，這裡補上「App 沒在跑時
    /// 錯過通知」的情況，見 HavenCircleApp 的呼叫點）。從未用 Apple 登入過（沒存過使用者代碼）
    /// 就直接略過，不發任何請求。
    func checkAppleCredentialState() async {
        guard let appleUserID = UserDefaults.standard.string(forKey: Self.appleUserIdentifierDefaultsKey) else {
            return
        }
        guard let state = await Self.fetchCredentialState(forUserID: appleUserID) else { return }
        if state == .revoked {
            await handleCredentialRevocation()
        }
    }

    /// `ASAuthorizationAppleIDProvider.getCredentialState` 只有 completion handler 版本，
    /// 包一層 continuation 讓呼叫端能用 async/await。
    private static func fetchCredentialState(
        forUserID userID: String
    ) async -> ASAuthorizationAppleIDProvider.CredentialState? {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error {
                    AppLog.cloud.error("查詢 Apple 授權狀態失敗：\(error.localizedDescription)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: state)
                }
            }
        }
    }

    /// 確認 Apple 授權已撤銷：登出 Firebase＋清掉本機家庭圈投影，但**不**呼叫雲端的
    /// 退出／解散家庭圈——刻意保留 Firestore `memberUids` 裡的這個 uid，讓使用者用「同一個」
    /// Apple 帳號重新登入時，[FamilySyncService.refreshAccountStatus] 能透過既有的
    /// [FirestoreFamilyBackend.findFamily]（用 uid 反查 `memberUids` array-contains）
    /// 自動找回原本的家庭圈，而不是永久失聯。
    ///
    /// 實作上借用 [FamilySyncService.leaveFamily]：呼叫它之前已經把 `uid` 設為 nil，
    /// 該函式內部 `if let uid, let familyID = currentFamilyID` 這段守門會整段跳過，
    /// 完全不會打 FirestoreFamilyBackend 的 leaveFamily／deleteFamily，只會執行後半段
    /// 「清本機投影＋重置本機狀態」——正是這裡要的效果，不需要再另寫一套清除邏輯。
    private func handleCredentialRevocation() async {
        AppLog.cloud.info("偵測到 Apple 帳號授權已撤銷，登出並清除本機家庭圈投影（雲端 memberUids 保留，供重新登入自動尋回）")
        do {
            try Auth.auth().signOut()
        } catch {
            AppLog.cloud.error("Firebase 登出失敗（Apple 授權撤銷後）：\(error.localizedDescription)")
        }
        uid = nil
        isSignedIn = false
        currentNonce = nil
        UserDefaults.standard.removeObject(forKey: Self.appleUserIdentifierDefaultsKey)
        try? await AppRuntime.familySync?.leaveFamily(context: AppRuntime.container?.mainContext)
    }

    // MARK: - 刪除帳號（App Store 5.1.1(v)：帳號刪除必須真的刪掉帳號本體）

    /// 永久刪除 Firebase 帳號＋盡力撤銷 Apple 授權。呼叫端須先用 [prepareAppleRequest] 設定
    /// SignInWithAppleButton 的 request，拿到使用者重新授權後的 credential 再呼叫本函式。
    ///
    /// 設計：一律先「重新驗證」再刪除，不做「先試刪、失敗才驗」——原因有二，合併處理讓流程單純：
    /// 1. Firebase 對「刪除帳號」這類敏感操作要求近期登入（requiresRecentLogin），先驗證一次最直接；
    /// 2. 只有這次全新的 Apple 授權流程才能拿到 `authorizationCode`，用來呼叫 Apple 的
    ///    token revocation——沒有這次重新授權，撤銷授權根本無從做起。
    ///
    /// 呼叫順序：reauthenticate（滿足 1、2 兩點）→ 丟一個背景 Task 嘗試撤銷 Apple 授權
    /// （真.盡力而為：不等待、不擋住後面的刪除，失敗只記 log）→ 真正刪除 Firebase 帳號。
    /// reauthenticate 與刪除各自套 15 秒逾時保護——這兩步是僅存還會讓 UI 無限期卡住的網路請求
    /// （離線／訊號差時 Firebase SDK 本身不會自己逾時），逾時就丟 [AuthTimeoutError]，
    /// 讓呼叫端的「刪除中」畫面能解鎖並顯示「請重試」，不再無限期卡住。
    ///
    /// ⚠️ 呼叫端要注意順序：任何「這個使用者還在家庭圈裡」相關的 Firestore 清理
    /// （退出／解散家庭圈）都必須在呼叫本函式「之前」做完——一旦 `currentUser.delete()`
    /// 成功，Firebase Auth session 立即消失，之後所有 Firestore 呼叫的 `request.auth`
    /// 都會變成 null，Security Rules 會直接拒絕，屆時再也無法替自己清理任何雲端資料。
    func deleteAccount(with credential: ASAuthorizationAppleIDCredential) async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }
        guard let nonce = currentNonce else {
            throw AuthError.missingNonce
        }
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )
        currentNonce = nil

        // 重新驗證：滿足 requiresRecentLogin，同時是唯一能拿到新鮮 authorizationCode 的時機。
        // 逾時保護（15 秒，withThrowingTaskGroup 讓「真正請求」與「計時器」賽跑，仿照
        // FirestoreFamilyBackend.postPing 的既有逾時實作模式，誰先完成用誰的結果）。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await user.reauthenticate(with: firebaseCredential) }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw AuthTimeoutError()
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }

        // 撤銷 Apple 授權：真.盡力而為——丟到背景 Task 就不再等待，失敗只記 log，
        // 不擋住下面的 user.delete()。舊版寫成 await 擋在刪除之前，註解說「盡力而為」但
        // 實作卻讓它成為刪除流程的必經關卡，這裡改成名符其實的 fire-and-forget。
        if let codeData = credential.authorizationCode,
           let authorizationCode = String(data: codeData, encoding: .utf8) {
            Task {
                do {
                    try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
                } catch {
                    AppLog.cloud.error("Apple 授權撤銷失敗（fire-and-forget，不影響刪除流程）：\(error.localizedDescription)")
                }
            }
        } else {
            AppLog.cloud.error("Apple 授權缺少 authorizationCode，無法撤銷（不中斷刪除流程）")
        }

        // 真正刪除 Firebase 帳號。逾時保護（15 秒），理由同上。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await user.delete() }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw AuthTimeoutError()
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
        uid = nil
        isSignedIn = false
        AppLog.cloud.info("Firebase 帳號已刪除")
    }

    // MARK: - nonce 工具（Firebase 官方 Sign in with Apple 建議實作）

    /// 產生密碼學等級的隨機 nonce 字串。
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

extension AuthService {
    /// 統一把 Sign in with Apple／Firebase 相關錯誤轉成人話：原始錯誤一律記 log（error 級）
    /// 供除錯排查，UI 只顯示對使用者友善的訊息，不直出 `error.localizedDescription`
    /// （真機上曾出現「AuthorizationError error 10…」這類讀不懂又被截斷的訊息）。
    ///
    /// - Parameters:
    ///   - error: 原始錯誤（ASAuthorizationError／URLError／其他）。
    ///   - context: 只用於 log 的場景描述（例如「登入失敗」「刪除帳號驗證失敗」），不會顯示給使用者。
    /// - Returns: 給使用者看的訊息；`nil` 表示不需要顯示任何東西（例如使用者主動按取消）。
    static func userFacingMessage(for error: Error, context: String) -> String? {
        // 不論最終要不要顯示給使用者，原始錯誤都先記下來，除錯才有根據。
        AppLog.cloudError("\(context)：\(error.localizedDescription)")

        if let authError = error as? ASAuthorizationError {
            if authError.code == .canceled {
                // 使用者主動取消，不是錯誤，不吵他。
                return nil
            }
            // 其餘 ASAuthorizationError（含 .unknown / error 1000）最常見成因是
            // 這台裝置根本沒有登入 Apple 帳號，直接告訴使用者怎麼解。
            return "登入沒有完成。請確認這台裝置已在「設定」登入 Apple 帳號，然後再試一次。"
        }

        // #1：reauthenticate／刪除帳號逾時，給明確、可行動的文案，不要落到最後泛用的
        // 「登入失敗，請再試一次」（那句話對「正在刪除」的情境文不對題）。
        if error is AuthTimeoutError {
            return error.localizedDescription
        }

        let nsError = error as NSError
        if error is URLError || nsError.domain == NSURLErrorDomain {
            return "網路連線有問題，請稍後再試。"
        }

        return "登入失敗，請再試一次。"
    }
}

enum AuthError: LocalizedError {
    case missingNonce
    case missingIdentityToken
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .missingNonce:
            return "登入流程遺失驗證碼，請重試一次。"
        case .missingIdentityToken:
            return "無法取得 Apple 身份權杖，請重試一次。"
        case .notSignedIn:
            return "目前沒有登入中的帳號，無法刪除。"
        }
    }
}

/// #1：reauthenticate／刪除帳號本體逾時（15 秒未完成）。離線或訊號差時 Firebase SDK
/// 不會自己逾時，[AuthService.deleteAccount] 用這個錯誤讓 UI 能解鎖並提示使用者重試，
/// 不再無限期卡在「正在刪除…」畫面。
struct AuthTimeoutError: LocalizedError {
    var errorDescription: String? { "網路逾時，請重試。" }
}
