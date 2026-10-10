import Foundation
import FirebaseFirestore
import os

// MARK: - Firestore 家庭圈資料模型（純 struct，Firestore 文件的 Swift 投影）

/// 家庭圈根文件（Firestore: families/{familyId}）
struct FamilyCircleDoc: Identifiable, Equatable {
    let id: String            // = familyId（Firestore 文件 ID）
    var name: String
    var ownerUid: String
    var inviteCode: String    // 8 碼邀請碼（取代 CKShare 連結）
    var memberUids: [String]  // 冗餘存成員 uid 陣列，供 Security Rules 快速判斷成員身份
    var createdAt: Date
}

/// 家庭成員文件（Firestore: families/{familyId}/members/{uid}）
struct FamilyMemberDoc: Identifiable, Equatable {
    let id: String            // = 成員 uid
    var displayName: String
    var role: String          // "owner" / "member"
    var joinedAt: Date

    var isOwner: Bool { role == "owner" }
}

/// 邀請碼預覽（C1）：加入前先讓使用者確認「要加入誰的家庭圈」，不加入就不寫任何資料。
/// 舊邀請碼（建立於本欄位補上之前）沒有 familyName/ownerName，對應欄位為 nil，
/// 呼叫端要處理「兩者皆 nil」的降級文案。
struct InvitePreview: Equatable {
    let familyId: String
    let familyName: String?
    let ownerName: String?
}

// MARK: - 錯誤

enum FamilyBackendError: LocalizedError {
    case notSignedIn
    case invalidInviteCode
    case familyNotFound
    /// 邀請碼格式合法、查得到 familyId，但已超過 7 天效期（C2）。
    /// 舊邀請碼（沒有 expiresAt 欄位）一律視為有效，不會落到這個分支。
    case inviteExpired

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "請先用 Apple 帳號登入，才能建立或加入家庭圈。"
        case .invalidInviteCode:
            return "邀請碼不正確或已失效，請向家人確認後重新輸入。"
        case .familyNotFound:
            return "找不到對應的家庭圈，可能已被解散。"
        case .inviteExpired:
            return "這組邀請碼已過期，請家人重新產生一組。"
        }
    }
}

/// 安否回報保命級 P0：Firestore 離線時 `setData` 會無限期等待伺服器 ack，
/// 讓呼叫端的 spinner／按鈕鎖死。[postPing] 用這個錯誤代表「等太久沒收到確認」。
///
/// ⚠️ 逾時不等於「寫入失敗」——那筆寫入很可能還在 Firestore 本機離線佇列裡，
/// 連上網路後會自動補送成功。呼叫端顯示文案務必誠實反映「可能未送出」這個不確定性，
/// 不能寫成「已失敗」，也不能假裝成功；教使用者用「家人回報清單有沒有出現」自行確認。
struct SafetyPingTimeoutError: LocalizedError {
    var errorDescription: String? {
        "已等候 8 秒未收到送出確認，回報可能未送出。若已連上網路，離線佇列稍後可能自動補送——請看家人回報清單有沒有出現你的回報來確認。"
    }
}

/// 即時位置寫入逾時：Firestore 的 setData 只在「伺服器確認」後才完成，離線或網路卡住時會一直懸著，
/// 若不設上限，FamilySyncService 的「只允許一筆在途」旗標會永遠不釋放，之後所有上傳都被擋掉（靜默失效）。
struct LiveLocationTimeoutError: LocalizedError {
    var errorDescription: String? { "網路不穩，位置尚未送出，稍後會自動重試" }
}

// MARK: - Firestore 家庭圈後端

/// 家庭圈的 Firestore 資料層（無狀態的操作集合）。
///
/// 身份一律用呼叫端傳入的 Firebase uid（來自 [AuthService]），這一層不自己碰 AuthService，
/// 方便測試與非 MainActor 呼叫。所有讀寫都透過 [FirestoreConfig.store] 指向具名資料庫 default。
enum FirestoreFamilyBackend {

    /// 建立家庭圈：產生 familyId 與 8 碼邀請碼，寫入根文件、擁有者成員、邀請碼索引。
    /// 回傳建立好的家庭圈文件。
    static func createFamily(
        ownerUid: String,
        ownerDisplayName: String,
        familyName: String
    ) async throws -> FamilyCircleDoc {
        let db = FirestoreConfig.store()
        let familyRef = db.collection(FirestoreConfig.Path.families).document()
        let code = generateInviteCode()
        let now = Date()

        try await familyRef.setData([
            "name": familyName,
            "ownerUid": ownerUid,
            "inviteCode": code,
            "memberUids": [ownerUid],
            "createdAt": Timestamp(date: now)
        ])
        try await familyRef.collection(FirestoreConfig.Path.members).document(ownerUid).setData([
            "displayName": FamilyNaming.clean(ownerDisplayName),
            "role": "owner",
            "joinedAt": Timestamp(date: now)
        ])
        // 邀請碼索引：家人輸入碼 → 查到 familyId。獨立 collection 讓「用碼查家庭」不必掃全表。
        // familyName/ownerName（C1）額外寫入：讓對方輸碼後能在加入前看到「要加入誰的家庭圈」，
        // 不必先加入才知道加錯人。
        // expiresAt（7 天效期）：只是欄位，過期判斷由 lookupInvite/joinFamily 在讀取端做；
        // 舊邀請碼（此欄位補上之前建立的）沒有這個欄位，視為長期有效，相容既有家庭。
        try await db.collection(FirestoreConfig.Path.inviteCodes).document(code).setData([
            "familyId": familyRef.documentID,
            "createdAt": Timestamp(date: now),
            "expiresAt": Timestamp(date: now.addingTimeInterval(inviteCodeLifetime)),
            "familyName": familyName,
            "ownerName": FamilyNaming.clean(ownerDisplayName)
        ])

        return FamilyCircleDoc(
            id: familyRef.documentID,
            name: familyName,
            ownerUid: ownerUid,
            inviteCode: code,
            memberUids: [ownerUid],
            createdAt: now
        )
    }

    /// 用邀請碼加入家庭圈。回傳加入的 familyId。
    static func joinFamily(
        code: String,
        uid: String,
        displayName: String
    ) async throws -> String {
        let db = FirestoreConfig.store()
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        let codeDoc = try await db.collection(FirestoreConfig.Path.inviteCodes).document(normalized).getDocument()
        guard codeDoc.exists, let data = codeDoc.data(), let familyId = data["familyId"] as? String else {
            throw FamilyBackendError.invalidInviteCode
        }
        // C2：expiresAt 存在且已過期 → 專屬錯誤；欄位不存在（舊碼）視為有效，相容既有家庭。
        if let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(), expiresAt < Date() {
            throw FamilyBackendError.inviteExpired
        }
        let familyRef = db.collection(FirestoreConfig.Path.families).document(familyId)
        // 併發安全：arrayUnion 不會重複加入同一個 uid。
        do {
            try await familyRef.updateData([
                "memberUids": FieldValue.arrayUnion([uid])
            ])
        } catch let error as NSError where error.domain == FirestoreErrorDomain
            && error.code == FirestoreErrorCode.permissionDenied.rawValue {
            // 邀請碼合法（inviteCodes 讀取通過）卻在寫入 memberUids 時被拒——rules 對這個更新
            // 分支只檢查 `resource.data`（文件現有內容），家庭圈一旦被圈主解散
            // （[deleteFamily]）根文件不存在，`resource.data` 求值出錯，一律回 permission-denied。
            // 在這個呼叫路徑下，這幾乎唯一可能的成因就是「家庭圈已解散」，轉譯成更精確的錯誤。
            throw FamilyBackendError.familyNotFound
        }
        try await familyRef.collection(FirestoreConfig.Path.members).document(uid).setData([
            "displayName": FamilyNaming.clean(displayName),
            "role": "member",
            "joinedAt": Timestamp(date: Date())
        ], merge: true)
        return familyId
    }

    /// 登記本機 FCM 權杖到自己的成員文件（merge，只動 fcmToken 相關欄位）。
    /// 權杖本身無法單獨發訊息（需伺服器端服務帳號），僅供 Oracle 依 uid 發家人到達通知與更新位置喚醒。
    static func publishFCMToken(familyId: String, uid: String, token: String) async throws {
        let ref = FirestoreConfig.store().collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.members).document(uid)
        try await withWriteDeadline(seconds: 10) {
            try await ref.setData([
                "fcmToken": token,
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    /// 把自己的名字同步到雲端所有相關文件（成員資料 members/{uid}、位置文件 locations/{uid}、
    /// 圈主時的邀請碼預覽 ownerName）。name 為空＝清掉雲端名字（位置文件刪欄位、成員資料寫空字串）。
    ///
    /// onlyIfPlaceholder＝true 為啟動時的「資料遷移」模式：先讀雲端現值，只有現值是佔位字
    /// （「我」「家人」「圈主」…）才改寫，已經是真名的不動，避免多裝置互相覆蓋。
    /// 位置文件不存在時不建立（沒開分享的人不該憑空多出一筆位置文件，也避免被規則拒絕）。
    static func syncOwnName(
        familyId: String, uid: String, name: String, onlyIfPlaceholder: Bool,
        isOwner: Bool, inviteCode: String?
    ) async throws {
        let db = FirestoreConfig.store()
        let familyRef = db.collection(FirestoreConfig.Path.families).document(familyId)
        let clean = FamilyNaming.clean(name)

        let memberRef = familyRef.collection(FirestoreConfig.Path.members).document(uid)
        let memberSnap = try? await memberRef.getDocument()
        if let data = memberSnap?.data() {
            let current = data["displayName"] as? String
            let isDirty = (current ?? "") != FamilyNaming.clean(current)
            if onlyIfPlaceholder ? isDirty : (current ?? "") != clean {
                try await memberRef.setData(["displayName": clean], merge: true)
            }
        }

        let locationRef = familyRef.collection(FirestoreConfig.Path.locations).document(uid)
        let locationSnap = try? await locationRef.getDocument()
        if let data = locationSnap?.data() {
            let current = data["displayName"] as? String
            let isDirty = current != nil && (current ?? "") != FamilyNaming.clean(current)
            let needsWrite = onlyIfPlaceholder ? isDirty : (current ?? "") != clean
            if needsWrite {
                // updateData 只改名字欄位，不會碰座標；空字串＝刪欄位
                try await locationRef.updateData([
                    "displayName": clean.isEmpty ? FieldValue.delete() : clean
                ])
            }
        }

        // 邀請碼預覽的圈主名字：盡力而為（規則不允許或碼已失效都不擋主流程）
        if isOwner, let inviteCode, !inviteCode.isEmpty {
            let codeRef = db.collection(FirestoreConfig.Path.inviteCodes).document(inviteCode)
            if let snap = try? await codeRef.getDocument(), let data = snap.data() {
                let current = data["ownerName"] as? String
                let isDirty = (current ?? "") != FamilyNaming.clean(current)
                if onlyIfPlaceholder ? isDirty : (current ?? "") != clean {
                    try? await codeRef.updateData(["ownerName": clean])
                }
            }
        }
    }

    /// 離開家庭圈：從 memberUids 移除自己，並刪掉自己的成員與位置文件。
    static func leaveFamily(familyId: String, uid: String) async throws {
        let db = FirestoreConfig.store()
        let familyRef = db.collection(FirestoreConfig.Path.families).document(familyId)
        // 軌跡與事件要在退出「之前」刪：退出後就不再是成員，規則不允許再碰這個家庭圈的子集合
        try? await deleteOwnTrail(familyId: familyId, uid: uid)
        try? await pruneOwnArrivals(familyId: familyId, uid: uid, olderThan: nil)
        try await familyRef.updateData(["memberUids": FieldValue.arrayRemove([uid])])
        try? await familyRef.collection(FirestoreConfig.Path.members).document(uid).delete()
        try? await familyRef.collection(FirestoreConfig.Path.locations).document(uid).delete()
    }

    /// 解散家庭圈：只有圈主能呼叫（對照 firestore.rules `families/{familyId}` 的
    /// `allow delete: if ... resource.data.ownerUid == request.auth.uid`）。
    ///
    /// 現在會把整個家庭圈的資料清乾淨，不再留孤兒資料。順序固定且刻意如此（每一步都對照
    /// firestore.rules 為什麼在「根文件還在」的當下有權限）：
    /// ①刪所有 members/*、locations/* 子文件（rules 新增的 `isOwner(familyId)` 給圈主刪
    ///   其他成員文件的權限；這個 get() 查根文件的 ownerUid，此時根文件必須還在）
    /// ②分頁批次刪 pings（同樣靠 isOwner；每批最多 400 筆，用 WriteBatch 減少往返）
    /// ③刪 inviteCodes/{familyDoc.inviteCode}（rules 的 isOwner 一樣要查得到根文件的
    ///   ownerUid，所以必須在刪根文件「之前」做）
    /// ④最後才刪 families/{id} 根文件本身
    ///
    /// 任何一步失敗都直接往上拋（不再用 try? 吞掉），根文件此時仍然存在——使用者重試
    /// 「解散家庭圈」即可從失敗處續刪（每一步都是刪除操作，天然冪等，重跑不會出錯）。
    /// 唯一無法完全避免的殘留情境：解散途中斷網／App 被殺掉、根文件還在但部分子資料
    /// 已被清掉，這種「解散中途」的殘留可重試修復，不是永久孤兒。
    static func deleteFamily(familyId: String, uid: String) async throws {
        let db = FirestoreConfig.store()
        let familyRef = db.collection(FirestoreConfig.Path.families).document(familyId)

        // 解散前讀一次根文件：拿 inviteCode（③要用）；此時根文件必須還在，
        // 之後每一步 rules 的 isOwner() 才查得到 ownerUid。
        let family = try await fetchFamily(familyId: familyId)

        // ①members/*、locations/* 子文件：列出目前實際存在的文件逐一刪，
        // 而不是只刪 memberUids 陣列裡的 uid——陣列可能因為某些歷史因素跟子集合不完全同步，
        // 直接列 collection 才能保證刪乾淨。
        let membersSnapshot = try await familyRef.collection(FirestoreConfig.Path.members).getDocuments()
        for doc in membersSnapshot.documents {
            try await doc.reference.delete()
        }
        let locationsSnapshot = try await familyRef.collection(FirestoreConfig.Path.locations).getDocuments()
        for doc in locationsSnapshot.documents {
            // 子集合不會隨父文件自動刪除：先清掉每位成員的軌跡點
            while true {
                let trailSnapshot = try await doc.reference.collection(FirestoreConfig.Path.trail)
                    .limit(to: 400).getDocuments()
                if trailSnapshot.documents.isEmpty { break }
                let batch = db.batch()
                trailSnapshot.documents.forEach { batch.deleteDocument($0.reference) }
                try await batch.commit()
                if trailSnapshot.documents.count < 400 { break }
            }
            try await doc.reference.delete()
        }

        // 到達／離開事件（同樣靠 isOwner；每批 400 筆）
        while true {
            let batchSnapshot = try await familyRef.collection(FirestoreConfig.Path.arrivals)
                .limit(to: 400)
                .getDocuments()
            if batchSnapshot.documents.isEmpty { break }
            let batch = db.batch()
            batchSnapshot.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            if batchSnapshot.documents.count < 400 { break }
        }

        let requestSnapshot = try await familyRef.collection(FirestoreConfig.Path.locationRequests).getDocuments()
        for doc in requestSnapshot.documents { try await doc.reference.delete() }

        // 全家共用的守護地點（家庭成員皆可刪，圈主當然也可以）；同樣每批 400 筆
        while true {
            let batchSnapshot = try await familyRef.collection(FirestoreConfig.Path.places)
                .limit(to: 400)
                .getDocuments()
            if batchSnapshot.documents.isEmpty { break }
            let batch = db.batch()
            batchSnapshot.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            if batchSnapshot.documents.count < 400 { break }
        }

        // ②pings：分頁批次刪，每批最多 400 筆（Firestore WriteBatch 上限），
        // 反覆抓下一批直到抓不到為止，避免安否回報量大時一次性操作逾時。
        while true {
            let batchSnapshot = try await familyRef.collection(FirestoreConfig.Path.pings)
                .limit(to: 400)
                .getDocuments()
            if batchSnapshot.documents.isEmpty { break }
            let batch = db.batch()
            for doc in batchSnapshot.documents {
                batch.deleteDocument(doc.reference)
            }
            try await batch.commit()
            if batchSnapshot.documents.count < 400 { break }
        }

        // ③inviteCodes/{code}：家庭文件還在，rules 的 isOwner() 查得到 ownerUid，這裡才刪得掉。
        try await db.collection(FirestoreConfig.Path.inviteCodes).document(family.inviteCode).delete()

        // ④最後才刪根文件——必須是最後一步，前面三步都依賴它還存在才有刪除權限。
        try await familyRef.delete()
    }

    /// 讀取家庭圈根文件。
    static func fetchFamily(familyId: String) async throws -> FamilyCircleDoc {
        let db = FirestoreConfig.store()
        let doc = try await db.collection(FirestoreConfig.Path.families).document(familyId).getDocument()
        guard doc.exists, let family = family(from: doc) else {
            throw FamilyBackendError.familyNotFound
        }
        return family
    }

    /// 讀取家庭圈所有成員。
    static func fetchMembers(familyId: String) async throws -> [FamilyMemberDoc] {
        let db = FirestoreConfig.store()
        let snapshot = try await db.collection(FirestoreConfig.Path.families)
            .document(familyId)
            .collection(FirestoreConfig.Path.members)
            .getDocuments()
        return snapshot.documents.compactMap(member(from:))
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    /// 找出這個 uid 目前所屬的家庭圈（用 memberUids 陣列查詢）。
    /// 回傳第一個符合的家庭圈；沒有則 nil。用於換裝置或本機沒存 familyId 時的還原。
    static func findFamily(forUid uid: String) async throws -> FamilyCircleDoc? {
        let db = FirestoreConfig.store()
        let snapshot = try await db.collection(FirestoreConfig.Path.families)
            .whereField("memberUids", arrayContains: uid)
            .limit(to: 1)
            .getDocuments()
        return snapshot.documents.first.flatMap(family(from:))
    }

    // MARK: - 邀請碼

    /// 邀請碼合法字元集：刻意排除易混淆字元（0/O、1/I、Z/2 等）。
    /// 抽成共用常數讓輸入端（JoinByCodeView）能驗證字元合法性，不只是驗長度。
    static let inviteCodeCharset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /// 邀請碼效期（C1）：7 天。createFamily／regenerateInviteCode 寫入 expiresAt 時共用這個常數。
    static let inviteCodeLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// 產生 8 碼邀請碼。
    static func generateInviteCode() -> String {
        let charset = Array(inviteCodeCharset)
        return String((0..<8).map { _ in charset.randomElement()! })
    }

    /// 邀請碼格式是否合法（8 碼、全落在合法字元集）。純本機檢查，不打網路，
    /// 讓 UI 能在送出查詢前先擋掉明顯打錯的輸入，給出「格式不對」這種更精準的錯誤文案。
    static func isValidInviteCodeFormat(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 8 else { return false }
        let allowed = Set(inviteCodeCharset)
        return trimmed.allSatisfy(allowed.contains)
    }

    /// 加入前確認（C1）：只讀 inviteCodes 索引，不寫入任何資料、不會讓人「不小心就加入了」。
    /// 舊邀請碼沒有 familyName/ownerName 欄位時，對應回傳 nil，交由呼叫端決定降級文案。
    ///
    /// ⚠️ 這裡刻意不多讀一次 `families/{familyId}` 來確認根文件是否還在：
    /// rules 的 `families/{familyId}` 讀取要求 `isMember(familyId)`，而 `isMember` 內部又對
    /// 同一份文件做一次 `get()`——非成員（正是這裡的呼叫情境：還沒加入就要先看預覽）讀取任何
    /// families 文件一律 `permission-denied`，不論該文件是否存在，無法用來判斷「已解散」。
    /// 因此「家庭圈已被圈主解散」這個情況，實際能可靠偵測到的時機是 [joinFamily] 真正嘗試
    /// 寫入 memberUids 的那一刻（見那裡的錯誤轉換），這裡維持只讀 inviteCodes 索引本身。
    static func lookupInvite(code: String) async throws -> InvitePreview {
        let db = FirestoreConfig.store()
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let codeDoc = try await db.collection(FirestoreConfig.Path.inviteCodes).document(normalized).getDocument()
        guard codeDoc.exists, let data = codeDoc.data(), let familyId = data["familyId"] as? String else {
            throw FamilyBackendError.invalidInviteCode
        }
        // C2：expiresAt 存在且已過期 → 專屬錯誤；欄位不存在（舊碼）視為有效，相容既有家庭。
        if let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(), expiresAt < Date() {
            throw FamilyBackendError.inviteExpired
        }
        return InvitePreview(
            familyId: familyId,
            familyName: data["familyName"] as? String,
            ownerName: FamilyNaming.clean(data["ownerName"] as? String)
        )
    }

    /// 讀取邀請碼索引文件的效期（C4：InviteOptionsView 顯示「效期至 M 月 d 日」用）。
    /// 沒有 expiresAt 欄位（舊碼）回傳 nil，呼叫端顯示「長期有效（建議重新產生）」。
    static func fetchInviteCodeExpiry(code: String) async throws -> Date? {
        let db = FirestoreConfig.store()
        let doc = try await db.collection(FirestoreConfig.Path.inviteCodes).document(code).getDocument()
        guard let data = doc.data() else { return nil }
        return (data["expiresAt"] as? Timestamp)?.dateValue()
    }

    /// 重新產生邀請碼（C3）：圈主專用（對照 firestore.rules `inviteCodes/{code}` 的
    /// `allow delete: if isOwner(...)`——非圈主呼叫這裡，刪舊碼那步會被拒但不擋主流程，
    /// UI 層本來就只對圈主顯示這個按鈕，見 InviteOptionsView）。
    ///
    /// 順序：先讀根文件拿 familyName/ownerUid（保留跟 createFamily 一致的預覽欄位）→
    /// 產新碼寫入 inviteCodes（含 7 天效期）→ 更新 families/{id}.inviteCode 指向新碼 →
    /// 盡力刪舊碼索引文件（失敗不擋：Firestore TTL 政策到期會自動清除，且加入邏輯真正
    /// 依賴的是 familyId，舊碼頂多讓「已經知道舊碼的人」還能看到加入前預覽）。
    static func regenerateInviteCode(familyId: String) async throws -> (code: String, expiresAt: Date) {
        let db = FirestoreConfig.store()
        let familyRef = db.collection(FirestoreConfig.Path.families).document(familyId)
        let family = try await fetchFamily(familyId: familyId)
        let oldCode = family.inviteCode

        let ownerDoc = try? await familyRef.collection(FirestoreConfig.Path.members)
            .document(family.ownerUid).getDocument()
        // 圈主沒有真名就存空字串，不再塞「圈主」佔位字（顯示端自己決定 fallback）
        let ownerName = FamilyNaming.clean(ownerDoc?.data()?["displayName"] as? String)

        let newCode = generateInviteCode()
        let now = Date()
        let expiresAt = now.addingTimeInterval(inviteCodeLifetime)
        try await db.collection(FirestoreConfig.Path.inviteCodes).document(newCode).setData([
            "familyId": familyId,
            "createdAt": Timestamp(date: now),
            "expiresAt": Timestamp(date: expiresAt),
            "familyName": family.name,
            "ownerName": ownerName
        ])
        try await familyRef.updateData(["inviteCode": newCode])
        // 舊碼盡力刪除；失敗（例如網路中斷）不擋，因為家庭根文件已指向新碼，
        // 舊碼殘留頂多是「查得到過期的預覽」，且 TTL 政策到期會自動清掉。
        try? await db.collection(FirestoreConfig.Path.inviteCodes).document(oldCode).delete()
        return (newCode, expiresAt)
    }

    // MARK: - 即時位置（同意式：只有開啟分享的人才會被寫入 locations 子集合）

    /// 寫入／更新這個成員的即時位置。merge 讓重複更新只改動座標欄位。
    /// updatedAt＝最後回報時間（位置變動與心跳都會刷新）；stationarySince＝開始停留時間。
    /// 兩者都只是時間戳，沒有新增任何個資或軌跡（文件仍只存「最新一筆」，覆寫不累積）。
    static func publishLocation(
        familyId: String,
        uid: String,
        displayName: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Int,
        district: String,
        stationarySince: Date,
        placeName: String?,
        placeSince: Date?,
        trailPoint: TrailPointInput? = nil
    ) async throws {
        let db = FirestoreConfig.store()
        let ref = db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locations).document(uid)
        var payload: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "radiusMeters": radiusMeters,
            "district": district,
            "updatedAt": Timestamp(date: Date()),
            "stationarySince": Timestamp(date: stationarySince),
            "isSharing": true
        ]
        // 名字：有真名才寫；沒有就刪欄位（merge 寫入會一併清掉舊版留下的「我」「家人」）
        let cleanName = FamilyNaming.clean(displayName)
        payload["displayName"] = cleanName.isEmpty ? FieldValue.delete() : cleanName
        // 目前所在守護地點（沒在任何守護地點內就清掉欄位，家人端才不會顯示過期的「在家」）
        if let placeName, !placeName.isEmpty {
            payload["placeName"] = placeName
            payload["placeSince"] = Timestamp(date: placeSince ?? Date())
        } else {
            payload["placeName"] = FieldValue.delete()
            payload["placeSince"] = FieldValue.delete()
        }
        // 位置文件與軌跡點放進同一個 batch：要嘛一起成功，不會出現「位置更新了但軌跡缺一點」。
        // 軌跡點：timestamp 用伺服器時間、clientAt 是手機取得定位的時間（讀取端用它排序與過濾 24 小時）、
        // expireAt = clientAt + 24 小時（供 Firestore TTL policy 自動清除，寫入時就帶上）。
        let batch = db.batch()
        batch.setData(payload, forDocument: ref, merge: true)
        if let trailPoint {
            let trailRef = ref.collection(FirestoreConfig.Path.trail).document()
            batch.setData([
                "latitude": trailPoint.latitude,
                "longitude": trailPoint.longitude,
                "accuracy": trailPoint.accuracy,
                "timestamp": FieldValue.serverTimestamp(),
                "clientAt": Timestamp(date: trailPoint.time),
                "expireAt": Timestamp(date: TrailPolicy.expireAt(for: trailPoint.time))
            ], forDocument: trailRef)
        }
        // 與逾時計時器賽跑：10 秒沒收到伺服器確認就丟出逾時（寫入仍在 Firestore 離線佇列，連線後會補送）
        try await withWriteDeadline(seconds: 10) { try await batch.commit() }
    }

    /// 軌跡點寫入參數
    struct TrailPointInput: Sendable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let time: Date
    }

    /// 讀某位家人 24 小時內的軌跡（clientAt 單欄位範圍查詢，不需複合索引），由舊到新。
    static func fetchTrail(familyId: String, uid: String, now: Date = .now) async throws -> [TrailPoint] {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locations).document(uid)
            .collection(FirestoreConfig.Path.trail)
            .whereField("clientAt", isGreaterThanOrEqualTo: Timestamp(date: TrailPolicy.cutoff(now: now)))
            .order(by: "clientAt")
            .limit(to: 1_500)
            .getDocuments()
        return snap.documents.compactMap { doc -> TrailPoint? in
            let data = doc.data()
            guard let lat = data["latitude"] as? Double, let lng = data["longitude"] as? Double,
                  let at = (data["clientAt"] as? Timestamp)?.dateValue() else { return nil }
            return TrailPoint(
                id: doc.documentID,
                sample: LocationSample(time: at, latitude: lat, longitude: lng),
                accuracy: data["accuracy"] as? Double ?? 0
            )
        }
    }

    /// 刪自己超過 24 小時的軌跡點，一次最多 [TrailPolicy.cleanupBatchLimit] 筆（批次）。回傳刪除筆數。
    @discardableResult
    static func pruneOwnTrail(familyId: String, uid: String, now: Date = .now) async throws -> Int {
        let db = FirestoreConfig.store()
        let snap = try await trailCollection(db, familyId, uid)
            .whereField("clientAt", isLessThan: Timestamp(date: TrailPolicy.cutoff(now: now)))
            .limit(to: TrailPolicy.cleanupBatchLimit)
            .getDocuments()
        guard !snap.documents.isEmpty else { return 0 }
        let batch = db.batch()
        snap.documents.forEach { batch.deleteDocument($0.reference) }
        try await batch.commit()
        return snap.documents.count
    }

    /// 刪光自己的軌跡（關閉分享、離開家庭圈時）：分頁批次，每批 400 筆
    static func deleteOwnTrail(familyId: String, uid: String) async throws {
        let db = FirestoreConfig.store()
        let collection = trailCollection(db, familyId, uid)
        while true {
            let snap = try await collection.limit(to: 400).getDocuments()
            if snap.documents.isEmpty { return }
            let batch = db.batch()
            snap.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            if snap.documents.count < 400 { return }
        }
    }

    private static func trailCollection(_ db: Firestore, _ familyId: String, _ uid: String) -> CollectionReference {
        db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locations).document(uid)
            .collection(FirestoreConfig.Path.trail)
    }

    /// 停止分享：標記 isSharing=false（家人下次刷新會移除此人的即時圈）。
    static func stopLocation(familyId: String, uid: String) async throws {
        let db = FirestoreConfig.store()
        try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locations).document(uid).setData([
                "isSharing": false,
                "updatedAt": Timestamp(date: Date()),
                "placeName": FieldValue.delete(),
                "placeSince": FieldValue.delete()
            ], merge: true)
        // 關閉分享＝刪除自己的 24 小時軌跡與到達/離開事件（隱私承諾）。失敗不擋停止分享本身，
        // 但要記錄；殘留的點最多 24 小時後由 TTL／清理機制移除。
        do {
            try await deleteOwnTrail(familyId: familyId, uid: uid)
            try await pruneOwnArrivals(familyId: familyId, uid: uid, olderThan: nil)
            await clearLocationRequest(familyId: familyId, uid: uid)
        } catch {
            AppLog.cloud.error("停止分享時清除軌跡失敗：\(error.localizedDescription)")
        }
    }

    /// 讀取家庭圈所有成員的即時位置。
    static func fetchLocations(familyId: String) async throws -> [FamilyLiveLocation] {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locations).getDocuments()
        return snap.documents.compactMap(liveLocation(from:))
    }

    // MARK: - 全家共用守護地點

    /// 雲端守護地點文件（不含任何個人位置，只有「地點」本身）
    struct PlaceDoc: Equatable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int
        let addressText: String
        let district: String
        let createdBy: String
    }

    static func fetchPlaces(familyId: String) async throws -> [PlaceDoc] {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.places).getDocuments()
        return snap.documents.compactMap { doc -> PlaceDoc? in
            let data = doc.data()
            guard let lat = data["latitude"] as? Double, let lon = data["longitude"] as? Double else { return nil }
            return PlaceDoc(
                id: doc.documentID,
                name: data["name"] as? String ?? "守護地點",
                latitude: lat,
                longitude: lon,
                radiusMeters: (data["radiusMeters"] as? Int) ?? Int(data["radiusMeters"] as? Double ?? 1_000),
                addressText: data["addressText"] as? String ?? "",
                district: data["district"] as? String ?? "未指定",
                createdBy: data["createdBy"] as? String ?? ""
            )
        }
    }

    /// 新增或更新一個共用守護地點。isCreate 時才寫 createdAt；createdBy 一律由呼叫端帶入
    /// （新建＝自己；編輯別人建立的＝原建立者，規則要求 createdBy 不可被改）。
    static func upsertPlace(familyId: String, place: PlaceDoc, isCreate: Bool) async throws {
        let db = FirestoreConfig.store()
        let ref = db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.places).document(place.id)
        var data: [String: Any] = [
            "name": place.name,
            "latitude": place.latitude,
            "longitude": place.longitude,
            "radiusMeters": place.radiusMeters,
            "addressText": place.addressText,
            "district": place.district,
            "createdBy": place.createdBy,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if isCreate { data["createdAt"] = FieldValue.serverTimestamp() }
        try await withWriteDeadline(seconds: 10) { try await ref.setData(data, merge: true) }
    }

    static func deletePlace(familyId: String, placeId: String) async throws {
        let db = FirestoreConfig.store()
        let ref = db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.places).document(placeId)
        try await withWriteDeadline(seconds: 10) { try await ref.delete() }
    }

    // MARK: - 守護地點到達／離開事件

    /// 寫一筆到達／離開事件。createdAt 用伺服器時間（各手機時鐘不一致時，家人端用它判斷「新事件」才可靠），
    /// clientAt 是事件實際發生時間，expireAt 供 Firestore TTL 政策使用（24 小時，寫入時就帶上）。
    /// 不存座標：只記「誰、到達／離開、哪個守護地點、何時」。
    static func postArrival(
        familyId: String,
        uid: String,
        name: String,
        kind: ArrivalEvent.Kind,
        source: ArrivalEvent.Source,
        placeName: String,
        at date: Date
    ) async throws {
        let db = FirestoreConfig.store()
        let ref = db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.arrivals).document()
        let data: [String: Any] = [
            "uid": uid,
            "name": FamilyNaming.clean(name),
            "kind": kind.rawValue,
            "source": source.rawValue,
            "placeName": placeName,
            "createdAt": FieldValue.serverTimestamp(),
            "clientAt": Timestamp(date: date),
            "expireAt": Timestamp(date: TrailPolicy.expireAt(for: date))
        ]
        try await withWriteDeadline(seconds: 10) { try await ref.setData(data) }
    }

    /// 讀 since 之後的事件（單欄位範圍查詢，不需複合索引；篩人與來源在用戶端做）
    static func fetchArrivals(familyId: String, since: Date) async throws -> [ArrivalEvent] {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.arrivals)
            .whereField("createdAt", isGreaterThan: Timestamp(date: since))
            .order(by: "createdAt")
            .limit(to: 300)
            .getDocuments()
        return snap.documents.compactMap { doc -> ArrivalEvent? in
            let data = doc.data()
            guard let uid = data["uid"] as? String,
                  let kindRaw = data["kind"] as? String, let kind = ArrivalEvent.Kind(rawValue: kindRaw),
                  let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                    ?? (data["clientAt"] as? Timestamp)?.dateValue()
            else { return nil }
            return ArrivalEvent(
                id: doc.documentID,
                uid: uid,
                name: FamilyNaming.clean(data["name"] as? String),
                kind: kind,
                source: (data["source"] as? String).flatMap(ArrivalEvent.Source.init(rawValue:)) ?? .region,
                placeName: data["placeName"] as? String ?? "",
                createdAt: createdAt
            )
        }
    }

    /// 刪除自己超過 24 小時的事件，以及（stopAll）全部事件；回傳刪除筆數。
    /// 用 uid 等值查詢（單欄位、不需複合索引），過期篩選在用戶端做。
    @discardableResult
    static func pruneOwnArrivals(familyId: String, uid: String, olderThan cutoff: Date?) async throws -> Int {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.arrivals)
            .whereField("uid", isEqualTo: uid)
            .limit(to: 400)
            .getDocuments()
        let doomed = snap.documents.filter { doc in
            guard let cutoff else { return true }
            let at = (doc.data()["clientAt"] as? Timestamp)?.dateValue() ?? .distantPast
            return at < cutoff
        }
        guard !doomed.isEmpty else { return 0 }
        let batch = db.batch()
        doomed.forEach { batch.deleteDocument($0.reference) }
        try await batch.commit()
        return doomed.count
    }

    /// 與逾時計時器賽跑：離線時 Firestore 寫入會無限期等伺服器 ack，這裡 N 秒沒確認就丟逾時
    /// （寫入仍在離線佇列，連線後會補送）。
    static func withWriteDeadline(seconds: UInt64, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw LiveLocationTimeoutError()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 家人要求「更新位置」

    /// 對某位家人發出更新位置請求：families/{id}/locationRequests/{targetUid}（每人最多一筆，新請求覆蓋舊的）。
    /// requestedAt 用伺服器時間，被請求方用它判斷是否過期（10 分鐘）。
    static func requestLocationUpdate(
        familyId: String, targetUid: String, requesterUid: String, requesterName: String
    ) async throws {
        let ref = FirestoreConfig.store().collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locationRequests).document(targetUid)
        let data: [String: Any] = [
            "requesterUid": requesterUid,
            "requesterName": FamilyNaming.clean(requesterName),
            "requestedAt": FieldValue.serverTimestamp(),
            "expireAt": Timestamp(date: Date().addingTimeInterval(LocationRequestPolicy.maxAge * 3))
        ]
        try await withWriteDeadline(seconds: 8) { try await ref.setData(data) }
    }

    /// 被請求方讀取自己的請求時間；沒有請求回 nil
    static func fetchLocationRequest(familyId: String, uid: String) async throws -> Date? {
        let doc = try await FirestoreConfig.store().collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locationRequests).document(uid).getDocument()
        guard doc.exists else { return nil }
        return (doc.data(with: .estimate)?["requestedAt"] as? Timestamp)?.dateValue() ?? Date()
    }

    static func clearLocationRequest(familyId: String, uid: String) async {
        do {
            try await FirestoreConfig.store().collection(FirestoreConfig.Path.families).document(familyId)
                .collection(FirestoreConfig.Path.locationRequests).document(uid).delete()
        } catch {
            AppLog.cloud.error("清除更新位置請求失敗：\(error.localizedDescription)")
        }
    }

    /// 即時監聽自己的請求（App 在前景或因背景定位而存活時，家人按下「更新位置」幾秒內就能收到）
    static func listenLocationRequest(
        familyId: String, uid: String, onRequest: @escaping @Sendable (Date) -> Void
    ) -> ListenerRegistration {
        FirestoreConfig.store().collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.locationRequests).document(uid)
            .addSnapshotListener { snapshot, error in
                if let error {
                    AppLog.cloud.error("監聽更新位置請求失敗：\(error.localizedDescription)")
                    return
                }
                guard let snapshot, snapshot.exists, !snapshot.metadata.hasPendingWrites else { return }
                let at = (snapshot.data(with: .estimate)?["requestedAt"] as? Timestamp)?.dateValue() ?? Date()
                onRequest(at)
            }
    }

    // MARK: - 安否回報

    @discardableResult
    static func postPing(
        familyId: String,
        senderUid: String,
        senderName: String,
        status: SafetyStatus,
        note: String,
        latitude: Double?,
        longitude: Double?,
        placeName: String?
    ) async throws -> String {
        let db = FirestoreConfig.store()
        let ref = db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.pings).document()
        let now = Date()
        var data: [String: Any] = [
            "senderUid": senderUid,
            "senderName": FamilyNaming.clean(senderName),
            "status": status.rawValue,
            "note": note,
            "createdAt": Timestamp(date: now),
            // D1：30 天 TTL 欄位，只負責寫入；Firestore 原生 TTL 政策（另行於 Console／REST 設定）
            // 才是實際刪除的機制，這裡到期後讀取端不用特別過濾，刪除本身有延遲也無妨。
            "expireAt": Timestamp(date: now.addingTimeInterval(30 * 24 * 60 * 60)),
            "readBy": [String]()
        ]
        // 位置為回報者「自願附上」的一次性座標，nil＝沒附
        if let latitude, let longitude {
            data["latitude"] = latitude
            data["longitude"] = longitude
            data["placeName"] = placeName ?? ""
        }

        // 逾時保護（8 秒）：離線時 setData 會無限期等伺服器 ack，讓呼叫端的 isReporting/isWorking
        // 永遠鎖住。用 withThrowingTaskGroup 讓「真正的寫入」與「8 秒計時」賽跑，誰先完成用誰的結果，
        // 另一個立刻取消——這是 Swift 結構化並行實作 timeout 的標準模式。
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await ref.setData(data)
                return ref.documentID
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw SafetyPingTimeoutError()
            }
            guard let result = try await group.next() else {
                throw SafetyPingTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    /// 讀取家庭圈所有安否回報（依時間新到舊；單欄排序不需複合索引）。
    static func fetchPings(familyId: String) async throws -> [SafetyPing] {
        let db = FirestoreConfig.store()
        let snap = try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.pings)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snap.documents.compactMap(ping(from:))
    }

    /// 標記某則回報為「某家人已讀」（已讀回條）。arrayUnion 天然去重。
    static func markPingRead(familyId: String, pingId: String, readerName: String) async throws {
        let db = FirestoreConfig.store()
        try await db.collection(FirestoreConfig.Path.families).document(familyId)
            .collection(FirestoreConfig.Path.pings).document(pingId).updateData([
                "readBy": FieldValue.arrayUnion([readerName])
            ])
    }

    // MARK: - 文件 → struct

    private static func family(from doc: DocumentSnapshot) -> FamilyCircleDoc? {
        guard let data = doc.data(),
              let name = data["name"] as? String,
              let ownerUid = data["ownerUid"] as? String,
              let inviteCode = data["inviteCode"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        else { return nil }
        return FamilyCircleDoc(
            id: doc.documentID,
            name: name,
            ownerUid: ownerUid,
            inviteCode: inviteCode,
            memberUids: data["memberUids"] as? [String] ?? [],
            createdAt: createdAt
        )
    }

    private static func member(from doc: QueryDocumentSnapshot) -> FamilyMemberDoc? {
        let data = doc.data()
        let displayName = FamilyNaming.clean(data["displayName"] as? String)
        guard let role = data["role"] as? String,
              let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue()
        else { return nil }
        return FamilyMemberDoc(
            id: doc.documentID,
            displayName: displayName,
            role: role,
            joinedAt: joinedAt
        )
    }

    /// Firestore 位置文件 → FamilyLiveLocation（文件 ID = 成員 uid，同時當 participantID）
    private static func liveLocation(from doc: QueryDocumentSnapshot) -> FamilyLiveLocation? {
        let data = doc.data()
        let displayName = FamilyNaming.clean(data["displayName"] as? String)
        guard let latitude = data["latitude"] as? Double,
              let longitude = data["longitude"] as? Double,
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
        else { return nil }
        return FamilyLiveLocation(
            id: doc.documentID,
            participantID: doc.documentID,
            displayName: displayName,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: (data["radiusMeters"] as? Int) ?? 1_000,
            district: data["district"] as? String ?? Districts.unspecified,
            updatedAt: updatedAt,
            // 舊版 App 寫的文件沒有這欄：nil 時文案退回「N 分鐘前更新位置」
            stationarySince: (data["stationarySince"] as? Timestamp)?.dateValue(),
            placeName: (data["placeName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            placeSince: (data["placeSince"] as? Timestamp)?.dateValue(),
            isSharing: data["isSharing"] as? Bool ?? false
        )
    }

    /// Firestore 回報文件 → SafetyPing
    private static func ping(from doc: QueryDocumentSnapshot) -> SafetyPing? {
        let data = doc.data()
        let senderName = FamilyNaming.clean(data["senderName"] as? String)
        guard let statusRaw = data["status"] as? String,
              let status = SafetyStatus(rawValue: statusRaw),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        else { return nil }
        return SafetyPing(
            id: doc.documentID,
            senderName: senderName,
            senderUid: data["senderUid"] as? String ?? "",
            status: status,
            note: data["note"] as? String ?? "",
            createdAt: createdAt,
            readBy: data["readBy"] as? [String] ?? [],
            latitude: data["latitude"] as? Double,
            longitude: data["longitude"] as? Double,
            placeName: (data["placeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
