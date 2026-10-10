import StoreKit
import SwiftUI

/// 升級（Guardian+）定價頁——接 StoreKit 2 真實金流（見 EntitlementStore）。
/// 設計原則：核心安全警報「兩邊都免費」的訊息要最醒目，付費牆只擋規模與便利。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var store
    /// 三張方案卡的選中狀態：預設年訂為主推（低頻安全 App 用「一年的安心」對抗月訂 churn），
    /// 終身買斷是第三選項，只給想一次付清的使用者，不搶主推位置。
    #if DEBUG
    /// 本機測試價格的 fallback：只要是 DEBUG build 且真的商品讀取失敗（不論是 --show-paywall
    /// 截圖模式、還是單純沒用 Xcode ▶️ Run 啟動吃不到 scheme 的 .storekit 設定、或 App Store
    /// Connect 那邊訂閱項目還沒建好），一律顯示與 HavenCircle.storekit 一致的靜態價格，
    /// 讓開發時可以直接看到完整版面，不必依賴啟動方式或 ASC 進度。發佈版（Release）
    /// 這個分支完全不會被編譯進去，真實使用者一律走下面 `#else` 的 nil，
    /// 商品讀取失敗時只會看到誠實的錯誤卡＋重試，不會出現假價格。
    private var screenshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-paywall") || store.productLoadError != nil
    }
    private func staticPrice(_ value: String) -> String? { screenshotMode ? value : nil }
    #else
    private func staticPrice(_ value: String) -> String? { nil }
    #endif

    private enum PlanOption {
        case yearly, monthly, lifetime
    }
    @State private var selectedPlan: PlanOption = .yearly
    @State private var showManageSubscriptions = false

    // 免費 vs 進階分層：付費只擴充規模和歷史，不碰核心安全警報。
    // 額度數字一律讀 FreeTier.swift，不寫死數字——調整額度只需要改那邊即可讓這張表跟著變。
    private var featureHighlights: [(icon: String, title: String, detail: String)] {
        [
            ("checkmark.shield.fill", "核心災害警報", "免費與 Guardian+ 一致，全開"),
            ("mappin.and.ellipse", "守護地點", "\(FreeTier.maxPlaces) 個 → 無上限"),
            ("person.3.fill", "家庭成員", "\(FreeTier.maxFamilyMembers) 人 → 無上限"),
            ("clock.arrow.circlepath", "歷史回顧", "\(FreeTier.historyDays) 天 → \(FreeTier.plusHistoryDays) 天"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 整頁呈現，不再被半頁 sheet 的高度限制卡住：首屏放得下「值不值得、選哪一個、怎麼開始」，
                // 完整呼吸空間讓層次做得出來；比較與條款留在下方可捲動區。
                VStack(spacing: HCSpacing.x3) {
                    if store.isPlus {
                        header
                        guardianPlusStatusCard
                        safetyFreeBanner
                    } else {
                        purchaseDecisionSection
                        // 首屏結束後才顯示的次要動作：完整比較表已在首屏攤開，這裡只剩安全承諾與恢復購買/管理訂閱。
                        safetyFreeBanner
                        restoreAndManageButtons
                    }
                    finePrint
                    legalLinks
                }
                .padding(.horizontal, HCSpacing.x4)
                .padding(.top, HCSpacing.x2)
                .padding(.bottom, HCSpacing.x6)
            }
            .navigationTitle("升級 Guardian+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 整頁呈現沒有下滑手勢可以隨手關掉，右上角要有一顆夠明顯、好按的關閉鍵，
                // 不能讓使用者覺得被困住——圓形底色的 X 比純文字「關閉」更符合整頁付費頁的慣例。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.secondary.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("關閉")
                }
            }
            .analyticsScreen("paywall")
            .task { await store.loadProducts() }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        }
    }

    /// 商品真的載不到時，CTA／選中方案條款一起讓位給 pricingCards 自己的重試卡——
    /// 不然價格是空字串會拼出「／年，自動續訂…」這種看起來壞掉的文字。
    private var hasProductLoadError: Bool {
        store.productLoadError != nil && staticPrice("") == nil
    }

    /// 首屏就是完整的決策單位：不需要展開或滑動就能看到全部功能與所有方案金額，直接就能開始試用/購買。
    /// 次要資訊（安全承諾、恢復購買、條款）自然接在下面，使用者往下滑才會看到。
    private var purchaseDecisionSection: some View {
        VStack(spacing: HCSpacing.x3) {
            header
            featureGrid
            pricingCards
            if !hasProductLoadError {
                ctaButton
                selectedPlanDisclosure
            }
            if let purchaseError = store.purchaseError {
                Text(purchaseError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 品牌漸層底卡＋置中徽章：不是裸白底上貼一顆圖示，而是有份量的「這是賣點頁」開場。
    private var header: some View {
        VStack(spacing: HCSpacing.x2) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(HCColor.brandFill.gradient, in: Circle())
                .shadow(color: HCColor.brand.opacity(0.35), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("把守護範圍，留給更多重要的人與地點")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text("適合多據點、大家庭，或需要完整一年回顧的人。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HCSpacing.x4)
        .background(
            LinearGradient(
                colors: [HCColor.brand.opacity(0.16), HCColor.brand.opacity(0.02)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
        )
    }

    /// 最醒目的一條：安全永遠免費（倫理與信任的核心訊息）
    private var safetyFreeBanner: some View {
        HStack(alignment: .center, spacing: HCSpacing.x2) {
            Image(systemName: "checkmark.shield.fill")
                .fontWeight(.medium)
                .foregroundStyle(HCColor.brandText)
            Text("火災、地震、颱風等**保命警報永遠免費**，付費只解鎖規模與便利。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HCSpacing.x3)
        .padding(.vertical, HCSpacing.x2)
        .background(
            HCColor.brand.opacity(0.10),
            in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                .stroke(HCColor.brand.opacity(0.22), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(HCColor.brand)
                .frame(width: HCSpacing.x1)
                .padding(.vertical, HCSpacing.x2)
        }
    }

    /// 已是 Guardian+：整頁改為感謝狀態，不再顯示購買 UI。
    /// 終身買斷（非消耗型）沒有訂閱可管理，文案與按鈕都要跟訂閱制區分開來。
    private var guardianPlusStatusCard: some View {
        VStack(spacing: HCSpacing.x3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(HCColor.brandText)
            Text(store.isLifetime ? "你已是終身 Guardian+" : "你已是 Guardian+")
                .font(.title3.weight(.bold))
            Text(
                store.isLifetime
                    ? "謝謝你的支持，讓安心圈能持續守護更多家庭。你已一次付清，永久解鎖家庭成員、多個關心據點與完整歷史回顧，不會過期也不需要續訂。"
                    : "謝謝你的支持，讓安心圈能持續守護更多家庭。你的家庭成員、多個關心據點與完整歷史回顧都已解鎖。"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if !store.isLifetime {
                Button {
                    showManageSubscriptions = true
                } label: {
                    Text("管理訂閱")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, HCSpacing.x1)
            }
        }
        .frame(maxWidth: .infinity)
        .hcCard()
    }

    /// 首屏就攤開全部四項解鎖內容——2x2 圖示卡比表格更好掃視，也不必展開才看得到「付費到底多什麼」。
    private var featureGrid: some View {
        VStack(alignment: .leading, spacing: HCSpacing.x2) {
            Text("解鎖內容")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: HCSpacing.x2),
                    GridItem(.flexible(), spacing: HCSpacing.x2),
                ],
                spacing: HCSpacing.x2
            ) {
                ForEach(featureHighlights, id: \.title) { item in
                    VStack(alignment: .leading, spacing: HCSpacing.x1) {
                        Image(systemName: item.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HCColor.brandText)
                            .frame(width: 28, height: 28)
                            .background(HCColor.brand.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HCSpacing.x3)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var pricingCards: some View {
        if hasProductLoadError {
            VStack(spacing: HCSpacing.x2) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(store.productLoadError ?? "暫時無法取得訂閱價格")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重試") {
                    Task { await store.reloadProducts() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(HCColor.brandFill)
            }
            .frame(maxWidth: .infinity)
            .padding(HCSpacing.x4)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
        } else {
            // 一張主推大卡（年訂）撐住視覺重量，月訂／終身收成並排的精簡小卡——
            // 三張同等大小的卡片並排時，使用者反而看不出來哪個是建議選項。
            VStack(spacing: HCSpacing.x2) {
                heroPlanCard(
                    title: "年訂",
                    price: store.yearlyProduct?.displayPrice ?? staticPrice("NT$690"),
                    unit: "每年",
                    note: yearlyNote,
                    badge: "最划算 · 省 36%",
                    selected: selectedPlan == .yearly
                ) {
                    selectedPlan = .yearly
                }
                HStack(spacing: HCSpacing.x2) {
                    compactPlanRow(
                        title: "月訂",
                        price: store.monthlyProduct?.displayPrice ?? staticPrice("NT$90"),
                        unit: "/月",
                        note: "隨時可取消",
                        selected: selectedPlan == .monthly
                    ) {
                        selectedPlan = .monthly
                    }
                    compactPlanRow(
                        title: "終身",
                        price: store.lifetimeProduct?.displayPrice ?? staticPrice("NT$1,490"),
                        unit: "一次付清",
                        note: "永久有效",
                        selected: selectedPlan == .lifetime
                    ) {
                        selectedPlan = .lifetime
                    }
                }
            }
        }
    }

    /// 年訂副標：優先顯示真實試用天數（讀自 .storekit／App Store Connect 設定的
    /// introductory offer），沒有試用資訊時退回單純的折算文案。
    private var yearlyNote: String {
        if store.yearlyProduct == nil, staticPrice("") != nil {
            return "約 NT$58/月 · 附 14 天免費試用"
        }
        var parts: [String] = []
        if let yearly = store.yearlyProduct {
            let monthly = yearly.price / 12
            let formatted = monthly.formatted(yearly.priceFormatStyle)
            parts.append("約 \(formatted)/月")
        }
        if let trialDays = freeTrialDays(for: store.yearlyProduct) {
            parts.append("附 \(trialDays) 天免費試用")
        }
        return parts.isEmpty ? "年繳最划算" : parts.joined(separator: " · ")
    }

    private var yearlyTrialDays: Int? {
        freeTrialDays(for: store.yearlyProduct) ?? (staticPrice("") != nil ? 14 : nil)
    }

    /// 從商品的 introductory offer 讀出免費試用天數；非「免費試用」型態的優惠一律回傳 nil。
    private func freeTrialDays(for product: Product?) -> Int? {
        guard let offer = product?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let value = offer.period.value
        switch offer.period.unit {
        case .day: return value
        case .week: return value * 7
        case .month: return value * 30
        case .year: return value * 365
        @unknown default: return nil
        }
    }

    /// 主推大卡（年訂專用）：選中時填上品牌色淺底＋粗邊框＋陰影，右上角是實心色塊徽章，
    /// 視覺重量明顯高於下面的月訂／終身小卡——一眼就知道「這是建議選項」。
    private func heroPlanCard(
        title: String,
        price: String?,
        unit: String,
        note: String,
        badge: String?,
        selected: Bool,
        tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: HCSpacing.x2) {
                HStack {
                    HStack(spacing: HCSpacing.x1) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? HCColor.brandText : .secondary)
                            .font(.body.weight(.medium))
                        Text(title).font(.body.weight(.bold))
                    }
                    Spacer(minLength: HCSpacing.x2)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, HCSpacing.x2)
                            .padding(.vertical, HCSpacing.x1)
                            .background(HCColor.brandFill, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: HCSpacing.x1) {
                    if let price {
                        Text(price).font(.system(size: 30, weight: .bold))
                    } else {
                        // 商品尚未載入完成：先用同尺寸佔位文字避免版面跳動，載入完成即替換
                        Text("NT$00").font(.system(size: 30, weight: .bold)).redacted(reason: .placeholder)
                    }
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HCSpacing.x4)
            .background(
                selected ? HCColor.brand.opacity(0.10) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                    .stroke(selected ? HCColor.brand : Color(.separator), lineWidth: selected ? 2 : 1)
            )
            .shadow(color: selected ? HCColor.brand.opacity(0.15) : .clear, radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(price == nil)
    }

    /// 次要方案的精簡小卡（月訂／終身並排）：只留標題、價格、一句話備註，
    /// 刻意比年訂卡矮小、素色，讓主推選項保有唯一的視覺焦點。
    private func compactPlanRow(
        title: String,
        price: String?,
        unit: String,
        note: String,
        selected: Bool,
        tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HCSpacing.x1) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(selected ? HCColor.brandText : .secondary)
                    Text(title).font(.subheadline.weight(.semibold))
                }
                if let price {
                    Text("\(price) \(unit)")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("NT$00 \(unit)")
                        .font(.footnote.weight(.semibold))
                        .redacted(reason: .placeholder)
                }
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HCSpacing.x3)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.card, style: .continuous)
                    .stroke(selected ? HCColor.brand : Color(.separator), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(price == nil)
    }

    private var ctaButton: some View {
        // 主推填色樣式只保留給年訂；月訂／終身用同一套「次要」外框樣式，避免搶主推的視覺重量。
        let isPrimaryStyle = selectedPlan == .yearly
        return Button {
            Task { await purchaseSelectedPlan() }
        } label: {
            HStack(spacing: HCSpacing.x2) {
                if store.purchaseInProgress {
                    ProgressView()
                        .tint(isPrimaryStyle ? .white : HCColor.brand)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(ctaTitle)
                        .font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HCSpacing.x3)
            .background(
                isPrimaryStyle ? AnyShapeStyle(HCColor.brandFill.gradient) : AnyShapeStyle(Color.clear),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isPrimaryStyle ? Color.clear : Color(.separator), lineWidth: 1)
            )
            .foregroundStyle(isPrimaryStyle ? .white : .primary)
            .shadow(color: isPrimaryStyle ? HCColor.brand.opacity(0.3) : .clear, radius: 10, y: 5)
        }
        .disabled(store.purchaseInProgress || selectedProduct == nil)
    }

    private var selectedPlanDisclosure: some View {
        Text(selectedPlanTerms)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedPlanTerms: String {
        switch selectedPlan {
        case .yearly:
            let price = store.yearlyProduct?.displayPrice ?? staticPrice("NT$690") ?? ""
            if let trialDays = yearlyTrialDays {
                return "先免費試用 \(trialDays) 天，之後 \(price)/年；可隨時在 Apple 訂閱中取消。"
            }
            return "\(price)/年，自動續訂；可隨時在 Apple 訂閱中取消。"
        case .monthly:
            let price = store.monthlyProduct?.displayPrice ?? staticPrice("NT$90") ?? ""
            return "\(price)/月，自動續訂；可隨時在 Apple 訂閱中取消。"
        case .lifetime:
            let price = store.lifetimeProduct?.displayPrice ?? staticPrice("NT$1,490") ?? ""
            return "\(price) 一次付清，永久有效，不會自動續訂。"
        }
    }

    private var ctaTitle: String {
        switch selectedPlan {
        case .yearly:
            return yearlyTrialDays != nil ? "開始 \(yearlyTrialDays!) 天免費試用" : "訂閱 Guardian+"
        case .monthly:
            return "訂閱 Guardian+"
        case .lifetime:
            return "一次買斷 Guardian+"
        }
    }

    private var selectedProduct: Product? {
        switch selectedPlan {
        case .yearly: return store.yearlyProduct
        case .monthly: return store.monthlyProduct
        case .lifetime: return store.lifetimeProduct
        }
    }

    private func purchaseSelectedPlan() async {
        guard let product = selectedProduct else { return }
        await store.purchase(product)
    }

    private var restoreAndManageButtons: some View {
        HStack(spacing: HCSpacing.x6) {
            Button("恢復購買") {
                Task { await store.restorePurchases() }
            }
            Button("管理訂閱") {
                showManageSubscriptions = true
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .disabled(store.purchaseInProgress)
    }

    /// 條款內容跟原本一字不改（法遵要求的揭露文字都在），只是從三段分開、同字重的
    /// 大塊灰字，併成一段更小、更安靜的文字——不然一路捲下來全是同樣顯眼的警語，
    /// 讀起來像「這頁很多陷阱」，反而破壞信任感。
    private var finePrint: some View {
        Text(finePrintText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var finePrintText: String {
        // 倫理承諾：不分免費或付費，保命警報一律免費——這是信任的底線，寫在付費頁最顯眼的收尾處
        var parts = ["災害警報推播永遠免費，不分免費或付費。"]
        // 免責文案跟著選中方案切換：終身是一次性買斷，掛訂閱自動續訂條款會誤導
        if selectedPlan == .lifetime {
            parts.append("終身方案為一次性付費、永久有效，不會自動續訂或再次扣款。")
        } else {
            parts.append("訂閱為自動續訂：除非在到期前至少 24 小時取消，否則會自動以相同方案續約並向 Apple 帳號扣款；可隨時在「設定 > Apple 帳號 > 訂閱」中取消或管理。試用期內取消不收費。")
        }
        parts.append("安心圈不是 110／119 或緊急救難服務。")
        return parts.joined(separator: " ")
    }

    private var legalLinks: some View {
        HStack(spacing: HCSpacing.x4) {
            NavigationLink("隱私權政策") {
                LegalDocumentView(document: .privacy)
            }
            NavigationLink("使用條款") {
                LegalDocumentView(document: .terms)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    PaywallView()
        .environment(EntitlementStore())
}
