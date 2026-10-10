import SwiftUI
import SwiftData

struct MemberEditorView: View {
    /// "person"＝家人；"place"＝獨立重要地點（如老家、倉庫）——重用同一結構，只換文案
    var kind: String = "person"
    /// 儲存成功後回傳新成員：呼叫端據此接著打開固定圈編輯器，流程一步到位
    var onSaved: ((LocalFamilyMember) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var relationship = "家人"

    private var isPlace: Bool { kind == "place" }

    var body: some View {
        NavigationStack {
            Form {
                TextField(isPlace ? "地點名稱（如：老家）" : "名稱", text: $name)
                if !isPlace {
                    TextField("關係", text: $relationship)
                }
                Text(isPlace
                     ? "重要地點跟家人一樣會收到警報、顯示在地圖上，適合放沒有人用手機、但你想看著的地方（老家、倉庫、店面）。儲存後會接著設定它的位置與提醒範圍。"
                     : "這只會建立此裝置中的家人資料。要看到對方的即時圈，仍需邀請對方加入家庭，並由對方在自己的手機上開啟位置分享。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(isPlace ? "新增重要地點" : "新增本機家人資料")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let member = LocalFamilyMember(
                            name: name.isEmpty ? (isPlace ? "重要地點" : "家人") : name,
                            relationship: isPlace ? "重要地點" : relationship,
                            kind: kind
                        )
                        context.insert(member)
                        context.saveReporting()
                        dismiss()
                        onSaved?(member)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
