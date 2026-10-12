# CloudKit + CKShare 設定與測試邊界（階段 3）

> 家庭連結（家人邀請、安否回報、即時圈位置）走 CloudKit + CKShare。
> 本檔說明：真實運作需要哪些設定、哪些已驗證、哪些只能在實機驗證。

## 架構

- **擁有者**在自己的 iCloud private database 建一個自訂 zone（`FamilyCircleZone`），內含一筆「家庭圈」根記錄。
- 對根記錄建立 **CKShare**。QR code 與 8 位邀請碼使用 `CKShare.Participant.oneTimeURLParticipant()` 的一次性私人網址；訊息／AirDrop 則保留 `UICloudSharingController` 系統邀請。
- **安否回報**（`SafetyPing`）以根記錄為 parent 寫入同一 zone，因此自動納入分享範圍。
- **即時圈**（`FamilyLiveLocation`）每台裝置固定一筆 record，只保留該裝置最新的位置、警戒半徑、行政區與更新時間；本人關閉分享時把 `isSharing` 改為 false。
- **家人**接受邀請後，用 shared database 存取同一 zone；雙方讀寫同一批 `SafetyPing`。
- App 前景每 30 秒刷新家庭位置；位置移動至少約 100 公尺才上傳。超過 15 分鐘未更新會標為過期，且不參與事件與區域警報判斷。
- 已讀回條：檢視他人回報時，把自己的名字加入該 ping 的 `readBy` 欄位。

程式進入點：`Services/FamilySyncService.swift`、`Services/LocationService.swift`、`Services/ShareAcceptance.swift`、`Views/Family/LiveCircleSharingSection.swift`、`Views/Family/InviteOptionsView.swift`、`Views/Family/SafetyCheckInView.swift`、`Views/Family/CloudSharingSheet.swift`。

## 上線前必做的設定

1. **建立 CloudKit container**：在 Apple Developer 後台或 Xcode Signing & Capabilities 加入 iCloud → CloudKit，容器 ID 使用 `iCloud.com.gomiigo.CamMenuApp.HavenCircle`（已寫在 `HavenCircle.entitlements`）。
2. **在 CloudKit Dashboard 定義 schema**：
   - `SafetyPing`：`senderName`(String)、`status`(String)、`note`(String)、`createdAt`(Date/Time)、`readBy`(String List)。
   - `FamilyLiveLocation`：`participantID`(String)、`displayName`(String)、`latitude`/`longitude`(Double)、`radiusMeters`(Int64)、`district`(String)、`updatedAt`(Date/Time)、`isSharing`(Int64/Bool)。
   - `FamilyCircle` root record type。
   首次以程式寫入時 development 環境會自動建立；確認 `FamilyLiveLocation.participantID`、`SafetyPing.createdAt` 為 Queryable 後再 Deploy to Production。App 不再以 `TRUEPREDICATE` 查詢未設索引的 system field `recordName`。
3. **推播能力**：`aps-environment` 已在 entitlements。CKShare 的變更通知需要 APNs；上線時確認 container 已啟用推播。
4. **一次性私人邀請**：App entitlement 必須包含 `com.apple.developer.icloud-extended-share-access = [InProcessOneTimeLinks]`。目前自動簽章 profile 與實機 App 都已確認含此值；若日後更換 App ID／團隊，必須重新檢查。
5. **佈建描述檔**：自動簽章需登入的 Apple ID 對此 container 有權限；用實機以 Xcode 直接 Run 才會真正授予 entitlement。

## 已驗證（模擬器）

- 專案含 CloudKit entitlement 可正常 build 與安裝。
- 無 iCloud 帳號時，`accountStatus()` 回傳 `noAccount`，安否分頁顯示「尚未登入 iCloud」引導、邀請按鈕停用，**App 不崩潰**（截圖存證）。
- SwiftData 本機 store 明確設 `cloudKitDatabase: .none`，與 CKShare 家庭同步互不干擾（修掉了 entitlement 存在時 SwiftData 誤試 CloudKit 鏡像、因 `@Attribute(.unique)` 建立失敗的問題）。

## 只能在實機驗證（需兩台不同 iCloud 帳號的裝置）

以下路徑在模擬器或單一帳號下無法端到端測試，需列入實機測試清單：

- 邀請流程：擁有者 `makeShare()` → `makeOneTimeInvitation()` → 家人掃描全新的 QR → 接受 → `windowScene(_:userDidAcceptCloudKitShareWith:)` 回呼。一般 `share.url` 在 `publicPermission = .none` 時不能直接做 QR，會出現「Item Unavailable」。
- 跨裝置回報：家人 A 送安否 → 家人 B 讀到 → B 的已讀回條回到 A。
- 即時圈：A 開啟分享並移動超過 100 公尺 → B 在 30 秒內看到圈心與更新時間改變 → A 關閉後 B 的圈消失。
- 背景定位：A 鎖定螢幕後移動，確認 iOS 顯示背景定位狀態、CloudKit 記錄持續更新，且關閉分享後不再更新。
- 位置過期：停止 A 的網路或定位超過 15 分鐘，B 必須看到「位置已過期」，且該圈不觸發警報。
- 安否回報與即時圈讀取都必須對 shared database 指定實際 shared zone ID；程式已按 `FamilyCircleZone` 篩選，不再以目前使用者的 private zone ID 查共享資料。
- 接受邀請後會把該 shared zone 設為目前家庭圈；即使成員手機曾建立過自己的空白 private zone，也不會把定位寫進錯誤家庭。

## 測試輔助（DEBUG only）

- `--start-tab-safety`：App 直接開在安否分頁（截圖驗證用）。
- `--smoke-onboard` / `--smoke-drill` / `--smoke-cloud`：見 `Support/SmokeTest.swift`。
  注意 `--smoke-cloud` 的 async 檢查在 `simctl launch`（背景）下不會執行，需前景（開 Simulator.app）才會跑。
