import SwiftUI
import SwiftData

/// 成員詳情頁——依成員三態呈現，設計鐵律：
/// 「一個守護地點＝剛好一個警戒圈」，額度＝地點數（見 FamilyHomeView.gateAddPlace）。
/// 這裡不再提供任何「往現有成員新增警戒圈」的無閘門入口——新增守護地點一律從
/// 家人頁「新增守護地點」走（有 gateAddPlace 額度閘門），本頁只負責呈現/編輯/刪除既有的圈。
struct MemberDetailView: View {
    let member: LocalFamilyMember
    @Environment(\.modelContext) private var context
    @Environment(FamilySyncService.self) private var sync
    @State private var editing: LocalLifeCircle?
    /// 僅用於地點孤兒補救：地點成員已建立但一個警戒圈都沒有時，唯一的「補建」入口
    /// （不是「新增第二個」，member 本來就 0 圈，建立後仍維持 1 地點＝1 圈）
    @State private var creatingCircle = false
    /// 「我的卡」編輯名字（只有本人那張卡有）
    @State private var editingName = false
    @AppStorage(SettingsKeys.profileDisplayName) private var ownName = ""

    private var fixedCircles: [LocalLifeCircle] {
        member.lifeCircles.filter { $0.kind == .fixed }
    }

    var body: some View {
        List {
            if member.isCurrentUser {
                // 名字：家人看到的稱呼；沒設定時家人會看到「家人 N」，所以這裡明講並給編輯入口
                Section("我的名字") {
                    Button {
                        editingName = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(FamilyNaming.clean(ownName).isEmpty ? "尚未設定" : FamilyNaming.clean(ownName))
                                    .foregroundStyle(.primary)
                                if FamilyNaming.clean(ownName).isEmpty {
                                    Text("家人目前會看到你是「家人 N」")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("編輯").foregroundStyle(HCColor.brandText)
                        }
                    }
                    .accessibilityIdentifier("member.editNameButton")
                }
                // 自己的詳情頁直接放即時圈控制，不再是「請回家人頁開啟」的死路文字
                LiveCircleSharingSection()
                if let uid = AuthService.shared.uid,
                   UserDefaults.standard.bool(forKey: SettingsKeys.liveLocationSharingEnabled) {
                    MemberTrailSection(uid: uid)
                }
            } else if member.isPlace {
                placeCircleSection
            } else {
                Section("即時圈") {
                    let liveCircles = member.lifeCircles.filter { $0.kind == .live }
                    if liveCircles.isEmpty {
                        Text("等待這位家人在自己的手機上開啟位置分享")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(liveCircles) { circle in
                            circleRow(circle)
                        }
                        if let uid = member.sharedIdentityKey {
                            RequestLocationButton(uid: uid, name: member.name)
                        }
                    }
                }
                if !member.lifeCircles.filter({ $0.kind == .live }).isEmpty,
                   let uid = member.sharedIdentityKey {
                    MemberTrailSection(uid: uid)
                }
                legacyFixedCircleSection
            }
        }
        .navigationTitle(member.isCurrentUser ? "我" : member.name)
        .analyticsScreen("member_detail")
        .sheet(isPresented: $editingName) {
            NamePromptSheet(mode: .edit) { editingName = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .formPresentationSizing()
        }
        .sheet(isPresented: $creatingCircle) { CircleEditorView(member: member).hcSheet() }
        .sheet(item: $editing) { circle in
            CircleEditorView(member: member, circle: circle).hcSheet()
        }
    }

    // MARK: - 地點（isPlace）：一個守護地點＝剛好一個警戒圈，只呈現/編輯/刪除，不提供新增

    @ViewBuilder
    private var placeCircleSection: some View {
        Section("警戒圈") {
            if fixedCircles.isEmpty {
                // 歷史孤兒（地點成員建好了但警戒圈沒設完）：這是唯一的補救入口，
                // 不是「加一個新的」——補完之後這個地點才真正符合 1:1。
                Button {
                    creatingCircle = true
                } label: {
                    Label("完成設定警戒圈", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(HCColor.attention)
                        .frame(maxWidth: .infinity)
                }
            } else {
                // 正常情況只有一個；若有多個（舊測試資料殘留）全部列出可編輯/刪除，但不給新增按鈕。
                ForEach(fixedCircles) { circle in
                    Button { editing = circle } label: { circleRow(circle) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                let sharedID = circle.remotePlaceId
                                context.delete(circle)
                                context.saveReporting()
                                GeofenceSync.sync(context: context)
                                if let sharedID { Task { await sync.deleteSharedPlaces(ids: [sharedID]) } }
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    // MARK: - 家人（person）：警戒圈是舊模型殘留，家人只該有即時圈；
    // 若有歷史殘留的固定圈，唯讀顯示＋可刪，不提供編輯與新增。

    @ViewBuilder
    private var legacyFixedCircleSection: some View {
        if !fixedCircles.isEmpty {
            Section("警戒圈") {
                ForEach(fixedCircles) { circle in
                    circleRow(circle)
                        .swipeActions {
                            Button(role: .destructive) {
                                context.delete(circle)
                                context.saveReporting()
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private func circleRow(_ circle: LocalLifeCircle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(circle.name).font(.headline)
                // 用詞鐵律：不用 circle.kind.title（模型層文案含「固定地點」），這裡自己講「警戒圈」
                Label(circle.kind == .live ? "即時圈" : "警戒圈", systemImage: circle.kind.iconName)
                    .font(.caption2.bold())
                    .foregroundStyle(circle.kind == .live ? HCColor.safe : HCColor.brandText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (circle.kind == .live ? HCColor.safe : HCColor.brand).opacity(0.12),
                        in: Capsule()
                    )
            }
            Text("\(circle.addressText) · 警戒半徑 \(circle.radiusMeters) 公尺")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if circle.kind == .live {
                Label(
                    circle.locationFreshnessText,
                    systemImage: circle.isActiveForAlerts ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(circle.isActiveForAlerts ? HCColor.safe : HCColor.attention)
            }
            Text("提醒：\(circle.alertTypes.joined(separator: "、")) · \(circle.scheduleText)")
                .font(.caption)
                .foregroundStyle(HCColor.brandText)
        }
    }
}
