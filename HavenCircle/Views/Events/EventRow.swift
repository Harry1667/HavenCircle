import SwiftUI
import CoreLocation

struct EventRow: View {
    enum Style {
        case standard
        case mapCompact
    }

    let event: LocalSafetyEvent
    let members: [LocalFamilyMember]
    let style: Style

    init(event: LocalSafetyEvent, members: [LocalFamilyMember], style: Style = .standard) {
        self.event = event
        self.members = members
        self.style = style
    }

    /// 可信度顏色（官方確認＝危險紅、確認中＝琥珀）；事件類型交給圖示表達
    private var trustColor: Color {
        event.isOfficiallyConfirmed ? HCColor.danger : HCColor.attention
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .standard:
            standardRow
        case .mapCompact:
            mapCompactRow
        }
    }

    private var standardRow: some View {
        HStack(spacing: HCSpacing.x3) {
            eventIcon(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.isDrill ? "【演練】\(event.title)" : event.title)
                    .lineLimit(2) // 卡片定高：超長標題（媒體事件偶有）截斷，不撐爆版面
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(event.approximateLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 來源、狀態與時間一起露出：全台動態不必猜「這是誰說的／還在不在」。
                // 概略位置仍只到行政區或測站周邊，避免把精確地址帶到資訊流。
                standardMetadata
            }
            Spacer(minLength: 0)
            Text(event.trustStatus)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(trustColor)
                .background(trustColor.opacity(0.12), in: Capsule())
        }
        .hcCard()
        .overlay(
            RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// 「 · N 則報導」（N>1 才有）：同一事件多篇報導合併後讓使用者知道背後有幾則
    private var reportSuffix: String {
        event.reportCountText.map { " · \($0)" } ?? ""
    }

    /// 窄卡先保住來源與狀態，時間、距離則自動換行；避免「分鐘前」孤零零掉到下一行。
    private var standardMetadata: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.sourceName)\(reportSuffix) · \(event.statusText) · \(relativeTime(event.occurredAt))")
                    .lineLimit(1)
                Text(relativeDistance(event, members))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.sourceName)\(reportSuffix) · \(event.statusText)")
                    .lineLimit(1)
                Text("\(relativeTime(event.occurredAt)) · \(relativeDistance(event, members))")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 地圖底部只保留事件判讀所需的資訊層級，避免小螢幕被卡片遮住。
    private var mapCompactRow: some View {
        HStack(spacing: 10) {
            eventIcon(size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.isDrill ? "【演練】\(event.title)" : event.title)
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(eventSeverityAndTrust(event))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(trustColor)
                    .fixedSize(horizontal: false, vertical: true)
                compactMetadata
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HCSpacing.x3)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// 寬度足夠時維持單行；窄機型自動拆成時間、距離兩行，不縮字也不截斷。
    private var compactMetadata: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(relativeTime(event.occurredAt))・\(relativeDistance(event, members))\(reportSuffix.replacingOccurrences(of: " · ", with: "・"))")
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(relativeTime(event.occurredAt))
                Text(relativeDistance(event, members))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func eventIcon(size: CGFloat) -> some View {
        Image(systemName: iconName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(trustColor)
            .frame(width: size, height: size)
            .background(
                trustColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: HCRadius.badge, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var iconName: String {
        if event.isDrill { return "bell.and.waves.left.and.right" }
        return EventCategory.icon(for: event.eventType)
    }
}

/// 事件到「最近生活圈」的距離，含歸屬（誰的哪個生活圈）。
/// 只顯示百公尺級精度，避免暴露精確位置。
func relativeDistance(_ event: LocalSafetyEvent, _ members: [LocalFamilyMember]) -> String {
    let point = CLLocation(latitude: event.latitude, longitude: event.longitude)
    let candidates = members.flatMap { member in
        member.lifeCircles.filter(\.isActiveForAlerts).map { circle in
            (
                ownerName: member.name,
                circleName: circle.name,
                distance: point.distance(from: CLLocation(latitude: circle.latitude, longitude: circle.longitude)),
                isCurrentUser: member.isCurrentUser
            )
        }
    }
    guard let nearest = candidates.min(by: { $0.distance < $1.distance }) else { return "尚未設定警戒圈" }
    let meters = max(Int(nearest.distance / 100) * 100, 100)
    // 本人的預設圈常叫「我的附近」，重複顯示名稱只會讓全球事件卡變長；
    // 家人圈仍保留名稱，讓使用者知道距離是以哪一個守護範圍判讀。
    let circleLabel = nearest.isCurrentUser
        ? "你的警戒圈"
        : "\(nearest.ownerName)的「\(nearest.circleName)」"
    // 全台動態不需要暴露到小數公里；超過 100 公里只表達「非你的附近」，保留閱讀價值而不製造假精確。
    if meters >= 100_000 {
        return "距離\(circleLabel)很遠"
    }
    if meters >= 1_000 {
        let km = Int((Double(meters) / 1_000).rounded())
        return "距離\(circleLabel)約 \(km) 公里"
    }
    return "距離\(circleLabel)\(meters) 公尺"
}

/// 相對時間文字（不依賴裝置語系，全繁中）
func relativeTime(_ date: Date) -> String {
    let seconds = Date.now.timeIntervalSince(date)
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "剛剛" }
    if minutes < 60 { return "\(minutes) 分鐘前" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) 小時前" }
    return "\(hours / 24) 天前"
}

/// 部分來源會把嚴重程度與驗證狀態填成同一句，顯示時合併避免重複。
func eventSeverityAndTrust(_ event: LocalSafetyEvent) -> String {
    event.severity == event.trustStatus
        ? event.severity
        : "\(event.severity)・\(event.trustStatus)"
}

/// 「附近」的距離語意：離所有有效警戒圈超過這個距離的事件不算「附近」。
/// 審查發現：沒有上限時，145 公里外的花蓮路況會被當「附近更新」推到台北使用者眼前，
/// 稀釋真正相關的訊號。超過上限的事件收進「全台其他」次級清單，不是消失。
/// 2026-07-23 使用者實測裁決：30 公里仍太寬（基隆火車事故出現在台北首屏），收到 10 公里。
/// 安心頁事件串、地圖附近卡、提醒中心分組共用此值——「附近」只有一種定義。
enum NearbyScope {
    static let maxMeters: Double = 10_000
}

/// 事件到最近有效警戒圈的距離（公尺），供排序使用
func nearestCircleDistance(_ event: LocalSafetyEvent, _ members: [LocalFamilyMember]) -> Double {
    let point = CLLocation(latitude: event.latitude, longitude: event.longitude)
    return members.flatMap(\.lifeCircles).filter(\.isActiveForAlerts)
        .map { point.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
        .min() ?? .greatestFiniteMagnitude
}
