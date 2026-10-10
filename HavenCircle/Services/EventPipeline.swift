import Foundation
import SwiftData
import os

// MARK: - 來源協定

/// 原始事件回報：來源擷取後、進入去重與可信度評分前的統一格式
nonisolated struct RawEventReport: Sendable {
    let title: String
    let eventType: String
    let approximateLocation: String
    let latitude: Double
    let longitude: Double
    let precisionMeters: Int
    let sourceName: String
    let sourceURL: String
    let isOfficial: Bool
    let occurredAt: Date
    let ttlSeconds: TimeInterval
    /// AI 整理的詳細描述（新聞走 LLM、官方走原始 description）；缺則 nil
    var detail: String? = nil
    /// 來源端已完成的交叉驗證數。新聞爬蟲可能把多家媒體合成一筆；
    /// 若不把這個數字帶進 App，合併後反而會被誤判為單一來源。
    var corroborationCount: Int = 1
    /// 需要跨時間維持同一事件的來源可提供穩定鍵（例如 AQI 測站）。
    /// 一般事故留 nil，改用「類型＋位置＋6 小時時間窗」去重。
    var stableDeduplicationKey: String? = nil
    /// 來源是否明確表示仍在發生或剛發生、需要即時反應。
    /// 官方即時來源預設為 true；媒體新聞會帶入爬蟲判定，不能只因 TTL 未到就冒充進行中。
    var isOngoing: Bool = true
}

/// 來源協定一律 nonisolated + Sendable：網路回應的 JSON 解碼、欄位轉換、地名定位
/// 都由各 provider 的 `@concurrent` fetch 在背景執行緒完成，只把值型結果交回主執行緒。
nonisolated protocol EventProvider: Sendable {
    var sourceName: String { get }
    @concurrent func fetchReports() async throws -> [RawEventReport]
}

nonisolated struct RawRegionAlert: Sendable {
    let alertKey: String
    let title: String
    let kind: String
    let affectedDistricts: [String]
    let severity: String
    let guidance: String
    let sourceName: String
    let sourceURL: String
    let ttlSeconds: TimeInterval
}

nonisolated protocol RegionAlertProvider: Sendable {
    var sourceName: String { get }
    @concurrent func fetchAlerts() async throws -> [RawRegionAlert]
}

// MARK: - 管線

/// 資料管線：來源擷取 → 去重 → 可信度評分 → 生活圈比對 → 通知 → 封存。
/// 區域警報（regionProviders）已接上 NCDR 民生示警平台真實資料（見 NCDRRegionAlertProvider）。
/// 點狀事件（providers）也是真實來源：NCDR 示警裡帶精確座標的（火災通報等）
/// 由 NCDRPointEventProvider 轉成地圖點；沒座標的走區域警報那條路。
@MainActor
enum EventPipeline {
    static let providers: [any EventProvider] = [
        NCDRPointEventProvider(),
        // 消防署全國即時派遣：官方第一手（isOfficial=true，可推播），對標 Beacon 後補上的
        // 治安/意外事件缺口——不依賴新聞媒體報導與否、也不依賴關鍵字猜得準不準
        NFAIncidentProvider(),
        // 台中市 119 派遣火災：每 2 分鐘更新，比全國消防署初報更細、更快；
        // 只使用行政區概略位置，不把公開頁面的街道資訊帶進 App。
        TaichungFireEventProvider(),
        // 全台 15 縣市消防局逐案級派遣：補的是 NCDR 與消防署全國災情都拿不到的
        // 逐案顆粒度，尤其是「車禍」這個現行系統完全漏抓的類別
        CityFireIncidentProvider(),
        // 國道即時交通事故：補的是「重大交通事故」這個類別長期只能靠新聞轉述的缺口，
        // 高速公路局交控中心資料，座標精度比行政區反查高很多
        FreewayIncidentProvider(),
        // 媒體報導層：多家公開新聞來源的現場事故（isOfficial=false，裝置端依可信度決策）
        NewsEventProvider(),
        // 空品惡化連鎖：圈附近測站 AQI 破門檻→官方事件→推播（門檻與開關走遠端設定）
        AirQualityEventProvider(),
    ]
    static let regionProviders: [any RegionAlertProvider] = [
        NCDRRegionAlertProvider(),
        // 中央氣象署地震報告：官方第一手，用縣市展開成轄下行政區的區域比對——
        // 地震是大範圍有感現象，不該用點狀事件的距離模型（見 CWARegionAlertProvider 檔頭說明
        // 2026-07-26 使用者實測踩到的真實漏報：新北雙溪地震完全沒推播）。
        CWARegionAlertProvider(),
    ]

    /// 重入保護與限流：多個入口（啟動、回前景、5 分鐘定時、家人位置變動、跟隨圈移動）會各自呼叫 refresh，
    /// 以前同時跑好幾份，每份都打 7 個網路來源並重寫全部事件。現在同時間只跑一份，
    /// 呼叫端可帶 minInterval 表示「距上次完成不到這麼久就略過」。
    private static var isRefreshing = false
    private static var lastRefreshFinishedAt: Date?

    static func refresh(context: ModelContext, minInterval: TimeInterval = 0) async {
        if isRefreshing {
            // 刷新途中又有人要求（例如跟隨圈剛移動）：不丟掉，跑完這輪後補跑一次，比對才不會用到舊圈位置
            if minInterval == 0 { rerunRequested = true }
            return
        }
        if minInterval > 0, let last = lastRefreshFinishedAt, Date.now.timeIntervalSince(last) < minInterval { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefreshFinishedAt = .now }
        // 補跑最多一次，避免呼叫端高頻要求時變成無限迴圈
        var runs = 0
        repeat {
            rerunRequested = false
            await performRefresh(context: context)
            runs += 1
        } while rerunRequested && runs < 2
    }

    private static var rerunRequested = false

    private static func performRefresh(context: ModelContext) async {
        let members = (try? context.fetch(FetchDescriptor<LocalFamilyMember>())) ?? []
        // 1. 擷取來源，分組／可信度評分在背景算；回主執行緒後同步（無 await）寫入 → 去重合併 → 封存，
        //    整段只存檔一次，UI 只會收到一次更新
        let touchedKeys = await ingestPointEvents(context: context)
        await consolidateAndArchive(context: context)
        await ingestRegionAlerts(context: context, members: members)
        sweepRegionAlerts(context: context)
        context.saveReporting()
        // 2. 推播只評估這輪被來源確認過、且是代表事件（未被合併、未封存）的未推播事件
        await notifyPending(context: context, members: members, touchedKeys: touchedKeys)
        context.saveReporting()
        DataFreshness.markRefreshedNow()
        // 每次刷新都同步 Widget 快照（Widget 不自己抓網路，靠這裡餵）
        WidgetSnapshotWriter.refresh(context: context)

        let events = (try? context.fetch(FetchDescriptor<LocalSafetyEvent>())) ?? []
        await NotificationScheduler.refreshDailyDigest(
            summary: DigestComposer.summary(events: events, members: members)
        )
        AppLog.pipeline.info("✅ 管線刷新完成：庫內事件 \(events.count) 筆、警戒圈成員 \(members.count) 位")
    }

    // MARK: 點狀事件

    /// 回傳這輪被來源確認過的 eventKey，供推播階段使用
    private static func ingestPointEvents(context: ModelContext) async -> Set<String> {
        var reports: [RawEventReport] = []
        // 只有新聞端點成功解碼時才會有值（空陣列也代表成功）。若網路或端點失敗，
        // 絕不能把本機所有新聞誤當成已下線而清掉。
        var currentNewsEventKeys: Set<String>?
        // 各來源平行抓取（總請求數不變）；RemoteConfig 開關在主執行緒先判斷，
        // 結果依 providers 原順序合併，分組輸入順序與以前串行時完全一致
        let activeProviders = providers.filter { provider in
            // 遠端開關：媒體報導層可從 config/app.json 整層關閉
            // （新聞源出問題時免送審止血；官方 NCDR 源不設開關，那是產品底線）
            !(provider is NewsEventProvider) || RemoteConfig.feature("newsEvents", default: true)
        }
        let results = await withTaskGroup(of: (Int, Result<[RawEventReport], Error>).self) { group in
            for (index, provider) in activeProviders.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await provider.fetchReports()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[RawEventReport], Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }
        }
        for (index, result) in results {
            let provider = activeProviders[index]
            switch result {
            case .success(let providerReports):
                if provider is NewsEventProvider {
                    currentNewsEventKeys = Set(providerReports.compactMap { report in
                        report.stableDeduplicationKey.map { "evt-\($0)" }
                    })
                }
                reports += providerReports
            case .failure(let error):
                // 來源健康度：擷取失敗要留下紀錄，不能整條管線靜默失敗
                AppLog.pipeline.error("來源擷取失敗（\(provider.sourceName)）：\(error.localizedDescription)")
            }
        }

        // 線上來源主動下架（例如修正後的酒駕裁罰／戒酒輔導舊聞）時，舊版只會
        // 等 TTL 到期，期間仍被誤標「進行中」。成功取得完整新聞清單後立即把不在
        // 清單裡的本機新聞降成非即時資訊；不刪歷史，且端點失敗時不動資料。
        if let currentNewsEventKeys {
            markMissingNewsAsNonLive(context: context, currentKeys: currentNewsEventKeys)
        }

        // 分組與可信度評分是純計算，丟到背景執行緒（RawEventReport 為值型）
        let snapshotReports = reports
        let planned = await Task.detached(priority: .utility) {
            ReportGrouping.plan(snapshotReports)
        }.value
        // 事件通報進 Xcode console：管線每輪的輸入量與去重結果，一眼看出資料有沒有進來
        AppLog.pipeline.info("📥 點狀事件：收到 \(reports.count) 筆回報 → 分組後 \(planned.count) 組")
        // 一次取出全部既有事件建字典，取代「每組一次帶 predicate 的 fetch」（約 200 次查詢）
        let existingByKey = Dictionary(
            ((try? context.fetch(FetchDescriptor<LocalSafetyEvent>())) ?? []).map { ($0.eventKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var touchedKeys = Set<String>()
        for plan in planned {
            let trust = plan.trust
            let key = "evt-\(plan.signature)"
            touchedKeys.insert(key)
            if let existing = existingByKey[key] {
                // 明確解除的事件不再喚醒；單純 TTL 到期但來源又回報仍在進行時可重新啟用。
                guard !existing.isResolved else { continue }
                // 值沒變就不寫（SwiftData 賦同值也會觸發 @Query 重算）；updatedAt／expiresAt 是「最後確認時間」，
                // 1 分鐘內重複確認不必再刷新，避免每輪對全部事件做無意義寫入
                if abs(existing.updatedAt.timeIntervalSinceNow) > 60 {
                    existing.updatedAt = .now
                    existing.expiresAt = .now.addingTimeInterval(plan.maxTTL)
                }
                if existing.isOngoing != plan.isOngoing { existing.isOngoing = plan.isOngoing }
                if ReportGrouping.trustRank(trust) > ReportGrouping.trustRank(existing.trustStatus) {
                    existing.trustStatus = trust
                }
                // 已被合併的報導只維持「最後確認時間」與可信度，不解除封存、不更新顯示欄位、不推播
                if existing.mergedIntoKey != nil { continue }
                // 來源仍在回報的封存事件：只有不符合封存規則（例如重新進行中）才解除，
                // 否則會與封存步驟每輪來回翻轉
                if existing.isArchived,
                   !EventConsolidation.shouldArchive(
                       occurredAt: existing.occurredAt, isOngoing: existing.isOngoing,
                       expiresAt: existing.expiresAt, now: .now
                   ) {
                    existing.isArchived = false
                }
                // 來源端的標題與地點可能改善（例：媒體事件改用 LLM 短摘要重推），同步最新版
                let primary = plan.primary
                if existing.title != primary.title { existing.title = primary.title }
                if existing.approximateLocation != primary.approximateLocation { existing.approximateLocation = primary.approximateLocation }
                if existing.sourceName != primary.sourceName { existing.sourceName = primary.sourceName }
                if existing.sourceURL != primary.sourceURL { existing.sourceURL = primary.sourceURL }
                // 詳細描述可能是後來才由 LLM 補上；有新的就更新，沒有就保留舊值
                if let detail = plan.detail, !detail.isEmpty, existing.detail != detail { existing.detail = detail }
            } else {
                // 建立新事件：來源欄位優先採用官方回報。推播延後到合併之後（見 notifyPending），
                // 避免同一事件的多篇新報導各推一次
                let primary = plan.primary
                let event = LocalSafetyEvent(
                    eventKey: key,
                    title: primary.title,
                    eventType: primary.eventType,
                    occurredAt: plan.earliestOccurredAt,
                    approximateLocation: primary.approximateLocation,
                    latitude: primary.latitude,
                    longitude: primary.longitude,
                    precisionMeters: primary.precisionMeters,
                    sourceName: primary.sourceName,
                    sourceURL: primary.sourceURL,
                    trustStatus: trust,
                    severity: trust == TrustStatus.confirming ? "持續確認中" : "需要注意",
                    deduplicationGroup: plan.signature,
                    expiresAt: .now.addingTimeInterval(plan.maxTTL),
                    detail: plan.detail,
                    isOngoing: plan.isOngoing
                )
                context.insert(event)
            }
        }
        return touchedKeys
    }

    // MARK: 去重合併與封存

    /// 同一事件多篇報導合併、舊事件封存、過期封存刪除。
    /// 比對在背景用值快照算（EventConsolidation），這裡只在主執行緒拍快照與「同步、無 await」地套用結果，
    /// 呼叫端接著只存檔一次，UI 不會逐筆收到更新。
    private static func consolidateAndArchive(context: ModelContext) async {
        let events = (try? context.fetch(FetchDescriptor<LocalSafetyEvent>())) ?? []
        guard !events.isEmpty else { return }
        let now = Date.now
        let snapshots = events.map { event in
            EventSnapshot(
                key: event.eventKey, eventType: event.eventType, occurredAt: event.occurredAt,
                latitude: event.latitude, longitude: event.longitude,
                trustRank: ReportGrouping.trustRank(event.trustStatus),
                isOngoing: event.isOngoing, isResolved: event.isResolved,
                expiresAt: event.expiresAt, updatedAt: event.updatedAt,
                hasNotified: event.hasNotified, hasDetail: event.detail?.isEmpty == false,
                isDrill: event.isDrill,
                isPerIncidentFeed: EventConsolidation.isPerIncidentSource(event.sourceName)
            )
        }
        let dispositions = await Task.detached(priority: .utility) {
            EventConsolidation.plan(snapshots, now: now)
        }.value

        let byKey = Dictionary(events.map { ($0.eventKey, $0) }, uniquingKeysWith: { first, _ in first })
        var mergedCount = 0, archivedCount = 0, deletedCount = 0
        for event in events {
            guard let d = dispositions[event.eventKey] else { continue }
            // 過期的進行中事件自動解除。不再補發「已解除」推播——使用者不需要這類通知（減少通知噪音）。
            if !event.isResolved && event.isExpired { event.resolve() }
            if d.shouldDelete {
                context.delete(event)
                deletedCount += 1
                continue
            }
            if event.mergedIntoKey != d.mergedIntoKey {
                event.mergedIntoKey = d.mergedIntoKey
                if d.mergedIntoKey != nil { mergedCount += 1 }
            }
            if event.reportCount != d.reportCount { event.reportCount = d.reportCount }
            if event.isArchived != d.shouldArchive {
                event.isArchived = d.shouldArchive
                if d.shouldArchive && d.mergedIntoKey == nil { archivedCount += 1 }
            }
            // 代表事件吸收群組資訊：官方確認不遺失、已推播不重推、到期時間取最晚
            guard d.mergedIntoKey == nil, d.memberKeys.count > 1 else { continue }
            if d.groupAnyNotified && !event.hasNotified { event.hasNotified = true }
            if let bestKey = d.groupBestTrustKey, let best = byKey[bestKey],
               ReportGrouping.trustRank(best.trustStatus) > ReportGrouping.trustRank(event.trustStatus) {
                event.trustStatus = best.trustStatus
            }
            if let maxExpires = d.groupMaxExpiresAt, maxExpires > event.expiresAt { event.expiresAt = maxExpires }
            // 使用者曾按「略過相似事件」的群組隨代表保留，代表換人也不會讓事件重新冒出來
            if !EventVisibility.isGroupSuppressed(event.deduplicationGroup),
               let suppressed = d.memberKeys.compactMap({ byKey[$0]?.deduplicationGroup }).first(where: EventVisibility.isGroupSuppressed) {
                event.deduplicationGroup = suppressed
            }
        }
        if mergedCount + archivedCount + deletedCount > 0 {
            AppLog.pipeline.info("🧹 事件整理：新合併 \(mergedCount) 筆、封存 \(archivedCount) 筆、刪除 \(deletedCount) 筆")
        }
    }

    /// 推播階段：只評估代表事件（未合併、未封存、仍在發生）中這輪被來源確認過且尚未推播的。
    /// 涵蓋事後才新增生活圈、或可信度剛升級的情況；已結束或已封存的舊事件不再每輪評估。
    private static func notifyPending(
        context: ModelContext,
        members: [LocalFamilyMember],
        touchedKeys: Set<String>
    ) async {
        let events = (try? context.fetch(FetchDescriptor<LocalSafetyEvent>())) ?? []
        let pending = events.filter {
            touchedKeys.contains($0.eventKey) && !$0.hasNotified && $0.mergedIntoKey == nil && $0.isActiveForAwareness
        }
        for event in pending {
            _ = await NotificationScheduler.notifyIfNeeded(for: event, members: members)
        }
    }

    private static func markMissingNewsAsNonLive(
        context: ModelContext,
        currentKeys: Set<String>
    ) {
        let events = (try? context.fetch(FetchDescriptor<LocalSafetyEvent>())) ?? []
        let removed = events.filter {
            $0.eventKey.hasPrefix("evt-news-")
                && !$0.isEnded
                && $0.isOngoing
                && !currentKeys.contains($0.eventKey)
        }
        for event in removed {
            event.isOngoing = false
            event.updatedAt = .now
        }
        if !removed.isEmpty {
            AppLog.pipeline.info("🧹 新聞來源已下架 \(removed.count) 筆，本機改列非即時資訊")
        }
    }

    // MARK: 區域警報

    private static func ingestRegionAlerts(context: ModelContext, members: [LocalFamilyMember]) async {
        // 區域警報來源同樣平行抓取，依原順序合併
        let regionResults = await withTaskGroup(of: (Int, Result<[RawRegionAlert], Error>).self) { group in
            for (index, provider) in regionProviders.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await provider.fetchAlerts()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[RawRegionAlert], Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var raws: [RawRegionAlert] = []
        for (index, result) in regionResults {
            switch result {
            case .success(let alerts):
                raws += alerts
            case .failure(let error):
                AppLog.pipeline.error("區域警報擷取失敗（\(regionProviders[index].sourceName)）：\(error.localizedDescription)")
            }
        }
        for raw in raws {
            let key = raw.alertKey
            let descriptor = FetchDescriptor<RegionAlert>(predicate: #Predicate { $0.alertKey == key })
            if let existing = ((try? context.fetch(descriptor)) ?? []).first {
                guard existing.status != EventStatus.resolved.rawValue else { continue }
                existing.updatedAt = .now
                existing.title = raw.title
                existing.affectedDistricts = raw.affectedDistricts
                existing.severity = raw.severity
                existing.guidance = raw.guidance
                existing.expiresAt = .now.addingTimeInterval(raw.ttlSeconds)
            } else {
                let alert = RegionAlert(
                    alertKey: raw.alertKey,
                    title: raw.title,
                    kind: raw.kind,
                    affectedDistricts: raw.affectedDistricts,
                    severity: raw.severity,
                    guidance: raw.guidance,
                    sourceName: raw.sourceName,
                    sourceURL: raw.sourceURL,
                    expiresAt: .now.addingTimeInterval(raw.ttlSeconds)
                )
                context.insert(alert)
                let matched = alert.matchedCircles(members: members)
                if !matched.isEmpty {
                    let names = matched.map { "\($0.memberName)（\($0.circleName)）" }.joined(separator: "、")
                    // 通知漏斗：地震／海嘯／颱風＝危險級（時效性＋互動按鈕）；
                    // 高溫、降雨、停水這類提醒級只發一般通知，不吵人也不開家人確認迴圈
                    let isDanger = RemoteConfig.isDangerKind(raw.kind)
                    let interaction: NotificationScheduler.AlertInteraction
                    var callToAction = ""
                    if !isDanger {
                        interaction = .none
                    } else if matched.contains(where: \.isCurrentUser) {
                        interaction = .selfReport
                        callToAction = "長按通知可直接回報安否。"
                    } else if let person = matched.first(where: { !$0.isPlace }) {
                        interaction = .familyCheck
                        callToAction = "長按通知可一鍵詢問\(person.memberName)是否平安。"
                    } else {
                        interaction = .none
                    }
                    await NotificationScheduler.scheduleAlert(
                        title: "\(raw.kind)警報：\(raw.title)",
                        body: "影響 \(names) 所在行政區。\(raw.guidance)\(callToAction)",
                        id: raw.alertKey,
                        interaction: interaction,
                        timeSensitive: isDanger,
                        kind: raw.kind
                    )
                }
            }
        }
    }

    // MARK: 區域警報過期

    private static func sweepRegionAlerts(context: ModelContext) {
        let alerts = (try? context.fetch(FetchDescriptor<RegionAlert>())) ?? []
        for alert in alerts where alert.status == EventStatus.active.rawValue && alert.expiresAt <= .now {
            alert.status = EventStatus.resolved.rawValue
        }
    }
}
