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

                HStack {
                    Label(
                        sync.ownLiveLocation?.freshnessText ?? "等待第一次位置更新",
                        systemImage: sync.ownLiveLocation?.isFresh == true
                            ? "location.fill"
                            : "clock.badge.exclamationmark"
                    )
                    .foregroundStyle(sync.ownLiveLocation?.isFresh == true ? HCColor.safe : HCColor.attention)
                    Spacer()
                    if isWorking { ProgressView() }
                }
                .font(.caption)
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
            Text("位置只同步給家庭圈成員（以 Apple 帳號登入辨識），並可隨時停止。畫面會顯示最後更新時間；超過 15 分鐘即視為過期，不參與提醒判斷。")
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
