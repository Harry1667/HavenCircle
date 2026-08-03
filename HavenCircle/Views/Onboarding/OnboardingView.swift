import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit
import os

/// 首次設定：六步分頁精靈（歡迎 → Apple 登入 → 名稱 → 警戒圈 → 通知 → 完成）。
/// 設計原則：一步只問一件事、先講理由再要權限、家人邀請可略過（軟門檻）。
struct OnboardingView: View {
    /// 重播模式（從設定頁「重看新手教學」進入）：只導覽，不建立任何資料
    var isReplay = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(FamilySyncService.self) private var familySync
    @AppStorage(SettingsKeys.profileDisplayName) private var profileName = ""
    @AppStorage(SettingsKeys.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(SettingsKeys.liveLocationSharingEnabled) private var liveLocationSharingEnabled = false
    @AppStorage(SettingsKeys.liveCircleRadiusMeters) private var liveCircleRadiusMeters = 1_000
    @AppStorage(SettingsKeys.legalAcceptanceVersion) private var legalAcceptanceVersion = ""
    @AppStorage(SettingsKeys.alertFrequencyLevel) private var alertFrequencyLevel = AlertFrequency.standard.rawValue

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var placeName = "住家"
    @State private var address = ""
    @State private var radius = 1000
    @State private var found: MKMapItem?
    @State private var searchFailed = false
    // 第一個警戒圈可選固定圈或本人即時圈
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel = ""
    @State private var pickedDistrict: String?
    @State private var locating = false
    @State private var locationHint = ""
    @State private var isFollowMe = false
    @State private var notificationGranted: Bool?
    @State private var legalAccepted = false

    enum Step: Int, CaseIterable {
        case welcome, signIn, name, circle, notification, done
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                if isReplay {
                    Label("教學模式：不會儲存變更或要求系統權限", systemImage: "eye.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HCColor.brand)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(HCColor.brand.opacity(0.08))
                }
                TabView(selection: $step) {
                    welcomePage.tag(Step.welcome)
                    signInPage.tag(Step.signIn)
                    namePage.tag(Step.name)
                    circlePage.tag(Step.circle)
                    notificationPage.tag(Step.notification)
                    donePage.tag(Step.done)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 只允許用按鈕前進：滑動跳步會略過必要輸入
                .animation(.easeInOut, value: step)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .welcome && step != .done {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") {
                            withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        }
                    }
                }
                // 登入步驟右上角提供「跳過」（軟門檻：不登入也能用完整警報功能）
                if step == .signIn && !isReplay {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("跳過") { withAnimation { step = .name } }
                    }
                }
                if isReplay {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("關閉") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - 進度條

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? HCColor.brand : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .accessibilityLabel("設定進度：第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
    }

    // MARK: - 第 1 步：歡迎

    /// 小螢幕適配：內容可捲動、條款與 CTA 固定在底部永不被遮——
    /// 原本的固定 VStack 在 iPhone 12 等較矮機型會把條款區擠出畫面
    private var welcomePage: some View {
        ScrollView {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            // 品牌漸層圓底座＋白色盾牌：歡迎頁的第一眼要像產品 logo，不是浮著的系統圖示
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [HCColor.brand.opacity(0.8), HCColor.brand],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 108, height: 108)
                    .shadow(color: HCColor.brand.opacity(0.3), radius: 16, y: 8)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            Text("安心圈")
                .font(.system(.largeTitle, design: .rounded).bold())
            Text("替家人留意住家與生活範圍的安全動態")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 三張價值卡統一品牌色：歡迎頁只留一個主色，靠圖示與文字區分——
            // 綠橘藍各自搶焦會讓第一印象像「通用範例」而不是有品牌的產品
            VStack(spacing: 12) {
                valueCard("checkmark.seal.fill", HCColor.brand,
                          "官方示警來源", "災害警報來自 NCDR 民生示警等政府公開資料")
                valueCard("mappin.and.ellipse", HCColor.brand,
                          "兩種警戒圈", "即時圈跟著家人手機；地點警戒圈守護住家、倉庫等地點")
                valueCard("person.2.fill", HCColor.brand,
                          "家人互報平安", "一鍵回報「我平安」，家人立刻知道")
            }
            .padding(.horizontal, 24)

            Label("安心圈不是緊急服務；遇立即危險請撥打 110 或 119。", systemImage: "phone.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HCColor.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 12)
        }
        .safeAreaInset(edge: .bottom) {
            // 法律同意放在流程起點：使用者在填任何資料、授任何權限之前先決定要不要同意，
            // 不同意就不會發生「輸入都填了、權限都給了才被條款卡住」的先斬後奏
            VStack(spacing: 10) {
                if !isReplay {
                    legalAgreementBlock
                        .padding(.horizontal, 24)
                }
                primaryButton("同意並開始設定", disabled: !isReplay && !legalAccepted) {
                    withAnimation { step = .signIn }
                }
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - 第 2 步：Apple 登入（右上角可跳過）

    @ViewBuilder
    private var signInPage: some View {
        if isReplay {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(HCColor.brand)
                stepHeader("用 Apple 帳號登入", "正式設定時可帶入名稱與 email，並建立 Firebase 家庭圈；這次重看不會開啟登入視窗。")
                Spacer()
                primaryButton("下一步") { withAnimation { step = .name } }
            }
            .padding(.bottom, 24)
        } else {
            AppleSignInPage(onSignedIn: {
                // 登入成功：帶入的名稱直接預填下一步，少打一次字
                if name.isEmpty { name = profileName }
                withAnimation { step = .name }
            })
        }
    }

    private func valueCard(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 第 2 步：名稱

    private var namePage: some View {
        ScrollView {
            VStack(spacing: 16) {
                stepHeader("怎麼稱呼你？", "這個名稱會顯示在家人的安否回報裡，例如「媽媽 回報了平安」。")
                TextField("你的名稱", text: $name)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 48)
            }
            .padding(.top, 56)
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton("下一步", disabled: !isReplay && name.trimmingCharacters(in: .whitespaces).isEmpty) {
                withAnimation { step = .circle }
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - 第 3 步：第一個生活圈

    private var circlePage: some View {
        VStack(spacing: 0) {
            stepHeader("設定第一個警戒圈", "即時圈跟著這支手機移動；地點警戒圈適合住家、倉庫或家人的家。只有圈內的事件才會提醒。")
                .padding(.bottom, 8)
            Form {
                Section {
                    if isFollowMe {
                        LabeledContent("圈名稱", value: "我的即時圈")
                        currentLocationPicker
                    } else {
                        TextField("地點名稱（例如：住家）", text: $placeName)
                        TextField("城市或地址", text: $address)
                            .onChange(of: address) {
                                found = nil
                                searchFailed = false
                            }
                            // 停止輸入 0.7 秒自動搜尋（與固定圈編輯器同一套行為）；按鈕保留供立即搜尋
                            .task(id: address) {
                                let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !isReplay, !query.isEmpty,
                                      address != pickedLabel,
                                      found == nil, picked == nil else { return }
                                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                                await search()
                            }
                        Button {
                            Task { await search() }
                        } label: {
                            Label("使用 Apple Maps 搜尋位置", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        currentLocationPicker
                        if let found, picked == nil {
                            Label("找到：\(found.name ?? address)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(HCColor.safe)
                        } else if searchFailed && picked == nil {
                            Text("找不到這個地點，請修改地址或改用目前位置；未確認位置前不會建立警戒圈。")
                                .font(.caption)
                                .foregroundStyle(HCColor.attention)
                        }
                    }
                    Stepper("提醒半徑：\(radius) 公尺", value: $radius, in: 300...3000, step: 100)
                } footer: {
                    // 服務範圍誠實告知（行政區已擴至全國 375 鄉鎮市區，文案同步更新）
                    Text("颱風、豪雨等區域型警報依行政區自動比對，已支援全國鄉鎮市區；地址判斷不到行政區時，可稍後在警戒圈編輯裡手動指定。")
                }
                Section {
                    Toggle("建立我的即時圈", isOn: $isFollowMe)
                        .onChange(of: isFollowMe) { _, on in
                            locationHint = ""
                            if on && !isReplay && LocationService.shared.authorization == .notDetermined {
                                LocationService.shared.requestPermissionIfNeeded()
                                locationHint = "允許使用位置後，請點「取得目前位置作為起點」。"
                            }
                        }
                } footer: {
                    Text("開啟後，警戒圈會跟著這支手機移動，並在登入 Apple 帳號、加入家庭圈後分享給家人。設定完成後會再詢問是否升級為「永遠允許」定位，讓離開 App 後也能更新；可隨時在家人頁停止，畫面會標示最後更新時間。")
                }
            }
            .scrollContentBackground(.hidden)
            // 這一步只用到「使用期間」定位；Always 升級留到完成頁——
            // 同一步連跳兩次系統定位彈窗會讓第二窗直接被系統吞掉（使用者選過「僅使用期間」後不再詢問）
            primaryButton("下一步", disabled: !circleCanAdvance) {
                advanceFromCircle()
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - 第 4 步：通知權限

    private var notificationPage: some View {
        ScrollView {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(HCColor.brand)
            stepHeader("打開通知，關鍵時刻才收得到",
                       "只有「落在有效警戒圈內、且可信度足夠」的事件才會推播；未驗證線索只在 App 內顯示，不會吵你。")

            // 通知頻率：讓使用者一開始就決定要收多少通知（小／中／大，依事件嚴重度）
            VStack(alignment: .leading, spacing: 8) {
                Text("通知頻率")
                    .font(.subheadline.weight(.semibold))
                Picker("通知頻率", selection: $alertFrequencyLevel) {
                    ForEach(AlertFrequency.allCases) { level in
                        Text(level.shortLabel).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((AlertFrequency(rawValue: alertFrequencyLevel) ?? .standard).explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)

            if notificationGranted == true {
                Label("通知已允許", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HCColor.safe)
            } else if notificationGranted == false {
                VStack(spacing: 8) {
                    Label("通知尚未開啟，安心圈無法主動提醒你。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(HCColor.attention)
                    Button("前往系統設定", systemImage: "gearshape") { openSystemSettings() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            Text("安心圈不是緊急服務；遇立即危險請撥打 110 或 119。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HCColor.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 40)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if isReplay {
                    Text("教學模式不會顯示系統通知權限視窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    primaryButton("下一步") { withAnimation { step = .done } }
                } else if notificationGranted == nil {
                    primaryButton("允許通知") {
                        Task {
                            notificationGranted = await NotificationScheduler.requestPermission()
                        }
                    }
                    Button("稍後再說") { withAnimation { step = .done } }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    primaryButton("下一步") { withAnimation { step = .done } }
                }
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task {
            guard !isReplay, notificationGranted == nil else { return }
            switch await NotificationScheduler.authorizationStatus() {
            case .authorized, .provisional, .ephemeral:
                notificationGranted = true
            case .denied:
                notificationGranted = false
            default:
                break
            }
        }
    }

    // MARK: - 第 5 步：完成

    private var donePage: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(HCColor.safe)
                    .accessibilityHidden(true)
                stepHeader("設定完成！", isReplay
                           ? "以下是教學示範摘要，關閉後不會變更目前設定。"
                           : "接下來會先打開安全地圖，確認剛建立的警戒圈與提醒半徑。")
                setupSummaryCard
                if !isReplay, isFollowMe, LocationService.shared.authorization != .authorizedAlways {
                    VStack(spacing: 8) {
                        Label("即時圈需要「永遠允許」定位，離開 App 後才能持續更新位置。", systemImage: "location.slash.fill")
                            .font(.caption)
                            .foregroundStyle(HCColor.attention)
                            .multilineTextAlignment(.center)
                        // Always 的系統升級彈窗只有一次機會，留到使用者看完摘要、理解用途的這一刻；
                        // LocationService 是 @Observable，授權成功後這整塊會自動消失
                        Button("允許背景定位", systemImage: "location.fill") {
                            LocationService.shared.requestAlwaysPermission()
                        }
                        .font(.subheadline.weight(.semibold))
                        Button("或前往系統設定開啟", systemImage: "gearshape") { openSystemSettings() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 32)
                }
                // 可點的行動卡（不是說明文字）：點了直接完成設定並跳到家人頁的邀請介面
                Button {
                    finishSetup(routeToFamily: true)
                } label: {
                    HStack(spacing: 0) {
                        valueCard("person.crop.circle.badge.plus", HCColor.brand,
                                  "邀請家人（可略過）",
                                  "點這裡完成設定並前往「家人」頁，用 QR code 或 8 位邀請碼邀請；需要登入 Apple 帳號。")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 12)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReplay)
                .padding(.horizontal, 24)
                Label("安心圈不是緊急服務；遇立即危險請撥打 110 或 119。", systemImage: "phone.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HCColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            // 法律同意已在第一步完成，這裡直接放行
            primaryButton(isReplay ? "完成" : "前往地圖確認") { finishSetup() }
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private var legalAgreementBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $legalAccepted) {
                Text("我已閱讀並同意用戶協議與使用條款，且了解隱私權政策")
                    .font(.footnote.weight(.semibold))
            }
            HStack(spacing: 16) {
                Link("隱私權政策", destination: LegalDocumentKind.privacy.webURL)
                Link("用戶協議", destination: LegalDocumentKind.userAgreement.webURL)
                Link("使用條款", destination: LegalDocumentKind.terms.webURL)
            }
            .font(.caption.weight(.semibold))
            Text("即時圈只有本人在自己的手機上主動開啟後才會分享最新位置；可隨時停止。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var currentLocationPicker: some View {
        Button {
            guard !isReplay else {
                pickedLabel = "教學示範位置"
                picked = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
                return
            }
            Task { await useCurrentLocation() }
        } label: {
            HStack {
                Spacer()
                Label(isFollowMe ? "取得目前位置作為起點" : "使用目前位置", systemImage: "location.fill")
                if locating { ProgressView() }
                Spacer()
            }
        }
        if !pickedLabel.isEmpty {
            Label("已確認位置：\(pickedLabel)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(HCColor.safe)
        } else if !locationHint.isEmpty {
            Text(locationHint)
                .font(.caption)
                .foregroundStyle(HCColor.attention)
        }
        if !isReplay,
           LocationService.shared.authorization == .denied ||
           LocationService.shared.authorization == .restricted {
            Button {
                openSystemSettings()
            } label: {
                Label("前往系統設定開啟定位", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var circleCanAdvance: Bool {
        if isReplay { return true }
        if isFollowMe { return picked != nil }
        return picked != nil || found != nil
    }

    private var setupSummaryCard: some View {
        VStack(spacing: 12) {
            setupSummaryRow("警戒圈", value: isFollowMe ? "我的即時圈" : (placeName.isEmpty ? "住家" : placeName), icon: "mappin.and.ellipse")
            Divider()
            setupSummaryRow("確認位置", value: circleLocationSummary, icon: "location.fill")
            Divider()
            setupSummaryRow("提醒半徑", value: "\(radius) 公尺", icon: "scope")
            Divider()
            setupSummaryRow("通知", value: notificationSummary, icon: "bell.fill")
            Divider()
            setupSummaryRow("Apple 帳號", value: iCloudSummary, icon: "person.crop.circle.fill")
            Divider()
            setupSummaryRow("定位權限", value: locationAuthorizationSummary, icon: "hand.raised.fill")
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func setupSummaryRow(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var circleLocationSummary: String {
        if !pickedLabel.isEmpty { return pickedLabel }
        if let found { return found.name ?? address }
        return isReplay ? "教學示範" : "尚未確認"
    }

    private var notificationSummary: String {
        switch notificationGranted {
        case true: "已允許"
        case false: "未允許，可前往系統設定"
        case nil: "稍後決定"
        }
    }

    private var iCloudSummary: String {
        switch familySync.state {
        case .ready: "已登入，可建立家庭圈"
        case .sharing: "家庭圈同步中"
        case .noAccount: "尚未登入 Apple 帳號"
        case .error: "暫時無法使用"
        case .unknown: "正在確認狀態"
        }
    }

    private var locationAuthorizationSummary: String {
        guard isFollowMe else { return "地點警戒圈不需背景定位" }
        return switch LocationService.shared.authorization {
        case .authorizedAlways: "永遠允許，可背景更新"
        case .authorizedWhenInUse: "使用 App 期間；背景更新待開啟"
        case .denied, .restricted: "未允許，需前往系統設定"
        case .notDetermined: "尚未決定"
        @unknown default: "狀態未知"
        }
    }

    // MARK: - 共用元件與邏輯

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private func primaryButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(HCColor.brand) // CTA 一律品牌群青：Onboarding 在 AppTabs 的 tint 範圍外，要自己指定
        .disabled(disabled)
        .padding(.horizontal, 24)
    }

    private func advanceFromCircle() {
        withAnimation { step = .notification }
    }

    private func search() async {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            found = nil
            searchFailed = false
            return
        }
        picked = nil
        pickedLabel = ""
        locationHint = ""
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            found = try await MKLocalSearch(request: request).start().mapItems.first
            searchFailed = (found == nil)
        } catch {
            AppLog.data.error("首次設定地點搜尋失敗：\(error.localizedDescription)")
            found = nil
            searchFailed = true
        }
    }

    /// 一鍵帶入目前位置（與家人分頁圈編輯器同一套行為）：反查地名與行政區
    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        guard LocationService.shared.isAuthorized else {
            switch LocationService.shared.authorization {
            case .denied, .restricted:
                locationHint = "定位權限未開啟，請前往系統設定，或改用地址搜尋守護地點。"
            default:
                LocationService.shared.requestPermissionIfNeeded()
                locationHint = "允許定位權限後，請再點一次取得位置。"
            }
            return
        }
        guard let location = await LocationService.shared.currentLocation() else {
            locationHint = "取不到目前位置，請稍後再試或改用地址搜尋"
            return
        }
        picked = location.coordinate
        locationHint = ""
        if let place = await MapReverseGeocoder.lookup(location) {
            let district = Self.guessDistrict(from: place.searchableText)
            pickedLabel = place.approximateLabel(district: district) ?? "座標已取得"
            if district != Districts.unspecified { pickedDistrict = district }
            if address.isEmpty { address = pickedLabel }
        } else {
            pickedLabel = "座標已取得"
        }
    }

    /// routeToFamily：使用者按了「邀請家人」行動卡——完成設定後直接前往家人頁的邀請介面，
    /// 並跳過守護圈動效與功能導覽（先讓他做想做的事；導覽可從設定頁重看）
    private func finishSetup(routeToFamily: Bool = false) {
        let displayName = name.trimmingCharacters(in: .whitespaces)
        // 重播模式只是導覽：不建立資料、不動旗標，關掉就好
        if isReplay {
            dismiss()
            return
        }
        let me = LocalFamilyMember(name: displayName.isEmpty ? "我" : displayName, relationship: "擁有者")
        me.isCurrentUser = true
        context.insert(me)
        // 固定圈與即時圈都必須先確認位置；不可用任意預設座標造成錯誤安心。
        guard let coordinate = picked ?? found?.placemark.coordinate else {
            context.delete(me)
            locationHint = "請先確認警戒圈位置。"
            withAnimation { step = .circle }
            return
        }
        let circle = LocalLifeCircle(
            name: isFollowMe ? "我的即時圈" : (placeName.isEmpty ? "住家" : placeName),
            encryptedAddress: isFollowMe
                ? "位置由這支手機分享"
                : AddressCrypto.encrypt(pickedLabel.isEmpty ? (found?.name ?? address) : pickedLabel),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radius,
            alertTypes: EventCategory.defaultSelection,
            member: me
        )
        circle.district = pickedDistrict ?? Self.guessDistrict(from: "\(found?.name ?? "") \(address)")
        circle.isFollowMe = isFollowMe
        circle.kind = isFollowMe ? .live : .fixed
        circle.locationUpdatedAt = isFollowMe && picked != nil ? .now : nil
        if isFollowMe {
            liveLocationSharingEnabled = true
            liveCircleRadiusMeters = radius
        }
        context.insert(circle)
        context.saveReporting()
        // 跟隨圈監聽開關跟著圈的存在與否走
        LocationService.shared.syncFollowMonitoring(
            hasFollowCircle: FollowCircleService.hasFollowCircle(context: context)
        )
        // 名稱同步進個人資訊（安否回報署名用），使用者不必到設定頁再填一次
        if !displayName.isEmpty { profileName = displayName }
        legalAcceptanceVersion = LegalDocumentKind.revision
        if isFollowMe {
            LocationService.shared.syncLiveLocationSharing(isEnabled: true)
            Task {
                guard let location = await LocationService.shared.currentLocation() else { return }
                await familySync.publishLiveLocation(
                    location,
                    displayName: displayName.isEmpty ? "我" : displayName,
                    radiusMeters: radius,
                    context: context
                )
            }
        }
        // 完成旗標與家人資料脫鉤：之後就算刪光家人資料也不會被打回新手流程
        onboardingCompleted = true
        // 匿名統計：新手設定完成是最重要的漏斗事件（啟動數 vs 完成數＝流失率）
        Analytics.track("onboarding_completed")
        if routeToFamily {
            // 直達家人頁邀請介面（AppTabs 出現後由 DeepLinkStore 補路由）
            DeepLinkStore.pending = URL(string: "havencircle://family")
        } else {
            // 種下守護圈開場動效旗標：首次進地圖時演「鏡頭飛向生活圈」的確認儀式
            UserDefaults.standard.set(true, forKey: SettingsKeys.guardianIntroPending)
            // 種下功能導覽旗標：首次進主畫面時黑幕聚光燈跨分頁逐步介紹
            UserDefaults.standard.set(true, forKey: SettingsKeys.homeTourPending)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// 從地址文字比對全國鄉鎮市區（供區域型警報使用）；找不到就標「未指定」
    static func guessDistrict(from text: String) -> String {
        Districts.all.dropFirst().first { text.contains($0) } ?? Districts.unspecified
    }
}

#if DEBUG
#Preview {
    OnboardingView()
        .modelContainer(PreviewSupport.container())
}
#endif
