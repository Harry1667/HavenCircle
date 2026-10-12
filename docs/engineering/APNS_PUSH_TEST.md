# APNs 實機推播驗證

> 更新：2026-07-17。APNs 後端與 `.p8` 金鑰已上線；目前缺的是 Development 與 Production 各一次實機收件證據。

## 先回答：要不要先上 TestFlight？

不用。第一輪直接用 Xcode 把 Debug build 裝到 iPhone，速度最快，也能驗證通知權限、APNs sandbox、背景喚醒與 deep link。介面封版後再用 TestFlight 驗證 Release build 的 production APNs，作為提交前的第二道證據。

| 安裝方式 | APNs 環境 | 用途 |
| --- | --- | --- |
| Xcode Debug 實機 | sandbox / Development | 開發期找問題、讀完整診斷 Log |
| TestFlight | production | 封版後確認正式簽名、production token 與真實安裝流程 |

App 上傳權杖時會附上 build 環境，伺服器會自動選擇對應 APNs 主機；不同環境的 token 不能混用。

## 測試前準備

1. iPhone 登入 iCloud，接上 Mac，在 Xcode 選擇該 iPhone 後執行 Debug build。
2. 開啟 App → 設定 → **Debug 實機測試** → **實機診斷金手指**。
3. 先按「清除」，再按「一鍵執行實機檢查」，允許通知與定位。
4. 若要驗證背景定位，另按「要求永遠允許定位」，並在系統設定確認定位權限為「永遠」。
5. 複製診斷報告留存。報告不包含完整 APNs token、精確座標、住址或家人姓名。

App 每次啟動都會自動留下裝置、Background Modes、通知權限、定位權限、APNs token 是否存在與 iCloud 狀態；一鍵檢查會再測定位回呼、NCDR API 及 5 秒本機診斷通知。

> 「5 秒本機診斷通知」只證明通知權限與系統呈現正常，**不等於 APNs 證據**。

## 方法一：Apple Push Notification Console

適合驗證單一 Development token 與保存 Apple 的送達紀錄。

1. 在 Debug 設定頁複製 APNs 裝置權杖。
2. 登入 [Apple Push Notification Console](https://icloud.developer.apple.com/dashboard/notifications/teams/)。
3. 選 App ID `com.gomiigo.CamMenuApp.HavenCircle`。
4. Environment 選 **Development**，貼上該 Debug build 的 token。
5. 發送以下可見通知：

```json
{
  "aps": {
    "alert": {
      "title": "安心圈實機驗證",
      "body": "APNs 已送達；點擊後應開啟提醒中心。"
    },
    "sound": "default"
  }
}
```

6. 鎖定 iPhone，錄下通知到達與點擊後開啟提醒中心。
7. 截圖 Push Notification Console 的 delivery log；裝置 token 需遮蔽，只保留環境、時間與成功狀態。

## 方法二：HavenCircle 伺服器

整條正式鏈為：App 上傳 token → Oracle 登記 → NCDR cron 發無聲喚醒 → App 在裝置端更新事件、比對警戒圈 → 命中時才發本機通知。

伺服器只保存推播所需 token 與環境，不接收警戒圈、最新位置或位置軌跡；最新位置只透過家庭 iCloud CKShare 分享。

管理金鑰只放在目前 Terminal 的環境變數，不能寫入 App、文件、影片或 git：

```bash
export HAVENCIRCLE_APNS_ADMIN_KEY='在這裡貼伺服器管理金鑰'

# 可見 APNs：驗證伺服器 → APNs → 鎖屏通知
curl -X POST https://havencircle.looptw.com/apns/notify_all.php \
  -H "X-Admin-Key: $HAVENCIRCLE_APNS_ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"mode":"alert","title":"安心圈實機驗證","body":"伺服器 APNs 已送達；點擊查看提醒中心。"}'

# 無聲 APNs：驗證背景喚醒與裝置端事件管線
curl -X POST https://havencircle.looptw.com/apns/notify_all.php \
  -H "X-Admin-Key: $HAVENCIRCLE_APNS_ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  -d '{}'
```

預期結果：

- HTTP 回應顯示至少一台相符環境裝置送出成功；若同時有 sandbox 與 production token，要分開看各環境結果。
- 可見推播在鎖屏出現，點擊後進提醒中心。
- 無聲推播本身不應出現橫幅；重新打開診斷頁，Log 應出現「收到背景遠端通知」及事件管線完成狀態。
- 若當下沒有新的相關官方事件，無聲喚醒後沒有使用者通知是正確結果，不能把它判定為失敗。

## 測試矩陣與通過條件

| 編號 | Build | 測試 | 通過條件 |
| --- | --- | --- | --- |
| P01 | Xcode Debug | 權限＋本機通知 | Log 有授權結果，5 秒通知可見 |
| P02 | Xcode Debug | Development 可見 APNs | 鎖屏收件、點擊進提醒中心、Apple／伺服器成功紀錄 |
| P03 | Xcode Debug | Development 無聲 APNs | 背景 callback 與事件管線完成 Log |
| P04 | TestFlight | Production 可見 APNs | 正式安裝可收件、點擊 deep link 正確 |
| P05 | TestFlight | Production 無聲 APNs | 背景 callback 與事件管線完成，無錯誤假成功 |

## 常見失敗判讀

- `BadDeviceToken`：token 與 Development／Production 環境不一致，先刪除 App、重裝並重新複製 token。
- 診斷顯示沒有 token：確認 Signing & Capabilities 有 Push Notifications，網路正常，重新啟動 App。
- 只有本機通知成功：只能證明通知權限，尚未證明 APNs。
- 可見通知成功、無聲喚醒偶爾延遲：iOS 會依電量、使用狀態與系統預算調度背景推播，需記錄實際時間，不能承諾固定秒數。
- 使用者手動從 App Switcher 強制結束 App：不要作為背景持續更新的成功案例；把它列為獨立邊界測試並如實記錄。

完整背景定位與雙機證據流程見 `submission/DEVICE_EVIDENCE_PLAN.md`。
