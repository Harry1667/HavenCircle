import Foundation

/// 行政區清單：全國鄉鎮市區（來自內嵌邊界圖資，取代第一版寫死的雙北清單）。
/// 審查發現的問題：清單只有雙北時，非雙北生活圈的區域警報永遠比對不到、
/// 且對使用者無聲失效——資料明明是全國的，服務範圍卻被清單卡死。
enum Districts {
    static let unspecified = "未指定"
    /// 「未指定」＋全國 375 個鄉鎮市區（排序）
    /// 效能：以前是計算屬性，每次讀取都對 375 個區名重新排序（動態頁每個事件、每次重繪都讀，
    /// 實測佔主執行緒約 75%），改成只算一次的 static let。邊界資料是內嵌資源、執行期不會變。
    static let all: [String] = [unspecified] + DistrictBoundaries.shared.allTownNames

    /// 從地址文字比對全國鄉鎮市區（供區域型警報使用）；找不到就標「未指定」
    static func guess(from text: String) -> String {
        all.dropFirst().first { text.contains($0) } ?? unspecified
    }
}
