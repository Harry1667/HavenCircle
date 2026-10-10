import Foundation

/// 每日安全摘要文案：讓「沒消息」也成為看得見的價值（留存關鍵）
enum DigestComposer {
    static func summary(events: [LocalSafetyEvent], members: [LocalFamilyMember]) -> String {
        let last24h = Date.now.addingTimeInterval(-86_400)
        let recent = events.filter { $0.occurredAt >= last24h && !$0.isDrill && !$0.isArchived }
        let attention = recent.filter { event in
            event.isActiveForAwareness
                && event.isOfficiallyConfirmed
                && !AlertPolicy.evaluate(event: event, members: members).matches.isEmpty
        }
        let filteredCount = recent.count - attention.count

        if attention.isEmpty {
            if filteredCount > 0 {
                return "今天，家人警戒圈附近暫無高風險事件。安心圈已為你過濾 \(filteredCount) 件低風險或未驗證資訊。"
            }
            return "今天，家人警戒圈附近暫無高風險事件。"
        }
        return "今天家人警戒圈附近有 \(attention.count) 件需要注意的事件，請開啟安心圈查看詳情。"
    }
}
