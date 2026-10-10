import Foundation
import SwiftData
import os

/// 集中管理的 Logger：錯誤一律明確記錄，不做 silent fail
nonisolated enum AppLog {
    private static let subsystem = "com.gomiigo.CamMenuApp.HavenCircle"
    static let data = Logger(subsystem: subsystem, category: "data")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let cloud = Logger(subsystem: subsystem, category: "cloud")

    /// 純字串的錯誤記錄包裝。
    /// 為什麼存在：專案開了 MemberImportVisibility，直接呼叫 Logger 的插值方法
    /// 需要每個檔案自己 import os；View 層改用這個包裝就完全不碰 os 型別，
    /// 也避免 Xcode 索引器狀態不同步時在 View 檔誤報 os 相關診斷。
    static func cloudError(_ message: String) {
        cloud.error("\(message, privacy: .public)")
    }

    static func dataError(_ message: String) {
        data.error("\(message, privacy: .public)")
    }

    static func notificationsError(_ message: String) {
        notifications.error("\(message, privacy: .public)")
    }
}

extension ModelContext {
    /// 儲存並記錄失敗原因（取代散落各處的 try? save()）
    func saveReporting() {
        do {
            try save()
        } catch {
            AppLog.data.error("SwiftData 儲存失敗：\(error.localizedDescription)")
        }
    }
}
