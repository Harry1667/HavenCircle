import SwiftUI
import SwiftData

/// 家人分頁：以人為中心的家人清單（FamilyListView）為唯一內容。
/// 舊版用頂部 segment 把「警戒圈」「安否回報」拆成兩個並列分頁，等於把「回報平安」
/// 這個核心動作也藏進去——2026-07 實測回饋「家人功能沒有明顯引導，所以沒用」，
/// segment 本身就是沒有引導的來源之一，改為單一頁＋固定底部回報鈕。
struct FamilyHubView: View {
    let myName: String
    @Environment(FamilySyncService.self) private var sync
    @Query private var members: [LocalFamilyMember]
    @State private var showCheckIn = false

    /// 共用 [FamilySyncService.isSolo]（D1 統一規則）：各頁各自定義同一件事就會養出兩套真相，
    /// 這裡直接沿用同一條規則，不再自己算本機成員數。
    private var isSoloUser: Bool {
        sync.isSolo(localMembers: members)
    }

    var body: some View {
        NavigationStack {
            FamilyListView()
                .navigationTitle("家人")
                .navigationBarTitleDisplayMode(.inline)
                // 單人時按了沒有對象收到，「回報平安」直接不出現，不留一顆死路按鈕
                // （與 HomeStatusView 的 checkInButton 同一款式、同一判斷）
                .safeAreaInset(edge: .bottom) { if !isSoloUser { checkInButton } }
                .sheet(isPresented: $showCheckIn) {
                    NavigationStack { SafetyCheckInView(myName: myName) }
                }
        }
    }

    private var checkInButton: some View {
        Button {
            showCheckIn = true
        } label: {
            // #9：不用 Label 直接套 .frame(maxWidth:)（icon 會消失），改用 HCCenteredLabel。
            HCCenteredLabel("回報平安", systemImage: "checkmark.shield.fill")
                .font(.headline)
                // iPad：與內容清單同寬上限，不讓整條按鈕撐滿 13 吋全寬
                .frame(maxWidth: 600)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(HCColor.brand)
        .padding(.horizontal, HCSpacing.x4)
        .padding(.bottom, HCSpacing.x2)
        .background(.bar)
    }
}

#if DEBUG
#Preview {
    FamilyHubView(myName: "我")
        .modelContainer(PreviewSupport.container())
        .environment(FamilySyncService())
}
#endif
