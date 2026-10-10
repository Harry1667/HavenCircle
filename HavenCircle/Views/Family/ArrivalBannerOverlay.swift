import SwiftUI

/// 家人到達／離開守護地點的 App 內橫幅（家人 App 在前景讀到新事件時顯示，約 6 秒後自動收起，也可點掉）。
/// 文字本身就說明狀態（「小明到達家」），不靠顏色。
struct ArrivalBannerOverlay: View {
    @Environment(FamilySyncService.self) private var sync

    var body: some View {
        if let banner = sync.arrivalBanners.first {
            HStack(spacing: 10) {
                Image(systemName: banner.kind == .arrive ? "house.fill" : "figure.walk.departure")
                    .foregroundStyle(HCColor.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.message).font(.subheadline.weight(.semibold))
                    Text("\(banner.timeText)・家人守護地點通知").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    sync.dismissArrivalBanner(banner.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("關閉通知")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 4, y: 2)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .task(id: banner.id) {
                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }
                withAnimation { sync.dismissArrivalBanner(banner.id) }
            }
            .animation(.default, value: banner.id)
        }
    }
}
