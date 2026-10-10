import Foundation
import UserNotifications
import os

/// 本機通知排程。所有通知都必須經過這裡，才能保證「暫停提醒」真的有效。
enum NotificationScheduler {
    /// 事件警報通知的互動分類：長按（或下拉）通知即可操作，不必先開 App。
    /// 依事件主角分兩種：命中「我的圈」→ 回報我平安／尚未脫離危險；
    /// 命中「家人的圈」→ 詢問是否平安（發出平安確認請求，對方手機會收到）。
    static let safetyAlertCategory = "SAFETY_ALERT"
    static let familyCheckCategory = "FAMILY_CHECK"
    static let actionReportSafe = "REPORT_SAFE"
    static let actionReportDanger = "REPORT_DANGER"
    static let actionAskSafe = "ASK_SAFE"

    /// 通知互動型態（依「事件打在誰的圈」決定）
    enum AlertInteraction {
        case selfReport   // 我的圈：回報我平安／尚未脫離危險
        case familyCheck  // 家人的圈：詢問是否平安
        case none         // 地點類成員或提醒級災害：純通知
    }

    /// App 啟動時登記通知分類（Apple 規定要在通知送出前登記好）
    static func registerCategories() {
        let safe = UNNotificationAction(
            identifier: actionReportSafe,
            title: "回報我平安",
            options: [] // 不需開 App，背景就能回報
        )
        let danger = UNNotificationAction(
            identifier: actionReportDanger,
            title: "尚未脫離危險",
            options: [] // 同上；紅色 destructive 樣式反而像「刪除」，不用
        )
        let selfCategory = UNNotificationCategory(
            identifier: safetyAlertCategory,
            actions: [safe, danger],
            intentIdentifiers: []
        )
        let ask = UNNotificationAction(
            identifier: actionAskSafe,
            title: "詢問是否平安",
            options: []
        )
        let familyCategory = UNNotificationCategory(
            identifier: familyCheckCategory,
            actions: [ask],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([selfCategory, familyCategory])
    }
    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.notifications.error("通知權限請求失敗：\(error.localizedDescription)")
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 發送事件提醒。修正舊版問題：這裡實際檢查「啟用本機提醒」與「暫停提醒」旗標，
    /// 任一不符就不發，並記錄原因。
    /// eventKey：讓通知點擊能直達該事件詳情，不帶就只開提醒中心清單（如每日摘要）。
    static func scheduleAlert(
        title: String,
        body: String,
        id: String,
        eventKey: String? = nil,
        interaction: AlertInteraction = .none,
        timeSensitive: Bool = false,
        kind: String? = nil
    ) async {
        let defaults = UserDefaults.standard
        // alertsEnabled 預設值為 true（鍵不存在時視為啟用），alertsPaused 預設 false
        let enabled = defaults.object(forKey: SettingsKeys.alertsEnabled) as? Bool ?? true
        let paused = defaults.bool(forKey: SettingsKeys.alertsPaused)
        guard enabled, !paused else {
            AppLog.notifications.info("提醒已停用或暫停，略過通知：\(id)")
            return
        }
        // 只檢查現有權限，不在這裡觸發系統對話框——
        // 否則資料管線會在刷新途中被權限框卡住。權限請求只發生在
        // 明確的 UX 時機（首次設定完成、演練頁、設定頁按鈕）。
        guard await authorizationStatus() == .authorized else {
            AppLog.notifications.info("尚未取得通知權限，略過通知：\(id)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let eventKey {
            content.userInfo = ["eventKey": eventKey]
        }
        // 互動按鈕依事件主角掛載；提醒級災害（高溫、降雨…）不掛
        switch interaction {
        case .selfReport: content.categoryIdentifier = safetyAlertCategory
        case .familyCheck: content.categoryIdentifier = familyCheckCategory
        case .none: break
        }
        // 危險級（火災、械鬥、地震、海嘯、颱風）用時效性通知：可突破專注模式、鎖屏置頂。
        // 提醒級維持一般層級，避免高溫特報也吵到勿擾中的使用者。
        // 是否「真的」能突破再交給 effectiveTimeSensitive 收斂（吵醒門檻／安靜時段／個別靜音）
        content.interruptionLevel = effectiveTimeSensitive(requested: timeSensitive, kind: kind) ? .timeSensitive : .active
        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            AppLog.notifications.info("✅ 已推播：\(title)")
            // 匿名漏斗：只累計「iOS 已接受排程」，不帶事件標題、位置、生活圈或裝置識別。
            // FCM 主題送達與使用者實際看到通知是兩件事，這一點能把兩段明確分開觀察。
            Analytics.track("notification_scheduled")
        } catch {
            AppLog.notifications.error("通知排程失敗（\(id)）：\(error.localizedDescription)")
        }
    }

    /// 吵醒門檻的單一收斂點：所有 scheduleAlert 呼叫都經這裡決定能不能用時效性通知
    /// 突破靜音／專注模式。降級只影響 interruptionLevel，**不擋通知本身**——
    /// 通知一律照常送達，只是降級後不亮屏、不出聲、不震動。
    private static func effectiveTimeSensitive(requested: Bool, kind: String?) -> Bool {
        // a. 呼叫端本來就沒要時效性，不必往下判斷
        guard requested else { return false }
        let threshold = WakeThreshold.current
        // b. 使用者選「絕不吵醒」：任何警報都不突破
        guard threshold != .never else { return false }
        let isMajor = WakeThreshold.isMajor(kind: kind)
        // c. 「僅重大才吵」：非重大一律不突破；家人安否視同重大
        if threshold == .majorOnly, !isMajor { return false }
        // d. .standard 且通過以上檢查：維持 requested==true，繼續往下看安靜時段與個別靜音
        // e. 安靜時段內：再收斂一層，只有重大（含家人安否）能維持突破，其餘一律降級
        if isWithinQuietHours(), !isMajor { return false }
        // f. 使用者對這個事件類別按過「這類警報以後不吵醒我」：一律不突破
        if let kind, AlertWakePrefs.isMuted(kind) { return false }
        return true
    }

    /// 安靜時段判定：跨夜區間（如 22→7）要特別處理——結束時刻小於開始時刻代表跨過午夜。
    private static func isWithinQuietHours() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.quietHoursEnabled) else { return false }
        let start = defaults.object(forKey: SettingsKeys.quietStartHour) as? Int ?? 22
        let end = defaults.object(forKey: SettingsKeys.quietEndHour) as? Int ?? 7
        let hour = Calendar.current.component(.hour, from: .now)
        if start == end { return true } // 邊界情況（開始＝結束）視為全天安靜，避免語意矛盾
        if start < end {
            return hour >= start && hour < end // 不跨夜，例如 9→17
        } else {
            return hour >= start || hour < end // 跨夜，例如 22→7：今晚 22 點後或今天 7 點前都算
        }
    }

    /// 事件提醒的唯一入口：先過 AlertPolicy 決策，該推才推。
    /// 回傳決策讓呼叫端（例如演練模式）能顯示「為何推播／為何不推播」。
    @discardableResult
    static func notifyIfNeeded(
        for event: LocalSafetyEvent,
        members: [LocalFamilyMember]
    ) async -> AlertDecision {
        let decision = AlertPolicy.evaluate(event: event, members: members)
        guard decision.shouldPush else {
            AppLog.notifications.info("不推播（\(event.eventKey)）：\(decision.reason)")
            return decision
        }
        Analytics.track("alert_circle_matched")
        let prefix = event.isDrill ? "【演練】" : ""
        // 通知漏斗：危險級才掛互動按鈕與時效性通知；主角是誰決定掛哪組按鈕
        let isDanger = RemoteConfig.isDangerKind(event.eventType)
        let best = decision.matches.min(by: { $0.distanceMeters < $1.distanceMeters })
        let interaction: AlertInteraction
        var callToAction = ""
        if !isDanger {
            interaction = .none
        } else if best?.isCurrentUser == true {
            interaction = .selfReport
            callToAction = "長按通知可直接回報安否，家人會收到你的狀態。"
        } else if let best, !best.isPlace {
            interaction = .familyCheck
            callToAction = "長按通知可一鍵詢問\(best.memberName)是否平安。"
        } else {
            interaction = .none // 地點類成員（倉庫等）不會回報平安
        }
        // 非官方確認的事件（新聞報導）一律在通知內文標明，避免被當成官方警報
        let newsDisclaimer = event.trustStatus == TrustStatus.officialConfirmed ? "" : "新聞報導，未經官方確認。"
        await scheduleAlert(
            title: "\(prefix)\(event.title)",
            body: "\(decision.reason)。\(newsDisclaimer)\(callToAction)",
            id: event.eventKey,
            eventKey: event.eventKey,
            interaction: interaction,
            timeSensitive: isDanger,
            kind: event.eventType
        )
        // 標記已推播：同一事件不重複打擾（通知限流的最小單位）
        event.hasNotified = true
        return decision
    }

    /// 解除通知：焦慮被打開了就要被關上
    static func notifyResolved(for event: LocalSafetyEvent) async {
        let prefix = event.isDrill ? "【演練】" : ""
        await scheduleAlert(
            title: "\(prefix)事件已解除：\(event.title)",
            body: "\(event.approximateLocation)的事件已標記為結束，無需進一步行動。",
            id: "\(event.eventKey)-resolved",
            eventKey: event.eventKey
        )
    }

    // MARK: - 每日安全摘要

    static let digestID = "daily-digest"

    /// 重排下一次每日摘要。摘要內容是「排程當下」計算的快照，不能用重複排程把
    /// 今天的內容原封不動帶到明天；每次資料管線刷新時改排下一個實際日期，確保
    /// App 有機會更新時不會繼續播報過期摘要。
    static func refreshDailyDigest(summary: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [digestID])

        let defaults = UserDefaults.standard
        let digestEnabled = defaults.object(forKey: SettingsKeys.digestEnabled) as? Bool ?? true
        let alertsEnabled = defaults.object(forKey: SettingsKeys.alertsEnabled) as? Bool ?? true
        guard digestEnabled, alertsEnabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        let calendar = Calendar.current
        let hour = min(23, max(0, defaults.object(forKey: SettingsKeys.digestHour) as? Int ?? 20))
        let now = Date.now
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        guard let today = calendar.date(from: components) else { return }
        let nextDate = today > now
            ? today
            : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        let triggerComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: nextDate
        )

        let content = UNMutableNotificationContent()
        content.title = "今日安全摘要"
        content.body = summary
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: digestID, content: content, trigger: trigger))
            Analytics.track("digest_scheduled")
        } catch {
            AppLog.notifications.error("每日摘要排程失敗：\(error.localizedDescription)")
        }
    }
}
