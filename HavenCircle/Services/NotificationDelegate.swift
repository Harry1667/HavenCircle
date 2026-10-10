import Foundation
import UserNotifications

/// 讓通知在 App 於前景時也以橫幅顯示——演練模式與即時事件都需要這個行為，
/// 否則使用者開著 App 演練時會以為通知管線壞了。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// 點擊通知 → 打開提醒中心；通知帶事件 key 時直達該事件詳情。
    /// 冷啟動時視圖可能尚未訂閱 NotificationCenter，
    /// 所以同時寫入 DeepLinkStore.pending（AppTabs 出現後會補路由），兩條路都通。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let eventKey = userInfo["eventKey"] as? String
        // 家人回報通知（本機與 FCM 推播都帶 type=familyPing、pingId、senderUid）
        let isFamilyPing = (userInfo["type"] as? String) == "familyPing"
        let pingID = userInfo["pingId"] as? String

        // 「收到 ❤️」：背景寫入確認、不開 App，結果用本機通知回饋（成功與失敗都要讓人知道）
        if response.actionIdentifier == NotificationScheduler.actionAckPing {
            guard let pingID, !pingID.isEmpty else {
                await postFeedback(title: "⚠️ 沒有送出收到", body: "找不到這則回報，請打開 App 查看")
                return
            }
            guard let sync = AppRuntime.familySync else {
                await postFeedback(title: "⚠️ 沒有送出收到", body: "請打開 App 後再回覆一次")
                return
            }
            guard await MainActor.run(body: { AuthService.shared.uid }) != nil else {
                await postFeedback(title: "尚未登入", body: "請先打開 App 登入後再回覆")
                return
            }
            await MainActor.run { Analytics.track("ping_ack_from_notification") }
            if await sync.ackPing(pingID: pingID) {
                await postFeedback(title: "❤️ 已回覆收到", body: "對方會知道你看到了")
            } else {
                await postFeedback(title: "⚠️ 收到可能未送出", body: "請打開 App 確認網路後再按一次")
            }
            return
        }

        // 快速按鈕（長按警報通知）：不開 App、直接寫入回報／發起確認並同步家庭圈。
        // 我的圈出事＝回報自己；家人的圈出事＝發「請回報平安」的確認請求。
        let quickStatus: SafetyStatus? = switch response.actionIdentifier {
        case NotificationScheduler.actionReportSafe: .safe
        case NotificationScheduler.actionReportDanger: .inDanger
        case NotificationScheduler.actionAskSafe: .pleaseReport
        default: nil
        }
        if let quickStatus {
            await MainActor.run {
                Analytics.track(quickStatus == .pleaseReport
                    ? "family_check_from_notification"
                    : "checkin_from_notification")
            }
            // 保命級 P0：舊版直接 postPing 就 return，零回饋——使用者長按通知回報後
            // 完全不知道有沒有送出。三種結局都要補一則本機通知讓使用者知道結果。
            guard let sync = AppRuntime.familySync else {
                // App 執行環境尚未就緒（極端的背景冷啟動情境），無法得知登入/送出狀態，
                // 誠實告知並導去 App 確認，而不是靜默吞掉這次快速操作。
                await postFeedback(title: "⚠️ 回報可能未送出", body: "請打開 App 確認家庭圈狀態後再回報一次")
                return
            }
            guard await MainActor.run(body: { AuthService.shared.uid }) != nil else {
                await postFeedback(title: "尚未登入", body: "請先打開 App 登入後再回報")
                return
            }
            // 沒有真名就送空字串（不上傳「我」），家人端顯示「家人 N」
            let senderName = FamilyNaming.ownUploadName()
            let success = await sync.postPing(
                senderName: senderName,
                status: quickStatus,
                note: quickStatus == .pleaseReport ? "收到警報後發起平安確認" : "由警報通知快速回報"
            )
            if success {
                await postFeedback(title: "✓ 已送出", body: "家人會看到你回報平安")
            } else {
                await postFeedback(title: "⚠️ 回報可能未送出", body: "請打開 App 確認")
            }
            return // 快速操作不需要開提醒中心
        }

        await MainActor.run {
            // 匿名統計：通知被點開＝提醒真的有被看（只記次數，不記事件內容）
            Analytics.track("notification_opened")
            // 家人回報通知（點通知本體或「查看家人」）：導到家人頁那一則回報
            if isFamilyPing, let pingID, !pingID.isEmpty {
                var pingComponents = URLComponents()
                pingComponents.scheme = "havencircle"
                pingComponents.host = "ping"
                pingComponents.queryItems = [URLQueryItem(name: "id", value: pingID)]
                if let pingURL = pingComponents.url {
                    DeepLinkStore.pending = pingURL
                    NotificationCenter.default.post(name: .didReceiveDeepLink, object: pingURL)
                    return
                }
            }
            // 用 URLComponents 組網址：eventKey 來自資料源（可能含空格或非 ASCII），要正確編碼
            var components = URLComponents()
            components.scheme = "havencircle"
            components.host = "alerts"
            if let eventKey {
                components.queryItems = [URLQueryItem(name: "event", value: eventKey)]
            }
            guard let url = components.url else { return }
            DeepLinkStore.pending = url
            NotificationCenter.default.post(name: .didReceiveDeepLink, object: url)
        }
    }

    /// 快速操作的即時結果回饋：刻意不走 NotificationScheduler.scheduleAlert——那條路徑是為
    /// 「災害警報」設計的節流（暫停提醒／吵醒門檻／權限檢查），而這裡是「使用者剛按下的動作」
    /// 的即時回饋，不該被同一套節流邏輯攔下，否則使用者按了快速回報卻連失敗通知都收不到。
    private func postFeedback(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "ping-feedback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 這個檔案沒有 import os：直接呼叫 AppLog.notifications.error(...) 的插值方法
            // 需要呼叫端自己 import os（見 AppLog.swift 註解），改用不碰 os 型別的包裝函式。
            AppLog.notificationsError("快速回報回饋通知排程失敗：\(error.localizedDescription)")
        }
    }
}
