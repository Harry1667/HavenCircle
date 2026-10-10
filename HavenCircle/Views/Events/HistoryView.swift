import SwiftUI
import SwiftData

/// 區域回顧：事件統計與清單，可查天數依方案分層（免費 [FreeTier.historyDays]／
/// Guardian+ [FreeTier.plusHistoryDays]，見 MONETIZATION_PLAN.md 裁決）。
/// 解決冷啟動問題——新使用者當下沒有事件時，仍看得到這個區域的歷史樣貌。
struct HistoryView: View {
    @Environment(EntitlementStore.self) private var entitlementStore
    @Query(sort: \LocalSafetyEvent.occurredAt, order: .reverse) private var events: [LocalSafetyEvent]
    @Query private var members: [LocalFamilyMember]
    @State private var showPaywall = false

    private var historyDays: Int {
        entitlementStore.isPlus ? FreeTier.plusHistoryDays : FreeTier.historyDays
    }

    private var cutoff: Date {
        Date.now.addingTimeInterval(-Double(historyDays) * 86_400)
    }

    private var recentEvents: [LocalSafetyEvent] {
        events.filter { $0.occurredAt >= cutoff && !$0.isDrill && $0.mergedIntoKey == nil }
    }

    /// 免費方案且本機確實存在被 cutoff 擋掉的更早事件時才顯示升級提示；
    /// Guardian+ 或本來就沒有更早資料時不必顯示（沒東西可多看）。
    private var isTruncatedByFreeTier: Bool {
        !entitlementStore.isPlus && events.contains { !$0.isDrill && $0.occurredAt < cutoff }
    }

    private var countsByType: [(type: String, count: Int)] {
        Dictionary(grouping: recentEvents, by: \.eventType)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        List {
            Section("過去 \(historyDays) 天統計") {
                if countsByType.isEmpty {
                    Text("這段期間沒有紀錄到事件").foregroundStyle(.secondary)
                } else {
                    ForEach(countsByType, id: \.type) { item in
                        statBar(type: item.type, count: item.count)
                    }
                }
            }
            Section("事件紀錄") {
                ForEach(recentEvents) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.title).font(.subheadline.bold())
                            Spacer()
                            Text(event.statusText).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(event.eventType) · \(event.approximateLocation)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if isTruncatedByFreeTier {
                Section {
                    Button {
                        Analytics.track("paywall_from_history")
                        showPaywall = true
                    } label: {
                        HStack(spacing: HCSpacing.x3) {
                            Image(systemName: "clock.badge.questionmark")
                                .foregroundStyle(HCColor.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("回顧更久以前需要 Guardian+")
                                    .font(.subheadline.weight(.medium))
                                Text("免費方案只顯示過去 \(FreeTier.historyDays) 天，Guardian+ 可回顧完整 \(FreeTier.plusHistoryDays) 天。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("區域回顧")
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    private func statBar(type: String, count: Int) -> some View {
        let maxCount = countsByType.first?.count ?? 1
        return HStack {
            Text(type).font(.subheadline).frame(width: 100, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(HCColor.brand.opacity(0.6))
                    .frame(width: max(geo.size.width * CGFloat(count) / CGFloat(maxCount), 8))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            Text("\(count) 件").font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: 24)
    }
}

#if DEBUG
#Preview {
    NavigationStack { HistoryView() }
        .modelContainer(PreviewSupport.container())
        .environment(EntitlementStore())
}
#endif
