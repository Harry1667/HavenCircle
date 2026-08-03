import SwiftUI

extension View {
    /// iPad 上 sheet 會忽略內容的隱含尺寸而放大成整頁，`presentationSizing(.form)` 可把它收斂成表單尺寸。
    ///
    /// 該 API 需要 iOS 18，但 App 的部署目標是 iOS 17，所以包一層可用性判斷：
    /// iOS 18 以上維持原本的收斂行為，iOS 17 退回系統預設呈現。
    /// 這只影響 iPad 上的 sheet 外觀，不影響任何功能或 iPhone 呈現。
    @ViewBuilder
    func formPresentationSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.form)
        } else {
            self
        }
    }
}
