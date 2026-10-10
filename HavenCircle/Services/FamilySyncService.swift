import Foundation
import CoreLocation
import SwiftData
import UIKit
import FirebaseFirestore
import FirebaseMessaging
import os

/// 登入 / 家庭圈狀態，供 UI 呈現對應提示
enum FamilySyncState: Equatable {
    case unknown
    case noAccount          // 未登入 Firebase Auth（Sign in with Apple）
    case ready              // 已登入，尚未建立或加入家庭圈
    case sharing            // 已是某個家庭圈的成員
    case error(String)
}

/// Firebase Firestore 家庭圈同步服務。
///
/// 設計：
/// - 身份用 Firebase Auth 的 uid（[AuthService]）——跨裝置、換手機都穩定，取代舊 CloudKit 的
///   本機隨機 participantID 與 CKCurrentUserDefaultName。
/// - 家庭圈根、成員、即時位置、安否回報都存 Firestore（[FirestoreFamilyBackend]）。
/// - 8 碼邀請碼取代 CKShare：建立者產生碼、家人輸碼加入，跨 iCloud 帳號都能用。
/// - 即時位置為「同意式」：使用者開啟分享才寫入 locations 子集合，隨時可停。
///
/// 保留舊架構的本機投影：把家人即時位置投影成 SwiftData 即時圈（[applyLiveLocationSnapshots]），
/// 讓既有的警報比對、地圖、摘要不必另外維護一套資料。
@MainActor
@Observable
final class FamilySyncService {
    private(set) var state: FamilySyncState = .unknown
    private(set) var pings: [SafetyPing] = []
    private(set) var liveLocations: [FamilyLiveLocation] = []
    private(set) var liveLocationError: String?
    /// 目前家庭圈的邀請碼（給 UI 顯示、分享給家人）；未在家庭圈時為 nil
    private(set) var currentInviteCode: String?
    /// 目前邀請碼的到期時間（C4：InviteOptionsView 顯示「效期至」用）。
    /// nil 代表「舊邀請碼沒有 expiresAt 欄位」（長期有效）或尚未讀到，兩者 UI 上顯示同一種文案。
    private(set) var currentInviteCodeExpiresAt: Date?
    /// 自動換新碼進行中／失敗訊息（家人頁與邀請頁共用，過期時畫面據此顯示進度或重試）
    private(set) var isRenewingInviteCode = false
    private(set) var inviteRenewError: String?
    /// 目前家庭圈的名稱（A4 header 用）；未在家庭圈或尚未讀到時為 nil
    private(set) var familyName: String?
    /// 目前家庭圈的成員 uid 清單（雲端真相）；未在家庭圈時為空陣列。
    /// FamilyHomeView 等畫面判斷「單人／多人」一律看這個，不看本機 LocalFamilyMember 筆數——
    /// 本機清單是投影，會落後於雲端（見 [isSolo]）。
    private(set) var memberUids: [String] = []
    /// 目前登入者是否為這個家庭圈的圈主（雲端真相）；未在家庭圈或尚未載入完成時為 false。
    /// 用於「退出家庭圈」判斷要走一般退出還是解散（見 [leaveFamily]）。
    private(set) var isFamilyOwner: Bool = false

    // 位置寫入去抖狀態（沿用舊邏輯，避免 GPS 抖動造成寫入風暴）
    private var lastPublishedLocation: CLLocation?
    private var lastPublishedAt: Date?
    private var lastPublishedRadius: Int?
    /// 上次寫入的「開始停留時間」；與 lastPublishedLocation（停留錨點座標）一起決定這次是否算移動
    private var lastStationarySince: Date?
    /// 上次確認「實際移動」的時間，與連續像在移動的筆數（見 MovementJudge：連續 2 筆才確認，防 GPS 漂移）
    private var lastMovedAt: Date?
    private var movedStreak = 0
    /// 上次追加的軌跡點（決定這次要不要再加一點）與上次清理過期點的時間
    private var lastTrailSample: LocationSample?
    private var lastTrailCleanupAt: Date?
    /// MainActor 在 await 期間仍可重入；只允許一筆位置寫入在途，避免重複建立同一 doc
    private var liveLocationPublishInFlight = false
    /// 共用守護地點同步狀態（見 syncPlaces）：避免重入、記錄本機近期寫入
    private var placesSyncInFlight = false
    private var recentPlaceWrites: [String: Date] = [:]

    /// Firebase 身份（未登入為 nil）
    private var uid: String? { AuthService.shared.uid }

    /// 目前所屬家庭圈的 Firestore familyId（本機快取；換裝置由 uid 反查還原）
    private var currentFamilyID: String? {
        get { UserDefaults.standard.string(forKey: SettingsKeys.currentFamilyID) }
        set {
            let defaults = UserDefaults.standard
            // 家庭指標一變（建立／加入／離開），成員文件可能是新的或被刪過 → 清掉權杖同步標記
            defaults.removeObject(forKey: SettingsKeys.fcmTokenSyncedMarker)
            if let newValue {
                defaults.set(newValue, forKey: SettingsKeys.currentFamilyID)
            } else {
                defaults.removeObject(forKey: SettingsKeys.currentFamilyID)
            }
        }
    }

    var ownLiveLocation: FamilyLiveLocation? {
        guard let uid else { return nil }
        return liveLocations.first { $0.participantID == uid && $0.isSharing }
    }

    /// D1：「是否已加入或建立家庭圈」的單一真相來源。FamilyHomeView 等畫面的空狀態／
    /// 家人清單分支一律看這個，不看本機 LocalFamilyMember 筆數——後者是本機投影，
    /// 剛加入、refreshFamilyMembers 還沒跑完時會落後，導致「明明已加入卻還顯示邀請空狀態」的錯覺。
    var isInFamilyCircle: Bool { currentFamilyID != nil }

    /// 單人／多人判斷的共用規則（取代 FamilyHomeView／FamilyHubView／HomeStatusView 各自一份）：
    /// 已在家庭圈時看雲端 memberUids（至少含自己一人，尚未載入完成時保守視為單人，
    /// 避免「載入前一瞬間」誤判成多人而閃現錯的畫面）；未在家庭圈時退回本機成員數（沿用舊行為）。
    func isSolo(localMembers: [LocalFamilyMember]) -> Bool {
        if isInFamilyCircle {
            return max(memberUids.count, 1) < 2
        }
        return localMembers.filter { !$0.isPlace }.count < 2
    }

    /// 本人要上傳的名字：本名 > 家庭身分 > 空字串。**絕不回傳「我」「家人」「圈主」這類佔位字**
    /// （規則見 [FamilyNaming]）；空字串代表「沒有名字」，家人端自己顯示「家人 N」。
    private var displayName: String { FamilyNaming.ownUploadName() }

    // MARK: - 名字 fallback 與同步

    /// 讀取端 fallback：別人沒有名字時顯示「家人 N」。N＝該 uid 在「其他成員」中的加入順序
    /// （memberUids 由 arrayUnion 依加入順序追加，穩定）；memberUids 尚未載入時退回已知位置文件
    /// 的 uid 排序。只用於顯示，絕不上傳。
    func fallbackName(forUid targetUid: String) -> String {
        var others = memberUids.filter { $0 != uid }
        if !others.contains(targetUid) {
            others = Array(Set(liveLocations.map(\.id).filter { $0 != uid } + [targetUid])).sorted()
        }
        let index = others.firstIndex(of: targetUid) ?? 0
        return FamilyNaming.fallbackLabel(number: index + 1)
    }

    /// 解析一位成員要顯示的名字：自己＝真名或「我」；別人＝真名或「家人 N」
    func resolvedName(_ raw: String, forUid targetUid: String) -> String {
        let cleaned = FamilyNaming.clean(raw)
        if targetUid == uid { return cleaned.isEmpty ? "我" : cleaned }
        return cleaned.isEmpty ? fallbackName(forUid: targetUid) : cleaned
    }

    private func resolvedLocations(_ locations: [FamilyLiveLocation]) -> [FamilyLiveLocation] {
        locations.map { $0.withDisplayName(resolvedName($0.displayName, forUid: $0.participantID)) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// 本人改名／設定名字後的統一入口（NamePromptSheet、設定頁共用）：
    /// 1. 本機「本人」成員的名字跟著改（有真名用真名，沒有才用身分，都沒有維持原狀）
    /// 2. 已在家庭圈就把新名字同步到雲端（成員資料＋位置文件＋圈主邀請碼預覽）
    /// profileDisplayName 由呼叫端先寫進 UserDefaults/AppStorage。
    func applyOwnNameChange(context: ModelContext) async {
        let resolved = FamilyNaming.ownUploadName()
        if !resolved.isEmpty,
           let me = (try? context.fetch(FetchDescriptor<LocalFamilyMember>()))?.first(where: \.isCurrentUser),
           me.name != resolved {
            me.name = resolved
            context.saveReporting()
        }
        await syncOwnNameToCloud(onlyIfPlaceholder: false)
    }

    /// 把本人名字同步到雲端所有相關文件（成員資料＋位置文件＋圈主的邀請碼預覽）。
    /// 改名後呼叫（onlyIfPlaceholder: false）；App 啟動時以 true 呼叫＝只清掉舊版留下的佔位字。
    /// 沒登入或不在家庭圈時什麼都不做。
    func syncOwnNameToCloud(onlyIfPlaceholder: Bool) async {
        guard AuthService.shared.isSignedIn, let uid, let familyID = currentFamilyID else { return }
        do {
            try await FirestoreFamilyBackend.syncOwnName(
                familyId: familyID, uid: uid, name: displayName,
                onlyIfPlaceholder: onlyIfPlaceholder,
                isOwner: isFamilyOwner, inviteCode: currentInviteCode
            )
        } catch {
            AppLog.cloud.error("同步名字到雲端失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - 帳號 / 家庭狀態

    func refreshAccountStatus() async {
        guard AuthService.shared.isSignedIn, let uid else {
            state = .noAccount
            isFamilyOwner = false
            return
        }
        do {
            if currentFamilyID == nil {
                // 本機沒存 familyId 就用 uid 反查（換裝置、重裝後還原所屬家庭）
                if let family = try await FirestoreFamilyBackend.findFamily(forUid: uid) {
                    currentFamilyID = family.id
                    await applyFamily(family)
                }
            } else if let familyID = currentFamilyID {
                // 每次都重讀根文件，讓 familyName/memberUids（A4 header、D1 單人判斷）保持新鮮，
                // 而不是只在「邀請碼尚未快取」時才補讀一次。
                let family = try await FirestoreFamilyBackend.fetchFamily(familyId: familyID)
                await applyFamily(family)
            }
        } catch {
            AppLog.cloud.error("查詢所屬家庭失敗：\(error.localizedDescription)")
        }
        state = currentFamilyID == nil ? .ready : .sharing
    }

    /// 把家庭圈根文件套用到本服務暴露的欄位（邀請碼／名稱／成員 uid 清單），
    /// 並附帶讀一次邀請碼的到期時間（C4）。到期時間存在 inviteCodes/{code} 文件而不是家庭
    /// 根文件上，所以這裡多一次讀取；讀取失敗（例如剛好離線）不擋主流程，頂多這次先顯示
    /// nil，下次呼叫再補上，不影響其他欄位。
    private func applyFamily(_ family: FamilyCircleDoc) async {
        currentInviteCode = family.inviteCode
        familyName = family.name
        memberUids = family.memberUids
        isFamilyOwner = family.ownerUid == uid
        currentInviteCodeExpiresAt = try? await FirestoreFamilyBackend.fetchInviteCodeExpiry(code: family.inviteCode)
        await syncFCMToken()
    }

    /// 把本機 FCM 權杖寫進 families/{id}/members/{uid}（fcmToken），讓 Oracle 的 family_push.php
    /// 能依 uid 找到要推播的裝置（家人到達通知、更新位置喚醒）。
    /// 權杖＋家庭＋uid 沒變就不重寫，避免每次刷新都打 Firestore；失敗只記 log，下次刷新會再試。
    func syncFCMToken() async {
        guard let uid, let familyID = currentFamilyID,
              let token = Messaging.messaging().fcmToken, !token.isEmpty else { return }
        let marker = "\(familyID)|\(uid)|\(token)"
        let key = SettingsKeys.fcmTokenSyncedMarker
        if UserDefaults.standard.string(forKey: key) == marker { return }
        do {
            try await FirestoreFamilyBackend.publishFCMToken(familyId: familyID, uid: uid, token: token)
            UserDefaults.standard.set(marker, forKey: key)
        } catch {
            AppLog.cloud.error("寫入 FCM 權杖失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - 建立 / 加入家庭圈（邀請碼取代 CKShare）

    /// 建立家庭圈（成為圈主）並產生邀請碼。回傳建立好的家庭圈。
    /// context 有給的話，建立完立即刷新一次成員清單（A2 呼叫點）；
    /// 內部自動建立（見 [ensureFamily]）不一定有 context 可用，留 nil 不強求。
    @discardableResult
    func createFamily(name: String = "我的家庭", context: ModelContext? = nil) async throws -> FamilyCircleDoc {
        guard let uid else { throw FamilyBackendError.notSignedIn }
        let family = try await FirestoreFamilyBackend.createFamily(
            ownerUid: uid,
            ownerDisplayName: displayName,
            familyName: name
        )
        currentFamilyID = family.id
        await applyFamily(family)
        state = .sharing
        if let context {
            await refreshFamilyMembers(context: context)
        }
        return family
    }

    /// 用 8 碼邀請碼加入家庭圈。context 有給的話，加入成功立即刷新成員清單（A2 呼叫點）。
    func joinFamily(code: String, context: ModelContext? = nil) async throws {
        guard let uid else { throw FamilyBackendError.notSignedIn }
        // 已有家庭圈時加入另一個＝「換家庭圈」。舊版沒處理這件事：只把本機指標改指向新家庭，
        // 雲端舊家庭的 memberUids 仍留著自己（幽靈成員、舊家人還看得到我）。
        // 這裡先記下舊家庭狀態，新家庭加入成功後才退出舊的（先加入再退出：加入失敗時原家庭完好）。
        let previousFamilyID = currentFamilyID
        let previousWasSoloOwner = isFamilyOwner && memberUids.count <= 1
        let familyID = try await FirestoreFamilyBackend.joinFamily(
            code: code,
            uid: uid,
            displayName: displayName
        )
        if let previousFamilyID, previousFamilyID != familyID {
            do {
                if previousWasSoloOwner {
                    try await FirestoreFamilyBackend.deleteFamily(familyId: previousFamilyID, uid: uid)
                } else {
                    try await FirestoreFamilyBackend.leaveFamily(familyId: previousFamilyID, uid: uid)
                }
            } catch {
                // 新家庭已加入成功，不回頭擋流程；殘留的舊成員資格只記 log
                AppLog.cloud.error("換家庭圈時退出舊家庭失敗：\(error.localizedDescription)")
            }
            if let context { purgeSyncedFamilyProjection(context: context) }
            pings = []
            liveLocations = []
            UserDefaults.standard.removeObject(forKey: SettingsKeys.knownFamilyMemberUids)
        }
        currentFamilyID = familyID
        if let family = try? await FirestoreFamilyBackend.fetchFamily(familyId: familyID) {
            await applyFamily(family)
        }
        state = .sharing
        await fetchPings()
        if let context {
            await refreshFamilyMembers(context: context)
        }
    }

    /// 重新產生邀請碼（C3）：只有圈主能真正生效（對照 firestore.rules `inviteCodes/{code}`
    /// 的 `isOwner` 刪除權；非圈主呼叫舊碼刪不掉，但 UI 本來就只對圈主顯示這顆按鈕，見
    /// InviteOptionsView 用 [isFamilyOwner] 判斷）。成功後立即更新 currentInviteCode／
    /// currentInviteCodeExpiresAt，讓 QR code 與分享文案馬上換成新碼，不必等下次刷新。
    func regenerateInviteCode() async throws {
        guard let familyID = currentFamilyID else { return }
        let result = try await FirestoreFamilyBackend.regenerateInviteCode(familyId: familyID)
        currentInviteCode = result.code
        currentInviteCodeExpiresAt = result.expiresAt
    }

    /// 目前邀請碼的效期狀態（純函式判斷，見 InviteCodeExpiry）
    var inviteCodeExpiry: InviteCodeExpiry {
        InviteCodeExpiry.evaluate(expiresAt: currentInviteCodeExpiresAt)
    }

    /// 邀請碼已過期或剩不到 24 小時就自動換新碼；不需要換就什麼都不做。
    /// 任何家庭成員都能換（rules：成員可更新家庭根文件、任何登入者可建立 inviteCodes；
    /// 只有刪舊碼需圈主，且該步驟本來就是盡力而為）。
    /// 失敗不吞：寫進 [inviteRenewError]，畫面顯示人話錯誤與重試鈕；
    /// 已過期的碼在失敗期間仍不可分享（見 InviteCodeExpiry.isShareable）。
    func renewInviteCodeIfNeeded() async {
        guard currentFamilyID != nil, inviteCodeExpiry.needsRenewal, !isRenewingInviteCode else { return }
        isRenewingInviteCode = true
        inviteRenewError = nil
        defer { isRenewingInviteCode = false }
        do {
            try await regenerateInviteCode()
        } catch {
            inviteRenewError = "邀請碼已過期，自動換新碼失敗。請檢查網路後按「重試」。"
            AppLog.cloudError("自動換新邀請碼失敗：\(error.localizedDescription)")
        }
    }

    /// 確保有家庭圈可寫入；沒有就自動建一個（給「還沒建家庭圈就發位置／回報」的情境）。回傳 familyId。
    private func ensureFamily() async throws -> String {
        if let familyID = currentFamilyID { return familyID }
        return try await createFamily().id
    }

    /// 邀請動線共用起點：FamilyHomeView「邀請家人」與事件詳情頁 C1 情境卡都從這裡開始——
    /// 還沒有家庭圈就建立一個（成為圈主）；已有的話原樣沿用現有邀請碼，不重建。
    /// 回傳「這是不是第一次建立家庭圈」，讓呼叫端決定要不要先接身分選擇（RoleSelectView）
    /// 再開邀請碼畫面——這個 UI 順序留在各畫面自己決定，這裡只管「確保家庭圈存在」這件事。
    @discardableResult
    func ensureInviteReady(context: ModelContext? = nil) async throws -> Bool {
        let isFirstFamily = currentInviteCode == nil
        if isFirstFamily {
            _ = try await createFamily(context: context)
        }
        return isFirstFamily
    }

    // MARK: - 家庭成員清單（A1）

    /// 從 Firestore 抓最新家庭圈根文件與成員清單，把「非本人」的成員 upsert 成本機
    /// LocalFamilyMember，並偵測「新成員加入」發本機通知（A3）。
    ///
    /// 鍵用 sharedIdentityKey（已查證：applyLiveLocationSnapshots 存的就是 Firebase uid，
    /// 兩邊共用同一把鍵，不需要新增欄位）。
    ///
    /// 保守處理「成員退出」：家庭裡已不存在的遠端成員，本機紀錄不自動刪除——刪除是破壞性操作，
    /// 且目前後端沒有明確的「已退出」語意（只是 memberUids 陣列裡少了這個 uid，也可能只是
    /// 暫時性的讀取或該筆成員文件還沒建立完成），貿然清掉本機資料(包含其固定圈設定)風險更大。
    func refreshFamilyMembers(context: ModelContext) async {
        guard let familyID = currentFamilyID, let selfUID = uid else { return }
        do {
            let family = try await FirestoreFamilyBackend.fetchFamily(familyId: familyID)
            await applyFamily(family)

            let remoteMembers = try await FirestoreFamilyBackend.fetchMembers(familyId: familyID)
            var localMembers = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
            var changed = false

            for remote in remoteMembers where remote.id != selfUID {
                let name = resolvedName(remote.displayName, forUid: remote.id)
                if let existing = localMembers.first(where: { $0.sharedIdentityKey == remote.id }) {
                    if existing.name != name {
                        existing.name = name
                        changed = true
                    }
                } else {
                    let member = LocalFamilyMember(name: name, relationship: "家庭成員")
                    member.sharedIdentityKey = remote.id
                    context.insert(member)
                    localMembers.append(member)
                    changed = true
                }
            }
            if changed { context.saveReporting() }

            await notifyNewMembers(remoteMembers, selfUID: selfUID)
        } catch {
            AppLog.cloud.error("刷新家庭成員清單失敗：\(error.localizedDescription)")
        }
    }

    /// A3：跟上次同步已知的成員 uid 比對，非首次同步時出現的新 uid → 發本機通知慶祝。
    /// 首次同步（鍵不存在）只登記、不通知，避免剛加入一個既有大家庭就被歷史成員洗版。
    private func notifyNewMembers(_ remoteMembers: [FamilyMemberDoc], selfUID: String) async {
        let defaults = UserDefaults.standard
        let key = SettingsKeys.knownFamilyMemberUids
        let previouslyKnown = defaults.stringArray(forKey: key)
        let isFirstSync = previouslyKnown == nil
        var knownSet = Set(previouslyKnown ?? [])

        if !isFirstSync {
            let newcomers = remoteMembers.filter { $0.id != selfUID && !knownSet.contains($0.id) }
            for member in newcomers {
                let displayName = resolvedName(member.displayName, forUid: member.id)
                // interruptionLevel 用 active（timeSensitive 預設 false）：這不是災害警報，
                // 不該突破勿擾模式。
                await NotificationScheduler.scheduleAlert(
                    title: "\(displayName) 已加入你的家庭圈 🎉",
                    body: "你們現在可以互相回報平安了。",
                    id: "member-joined-\(member.id)",
                    kind: "家庭成員加入"
                )
            }
        }
        knownSet.formUnion(remoteMembers.map(\.id))
        defaults.set(Array(knownSet), forKey: key)
    }

    // MARK: - 家庭即時圈

    /// 把這台手機最新的位置寫進家庭圈的 locations 子集合。
    /// 節流（UploadThrottle）：距離上次成功上傳不到 30 秒、且位移沒超過 200 公尺的更新會合併，避免寫入風暴；
    /// `force` 用於進出守護地點、家人要求更新位置這類「必須立刻送」的情境。
    ///
    /// 心跳：LocationService 每 5 分鐘會送來一筆新定位（即使沒移動），這裡照常寫入，
    /// 讓 updatedAt（最後回報時間）持續刷新；30 秒去抖不會擋到 5 分鐘一次的心跳。
    /// 沒移動（距離停留錨點 < 100 公尺）時寫回錨點座標並沿用 stationarySince，
    /// 家人看到的是「同一地點 N 分鐘・M 分鐘前確認」，而不是 GPS 抖動造成的假移動。
    ///
    /// 回傳 true＝這筆位置已確認送達（或 30 秒內重複而合併）；false＝沒送出，原因會寫進
    /// [liveLocationError]（不再靜默吞掉），呼叫端與心跳排程會在下一輪自動重試。
    @discardableResult
    func publishLiveLocation(
        _ location: CLLocation,
        displayName: String,
        radiusMeters: Int,
        context: ModelContext,
        force: Bool = false
    ) async -> Bool {
        guard AuthService.shared.isSignedIn, let uid else {
            liveLocationError = "請先用 Apple 帳號登入，才能把即時位置分享給家人"
            return false
        }
        // 名字沒設不再擋上傳（位置分享不該被名字綁架），也**不能**退回本機「我」成員的名字——
        // 那正是「我」被上傳到雲端的根因。沒有真名就送空字串（publishLocation 會刪欄位），
        // 家人端顯示「家人 N」。
        var trimmedName = FamilyNaming.clean(displayName)
        if trimmedName.isEmpty { trimmedName = FamilyNaming.ownUploadName() }
        // 過舊（> 2 分鐘）或精度太差（> 1000 公尺）的定位不上傳，但要讓使用者看到原因而不是無聲略過：
        // 先前門檻 500 公尺，剛開 GPS 的第一筆常是基地台定位（數百至上千公尺），被默默丟掉後
        // 要等移動 100 公尺才會有下一筆，畫面就一直卡在「等待第一次位置更新」。
        let locationAge = max(0, -location.timestamp.timeIntervalSinceNow)
        guard locationAge <= 120,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000 else {
            if lastPublishedAt == nil {
                liveLocationError = "定位訊號還不夠準，正在重新取得位置…"
            }
            return false
        }
        if !force, let lastPublishedLocation, let lastPublishedAt, lastPublishedRadius == radiusMeters {
            let previous = LocationSample(
                time: lastPublishedAt,
                latitude: lastPublishedLocation.coordinate.latitude,
                longitude: lastPublishedLocation.coordinate.longitude
            )
            if !UploadThrottle.shouldUpload(previous: previous, current: LocationSample(time: .now, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)) {
                return true
            }
        }
        guard !liveLocationPublishInFlight else { return false }
        liveLocationPublishInFlight = true
        defer { liveLocationPublishInFlight = false }

        do {
            let familyID = try await ensureFamily()
            let localCircles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
            // 行政區由座標解析（離線邊界優先、CLGeocoder 備援、每移動 500 公尺才重查）；
            // 解析不到才退回本機跟隨圈已有的值，仍沒有就留空——絕不上傳「未指定」字樣。
            let localDistrict = localCircles.first {
                $0.isFollowMe && $0.member?.isCurrentUser == true
            }?.district
            let resolvedDistrict = await DistrictResolver.shared.resolve(location)
            let district: String = resolvedDistrict
                ?? localDistrict.flatMap { $0 == Districts.unspecified ? nil : $0 }
                ?? ""

            // 停留錨點：優先用本次執行期間記住的；App 被系統重啟後記憶體清空，
            // 退回家庭圈上自己那筆（雲端真相），避免每次重啟都把「停留時間」歸零。
            let previousAnchor: CLLocation?
            let previousStationarySince: Date?
            let previousMovedAt: Date?
            if let lastPublishedLocation {
                previousAnchor = lastPublishedLocation
                previousStationarySince = lastStationarySince
                previousMovedAt = lastMovedAt
            } else if let own = ownLiveLocation {
                previousAnchor = CLLocation(latitude: own.latitude, longitude: own.longitude)
                previousStationarySince = own.stationarySince
                previousMovedAt = own.movedAt
            } else {
                previousAnchor = nil
                previousStationarySince = nil
                previousMovedAt = nil
            }
            let movedMeters = previousAnchor.map { location.distance(from: $0) }
            // 移動判定：位移 > max(定位精度, 50 公尺)、速度不是明確低速、連續 2 筆才確認（GPS 漂移不算移動）
            var confirmedMoved: Bool?
            if let movedMeters {
                let result = MovementJudge.advance(
                    isMovedSample: MovementJudge.isMovedSample(
                        displacement: movedMeters, accuracy: location.horizontalAccuracy, speed: location.speed
                    ),
                    displacement: movedMeters, accuracy: location.horizontalAccuracy, streak: movedStreak
                )
                movedStreak = result.streak
                confirmedMoved = result.confirmed
            } else {
                movedStreak = 0
            }
            let stationarySince = LiveLocationPresence.stationarySince(
                previousStationarySince: previousStationarySince, moved: confirmedMoved
            )
            // 「移動中」的證據：只有確認移動才刷新；沒有可比較的上次紀錄（剛開始分享、重啟）沿用舊值，不當成移動
            let movedAt: Date? = confirmedMoved == true ? .now : previousMovedAt
            // 沒移動（含尚未確認的漂移）：寫回錨點座標（同座標、新的 updatedAt）；確認移動：錨點換成新位置
            let anchor = (confirmedMoved == false ? previousAnchor : nil) ?? location

            // 24 小時軌跡：移動 30 公尺以上或距上一點 10 分鐘就追加一點（靜止時不必每次心跳都加）
            let trailSample = LocationSample(
                time: location.timestamp, latitude: anchor.coordinate.latitude, longitude: anchor.coordinate.longitude
            )
            let trailInput: FirestoreFamilyBackend.TrailPointInput? =
                TrailPolicy.shouldAppendPoint(previous: lastTrailSample, current: trailSample)
                ? .init(
                    latitude: trailSample.latitude, longitude: trailSample.longitude,
                    accuracy: location.horizontalAccuracy, time: location.timestamp
                ) : nil
            // 目前所在的守護地點（地理圍欄判斷；不在任何守護地點內為 nil）
            let place = LocationService.shared.currentPlace
            // 隱私與救援的取捨：寫入原始座標，不加雜訊模糊化——這是家人要據以趕去救人的位置。
            // 降低暴露改用其他手段：擷取端 ~100m 精度、預設關閉且可隨時停止、Security Rules 限同家庭可讀。
            try await FirestoreFamilyBackend.publishLocation(
                familyId: familyID,
                uid: uid,
                displayName: trimmedName,
                latitude: anchor.coordinate.latitude,
                longitude: anchor.coordinate.longitude,
                radiusMeters: max(300, min(radiusMeters, 5_000)),
                district: district,
                stationarySince: stationarySince,
                movedAt: movedAt,
                placeName: place?.name,
                placeSince: place?.since,
                trailPoint: trailInput
            )
            if let trailInput {
                lastTrailSample = LocationSample(
                    time: trailInput.time, latitude: trailInput.latitude, longitude: trailInput.longitude
                )
            }
            pruneTrailIfDue(familyID: familyID, uid: uid)
            lastPublishedLocation = anchor
            lastStationarySince = stationarySince
            lastMovedAt = movedAt
            lastPublishedAt = .now
            lastPublishedRadius = radiusMeters
            liveLocationError = nil
            state = .sharing
            // 告訴定位服務「這次確實送達」：心跳計時只認成功上傳，失敗時下一輪（15 秒內）就重試
            LocationService.shared.noteLiveLocationDelivered()
            // 先把剛送出的位置投影到本機（本人的圈與「分享中・剛剛更新」立刻出現），
            // 不必等下面這次完整讀取往返；讀取失敗也不會讓畫面卡在「等待」。
            projectOwnPublishedLocation(
                uid: uid, name: trimmedName, anchor: anchor, radiusMeters: radiusMeters,
                district: district, stationarySince: stationarySince, movedAt: movedAt,
                placeName: place?.name, placeSince: place?.since, context: context
            )
            await fetchLiveLocations(context: context)
            return true
        } catch {
            liveLocationError = "即時位置同步失敗：\(error.localizedDescription)"
            AppLog.cloud.error("即時位置同步失敗：\(error.localizedDescription)")
            return false
        }
    }

    /// 上傳成功後順手刪自己超過 24 小時的軌跡點（批次、一次最多 50 筆；至少間隔 10 分鐘才查一次，
    /// 避免每次上傳都多一次讀取）。失敗只記錄，下次到期再試。
    private func pruneTrailIfDue(familyID: String, uid: String) {
        guard TrailPolicy.shouldCleanup(lastCleanupAt: lastTrailCleanupAt) else { return }
        lastTrailCleanupAt = .now
        Task {
            do {
                try await FirestoreFamilyBackend.pruneOwnTrail(familyId: familyID, uid: uid)
                try await FirestoreFamilyBackend.pruneOwnArrivals(
                    familyId: familyID, uid: uid, olderThan: TrailPolicy.cutoff()
                )
            } catch {
                AppLog.cloud.error("清理過期軌跡失敗：\(error.localizedDescription)")
            }
        }
    }

    /// 讀某位家人 24 小時內的軌跡（含自己）
    func fetchTrail(forUid targetUid: String) async -> [TrailPoint] {
        guard let familyID = currentFamilyID else { return [] }
        do {
            return try await FirestoreFamilyBackend.fetchTrail(familyId: familyID, uid: targetUid)
        } catch {
            AppLog.cloud.error("讀取軌跡失敗：\(error.localizedDescription)")
            return []
        }
    }

    /// 讀 24 小時內某位家人的到達／離開事件（含 visit）
    func fetchArrivalHistory(forUid targetUid: String) async -> [ArrivalEvent] {
        guard let familyID = currentFamilyID else { return [] }
        do {
            let events = try await FirestoreFamilyBackend.fetchArrivals(
                familyId: familyID, since: TrailPolicy.cutoff()
            )
            return events.filter { $0.uid == targetUid }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            AppLog.cloud.error("讀取到達/離開事件失敗：\(error.localizedDescription)")
            return []
        }
    }

    /// 上傳成功後立刻把本人那筆放進 liveLocations 並投影成本機即時圈（樂觀更新，之後由讀取校正）。
    private func projectOwnPublishedLocation(
        uid: String, name: String, anchor: CLLocation, radiusMeters: Int,
        district: String, stationarySince: Date, movedAt: Date?,
        placeName: String?, placeSince: Date?, context: ModelContext
    ) {
        let own = FamilyLiveLocation(
            id: uid,
            participantID: uid,
            displayName: name,
            latitude: anchor.coordinate.latitude,
            longitude: anchor.coordinate.longitude,
            radiusMeters: max(300, min(radiusMeters, 5_000)),
            district: district.isEmpty ? Districts.unspecified : district,
            updatedAt: .now,
            stationarySince: stationarySince,
            movedAt: movedAt,
            placeName: placeName,
            placeSince: placeSince,
            isSharing: true
        )
        var updated = liveLocations.filter { $0.id != uid }
        updated.append(own)
        liveLocations = resolvedLocations(updated)
        if applyLiveLocationSnapshots(liveLocations, context: context) {
            context.saveReporting()
        }
    }

    /// 開啟本機位置分享的全套動作（B3-2）：LiveCircleSharingSection 的手動開關與
    /// PostJoinActivationView 的入圈後激活頁共用同一份實作，不要各寫一份——
    /// 要權限、寫入啟用旗標（給 App 啟動時的監聽判斷讀）、開始監聽、發布一次目前座標。
    /// 呼叫端若在意「iCloud／登入尚未就緒」（見 LiveCircleSharingSection.iCloudUnavailable）
    /// 要自己先擋，這裡不重複判斷——入圈後的激活頁在呼叫這裡之前必然已登入（joinFamily 前提）。
    func enableLiveLocationSharing(radiusMeters: Int, context: ModelContext) async {
        UserDefaults.standard.set(true, forKey: SettingsKeys.liveLocationSharingEnabled)
        liveLocationError = nil
        LocationService.shared.requestAlwaysPermission()
        LocationService.shared.syncLiveLocationSharing(isEnabled: true)
        // 權限對話框還沒按完時 currentLocation() 會立刻回 nil（舊版就是在這裡默默 return，
        // 之後只能靠使用者移動 100 公尺才有下一筆）。先等使用者做完授權決定再取位。
        let authorized = await LocationService.shared.waitForAuthorizationDecision()
        guard authorized else {
            liveLocationError = "沒有定位權限：請到 iOS 設定 > 隱私權 > 定位服務 > 安心圈，允許「使用 App 期間」或「永遠」"
            return
        }
        GeofenceSync.sync(context: context)
        startLocationRequestListener()
        // 最多嘗試 3 次（取位逾時 8 秒＋短暫間隔），整體約 10 秒內完成第一次上傳
        for attempt in 0..<3 {
            if let location = await LocationService.shared.currentLocation(),
               await publishLiveLocation(
                location,
                displayName: displayName,
                radiusMeters: radiusMeters,
                context: context
               ) {
                return
            }
            if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
        }
        if liveLocationError == nil {
            liveLocationError = "暫時取不到目前位置，會在背景持續重試"
        }
    }

    /// 警戒範圍可選值（公尺）：設定→提醒設定的選項，也是唯一調整警戒半徑的地方
    /// （地圖上不再能拖圈或開滑桿）。
    static let alertRadiusOptions = [500, 1_000, 2_000, 3_000, 5_000]

    /// 套用新的警戒範圍：寫入既有的半徑欄位（liveCircleRadiusMeters 與本人所有即時圈的 radiusMeters），
    /// 立即讓地圖圈與警報判斷（AlertPolicy 讀 circle.radiusMeters、FCM 行政區訂閱）吃到新值；
    /// 分享中則重新上傳一次，讓家人看到的圈也同步變大變小。
    func applyAlertRadius(_ meters: Int, context: ModelContext) async {
        UserDefaults.standard.set(meters, forKey: SettingsKeys.liveCircleRadiusMeters)
        let circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        var changed = false
        for circle in circles where circle.member?.isCurrentUser == true
            && (circle.isFollowMe || circle.kind == .live) && circle.radiusMeters != meters {
            circle.radiusMeters = meters
            changed = true
        }
        if changed { context.saveReporting() }
        FCMTopicSync.sync(circles: circles)
        if changed { await EventPipeline.refresh(context: context) }
        if UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
           let location = await LocationService.shared.currentLocation() {
            await publishLiveLocation(location, displayName: displayName, radiusMeters: meters, context: context)
        }
        Analytics.track("circle_adjusted") // 漏斗：調整了警戒範圍
    }

    /// 停止分享：標記雲端記錄停用，並清掉本機自己的即時圈。
    func stopLiveLocationSharing(context: ModelContext) async {
        let localCircles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        for circle in localCircles where circle.kind == .live && circle.member?.isCurrentUser == true {
            context.delete(circle)
        }
        context.saveReporting()
        await EventPipeline.refresh(context: context)

        lastPublishedLocation = nil
        lastPublishedAt = nil
        lastPublishedRadius = nil
        lastStationarySince = nil
        lastMovedAt = nil
        movedStreak = 0
        lastTrailSample = nil
        lastTrailCleanupAt = nil
        liveLocationError = nil
        stopLocationRequestListener()

        guard let uid, let familyID = currentFamilyID else { return }
        do {
            try await FirestoreFamilyBackend.stopLocation(familyId: familyID, uid: uid)
            await fetchLiveLocations(context: context)
        } catch {
            AppLog.cloud.error("停止即時位置分享失敗：\(error.localizedDescription)")
        }
    }

    /// 讀取家庭圈所有成員位置，並投影成本機 SwiftData 即時圈。
    func fetchLiveLocations(context: ModelContext) async {
        guard let familyID = currentFamilyID else { return }
        do {
            let locations = try await FirestoreFamilyBackend.fetchLocations(familyId: familyID)
            // 先記下 uid 清單再解析名字（fallbackName 在 memberUids 未載入時要靠它）
            // 先暫存 uid 清單再解析名字（fallbackName 在 memberUids 未載入時要靠它）；
            // 效能：@Observable 屬性每次賦值都會通知觀察者（即使值相同），所以只在真的有變時才寫入，
            // 也不再先寫一次原始值再寫一次解析後的值（以前每 20 秒輪詢最少觸發兩次整頁重繪）
            if liveLocations.isEmpty { liveLocations = locations }
            let resolved = resolvedLocations(locations)
            if resolved != liveLocations { liveLocations = resolved }
            let changed = applyLiveLocationSnapshots(resolved, context: context)
            if changed {
                context.saveReporting()
                // 家人位置變了不代表事件資料變了：管線刷新要打 7 個網路來源。
                // 只有圈新增／刪除或位移 > 200 公尺才在 30 秒限流下重跑，其餘（心跳、小幅位移）至少隔 5 分鐘；
                // 事件資料本身另有 5 分鐘定時與回前景刷新
                await EventPipeline.refresh(context: context, minInterval: lastProjectionSignificant ? 30 : 300)
            }
        } catch {
            AppLog.cloud.error("讀取即時位置失敗：\(error.localizedDescription)")
        }
    }

    /// 把家人即時位置投影成本機 SwiftData 即時圈，讓警報比對／地圖／摘要共用同一套圈資料。
    /// 上一次投影是否有「值得重跑警報比對」的變動：圈新增／刪除、或圈心位移 > 200 公尺、半徑改變。
    /// 只有心跳（updatedAt 刷新）或小幅位移不算——它們不會改變任何事件與圈的命中關係。
    private var lastProjectionSignificant = false

    private func applyLiveLocationSnapshots(
        _ locations: [FamilyLiveLocation],
        context: ModelContext
    ) -> Bool {
        lastProjectionSignificant = false
        let selfUID = uid ?? ""
        var members = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
        var circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        let activeLocations = locations.filter(\.isSharing)
        let activeIDs = Set(activeLocations.map(\.id))
        var changed = false

        for circle in circles where circle.sharedLocationID != nil {
            guard let sourceID = circle.sharedLocationID, !activeIDs.contains(sourceID) else { continue }
            context.delete(circle)
            changed = true
            lastProjectionSignificant = true
        }

        for location in activeLocations {
            let member: LocalFamilyMember
            if let matched = members.first(where: { $0.sharedIdentityKey == location.participantID }) {
                member = matched
            } else if location.participantID == selfUID,
                      let current = members.first(where: \.isCurrentUser) {
                member = current
                member.sharedIdentityKey = location.participantID
            } else if let named = members.first(where: {
                !$0.isPlace && $0.sharedIdentityKey == nil && $0.name == location.displayName
            }) {
                member = named
                member.sharedIdentityKey = location.participantID
            } else {
                member = LocalFamilyMember(name: location.displayName, relationship: "家庭成員")
                member.sharedIdentityKey = location.participantID
                context.insert(member)
                members.append(member)
                changed = true
            }

            let circle: LocalLifeCircle
            if let existing = circles.first(where: { $0.sharedLocationID == location.id }) {
                circle = existing
            } else if location.participantID == selfUID,
                      let ownLive = member.lifeCircles.first(where: \.isFollowMe) {
                circle = ownLive
                circle.sharedLocationID = location.id
            } else {
                circle = LocalLifeCircle(
                    circleKey: "shared-\(location.id)",
                    name: location.participantID == selfUID
                        ? "我的即時圈"
                        : "\(location.displayName)的即時圈",
                    encryptedAddress: "位置由家人手機共享",
                    latitude: location.latitude,
                    longitude: location.longitude,
                    radiusMeters: location.radiusMeters,
                    alertTypes: EventCategory.defaultSelection,
                    member: member
                )
                context.insert(circle)
                circles.append(circle)
                changed = true
                lastProjectionSignificant = true
            }

            if circle.radiusMeters != location.radiusMeters
                || CLLocation(latitude: circle.latitude, longitude: circle.longitude)
                    .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude)) > 200 {
                lastProjectionSignificant = true
            }
            if circle.latitude != location.latitude
                || circle.longitude != location.longitude
                || circle.radiusMeters != location.radiusMeters
                || circle.locationUpdatedAt != location.updatedAt
                || circle.locationStationarySince != location.stationarySince
                || circle.locationMovedAt != location.movedAt
                || circle.locationPlaceName != location.placeName
                || circle.locationPlaceSince != location.placeSince
                || circle.district != location.district {
                circle.locationPlaceName = location.placeName
                circle.locationPlaceSince = location.placeSince
                circle.latitude = location.latitude
                circle.longitude = location.longitude
                circle.radiusMeters = location.radiusMeters
                circle.locationUpdatedAt = location.updatedAt
                circle.locationStationarySince = location.stationarySince
                circle.locationMovedAt = location.movedAt
                circle.district = location.district
                changed = true
            }
            let isOwnLocation = location.participantID == selfUID
            if circle.kind != .live
                || circle.sharedLocationID != location.id
                || circle.isFollowMe != isOwnLocation
                || circle.encryptedAddress != "位置由家人手機共享"
                || circle.member !== member {
                changed = true
            }
            // 值相同就不寫：SwiftData 模型的 setter 即使賦同值也會標記為已變更並通知 @Query／觀察者
            if circle.kind != .live { circle.kind = .live }
            if circle.isFollowMe != isOwnLocation { circle.isFollowMe = isOwnLocation }
            if circle.sharedLocationID != location.id { circle.sharedLocationID = location.id }
            if circle.encryptedAddress != "位置由家人手機共享" { circle.encryptedAddress = "位置由家人手機共享" }
            if circle.member !== member { circle.member = member }
        }
        return changed
    }

    // MARK: - 守護地點到達／離開、拜訪

    /// 家人 App 在前景時讀到的新到達／離開事件，UI 顯示成頂端橫幅（橫幅自己 5 秒後淡出）
    private(set) var arrivalBanners: [ArrivalEvent] = []
    /// 事件列表（成員詳情的「到達／離開」用）會自己查，這裡只負責橫幅

    func dismissArrivalBanner(_ id: String) {
        arrivalBanners.removeAll { $0.id == id }
    }

    private var arrivalLastSeenKey: String { "hc.arrivals.lastSeen.\(currentFamilyID ?? "")" }

    /// 自己手機進出守護地點：立刻補傳位置（force，帶上最新所在地點）並寫一筆事件。
    /// 位置分享沒開就什麼都不做（事件本身就是位置資訊，必須同樣 opt-in）。
    func handleRegionTransition(_ transition: RegionTransition, context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled) else { return }
        await withBackgroundTask(name: "region-transition") {
            await self.uploadLocationNow(context: context)
            await self.recordArrival(
                kind: transition.kind, source: .region, placeName: transition.placeName,
                at: transition.date
            )
        }
    }

    /// CLVisit：到達／離開某處。有對應守護地點就用它的名字，否則寫「某處」（不存座標、不反查地址）
    func handleVisit(_ visit: VisitTransition, context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled) else { return }
        await withBackgroundTask(name: "visit") {
            await self.uploadLocationNow(context: context)
            await self.recordArrival(
                kind: visit.kind, source: .visit,
                placeName: LocationService.shared.currentPlace?.name ?? "",
                at: visit.date
            )
        }
    }

    /// 取一筆新定位並立即上傳（不受節流限制）。回傳是否上傳成功
    @discardableResult
    func uploadLocationNow(context: ModelContext) async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
              let location = await LocationService.shared.currentLocation() else { return false }
        let storedRadius = defaults.integer(forKey: SettingsKeys.liveCircleRadiusMeters)
        return await publishLiveLocation(
            location,
            displayName: FamilyNaming.ownUploadName(defaults: defaults),
            radiusMeters: storedRadius > 0 ? storedRadius : 1_000,
            context: context,
            force: true
        )
    }

    private func recordArrival(
        kind: ArrivalEvent.Kind, source: ArrivalEvent.Source, placeName: String, at date: Date
    ) async {
        guard AuthService.shared.isSignedIn, let uid, let familyID = currentFamilyID else { return }
        let name = displayName
        do {
            try await FirestoreFamilyBackend.postArrival(
                familyId: familyID, uid: uid, name: name,
                kind: kind, source: source, placeName: placeName, at: date
            )
        } catch {
            AppLog.cloud.error("寫入到達/離開事件失敗：\(error.localizedDescription)")
        }
    }

    /// 讀取家人新的到達／離開事件。前景時變成頂端橫幅；非前景（例如被推播喚醒）改發本機通知。
    /// 第一次讀（沒有 lastSeen）只記時間、不補發，避免剛加入就收到一堆舊事件。
    func pollArrivals() async {
        guard let familyID = currentFamilyID else { return }
        let defaults = UserDefaults.standard
        let key = arrivalLastSeenKey
        let now = Date.now
        guard let lastSeen = defaults.object(forKey: key) as? Date else {
            defaults.set(now, forKey: key)
            return
        }
        do {
            let events = try await FirestoreFamilyBackend.fetchArrivals(familyId: familyID, since: lastSeen)
            guard let newest = events.map(\.createdAt).max() else { return }
            defaults.set(max(newest, lastSeen), forKey: key)
            // 事件裡沒名字的人補「家人 N」（名字不上傳佔位字，顯示端補）
            let named = events.map { event in
                event.name.isEmpty ? event.withName(fallbackName(forUid: event.uid)) : event
            }
            let candidates = ArrivalPolicy.bannerCandidates(named, selfUID: uid, lastSeen: lastSeen, now: now)
            guard !candidates.isEmpty else { return }
            if UIApplication.shared.applicationState == .active {
                arrivalBanners.append(contentsOf: candidates)
            } else {
                for event in candidates { await NotificationScheduler.notifyArrival(event) }
            }
        } catch {
            AppLog.cloud.error("讀取到達/離開事件失敗：\(error.localizedDescription)")
        }
    }

    /// 背景短任務：區域／拜訪喚醒只有約 10 秒，向系統多要時間讓上傳與寫事件做完
    private func withBackgroundTask(name: String, _ work: @escaping () async -> Void) async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        await work()
        if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
    }

    // MARK: - 家人主動「更新位置」

    private var requestListener: ListenerRegistration?
    private var isAnsweringRequest = false
    /// 這台手機最近一次對各家人送出請求的時間（冷卻用，只在記憶體）
    private var lastRequestSentAt: [String: Date] = [:]
    private static let lastRequestHandledKey = "hc.locationRequest.lastHandled"

    enum LocationRequestOutcome: Equatable {
        case sent
        case cooldown(seconds: Int)
        case failed(String)
    }

    /// 請某位家人的手機立刻回報位置。對方沒開分享就不會回應（尊重 opt-in），
    /// 這個請求只是「請你現在更新一次」，不會讓對方的手機偷偷開始分享。
    func requestLocationUpdate(forUid targetUid: String, requesterName: String) async -> LocationRequestOutcome {
        guard AuthService.shared.isSignedIn, let uid, let familyID = currentFamilyID else {
            return .failed("請先登入並加入家庭圈")
        }
        let remaining = LocationRequestPolicy.cooldownRemaining(lastRequestAt: lastRequestSentAt[targetUid])
        if remaining > 0 { return .cooldown(seconds: Int(remaining.rounded(.up))) }
        do {
            try await FirestoreFamilyBackend.requestLocationUpdate(
                familyId: familyID, targetUid: targetUid, requesterUid: uid,
                requesterName: FamilyNaming.clean(requesterName)
            )
            lastRequestSentAt[targetUid] = .now
            return .sent
        } catch {
            AppLog.cloud.error("送出更新位置請求失敗：\(error.localizedDescription)")
            return .failed("請求沒有送出，請確認網路後再試一次")
        }
    }

    /// 開始監聽發給自己的請求（位置分享開啟、已登入且在家庭圈時）。重複呼叫會先移除舊的監聽。
    func startLocationRequestListener() {
        requestListener?.remove()
        requestListener = nil
        guard UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
              AuthService.shared.isSignedIn, let uid, let familyID = currentFamilyID else { return }
        requestListener = FirestoreFamilyBackend.listenLocationRequest(familyId: familyID, uid: uid) { requestedAt in
            Task { @MainActor in
                guard let context = AppRuntime.container?.mainContext else { return }
                await AppRuntime.familySync?.answerLocationRequest(requestedAt: requestedAt, context: context)
            }
        }
    }

    func stopLocationRequestListener() {
        requestListener?.remove()
        requestListener = nil
    }

    /// 前景輪詢／推播喚醒時主動查一次有沒有請求（監聽失效時的保底）
    func checkLocationRequest(context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled),
              AuthService.shared.isSignedIn, let uid, let familyID = currentFamilyID else { return }
        guard let requestedAt = try? await FirestoreFamilyBackend.fetchLocationRequest(familyId: familyID, uid: uid) else { return }
        await answerLocationRequest(requestedAt: requestedAt, context: context)
    }

    /// 回應請求：立即定位並上傳（force），成功後刪掉請求。
    /// 位置分享沒開就完全不回應；過期（> 10 分鐘）或已處理過的請求略過。
    func answerLocationRequest(requestedAt: Date, context: ModelContext) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.liveLocationSharingEnabled), !isAnsweringRequest,
              let uid, let familyID = currentFamilyID else { return }
        let lastHandled = defaults.object(forKey: Self.lastRequestHandledKey) as? Date
        guard LocationRequestPolicy.shouldAnswer(requestedAt: requestedAt, lastHandledAt: lastHandled) else {
            return
        }
        isAnsweringRequest = true
        defer { isAnsweringRequest = false }
        await withBackgroundTask(name: "location-request") {
            if await self.uploadLocationNow(context: context) {
                defaults.set(requestedAt, forKey: Self.lastRequestHandledKey)
                await FirestoreFamilyBackend.clearLocationRequest(familyId: familyID, uid: uid)
            }
        }
    }

    // MARK: - 安否回報

    /// 送出一則安否回報。位置為回報者「自願附上」的一次性座標（nil＝沒附）。
    ///
    /// 回傳成敗（保命級 P0 修復）：舊版未登入時只默默設 state 就 return、
    /// 呼叫端（EventDetailView／NotificationDelegate／SafetyCheckInView）完全拿不到結果，
    /// 導致未登入或失敗時 UI 仍無條件顯示「已送出」的假成功。選 `Bool` 而非 `throws`：
    /// 三個呼叫端都只需要「成功了嗎」的是非題去決定要不要顯示回饋，不需要區分錯誤型別
    /// （人話文案已在下面就地轉換好、經由 [state] 帶出），throws 只會讓呼叫端多包一層
    /// do/catch 卻沒有額外資訊可用。
    @discardableResult
    func postPing(
        senderName: String,
        status: SafetyStatus,
        note: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        placeName: String? = nil
    ) async -> Bool {
        guard let uid else {
            state = .error("請先用 Apple 帳號登入，才能回報平安給家人")
            return false
        }
        do {
            let familyID = try await ensureFamily()
            _ = try await FirestoreFamilyBackend.postPing(
                familyId: familyID,
                senderUid: uid,
                senderName: FamilyNaming.clean(senderName),
                status: status,
                note: note,
                latitude: latitude,
                longitude: longitude,
                placeName: placeName
            )
            await fetchPings()
            return true
        } catch {
            AppLog.cloud.error("送出安否回報失敗：\(error.localizedDescription)")
            state = .error(Self.humanPingErrorMessage(error))
            return false
        }
    }

    /// 安否回報失敗的人話文案（統一錯誤文案原則）：逾時的真相是「不確定送沒送出」——
    /// Firestore 離線佇列可能事後補送成功，一律用「可能未送出」＋教使用者怎麼自行確認，
    /// 不寫「已失敗」也不假裝成功。原始錯誤已在上一行進 AppLog，這裡只轉譯給使用者看的字串。
    private static func humanPingErrorMessage(_ error: Error) -> String {
        if error is SafetyPingTimeoutError {
            return "網路不穩，回報可能未送出——連上網路後會自動重試，家人清單出現你的回報才算成功"
        }
        return "回報失敗，請再試一次"
    }

    /// 讀取家庭圈所有安否回報（依時間新到舊），並對新回報發本機通知。
    func fetchPings() async {
        guard let familyID = currentFamilyID else { return }
        do {
            // 回報者沒名字時補「家人 N」（自己的回報顯示「我」）
            pings = try await FirestoreFamilyBackend.fetchPings(familyId: familyID).map { ping in
                var resolved = ping
                if ping.senderName.isEmpty {
                    resolved = SafetyPing(
                        id: ping.id,
                        senderName: ping.senderUid.isEmpty ? "家人" : resolvedName("", forUid: ping.senderUid),
                        senderUid: ping.senderUid, status: ping.status, note: ping.note,
                        createdAt: ping.createdAt, readBy: ping.readBy,
                        latitude: ping.latitude, longitude: ping.longitude, placeName: ping.placeName
                    )
                }
                return resolved
            }
            await notifyIncomingPings(pings)
        } catch {
            AppLog.cloud.error("讀取安否回報失敗：\(error.localizedDescription)")
        }
    }

    /// 家人回報通知：抓到「別人新送出」的回報時發本機通知。
    /// 已看過的回報 ID 存本機（上限 300）；首次同步只登記不通知，避免剛加入就被歷史回報洗版。
    private func notifyIncomingPings(_ latest: [SafetyPing]) async {
        let defaults = UserDefaults.standard
        let seenKey = "seenSafetyPingIDs"
        let myName = defaults.string(forKey: SettingsKeys.profileDisplayName) ?? ""
        let myUid = uid ?? ""
        let previouslySeen = defaults.stringArray(forKey: seenKey)
        let isFirstSync = previouslySeen == nil
        var seenSet = Set(previouslySeen ?? [])
        var seenList = previouslySeen ?? []

        for ping in latest where !seenSet.contains(ping.id) {
            seenSet.insert(ping.id)
            seenList.append(ping.id)
            let isMine = (!myUid.isEmpty && ping.senderUid == myUid) || (!myName.isEmpty && ping.senderName == myName)
            guard !isFirstSync, !isMine else { continue }
            let (title, body): (String, String) = switch ping.status {
            case .safe:
                ("\(ping.senderName)已回報平安",
                 ping.note.isEmpty ? "已收到平安回報。" : ping.note)
            case .inDanger:
                ("\(ping.senderName)回報：尚未脫離危險",
                 (ping.note.isEmpty ? "" : "\(ping.note)。") + "請持續關注並保持聯繫。")
            case .needHelp:
                ("\(ping.senderName)回報：需要協助",
                 (ping.note.isEmpty ? "" : "\(ping.note)。") + "請立即聯繫確認狀況。")
            case .pleaseReport:
                ("\(ping.senderName)想確認你是否平安",
                 "收到警報後，\(ping.senderName)發起了平安確認；請開啟 App 回報你的狀態。")
            }
            let urgent = ping.status != .safe
            await NotificationScheduler.scheduleAlert(
                title: title, body: body, id: "ping-\(ping.id)",
                timeSensitive: urgent,
                kind: "家人安否" // 家人安否視同重大：吵醒門檻設「僅重大」或安靜時段內仍會吵醒
            )
        }

        if seenList.count > 300 { seenList.removeFirst(seenList.count - 300) }
        defaults.set(seenList, forKey: seenKey)
    }

    /// 標記某則回報為「我已讀」（已讀回條）
    func markRead(pingID: String, readerName: String) async {
        guard let familyID = currentFamilyID else { return }
        // 沒有真名就不寫已讀回條（寫空字串或佔位字都是髒資料）
        guard !FamilyNaming.clean(readerName).isEmpty else { return }
        do {
            try await FirestoreFamilyBackend.markPingRead(
                familyId: familyID,
                pingId: pingID,
                readerName: readerName
            )
            await fetchPings()
        } catch {
            AppLog.cloud.error("更新安否回報已讀狀態失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - 全家共用守護地點（families/{fid}/places/{placeId}）
    //
    // 一個守護地點＝「地點成員（kind=place）＋其下一個固定圈」。雲端 placeId 就是固定圈的 circleKey
    // （本機新建的用自己的 circleKey 上傳；別人建的用 placeId 當 circleKey 投影），
    // 並用 LocalLifeCircle.remotePlaceId 標記「已上雲／來自雲端」。
    // 沒有家庭時完全不碰雲端，維持純本機。

    /// 近期（60 秒內）本機剛寫過雲端的地點：避免輪詢拿到寫入前的舊快照，把剛改的內容蓋回去
    /// 或把剛上傳的地點誤判成「別人刪掉了」。
    private static let placeWriteGrace: TimeInterval = 60

    private var pendingPlaceDeleteKey: String { "hc.places.pendingDelete.\(currentFamilyID ?? "")" }

    private func placeDoc(from circle: LocalLifeCircle, createdBy: String) -> FirestoreFamilyBackend.PlaceDoc {
        // 名字以地點成員為準（與 GeofenceSync、家人頁列表一致）
        let name = circle.member?.isPlace == true ? (circle.member?.name ?? circle.name) : circle.name
        return FirestoreFamilyBackend.PlaceDoc(
            id: circle.circleKey,
            name: name,
            latitude: circle.latitude,
            longitude: circle.longitude,
            radiusMeters: circle.radiusMeters,
            addressText: circle.addressText,
            district: circle.district,
            createdBy: createdBy
        )
    }

    /// 本機新增／編輯守護地點後呼叫：已在家庭中才寫雲端（沒有家庭維持本機）。
    /// 失敗只記 log，不丟錯——地點仍在本機，下次 [syncPlaces] 會把「尚未上雲」的補傳。
    func pushPlace(_ circle: LocalLifeCircle, context: ModelContext) async {
        guard let familyID = currentFamilyID, let selfUID = uid,
              circle.kind == .fixed, circle.member?.isPlace == true,
              !(circle.latitude == 0 && circle.longitude == 0) else { return }
        let isCreate = circle.remotePlaceId == nil
        let doc = placeDoc(from: circle, createdBy: circle.createdByUid ?? selfUID)
        do {
            try await FirestoreFamilyBackend.upsertPlace(familyId: familyID, place: doc, isCreate: isCreate)
            circle.remotePlaceId = doc.id
            circle.createdByUid = doc.createdBy
            recentPlaceWrites[doc.id] = .now
            context.saveReporting()
        } catch {
            AppLog.cloud.error("寫入共用守護地點失敗：\(error.localizedDescription)")
        }
    }

    /// 使用者在本機刪除守護地點時呼叫（呼叫端須在刪除前先收集 remotePlaceId）。
    /// 失敗的 ID 記入待刪清單，下次 [syncPlaces] 重試；待刪期間不會被投影回本機。
    func deleteSharedPlaces(ids: [String]) async {
        guard let familyID = currentFamilyID, !ids.isEmpty else { return }
        let defaults = UserDefaults.standard
        let key = pendingPlaceDeleteKey
        var pending = Set(defaults.stringArray(forKey: key) ?? [])
        pending.formUnion(ids)
        defaults.set(Array(pending), forKey: key)
        for id in ids {
            do {
                try await FirestoreFamilyBackend.deletePlace(familyId: familyID, placeId: id)
                pending.remove(id)
            } catch {
                AppLog.cloud.error("刪除共用守護地點失敗（稍後重試）：\(error.localizedDescription)")
            }
        }
        defaults.set(Array(pending), forKey: key)
    }

    /// 家人頁「由 X 新增」用的建立者名稱：自己＝「你」；別人＝本機家人名字，查不到退回「家人 N」。
    func placeCreatorLabel(uid creatorUid: String, members: [LocalFamilyMember]) -> String {
        if creatorUid == uid { return "你" }
        if let name = members.first(where: { $0.sharedIdentityKey == creatorUid })?.name,
           !FamilyNaming.clean(name).isEmpty {
            return name
        }
        return fallbackName(forUid: creatorUid)
    }

    /// 雙向同步守護地點（App 啟動、回前景、前景每 20 秒輪詢都會呼叫）：
    /// ① 重試待刪的雲端地點 ② 遷移：把本機尚未上雲的固定圈上傳一次
    /// ③ 投影：雲端 → 本機（新增、更新、別人刪掉的從本機移除）
    /// 讀雲端失敗時整個中止，絕不因為「讀不到」而刪本機資料。
    func syncPlaces(context: ModelContext) async {
        guard let familyID = currentFamilyID, let selfUID = uid, !placesSyncInFlight else { return }
        placesSyncInFlight = true
        defer { placesSyncInFlight = false }
        do {
            let defaults = UserDefaults.standard
            let key = pendingPlaceDeleteKey
            var pending = Set(defaults.stringArray(forKey: key) ?? [])
            for id in pending {
                if (try? await FirestoreFamilyBackend.deletePlace(familyId: familyID, placeId: id)) != nil {
                    pending.remove(id)
                }
            }
            defaults.set(Array(pending), forKey: key)

            let remote = try await FirestoreFamilyBackend.fetchPlaces(familyId: familyID)
            var circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
            var changed = false
            var knownRemoteIDs = Set(remote.map(\.id))

            // 雲端去重：兩台裝置各自建了同名（< 150 公尺）的地點時，每組只保留 id 最小的一筆顯示
            let collapsed = PlaceDedup.collapse(remote.map {
                PlaceCandidate(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
            })
            let visibleRemote = remote.filter { collapsed.mapping[$0.id] == nil }

            // 本機若綁在被收掉的重複筆上：改綁保留的那筆；本機已有圈綁在保留筆上就直接刪掉多的這個。
            // 被收掉的雲端文件若是自己建的，順手刪除，讓雲端也收斂成一筆（別人建的留給他自己的裝置處理）。
            for circle in circles {
                guard let id = circle.remotePlaceId, let keeperID = collapsed.mapping[id] else { continue }
                if circles.contains(where: { $0 !== circle && $0.remotePlaceId == keeperID }) {
                    deleteProjectedPlace(circle, context: context)
                    circles.removeAll { $0 === circle }
                } else {
                    circle.remotePlaceId = keeperID
                    if let keeper = remote.first(where: { $0.id == keeperID }) { circle.createdByUid = keeper.createdBy }
                }
                changed = true
                if remote.first(where: { $0.id == id })?.createdBy == selfUID {
                    try? await FirestoreFamilyBackend.deletePlace(familyId: familyID, placeId: id)
                    knownRemoteIDs.remove(id)
                }
            }

            // ② 遷移／補傳：本機守護地點（地點成員下的固定圈）尚未上雲者上傳——
            // 但雲端已有同名且 < 150 公尺的地點時，改為綁定那筆而不新建
            var cloudCandidates = visibleRemote.map {
                PlaceCandidate(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
            }
            for circle in circles
            where circle.kind == .fixed && circle.member?.isPlace == true && circle.remotePlaceId == nil
                && !(circle.latitude == 0 && circle.longitude == 0) {
                let doc = placeDoc(from: circle, createdBy: selfUID)
                let mine = PlaceCandidate(id: doc.id, name: doc.name, latitude: doc.latitude, longitude: doc.longitude)
                let boundIDs = Set(circles.compactMap(\.remotePlaceId))
                if let existing = PlaceDedup.match(mine, in: cloudCandidates.filter { !boundIDs.contains($0.id) }) {
                    circle.remotePlaceId = existing.id
                    circle.createdByUid = remote.first { $0.id == existing.id }?.createdBy ?? circle.createdByUid
                    changed = true
                    continue
                }
                do {
                    try await FirestoreFamilyBackend.upsertPlace(familyId: familyID, place: doc, isCreate: true)
                    circle.remotePlaceId = doc.id
                    circle.createdByUid = selfUID
                    recentPlaceWrites[doc.id] = .now
                    knownRemoteIDs.insert(doc.id)
                    cloudCandidates.append(mine)
                    changed = true
                } catch {
                    AppLog.cloud.error("上傳本機守護地點失敗：\(error.localizedDescription)")
                }
            }

            // ③ 投影：雲端 → 本機
            let now = Date.now
            for place in visibleRemote where !pending.contains(place.id) {
                if let circle = circles.first(where: { $0.remotePlaceId == place.id }) {
                    if let wrote = recentPlaceWrites[place.id], now.timeIntervalSince(wrote) < Self.placeWriteGrace { continue }
                    if circle.name != place.name { circle.name = place.name; changed = true }
                    if let member = circle.member, member.isPlace, member.name != place.name {
                        member.name = place.name; changed = true
                    }
                    if circle.latitude != place.latitude { circle.latitude = place.latitude; changed = true }
                    if circle.longitude != place.longitude { circle.longitude = place.longitude; changed = true }
                    if circle.radiusMeters != place.radiusMeters { circle.radiusMeters = place.radiusMeters; changed = true }
                    if circle.district != place.district { circle.district = place.district; changed = true }
                    if circle.addressText != place.addressText { circle.setAddress(place.addressText); changed = true }
                    if circle.createdByUid != place.createdBy { circle.createdByUid = place.createdBy; changed = true }
                } else {
                    let member = LocalFamilyMember(name: place.name, relationship: "重要地點", kind: "place")
                    context.insert(member)
                    let circle = LocalLifeCircle(
                        circleKey: place.id,
                        name: place.name,
                        encryptedAddress: "",
                        latitude: place.latitude,
                        longitude: place.longitude,
                        radiusMeters: place.radiusMeters,
                        alertTypes: EventCategory.defaultSelection,
                        member: member
                    )
                    circle.setAddress(place.addressText)
                    circle.district = place.district
                    circle.kind = .fixed
                    circle.remotePlaceId = place.id
                    circle.createdByUid = place.createdBy
                    context.insert(circle)
                    changed = true
                }
            }

            // 別人（或別台裝置）刪掉的：本機有 remotePlaceId 但雲端已沒有 → 移除
            for circle in circles {
                guard let id = circle.remotePlaceId, !knownRemoteIDs.contains(id) else { continue }
                if let wrote = recentPlaceWrites[id], now.timeIntervalSince(wrote) < Self.placeWriteGrace { continue }
                deleteProjectedPlace(circle, context: context)
                changed = true
            }
            recentPlaceWrites = recentPlaceWrites.filter { now.timeIntervalSince($0.value) < Self.placeWriteGrace }

            if changed {
                context.saveReporting()
                GeofenceSync.sync(context: context)
                await EventPipeline.refresh(context: context, minInterval: 120)
            }
        } catch {
            AppLog.cloud.error("同步共用守護地點失敗：\(error.localizedDescription)")
        }
    }

    /// 刪除一個固定圈；它是地點成員唯一的圈時，連地點成員一起刪（避免留下 0 圈孤兒）
    private func deleteProjectedPlace(_ circle: LocalLifeCircle, context: ModelContext) {
        let circleID = circle.persistentModelID
        let member = circle.member
        let onlyCircle = member.map { $0.lifeCircles.allSatisfy { $0.persistentModelID == circleID } } ?? false
        context.delete(circle)
        if let member, member.isPlace, onlyCircle { context.delete(member) }
    }

    /// 離開／解散家庭圈時處理本機的共用地點：本人建立的保留成個人地點（清掉雲端標記，
    /// 之後加入別的家庭會再次上傳）；別人建立的不屬於我，從本機移除。
    private func detachSharedPlaces(context: ModelContext) {
        let circles = (try? context.fetch(FetchDescriptor<LocalLifeCircle>())) ?? []
        var changed = false
        for circle in circles where circle.remotePlaceId != nil {
            if circle.createdByUid == nil || circle.createdByUid == uid {
                circle.remotePlaceId = nil
                circle.createdByUid = nil
            } else {
                deleteProjectedPlace(circle, context: context)
            }
            changed = true
        }
        if changed {
            context.saveReporting()
            GeofenceSync.sync(context: context)
        }
    }

    // MARK: - 退出／解散家庭圈（帳號刪除流程／主動退出用）

    /// 退出（一般成員／圈主但還有其他成員）或解散（圈主且只剩自己一人）目前的家庭圈。
    ///
    /// 判斷依據：[isFamilyOwner] ＋ [memberUids]（雲端真相，同 [isSolo] 的判法）——
    /// 圈主且 memberUids 只剩自己一人時走解散（[FirestoreFamilyBackend.deleteFamily]，
    /// 對照 firestore.rules 允許圈主 delete 根文件那條）；其餘情況走一般退出
    /// （[FirestoreFamilyBackend.leaveFamily]，只把自己移出 memberUids）。
    ///
    /// Firestore 呼叫失敗會原樣往上拋，呼叫端（FamilyHomeView 的「退出家庭圈」按鈕）要接住
    /// 顯示人話錯誤，不能 silent fail；帳號整個刪除那條路徑（SettingsView.deleteEverything）
    /// 呼叫這裡時刻意用 `try?` 吞掉錯誤——那條路徑就算離線，本機清除仍要能完成，
    /// 不該被雲端呼叫失敗卡住。
    ///
    /// context 有給的話（一般由「退出家庭圈」按鈕呼叫），額外清掉同步而來的家人本機投影
    /// （見 [purgeSyncedFamilyProjection]），保留使用者手動新增的家人與所有其他本機資料——
    /// 這條路徑跟整個刪帳號不同，是「只離開這個家庭圈，其他本機資料保留」。
    func leaveFamily(context: ModelContext? = nil) async throws {
        if let uid, let familyID = currentFamilyID {
            if isFamilyOwner, memberUids.count <= 1 {
                try await FirestoreFamilyBackend.deleteFamily(familyId: familyID, uid: uid)
            } else {
                try await FirestoreFamilyBackend.leaveFamily(familyId: familyID, uid: uid)
            }
        }
        if let context {
            purgeSyncedFamilyProjection(context: context)
            detachSharedPlaces(context: context)
        }
        pings = []
        liveLocations = []
        currentFamilyID = nil
        currentInviteCode = nil
        currentInviteCodeExpiresAt = nil
        familyName = nil
        memberUids = []
        isFamilyOwner = false
        // 清掉 CloudKit 舊架構殘留的鍵
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingsKeys.activeFamilyZoneName)
        defaults.removeObject(forKey: SettingsKeys.activeFamilyOwnerName)
        defaults.removeObject(forKey: SettingsKeys.knownFamilyMemberUids)
        await refreshAccountStatus()
    }

    /// 清掉「同步而來」的家人本機投影：sharedIdentityKey 非 nil（代表是雲端家庭圈成員投影
    /// 出來的，見 [refreshFamilyMembers] / [applyLiveLocationSnapshots]）且不是本人、
    /// 不是重要地點的紀錄。手動新增的家人（sharedIdentityKey == nil）刻意保留——
    /// 那是使用者自己建的本機資料，跟「這台裝置屬於哪個雲端家庭圈」無關。
    private func purgeSyncedFamilyProjection(context: ModelContext) {
        guard let members = try? context.fetch(FetchDescriptor<LocalFamilyMember>()) else { return }
        var changed = false
        for member in members where !member.isCurrentUser && !member.isPlace && member.sharedIdentityKey != nil {
            context.delete(member)
            changed = true
        }
        if changed { context.saveReporting() }
    }
}
