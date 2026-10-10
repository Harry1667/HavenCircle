import Foundation
import StoreKit
import os

/// StoreKit 2 訂閱狀態與購買流程。
///
/// 設計：
/// - 商品 ID 為單一真相來源（[monthlyProductID] / [yearlyProductID] / [lifetimeProductID]），畫面一律
///   透過 [monthlyProduct] / [yearlyProduct] / [lifetimeProduct] 拿 `Product`，不要另外硬寫字串。
/// - `isPlus` 只信任 `Transaction.currentEntitlements`（App Store 端真相），不做本機快取判定；
///   家庭共享（Family Sharing）成員即使沒有自己買，收到共享的訂閱也會出現在這裡，走同一條判定。
///   終身買斷（非消耗型）交易同樣會出現在 `currentEntitlements`（消耗型才不會），因此沿用同一條
///   `productIDs.contains(...)` 判斷即可涵蓋，不需要另外比對 `Transaction.productType`。
/// - `Transaction.updates` 長聽整個 App 生命週期：外部續訂、退款、方案變更、Ask to Buy
///   核准都會即時反映，不必等下次啟動或手動 restore。
/// - `isPlus` 除了讓 PaywallView 顯示「已是 Guardian+」狀態，也是 [canAddPlace] / [canAddFamilyMember]
///   等功能閘門判斷的依據（見 FreeTier.swift 額度定義）。
@MainActor
@Observable
final class EntitlementStore {
    /// Guardian+ 月訂閱商品 ID（同一訂閱群組「Guardian+」）
    static let monthlyProductID = "com.gomiigo.HavenCircleApp.plus.monthly"
    /// Guardian+ 年訂閱商品 ID（同一訂閱群組「Guardian+」）
    static let yearlyProductID = "com.gomiigo.HavenCircleApp.plus.yearly"
    /// Guardian+ 終身買斷商品 ID（非消耗型 IAP，不屬於訂閱群組，家庭共享同樣開啟）
    static let lifetimeProductID = "com.gomiigo.HavenCircleApp.plus.lifetime"
    /// 顯示順序固定為「年、月、終身」：PaywallView 依這個順序排序卡片，不依賴 App Store 回傳順序。
    static let productIDs: [String] = [yearlyProductID, monthlyProductID, lifetimeProductID]

    private(set) var products: [Product] = []
    private(set) var isPlus = false
    /// 目前的 Plus 權益是否來自終身買斷（非消耗型）：用來讓 PaywallView 顯示「終身 Guardian+」
    /// 而非「管理訂閱」——非消耗型沒有訂閱可管理。
    private(set) var isLifetime = false
    private(set) var isLoadingProducts = false
    /// 載入商品失敗時的人話文案；nil 代表沒有錯誤（見 [loadProducts]）
    private(set) var productLoadError: String?
    private(set) var purchaseInProgress = false
    /// 購買／恢復購買失敗時的人話文案；nil 代表沒有待顯示的錯誤
    private(set) var purchaseError: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    var monthlyProduct: Product? { products.first { $0.id == Self.monthlyProductID } }
    var yearlyProduct: Product? { products.first { $0.id == Self.yearlyProductID } }
    var lifetimeProduct: Product? { products.first { $0.id == Self.lifetimeProductID } }

    // 沒有 deinit：這個物件跟 App 同壽命（見 HavenCircleApp 以 @State 持有並用 environment 注入），
    // 不會提前釋放；且 deinit 一律是 nonisolated context，無法安全存取 MainActor 隔離的屬性。

    /// App 啟動時呼叫一次（見 HavenCircleApp）：先用目前權益判斷 isPlus，
    /// 再開長聽監聽後續的續訂／退款／方案變更。
    func start() {
        Task { await refreshEntitlements() }
        transactionUpdatesTask = listenForTransactionUpdates()
    }

    /// 向 App Store 取商品資料（價格、試用資訊等）。已載入過就不重覆打——
    /// PaywallView 每次出現都可能呼叫，不該每次都重新打 App Store。
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        productLoadError = nil
        defer { isLoadingProducts = false }
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            if storeProducts.isEmpty {
                AppLog.cloudError("StoreKit 商品清單為空：檢查 .storekit 設定或 App Store Connect 產品狀態")
                productLoadError = "暫時無法取得訂閱價格，請稍後再試。"
                return
            }
            // 固定依 productIDs 的順序排列（年訂在前），不依賴 App Store 回傳順序
            products = Self.productIDs.compactMap { id in storeProducts.first { $0.id == id } }
        } catch {
            productLoadError = Self.userFacingMessage(for: error, context: "載入訂閱商品失敗")
        }
    }

    /// 重新載入（供「重試」按鈕使用）：清空目前商品清單後重打一次。
    func reloadProducts() async {
        products = []
        await loadProducts()
    }

    /// 購買指定商品；含驗證（VerificationResult）與 Transaction.finish()。
    /// 回傳是否成功（成功後 `isPlus` 會同步更新，UI 不需要另外查詢）。
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }
        Analytics.track("purchase_started")
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await refreshEntitlements()
                await transaction.finish()
                // 終身買斷用獨立事件名區分（Analytics.track 不支援附加參數）
                Analytics.track(product.id == Self.lifetimeProductID ? "purchase_success_lifetime" : "purchase_success")
                return true
            case .userCancelled:
                // 使用者主動取消，不是錯誤，不需要顯示任何訊息
                return false
            case .pending:
                purchaseError = "購買正在等待確認（例如家長同意），完成後會自動生效，不需要重新購買。"
                return false
            @unknown default:
                purchaseError = "購買未完成，請稍後再試。"
                return false
            }
        } catch {
            purchaseError = Self.userFacingMessage(for: error, context: "購買失敗")
            return false
        }
    }

    /// 恢復購買：向 App Store 同步既有交易（AppStore.sync），完成後重新判定 isPlus。
    func restorePurchases() async {
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            Analytics.track("purchase_restored")
        } catch {
            purchaseError = Self.userFacingMessage(for: error, context: "恢復購買失敗")
        }
    }

    /// 依 `Transaction.currentEntitlements` 重新判定 isPlus——這是 App Store 端的真相來源，
    /// 家庭共享成員收到的共享訂閱也會出現在這裡，跟自己購買走同一條判定，不需要另外分支。
    /// 同時判定 isLifetime：終身買斷（非消耗型）交易同樣出現在 currentEntitlements 裡。
    func refreshEntitlements() async {
        var active = false
        var lifetime = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result) else { continue }
            guard Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            active = true
            if transaction.productID == Self.lifetimeProductID {
                lifetime = true
            }
        }
        isPlus = active
        isLifetime = lifetime
    }

    /// 長聽交易更新：續訂、退款、方案升降級、Ask to Buy 核准都會從這裡進來。
    /// 用 weak self 避免這顆長跑 Task 讓 EntitlementStore 無法釋放（雖然實務上它跟 App 同壽命）。
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if let transaction = try? Self.checkVerified(update) {
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }
    }

    /// 驗證 StoreKit 回傳的交易簽章；未通過驗證一律視為不可信，不予採認。
    /// 明確標 nonisolated：純函式、不碰任何 MainActor 狀態，讓 [listenForTransactionUpdates]
    /// 的 detached task 不必為了呼叫這支函式而額外跳回 MainActor。
    private static nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw EntitlementError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum EntitlementError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        "交易驗證失敗，請稍後再試。"
    }
}

extension EntitlementStore {
    /// 是否還能新增「重要地點」：Guardian+ 無上限；免費方案受 [FreeTier.maxPlaces] 限制。
    /// 唯一共用判斷——FamilyHomeView（toolbar／addPlaceCard）、HomeStatusView（guardMorePlacesCard）
    /// 三處入口都呼叫這裡，不各自寫一份數字比較，避免三處的免費額度定義走岔。
    /// 鐵律：這條閘門只擋「新增地點」這個功能本身，不影響任何警報推播的接收。
    func canAddPlace(currentCount: Int) -> Bool {
        isPlus || currentCount < FreeTier.maxPlaces
    }

    /// 是否還能新增家庭成員（不含地點）：Guardian+ 無上限；免費方案受 [FreeTier.maxFamilyMembers] 限制。
    /// 注意：這條只擋「手動新增家人」入口，**不擋**輸入邀請碼加入他人家庭圈的路徑——
    /// 受邀者要不要進圈，不該被自己這台裝置的方案等級擋下。
    func canAddFamilyMember(currentCount: Int) -> Bool {
        isPlus || currentCount < FreeTier.maxFamilyMembers
    }

    /// 統一把 StoreKit 相關錯誤轉成人話：原始錯誤一律記 log（error 級）供除錯，
    /// UI 只顯示對使用者友善的訊息（做法比照 AuthService.userFacingMessage）。
    static func userFacingMessage(for error: Error, context: String) -> String {
        AppLog.cloudError("\(context)：\(error.localizedDescription)")

        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .networkError:
                return "網路連線有問題，請稍後再試。"
            case .notAvailableInStorefront:
                return "此訂閱在目前所在地區的 App Store 無法使用。"
            case .notEntitled:
                return "沒有取得使用權限，請確認 Apple 帳號登入狀態後再試。"
            case .userCancelled:
                return "已取消。"
            default:
                return "App Store 目前無法處理，請稍後再試。"
            }
        }

        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable:
                return "此方案目前無法購買，請稍後再試。"
            case .purchaseNotAllowed:
                return "這台裝置的設定不允許購買，請至「設定 > 螢幕使用時間」檢查是否限制了 App 內購買。"
            default:
                return "購買未完成，請稍後再試。"
            }
        }

        let nsError = error as NSError
        if error is URLError || nsError.domain == NSURLErrorDomain {
            return "網路連線有問題，請稍後再試。"
        }

        return "\(context)，請稍後再試。"
    }
}
