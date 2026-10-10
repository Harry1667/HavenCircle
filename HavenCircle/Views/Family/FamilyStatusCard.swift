import SwiftUI
import SwiftData

/// 家人首頁頂部的狀態卡（取代原「安心」分頁的大字狀態區）。
/// 一眼回答兩件事：「我的警戒圈／家人平不平安」「附近有沒有事」，細節下鑽到動態與地圖。
///
/// 口徑（與地圖、通知共用同一份聚合 [SafetyOverview]，一律以未過濾事件計算——假性安心是最不可犯的錯）：
/// - 有事件靠近警戒圈：「N 件事件靠近警戒圈」＋查看地圖。
/// - 家人的即時圈超過 15 分鐘沒有回報：「部分家人的即時圈沒有回報」。**只計家人**，
///   自己這支手機的圈不算；單人使用者永遠不會看到這個警告。
/// - 其餘：單人「守護中：你」，多人「警戒圈一切平安」。
/// 每個狀態都有文字標籤，不只靠顏色。
struct FamilyStatusCard: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(TabRouter.self) private var router
    @Query private var members: [LocalFamilyMember]
    @Query private var events: [LocalSafetyEvent]
    @Query private var regionAlerts: [RegionAlert]

    private var status: SafetyOverview {
        SafetyOverview.compute(events: events, regionAlerts: regionAlerts, members: members)
    }

    /// 共用 [FamilySyncService.isSolo]（D1 統一規則）
    private var isSoloUser: Bool { sync.isSolo(localMembers: members) }

    /// 只計「家人」的即時圈：自己的圈在自己手上，不存在「沒有回報」
    private var staleFamilyLiveCircleCount: Int {
        guard !isSoloUser else { return 0 }
        return members.filter { !$0.isCurrentUser }.flatMap(\.lifeCircles).filter {
            $0.kind == .live && !$0.isActiveForAlerts
        }.count
    }

    private var activeVisibleEvents: [LocalSafetyEvent] {
        events.filter { $0.isActiveForAwareness && !$0.isArchived && !EventVisibility.isSuppressed($0) }
    }

    private var nearbyActiveEventCount: Int {
        activeVisibleEvents.filter { nearestCircleDistance($0, members) <= NearbyScope.maxMeters }.count
    }

    private enum Tone {
        case danger, attention, safe

        var color: Color {
            switch self {
            case .danger: HCColor.danger
            case .attention: HCColor.attention
            case .safe: HCColor.safe
            }
        }

        var icon: String {
            switch self {
            case .danger: "exclamationmark.shield.fill"
            case .attention: "location.slash.fill"
            case .safe: "checkmark.shield.fill"
            }
        }
    }

    private var tone: Tone {
        if !status.isAllClear { return .danger }
        return staleFamilyLiveCircleCount > 0 ? .attention : .safe
    }

    private var headline: String {
        if !status.isAllClear { return "\(status.attentionCount) 件事件靠近警戒圈" }
        if staleFamilyLiveCircleCount > 0 { return "部分家人的即時圈沒有回報" }
        return isSoloUser ? "守護中：你" : "警戒圈一切平安"
    }

    private var subline: String {
        if !status.isAllClear {
            // 計數已含主流媒體報導，文案不可只說「官方已確認」——那會把媒體來源冒充成官方
            return "經官方或主流媒體確認的事件落在提醒範圍內，點開地圖確認位置與建議。"
        }
        if staleFamilyLiveCircleCount > 0 {
            return "\(staleFamilyLiveCircleCount) 個家人的即時圈超過 15 分鐘沒有回報（可能沒電、關機或沒有網路），舊位置不會用來判斷警報。"
        }
        if isSoloUser {
            return nearbyActiveEventCount == 0
                ? "附近 24 小時無事件"
                : "附近有 \(nearbyActiveEventCount) 件事件，你的警戒圈平安"
        }
        return "目前沒有需要注意的事件，安心圈持續看守中。"
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HCSpacing.x3) {
                HStack(alignment: .top, spacing: HCSpacing.x3) {
                    Image(systemName: tone.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: HCSpacing.x6 * 2, height: HCSpacing.x6 * 2)
                        .background(tone.color.gradient, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text(headline)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(tone == .danger ? HCColor.danger : .primary)
                        Text(subline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if !status.isAllClear {
                    Button {
                        router.selection = TabRouter.mapTab
                    } label: {
                        Label("查看地圖", systemImage: "map.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HCColor.danger)
                    .controlSize(.large)
                }
                Divider()
                eventsRow
                if status.isAllClear { nearestShelterRow }
            }
            .hcCard()
        }
        .listRowInsets(
            EdgeInsets(top: HCSpacing.x1, leading: HCSpacing.x4, bottom: HCSpacing.x1, trailing: HCSpacing.x4)
        )
        .listRowBackground(Color.clear)
    }

    /// 動態入口：附近與全台進行中的件數，點了進「動態」分頁
    private var eventsRow: some View {
        Button {
            router.openEvents()
        } label: {
            HStack(spacing: HCSpacing.x3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HCColor.brand)
                    .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                    .background(HCColor.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HCSpacing.x1) {
                    Text("附近動態")
                        .font(.subheadline.weight(.semibold))
                    Text("附近 \(nearbyActiveEventCount) 件 · 全台 \(activeVisibleEvents.count) 件進行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("附近動態，附近 \(nearbyActiveEventCount) 件，全台 \(activeVisibleEvents.count) 件進行中。點兩下查看動態分頁")
    }

    /// 全空狀態退而求其次：給一個「就算沒事，這附近有這個避難所」的實用資訊。
    /// 座標取本人成員的圈心；本人還沒設圈就不顯示。超過 50 公里（人在境外）也不顯示。
    @ViewBuilder
    private var nearestShelterRow: some View {
        if let circle = members.first(where: \.isCurrentUser)?.lifeCircles.first,
           let nearest = EmergencyResourceStore.nearest(
               kind: ResourceKind.shelter, latitude: circle.latitude, longitude: circle.longitude),
           nearest.distanceMeters <= 50_000 {
            Button {
                router.selection = TabRouter.mapTab
            } label: {
                HStack(spacing: HCSpacing.x3) {
                    Image(systemName: "tent.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HCColor.brand)
                        .frame(width: HCSpacing.x6 + HCSpacing.x2, height: HCSpacing.x6 + HCSpacing.x2)
                        .background(HCColor.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Text("最近避難所")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HCColor.brand)
                        Text(nearest.resource.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(shelterDistanceText(nearest.distanceMeters))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
    }

    private func shelterDistanceText(_ meters: Int) -> String {
        meters >= 1_000
            ? String(format: "距離約 %.1f 公里", Double(meters) / 1_000)
            : "距離約 \(meters) 公尺"
    }
}
