import Foundation

// 事件去重與封存的「純計算」層：全部用值型快照進、值型計畫出，不碰 SwiftData model，
// 因此可在背景執行緒跑；主執行緒只負責拍快照與一次套用結果。

/// 單一事件的值型快照（由主執行緒從 LocalSafetyEvent 擷取）
nonisolated struct EventSnapshot: Sendable {
    let key: String
    let eventType: String
    let occurredAt: Date
    let latitude: Double
    let longitude: Double
    /// 可信度等級：3 官方確認、2 交叉驗證／主流媒體、1 持續確認中
    let trustRank: Int
    let isOngoing: Bool
    let isResolved: Bool
    let expiresAt: Date
    let updatedAt: Date
    let hasNotified: Bool
    let hasDetail: Bool
    let isDrill: Bool
    /// 逐案通報來源（消防局派遣、高速公路局等）：一筆就是一起獨立案件
    let isPerIncidentFeed: Bool
}

/// 對單一事件的處置結果
nonisolated struct EventDisposition: Sendable {
    /// 被合併時指向代表事件的 key；代表或獨立事件為 nil
    var mergedIntoKey: String?
    var reportCount: Int = 1
    /// 目標封存狀態（已含「被合併」）
    var shouldArchive: Bool
    /// 封存超過保留期，可直接刪除
    var shouldDelete: Bool
    /// 代表事件才有：群組內任一成員已推播過／最高可信度成員／最晚到期時間
    var groupAnyNotified: Bool = false
    var groupBestTrustKey: String?
    var groupMaxExpiresAt: Date?
    /// 群組成員 key（含自己），供同步「略過相似事件」群組
    var memberKeys: [String] = []
}

nonisolated enum EventConsolidation {
    /// 同一事件判定：同類型、距離 ≤ 1.5 公里、發生時間差 ≤ 6 小時
    static let mergeDistanceMeters: Double = 1_500
    static let mergeWindow: TimeInterval = 6 * 3_600
    /// 已結束且發生超過 72 小時 → 封存
    static let archiveAge: TimeInterval = 72 * 3_600
    /// 封存後保留 14 天，之後刪除
    static let archiveRetention: TimeInterval = 14 * 86_400

    /// 封存規則：已過期，或「非進行中且發生超過 72 小時」
    static func shouldArchive(occurredAt: Date, isOngoing: Bool, expiresAt: Date, now: Date) -> Bool {
        expiresAt <= now || (!isOngoing && occurredAt < now.addingTimeInterval(-archiveAge))
    }

    /// 連續量測型來源（AQI 測站）與演練事件不參與合併
    private static func isMergeable(_ s: EventSnapshot) -> Bool {
        !s.isDrill && !s.key.hasPrefix("evt-aqi-")
    }

    /// 逐案通報來源判定：消防、警政、高速公路局等官方派遣／事故資料，每筆都是不同案件。
    /// 2026-10-11 實機：未區分前高雄市消防局同一路段 11 起不同車禍被併成「11 則報導」，會藏掉真實案件
    static func isPerIncidentSource(_ sourceName: String) -> Bool {
        ["消防", "高速公路局", "警察", "警政", "內政部", "衛生福利部"].contains { sourceName.contains($0) }
    }

    /// 近似距離（公尺）；台灣尺度下等距圓柱投影誤差可忽略
    static func approxDistance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * 111_320
        let dLon = (lon2 - lon1) * 111_320 * cos((lat1 + lat2) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    static func plan(_ snaps: [EventSnapshot], now: Date) -> [String: EventDisposition] {
        var result: [String: EventDisposition] = [:]
        result.reserveCapacity(snaps.count)

        // 1. 分組：同類型內依發生時間排序；與群組「錨點（最早者）」時差 ≤ 6 小時，
        //    且距群組內任一成員 ≤ 1.5 公里者併入。
        var groups: [[EventSnapshot]] = []
        let byType = Dictionary(grouping: snaps.filter(isMergeable), by: \.eventType)
        for (_, list) in byType {
            let sorted = list.sorted { ($0.occurredAt, $0.key) < ($1.occurredAt, $1.key) }
            var open: [[EventSnapshot]] = []
            for event in sorted {
                // 錨點已超出時間窗的群組不會再吸收後面（更晚）的事件
                open.removeAll { group in
                    if event.occurredAt.timeIntervalSince(group[0].occurredAt) > mergeWindow {
                        groups.append(group)
                        return true
                    }
                    return false
                }
                // 一個群組最多只能有一筆逐案通報：兩筆官方案件不論多近都是不同案件，
                // 新聞報導則可併到官方案件底下（同一起事故的多篇報導）
                if let index = open.firstIndex(where: { group in
                    !(event.isPerIncidentFeed && group.contains(where: \.isPerIncidentFeed))
                        && group.contains { approxDistance($0.latitude, $0.longitude, event.latitude, event.longitude) <= mergeDistanceMeters }
                }) {
                    open[index].append(event)
                } else {
                    open.append([event])
                }
            }
            groups.append(contentsOf: open)
        }

        // 2. 每組選代表：未結束 > 可信度高（官方優先）> 已推播過 > 最早 > 資訊完整 > key（決定性排序，避免代表來回換）
        var grouped = Set<String>()
        for group in groups {
            if group.count == 1 { continue }
            let rep = group.min { a, b in
                let ae = a.isResolved || a.expiresAt <= now, be = b.isResolved || b.expiresAt <= now
                if ae != be { return !ae }
                if a.trustRank != b.trustRank { return a.trustRank > b.trustRank }
                if a.hasNotified != b.hasNotified { return a.hasNotified }
                if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
                if a.hasDetail != b.hasDetail { return a.hasDetail }
                return a.key < b.key
            }!
            let best = group.max { ($0.trustRank, $1.key) < ($1.trustRank, $0.key) }!
            let latestOccurred = group.map(\.occurredAt).max()!
            let maxExpires = group.map(\.expiresAt).max()!
            let anyOngoing = group.contains { $0.isOngoing }
            for member in group {
                grouped.insert(member.key)
                if member.key == rep.key {
                    var d = EventDisposition(
                        mergedIntoKey: nil,
                        reportCount: group.count,
                        shouldArchive: shouldArchive(occurredAt: latestOccurred, isOngoing: anyOngoing, expiresAt: maxExpires, now: now),
                        shouldDelete: false
                    )
                    d.groupAnyNotified = group.contains { $0.hasNotified }
                    d.groupBestTrustKey = best.key
                    d.groupMaxExpiresAt = maxExpires
                    d.memberKeys = group.map(\.key)
                    result[member.key] = d
                } else {
                    result[member.key] = EventDisposition(
                        mergedIntoKey: rep.key, shouldArchive: true, shouldDelete: false
                    )
                }
            }
        }
        // 3. 獨立事件
        for s in snaps where !grouped.contains(s.key) {
            result[s.key] = EventDisposition(
                shouldArchive: shouldArchive(occurredAt: s.occurredAt, isOngoing: s.isOngoing, expiresAt: s.expiresAt, now: now),
                shouldDelete: false
            )
        }
        // 4. 刪除：已封存且超過保留期沒有被來源再確認過（updatedAt 為最後確認時間）
        let cutoff = now.addingTimeInterval(-archiveRetention)
        for s in snaps {
            if var d = result[s.key], d.shouldArchive, s.updatedAt < cutoff, s.expiresAt < cutoff {
                d.shouldDelete = true
                result[s.key] = d
            }
        }
        return result
    }
}

// MARK: - 來源回報分組（可信度評分、簽名）

/// 同一簽名的回報組：全部是純值，供背景計算後在主執行緒一次套用
nonisolated struct PlannedReportGroup: Sendable {
    let signature: String
    let reports: [RawEventReport]
    let trust: String
    let primary: RawEventReport
    let maxTTL: TimeInterval
    let isOngoing: Bool
    let earliestOccurredAt: Date
    let detail: String?
}

nonisolated enum ReportGrouping {
    static func plan(_ reports: [RawEventReport]) -> [PlannedReportGroup] {
        Dictionary(grouping: reports, by: signature(of:)).compactMap { sig, group in
            guard let primary = group.first(where: \.isOfficial) ?? group.first else { return nil }
            return PlannedReportGroup(
                signature: sig,
                reports: group,
                trust: trustLevel(for: group),
                primary: primary,
                maxTTL: group.map(\.ttlSeconds).max() ?? 86_400,
                isOngoing: group.contains(where: \.isOngoing),
                earliestOccurredAt: group.map(\.occurredAt).min() ?? .now,
                detail: (group.first(where: { $0.detail?.isEmpty == false }) ?? primary).detail
            )
        }
    }

    /// 去重簽名：一般事故用「類型＋約 500 公尺網格＋6 小時時間窗」。AQI 等連續量測來源與
    /// 新聞（每篇一個 id）使用 provider 給的穩定鍵——同一事件的多篇報導改由 EventConsolidation 合併。
    static func signature(of report: RawEventReport) -> String {
        if let stable = report.stableDeduplicationKey, !stable.isEmpty {
            return stable
        }
        let gridLat = (report.latitude / 0.005).rounded() * 0.005
        let gridLon = (report.longitude / 0.005).rounded() * 0.005
        let sixHourBucket = Int(report.occurredAt.timeIntervalSince1970 / (6 * 3_600))
        return "\(report.eventType)@\(String(format: "%.3f", gridLat)),\(String(format: "%.3f", gridLon))#\(sixHourBucket)"
    }

    /// 可信度評分：官方 > （多來源交叉驗證／主流媒體單一報導）> 持續確認中
    static func trustLevel(for group: [RawEventReport]) -> String {
        if group.contains(where: \.isOfficial) { return TrustStatus.officialConfirmed }
        if group.reduce(0, { $0 + max($1.corroborationCount, 1) }) >= 2
            || Set(group.map(\.sourceName)).count >= 2 {
            return TrustStatus.crossVerified
        }
        if group.contains(where: { MainstreamMedia.isTier1($0.sourceName) }) {
            return TrustStatus.mediaConfirmed
        }
        return TrustStatus.confirming
    }

    static func trustRank(_ trust: String) -> Int {
        switch trust {
        case TrustStatus.officialConfirmed: 3
        case TrustStatus.crossVerified, TrustStatus.mediaConfirmed: 2
        default: 1
        }
    }
}
