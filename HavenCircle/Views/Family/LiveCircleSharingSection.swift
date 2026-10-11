import SwiftUI
import SwiftData

/// 本人裝置的即時圈控制。分享必須在每位家人的手機上各自開啟，其他人不能代開。
struct LiveCircleSharingSection: View {
    @Environment(FamilySyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.profileDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.liveLocationSharingEnabled) private var isSharing = false
    @AppStorage(SettingsKeys.liveCircleRadiusMeters) private var radiusMeters = 1_000
    @State private var isWorking = false
    @Environment(\.openURL) private var openURL
    /// @Observable：授權狀態改變（使用者從設定改成「永遠」回來）時這個畫面會自己更新
    private let location = LocationService.shared

    private var iCloudUnavailable: Bool {
        sync.state == .noAccount
    }

    var body: some View {
        Section {
            // #10：和「警報跟著我移動（不分享）」刻意拉開——這個是把位置「上傳給家人看」。
            Toggle("把我的位置分享給家人", isOn: $isSharing)
                .disabled(isWorking || (!isSharing && iCloudUnavailable))
                .onChange(of: isSharing) { _, enabled in
                    Task { await updateSharing(enabled) }
                }

            if isSharing {
                // 警戒半徑改到「設定 > 提醒設定 > 警戒範圍」調整，這裡只顯示目前值
                Text("警戒範圍：\(radiusMeters >= 1_000 ? String(format: "%g 公里", Double(radiusMeters) / 1_000) : "\(radiusMeters) 公尺")（可在設定 > 提醒設定調整）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 每 15 秒重算一次，「剛剛」會自己變成「1 分鐘前」，不靠重新整理
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    HStack {
                        Label(
                            statusText(now: timeline.date),
                            systemImage: sync.ownLiveLocation?.isFresh == true
                                ? "location.fill"
                                : "clock.badge.exclamationmark"
                        )
                        .foregroundStyle(sync.ownLiveLocation?.isFresh == true ? HCColor.safe : HCColor.attention)
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                    .font(.caption)
                }

                permissionGuidance
            } else {
                Label(
                    iCloudUnavailable ? "尚未登入 Apple 帳號，分享功能目前不可用" : "即時位置分享已停止",
                    systemImage: iCloudUnavailable ? "person.crop.circle.badge.exclamationmark" : "location.slash"
                )
                    .font(.caption)
                    .foregroundStyle(iCloudUnavailable ? HCColor.attention : Color.secondary)
            }

            if let error = sync.liveLocationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HCColor.attention)
            }
        } header: {
            Text("我的即時圈")
        } footer: {
            Text("位置只同步給家庭圈成員（以 Apple 帳號登入辨識），並可隨時停止。分享期間會保留最近 24 小時的軌跡，並在你到達或離開守護地點時通知家人；關閉分享就會刪除軌跡。畫面會顯示最後更新時間；超過 15 分鐘即視為過期，不參與提醒判斷。")
        }
        .task(id: radiusMeters) {
            guard isSharing, !iCloudUnavailable else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            await publishCurrentLocation()
        }
    }

    /// 定位權限狀態與背景定位提醒（分享中才顯示）。不強迫升級：「使用期間」可正常使用，
    /// 只是 App 在背景時家人可能較久才看到更新；要升級由使用者自己按「前往設定」。
    @ViewBuilder
    private var permissionGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch location.authorization {
            case .authorizedAlways:
                Label("定位權限：永遠（移動時背景更新）", systemImage: "location.fill")
                    .font(.caption)
            case .authorizedWhenInUse:
                Label("定位權限：使用期間", systemImage: "location")
                    .font(.caption)
                Text("目前 App 在背景時定位會停止，家人可能較久才看到你的位置。若希望像「尋找」一樣持續更新、到家或離開守護地點時通知家人，可到設定改成「永遠」；不改也能正常使用，隨時可以暫停分享。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("前往設定") { openAppSettings() }
                    .font(.caption.weight(.semibold))
            case .denied, .restricted:
                Label("定位權限：已關閉", systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(HCColor.attention)
                Button("前往設定") { openAppSettings() }
                    .font(.caption.weight(.semibold))
            default:
                Label("定位權限：尚未決定", systemImage: "location")
                    .font(.caption)
            }
            Text("請不要在多工畫面把安心圈滑掉，否則背景定位會停止，家人就看不到你的最新位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    /// 「分享中・剛剛更新」／「等待第一次位置更新」／失聯文案
    private func statusText(now: Date) -> String {
        guard let own = sync.ownLiveLocation else { return "等待第一次位置更新" }
        guard own.isFresh else { return own.freshnessText }
        return "分享中・\(LiveLocationPresence.agoText(max(0, now.timeIntervalSince(own.updatedAt))))更新"
    }

    private func updateSharing(_ enabled: Bool) async {
        guard !enabled || !iCloudUnavailable else {
            isSharing = false
            return
        }
        isWorking = true
        defer { isWorking = false }
        if enabled {
            // 開啟邏輯抽到 FamilySyncService（B3-2 與入圈後激活頁 PostJoinActivationView 共用一份）
            await sync.enableLiveLocationSharing(radiusMeters: radiusMeters, context: context)
        } else {
            LocationService.shared.syncLiveLocationSharing(isEnabled: false)
            await sync.stopLiveLocationSharing(context: context)
        }
    }

    private func publishCurrentLocation() async {
        guard let location = await LocationService.shared.currentLocation() else { return }
        await sync.publishLiveLocation(
            location,
            displayName: displayName,
            radiusMeters: radiusMeters,
            context: context
        )
    }
}
