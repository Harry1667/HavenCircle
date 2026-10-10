import XCTest

/// 家庭流程 UI 測試：每一步截圖（keepAlways），找不到元素就記錄並繼續。
/// 前置：裝置上已手動登入 Apple 帳號（測試不處理登入）。
final class HavenCircleUITests: XCTestCase {
    var app: XCUIApplication!
    private var step = 0
    private var missing: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // UX 稽核測試（Audit）自行決定啟動參數，不走既有的預先啟動
        if name.contains("testOnboardingTour") || name.contains("testEventsTour")
            || name.contains("testSettingsTour") || name.contains("testPaywallTour") {
            installPermissionMonitor()
            return
        }
        // 家人走查要驗「冷啟動落在家人首頁」，不指定分頁（預設即家人）；其餘維持地圖
        if name.contains("testFamilyTour") {
            app.launchArguments += ["--skip-location-prompt"]
        } else {
            app.launchArguments += ["--start-tab", "2", "--skip-location-prompt"]
        }
        // 系統彈窗（定位、通知）會卡住自動化
        addUIInterruptionMonitor(withDescription: "系統權限") { alert in
            for title in ["使用 App 時允許", "允許", "好", "Allow While Using App", "Allow", "OK"] {
                let b = alert.buttons[title]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        sleep(2)
        // 點頂端空白處觸發 interruption monitor；不可點正中央（會點到首頁避難所／動態列而換頁）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    override func tearDownWithError() throws {
        if !missing.isEmpty {
            attach(text: missing.joined(separator: "\n"), name: "missing-elements")
        }
        if !auditLines.isEmpty { attach(text: auditLines.joined(separator: "\n"), name: "inventory") }
    }

    // MARK: - helpers

    private func shot(_ name: String) {
        step += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", step, name)
        a.lifetime = .keepAlways
        add(a)
    }

    private func attach(text: String, name: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 找元素（可往下捲）；找不到記錄後回傳 nil
    private func find(_ label: String, in query: XCUIElementQuery? = nil, timeout: TimeInterval = 4) -> XCUIElement? {
        let q = query ?? app.descendants(matching: .any)
        var el = q.matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", label, label)).firstMatch
        if el.waitForExistence(timeout: timeout) { return el }
        for _ in 0..<3 {
            app.swipeUp()
            el = q.matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", label, label)).firstMatch
            if el.exists { return el }
        }
        missing.append("找不到：\(label)（步驟 \(step)）")
        return nil
    }

    @discardableResult
    private func tapIf(_ label: String, timeout: TimeInterval = 4) -> Bool {
        guard let el = find(label, timeout: timeout), el.isHittable else { return false }
        el.tap()
        sleep(1)
        return true
    }

    private func dismissSheet() {
        for t in ["完成", "取消", "關閉", "好"] {
            let b = app.buttons[t].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(1); return }
        }
        app.swipeDown()
        sleep(1)
    }

    /// 登入畫面或系統登入彈窗：截圖並回傳 true
    private func hitSignIn() -> Bool {
        let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS '使用 Apple 登入' OR label CONTAINS 'Sign in with Apple' OR label CONTAINS '繼續使用 Apple'")).firstMatch
        if signIn.waitForExistence(timeout: 2) {
            shot("遇到登入畫面-停止")
            missing.append("遇到登入畫面（裝置未登入），中止")
            return true
        }
        return false
    }


    // MARK: - tests

    func testFamilyTour() throws {
        shot("家庭首頁")
        if !app.navigationBars["家人"].exists { tapIf("家人") ; shot("家人分頁") }

        // 家人列表（未入圈：空狀態；已入圈：成員卡）
        shot("家人列表")

        // 邀請家人
        if app.buttons["family.inviteButton"].exists {
            app.buttons["family.inviteButton"].tap(); sleep(2)
            if hitSignIn() { return }
            shot("邀請家人-點擊後")
            dismissSheet()
        } else if tapIf("邀請更多家人") || tapIf("再次分享") {
            shot("邀請選項-InviteOptions")
            dismissSheet()
        } else { shot("邀請入口-找不到") }

        // 輸入邀請碼頁：未入圈時在首頁空狀態（「我收到了邀請碼」）；已入圈時收在「家庭圈管理」子頁
        if app.buttons["family.joinByCodeButton"].exists {
            app.buttons["family.joinByCodeButton"].tap(); sleep(1)
            if hitSignIn() { return }
            shot("輸入邀請碼頁")
            dismissSheet()
        }

        // 平安回報：底部固定鈕（多人時才有；單人沒有對象不顯示）
        if app.buttons["family.checkInButton"].waitForExistence(timeout: 2) {
            app.buttons["family.checkInButton"].tap(); sleep(1)
            shot("平安回報-SafetyCheckIn")
            dismissSheet()
        } else { shot("平安回報入口-單人或未入圈-不顯示") }

        // 家庭圈管理子頁：位置分享、警報跟著我、換圈、解散
        if tapIf("家庭圈管理") {
            shot("家庭圈管理")
            if find("把我的位置分享給家人", timeout: 3) != nil {
                shot("即時位置分享區塊")
            } else { shot("即時位置分享區塊-找不到（未入圈時不顯示）") }
            if app.buttons["family.joinByCodeButton"].exists {
                app.buttons["family.joinByCodeButton"].tap(); sleep(1)
                shot("換圈確認")
                for name in ["取消"] where app.buttons[name].exists { app.buttons[name].tap(); sleep(1); break }
            }
            app.navigationBars.buttons.firstMatch.tap(); sleep(1) // 返回家人首頁
        } else { shot("家庭圈管理入口-找不到") }

        // 成員詳情：家人首頁第一張人卡（我的卡）
        let firstCard = app.cells.containing(NSPredicate(format: "label CONTAINS '平安回報'")).firstMatch
        if firstCard.waitForExistence(timeout: 3) {
            firstCard.tap(); sleep(1)
            shot("成員詳情")
        } else { shot("成員詳情-無成員") }
    }

    func testCreateInvite() throws {
        shot("起點")
        // App 可能停在其他分頁，先切到「家人」
        let familyTab = app.tabBars.buttons["家人"].firstMatch
        if familyTab.waitForExistence(timeout: 4) { familyTab.tap() } else { app.buttons["家人"].firstMatch.tap() }
        sleep(2)
        shot("家人分頁")
        // 已有家庭：「等待家人加入」卡直接顯示邀請碼
        var code = readCode()
        if code == nil {
            if app.buttons["family.inviteButton"].waitForExistence(timeout: 4) {
                app.buttons["family.inviteButton"].tap()
            } else if !tapIf("邀請更多家人") { tapIf("再次分享") }
            sleep(3)
            if hitSignIn() { return }
            shot("建立家庭中")
            // 身分選擇可能出現：略過
            if app.buttons["稍後再說"].waitForExistence(timeout: 6) { shot("身分選擇"); app.buttons["稍後再說"].tap(); sleep(2) }
            shot("邀請選項")
            code = readCode()
        }
        shot("邀請碼畫面")
        if let code { attach(text: code, name: "invite-code") }
        else { missing.append("取不到邀請碼") ; XCTFail("取不到邀請碼") }
    }

    private func readCode() -> String? {
        let el = app.staticTexts["invite.code"].firstMatch
        guard el.waitForExistence(timeout: 4) else { return nil }
        let v = el.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    func testJoinWithCode() throws {
        guard let code = ProcessInfo.processInfo.environment["INVITE_CODE"], !code.isEmpty else {
            XCTFail("未提供 INVITE_CODE（用 TEST_RUNNER_INVITE_CODE=xxxx 傳入）"); return
        }
        shot("起點")
        let familyTab = app.tabBars.buttons["家人"].firstMatch
        if familyTab.waitForExistence(timeout: 4) { familyTab.tap() } else { app.buttons["家人"].firstMatch.tap() }
        sleep(2)
        // 未入圈：首頁空狀態直接有「我收到了邀請碼」；已入圈：先進「家庭圈管理」子頁再點輸碼換圈
        if !app.buttons["family.joinByCodeButton"].waitForExistence(timeout: 4) {
            _ = tapIf("家庭圈管理")
        }
        if app.buttons["family.joinByCodeButton"].waitForExistence(timeout: 4) {
            app.buttons["family.joinByCodeButton"].tap()
        } else {
            shot("找不到輸碼入口"); XCTFail("找不到輸碼入口"); return
        }
        sleep(2)
        // 已在家庭時會先跳「要加入另一個家庭圈嗎？」確認
        let goOn = app.buttons["繼續輸入邀請碼"].firstMatch
        if goOn.waitForExistence(timeout: 3) { shot("換圈確認"); goOn.tap(); sleep(2) }
        if hitSignIn() { return }
        shot("輸入邀請碼頁")
        let field = app.textFields["join.codeField"]
        guard field.waitForExistence(timeout: 4) else { shot("找不到輸入框"); XCTFail("找不到輸入框"); return }
        field.tap(); field.typeText(code)
        shot("已輸入邀請碼")
        // 用鍵盤 Return 送出（鍵盤可能蓋住「下一步」）
        field.typeText("\n")
        sleep(3)
        shot("加入前確認頁")
        let confirm = app.buttons["join.confirmButton"]
        guard confirm.waitForExistence(timeout: 8) else {
            shot("沒有確認頁-可能查碼失敗"); XCTFail("沒進入確認頁"); return
        }
        confirm.tap()
        sleep(4)
        shot("加入成功-歡迎頁")
        for name in ["繼續", "好", "開始"] where app.buttons[name].exists { app.buttons[name].tap(); sleep(2); break }
        shot("身分選擇")
        if app.buttons["稍後再說"].waitForExistence(timeout: 3) { app.buttons["稍後再說"].tap(); sleep(2) }
        shot("加入後-啟動問題")
        for name in ["稍後再說", "略過", "跳過", "完成", "開始使用"] where app.buttons[name].exists { app.buttons[name].tap(); sleep(2); break }
        sleep(2)
        shot("加入後-家人頁")
    }

    // MARK: - UX 稽核（Audit）：完整走查 + 截圖 + 可點元素盤點

    private var auditClicks = 0
    private var auditStep = 0
    private var auditLines: [String] = []

    private func installPermissionMonitor() {
        addUIInterruptionMonitor(withDescription: "系統權限") { alert in
            for title in ["使用 App 時允許", "允許一次", "允許", "Allow While Using App", "Allow Once", "Allow", "OK", "好"] {
                let b = alert.buttons[title]
                if b.exists { b.tap(); return true }
            }
            return false
        }
    }

    private func auditLaunch(_ args: [String]) {
        // 模擬器全新安裝時用 --demo-firstrun 跳過新手引導（環境變數 AUDIT_DEMO=1）；實機不要設
        var args = args
        if ProcessInfo.processInfo.environment["AUDIT_DEMO"] == "1" { args.append("--demo-firstrun") }
        app.launchArguments = args
        app.launch()
        sleep(2)
        app.tap() // 觸發 interruption monitor
    }

    /// 以 snapshot 一次抓出畫面上所有可互動元素
    private func clickableInventory() -> [String] {
        guard let snap = try? app.snapshot() else { return ["(snapshot 失敗)"] }
        let screen = snap.frame
        var out: [String] = []
        var seen = Set<String>()
        func walk(_ n: XCUIElementSnapshot) {
            let typeName: String?
            switch n.elementType {
            case .button: typeName = "按鈕"
            case .link: typeName = "連結"
            case .switch: typeName = "開關"
            case .textField: typeName = "輸入框"
            case .secureTextField: typeName = "密碼框"
            case .cell: typeName = "列"
            case .segmentedControl: typeName = "分段"
            case .tab: typeName = "分頁"
            case .slider: typeName = "滑桿"
            case .stepper: typeName = "步進器"
            default: typeName = nil
            }
            if let t = typeName, n.frame.intersects(screen), n.frame.width > 0 {
                let l = n.label.replacingOccurrences(of: "\n", with: " ")
                let text = l.isEmpty ? n.identifier : l
                let key = "\(t):\(text)"
                if !text.isEmpty, !seen.contains(key) {
                    seen.insert(key)
                    out.append(n.isEnabled ? key : key + "(停用)")
                }
            }
            for c in n.children { walk(c) }
        }
        walk(snap)
        return out
    }

    /// 截圖 + 盤點。name 不可含底線（匯出時以底線切檔名）
    private func auditShot(_ flow: String, _ name: String, note: String = "") {
        auditStep += 1
        let nn = String(format: "%02d", auditStep)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "\(nn)-\(name)"
        a.lifetime = .keepAlways
        add(a)
        let items = clickableInventory()
        auditLines.append("\(flow)|\(nn)|\(name)|\(auditClicks)|\(note)|\(items.joined(separator: " ¦ "))")
    }

    private func flushAudit(_ flow: String) {
        // inventory 由 tearDown 統一附加（失敗時也保留）
    }

    @discardableResult
    private func auditTap(_ el: XCUIElement, wait: UInt32 = 1) -> Bool {
        guard el.exists else { return false }
        if el.isHittable { el.tap() } else { el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        auditClicks += 1
        sleep(wait)
        return true
    }

    private func firstMatch(_ label: String, types: [XCUIElement.ElementType] = [.button, .cell, .link, .staticText, .other]) -> XCUIElement? {
        let pred = NSPredicate(format: "label CONTAINS %@ OR identifier == %@", label, label)
        for t in types {
            let el = app.descendants(matching: t).matching(pred).firstMatch
            if el.exists { return el }
        }
        return nil
    }

    private func auditBack() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { auditTap(b) }
    }

    private func auditDismiss() {
        for t in ["關閉", "完成", "取消", "Close", "Done"] {
            let b = app.buttons[t].firstMatch
            if b.exists && b.isHittable { auditTap(b); return }
        }
        // 沒有關閉鈕的 sheet（例如區域警報詳情）：從頂部標題列往下拖
        auditLines.append("--|--|此 sheet 沒有關閉/完成按鈕，只能下拉關閉|\(auditClicks)|UX 發現||")
        for _ in 0..<2 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            from.press(forDuration: 0.1, thenDragTo: to)
            sleep(1)
        }
        // iPad 的表單式 sheet：點外側暗區關閉
        if app.sheets.count > 0 || app.otherElements["PopoverDismissRegion"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02)).tap(); sleep(1)
        }
    }

    /// SpringBoard 上的系統權限彈窗：截圖、記錄按鈕、點允許。回傳是否處理了彈窗
    private func handleSystemAlert(_ flow: String, tapLog: inout [String]) -> Bool {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = sb.alerts.firstMatch
        guard alert.exists else { return false }
        let labels = alert.buttons.allElementsBoundByIndex.map { $0.label }
        let title = alert.label
        auditStep += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-系統彈窗", auditStep); a.lifetime = .keepAlways; add(a)
        auditLines.append("\(flow)|\(String(format: "%02d", auditStep))|系統彈窗|\(auditClicks)|\(title)|" + labels.map { "按鈕:" + $0 }.joined(separator: " ¦ "))
        let allow = alert.buttons.matching(NSPredicate(format: "(label CONTAINS '期間允許' OR label CONTAINS '時允許' OR label CONTAINS 'While Using') OR (label CONTAINS '允許' AND NOT label CONTAINS '不允許' AND NOT label CONTAINS '一次') OR label == 'Allow'")).firstMatch
        if allow.exists { let l = allow.label; allow.tap(); auditClicks += 1; tapLog.append("系統彈窗:" + l); sleep(2); return true }
        if let first = alert.buttons.allElementsBoundByIndex.last { first.tap(); auditClicks += 1; tapLog.append("系統彈窗:其他"); sleep(2) }
        return true
    }

    // MARK: 1. 新手引導

    func testOnboardingTour() throws {
        let flow = "onboarding"
        auditLaunch(["--start-tab", "0"].filter { _ in false }) // 不帶任何旗標：模擬全新使用者
        auditShot(flow, "首次開啟")
        // 偏好的「往前走」按鈕（越前面越優先）
        let buttonPrefs = ["下一步", "完成", "開始使用", "開始", "繼續", "先看看，稍後再開", "先看看警報長什麼樣", "先不用", "稍後再說", "略過", "跳過"]
        var lastSig = ""
        var stuckCount = 0
        var idle = 0
        var tapLog: [String] = []
        for _ in 0..<30 {
            var acted = false
            // 0) 系統彈窗（定位/通知）：截圖後點「允許」類
            if handleSystemAlert(flow, tapLog: &tapLog) { acted = true; continue }
            // 1) 地圖著陸：點一下地圖索要定位
            if firstMatch("點一下地圖", types: [.staticText, .other]) != nil, tapLog.last != "地圖中央" || stuckCount < 2 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                auditClicks += 1; sleep(3)
                app.tap() // 讓 interruption monitor 處理定位彈窗
                tapLog.append("地圖中央"); acted = true
            } else if let pref = buttonPrefs.first(where: { l in clickableInventory().contains { $0.hasPrefix("按鈕:" + l) } }) {
                let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pref)).firstMatch
                auditTap(b, wait: 2); tapLog.append(pref); acted = true
            } else if let t = firstMatch("輕點繼續", types: [.staticText]) {
                auditTap(t, wait: 2); tapLog.append("輕點繼續"); acted = true
            }
            if acted {
                idle = 0
                let sig = clickableInventory().joined() + (tapLog.last ?? "")
                if sig == lastSig { stuckCount += 1 } else { stuckCount = 0 }
                lastSig = sig
                auditShot(flow, "點擊後-\(tapLog.count)", note: "點了「\(tapLog.last ?? "")」")
                if stuckCount >= 3 { auditLines.append("\(flow)|--|STUCK|\(auditClicks)|畫面不變卡住||"); break }
            } else {
                idle += 1
                if idle >= 5 { break }
                sleep(3)
            }
        }
        auditShot(flow, "終點-主畫面", note: "點擊序列：" + tapLog.joined(separator: " > "))
        attach(text: "總點擊數 \(auditClicks)；序列：" + tapLog.joined(separator: " > "), name: "onboarding-summary")
        flushAudit(flow)
    }

    // MARK: 2. 事件

    func testEventsTour() throws {
        let flow = "events"
        // 先看家人首頁（狀態卡），再切到「動態」分頁
        auditLaunch(["--start-tab", "0", "--skip-location-prompt"])
        clearOverlays()
        sleep(8) // 等事件管線抓到資料
        auditShot(flow, "家人首頁")
        let eventsTab = app.tabBars.buttons["動態"].exists ? app.tabBars.buttons["動態"] : app.buttons.matching(NSPredicate(format: "label == '動態'")).firstMatch
        // 動態分頁（原提醒中心，事件列表）
        if auditTap(eventsTab, wait: 2) {
            auditShot(flow, "動態-事件列表")
            // 先點第一則區域警報（官方示警），再切到「全台動態」點第一則事件
            let alertRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '警報：'")).firstMatch
            if alertRow.exists {
                auditTap(alertRow, wait: 2)
                auditShot(flow, "區域警報詳情")
                app.swipeUp(); sleep(1)
                auditShot(flow, "區域警報詳情-下捲")
                auditDismiss(); sleep(1)
            } else { auditLines.append("\(flow)|--|列表無區域警報列|\(auditClicks)|||") }
            if auditTap(app.buttons["全台動態"], wait: 2) {
                auditShot(flow, "動態-全台動態")
                let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '進行中、'")).firstMatch
                if row.waitForExistence(timeout: 10) {
                    auditTap(row, wait: 2)
                    auditShot(flow, "事件詳情-列表進入")
                    app.swipeUp(); sleep(1)
                    auditShot(flow, "事件詳情-下捲")
                    auditDismiss(); sleep(1)
                } else { auditLines.append("\(flow)|--|全台動態無事件列|\(auditClicks)|||") }
            }
        } else { auditLines.append("\(flow)|--|找不到動態分頁|\(auditClicks)|||") }

        // 區域回顧（動態分頁底部）
        if let h = firstMatch("回顧過去") {
            if !h.isHittable { app.swipeUp() }
            auditTap(h, wait: 2)
            auditShot(flow, "區域回顧")
            auditBack(); sleep(1)
        }

        // 安全地圖
        let mapTab = app.tabBars.buttons["地圖"].exists ? app.tabBars.buttons["地圖"] : app.buttons.matching(NSPredicate(format: "label == '地圖'")).firstMatch
        if auditTap(mapTab, wait: 3) {
            clearOverlays()
            auditShot(flow, "安全地圖")
            let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '.*，.*，.*' AND NOT label CONTAINS 'AQI' AND NOT label CONTAINS '點擊' AND NOT label CONTAINS '回報於' AND NOT label CONTAINS '圖例'")).firstMatch
            if marker.waitForExistence(timeout: 4) {
                auditTap(marker, wait: 2)
                auditShot(flow, "點事件標記後", note: "標記：" + marker.label)
                if app.buttons["關閉"].exists || app.navigationBars.count > 0 {
                    app.swipeUp(); sleep(1)
                    auditShot(flow, "地圖事件詳情-下捲")
                }
                auditDismiss(); sleep(1)
            } else { auditLines.append("\(flow)|--|地圖上找不到事件標記|\(auditClicks)|可能無事件或標記無 a11y 標籤||") }

            // 圖例 / 篩選
            if let legend = firstMatch("地圖圖例") {
                auditTap(legend, wait: 1)
                auditShot(flow, "圖例展開")
            } else { auditLines.append("\(flow)|--|找不到圖例入口|\(auditClicks)|建議加 accessibilityIdentifier map.legend||") }
            if let chrome = firstMatch("資訊面板") {
                auditTap(chrome, wait: 1)
                auditShot(flow, "資訊面板切換後")
                if let again = firstMatch("資訊面板") { auditTap(again, wait: 1) } // 還原
            }
        }
        flushAudit(flow)
    }

    /// 清掉可能擋住的覆蓋層（導覽卡、角色選擇、教學）。只點「略過/稍後」類，不點會改狀態的選項。
    private func clearOverlays() {
        for _ in 0..<10 {
            var hit = false
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if sb.exists {
                let allow = sb.buttons.matching(NSPredicate(format: "label CONTAINS '期間允許' OR label == '允許' OR label == 'Allow'")).firstMatch
                if allow.exists { allow.tap() } else if let b = sb.buttons.allElementsBoundByIndex.last { b.tap() }
                sleep(1); continue
            }
            let cont = app.staticTexts["輕點繼續"]
            if cont.exists { cont.tap(); sleep(1); continue }
            for l in ["略過", "稍後再說", "先不用", "跳過"] {
                let b = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", l)).firstMatch
                if b.exists && b.isHittable { b.tap(); sleep(1); hit = true; break }
            }
            if !hit { break }
        }
    }

    // MARK: 3. 設定

    func testSettingsTour() throws {
        let flow = "settings"
        auditLaunch(["--start-tab", "0", "--skip-location-prompt"])
        clearOverlays()
        auditShot(flow, "安心首頁-設定入口前")
        guard let gear = firstMatch("設定", types: [.button]) else {
            auditLines.append("\(flow)|--|找不到設定齒輪|\(auditClicks)|||"); flushAudit(flow); XCTFail("找不到設定"); return
        }
        auditTap(gear, wait: 2)
        auditShot(flow, "設定-主頁")
        // 只進白名單內的導覽列（避免碰到刪除/重設/示範資料/開關）
        let safeRows = ["登入 Apple 帳號", "Apple 帳號", "升級 Guardian+", "防災問答", "你的名字與家庭身分", "提醒設定", "顯示與文字", "法律與隱私", "資料來源", "關於安心圈"]
        var done = Set<String>()
        for round in 0..<14 {
            var progressed = false
            for row in safeRows where !done.contains(row) {
                let el = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
                guard el.exists, el.isHittable else { continue }
                done.insert(row); progressed = true
                auditTap(el, wait: 2)
                let short = row.replacingOccurrences(of: " ", with: "")
                auditShot(flow, "子頁-\(short)", note: "列：" + row)
                let isCover = app.buttons["關閉"].exists && app.navigationBars.buttons.count <= 1 && row.hasPrefix("升級")
                app.swipeUp(); sleep(1)
                auditShot(flow, "子頁-\(short)-下捲")
                if isCover { auditDismiss() } else { auditBack() }
                sleep(1)
                break
            }
            if !progressed {
                if round > 8 { break }
                app.swipeUp(); sleep(1)
                if round == 0 { auditShot(flow, "設定-下捲") }
            }
        }
        auditLines.append("\(flow)|--|未進入的列（刻意略過）|\(auditClicks)|刪除帳號、模擬警報、載入示範資料、重設 Demo、重跑新手流程、匿名統計開關、重播地圖導覽||")
        auditShot(flow, "設定-回到列表")
        flushAudit(flow)
    }

    // MARK: 4. 付費牆

    func testPaywallTour() throws {
        let flow = "paywall"
        auditLaunch(["--start-tab", "0", "--skip-location-prompt", "--show-paywall"])
        sleep(2)
        auditShot(flow, "付費牆")
        app.swipeUp(); sleep(1)
        auditShot(flow, "付費牆-下捲")
        flushAudit(flow)
    }
}
