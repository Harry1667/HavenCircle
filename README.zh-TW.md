[English](README.md) | 繁體中文 | [日本語](README.ja.md)

# HavenCircle

為台灣打造的個人化災害與安全警示。

HavenCircle 從約十個政府與新聞來源彙整事件資料、去除重複、為每個事件評估可信度，並且
**只在事情發生在你真正在意的地方**——你的家、父母的住處、孩子的學校——而且是在你
指定的時段內，才通知你。

台灣的災害資料原本就是公開的，但分散在 NCDR、中央氣象署、消防署、十六個縣市消防局、
高速公路局、環境部與新聞媒體之間。沒有人會每天把這些全部看一遍。每件事都推播，等於
什麼都沒推播：雜訊只會讓人把通知關掉。HavenCircle 的產品決策就是做減法。

**狀態：** 已在 App Store 上架。iOS 17.0+，SwiftUI + SwiftData，含一個 Widget 擴充。
目前版本 1.2。一人獨立開發。

## 上架範圍

HavenCircle **只在台灣 App Store 上架**：
<https://apps.apple.com/tw/app/id6791872200>

所有資料來源都是台灣的政府機關或台灣新聞媒體，介面也是繁體中文，因此沒有在其他地區
上架。如果你在其他國家的 App Store 搜尋不到，這是預期中的情況。下方附上截圖與說明，
讓你了解 App 的樣貌。

## 截圖

<table>
<tr>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_01_map.png" width="170" alt="安全地圖"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_02_home.png" width="170" alt="首頁"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_03_eventlist.png" width="170" alt="提醒中心"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_04_eventdetail.png" width="170" alt="事件詳情"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_05_family.png" width="170" alt="家人"></td>
</tr>
<tr>
<td valign="top"><sub><b>安全地圖。</b>標語：「掌握全台安全動態」。台北地區的地圖，標示著警戒範圍色塊、已命名地點的圖釘（「阿嬤家」「倉庫」「媽媽公司」）、紅色的「2 件需要注意」橫幅，以及底部附近事件的卡片（「持續確認中、11 小時前、距離媽媽的公司 500 公尺」）。</sub></td>
<td valign="top"><sub><b>首頁。</b>標語：「一鍵報平安」。紅色盾牌寫著「2 件事件靠近警戒圈」，並有「查看地圖」按鈕。下方列出圈內每個人或地點（倉庫：工廠大火濃煙，約 1.4 公里；阿嬤：聯結車撞機車，約 1.1 公里）。底部有藍色的「回報我平安」按鈕。</sub></td>
<td valign="top"><sub><b>提醒中心。</b>標語：「隨時發現周遭危險」。兩個分頁：「與我有關」與「全台動態」，並說明通知只會依據你的生活圈與設定發送。小地圖顯示一個警戒圈，下方是區域天災警報清單（此處為雨量站的淹水警報解除），共 14 則。</sub></td>
<td valign="top"><sub><b>事件詳情。</b>標語：「閱讀詳細事件報告」。一則標示為「進行中・官方已確認」的事件報告，附有建議行動（遠離現場、尋找掩蔽、撥打 110）、官方說明、「提醒判斷」一行（事件不在任何有效警戒圈的提醒範圍內），以及「AI 分析：這起事件對我的影響」按鈕。</sub></td>
<td valign="top"><sub><b>家人。</b>標語：「邀請家人一起守護」。空狀態畫面（「災害來的時候，一個人知道不夠」），有「登入並邀請家人」（用 Apple 帳號，約 10 秒完成）與「輸入邀請碼加入」。說明文字指出位置分享由每個人自行決定，預設關閉。</sub></td>
</tr>
</table>

---

## 運作方式

使用者先宣告自己在意什麼——家人，以及有半徑與時段的守護地點。其餘一切都由此而來。

```
parallel fetch from ~10 providers
  → grid-based deduplication (EventClustering)
  → three-tier trust scoring
  → AlertPolicy: does this intersect the user's life circle?
  → notify (local / APNs)
  → archive after 7 days
```

`Services/EventPipeline.swift` 是整個 App 的核心。程式碼強制執行兩條規則，並在註解中說明：

- **`SafetyOverview` 與 `AlertPolicy` 是僅有的兩個判定入口，而且都必須讀取「未過濾」的
  事件集合。** 用已經過濾的資料去算安全狀態，會造成假性安心——隔壁正在起火，畫面卻亮綠燈。
- **人命相關的警示（火災、地震、颱風）絕不設在付費牆後面。** 該路徑上不會執行任何付費檢查。

## 資料來源

每個 provider 都在檔案開頭註明它如何與其他來源互補，讓覆蓋範圍盡量不重疊。

| Provider | 來源 | 形式 |
|---|---|---|
| `NCDRPointEventProvider` / `NCDRRegionAlertProvider` | 國家災害防救科技中心 | 點狀事件＋區域警報 |
| `CWARegionAlertProvider` | 中央氣象署 | 地震報告、天氣警特報 |
| `NFAIncidentProvider` | 內政部消防署 | 全國事件 |
| `CityFireIncidentProvider` | 16 個縣市消防局 | 粒度最細（約 300 公尺） |
| `TaichungFireEventProvider` | 臺中市政府消防局 | 獨立實作 |
| `FreewayIncidentProvider` | 高速公路局 | 國道事件 |
| `AirQualityEventProvider` | 環境部 | 空氣品質 |
| `NewsEventProvider` | 主要新聞媒體 | 規則優先，LLM 只補缺口 |

App 從不直接連到這些網站。由一台自架的中繼爬蟲將所有資料來源正規化，因此單一縣市網站壞掉
不會讓 App 卡住。`AlertSourceHealthService` 會為每個來源維護一份健康狀態快照。

`CrimeReferenceService` 會讀取治安統計，但刻意**不會**依此發出警示——把事後統計當成通知
推播，只會製造焦慮。

## 主要畫面

| 分頁 | 檔案 | 用途 |
|---|---|---|
| 安心（首頁） | `Views/Home/HomeStatusView.swift` | 安全狀態總覽與提醒中心 |
| 安全地圖 | `Views/Map/SafetyMapView.swift` | 警戒半徑、事件圖釘、環境圖層 |
| 家人 | `Views/Family/FamilyHubView.swift` | 成員、生活圈、即時位置、「我平安」回報 |

## 隱私與安全

- **住家地址在儲存前以 AES-GCM 加密**（`AddressCrypto`）。
- **Widget 擴充從不直接讀取位置或地址資料。** 它只從 App Group 快照繪製畫面，
  所以 Widget 的程式碼無法接觸敏感資料。
- **Firestore 規則把所有家人資料限定在圈內成員。** 讀取需要成員資格；每位成員只能
  寫入自己的位置與狀態文件。見 `firestore.rules`。
- **用戶端不內建任何 LLM 金鑰。** AI 助理呼叫的是伺服器端代理；App 不持有任何上游金鑰。
- 遠端設定只能改變資料與設定——絕不能改變可執行程式碼——以符合 App Store Guideline 2.5.2。

## 技術

Swift · SwiftUI · SwiftData · MapKit · WidgetKit · StoreKit 2 · BGTaskScheduler ·
Firebase (Auth with Sign in with Apple, Firestore, FCM) · fastlane and the App Store
Connect API for submission.

Roughly 20,800 lines of Swift across 105 files.

（約 20,800 行 Swift，分布在 105 個檔案。）

## 開發方式

除了第一點，以下每一點都能在此 repo 中查證。

- **用 Claude Code 開發，先定骨架。** 作者自己決定需求、使用者流程與技術棧，並和 Claude 反覆討論，定成專案的規則與規格；之後才讓 Claude Code 在這個骨架內逐項實作。
- **`AGENTS.md`** 是給 AI 協作者的工作規則：產品底線（非緊急服務聲明、位置分享須自願開啟、
  狀態不能只靠顏色表達）與工程慣例。
- **Swift 程式碼改動後以 `xcodebuild` 驗證建置**，這是 `AGENTS.md` 的要求。
- **22 個 UI 測試**（`HavenCircleUITests/HavenCircleUITests.swift` 中的 `func test…`）。
- **約 200 個 commit**，逐日的開發紀錄在 `SESSION_NOTES.md`。

## Repo 結構

```
HavenCircle/            main app target
HavenCircleWidget/      widget extension
docs/                   design, UX, data-source and App Store notes (Chinese)
  appstore/             submission material and review checklists
  ux/                   user-flow studies and walkthrough reports
  data-sources/         per-source research notes
  engineering/          push and CloudKit setup notes
  planning/             development and monetization plans
fastlane/               build and submission lanes
website/                marketing site and server-side endpoints
tools/                  crawler and maintenance scripts
test/                   test fixtures
AGENTS.md               working agreement for AI contributors
SESSION_NOTES.md        development log
```

## 建置

需要 Xcode（含 iOS 17.0+ SDK）與一個 Firebase 專案。

```bash
open HavenCircle.xcodeproj
```

`GoogleService-Info.plist` 是刻意提交的。它不含機密：Firebase iOS 設定是公開的用戶端識別碼，
本來就會包在每個發佈的 `.ipa` 裡，存取控制由此 repo 中的 Firestore 安全規則負責，而不是靠
藏起這個檔案。真正的機密——APNs `.p8` 金鑰、service account JSON、簽章憑證——都已列入
gitignore，絕不會進入 repo。

## 關於語言

App 介面與 `docs/` 底下的大部分文件都以繁體中文撰寫，因為產品服務台灣、資料來源也以中文
發布。英文版 README 是為了讓海外讀者了解專案而寫；程式碼與共用模組中的註解以英文撰寫。
