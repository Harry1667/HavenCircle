import SwiftUI
import SwiftData

/// 地圖與提醒中心共用的區域警報橫幅
struct RegionAlertBanner: View {
    let alert: RegionAlert
    let members: [LocalFamilyMember]

    /// 危急/警戒（rank ≥ 2）視覺升級：實底圖示徽章，掃視時第一眼就跳出來
    private var isSevere: Bool { alert.severityRank >= 2 }

    var body: some View {
        HStack(spacing: HCSpacing.x3) {
            // 左側嚴重度條＋依嚴重度取色：危急/警戒紅、注意橘、留意黃。
            // 「哪則重要」不能只靠讀完標題才知道
            RoundedRectangle(cornerRadius: 2)
                .fill(alert.severityColor)
                .frame(width: 4)
            Image(systemName: alert.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSevere ? Color.white : alert.severityColor)
                .frame(width: 34, height: 34)
                .background(
                    isSevere ? AnyShapeStyle(alert.severityColor) : AnyShapeStyle(alert.severityColor.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text("\(alert.kind)警報：\(alert.title)")
                    .font(.subheadline.bold())
                // 嚴重度用文字寫出來，不能只靠顏色（色覺障礙與投影環境）
                Text("\(alert.severity)・\(matchedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(HCSpacing.x3)
        .background(alert.severityColor.opacity(0.10), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
    }

    private var matchedText: String {
        let matched = alert.matchedCircles(members: members)
        guard !matched.isEmpty else { return "影響 \(districtSummary)" }
        let names = matched.map { "\($0.memberName)（\($0.circleName)）" }.joined(separator: "、")
        return "影響 \(names) 所在行政區"
    }

    /// 影響範圍截斷：前 3 個行政區＋「等 N 個地區」——NCDR 大範圍警報動輒列數十個鄉鎮，
    /// 整串塞進副標會把卡片撐到五六行；完整清單留在詳情頁
    private var districtSummary: String {
        let districts = alert.affectedDistricts
        guard districts.count > 3 else { return districts.joined(separator: "、") }
        return districts.prefix(3).joined(separator: "、") + " 等 \(districts.count) 個地區"
    }
}

struct RegionAlertDetailView: View {
    let alert: RegionAlert
    let members: [LocalFamilyMember]
    @Environment(\.dismiss) private var dismiss

    /// 與事件詳情同一個殼：inline 標題＋左上「關閉」＋拖曳條；110/119 在建議行動之後的第一屏
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("\(alert.statusText)・\(alert.severity)", systemImage: alert.iconName)
                        .foregroundStyle(alert.isEnded ? Color.secondary : HCColor.attention)
                    Text(alert.guidance)
                }
                Section {
                    EmergencyCallRow()
                }
                .listRowInsets(
                    EdgeInsets(top: HCSpacing.x1, leading: HCSpacing.x4, bottom: HCSpacing.x1, trailing: HCSpacing.x4)
                )
                .listRowBackground(Color.clear)
                Section("影響範圍") {
                    Text(alert.affectedDistricts.joined(separator: "、"))
                    ForEach(alert.matchedCircles(members: members), id: \.circleName) { match in
                        Label("\(match.memberName)・\(match.circleName)", systemImage: "person.crop.circle")
                            .font(.subheadline)
                    }
                }
                Section("來源") {
                    LabeledContent("發布單位", value: alert.sourceName)
                    LabeledContent("發布時間", value: alert.issuedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("最近更新", value: alert.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let url = URL(string: alert.sourceURL) {
                        Link("查看原始來源", destination: url)
                    }
                }
            }
            .navigationTitle(alert.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
