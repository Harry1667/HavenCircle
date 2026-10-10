import Foundation
import FirebaseAuth
import UIKit
import ImageIO

/// 「我是誰」的顯示規則集中處：名字從哪來、中文姓名怎麼組、登入後怎麼回填。
///
/// 名字來源順序：本機 profileDisplayName（使用者自己填的）→ Firebase displayName（Apple 首次授權的姓名）
/// → email @ 前段（私人轉寄信箱不算）→ 都沒有就回傳 nil，由畫面顯示「Apple 帳號」。
enum ProfileIdentity {
    /// 真正可顯示的名字；沒有任何來源時回傳 nil
    static func resolvedName(local: String, email: String) -> String? {
        let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let firebase = firebaseDisplayName() { return firebase }
        return emailPrefix(email)
    }

    private static func firebaseDisplayName() -> String? {
        let name = (Auth.auth().currentUser?.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func emailPrefix(_ email: String) -> String? {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        // Apple 隱藏我的 Email 產生的隨機字串不是名字，不拿來當顯示名
        if parts[1].lowercased().hasSuffix("privaterelay.appleid.com") { return nil }
        return String(parts[0])
    }

    /// Apple 給的姓名元件組成單一字串。含中日韓字元時姓在前、名在後且不加空格
    /// （PersonNameComponentsFormatter 依裝置語系排序，英文語系手機會把中文名排成「名 姓」）。
    static func formattedName(from components: PersonNameComponents) -> String {
        let family = components.familyName ?? ""
        let given = components.givenName ?? ""
        if (family + given).unicodeScalars.contains(where: isCJK) {
            return (family + given).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    /// 本機名字是空的才回填，絕不覆蓋使用者自己填的。
    /// 來源：這次登入 credential 的 fullName（只有首次授權才有）→ Firebase displayName。
    /// 回傳是否真的寫入了。
    @discardableResult
    static func backfillLocalName(fullName: PersonNameComponents? = nil) -> Bool {
        let defaults = UserDefaults.standard
        let current = (defaults.string(forKey: SettingsKeys.profileDisplayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty else { return false }
        var candidate = fullName.map(formattedName(from:)) ?? ""
        if candidate.isEmpty { candidate = firebaseDisplayName() ?? "" }
        guard !candidate.isEmpty else { return false }
        defaults.set(candidate, forKey: SettingsKeys.profileDisplayName)
        return true
    }
}

/// 自選頭像：只存在這支手機的 Application Support，不上傳、不同步。
/// 檔案為最長邊 512px 的 JPEG（品質 0.8）。
@MainActor
@Observable
final class ProfilePhotoStore {
    static let shared = ProfilePhotoStore()

    enum PhotoError: LocalizedError {
        case unreadable
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "這張照片無法讀取，請換一張再試。"
            case .saveFailed: "照片儲存失敗，請稍後再試。"
            }
        }
    }

    private(set) var image: UIImage?

    private static var fileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ProfilePhoto.jpg")
    }

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url) {
            image = UIImage(data: data)
        }
    }

    /// 縮圖（最長邊 512px）→ JPEG → 寫檔。失敗一律丟出可顯示的錯誤，不默默吞掉。
    func save(imageData: Data) throws {
        guard let jpeg = Self.downsampledJPEG(from: imageData), let url = Self.fileURL else {
            throw PhotoError.unreadable
        }
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            AppLog.dataError("頭像寫檔失敗：\(error.localizedDescription)")
            throw PhotoError.saveFailed
        }
        image = UIImage(data: jpeg)
    }

    func remove() {
        image = nil
        guard let url = Self.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.dataError("頭像刪除失敗：\(error.localizedDescription)")
        }
    }

    private nonisolated static func downsampledJPEG(from data: Data) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // 套用 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}
