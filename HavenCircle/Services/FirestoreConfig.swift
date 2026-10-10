import Foundation
import FirebaseFirestore

/// Firestore 家庭圈後端的共用設定與常數。
///
/// ⚠️ 重要坑：本專案的 Firestore 是「具名資料庫」`default`，不是 Firestore 慣例的 `(default)`。
/// 一定要用 `Firestore.firestore(database:)` 版本；直接呼叫 `Firestore.firestore()` 會連到
/// 不存在的 `(default)` 資料庫，所有讀寫都失敗，而且實機才爆、很難查。全 App 一律透過
/// `FirestoreConfig.store()` 取用，別自己呼叫 `Firestore.firestore()`。
enum FirestoreConfig {
    /// 具名資料庫 ID（見上方警告，勿改成 "(default)"）
    static let databaseID = "default"

    /// 取得指向正確資料庫的 Firestore 實例。
    static func store() -> Firestore {
        Firestore.firestore(database: databaseID)
    }

    /// Collection 路徑名（集中定義，避免字串散落各處）
    enum Path {
        static let families = "families"
        static let members = "members"
        static let locations = "locations"
        static let pings = "pings"
        static let inviteCodes = "inviteCodes"
        /// 守護地點到達／離開事件（families/{id}/arrivals）
        static let arrivals = "arrivals"
        /// 24 小時軌跡（families/{id}/locations/{uid}/trail）
        static let trail = "trail"
    }
}
