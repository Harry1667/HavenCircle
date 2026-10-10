import SwiftUI
import SwiftData

/// 地圖與提醒中心共用的區域警報橫幅
struct RegionAlertBanner: View {
    let alert: RegionAlert
    let members: [LocalFamilyMember]

    /// 嚴重度標籤的圖示（與文字並列，色盲也分得出層級）
    private var severityIcon: String {
        switch alert.severityRank {
        case 2...: "exclamationmark.triangle.fill"
        case 1: "exclamationmark.circle.fill"
        default: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: HCSpacing.x3) {
            // 設定頁式實色方塊＋反白符號，顏色依嚴重度（危急/警戒紅、注意橘、留意黃）；
            // 取消舊的左側色條——它與圖示是同一件事的兩次表達
            Image(systemName: alert.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HCColor.onStatus)
                .frame(width: 34, height: 34)
                .background(alert.severityColor, in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HCSpacing.x1) {
                Text("\(alert.kind)警報：\(alert.title)")
                    .font(.subheadline.bold())
                // 嚴重度用「圖示＋文字」膠囊寫出來，不能只靠顏色（色覺障礙與投影環境）
                Label(alert.severity, systemImage: severityIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(alert.severityColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(alert.severityColor.opacity(0.12), in: Capsule())
                Text(matchedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                .padding(.top, HCSpacing.x1)
        }
        .padding(HCSpacing.x3)
        // 材質底＋實色淡染（染色是平的 fill，不是第二層 Material）
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous).fill(alert.severityColor.opacity(0.08))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
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
