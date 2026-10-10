import SwiftUI

/// 資料來源頁：告訴使用者警報從哪來、多新鮮——這是安全 App 的信任基礎。
struct DataSourceView: View {
    @State private var statuses: [AlertSourceStatus] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section("警報來源與更新狀態") {
                if statuses.isEmpty && isLoading {
                    HStack {
                        ProgressView()
                        Text("正在檢查各來源…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(statuses) { status in
                        sourceRow(status)
                    }
                }

                Button {
                    Task { await reload() }
                } label: {
                    Label("重新檢查", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            Section("緊急應變資源") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("避難收容所與急救責任醫院").font(.subheadline.bold())
                    Text("避難收容所來自內政部消防署「避難收容處所點位檔」（全國約 5,900 處）；急救責任醫院來自衛福部分區名單（全國 205 家），座標取自內政部國土測繪中心。全部內建於 App，斷網時仍可查詢與導航。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("環境與統計圖層") {
                Text("空氣品質：環境部空品測站即時資料，每小時更新。治安參考：內政部警政署刑事案件統計，每季更新（統計≠即時安全程度）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("資料怎麼到你手上") {
                Text("官方資料與公開新聞 → 安心圈爬蟲（整理、去重與標記來源）→ 警報中繼站只喚醒 App → 你的手機依警戒圈、距離、時效與可信度決定是否提醒。新聞線索一律先視為「未驗證」，除非已有官方來源或多家來源交叉佐證。")
                    .font(.footnote)
                Text("你主動開啟的家人即時位置與公開警報完全分流，不會傳給警報中繼站；超過 15 分鐘的位置不會參與警報判斷。")
                    .font(.footnote)
            }

            Section("重要提醒") {
                Text("新聞與社群資訊可能誤報或延遲，不能代替官方確認。安心圈不是 110、119 或緊急救難服務；遇到立即危險請直接撥打 110 或 119。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("資料來源")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("data_source")
        .task {
            guard statuses.isEmpty else { return }
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    @ViewBuilder
    private func sourceRow(_ status: AlertSourceStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.name)
                    .font(.subheadline.bold())
                Spacer()
                Label(status.health.rawValue, systemImage: healthIcon(status.health))
                    .font(.caption.bold())
                    .foregroundStyle(healthColor(status.health))
            }
            Text(status.sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("可信度：\(status.trustLabel)")
                .font(.caption)
            Text("預計頻率：\(status.expectedUpdateText)・最後更新：\(updateText(status.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let count = status.itemCount {
                Text("目前批次：\(count) 筆")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        statuses = await AlertSourceHealthService.fetchAll()
        isLoading = false
    }

    private func updateText(_ date: Date?) -> String {
        guard let date else { return "尚未取得" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func healthIcon(_ health: AlertSourceStatus.Health) -> String {
        switch health {
        case .healthy: "checkmark.circle.fill"
        case .delayed: "clock.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private func healthColor(_ health: AlertSourceStatus.Health) -> Color {
        switch health {
        case .healthy: .green
        case .delayed: .orange
        case .unavailable: .red
        }
    }
}

/// 關於頁：版本、官網與隱私原則。
struct AboutView: View {
    @AppStorage(SettingsKeys.devToolsUnlocked) private var devToolsUnlocked = false
    /// 連點版本號計數：7 下切換「示範與開發」顯示（類似 Android 開發者選項）
    @State private var versionTaps = 0
    @State private var unlockNote: String?

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version)（\(build)）"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: versionText)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        versionTaps += 1
                        guard versionTaps >= 7 else { return }
                        versionTaps = 0
                        devToolsUnlocked.toggle()
                        unlockNote = devToolsUnlocked ? "已顯示設定頁的「示範與開發」" : "已隱藏設定頁的「示範與開發」"
                    }
                if let unlockNote {
                    Text(unlockNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: "https://havencircle.looptw.com") {
                    Link("官方網站", destination: url)
                }
            }
            Section("隱私原則") {
                Label("固定圈與事件資料儲存在這支手機", systemImage: "iphone")
                Label("即時圈必須由本人開啟，並可隨時停止", systemImage: "location.fill")
                Label("家人位置只存在 Firebase 雲端家庭圈資料庫，只有你的家庭圈成員能讀取", systemImage: "lock.fill")
            }
            .font(.subheadline)
            Section("法律文件") {
                NavigationLink("隱私權政策") { LegalDocumentView(document: .privacy) }
                NavigationLink("用戶協議") { LegalDocumentView(document: .userAgreement) }
                NavigationLink("使用條款") { LegalDocumentView(document: .terms) }
            }
            Section {
                Text("安心圈不是 110、119 或緊急救難服務。遇立即危險請直接撥打 110 或 119。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("關於安心圈")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("about")
    }
}
