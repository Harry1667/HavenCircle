import SwiftUI

/// 仿 Apple 原生設定的頭像：有照片就圓形裁切；沒照片是灰色漸層圓＋白色縮寫（monogram）；
/// 連名字都沒有時用白色 person.fill。
struct ProfileAvatar: View {
    /// 真正的名字（沒有就傳 nil，不要把「Apple 帳號」這種預設文字傳進來）
    var name: String?
    var size: CGFloat = 60

    private var photo: UIImage? { ProfilePhotoStore.shared.image }

    var body: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Self.gradient)
                if let text = Self.monogram(for: name) {
                    Text(text)
                        .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
                        .foregroundStyle(.white) // 灰底上的白字，淺深色都固定白
                        .minimumScaleFactor(0.5)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.46))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// 淺色 #A8ADB7→#868B95；深色 #6E737D→#4E525B（由上到下）
    private static let gradient = LinearGradient(
        colors: [
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(0x6E737D) : rgb(0xA8ADB7) }),
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(0x4E525B) : rgb(0x868B95) })
        ],
        startPoint: .top, endPoint: .bottom
    )

    private nonisolated static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 中文取第一個字；英文取前兩個單字的首字母（單一單字只取一個）
    static func monogram(for name: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        let isLatin = first.unicodeScalars.allSatisfy { $0.value < 0x2E80 }
        if isLatin {
            let initials = trimmed.split(whereSeparator: { $0.isWhitespace })
                .prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
            return initials.joined()
        }
        return String(first)
    }
}
