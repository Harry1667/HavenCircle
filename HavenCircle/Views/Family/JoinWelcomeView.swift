import SwiftUI

/// C3：加入家庭圈成功後的慶祝畫面。fullScreenCover 呈現，「繼續」接著才是身分選擇（RoleSelectView）。
/// 這是修「加入後沒有任何提示」的核心一步——舊版加入成功只有一行畫面內小字，
/// 使用者根本沒感覺到「有效」，這裡刻意用整頁儀式感取代。
struct JoinWelcomeView: View {
    /// B3-1：受邀者第一眼就要知道自己加入了「誰」的圈——優先序見 JoinByCodeView.welcomeFamilyName
    /// （自訂家庭名 >「○○ 的安心圈」>「安心圈」），不再是通用的「歡迎加入！」。
    var familyDisplayName: String
    /// 按「繼續」後呼叫（由 JoinByCodeView 接著開身分選擇）
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: HCSpacing.x6) {
            Spacer()
            ZStack {
                Circle()
                    .fill(HCColor.brand.opacity(0.10))
                    .frame(width: 112, height: 112)
                Circle()
                    .stroke(HCColor.brand.opacity(0.14), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(HCColor.brandText)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(HCColor.brandText)
                    .offset(x: 36, y: 36)
            }
                .accessibilityHidden(true)
            VStack(spacing: HCSpacing.x2) {
                Text("已加入「\(familyDisplayName)」！")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("災害靠近時，你和家人會互相知道平安。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                onContinue()
            } label: {
                Text("繼續")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HCColor.brandFill)
            .controlSize(.large)
            .tint(HCColor.brandFill)
            .padding(.bottom, HCSpacing.x4)
        }
        .padding(.horizontal, HCSpacing.x6)
        .padding(.top, HCSpacing.x6)
        // iPad：fullScreenCover 沒有 presentationSizing 可用，內容欄自己限寬置中，
        // 避免整頁儀式感在 13 吋螢幕上被拉伸得又空又怪
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
        // fullScreenCover 呈現、根層只有 VStack，沒有 List/Form/NavigationStack 自帶的
        // 不透明底：同 RoleSelectView 的坑，鋪系統底色避免深色模式整層透明。
        .background(Color(.systemBackground).ignoresSafeArea())
        .analyticsScreen("join_welcome")
    }
}

#if DEBUG
#Preview {
    JoinWelcomeView(familyDisplayName: "陳家的安心圈", onContinue: {})
}
#endif
