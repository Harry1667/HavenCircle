import SwiftUI
import MapKit
import SwiftData

/// 成員詳情的「今天的軌跡」：24 小時內的折線＋起訖點，下方列出到達／離開事件。
/// 資料只有本人開啟位置分享才會存在（關閉分享就刪除），且只保留 24 小時；
/// 軌跡是依定位回報連成的概略路線，不是逐秒追蹤，點與點之間可能相隔數分鐘。
struct MemberTrailSection: View {
    let uid: String
    @Environment(FamilySyncService.self) private var sync
    @State private var points: [TrailPoint] = []
    @State private var events: [ArrivalEvent] = []
    @State private var isLoading = true

    var body: some View {
        Section {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("讀取軌跡中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if points.count < 2 {
                Text("過去 24 小時還沒有足夠的軌跡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                trailMap
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isLoading {
                if events.isEmpty {
                    Text("今天還沒有到達或離開的紀錄")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        HStack {
                            Label(
                                event.message,
                                systemImage: event.kind == .arrive ? "arrow.down.right.circle" : "arrow.up.right.circle"
                            )
                            .font(.subheadline)
                            Spacer()
                            Text(event.timeText).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } header: {
            Text("今天的軌跡")
        } footer: {
            Text("軌跡與到達／離開紀錄只保留 24 小時，對方關閉位置分享時會一併刪除。")
        }
        .task(id: uid) { await load() }
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.sample.latitude, longitude: $0.sample.longitude) }
    }

    private var trailMap: some View {
        let coords = coordinates
        return Map(initialPosition: .region(Self.region(fitting: coords)), interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coords)
                .stroke(HCColor.brand, lineWidth: 4)
            if let first = points.first, let last = points.last {
                Annotation(
                    "起點 \(LiveLocationPresence.clockText(first.sample.time))",
                    coordinate: CLLocationCoordinate2D(latitude: first.sample.latitude, longitude: first.sample.longitude)
                ) {
                    Image(systemName: "flag.fill").foregroundStyle(HCColor.safe)
                }
                Annotation(
                    "最新 \(LiveLocationPresence.clockText(last.sample.time))",
                    coordinate: CLLocationCoordinate2D(latitude: last.sample.latitude, longitude: last.sample.longitude)
                ) {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(HCColor.brand)
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("過去 24 小時軌跡地圖")
    }

    private var summaryText: String {
        guard let first = points.first, let last = points.last else { return "" }
        let km = TrailPolicy.totalDistance(points.map(\.sample)) / 1_000
        return "\(LiveLocationPresence.clockText(first.sample.time))–\(LiveLocationPresence.clockText(last.sample.time))・共 \(points.count) 個點・約 \(String(format: "%.1f", km)) 公里"
    }

    private func load() async {
        isLoading = true
        async let trail = sync.fetchTrail(forUid: uid)
        async let history = sync.fetchArrivalHistory(forUid: uid)
        points = await trail
        events = await history
        isLoading = false
    }

    /// 包住所有點並留 30% 邊界；單點或極小範圍給最小視野
    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 121), span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.3, 0.005),
                longitudeDelta: max((maxLng - minLng) * 1.3, 0.005)
            )
        )
    }
}

/// 「更新位置」按鈕：請這位家人的手機現在回報一次位置。
/// 對方沒開位置分享時不會有回應；按鈕會說明這點，不假裝一定成功。
struct RequestLocationButton: View {
    let uid: String
    let name: String
    @Environment(FamilySyncService.self) private var sync
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @State private var isSending = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await send() }
            } label: {
                HStack {
                    Label("更新位置", systemImage: "arrow.triangle.2.circlepath")
                    if isSending { ProgressView() }
                }
            }
            .disabled(isSending)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        switch await sync.requestLocationUpdate(forUid: uid, requesterName: displayName) {
        case .sent:
            message = "已通知\(name)的手機，對方手機回應後位置會更新（對方未開啟分享、關機或沒有網路時不會回應）"
            // 對方多半數秒內回報，稍後主動讀一次以便立即看到新位置
            try? await Task.sleep(for: .seconds(8))
            if let context = AppRuntime.container?.mainContext {
                await sync.fetchLiveLocations(context: context)
            }
        case .cooldown(let seconds):
            message = "剛剛已經請\(name)更新過，\(seconds) 秒後可再試"
        case .failed(let reason):
            message = reason
        }
    }
}
