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
        // 現況快照：不重啟 App，原樣拍下使用者眼前的畫面
        if name.contains("testSnapshotNow") { return }
        // 外觀走查：每種外觀各自重啟並帶 --appearance 參數，由測試本體啟動
        if name.contains("testAppearanceTour") { return }
        if name.contains("testOnboardingTour") || name.contains("testEventsTour")
            || name.contains("testSettingsTour") || name.contains("testPaywallTour") {
            installPermissionMonitor()
            return
        }
        // 家人走查驗「冷啟動預設落在動態」，不指定分頁，之後自行切到家人；其餘維持地圖（tag 1）
        // 通知說明視窗測試：不帶 --skip-notification-prompt，才會走到 App 內說明
        if name.contains("testNotificationPrimer") {
            app.launchArguments += ["--start-tab", "2", "--skip-location-prompt"]
        } else if name.contains("testFamilyTour") {
            app.launchArguments += ["--skip-location-prompt", "--skip-notification-prompt"]
        } else {
            app.launchArguments += ["--start-tab", "1", "--skip-location-prompt", "--skip-notification-prompt"]
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
        // 環境變數 AUDIT_DEMO=1：加 --demo-firstrun 清掉引導卡旗標並載入示範種子（彩排／截圖用）；實機不要設
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

    /// 零導覽冷啟動：第一幀就是動態分頁（無著陸頁、無模態、無「輕點繼續」），
    /// 定位／通知是動態頂端的情境卡，0 點擊也能使用；點卡片才會出現系統權限框。
    func testOnboardingTour() throws {
        let flow = "onboarding"
        auditLaunch([]) // 不帶任何旗標：模擬全新使用者
        auditShot(flow, "冷啟動首屏")
        var tapLog: [String] = []
        // 驗收 1：第一幀是動態分頁，沒有舊的強制帶領
        XCTAssertTrue(app.navigationBars["動態"].waitForExistence(timeout: 8), "冷啟動第一幀應為動態分頁")
        XCTAssertFalse(app.staticTexts["輕點繼續"].exists, "不應再有「輕點繼續」帶領")
        XCTAssertFalse(app.staticTexts["點一下地圖"].exists, "不應再有地圖著陸頁")
        // 定位邀請卡 → 點「允許定位」→ 系統框
        let allowLocation = app.buttons["允許定位"]
        if allowLocation.waitForExistence(timeout: 5) {
            auditShot(flow, "定位邀請卡")
            auditTap(allowLocation, wait: 2); tapLog.append("允許定位")
            _ = handleSystemAlert(flow, tapLog: &tapLog)
            auditShot(flow, "允許定位後")
        } else {
            missing.append("找不到「允許定位」卡（可能已授權／已決定）")
        }
        // 通知邀請卡（首次渲染 3 秒後出現）
        let allowNotify = app.buttons["開啟通知"]
        if allowNotify.waitForExistence(timeout: 8) {
            auditShot(flow, "通知邀請卡")
            auditTap(allowNotify, wait: 2); tapLog.append("開啟通知")
            _ = handleSystemAlert(flow, tapLog: &tapLog)
        }
        auditShot(flow, "終點-動態", note: "點擊序列：" + tapLog.joined(separator: " > "))
        attach(text: "總點擊數 \(auditClicks)；序列：" + tapLog.joined(separator: " > "), name: "onboarding-summary")
        flushAudit(flow)
    }

    // MARK: 2. 事件

    func testEventsTour() throws {
        let flow = "events"
        // 先看家人首頁（狀態卡），再切到「動態」分頁
        auditLaunch(["--start-tab", "2", "--skip-location-prompt", "--skip-notification-prompt"])
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
        auditLaunch(["--start-tab", "2", "--skip-location-prompt", "--skip-notification-prompt"])
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
        auditLaunch(["--start-tab", "2", "--skip-location-prompt", "--skip-notification-prompt", "--show-paywall"])
        sleep(2)
        auditShot(flow, "付費牆")
        app.swipeUp(); sleep(1)
        auditShot(flow, "付費牆-下捲")
        flushAudit(flow)
    }

    /// 家人位置觀察：在觀看端（iPad）截家人列表、對方詳情（今天的軌跡）、地圖，記錄對方位置是否持續更新
    func testWatchMember() throws {
        let familyTab = app.tabBars.buttons["家人"].firstMatch
        if familyTab.waitForExistence(timeout: 4) { familyTab.tap() } else { app.buttons["家人"].firstMatch.tap() }
        sleep(25) // 等前景輪詢（每 20 秒）抓到最新位置
        shot("家人列表")
        attach(text: app.debugDescription, name: "家人列表文字")
        // 點另一位家人：優先找「圈主」「家人」等非本人的列（本人列的標籤以「我」開頭，可能前面有表情）
        let rowPred = NSPredicate(format: "label CONTAINS '位置' AND NOT (label CONTAINS '我,' OR label CONTAINS '我，' OR label BEGINSWITH '我' OR label CONTAINS '😐 我' OR label CONTAINS '🙂 我')")
        let byName = app.buttons.matching(NSPredicate(format: "label CONTAINS '圈主'")).firstMatch
        let candidates = app.buttons.matching(rowPred).allElementsBoundByIndex + app.cells.matching(rowPred).allElementsBoundByIndex
        if let other = byName.exists ? byName : candidates.first {
            attach(text: other.label, name: "點選的家人列")
            other.tap(); sleep(4)
            shot("家人詳情")
            app.swipeUp(); sleep(1)
            shot("家人詳情-軌跡")
            attach(text: app.debugDescription, name: "家人詳情文字")
        } else {
            missing.append("找不到其他家人的列")
        }
        let mapTab = app.tabBars.buttons["地圖"].firstMatch
        if mapTab.waitForExistence(timeout: 3) { mapTab.tap() } else { app.buttons["地圖"].firstMatch.tap() }
        sleep(5)
        shot("地圖")
    }

    /// 新增使用者指定的兩個守護地點（走真實 UI：家人 → 新增守護地點 → 名稱＋地址 → 等 Apple Maps 搜尋 → 儲存）
    func testAddPlaces() throws {
        let places = [("福上巷", "台中市西屯區福上巷214弄100號"), ("育英街", "台北市文山區育英街85號")]
        let familyTab = app.tabBars.buttons["家人"].firstMatch
        if familyTab.waitForExistence(timeout: 4) { familyTab.tap() } else { app.buttons["家人"].firstMatch.tap() }
        sleep(2)
        for (idx, (name, addr)) in places.enumerated() {
            if app.staticTexts[name].exists { shot("已存在-\(name)"); continue }
            guard let add = find("新增守護地點", timeout: 6) else { shot("找不到新增入口"); XCTFail("找不到新增守護地點"); return }
            add.tap(); sleep(2)
            shot("編輯頁-\(idx + 1)")
            let nameField = app.textFields["地點名稱"].firstMatch
            guard nameField.waitForExistence(timeout: 5) else { shot("找不到名稱欄"); XCTFail("找不到名稱欄"); return }
            if (nameField.value as? String) != name { nameField.tap(); nameField.typeText(name) }
            let addrField = app.textFields["地址或地標"].firstMatch
            addrField.tap(); addrField.typeText(addr)
            sleep(4) // 0.7 秒 debounce 後自動用 Apple Maps 搜尋
            shot("已輸入-\(name)")
            attach(text: app.debugDescription, name: "編輯頁文字-\(name)")
            let save = app.buttons["儲存"].firstMatch
            if !save.isEnabled {
                tapIf("使用 Apple Maps 搜尋"); sleep(4)
            }
            shot("搜尋後-\(name)")
            guard save.isEnabled else { missing.append("儲存鈕不可用：\(name)（地址搜尋可能失敗）"); app.buttons["取消"].firstMatch.tap(); sleep(1); continue }
            save.tap(); sleep(3)
            shot("儲存後-\(name)")
        }
        shot("家人頁-守護地點")
    }

    /// 診斷「整個 App 點不動」：冷啟動後傾印畫面結構、逐一試點分頁與捲動，記錄每步是否有反應
    func testDiagnoseFreeze() throws {
        sleep(8)
        shot("啟動後8秒")
        attach(text: app.debugDescription, name: "結構-啟動後")
        for tab in ["地圖", "家人", "動態"] {
            let b = app.tabBars.buttons[tab].firstMatch
            let ok = b.waitForExistence(timeout: 3)
            let hit = ok && b.isHittable
            attach(text: "分頁 \(tab)：存在=\(ok) 可點=\(hit) selected=\(ok ? b.isSelected : false)", name: "分頁-\(tab)")
            if ok { b.tap() }
            sleep(3)
            attach(text: "點完 \(tab) 後 selected=\(ok ? b.isSelected : false)", name: "點後-\(tab)")
            shot("點\(tab)後")
        }
        app.swipeUp(); sleep(2); shot("上滑後")
        attach(text: app.debugDescription, name: "結構-最後")
    }

    /// 不重啟、不點任何東西：拍下目前螢幕、App 與系統層（SpringBoard）的元素結構，找出攔住觸控的東西
    func testSnapshotNow() throws {
        let shotNow = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shotNow.name = "現況"; shotNow.lifetime = .keepAlways; add(shotNow)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attach(text: springboard.debugDescription, name: "系統層")
        attach(text: "App 狀態=\(app.state.rawValue)\n" + app.debugDescription, name: "App結構")
        // 安裝測試會把 App 關掉：用 activate 正常開起來（不帶任何測試參數、不自動按掉系統彈窗），等 12 秒再拍
        app.activate(); sleep(12)
        let later = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        later.name = "開啟12秒後"; later.lifetime = .keepAlways; add(later)
        attach(text: springboard.debugDescription, name: "系統層-12秒後")
        attach(text: "App 狀態=\(app.state.rawValue)\n" + app.debugDescription, name: "App結構-12秒後")
    }

    /// 動態頁頂端「我平安」一鍵卡：切到動態、拉到最頂，確認卡片存在並截圖
    func testQuickSafeCard() throws {
        app.tabBars.buttons["動態"].firstMatch.tap()
        sleep(3)
        app.swipeDown(); app.swipeDown(); sleep(2)
        shot("動態頂端")
        let send = app.buttons["quickSafe.sendButton"].exists
        let invite = app.staticTexts["加入家人，才能一鍵報平安"].exists
        attach(text: "送出鈕=\(send) 邀請卡=\(invite)\n" + app.debugDescription, name: "我平安卡")
    }

    /// 我平安一鍵卡實際送出：我平安 → 改報需要協助 → 改回我平安（家人最後看到的是平安）
    func testQuickSafeSend() throws {
        app.tabBars.buttons["動態"].firstMatch.tap()
        sleep(2); app.swipeDown(); sleep(1)
        let send = app.buttons["quickSafe.sendButton"].firstMatch
        guard send.waitForExistence(timeout: 5) else { shot("找不到我平安鈕"); XCTFail("找不到我平安鈕"); return }
        send.tap()
        let sent = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '已告訴家人你'")).firstMatch
        let ok = sent.waitForExistence(timeout: 15)
        shot("送出我平安後")
        attach(text: "已送出狀態=\(ok) 文字=\(ok ? sent.label : "")", name: "送出結果-平安")
        // 首次報平安後可能跳出通知說明（已授權則不會）
        sleep(3)
        if app.buttons["開啟通知"].exists { shot("通知說明"); _ = tapIf("稍後"); sleep(1) }
        guard app.buttons["改報需要協助"].waitForExistence(timeout: 5) else { XCTFail("找不到改報需要協助"); return }
        app.buttons["改報需要協助"].tap(); sleep(1)
        shot("需要協助確認框")
        app.buttons["告訴家人我需要協助"].firstMatch.tap()
        let help = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '需要協助・'")).firstMatch
        let okHelp = help.waitForExistence(timeout: 15)
        shot("改報需要協助後")
        attach(text: "需要協助狀態=\(okHelp) 文字=\(okHelp ? help.label : "")", name: "送出結果-需要協助")
        guard app.buttons["改報我平安"].waitForExistence(timeout: 5) else { XCTFail("找不到改報我平安"); return }
        app.buttons["改報我平安"].tap()
        let back = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '平安・'")).firstMatch
        let okBack = back.waitForExistence(timeout: 15)
        shot("改回我平安後")
        attach(text: "改回平安=\(okBack)", name: "送出結果-改回平安")
        XCTAssertTrue(ok && okHelp && okBack)
    }

    /// 家人回報「收到 ❤️」：家人頁 → 回報平安 → 對最上面一則他人的回報按「收到 ❤️」（若存在），
    /// 再看動態頁我平安卡的已送出狀態（有人收到時會顯示「XX已收到」）。只截圖與記錄，不強制斷言有他人回報。
    func testPingAck() throws {
        app.tabBars.buttons["家人"].firstMatch.tap(); sleep(3)
        let checkIn = app.buttons["回報平安"].firstMatch
        if checkIn.waitForExistence(timeout: 5) {
            checkIn.tap(); sleep(3)
            shot("回報中心")
            let ackButton = app.buttons["pingRow.ackButton"].firstMatch
            if ackButton.waitForExistence(timeout: 3) {
                ackButton.tap(); sleep(3)
                shot("按下收到後")
                let acked = app.staticTexts["已回覆收到"].firstMatch.exists
                attach(text: "已回覆收到=\(acked)", name: "收到結果")
            } else {
                // 沒有他人的回報（或都已回覆）：記錄現況，不算失敗
                attach(text: "無可回覆的他人回報｜已回覆數=\(app.staticTexts.matching(identifier: "已回覆收到").count)", name: "收到結果")
                shot("無可回覆的回報")
            }
            app.swipeDown(velocity: .fast); sleep(1)
        } else {
            attach(text: "找不到回報平安鈕（單人或未登入）", name: "收到結果")
        }
        app.tabBars.buttons["動態"].firstMatch.tap(); sleep(2)
        app.swipeDown(); sleep(1)
        let sent = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '已告訴家人你'")).firstMatch
        let hasSent = sent.waitForExistence(timeout: 3)
        let ackSummary = app.staticTexts["quickSafe.ackSummary"].exists
        shot("動態-我平安卡已送出狀態")
        attach(text: "已送出狀態=\(hasSent) 有人收到=\(ackSummary)", name: "我平安卡-收到")
    }

    /// 通知說明視窗：全新安裝（模擬器）新增第一個守護地點後，應先出現 App 內說明，按「開啟通知」才跳系統詢問
    func testNotificationPrimer() throws {
        sleep(2)
        shot("啟動")
        let familyTab = app.tabBars.buttons["家人"].firstMatch
        if familyTab.waitForExistence(timeout: 4) { familyTab.tap() }
        sleep(2)
        guard let add = find("新增守護地點", timeout: 6) else { shot("找不到新增入口"); attach(text: app.debugDescription, name: "家人頁結構"); XCTFail("找不到新增守護地點"); return }
        add.tap(); sleep(2)
        let nameField = app.textFields["地點名稱"].firstMatch
        guard nameField.waitForExistence(timeout: 5) else { shot("找不到名稱欄"); XCTFail("找不到名稱欄"); return }
        nameField.tap(); nameField.typeText("測試地點")
        let addrField = app.textFields["地址或地標"].firstMatch
        addrField.tap(); addrField.typeText("台北101")
        sleep(5)
        let save = app.buttons["儲存"].firstMatch
        if !save.isEnabled { _ = tapIf("使用 Apple Maps 搜尋"); sleep(4) }
        shot("儲存前")
        guard save.isEnabled else { XCTFail("儲存鈕不可用"); return }
        save.tap()
        let primer = app.buttons["開啟通知"].firstMatch
        let shown = primer.waitForExistence(timeout: 8)
        shot("儲存後-通知說明")
        attach(text: "通知說明出現=\(shown)\n" + app.debugDescription, name: "通知說明結構")
        XCTAssertTrue(shown, "新增第一個守護地點後應出現通知說明")
        guard shown else { return }
        primer.tap(); sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch.exists
        let shotAlert = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shotAlert.name = "系統通知詢問"; shotAlert.lifetime = .keepAlways; self.add(shotAlert)
        attach(text: "系統詢問出現=\(systemAlert)", name: "系統詢問")
        XCTAssertTrue(systemAlert, "按開啟通知後應跳出系統詢問")
    }

    // MARK: - 外觀走查（層次／晴空湖水）

    /// 以指定外觀（與天空時段）重新啟動 App；--appearance／--force-sky-period 只有 DEBUG 建置會解析
    private func launchForAppearance(_ appearance: String, period: String? = nil) {
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["--appearance", appearance, "--skip-location-prompt", "--skip-notification-prompt"]
        if let period { app.launchArguments += ["--force-sky-period", period] }
        addUIInterruptionMonitor(withDescription: "系統權限") { alert in
            for title in ["使用 App 時允許", "允許", "好", "Allow While Using App", "Allow", "OK"] {
                let b = alert.buttons[title]
                if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()
        sleep(3)
        // 點頂端空白處觸發 interruption monitor（同 setUp 慣例）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    /// 兩種外觀各截：動態頁頂端、地圖頁、家人頁、設定頁外觀區塊；
    /// 晴空湖水另外用 --force-sky-period 各截清晨／白天／傍晚／夜晚的動態頁頂端
    func testAppearanceTour() throws {
        for appearance in ["layered", "skyLagoon"] {
            launchForAppearance(appearance)
            app.tabBars.buttons["動態"].firstMatch.tap()
            sleep(3)
            app.swipeDown(); app.swipeDown(); sleep(2)
            shot("\(appearance)-動態頁頂端")
            app.tabBars.buttons["地圖"].firstMatch.tap()
            sleep(4)
            shot("\(appearance)-地圖頁")
            app.tabBars.buttons["家人"].firstMatch.tap()
            sleep(3)
            shot("\(appearance)-家人頁")
            // 設定（齒輪）→ 顯示與文字 → 外觀區塊
            app.tabBars.buttons["動態"].firstMatch.tap()
            sleep(1)
            if tapIf("設定") {
                if tapIf("顯示與文字") {
                    sleep(1)
                    shot("\(appearance)-設定頁外觀區塊")
                    let picker = app.segmentedControls.firstMatch
                    attach(text: "外觀選擇器存在=\(picker.exists)", name: "\(appearance)-外觀選擇器")
                } else {
                    shot("\(appearance)-找不到顯示與文字")
                }
                dismissSheet()
            } else {
                shot("\(appearance)-找不到設定入口")
            }
        }
        for period in ["dawn", "day", "dusk", "night"] {
            launchForAppearance("skyLagoon", period: period)
            app.tabBars.buttons["動態"].firstMatch.tap()
            sleep(3)
            app.swipeDown(); app.swipeDown(); sleep(2)
            shot("skyLagoon-天空-\(period)")
        }
    }

    /// 地圖圖例：開關在工具列 ⓘ，展開後接在頂部狀態卡下方；左下角不再有圖例膠囊
    func testMapLegend() throws {
        app.tabBars.buttons["地圖"].firstMatch.tap()
        sleep(4)
        shot("地圖-圖例收合")
        let button = app.buttons["地圖圖例"].firstMatch
        guard button.waitForExistence(timeout: 5) else { attach(text: app.debugDescription, name: "地圖結構"); XCTFail("工具列找不到地圖圖例"); return }
        button.tap(); sleep(1)
        shot("地圖-圖例展開")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap(); sleep(1)
        shot("地圖-點空白收合")
    }

    /// 顯示範圍膠囊拆成兩顆：「調整」原地選單切換範圍（測完改回預設），左側按鈕把地圖移到範圍；
    /// 以及「關於」連點版本號 7 下解鎖／收起「示範與開發」
    func testScopeAndDevTools() throws {
        app.tabBars.buttons["地圖"].firstMatch.tap(); sleep(4)
        let adjust = app.buttons["調整地圖顯示範圍"].firstMatch
        guard adjust.waitForExistence(timeout: 5) else { attach(text: app.debugDescription, name: "地圖結構"); XCTFail("找不到調整鈕"); return }
        adjust.tap(); sleep(1)
        shot("範圍選單")
        app.buttons["只有我所在的縣市"].firstMatch.tap(); sleep(2)
        shot("只有我所在的縣市")
        adjust.tap(); sleep(1)
        app.buttons["我和家人的縣市"].firstMatch.tap(); sleep(2)
        let fly = app.buttons.containing(NSPredicate(format: "label BEGINSWITH '顯示範圍'")).firstMatch
        if fly.exists { fly.tap(); sleep(2) }
        shot("移到顯示範圍")

        app.buttons["設定"].firstMatch.tap(); sleep(2)
        let about = app.staticTexts["關於安心圈"].firstMatch
        for _ in 0..<5 where !about.isHittable { app.swipeUp(); sleep(1) }
        shot("設定頁")
        about.tap(); sleep(2)
        let version = app.staticTexts["版本"].firstMatch
        guard version.waitForExistence(timeout: 5) else { XCTFail("找不到版本"); return }
        for _ in 0..<7 { version.tap() }
        sleep(1)
        shot("關於-連點版本號後")
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        app.swipeUp(); app.swipeUp(); sleep(1)
        // 區塊標題可能已捲出畫面，改以區塊最後一顆「收起示範與開發」判斷
        let hasDemo = app.buttons["收起示範與開發"].exists
        shot("設定-示範與開發")
        attach(text: "示範與開發出現=\(hasDemo)", name: "解鎖結果")
        XCTAssertTrue(hasDemo, "連點 7 下後應出現示範與開發")
        if app.buttons["收起示範與開發"].exists { app.buttons["收起示範與開發"].tap(); sleep(1) }
        attach(text: "收起後仍存在=\(app.buttons["收起示範與開發"].exists)", name: "收起結果")
    }
}
