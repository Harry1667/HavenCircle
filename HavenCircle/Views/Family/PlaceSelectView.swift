import SwiftUI

/// 「新增重要地點」的名稱選擇：點方塊代替打字，樣式比照 RoleSelectView（家庭身分選擇）。
/// 取代舊版 MemberEditorView(kind: "place") 的打字表單——多數人要的地點是住家、公司這幾種，
/// 用選的比打字快，也少一步輸入畫面。
struct PlaceSelectView: View {
    /// 選定後呼叫：呼叫端負責直接建立 place 成員（本畫面不碰 SwiftData）。
    var onSelect: (_ name: String, _ emoji: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCustomInput = false
    @State private var customName = ""

    private struct Option: Identifiable {
        var id: String { name }
        let name: String
        let emoji: String
    }

    private static let options: [Option] = [
        Option(name: "住家", emoji: "🏠"),
        Option(name: "公司", emoji: "🏢"),
        Option(name: "學校", emoji: "🏫"),
        Option(name: "爸媽家", emoji: "🏡"),
    ]

    /// 自訂稱呼統一用的中性圖釘，跟 RoleSelectView 的自訂黃臉是同一種設計語言。
    private static let customEmoji = "📍"

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("這是什麼地方？")
                        .font(.title.weight(.bold))
                    Text("選一個名稱，之後可以調整警戒範圍。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Self.options) { option in
                            tile(option)
                        }
                        customTile
                    }
                    .padding(20)
                }
            }
            // iPad 上限制內容欄寬度並置中，避免固定 3 欄的方塊在 13 吋螢幕上被拉得過大
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .analyticsScreen("place_select")
            .alert("這是什麼地方？", isPresented: $showCustomInput) {
                TextField("例如：倉庫、宿舍", text: $customName)
                Button("就用這個") {
                    let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onSelect(name, Self.customEmoji)
                }
                Button("取消", role: .cancel) { customName = "" }
            } message: {
                Text("輸入這個地點的名稱即可")
            }
        }
    }

    private func tile(_ option: Option) -> some View {
        Button {
            onSelect(option.name, option.emoji)
        } label: {
            tileLabel(emoji: option.emoji, title: option.name)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
    }

    /// 第五格：四個常見地點之外的所有名稱（倉庫、宿舍、店面⋯）走自訂輸入。
    private var customTile: some View {
        Button {
            showCustomInput = true
        } label: {
            tileLabel(emoji: Self.customEmoji, title: "其他")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("其他，自行輸入名稱")
    }

    private func tileLabel(emoji: String, title: String) -> some View {
        VStack(spacing: 8) {
            Text(emoji)
                .font(.system(size: 40))
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(HCColor.medical.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                .stroke(HCColor.medical.opacity(0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
    }
}

#if DEBUG
#Preview {
    PlaceSelectView(onSelect: { _, _ in })
}
#endif
