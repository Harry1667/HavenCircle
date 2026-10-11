# SESSION_NOTES

## 2026-10-10〜12（效能＋地圖範圍＋事件去重＋晴空湖水外觀＋家人互動＋背景位置大修；TF 1.3 build 2→5）

### ✅ 完成
- **卡頓修復**：地圖聚合門檻 1.5°→0.12°、只算可視範圍；新聞 provider 移出主執行緒並行抓取；冷啟動忙碌 9s→約 3s。
- **地圖顯示範圍**：本人＋家人所在縣市（可在地圖膠囊右側選單切換 家人／只有我／全台），縣界金色描邊；事件縣市以地點文字優先判定（修海上／離島座標誤判）。
- **事件去重與封存**：同類型 1.5km／6h 合併（官方逐案來源彼此不合併），72h 封存、14 天刪除；599→172 筆。
- **家人互動**：一鍵「我平安」卡、通知權限先說明再問、請回報平安／求助通知按鈕、「收到 ❤️」回推寄件者、點通知直達該則回報；伺服器 family_push.php 補報平安推播與已讀回推、修正離開被當成到達。
- **外觀**：晴空湖水為唯一配色（層次已移除），動態頁頁首天空隨時段變色；深淺色全面對比稽核修正；設定頂端仿原生 Apple 帳號列。
- **地圖圖例**移到工具列 ⓘ；**示範與開發**改為隱藏（關於頁連點版本號 7 下）。
- **背景位置（10/11 晚）**：實機 iOS 27、權限「永遠」下 App 進背景數十秒就被掛起，5 分鐘心跳全停。
  - `CLBackgroundActivitySession` 可持續跑但必出藍色膠囊 → 使用者選「背景靜默優先」，改用**移動圍欄**（150m，走出即喚醒上傳並重畫）。iPad 模擬移動兩次、iPhone 實際外出皆驗證移動中約每 300–500m 一筆。
  - 靜止的人靠伺服器靜默推播約每 30 分鐘補時間戳；家人端超過 15 分鐘但最後是靜止的，1 小時內顯示「靜止中・最後確認 X 分鐘前」（仍不參與警報判斷）。
- **Threads 治安觀察器**：24h 試跑只 1 件真事件，決定不做；已停機、刪原始貼文（見 memory threads-source-dropped）。
- TestFlight：1.3 (2)(3)(4)(5) 皆已上傳；最新提交 `ee04331` 已推 GitHub。

### 🔄 未完成 / 待決
- **iPad 要手動開一次安心圈**：10/12 00:2x 裝新版時鎖屏沒能自動重開，開過背景位置才接上。
- **實機還沒看到「靜止中」文案**：兩台剛更新，等靜止超過 15 分鐘後到家人頁確認。
- **雙機互動未實測**：收到 ❤️ 按鈕、通知上的動作按鈕、點通知 deep link（需兩台同時在手邊、解鎖）。
- **UI 自動化在兩台實機都起不來**（Timed out while enabling automation mode，解鎖也一樣）；暫用 `devicectl process launch --console` 讀 print 診斷。可能要重開裝置或重新信任。
- 待使用者決定：深色模式未選分頁的灰字要不要調亮；動態頁「未驗證線索」「附近動態」淡字要不要維持。
- 使用者「設定你的名字」尚未設定；兩台的自動鎖定記得還原。

### 下次起點
1. 兩台更新到 TF 1.3 (5)，iPad 打開一次 App。
2. 查伺服器 `locations` 更新節奏（scratchpad 的 locq2.php 做法：scp 到 /tmp 後 `sudo -u www php`），確認靜止時約 30 分鐘一筆、移動時圍欄喚醒正常。
3. 家人頁實機確認「靜止中」文案，再做雙機互動測試。

### ⚠️ 環境備忘（新增）
- Firestore `locations` 的 `updatedAt` 由 PHP 函式庫解成**整數秒**，不是字串。
- `devicectl device install app` 會終止 App；裝置鎖屏時 `process launch` 失敗，背景定位要等使用者自己開 App 才恢復。
- `devicectl device simulate location coordinate --latitude --longitude` 可在背景觸發圍欄事件（`clear` 還原）。
- zsh 裡 `echo ===` 會報「== not found」，分隔線改用 `echo '---'`。

## 2026-07-27〜28（付費牆整頁化＋上架素材生產線＋ASC 送審實戰陪跑；TF build 07271029）

> 完整技術細節見新 skill：`harry-havencircle-appstore-metadata`（年齡分級/fastlane metadata API/內容版權）、
> `harry-havencircle-screenshot-pipeline`（Beacon 風格行銷截圖生產線）；`harry-havencircle-oracle` 補了網站部署段落。

### ✅ 完成
- **付費牆重新設計＋整頁化**（多輪迭代）：從半頁 sheet 改成 `.fullScreenCover`（4 個入口＋DEBUG 截圖入口全改），Beacon 風格視覺（漸層 hero 卡、2×2 圖示解鎖網格、主推大卡＋精簡雙卡）、修掉商品讀取失敗時拼出「／年」破碎文字的 bug。
- **地圖連續點兩個事件的 bug**：`SafetyMapView.swift` 的 marker 點擊直接覆寫 `selected` 是 SwiftUI `.sheet(item:)` 經典坑，仿現有 `selectedCluster→selected` 的 nil-then-delay pattern 修掉。
- **StoreKit 本機測試**：試過用 `SKTestSession` 在 App 內強制吃本機 `.storekit`（想解決「沒用 Xcode Run 啟動就讀不到本機測試價格」），**結果閃退，已完整回退**——SKTestSession 仍然依賴 Xcode 啟動時的橋接環境，此路不通。改用更安全的作法：DEBUG 版只要商品讀取真的失敗就自動退回靜態展示價格（不管什麼原因），Release 版完全不受影響。
- **App Store 上架申報清理**：定位權限說明文字（還寫著舊 iCloud 說法）、程式碼裡殘留的 CKShare 過時註解、官網（index.html + pitch/index.html）所有 CloudKit/CKShare 字樣，全部改成 Firebase 現況；AppIcon 補了 dark/tinted 兩個變體（用 sips 從主圖產生，暫時堪用版）。
- **移除「演練」功能**：使用者確認後拿掉 `EventListView` 的「演練」按鈕與整個 `DrillView.swift`（這是正式產品功能不是測試殘留，但使用者決定不要了）。
- **TestFlight 上傳**：`fastlane beta` 成功，build `07271029`。
- **App Store 行銷截圖生產線**（iPhone 1320×2868 + iPad 2064×2752，各 5 張，Beacon 風格）：HTML/CSS 樣板（暗色底＋金色發光外框＋Noto Serif TC 900 粗體標題，跟官網同字體）用 **headless Chrome 直接 render**（gstack browse daemon 卡死時的備援路徑，見新 skill）。截圖內容一度卡在「地圖鏡頭定位跑到歐洲/舊金山」「系統定位權限彈窗擋死自動化流程且 `simctl privacy grant` 對這個彈窗完全不生效」，最後解法：① 加 DEBUG-only `--skip-location-prompt` 旗標＋讓 `UserAnnotation()` 在該旗標下不畫（MapKit 的這個元件會繞過 App 自己的權限請求直接跟系統要權限）；② 卡住的彈窗是模擬器層級的佇列問題，完整 `simctl shutdown`+重開機才清得掉，光 uninstall/reinstall 沒用。
- **示範事件內容真實化**：使用者要求把行銷截圖裡的示範事件從「【測試】聯結車撞機車」換成真實發生過的「中山站持刀攻擊」事件（2025-12-19 張文台北車站/中山站隨機攻擊案，4死11傷）。**倫理裁決**：不用真實死傷數字與加害者姓名，改用類似 Beacon 自家截圖的模糊化寫法（地點＋事件類型＋官方已確認＋避難建議）。技術上用「暫時改 `SixDisasterScenario.swift`（含 sourceName 欄位，不只 title）→截圖→`git checkout` 完整還原」的模式，兩次都有確認 diff 乾淨。
- **官網部署**：SSH 到 Oracle（`ubuntu@137.131.7.230`），確認網站根目錄是 `www:www` 擁有、`ubuntu` 有 `NOPASSWD: ALL` sudo，走「sudo 備份→scp 到 /tmp→sudo mv 進正式目錄→sudo chown www:www」流程，部署後 curl 驗證正式網址內容。
- **App Store Connect metadata 直接用 API 寫入**：發現使用者手上的 App Store Connect API 金鑰（本來只給 fastlane beta 用）其實可以拿來寫 metadata，不只上傳 build。新增 `fastlane` 的 `metadata` lane（`upload_to_app_store` + `skip_screenshots: true` + `skip_binary_upload: true` + `submit_for_review: false`），把名稱/副標題/描述/關鍵字/URL/版權/審查備註一次寫進 ASC，precheck 9 項全過。**唯一失敗項**：審查備註（App Review Notes）上傳報錯 `Error fetching app store review detail - No data`，懷疑要先填聯絡人姓名/電話/信箱，使用者還沒提供，待補。
- **年齡分級問卷陪跑**（Apple 新版 7 步驟精靈，非舊版單頁勾選表）：因為 App 的新聞爬蟲會抓到真實社會案件（含上面的中山事件），「驚悚/恐怖題材」「現實暴力」「槍支或其他武器」不能選「無」，改選「偶爾」；「使用者生成內容」「社群媒體」「傳訊和聊天」選「否」；「醫療或保健」整段不適用選「無/否」。**踩過一個坑**：一度建議「對未滿13歲的使用者停用社群媒體」在被強制要求回答時選「是」，結果系統判定「你說有停用=你有社群媒體」，跟「社群媒體=否」互相矛盾跳出紅色驗證錯誤——已更正為統一選「否」（因為根本沒有社群媒體功能，不是「停用」的問題）。最終計算結果 13+（含中山事件的暴力/恐怖內容因子後的合理結果，不是 4+）。
- **App 內購買項目確認**：`plus.lifetime` 已建好，Product ID 跟 `EntitlementStore.swift` 完全一致，家人共享已開啟；「無法提交以供審查」是正常現象（IAP 要跟 App 版本一起送，不能單獨送），不是設定錯誤。

### 🔄 未完成 / 待決
- **審查備註**：ASC 上傳失敗那項，等使用者提供聯絡姓名/電話/信箱，或使用者自己去網頁貼（內容在 `fastlane/metadata/review_information/notes.txt`）。
- **年齡分級第4、6步**：使用者自己填過去沒截圖給我看，最終13+結果合理但沒有逐步覆核，有需要可回頭補看。
- **另外兩個 IAP**（monthly/yearly）：不確定是否已建，需使用者確認。
- **隱私問卷、真機回歸測試（`docs/appstore/真機回歸檢查表.md` 23條，#19 production 推播最重要）**：使用者說要去填/去測，未回報完成。
- **iPad 截圖是否已上傳 ASC**：使用者只截圖確認過 iPhone 那組，iPad 分頁待確認。
- **內容版權問卷（App是否包含第三方內容）**：討論到新聞爬蟲有 verbatim 標題退回路徑的風險，尚未決定要不要動 `NewsEventProvider.swift` 拿掉退回顯示原始標題的邏輯（使用者還沒回覆要不要改）。

### ⚠️ 環境備忘（新增）
- **`xcrun simctl privacy grant location*` 對 `requestWhenInUseAuthorization`/`requestAlwaysAuthorization` 觸發的系統彈窗完全不生效**，這個彈窗一旦卡住，只有整台模擬器 `shutdown`→重開機能清掉，`uninstall`/`reinstall` 沒用。
- **MapKit 的 `UserAnnotation()` 會繞過 App 自己的 `CLLocationManager` 請求邏輯**，只要畫在 `Map{}` 裡就會自動跟系統要權限，App 層的旗標/guard 攔不住，只能讓它在截圖模式下乾脆不畫。
- **gstack `browse` daemon 在這台機器上會卡死**（`browse status`/`goto` 掛住不回應），備援方案：直接呼叫 `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --disable-gpu --no-sandbox --window-size=W,H --screenshot=out.png --virtual-time-budget=4000 file://...html`，一次性行程、不需要常駐 daemon，穩定很多。
- **App Store Connect 的 API 金鑰（fastlane 用的那把）不只能上傳 build，也能寫 metadata**：`upload_to_app_store` 搭配 `skip_screenshots`/`skip_binary_upload`/`submit_for_review: false` 可以安全地只更新文字欄位，不會動到使用者手動傳的截圖或誤觸送審。
- **Apple 年齡分級問卷已經是新版 7 步驟精靈**，不是舊版單頁勾選表；`~/.claude/skills` 舊文件裡「問卷全部『無』→4+」的假設已過時，要照 App 實際內容逐題答，不能套公式。

## 2026-07-24（上架準備＋付費牆＋走查修復大批；TF 最終 build 07241320）

> 完整 durable 設計裁決見 memory：`havencircle-ux-conventions`（術語/一地點一圈/我平安不變式/膠囊誠實態）、`havencircle-appstore-submission`、`havencircle-crawler-pipeline`、`havencircle-monetization-verdict`。

### ✅ 完成
- **上架申報三件套**（commit `baf8cc0`）：PrivacyInfo.xcprivacy 重寫為 Firebase 真實申報（精確位置/姓名/Email/UserID 連結身分＋裝置ID/產品互動不連結，全不追蹤）；`docs/appstore/ASC隱私問卷答案.md`（你照填）；`docs/appstore/AppStore上架素材.md`（描述/關鍵字/雙語審查備註）；隱私政策/條款/用戶協議部署 havencircle.looptw.com（新目錄頁，舊根 .html 轉址）；App 內 webURL 跟進。
- **爬蟲提速＋延遲埋點**（commit `58464cb`，遠端已生效有 .bak-0724）：NCDR 2→1 分鐘、CWA 10→5 分鐘；事件加 source_published_at/fetched_at，ingest.php 寫 latency.log（實測爬蟲→Oracle 落地約 1 秒）。**既有 bug 未修**：ingest 即推的 exec() 被主機 disable_functions 停用，推播靠每分鐘 cron 兜底。
- **付費牆**：三方案（月90/年690+14天試用/終身1490）；EntitlementStore/FreeTier/.storekit 齊；視覺重設計一屏完整＋信任錨（commit `c7facb8`）；DEBUG `--show-paywall` 截圖模式產 IAP 審查圖（`docs/appstore/screenshots/iap/`）。
- **20 人冷啟動走查**（`docs/ux/冷啟動走查報告-2026-07-24.md`，推薦率 19/20）→ **12 類全修**（commit `eac81b2`，21 檔）：地圖膠囊三態誠實化（無圈灰「尚未設定」不再假性安心）、靜音確認框＋常駐提示、圈色冷色系＋圈旁標名、圖例文字膠囊＋首展、未登入邀請鈕講成本、設定齒輪三頁統一、隱私承諾進 UI、字體大小四檔（Dynamic Type）、提醒「安靜→僅重大」消歧、絕不吵醒收起無效安靜時段、「啟用本機提醒→災害警報通知」＋確認框。
- **我平安保命級 P0**（deep-dive 揪出，含在 `eac81b2`）：postPing 回傳成敗＋8 秒 timeout（離線不卡死）；事件詳情頁未登入不再假成功；通知快速回報補回饋；補「需要協助」按鈕＋成功提示＋防連點。
- **額度模型收斂「一地點一圈」**（含在 `eac81b2`）：MemberDetailView 收掉無閘門加圈入口；scheduleCircleEditor guard isPlace 堵漏；新增地點取消不留孤兒＋不誤佔額度誤觸付費；CircleEditorView 內嵌小地圖長按放 pin＋畫圈預覽。
- **動作按鈕文字統一置中**（commit `fd51a5f`，7 檔）：帶圖示的清單/表單動作列補 maxWidth 置中；CTA 大多本來就置中未動。

### 🔄 未完成 / 待決
- **你（ASC 後台）**：填隱私問卷（答案表已備）、簽付費合約→建 3 個 IAP 商品（本地化文案已給，審查截圖在 iap/）、真機跑 `docs/appstore/真機回歸檢查表.md`（23 條，第19 production 推播最重要）。
- **設定頁三顆按鈕（升級Guardian+/刪除帳號/重看導覽）是否置中**：我判斷維持靠左（跟設定選單列一致），等你點頭；不回＝維持現狀。
- **我平安 P1（家人端伺服器主動推播）**：卡 Blaze（Cloud Function 或走 Oracle 中繼），同 TTL 一起等 Blaze。
- **TTL 政策**：仍卡 Blaze（Spark 免費方案 billing disabled），recipe 已記 memory。
- HomeStatusView 首頁回報按鈕未接 SignInGate（下輪補）；上架 store 截圖此批 UX 後已過時要重拍。

### ⚠️ 環境備忘
- fastlane beta 要帶 `ASC_KEY_ID=BY34254SVJ ASC_ISSUER_ID=e473f18e-d7f2-40c6-a7b7-e69ae833566b`（不帶會報缺變數）；build 號＝時間戳 MMddHHmm。
- 截圖定式：DEBUG `--start-tab 0/2/3`＋`simctl spawn defaults write` 設 onboarding 旗標逐條（zsh 迴圈不斷詞）；付費牆 `--show-paywall`。**別用 AppleScript/cliclick 合成點擊**（屢敗）。
- 模擬器 7A6A09FE（iPhone 17 Pro Max）常自己 Shutdown→boot 要等 15-18 秒；install+多旗標指令易逾時，拆步驟跑。
- **多 agent 並行紀律**：每檔只讓一個 agent 寫、各用獨立 DerivedData（DD-mapfix/DD-quotafix…）、全樹整合 build 由主對話自跑驗收、名單式 git add（不用 -A）。部分 agent 會卡在等自己 build 的 Monitor 不回報——主對話直接自己整合 build 驗收即可。

## 2026-07-23（用戶流程重構動工日：#2–#8 全部完成＋使用者實測回饋六項落地）

### ✅ 完成（細節見專案 memory `havencircle-onboarding-redesign` 六批記錄）
- **#2 密度驗證**：賭注1不成立（30天歷史不存在、新聞無座標）→A2 改向；賭注1b 成立；避難所 JSON 清洗 239 筆錯置座標（6152→5913）。結果在 `用戶流程重構思.md` §0.1。
- **20 人模擬走查**（`模擬走查報告.md`＋劇本 `App完整體驗腳本.md`）：三激進取捨判定、五大死點，修正全數寫回 `目標用戶流程.md`（含設計紀律六條、D 骨架展開、動工順序修訂）。
- **#3–#7 實裝**：A1 著陸瘦身（刪開場白＋刪確認步自動前進）、A2/A3 三件套＋保底帶領、D1+D2 安心頁雙狀態＋事件串（刪背景看守列）、A4 通知情境卡（App 內模擬示範）、D4 通知自主權（吵醒門檻/安靜時段/一鍵靜音/重問通道）、身分方塊加「其他稱呼」。
- **#8 D3 家人頁重寫**：刪 segment、以人為中心、空狀態情境引導、SignInPreflight 登入前置卡（登入永不突襲、成功自動續作）、C3 身分接回（建圈/入圈成功跳六方塊）。
- **重大 bug 修復**：①設定頁 Apple 登入按鈕是假的（無 nonce 不接 AuthService；登出也是假的）——家人頁所有 gate 導向死路的根因；②首次進地圖鏡頭與圈心校正脫鉤（isFirstRunSession 重取景）；③跟隨圈誤吃 .live 15 分鐘過期規則（isActiveForAlerts 加 !isFollowMe）；④SLC 不觸發時開 App 不校正跟隨圈（ShareAcceptance 前景啟動主動取位）。
- **使用者實測六項裁決落地**：避難所 pin 撤預設、「附近」=10km（NearbyScope 單一常數）、預設圈=跟隨圈「我的身邊」（關=留原地變固定圈）、地點命名點選（PlaceSelectView 方塊）、調半徑改滑桿面板（拖把手整套刪除）、位置分享與即時圈拆分（FollowCircleToggleSection 免登入）。

### 🔄 未完成/殘留
- SafetyCheckInView 內「前往設定查看帳號」舊死路（觸發面已縮小）；「隱藏相似提醒」只擋 UI 不擋通知（既有缺口）；地點 emoji 未存（model 無欄位）；跟隨圈改名會讓開關失聯（現無改名入口）。
- Apple 登入端到端（模擬器需 Apple ID）、多人態畫面、A4 卡片實機動線——待使用者實測回報。
- 動工順序 #9–#13：家人閉環 S 批（B1/B2 強化/受邀通道/情境邀請）→C4 慶祝推播→C2 帳號設計稿→F 週報→E 颱風 CTA。

### ⚠️ 環境備忘
- bundle ID 已改 `com.gomiigo.HavenCircleApp`（舊 CamMenuApp 失效）；`--start-tab` 1=安心 2=地圖 3=家人；`--force-onboarding` 會釘住著陸頁；模擬器定位偶發釘死舊金山→shutdown+boot 後再 set；PATH 的 python3 是壞的 3.5，用 `/usr/bin/python3`。
- 本次 commit 含四個「混有另一 session 早前 cosmetic hunks」的檔案（SafetyMapView/HomeStatusView/SettingsView/LiveCircleSharingSection）——無法事後拆 hunk，已隨今日多輪 Debug build＋截圖驗證；SixDisasterScenario/HavenCircleWidget 未收（另一 session 的、未經驗證）。

## 2026-07-22（本場跨 07-20 深夜～07-22，同一長 session）

### ✅ 本次完成
- **Firebase 家庭圈重構收尾＋上 TF**：commit `c4a2775`（20 檔，只提自己的檔）；TestFlight 建置 `07201511` 上傳成功。
- **新手流程整條重做**（多輪迭代，全部編譯過＋能截圖的都截圖驗證）：
  - 著陸：乾淨地圖定位台北車站→點畫面才索定位；拒絕退台北車站＋溫和引導（`WelcomeMapView`）。
  - 首次進地圖：自動建「本人」＋預設 1 公里圈（`FirstRunSetup`），落在地圖分頁。
  - 帶領改「目標自己動」：聲納脈動圈＋膠囊短標籤（`PulseRing`），拿掉文字卡（使用者嫌蠢）；附近 2.5km 無事件就跳過事件段。
  - 拖圈：點自己的圈→圈邊拖把手改半徑 200–5000m（`SafetyMapView` 加 MapReader/proxy.convert）。教學改「第一次點事件關掉後」才提示一次。
  - 分頁一句話介紹（點畫面即關）；選身分六方塊（統一黃臉）**已解耦**成獨立元件，待家人介面重寫再接回。
  - 設定→示範與開發加「重跑新手流程」按鈕（DEBUG）。
- **三份流程文檔**：`原始用戶流程.md`（改版前逐字還原）、`App用戶流程.md`（現況全 App）、`新手流程說明.md`（新手細節）。
- **用戶流程重構思 v3**（`用戶流程重構思.md`）：走完五問→三版分歧→premortem→收斂→**對抗驗收（抓到深連結自相矛盾/匿名帳號藏 L 級/避難所保底沒驗證）**→使用者審查（家人閉環資源錯配，補受邀通道/慶祝閉環/情境邀請/north star 換互報家庭數/平時心跳）。
- **拍板**：平時心跳＝**週報**（三護欄：不動警報信任額度/沒事也發/通知關閉率護欄指標）；颱風 CTA 歸核心警報迴圈 backlog；north star＝「≥2 人且完成首次互報的家庭數」。
- **`目標用戶流程.md`**：完整目標流程 A–F 六條線，每步標 [現有]/[改]/[新]，供使用者修改。
- **動工 #1 漏斗埋點**：8 個事件已埋進現有畫面（landing shown/tapped、location granted/denied、onboarding_completed、guidance started/finished、adjust hint/adjusted、tab_intro×2），BUILD SUCCEEDED。

### 🔄 未完成 / 進行中
- 使用者要改 `目標用戶流程.md`（等回饋）。
- 動工順序 #2–#9：資料密度驗證（1/1b）→地圖鋪真實資料→通知情境卡→家人閉環 S 級一批→慶祝推播→帳號設計稿（L）→週報→颱風 CTA。
- **本場所有新手流程改動未 commit**（含 dirty 檔 `SafetyMapView`/`SettingsView` 裡我的 hunk 與另一 session 未提交改動混在一起——commit 必須 `git add -p` 挑 hunk）。
- 舊教學（OnboardingView/FeatureTour）仍是死碼；設定頁「重看」兩按鈕還指向它們。
- 實機未驗：拖圈手感、真實冷啟動全鏈路、Firebase 登入/邀請碼端到端（TF 07201511 可測）。

### 💡 重要決策 / 發現
- 「能學習的功能優先於不能學習的」（使用者拍板判準，一年五個樣本的功能無法迭代）。
- 提案自檢新項：**宣稱的核心 vs 量級分佈要一致**（對抗驗收員驗可執行性，使用者抓到的是資源錯配——兩層不同）。
- 模擬器只有 iPhone 17/iOS 26.5 可用（UDID 67B28D8A-…），`name=iPhone 15` 會 destination 失敗。
- 受邀深連結不做：LINE 攔 Universal Link＋基礎設施不存在＋剪貼簿讀取跳系統提示；8 碼優化先收數據。

### 🚀 下次起點
1. 看使用者對 `目標用戶流程.md` 的修改 → 調整後執行動工 #2「資料密度驗證」（抽 10 城鄉座標算首屏視野內 30 天事件數＋6 個極端座標算最近避難所距離——查資料即可，不用寫 App 碼）。
2. 或使用者說 commit：`git add -p` 只挑自己 hunk（SafetyMapView 的 MapReader/拖把手/脈動帶領/埋點段、SettingsView 的重跑按鈕＋resetOnboarding），新檔可整檔 add。

### 📁 相關檔案
- 新增：`HavenCircle/Views/Onboarding/{WelcomeMapView,WelcomeFlowView,RoleSelectView,FirstRunSetup,FirstRunCoach}.swift`
- 修改：`ContentView.swift`、`AppTabs.swift`、`SettingsKeys.swift`、`HavenCircleApp.swift`、`SafetyMapView.swift`（dirty！）、`SettingsView.swift`（dirty！）
- 文檔：`目標用戶流程.md`、`用戶流程重構思.md`（v3）、`App用戶流程.md`、`原始用戶流程.md`、`新手流程說明.md`

## 2026-07-20

### 完成事項：修復「推播完全收不到」（實機 iPhone 12 端到端驗證通過）

症狀：不論官方警報或新聞危險，手機從來收不到通知。逐層排查後發現是**三個真 bug 疊加**（commit `f65068d`，只列名提交 3 檔，未動另一 session 的外來檔）：

1. **Firebase AppDelegate Proxy 吞掉 APNs 註冊回呼**
   - SwiftUI `@UIApplicationDelegateAdaptor` + Firebase swizzling 下，`didRegisterForRemoteNotificationsWithDeviceToken` 沒被轉發給 App 的方法 → APNs 權杖從未上傳中繼站 → 伺服器根本不知道這台裝置。
   - 判斷式：log 有「已取得 FCM 註冊權杖」卻**沒有**「已取得 APNs 裝置權杖」＝ didRegister 沒觸發。
   - 修法：`Info.plist` 設 `FirebaseAppDelegateProxyEnabled=NO`，改手動整合（`ShareAcceptance.swift` 已自設 delegate/apnsToken，並在 `didReceiveRemoteNotification` 補呼叫 `appDidReceiveMessage`）。

2. **FCM 對 Debug(sandbox) 裝置用 production APNs 閘道 → 靜默丟包**
   - FCM 回 `ok` 但收不到；原生 APNs 直發（明確走 sandbox）卻收得到 → 環境判定錯。
   - 修法：依 build 型態 `setAPNSToken(deviceToken, type: .sandbox/.prod)`（取代 `apnsToken =` 的自動判定）。

3. **FCM 訂閱快取未隨權杖更新（drift）**
   - 權杖一換，Google 端舊主題訂閱全失效，但本機「已訂閱 hc_all」旗標還在 → `sync()` 誤判無變動跳過 → 從沒真的訂上。
   - 判斷式：log 從頭到尾沒有「FCM 主題同步：共訂閱 N 個主題」。
   - 修法：新增 `FCMTopicSync.resync()`，於 `didReceiveRegistrationToken`（權杖刷新）時清快取強制重訂。

驗證：實機用 `xcodebuild`＋`devicectl` 乾淨重裝；盯伺服器 `tokens.json` 確認新權杖登記；hc_all 全台廣播＋文山區按區精準兩發 FCM 皆成功送達並顯示（log 見 `共訂閱 3 個主題`＋兩則到達）。HEAD 已 stash 外來檔獨立編譯通過。

### 除錯環境筆記（下次可複用）
- Oracle：`ssh -i ~/Documents/important\ file/ssh-key-2026-04-08.key ubuntu@137.131.7.230`，apns 檔在 `/www/wwwroot/havencircle.looptw.com/apns/`，`sudo -n -u www php ...` 跑腳本；發測試推播用 `_fcm_lib.php`/`_apns_lib.php`。
- 讀裝置 log：`idevicesyslog`（brew libimobiledevice）**抓不到 os.Logger/print**；`log collect --device-udid` 要 root。最可靠是**從 Xcode 跑**看 console，或**盯伺服器 tokens.json**當註冊成功的訊號。
- zsh 有 `log` 別名會攔截 `log` 指令，要用 `/usr/bin/log`。

### 未完成 / 下次起點
- **上架前務必驗 production 環境**：目前只驗過 Debug(sandbox)。TestFlight/App Store 版走 `.prod` 分支＋production APNs，需另測一次真的收得到。
- 手機上跑的乾淨版建議再從 Xcode Run 一次（前一版帶過除錯 log，已移除）。
- 天災只有縣級（無區，如堰塞湖）目前不推 → 可加縣級 FCM 主題補上（既有待辦）。

## 2026-07-15

### 完成事項

**規劃**
- 產品功能缺口分析（10 項），寫入對話並整理成 `DEVELOPMENT_PLAN.md`（6 階段規劃）
- 後端決策定案：CloudKit + CKShare（使用者選定）

**階段 0–3 全部完成**（每階段一個 commit，均通過 xcodebuild 與模擬器驗證）
- 階段 0（`a72fad8`）：單檔原型拆為 Models/Views/Services/Support；修 try!、假暫停旗標、刪除索引 bug、alertTypes 改陣列
- 階段 1（`1e83eca`）：AlertPolicy 集中提醒決策（含「為何收到」理由）、事件狀態機＋解除通知、每日安全摘要、演練模式、資料時效標示、SmokeTest 冒煙掛鉤
- 階段 2（`2beb2e0`）：EventPipeline mock 資料管線（去重/可信度評分/生活圈比對，SwiftData 實測通過）、RegionAlert 行政區災害層、內嵌雙北緊急資源 JSON、HistoryView 區域回顧
- 階段 3（`b5aaf69`）：FamilySyncService（CloudKit 自訂 zone + CKShare）、SafetyCheckInView 安否回報＋已讀回條、CloudSharingSheet 邀請、share 接受的 scene delegate；修掉兩個根因 bug——SwiftData 誤試 CloudKit 鏡像（設 `cloudKitDatabase: .none`）、降級鏈漏刪 -wal/-shm

**介面優化（使用者逐項驗收）**
- 第一批（`5019271`）：修「需要注意」分類與標籤不符 bug、事件摘要補齊（歸屬＋相對時間）、地圖家人切換器、鏡頭 .automatic、暫停狀態可見性
- 第二批（`689cf7b`）：半版事件摘要（presentationDetents）、家人頁邀請捷徑（TabRouter）、Onboarding 地址搜尋＋行政區自動判斷
- 導航重整（`db391c8`）：分頁改〔提醒中心｜回顧｜安全地圖(置中/預設)｜家人｜設定〕、地圖全螢幕化（浮層＋底部橫向卡片）、圖層與過濾選單、家人＋安否合併為 FamilyHubView
- 提醒中心加回精簡地圖卡 EventsMiniMap（`afd4ab8`）
- View 層移除 os Logger 直接依賴（`73a8296`），根治 Xcode 索引誤報

### 後端資料源規劃與官網上線（同日第二段工作）

**政府災害資料接取規劃**
- 撰寫 `GOVERNMENT_DATA_SOURCES.md`（已實際上網查證，非憑記憶）：
  - **NCDR 民生示警平台**為主幹——免申請、CAP 格式，一次涵蓋火災/地震/颱風/淹水等 43 項示警；即時火災走這裡的 `NFA_Fire`，不必接消防局
  - **CWA 中央氣象署開放資料**——需免費註冊拿授權碼，補充精細地震規模/颱風路徑
  - **消防局無即時火災 API**（只有網頁與年度統計，已查證確認）
  - **data.gov.tw**——抓避難所等靜態清單
  - **架構建議**：用現有 Oracle 機器當中間層（抓資料→解析→去重→存 JSON→發 APNs）；隱私設計＝App 只上傳「關心的行政區」不上傳住址；分兩步（先 pull 拿真資料、後加背景 APNs 推播）
  - 附斷網降級（離線橫幅）與通知去重（同區短時合併）的具體修改建議

**官網上線**
- `website/`（純靜態 HTML/CSS/JS）部署到 https://havencircle.looptw.com ，用 `001-deploy-docs` skill
- 站點/SSL/Nginx 在 aaPanel 已預建好，實際只需上傳檔案：rsync 上傳（Mac 內建 rsync 2.6.9 不支援 `--chown`，改上傳後 SSH `chown -R www:www`）
- **純靜態站不佔應用端口**，走 80/443；上傳後 `nginx -s reload` 才讓 443 生效（先 `nginx -t` 確認不影響其他 30+ 站）
- 驗證：HTTPS 回 HTTP/2 200、HTTP 301 轉址、三張截圖與 CSS/JS 全 200

### 未完成 / 已知問題

1. **CKShare 跨帳號流程未驗證**：需兩台不同 iCloud 帳號的實機＋已佈建 container。已知疑點：`FamilySyncService.markRead` 在成員端組 recordID 的 zone owner 可能不對（應改用 fetchPings 保留的原始 CKRecord.ID）。詳見 `CLOUDKIT_SETUP.md`
2. Xcode 編輯器可能殘留舊的 os import 誤報診斷（程式碼已根治），使用者端需 ⌘Q 重開 Xcode + ⌘B 清除
3. 階段 4（真實資料源：NCDR CAP / CWA / 消防開放資料＋APNs 推播）、階段 5（上線硬化）未開始
4. 生活圈只能新增不能編輯（原型限制，編輯＝刪除重建）

### 下次起點

- 優先：拿實機跑通階段 3 CloudKit 流程（照 `CLOUDKIT_SETUP.md` 設定），修 markRead zone 疑點
- 然後：階段 4 依 `GOVERNMENT_DATA_SOURCES.md`，建議先在 Oracle 上做「抓 NCDR 示警 → 整理成 JSON API」，App 端把 mock provider 換成拉真源（此步不用碰 APNs 就能讓真資料進 App），背景推播留到第二步
- 官網已上線 https://havencircle.looptw.com （純靜態，日後更新＝改 `website/` 後 rsync 覆蓋）
- 使用者可能的 UI 後續：地圖底部卡片改可收合、迷你地圖改唯讀跳轉（都已口頭提過選項，等使用者反饋）

### 技術備忘（本 session 驗證過的環境事實）

- 專案用 Xcode 16+ 同步資料夾（PBXFileSystemSynchronizedRootGroup），新增檔案不用改 pbxproj
- Swift 6.2 預設 MainActor + MemberImportVisibility：用 os Logger 插值的檔案必須自己 `import os`（View 層改走 AppLog 包裝已免疫）
- 驗證流程：`xcodebuild -project HavenCircle.xcodeproj -scheme HavenCircle -destination 'platform=iOS Simulator,id=58EB62E3-88E2-4827-B286-95382DD94AD7' build`（iPhone 17 Pro / iOS 26.5 模擬器）
- 冒煙測試（DEBUG）：`xcrun simctl launch <udid> com.gomiigo.CamMenuApp.HavenCircle --smoke-onboard --smoke-drill --smoke-cloud --start-tab <0-4>`；注意 simctl 背景啟動時 async Task 不會跑，`--smoke-cloud` 需前景
- log 查詢：`log show --predicate 'subsystem == "com.gomiigo.CamMenuApp.HavenCircle"'`（.info 級別要加 --info）
- SwiftData 資料庫直查：模擬器 App 容器內 `default.store`（sqlite3 可讀，表名 ZLOCALSAFETYEVENT 等）

## 2026-07-16

### 完成事項

**NCDR 會員註冊調查**
- 查證 `alerts.ncdr.nat.gov.tw` 會員註冊限制：僅受理公務/公司/學校信箱（gmail/yahoo 等會被拒），機關類別無「個人」選項
- 確認逢甲大學在校生信箱（`@o365.fcu.edu.tw`）符合格式，已用「企業學研」類別送出註冊，**目前卡在帳號審核，審核天數官方未公開**
- **重要發現**：這組會員審核只有在要用官方「示警查詢 API」拿 API Key、或訂閱推播服務時才需要。NCDR 平台的公開 CAP feed（`https://alerts.ncdr.nat.gov.tw/JSONAtomFeeds.ashx`）完全不用申請、不用等審核，現在就能直接抓，已實測成功

**爬蟲機建置：Mac Mini（A1347，i5-2415M，實為 2011 年丐版，非原先以為的 2012 年）**
- 機器已重灌 Linux Mint 22.3 XFCE（帳號 david），改造成專門跑爬蟲的無人值守機器
- 修好兩個原本擋住連線的問題：SSH 服務未啟動（`enable --now ssh`）、ufw 防火牆未放行 22 埠
- 設定 SSH 金鑰驗證取代密碼登入，私鑰放在 `/Users/harryhwa/Documents/important file/macmini-crawler-ssh/`（跟 aaPanel 私鑰同一慣例），控制電腦的 `~/.ssh/config` 設了 `Host macmini` 別名，直接 `ssh macmini` 免密碼連線
- 設定範圍限定的免密碼 sudo（僅 `systemctl`/`apt`/`apt-get`/`ufw`，其餘操作仍需密碼），設定檔在機器上的 `/etc/sudoers.d/david-automation`
- 鎖死系統睡眠/待機（`systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`），靜音 Mac 硬體開機提示音（改寫 EFI NVRAM 變數 `SystemAudioVolume`，備份存在機器上的 `~/systemaudiovolume_backup.txt`）
- 系統更新完成（387 個套件，含核心 `6.14.0-37` → `6.17.0-40`），已重開機驗證新核心正常開機、爬蟲排程不中斷
- **目錄慣例確立**：`~/crawlers/<專案>/<資料源>/`，先分專案、再分資料源，說明寫在機器上的 `~/crawlers/README.md`
- **HavenCircle 專案的 NCDR 爬蟲已完成並上線**：`~/crawlers/havencircle/ncdr/fetch_ncdr.py`（純 Python 標準函式庫，無額外依賴），過濾出跟家庭安全相關的類別（颱風/地震/海嘯/淹水/土石流/火災/豪雨/強風/高溫/停水/水庫放流/行動電話中斷/傳染病），已處理過真實資料源的怪癖（同一天偶爾多筆事件共用同一個 identifier 且 CAP 連結相同，已用 identifier 去重並記錄跳過筆數）。cron 每 5 分鐘執行一次，log 在 `~/crawlers/havencircle/logs/ncdr.log`
- 搬機器到新位置、斷電重開機後已實測：連線、新核心、爬蟲排程全部正常
- 連線方式說明文件放在控制電腦桌面（`爬蟲機-Mac Mini 連線方式.md`）跟私鑰資料夾裡（`說明.md`），裡面刻意不含任何密碼

### 未完成 / 已知問題

1. **Oracle 端還沒有接收爬蟲資料的服務**：目前 `fetch_ncdr.py` 只把結果存在 Mac Mini 本機的 `latest.json`，還沒有推送到 Oracle、也還沒有給 App 拉取的 API。規劃好但還沒動手：(a) Oracle 上寫一支接收用的 POST endpoint（要有簡單的驗證機制，避免被亂塞假資料）、(b) 給 App 拉取的 GET endpoint、(c) Nginx/SSL 掛載（Oracle 上跑著 30+ 站，改設定前務必 `nginx -t`）
2. **NCDR 會員審核還在等**，審核過後才能拿 API Key／設定推播訂閱，但這不擋路——公開 CAP feed 現在就能用
3. 沿用前一天的未完成項目：CKShare 跨帳號流程未驗證、生活圈只能新增不能編輯
4. **`HavenCircle` git repo 裡還有一批本次 session 開始前就存在、尚未 commit 的本機修改**（`SettingsView.swift` 重寫、新增 `EventVisibility.swift` 等，詳見 `git status`），本次 session 沒有處理這批，也還沒驗證能不能編譯過

### 下次起點

- **優先**：在 Oracle 上把接收 API／serving API／Nginx 掛載這三塊建起來，然後把 `fetch_ncdr.py` 加上「推送給 Oracle」的邏輯（目前只寫本機檔案），這樣才能讓 App 真正拉到真資料
- 之後：等 NCDR 會員審核通過，視需要換成官方 API Key 或加訂閱推播（非必要，公開 feed 已經夠用）
- 有新專案要用 Mac Mini 跑爬蟲時，照 `~/crawlers/README.md` 的慣例開新資料夾，不要跟 havencircle 的混在一起
- 回頭處理 App 端那批還沒 commit 的本機修改（SettingsView 重寫等），先確認能編譯過再決定要不要收進版本控制

## 2026-07-16 深夜 〜 07-17（同一個 session）

### 完成事項

**APNs 伺服器推播全鏈（`99838f6`）**
- Oracle `/apns/`：register.php（權杖登記）、notify_all.php（X-Admin-Key 廣播，admin key 在伺服器 `_apns_config.php`）、cron_check.php（每 5 分鐘比對 NCDR identifier，新警報→無聲喚醒廣播）；資料在 `apns/data/`（nginx deny）
- .p8 金鑰（Key ID B7F7W3Q973）已裝伺服器；本機備份在 `~/Documents/important file/apns-havencircle/`（Apple 不能重下載！）
- App：權杖自動上傳、無聲推播喚醒跑管線；實測 Apple 回 200 sent=1；模擬器收無聲推播不可靠（Apple 限制），實機待測
- nginx：站是「逐目錄開 PHP」，新目錄要加 extension conf（apns.conf 已建）
- 零追蹤架構：伺服器只存權杖、廣播喚醒，比對永遠在裝置上

**功能批（`0b309ad`、`9adb0ba`、`fe5cb74`）**
- 跟隨圈（顯著位置變更、Always 權限、FollowCircleService）、獨立重要地點（member.kind="place"）、圈編輯器與 Onboarding 都有「使用目前位置」
- 新聞 LLM 短摘要 ≤20 字（fetch_news.py summary 欄位＋OpenCC 簡轉繁兜底——LLM 會無視「禁簡體」指令）；App NewsEventProvider 優先顯示 summary；EventPipeline 對既有事件同步新標題

**介面重構「合成案」（C1-C4，`5cfd840`/`d066398`/`e8bc1ed`）**
- 設計流程照 70-deep-planning：3 平行 agent 真分歧提案→premortem→收斂→fresh-context 對抗驗收（抓出 5 個問題）→使用者選定
- 安心頁（HomeStatusView）為啟動頁：大字狀態/家人列/背景看守/回報平安；SafetyOverview 共用聚合（防假性安心，注意：專案已有 enum SafetyStatus 在 SafetyPing.swift，命名撞過一次）
- 分頁五減三（安心/地圖/家人）；提醒中心與回顧降二級（router.homePath push）；設定變全域 sheet（router.showSettings）
- 提醒中心按可信度收合；地圖摘要膠囊化；深淺色/XXXL 字級回歸通過

**其他**
- 功能導覽 coach marks（`3b334aa`）：黑幕聚光燈 6 步；DEBUG `--tour` 參數強制播放；設定頁可重看
- 外觀設定三檔（跟隨系統/淺/深）；APNs 權杖只在 DEBUG 顯示
- 主題：守護綠改 teal 0x0F8A6B/0x4AD6B8＋安心頁狀態色漸層底（`9edebc6`）
- Pitch 頁 https://havencircle.looptw.com/pitch/ 已上線（五畫面，WHY 段註解待實機截圖）

### 未完成／下次起點
1. **系統碟又爆了（清理到一半被中斷）**：已清 DerivedData（騰 1.8G）＋simctl delete unavailable。掃描結果待處理：~/Library/Caches 9.6G（Google 3.2G、VSCode ShipIt 1.3G、Homebrew 1.3G、ms-playwright 1.0G 都可清）、iOS DeviceSupport 5.5G（舊版可刪）、其他模擬器 19G（iPhone 14 Pro Max 6.4G 等；**58EB62E3=iPhone 17 Pro 是 demo 機有資料，勿刪**）
2. 實機測試清單：APNs 無聲喚醒＋可見橫幅、通知權限、跟隨圈背景更新、CKShare 雙機、提醒中心收合手感、04-event-detail 截圖
3. Pitch 頁缺：04 實機截圖（補後取消 index.html 註解、改回六畫面）、家人頁實機重拍、demo 影片連結、隊名
4. 使用者放了 App icon 概念稿在 design/icon-concepts/（獎盃 v1/v2）；若做正式 AppIcon 注意品牌群青 #3657D6 與新 teal
5. 模擬器 demo 資料曾被誤刪，`--smoke-onboard` 可一鍵重建（測試者＋信義區住家圈）

### 踩坑（詳見 LESSONS）
- `xcrun simctl spawn booted defaults write` 會蓋掉 App 沙盒偏好設定的其他 key（onboardingCompleted 等全丟）；且寫入的位置 App 不一定讀得到——改用 DEBUG 啟動參數傳旗標

## 2026-07-17 即時圈／固定圈產品轉向

> 本節記錄使用者最新、明確的產品決策，取代本文件較早的「零追蹤／不分享家人位置」敘述。舊段落保留作為歷史背景，不再代表目前規格。

### 已完成

- 警戒圈拆成兩類：**即時圈**代表每位家庭成員自行開啟的位置分享，隨其手機移動；**固定圈**代表住家、倉庫、家人的家等固定資產，可自訂名稱與警戒半徑。
- 每台手機只能替自己開啟／停止即時圈。位置透過既有家庭 `CKShare` 儲存，不送到 HavenCircle 的事件／推播伺服器；只有已加入家庭分享的人可讀取。
- 即時圈以約 100 公尺位移與 30 秒內寫入合併控制更新量；App 活躍時約每 30 秒刷新家庭位置，背景更新仍由 iOS 定位與執行排程決定，因此產品文案定位為「近即時」而非保證秒級追蹤。
- 每個即時圈都有 300–3,000 公尺的警戒半徑與最後更新時間。超過 15 分鐘未更新會顯示「位置已過期」，並排除警報比對，避免把舊位置誤當成現在位置。
- 家人頁、地圖、安心頁、Widget、Onboarding、設定與網站文案都已區分即時圈／固定圈；風險狀態不只靠顏色，會同步顯示文字標籤。
- 未登入 iCloud 時會顯示明確提示並禁止新開啟分享；若先前已開啟，仍可在本機關閉。

### 上線前仍需驗證

1. 在 CloudKit Development 建立／驗證 `FamilyLiveLocation` record type 與欄位，確認後部署到 Production。
2. 使用兩台登入不同 iCloud 帳號的實機，驗證 CKShare 邀請、雙向位置更新、停止分享與重新加入。
3. 實機驗證 Always 定位、前景／背景／鎖屏更新頻率、耗電、斷網後的過期狀態，以及系統終止 App 後的行為；不得對外承諾固定秒數更新。

## 2026-07-17 黑客松一等獎差距審查

### 核心結論

- 依 `111` 正式評分表審查後，App 本體的安心頁、提醒中心、真實資料鏈與產品倫理已具決賽競爭力；主要差距不是功能數量，而是**提交敘事與可驗證完成度落後於程式本體**。
- 線上 Pitch 仍混用「零位置追蹤／不看家人在哪」與新即時圈功能，截圖也仍是舊版生活圈／五分頁 UI；另外還標示 APNs 後端建置中、Demo 影片準備中，會直接傷害初賽的價值、潛力與完成度評分。
- 技術面的最大證據缺口是 CloudKit schema 與雙機 CKShare、即時圈、背景定位、安否回報／已讀回條尚未實機端到端驗證；`markRead` shared-zone owner 疑點仍需修正。
- 新增 `submission/COMPETITION_READINESS.md` 作為主張、證據、禁用舊文案、Demo 路徑與人工驗證紀錄的單一事實來源。
- 新增 `submission/verify_submission.sh` 作為自動提交閘門，檢查舊敘事、APNs 過期說法、六張截圖、AppIcon、隊名與 Demo 影片連結；可另用 `--online` 驗證 NCDR API，或 `--build` 驗證模擬器建置。

### 封版優先級

1. 先同步 Pitch／影片／截圖的產品敘事並部署，不再宣稱零位置追蹤；改講「不保存位置軌跡，只在官方風險命中警戒圈時提醒」。
2. 裝入正式 AppIcon，用同一個 release build 重拍三分頁、事件詳情、即時圈／固定圈與雙機安否畫面，補隊名與 Demo 影片。
3. 兩台不同 iCloud 帳號實機跑通 CKShare，修正 `markRead` zone，完成即時圈移動／停止／過期與背景定位證據。
4. 移除固定圈搜尋失敗後落到台北市中心的預設座標，並增加固定圈編輯。
5. 建立測試 target，至少覆蓋 AlertPolicy、即時圈過期、行政區解析、事件去重與家庭已讀流程；最後以乾淨 release commit 封版。

## 2026-07-17 競賽封版與法律基線落地

### 本輪已完成

- App 設定加入可離線閱讀的「法律與隱私」中心，含隱私權政策、用戶協議與使用條款；首次設定完成前需明確勾選同意。網站首頁與 Pitch 頁尾也加入三份同版公開文件。
- 「刪除帳號與所有資料」新增 APNs 權杖撤銷：App 會先呼叫 `website/apns/unregister.php`，再清除本機權杖、家庭圈、本機資料與通知。
- 固定圈搜尋失敗不再落到台北市中心預設座標；未確認位置時禁止儲存。固定圈可點入編輯並可滑動刪除。
- `markRead` 改用實際解析出的 shared zone ID；共享成員不再錯用 `CKCurrentUserDefaultName`，並針對多人同時已讀加入 CloudKit 衝突重試。
- 正式 AppIcon 已採用 1024×1024、無透明通道的避風港版本並連結 asset catalog。
- 修正功能導覽說明卡因外層 `ScrollView` 撐滿高度造成的大黑邊；已在 iPhone 17 Pro 模擬器重現並以修正後截圖驗證。
- Pitch 與影片腳本已移除「零位置追蹤／不看家人在哪」及「APNs 後端建置中」舊敘事，改為本人同意的最新位置、不建立移動軌跡、實機閉環驗證中的可證明主張。

### 仍需真人／外部條件

1. 正式隊名已確認為「山形」並寫入 Pitch；Demo 影片待介面封版後錄製、上傳並補入網址。
2. 兩台不同 iCloud 帳號實機完成 CKShare、即時圈、安否回報／已讀與背景定位錄影。
3. 正式部署網站與 `unregister.php` 後，核對三份法律頁公開 URL 與客服信箱確實可用；公開營運前交由法律專業人員審閱營運者資料與條款。

## 2026-07-17 Debug 實機診斷與證據流程

### 已完成

- 新增只存在於 Debug build 的「實機診斷金手指」：App 啟動自動記錄裝置、Background Modes、通知／定位權限、APNs token 是否存在與 iCloud 狀態；設定頁可一鍵測試定位回呼、APNs 註冊、NCDR API 與 5 秒本機通知。
- APNs 註冊／上傳、遠端通知 callback、通知點擊、前景／背景定位、CloudKit 最新位置上傳與 App scene phase 都加入無敏感資料 Log；不記錄精確座標、完整 token、住址或家人姓名。
- 診斷 Log 最多保留 300 筆，可在 App 內複製或分享；Release／TestFlight 不含診斷頁與診斷程式碼，不需封版前人工移除。
- 更新 `APNS_PUSH_TEST.md`，移除「後端／金鑰未完成」舊說法，明確區分本機通知、Development APNs 與 Production APNs。
- 新增 `submission/DEVICE_EVIDENCE_PLAN.md`，定義 APNs、背景定位、位置過期、CKShare 與安否閉環的拍攝順序、通過條件及證據檔名。
- 修正十個 `#Preview` 在 Release 仍引用 Debug-only `PreviewSupport` 的問題；Debug simulator、Debug iphoneos、Release iphoneos 都已無簽名編譯通過。
- Xcode 已偵測「華柏翰的 iPhone12」，並針對該裝置完成 Development Team 簽名建置；Push Notifications、CloudKit、Sign in with Apple 與 App Group entitlement 均存在，可直接由 Xcode Run 安裝測試。

### 實機驗證順序

1. 先以 Xcode Debug 直裝 iPhone，執行診斷金手指並把報告回傳；不需先經 TestFlight。
2. 使用兩台不同 iCloud 帳號裝置完成 Development APNs、鎖屏定位、停止分享、過期與安否回報證據。
3. 介面封版後才錄 Demo，並以 TestFlight 再驗證一次 production APNs 與正式安裝流程。

### 第一輪實機發現與修正

- iPhone 首次開啟即時圈時，手動取位與 `CLLocationManager` 連續回呼同時新增相同 CloudKit record；第一筆成功後，後到寫入收到 `record to insert already exists`，並把 UI 覆蓋成「即時位置同步失敗」。
- `FamilySyncService` 已將即時圈上傳序列化；在途期間的重複回呼會合併，CloudKit duplicate insert 也會抓回 server record 後重試。修正版覆蓋安裝實機後，三個同時回呼只產生一筆成功，沒有再出現 duplicate error。
- 實機重啟另觀察到 Core Location 先回傳 91 分鐘前、精度約 2 公里的快取，再回傳 5 公尺新位置；新增資料品質閘門，超過 2 分鐘或精度差於 500 公尺的位置不得同步，避免陳舊位置冒充最新位置。
- 已保存遮蔽識別碼的 pre/post 診斷快照於 `test/fixtures/ios-fix/`。
- 第二台 iPhone 實測定位寫入成功後，CloudKit query 回 `CKError 12: Field 'recordName' is not marked queryable`；原因是 `TRUEPREDICATE` 依賴未設 Queryable 的 system field。即時圈改以必填 `participantID` 查詢，自己的固定 record ID 另走直接 fetch；安否回報也同步改成必填 `createdAt` predicate，且 shared database 明確指定分享 zone。
- 查詢修正版已覆蓋安裝到 iPhone 16 實測：低精度舊位置被擋、準確位置單次寫入成功、再讀回 1 筆家庭最新位置，且沒有 duplicate insert、CKError 12 或同步失敗。這證明單機 CloudKit 寫入／讀回閉環；仍需另一台不同 iCloud 帳號接受 CKShare，才能把跨帳號列改為已驗證。

## 2026-07-17 官網即時圈敘事與產品海報上線

### 已完成

- 正式官網首頁已從「固定警戒圈為主」同步到目前產品規格：即時圈由本人在自己的手機上開啟／停止，只透過家庭 CKShare 分享最新位置，不建立移動軌跡；超過 15 分鐘未更新會標示過期並排除警報判斷。
- 核心功能改成四張卡：本人同意的即時圈、固定警戒圈、有理由的真警報、家人安否閉環；介面展示新增家人頁的即時圈控制畫面。
- 技術證據區新增私人位置資料路徑，清楚區分「家庭最新位置 → 家庭 iCloud → 裝置端判斷」與 NCDR／APNs 公開事件中繼；家庭位置不送到 HavenCircle 事件／推播伺服器。
- 驗證狀態依實際證據更新：CloudKit 最新位置單機寫入／讀回列為已驗證；雙帳號 CKShare、停止分享、位置過期與鎖屏推播仍維持驗證中。
- 三張產品海報已放入 `website/assets/posters/` 並上線：安心總覽、即時圈隱私控制、附近事件提醒。網站使用 830×1800 JPEG 輕量預覽，點擊可開啟 1290×2796 原始 PNG。
- `website/`、`assets/`、`pitch/` 與三份法律頁已選擇性同步到 <https://havencircle.looptw.com>；部署未覆蓋 `apns/`、`crawler/`、`join/`，檔案權限為 `www:www`。
- 正式站驗證：HTTPS 200、HTTP 301 轉址、三份法律頁與 Pitch 200、桌面 1440 與手機 390 無橫向溢出、手機選單正常、瀏覽器 console 無錯誤。三張原始海報線上 SHA-256 與本機一致。
- Pitch 已同步目前即時圈規格並重新上線：新增本人同意／家庭 iCloud／只留最新一筆／15 分鐘過期四條界線、三張產品海報與 CloudKit 單機已驗證狀態；六張 App 畫面從 5＋1 改為桌面 3×2、手機 2 欄。正式 `/pitch/` 已驗證 HTTP 200、海報完整載入且 console 無錯誤。

### 仍需外部條件

1. Demo 影片仍需錄製、上傳並把可點擊網址補進 Pitch，這是 `submission/verify_submission.sh` 唯一未通過項目。
2. 即時圈仍需兩台不同 iCloud 帳號的實機完成 CKShare 跨帳號、停止分享、過期與背景／鎖屏更新證據；對外不得承諾固定秒數更新。
- 雙機第一次掃描 QR 出現系統「Item Unavailable」：根因是 App 把 `publicPermission = .none` 的一般 `share.url` 直接編成 QR，未被圈主預先加入的 Apple 帳號依法無權開啟。已改為 iOS 26 的一次性私人參與者網址，加入並驗證 `InProcessOneTimeLinks` entitlement／自動簽章 profile；舊 QR 不會自動修復，必須由新版重新產生。
- 接受家庭邀請時會記住該 shared zone 並優先讀寫；修掉「成員手機加入前曾建立自己的 private 家庭圈，接受後仍把定位寫回自己圈」的跨帳號路由問題。成員端也不再能誤產生自己空圈的邀請，會明示僅圈主可邀請。

## 2026-07-17 上架前清理封版 + 黑客松落選複盤 + 監控/熱更決策

### 已完成：上架前程式碼清理（全部實 build 驗證過）

- **審查**：兩組偵查兵掃過（debug/placeholder、Info.plist/權限/隱私）＋跑 `submission/verify_submission.sh`。結論：程式本體幾乎就緒，閘門 26 項過 25，唯一 FAIL 是 Pitch 缺 Demo 影片連結。
- **demoSection 包 `#if DEBUG`**：`SettingsView.swift:154` 的三顆示範按鈕（模擬警報／載入歷史示範／重設 Demo）原本會編進正式版，已收進 DEBUG。
- **新增 `PrivacyInfo.xcprivacy`（App + Widget 各一份）**：App 申報 UserDefaults=CA92.1（唯一 required-reason API；已 grep 確認無 systemUptime/檔案時間戳/磁碟/鍵盤）；Widget 是空殼（只讀 App Group 容器 JSON 檔，無 required-reason API）。**已用 build 產物確認兩份都入包**（同步資料夾自動納入，不用改 pbxproj）。
- **刪唯一會上架的測試遺留物**：DrillView「手動新增測試事件」按鈕（四處連動）+ 整檔 `EventEditorView.swift`。
- **依使用者要求刪除 Debug 診斷/測試碼**（使用者已知情這些本來就是 `#if DEBUG` 不會上架，仍選擇刪乾淨原始碼）：刪 `DeviceDiagnostics.swift`／`DeviceDiagnosticsView.swift`／`SmokeTest.swift` 三檔 + 散落在 7 個 Service 檔的約 52 個診斷呼叫點（純 log，不影響邏輯；由一個有編輯權的 general-purpose agent 精確切除並自我 build 驗證）。`DemoSeed.swift` **保留**（被 DEBUG-only 的 demoSection 依賴）。
- **修 `verify_submission.sh`**：移除「要求 DeviceDiagnostics.swift 存在」的兩個過時檢查（原本設計是確保有做過實機診斷，與「上架前移除」目標相反）。
- **驗證（我自己跑、非採信 agent 自報）**：`xcodebuild` Debug 模擬器 build → `** BUILD SUCCEEDED **`（含 Widget extension）；grep 診斷/測試符號零殘留；閘門重跑仍只剩 Demo 影片一項 FAIL。

### 已完成：整包封版 commit

- 使用者選「整包可建置狀態一起提交」。開分支 **`chore/app-store-prep`**、commit **`b679b5b`**、**112 檔**（6912+/1033-）。**main 未動**。
- **排除的垃圾檔**（仍在工作區未追蹤，之後可考慮 `.gitignore`）：`HavenCircle-video.mp4`（Demo 影片本體）、根目錄三張 UUID 截圖 + 一張 `Screenshot …png`、`.scc/`。
- ⚠️ 這個 commit 一次收進了**多天累積、session 前就未 commit 的整個工作區**（不只本次清理）——SESSION_NOTES.md 也在裡面，本 session 前 git log 只有 5 個 commit 但工作區有 ~110 項變更，兩者對不上，改由「能建置就整包收進」處理。

### 已完成：黑客松落選複盤（studentcreator.tw）

- 活動＝「iOS AI Summer Camp 2026」（就是本專案 iosaicamp）。安心圈在「所有團隊」展示頁，但**不在評審選出的 10 組「決選/上台簡報」名單**。決選是評審討論選的，不是公開投票（票數軌道另計、皆剩 0 票）。
- 逐一讀完 10 組決選（練舞人、吃菜啦、第一幀、Packmon、PillScan、句源、雷包點點名、Snoots!、TrailUp、VocabStash）+ 安心圈自家詳情頁 + 官網 + Pitch。
- **診斷（呈現層落後，非產品層）**：決選作品全是「一人一件事、一句話懂」，且 **5/10 附 YouTube Demo 影片**；安心圈**無 Demo 影片**、概念先行（同意式邊界/即時圈vs固定圈/CKShare/NCDR 要讀三段才懂）、且官網/Pitch 到處「驗證中／展示版本」自曝未完成。安心圈技術完成度其實高於多數決選，但被包裝成難懂又自稱沒做完。
- 使用者決定：比賽結束，不再管，轉向真實 App Store。

### 已盤點：距離真實 App Store 上架還差的（給下次）

- 🔴 **CloudKit schema 從 Development 部署到 Production**（`FamilyLiveLocation`/`SafetyPing` 等；不做真實使用者家庭同步會壞）— 最易漏的致命項。
- 🔴 **App Privacy 問卷**（App Store Connect 內，與 `PrivacyInfo.xcprivacy` 是兩回事）。
- 🔴 **商店規格截圖**（6.9"/6.7"，Pitch 截圖尺寸不符，要用模擬器重截）。
- 🟡 Archive 後驗 `aps-environment` 是否被改寫成 `production`；AppIcon 的 dark/tinted 插槽仍空。
- ⚠️ **App Review 兩大風險**：背景定位（Guideline 2.5.4 要在送審備註說明必要性）、CKShare 跨帳號審查員測不了（要附備註/影片）。建議先上 **TestFlight** 補實機證據（雙機 CKShare、鎖屏 APNs、背景定位過期）再送審。
- ⏸️ Demo 影片（硬碟已有 `HavenCircle-video.mp4`，未上傳/未接進 Pitch）。

### 進行中：監控 + 熱更（決策已收斂、尚未動工）

- 使用者原要「加 Firebase 後臺監視」+「用 Firebase 熱更 API、免再送審」。
- 我已釐清紅線：iOS **禁止熱更程式邏輯/可執行碼（Guideline 2.5.2）**，只能熱更設定/資料/開關/端點；**祕密金鑰不可放** Remote Config（客戶端可讀）。Firebase Analytics 會觸發「Data Used to Track You」隱私標籤，重傷安心圈唯一還在的「零追蹤」差異化。
- **我的建議（使用者傾向採納）＝自建在既有 Oracle，不用 Firebase**：① 熱更＝`havencircle.looptw.com/config/app.json`（App 啟動抓＋離線兜底＋密碼保護後臺編輯），與現有 NCDR JSON serving 同模式；② 分析＝匿名 `events.php`（仿現有 APNs `register.php`）+ 簡單後臺看板；不想做看板才退而用 TelemetryDeck（隱私優先第三方），別用 Firebase。
- **下一步待使用者點頭**：是否要我把 `config/app.json` + `events.php` + 密碼保護後臺 + App 端（啟動抓設定、送匿名事件）整套搭起來；或先只做熱更那塊。

### 下次起點

1. 決定 `chore/app-store-prep` 是否併回 main（`git checkout main && git merge --ff-only chore/app-store-prep`）；順手考慮把垃圾檔加進 `.gitignore`。
2. 若要繼續監控/熱更：照上面「自建在 Oracle」的方案動工。
3. 真實上架優先序：CloudKit schema→Production、商店截圖、App Privacy 問卷、TestFlight 補實機證據。

## 2026-07-18〜19 熱更/監控上線 + 影響圈模型 + 安否閉環 + 實機打磨（`chore/app-store-prep`，已逐次併回 main，HEAD `f43fd96`）

### ⚠️ 下個 session 最優先的兩件待辦（已存成專案 memory，會自動提醒）
1. **部署新聞爬蟲 detail 到 Mac Mini**：`fetch_news.py` 已加 AI 詳述 prompt 並 commit，但這台機器連不到 Mac Mini（`macmini` 別名在控制電腦上）。真實新聞的「事件說明」尚未生效；官方事件與測試事件已可見。見 memory `deploy-news-crawler-detail`。
2. **上架前驗 SwiftData schema 遷移**：加 `LocalSafetyEvent.detail` 這種標準加法式遷移，覆蓋安裝舊版竟會執行期崩潰（崩在 `LocalLifeCircle.alertTypes` 的 SwiftData 斷言，`makeContainer` fallback 攔不到）。上架前、每次改 @Model 都要專門測「帶舊資料升級」路徑。見 memory `verify-schema-migration-before-appstore` 與 LESSONS 2026-07-19 條。

### 已完成：Oracle 自建熱更 + 匿名統計（不用 Firebase）
- `website/config/`：`app.json`（App 啟動抓、`no-store`、三層兜底：遠端→快取→內建預設）＋密碼保護後臺 `admin.php`（改值自動蓋 updatedAt、留 20 份備份）。App 端 `RemoteConfig.swift`。
- `website/analytics/`：匿名 `events.php`（只累加「當日×事件名×版本×iOS 大版本」，不存 IP/識別碼/位置）＋密碼保護看板 `dashboard.php`。App 端 `Analytics.swift`（佇列→啟動批次送、斷網保留）。設定頁有「匿名使用統計」開關。
- 已部署 havencircle.looptw.com 並實測（含安全邊界 data/ 與底線檔全 404）；密鑰檔照 apns 慣例 gitignore。App Privacy 問卷對照表在 `submission/APP_PRIVACY_QUESTIONNAIRE.md`。
- 熱更實戰驗證過：線上把 AQI 門檻 150→60（未重裝 App），枋山站 AQI 62 立即生成事件並推播。

### 已完成：影響圈模型（使用者要的「災難影響圈 ∩ 警戒圈 → 警報」）
- 判定式：`事件距離 ≤ 圈半徑 + 位置精度 + 災型影響半徑`。影響半徑依災型（車禍 300m／公共安全 1500m／火災·天災 1000m），表放 `config/app.json` 可遠端調。
- 空品連鎖：`AirQualityEventProvider` 圈附近測站 AQI 破門檻（預設 150）→ 生成官方事件 → 走同一套判定。工廠火災空污飄到你家的情境。
- 實測：圈距火災 1.9km（舊上限 1.5km 收不到）→ 正確推播。

### 已完成：通知漏斗 + 主角分化按鈕 + 安否閉環
- **通知漏斗**：危險級（火災/公共安全/地震/海嘯/颱風，清單 `dangerKinds` 可遠端調）用**時效性通知**（`interruptionLevel=.timeSensitive`，突破勿擾，entitlement `time-sensitive` 已簽入）＋互動按鈕；提醒級（高溫/降雨/停水）只發一般通知。
- **主角分化按鈕**（長按通知＋事件詳情頁「安否」區同一套邏輯）：我的圈→「回報我平安／尚未脫離危險」；家人的圈→「詢問是否平安」（發 pleaseReport，對方收到「X想確認你是否平安」）；地點類（倉庫）→純通知。SafetyStatus 加 `inDanger`、`pleaseReport`。
- 家人端 `fetchPings` 偵測他人新回報 → 本機通知（首次同步只登記不通知防洗版）。
- ⚠️ 跨裝置閉環（家人真的收到回報）**單機驗不了**，等雙機 CKShare 實測。

### 已完成：實機測試打磨（iPhone 12 華柏翰的iPhone12，`devicectl` 直裝）
- **A1 本人顯示「我」**：家人列/通知/詳情不再出現「1的『住家』」；設定改名同步到本人成員 name。
- **A2 事件詳情頁補安否按鈕**（錯過通知也有動線）。
- **新增：事件 AI 詳細描述**：`LocalSafetyEvent.detail`。新聞走爬蟲 LLM 白話重寫、官方走政府原始 description；詳情頁「事件說明」區（不是貼原始新聞）。六災難測試事件內建 detail 可立即看。
- **A4 地圖降噪**：圈標記移除重複「固定圈」徽章與外框、縮小；事件 pin 縮小；提醒級警報塗層淡化（大雨特報不再鋪滿雙北）。
- **導覽修正**：跨分頁先切頁等錨點再移聚光燈；修 safe area 重複計算（家人頁 5/6 窗頂切標題的根因）；小螢幕 Onboarding 條款不再被遮、邀請家人改可點行動卡。DEBUG `--tour-step N` 可逐步截圖。
- **六災難場景**：設定頁一鍵「載入／清除」按鈕（DEBUG-only），實機不用改 scheme 參數。
- **Xcode console log**：管線「收到X筆→去重Y組」、`✅ 已推播`、`不推播（原因）`、「導覽挖洞」座標。

### 仍需真人／外部條件（延續，未變）
1. **雙機 CKShare 全流程**（跨帳號邀請、即時圈雙向、安否閉環對方真收到、鎖屏 APNs、背景定位過期）——目前風險最集中的未驗證區，也是 CloudKit schema→Production 的前置。
2. 時效性通知在實機的鎖屏呈現、地圖降噪、詳情頁安否按鈕——待使用者在 iPhone 12 上確認（本 session 結束時 App 剛乾淨重裝、停在新 Onboarding）。
3. Demo 影片；三份法律頁公開 URL 與客服信箱；營運前法律審閱。

### 本 session 踩坑（詳見 LESSONS 2026-07-19 兩條）
- 共用工作區用 `git add -A` 兩度掃進另一個 AI session 的未驗證變更 → 改用列名 `git add <檔案清單>`。
- SwiftData 加 @Model 欄位後舊 store 覆蓋安裝執行期崩潰（見上面待辦 2）。
