import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import os

struct CircleEditorView: View {
    let member: LocalFamilyMember
    let circle: LocalLifeCircle?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var radius = 1000
    @State private var found: MKMapItem?
    @State private var searchFailed = false
    @State private var district = Districts.unspecified
    @State private var scheduleEnabled = false
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]  // 預設週一到週五
    @State private var startHour = 8
    @State private var endHour = 19
    // 可把目前位置保存成固定圈；儲存後不會跟著手機移動
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel = ""
    @State private var locating = false
    @State private var locationHint = ""
    @State private var locationNeedsConfirmation: Bool
    /// 行政區是否由地址搜尋／目前位置反查「自動判定」而來（非使用者手動在進階設定裡挑的）；
    /// 只用來決定要不要顯示「自動判定」提示行，不影響實際儲存的 district 值。
    @State private var districtAutoDetected = false
    /// 「進階設定」（手動行政區 Picker）展開狀態：新增地點情境下預設展開，
    /// 自動判定成功就收合，判定失敗（含尚未查詢）維持展開讓人手動挑。
    @State private var advancedExpanded = false
    // MARK: - 第三條路：地圖上直接點選守護地點
    // 解「鄉下老門牌搜尋失敗＋人不在現場」的雙死路——地址搜不到、目前位置又不是要設的地方時，
    // 讓使用者直接在小地圖上長按／點擊放大頭針選點。
    /// 小地圖鏡頭位置：有既有座標就置中該座標近距顯示；否則先用台灣全島視野墊著，
    /// 再由下方 `.task` 嘗試用目前位置重新置中拉近（只影響鏡頭，不會連帶把目前位置設成座標）。
    @State private var mapCameraPosition: MapCameraPosition
    /// 手指正在觸碰小地圖：暫停外層 Form 捲動，避免「想拖地圖結果表單先捲走」的手感衝突
    @State private var isTouchingMap = false
    /// 「把目前位置設為守護地點」的防誤觸確認：地點類型可能是遠端（爸媽家等）時才跳出
    @State private var showCurrentLocationConfirm = false
    /// 台灣地理中心概略座標（南投埔里一帶），地圖找不到任何座標線索時的墊底視野中心
    private static let taiwanFallbackCenter = CLLocationCoordinate2D(latitude: 23.6978, longitude: 120.9605)

    /// 新增地點接續情境：從 PlaceSelectView 選完地點名稱、550ms 後直接接著開這裡建第一個固定圈。
    /// 此時 member 名稱就是使用者剛選的地點名稱（住家／公司／⋯），標題與欄位預填據此客製化；
    /// 編輯既有圈或替一般家人新增圈都不算，外觀維持原本樣子（見 body 內 districtSection 分支）。
    private let isNewPlaceCircle: Bool
    /// 是否已成功按過「儲存」：用來跟「未儲存就離開（取消／下滑關閉）」區分——
    /// 見 `deleteOrphanPlaceIfNeeded()`，兩條離開路徑都靠 `.onDisappear` 收斂到同一個判斷點
    @State private var didSave = false

    init(member: LocalFamilyMember, circle: LocalLifeCircle? = nil) {
        self.member = member
        self.circle = circle
        let isNewPlaceCircle = member.isPlace && circle == nil
        self.isNewPlaceCircle = isNewPlaceCircle
        _name = State(initialValue: circle?.name ?? (isNewPlaceCircle ? member.name : ""))
        _address = State(initialValue: circle?.addressText ?? "")
        _radius = State(initialValue: circle?.radiusMeters ?? 1_000)
        _district = State(initialValue: circle?.district ?? Districts.unspecified)
        _scheduleEnabled = State(initialValue: circle?.scheduleEnabled ?? false)
        _weekdays = State(initialValue: Set(circle?.scheduleWeekdays ?? [2, 3, 4, 5, 6]))
        _startHour = State(initialValue: circle?.scheduleStartHour ?? 8)
        _endHour = State(initialValue: circle?.scheduleEndHour ?? 19)
        _locationNeedsConfirmation = State(initialValue: circle == nil)
        // 尚未做過任何自動判定嘗試前，進階設定預設展開，讓使用者一開始就能手動挑
        _advancedExpanded = State(initialValue: true)
        // 小地圖初始鏡頭：既有圈就近距置中該座標；新圈先用台灣全島視野墊著（避免還沒拿到
        // 目前位置前地圖畫面是空的），拿到目前位置後由 `.task` 再拉近置中一次
        if let circle {
            let center = CLLocationCoordinate2D(latitude: circle.latitude, longitude: circle.longitude)
            _mapCameraPosition = State(initialValue: .region(
                MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            ))
        } else {
            _mapCameraPosition = State(initialValue: .region(
                MKCoordinateRegion(center: Self.taiwanFallbackCenter, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
            ))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("地點名稱", text: $name)
                TextField("地址或地標", text: $address)
                    .onChange(of: address) { oldValue, newValue in
                        guard oldValue != newValue,
                              newValue != circle?.addressText,
                              newValue != pickedLabel else { return }
                        found = nil
                        picked = nil
                        pickedLabel = ""
                        searchFailed = false
                        locationNeedsConfirmation = true
                    }
                    // 停止輸入 0.7 秒就自動搜尋（每次改字 task 會重啟，形成 debounce）；
                    // 下方按鈕保留，給想立即搜尋或自動搜尋失敗後重試的人
                    .task(id: address) {
                        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty,
                              address != circle?.addressText,
                              address != pickedLabel,
                              found == nil, picked == nil else { return }
                        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                        await search()
                    }
                Button("使用 Apple Maps 搜尋") {
                    Task { await search() }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    if member.name == "住家" {
                        // 住家不會是遠端地點，不必多問一次
                        Task { await useCurrentLocation() }
                    } else {
                        showCurrentLocationConfirm = true
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("把目前位置設為這個守護地點", systemImage: "location.fill")
                        if locating { ProgressView() }
                        Spacer()
                    }
                }
                .confirmationDialog(
                    "你現在人在「\(member.name)」嗎？",
                    isPresented: $showCurrentLocationConfirm,
                    titleVisibility: .visible
                ) {
                    Button("對，就是這裡") { Task { await useCurrentLocation() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("這會把警戒圈設在你目前的位置。人不在現場的話，改用下面的地址搜尋或地圖選點。")
                }
                if !pickedLabel.isEmpty {
                    Text("已確認位置：\(pickedLabel)").foregroundStyle(HCColor.safe)
                } else if !locationHint.isEmpty {
                    Text(locationHint).font(.caption).foregroundStyle(HCColor.attention)
                }
                if let found, picked == nil {
                    Text("找到：\(found.name ?? address)").foregroundStyle(HCColor.safe)
                } else if searchFailed && picked == nil {
                    Text("找不到這個地點，請修改地址或改用目前位置；未確認前不會儲存這個地點。")
                        .font(.caption)
                        .foregroundStyle(HCColor.attention)
                }
                mapPickerSection
                Text("在地圖上長按或點一下任一點，可直接放大頭針選點；地址搜尋找不到、人又不在現場時最好用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("通知範圍：\(radius) 公尺", value: $radius, in: 300...3000, step: 100)
                Text("約走路 15 分鐘的範圍。地震、颱風等大範圍警報依行政區推播，不受這個範圍限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                districtSection
                Text("提醒類型：\(EventCategory.defaultSelection.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                scheduleSection
            }
            // 手指觸碰小地圖期間暫停 Form 捲動，放開立刻恢復——見 mapPickerSection 手勢方案說明
            .scrollDisabled(isTouchingMap)
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // #4：常駐醒目提示——只要位置還沒確認，這段說明就固定顯示（不是條件式時有時無），
            // 讓「儲存鈕按不下去」的原因一眼可見，不用等使用者先按過搜尋失敗才看到提示。
            .safeAreaInset(edge: .bottom) {
                if locationNeedsConfirmation {
                    unresolvedLocationBanner
                }
            }
            .analyticsScreen("circle_editor")
        }
        // 未儲存就離開（取消按鈕／下滑手勢關閉 sheet）兩條路徑都會讓這個 View 從畫面消失，
        // 用同一個 .onDisappear 收斂判斷，不必分別在取消按鈕與下滑手勢各接一次
        .onDisappear { deleteOrphanPlaceIfNeeded() }
        // #4：新增地點且是「住家」時，嘗試自動帶入目前位置——住家本來就是「不必多問一次」
        // 的信任情境（見上方「把目前位置設為這個守護地點」按鈕同樣的判斷），減少卡住機率。
        // 其餘地點名稱（爸媽家、公司⋯）刻意不自動帶入：使用者當下人多半不在那個地點，
        // 靜默帶入目前位置反而會建出錯誤的警戒圈，安全風險比「多一步確認」更高。
        // 沒有定位權限就安靜略過，不 crash、也不強制要求權限。
        .task {
            guard isNewPlaceCircle, member.name == "住家",
                  picked == nil, found == nil,
                  LocationService.shared.isAuthorized else { return }
            await useCurrentLocation()
        }
    }

    /// #4 常駐提示文案：清楚列出三種能解除「位置待確認」的動作，不只是抽象地說「請確認位置」。
    private var unresolvedLocationBanner: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x1) {
            Label("請先確認地點位置，儲存鈕才會亮起", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HCColor.attention)
            Text("搜尋地址、點「把目前位置設為這個守護地點」，或在地圖上點一下，三選一即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HCSpacing.x3)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HCColor.attention.opacity(0.3))
                .frame(height: 1)
        }
    }

    /// 新增地點兩段式流程的收尾：步驟 A（PlaceSelectView／FamilyHomeView／HomeStatusView
    /// 建立 `LocalFamilyMember(kind: "place")` 並存檔）已經讓這個 member 落地，
    /// 若使用者在這裡（步驟 B）沒儲存就離開，這個 member 會變成「0 個圈」的孤兒——
    /// 不只家人頁多一筆空地點，還會佔掉 `FreeTier.maxPlaces` 的免費額度，讓下次新增誤觸付費牆
    /// （`gateAddPlace` 數的是 `members.filter(\.isPlace).count`，孤兒 member 也算一個）。
    /// 條件同時成立才刪，任一不成立就直接放過：
    /// - `isNewPlaceCircle`：只有「選完地點名稱、接著開這裡建第一個圈」這個接續情境才可能孤兒；
    ///   編輯既有圈（circle != nil）或替一般家人（非地點）新增圈都不會是這個情境，天然被排除
    /// - `!didSave`：使用者真的有按儲存就不是孤兒，`save()` 裡會先設 `didSave = true` 才 dismiss
    /// - `member.lifeCircles.isEmpty`：這個 member 目前確實沒有任何圈——如果使用者是回來幫
    ///   已有圈的地點「加第二個圈」，中途取消也不該連累第一個圈，用這個條件排除
    private func deleteOrphanPlaceIfNeeded() {
        guard isNewPlaceCircle, !didSave, member.lifeCircles.isEmpty else { return }
        context.delete(member)
        context.saveReporting()
    }

    /// 導覽標題：新增地點接續情境講人話（帶出剛選的地點名稱），其餘情境沿用「守護地點」語彙
    private var navigationTitleText: String {
        if isNewPlaceCircle { return "把「\(member.name)」放上地圖" }
        return circle == nil ? "守護這個地點" : "編輯守護地點"
    }

    /// 所在行政區欄位：新增地點接續情境下改成「自動判定＋收進進階設定」，
    /// 其餘情境（編輯既有圈、替一般家人新增圈）外觀維持原本常駐 Picker。
    @ViewBuilder
    private var districtSection: some View {
        if isNewPlaceCircle {
            if districtAutoDetected, district != Districts.unspecified {
                Text("所在行政區：\(district)（自動判定）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("進階設定", isExpanded: $advancedExpanded) {
                Picker("所在行政區", selection: districtBinding) {
                    ForEach(Districts.all, id: \.self) { Text($0) }
                }
                Text("行政區用於颱風、豪雨等區域型警報的比對，已支援全國鄉鎮市區；沒把握就選「未指定」，仍可收到點狀事件與全國官方警報。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("所在行政區", selection: districtBinding) {
                ForEach(Districts.all, id: \.self) { Text($0) }
            }
            Text("行政區用於颱風、豪雨等區域型警報的比對，已支援全國鄉鎮市區；沒把握就選「未指定」，仍可收到點狀事件與全國官方警報。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 使用者手動在 Picker 挑行政區時，視為不再是自動判定的結果，讓上面的「自動判定」提示行消失
    private var districtBinding: Binding<String> {
        Binding(
            get: { district },
            set: { newValue in
                district = newValue
                districtAutoDetected = false
            }
        )
    }

    /// 自動判定行政區的共用邏輯：只從 Districts.all 這個集合裡挑值（guessDistrict 內部已用包含比對
    /// 對到集合項），對不到就維持「未指定」並展開進階設定讓使用者手動選——絕不寫入集合外的自創字串，
    /// 否則會讓區域型警報的行政區比對失效。已有值（含使用者手動選過）時不覆蓋。
    private func applyAutoDetectedDistrict(_ matched: String) {
        guard district == Districts.unspecified else { return }
        if matched != Districts.unspecified {
            district = matched
            districtAutoDetected = true
            advancedExpanded = false
        } else {
            districtAutoDetected = false
            advancedExpanded = true
        }
    }

    /// 一鍵帶入目前位置：反查地名與行政區，取代手動輸入地址
    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        guard LocationService.shared.isAuthorized else {
            LocationService.shared.requestPermissionIfNeeded()
            locationHint = "請先允許定位權限，再點一次"
            return
        }
        guard let location = await LocationService.shared.currentLocation() else {
            locationHint = "取不到目前位置，請稍後再試或改用地址搜尋"
            return
        }
        picked = location.coordinate
        locationNeedsConfirmation = false
        locationHint = ""
        if let place = await MapReverseGeocoder.lookup(location) {
            let matchedDistrict = Districts.guess(from: place.searchableText)
            pickedLabel = place.approximateLabel(district: matchedDistrict) ?? "座標已取得"
            applyAutoDetectedDistrict(matchedDistrict)
            if address.isEmpty { address = pickedLabel }
        } else {
            pickedLabel = "座標已取得"
        }
    }

    /// 第三條路的座標來源：跟 `save()` 同一套優先序（手動點選 > 搜尋結果 > 既有圈），
    /// 三種輸入管道（地址搜尋、目前位置、地圖點選）任一路更新，小地圖頭針與警戒圈預覽都跟著換。
    private var displayCoordinate: CLLocationCoordinate2D? {
        picked
            ?? found?.placemark.coordinate
            ?? circle.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// 嵌在表單裡的小地圖：長按或點擊放大頭針選點，同時即時預覽通知範圍圈。
    /// 手勢方案：
    /// - Map 本身放進固定高度容器（非整頁地圖），搭配一個「輕量偵測觸碰中/放開」的
    ///   `simultaneousGesture(DragGesture(minimumDistance: 0))` 只切換 `isTouchingMap` 旗標，
    ///   不消費、不攔截事件；外層 Form 用 `.scrollDisabled(isTouchingMap)` 在手指觸碰地圖期間
    ///   暫停捲動，放開後立刻恢復——這樣「拖地圖」不會被「表單捲動」搶走，Map 原生的平移／
    ///   縮放手勢也完全不受影響（不是攔截式的 `.gesture`，是併行觀察式的 `.simultaneousGesture`）。
    /// - 點擊放大頭針用 `SpatialTapGesture`（一般 `onTapGesture` 拿不到座標）；長按放大頭針用
    ///   `LongPressGesture` 串接 `minimumDistance: 0` 的 `DragGesture` 取放開當下座標
    ///   （`LongPressGesture` 本身也沒有位置）。兩者都掛 `simultaneousGesture`，不是 `.gesture`，
    ///   理由同上——這個專案在 SafetyMapView 已驗證過 tap 類手勢可以跟 Map 原生的 pan/pinch
    ///   並存，長按的第一階段又要求手指基本不動超過 0.4 秒，跟「一碰就滑動」的平移手勢時序
    ///   自然錯開，不會互搶。
    private var mapPickerSection: some View {
        MapReader { proxy in
            Map(position: $mapCameraPosition) {
                if let coordinate = displayCoordinate {
                    MapCircle(center: coordinate, radius: CLLocationDistance(radius))
                        .foregroundStyle(HCColor.brand.opacity(0.12))
                        .stroke(HCColor.brand.opacity(0.6), lineWidth: 1.5)
                    Annotation("守護地點", coordinate: coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(HCColor.brand)
                    }
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: HCRadius.control))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isTouchingMap = true }
                    .onEnded { _ in isTouchingMap = false }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                    pickOnMap(coordinate)
                }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        guard case .second(true, let drag) = value, let location = drag?.location,
                              let coordinate = proxy.convert(location, from: .local) else { return }
                        pickOnMap(coordinate)
                    }
            )
        }
        .listRowInsets(EdgeInsets())
        // 還沒有任何座標線索（新守護地點、尚未搜尋也沒用過目前位置）時，
        // 嘗試拿目前位置只為了把小地圖鏡頭拉近，不會連帶把座標設為目前位置——
        // 使用者仍要親自長按/點擊或按「把目前位置設為這個守護地點」才會真的選定座標
        .task {
            guard displayCoordinate == nil, LocationService.shared.isAuthorized,
                  let location = await LocationService.shared.currentLocation() else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                mapCameraPosition = .region(
                    MKCoordinateRegion(center: location.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
                )
            }
        }
    }

    /// 使用者在小地圖上長按／點擊選點：與「把目前位置設為這個守護地點」走同一條路，
    /// 差別只在座標來源改成手指指的位置；反查失敗就只設座標，地址欄不動。
    private func pickOnMap(_ coordinate: CLLocationCoordinate2D) {
        picked = coordinate
        locationNeedsConfirmation = false
        locationHint = ""
        searchFailed = false
        withAnimation(.easeInOut(duration: 0.3)) {
            mapCameraPosition = .region(
                MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            )
        }
        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let place = await MapReverseGeocoder.lookup(location) {
                let matchedDistrict = Districts.guess(from: place.searchableText)
                pickedLabel = place.approximateLabel(district: matchedDistrict) ?? "座標已取得"
                applyAutoDetectedDistrict(matchedDistrict)
                if address.isEmpty { address = pickedLabel }
            } else {
                pickedLabel = "座標已取得"
            }
        }
    }

    /// 時段感知設定：公司圈只在上班時間推播、住家圈只在夜間等。
    /// 時段外的官方事件仍會顯示在 App 內，只是不推播。
    private var scheduleSection: some View {
        Section {
            Toggle("只在特定時段提醒", isOn: $scheduleEnabled)
            if scheduleEnabled {
                HStack {
                    ForEach(1...7, id: \.self) { day in
                        let names = ["日", "一", "二", "三", "四", "五", "六"]
                        Button(names[day - 1]) {
                            if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(weekdays.contains(day) ? HCColor.brand : .gray)
                        .font(.caption)
                    }
                }
                Stepper("開始：\(startHour):00", value: $startHour, in: 0...23)
                Stepper("結束：\(endHour):00", value: $endHour, in: (startHour + 1)...24)
                Text("時段外的官方事件仍會顯示在 App 內，只是不推播。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func search() async {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            found = nil
            searchFailed = false
            locationNeedsConfirmation = true
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            found = try await MKLocalSearch(request: request).start().mapItems.first
            searchFailed = (found == nil)
            locationNeedsConfirmation = (found == nil)
            // 搜尋成功時嘗試從地址文字自動帶入行政區（已有值時 applyAutoDetectedDistrict 內部會自動略過）
            applyAutoDetectedDistrict(Districts.guess(from: "\(found?.name ?? "") \(address)"))
        } catch {
            AppLog.data.error("地點搜尋失敗：\(error.localizedDescription)")
            found = nil
            searchFailed = true
            locationNeedsConfirmation = true
        }
    }

    private var canSave: Bool {
        guard !locationNeedsConfirmation else { return false }
        return picked != nil || found != nil || circle != nil
    }

    private func save() {
        guard canSave else { return }
        let coordinate = picked
            ?? found?.placemark.coordinate
            ?? circle.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let coordinate else { return }
        let target = circle ?? LocalLifeCircle(
            name: "守護地點",
            encryptedAddress: "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radius,
            alertTypes: EventCategory.defaultSelection,
            member: member
        )
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "守護地點" : name
        target.setAddress(pickedLabel.isEmpty ? (found?.name ?? address) : pickedLabel)
        target.latitude = coordinate.latitude
        target.longitude = coordinate.longitude
        target.radiusMeters = radius
        target.scheduleEnabled = scheduleEnabled
        target.scheduleWeekdays = Array(weekdays).sorted()
        target.scheduleStartHour = startHour
        target.scheduleEndHour = endHour
        target.district = district
        target.kind = .fixed
        if circle == nil { context.insert(target) }
        context.saveReporting()
        // 一定要在 dismiss() 之前設 true：.onDisappear 觸發的孤兒清除判斷靠這個旗標
        // 分辨「有存過」跟「取消/下滑關閉」，順序反了會被自己剛存好的圈也一併判定成孤兒刪掉
        didSave = true
        dismiss()
    }
}
